package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import lua "lib:lua"

FILETREE_FILTER_DEBOUNCE_MS :: 100
FILETREE_PREVIEW_DEBOUNCE_MS :: 80
FILETREE_FILTER_MAX_RESULTS :: 500
FILETREE_WALK_THREADS :: 0
FILETREE_PREWARM :: true

FileEntry :: struct {
	path:   string,
	name:   string,
	depth:  int,
	is_dir: bool,
}

WalkAdmit :: struct {
	dotfiles, ignored: bool,
	ignore:            ^map[string]bool,
	scope:             ^WalkScope,
}

Walk :: struct {
	refs:              int,
	root:              string,
	dotfiles, ignored: bool,
	cands:             [dynamic]FileEntry,
	valid:             bool,
	gen:               u64,
	builds:            u64,
	walk_ms:           f64,
	pw:                WalkPrewarm,
}

WalkPrewarm :: struct {
	thread:  ^thread.Thread,
	admit:   WalkAdmit,
	ignore:  map[string]bool,
	root:    string,
	staging: [dynamic]FileEntry,
	heap:    runtime.Allocator,
	gen:     u64,
	active:  bool,
	restart: bool,
	done:    bool,
}

WalkScope :: struct {
	refs:    int,
	all:     bool,
	listed:  map[string]bool,
	closure: map[string]bool,
	virtual: [dynamic]string,
	cands:   [dynamic]FileEntry,
	valid:   bool,
	gen:     u64,
	builds:  u64,
}

walk_entries_free :: proc(entries: ^[dynamic]FileEntry) {
	for e in entries {
		delete(e.path)
	}
	clear(entries)
}

walk_admit :: proc(a: ^WalkAdmit, name, p: string) -> bool {
	if a.scope != nil && (!a.scope.all || p in a.scope.closure) {
		return walk_scope_has(a.scope, p)
	}
	if !a.dotfiles && strings.has_prefix(name, ".") {
		return false
	}
	// ignored dirs are pruned before the walk descends, so no ancestor is ever ignored here
	return a.ignored || a.ignore == nil || !a.ignore[p]
}

walk_collect :: proc(a: ^WalkAdmit, dir: string, out: ^[dynamic]FileEntry, heap: runtime.Allocator) {
	dirp := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if dirp == nil {
		return
	}
	defer posix.closedir(dirp)
	for {
		entry := posix.readdir(dirp)
		if entry == nil {
			break
		}
		cname := cstring(raw_data(entry.d_name[:]))
		name := string(cname)
		if name == "." || name == ".." {
			continue
		}
		kind := entry.d_type
		if kind == .UNKNOWN {
			st: posix.stat_t
			if posix.fstatat(posix.dirfd(dirp), cname, &st, {.SYMLINK_NOFOLLOW}) != .OK {
				continue
			}
			kind = .DIR if posix.S_ISDIR(st.st_mode) else .REG
		}
		is_dir := kind == .DIR
		p := strings.concatenate({dir, "/", name}, context.temp_allocator)
		if !walk_admit(a, name, p) {
			continue
		}
		append(out, FileEntry{strings.clone(p, heap), "", 0, is_dir})
		if is_dir {
			walk_collect(a, p, out, heap)
		}
	}
}

WalkJob :: struct {
	admit: ^WalkAdmit,
	dirs:  [dynamic]string,
	out:   [dynamic]FileEntry,
	heap:  runtime.Allocator,
}

walk_worker :: proc(th: ^thread.Thread) {
	job := (^WalkJob)(th.data)
	for dir in job.dirs {
		walk_collect(job.admit, dir, &job.out, job.heap)
	}
}

// the root is read serially, then each top-level subtree goes to a worker (round-robin);
// workers only read the admit rules and clone with the shared heap allocator
walk_run :: proc(a: ^WalkAdmit, root: string, out: ^[dynamic]FileEntry, threads := -1) {
	heap := context.allocator
	top := make([dynamic]FileEntry, context.temp_allocator)
	walk_top: {
		dirp := posix.opendir(strings.clone_to_cstring(root, context.temp_allocator))
		if dirp == nil {
			return
		}
		defer posix.closedir(dirp)
		for {
			entry := posix.readdir(dirp)
			if entry == nil {
				break walk_top
			}
			cname := cstring(raw_data(entry.d_name[:]))
			name := string(cname)
			if name == "." || name == ".." {
				continue
			}
			kind := entry.d_type
			if kind == .UNKNOWN {
				st: posix.stat_t
				if posix.fstatat(posix.dirfd(dirp), cname, &st, {.SYMLINK_NOFOLLOW}) != .OK {
					continue
				}
				kind = .DIR if posix.S_ISDIR(st.st_mode) else .REG
			}
			p := strings.concatenate({root, "/", name}, context.temp_allocator)
			if walk_admit(a, name, p) {
				append(&top, FileEntry{p, "", 0, kind == .DIR})
			}
		}
	}
	top_dirs := make([dynamic]string, context.temp_allocator)
	for e in top {
		append(out, FileEntry{strings.clone(e.path, heap), "", 0, e.is_dir})
		if e.is_dir {
			append(&top_dirs, e.path)
		}
	}
	n := threads
	if n < 0 {
		n = FILETREE_WALK_THREADS
	}
	if n <= 0 {
		n = max(1, os.get_processor_core_count())
	}
	n = min(n, len(top_dirs))
	if n <= 1 {
		for d in top_dirs {
			walk_collect(a, d, out, heap)
		}
		return
	}
	jobs := make([]WalkJob, n, context.temp_allocator)
	workers := make([]^thread.Thread, n, context.temp_allocator)
	for &j in jobs {
		j.admit = a
		j.heap = heap
		j.dirs = make([dynamic]string, context.temp_allocator)
		j.out = make([dynamic]FileEntry, heap)
	}
	for d, i in top_dirs {
		append(&jobs[i % n].dirs, d)
	}
	for i in 0 ..< n {
		th := thread.create(walk_worker)
		th.data = &jobs[i]
		workers[i] = th
		thread.start(th)
	}
	for th in workers {
		thread.join(th)
	}
	for &j in jobs {
		append(out, ..j.out[:])
		delete(j.out)
	}
	for th in workers {
		thread.destroy(th)
	}
}

walk_acquire :: proc(editor: ^Editor, root: string, dotfiles, ignored: bool) -> ^Walk {
	for w in editor.walks {
		if w.root == root && w.dotfiles == dotfiles && w.ignored == ignored {
			w.refs += 1
			return w
		}
	}
	w := new(Walk)
	w.refs, w.root, w.dotfiles, w.ignored = 1, strings.clone(root), dotfiles, ignored
	append(&editor.walks, w)
	return w
}

walk_release :: proc(w: ^Walk) {
	if w != nil {
		w.refs -= 1
	}
}

walk_free :: proc(w: ^Walk) {
	walk_prewarm_cancel(w)
	walk_entries_free(&w.cands)
	delete(w.cands)
	delete(w.root)
	free(w)
}

// an unreferenced walk is freed once its prewarm landed, so dropping one never joins a thread
walk_gc :: proc(editor: ^Editor) {
	for i := len(editor.walks) - 1; i >= 0; i -= 1 {
		if w := editor.walks[i]; w.refs <= 0 && !w.pw.active {
			walk_free(w)
			ordered_remove(&editor.walks, i)
		}
	}
}

walk_valid :: proc(editor: ^Editor, w: ^Walk) -> bool {
	return w.valid && w.gen == editor.walk_gen
}

walk_invalidate :: proc(editor: ^Editor) {
	editor.walk_gen += 1
}

walk_admit_of :: proc(editor: ^Editor, w: ^Walk) -> WalkAdmit {
	return {dotfiles = w.dotfiles, ignored = w.ignored, ignore = &editor.filetree.ignored}
}

walk_cands :: proc(editor: ^Editor, w: ^Walk) -> []FileEntry {
	w.walk_ms = 0
	if walk_valid(editor, w) {
		return w.cands[:]
	}
	if w.pw.active {
		if walk_prewarm_finish(editor, w) {
			return w.cands[:]
		}
		w.pw.restart = false
	}
	walk_entries_free(&w.cands)
	at := time.tick_now()
	admit := walk_admit_of(editor, w)
	walk_run(&admit, w.root, &w.cands)
	w.walk_ms = time.duration_milliseconds(time.tick_since(at))
	w.valid, w.gen = true, editor.walk_gen
	w.builds += 1
	return w.cands[:]
}

walk_prewarm :: proc(editor: ^Editor, w: ^Walk) {
	pw := &w.pw
	if !FILETREE_PREWARM || !editor.filetree.scanned || walk_valid(editor, w) {
		return
	}
	if pw.active {
		pw.restart = true
		return
	}
	pw.ignore = make(map[string]bool)
	for key in editor.filetree.ignored {
		pw.ignore[strings.clone(key)] = true
	}
	pw.admit = {dotfiles = w.dotfiles, ignored = w.ignored, ignore = &pw.ignore}
	pw.root = strings.clone(w.root)
	pw.heap = context.allocator
	pw.gen = editor.walk_gen
	pw.done, pw.restart, pw.active = false, false, true
	pw.thread = thread.create(walk_prewarm_run)
	pw.thread.data = pw
	thread.start(pw.thread)
}

walk_prewarm_run :: proc(th: ^thread.Thread) {
	pw := (^WalkPrewarm)(th.data)
	// staging is freed by the main thread, so clone with its allocator
	context.allocator = pw.heap
	walk_run(&pw.admit, pw.root, &pw.staging)
	sync.atomic_store(&pw.done, true)
}

walk_prewarm_release :: proc(pw: ^WalkPrewarm) {
	for key in pw.ignore {
		delete(key)
	}
	delete(pw.ignore)
	pw.ignore = nil
	delete(pw.root)
	pw.root = ""
	walk_entries_free(&pw.staging)
	delete(pw.staging)
	pw.staging = {}
}

walk_prewarm_join :: proc(pw: ^WalkPrewarm) {
	thread.join(pw.thread)
	thread.destroy(pw.thread)
	pw.thread = nil
	pw.active = false
}

walk_prewarm_finish :: proc(editor: ^Editor, w: ^Walk) -> bool {
	pw := &w.pw
	walk_prewarm_join(pw)
	if pw.gen != editor.walk_gen {
		walk_prewarm_release(pw)
		return false
	}
	if !walk_valid(editor, w) {
		walk_entries_free(&w.cands)
		delete(w.cands)
		w.cands = pw.staging
		pw.staging = {}
		w.valid, w.gen = true, editor.walk_gen
		w.builds += 1
	}
	walk_prewarm_release(pw)
	return true
}

walk_prewarm_cancel :: proc(w: ^Walk) {
	if !w.pw.active {
		return
	}
	walk_prewarm_join(&w.pw)
	w.pw.restart = false
	walk_prewarm_release(&w.pw)
}

walk_busy :: proc(editor: ^Editor) -> bool {
	for w in editor.walks {
		if w.pw.active {
			return true
		}
	}
	return false
}

walk_pump :: proc(editor: ^Editor) -> bool {
	landed := false
	for w in editor.walks {
		if !w.pw.active || !sync.atomic_load(&w.pw.done) {
			continue
		}
		walk_prewarm_finish(editor, w)
		landed = true
		if w.pw.restart && w.refs > 0 {
			w.pw.restart = false
			walk_prewarm(editor, w)
		}
	}
	walk_gc(editor)
	return landed
}

walk_destroy_all :: proc(editor: ^Editor) {
	for w in editor.walks {
		walk_free(w)
	}
	delete(editor.walks)
}

walk_scope_new :: proc(root: string, base: ^WalkScope, within, virtual: []string) -> ^WalkScope {
	s := new(WalkScope)
	s.refs = 1
	if base != nil {
		for key in base.listed {
			s.listed[strings.clone(key)] = true
		}
		for key in base.closure {
			s.closure[strings.clone(key)] = true
		}
		for v in base.virtual {
			append(&s.virtual, strings.clone(v))
		}
	}
	for p in within {
		walk_set_add(&s.listed, p)
		walk_closure_add(&s.closure, root, p)
	}
	for p in virtual {
		append(&s.virtual, strings.clone(p))
		walk_closure_add(&s.closure, root, p)
	}
	return s
}

walk_scope_release :: proc(s: ^WalkScope) {
	if s == nil {
		return
	}
	s.refs -= 1
	if s.refs > 0 {
		return
	}
	walk_set_clear(&s.listed)
	delete(s.listed)
	walk_set_clear(&s.closure)
	delete(s.closure)
	for v in s.virtual {
		delete(v)
	}
	delete(s.virtual)
	walk_entries_free(&s.cands)
	delete(s.cands)
	free(s)
}

walk_set_add :: proc(set: ^map[string]bool, path: string) {
	if path not_in set^ {
		set^[strings.clone(path)] = true
	}
}

walk_set_clear :: proc(set: ^map[string]bool) {
	for key in set^ {
		delete(key)
	}
	clear(set)
}

walk_closure_add :: proc(set: ^map[string]bool, root, path: string) {
	walk_set_add(set, path)
	p := path
	for strings.has_prefix(p, root) && p != root {
		np := filetree_parent_dir(p)
		if np == p {
			break
		}
		p = np
		walk_set_add(set, p)
	}
}

walk_scope_has :: proc(s: ^WalkScope, p: string) -> bool {
	if p in s.closure {
		return true
	}
	for q := p; true; {
		np := filetree_parent_dir(q)
		if np == q {
			return false
		}
		q = np
		if q in s.listed {
			return true
		}
	}
	return false
}

walk_scope_cands :: proc(editor: ^Editor, w: ^Walk, s: ^WalkScope) -> []FileEntry {
	w.walk_ms = 0
	if s.valid && s.gen == editor.walk_gen {
		return s.cands[:]
	}
	walk_entries_free(&s.cands)
	at := time.tick_now()
	admit := walk_admit_of(editor, w)
	admit.scope = s
	walk_run(&admit, w.root, &s.cands)
	under := strings.concatenate({w.root, "/"}, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for d in s.virtual {
		for p := d; strings.has_prefix(p, under) && !(p in seen) && !os.exists(p); p = filetree_parent_dir(p) {
			seen[p] = true
			append(&s.cands, FileEntry{strings.clone(p), "", 0, p != d})
		}
	}
	w.walk_ms = time.duration_milliseconds(time.tick_since(at))
	s.valid, s.gen = true, editor.walk_gen
	s.builds += 1
	return s.cands[:]
}

walk_ready :: proc(editor: ^Editor, src: ^ListSource) -> bool {
	if src.wscope != nil {
		return src.wscope.valid && src.wscope.gen == editor.walk_gen
	}
	return walk_valid(editor, src.walk) && !src.walk.pw.active
}

walk_source_cands :: proc(editor: ^Editor, src: ^ListSource) -> []FileEntry {
	if src.wscope != nil {
		return walk_scope_cands(editor, src.walk, src.wscope)
	}
	return walk_cands(editor, src.walk)
}

walk_narrow_reset :: proc(src: ^ListSource) {
	delete(src.narrow_q)
	src.narrow_q = ""
	clear(&src.narrow_idx)
}

pane_tree_expanded :: proc(p: ^Pane, path: string) -> bool {
	if v, ok := p.list.expanded[path]; ok {
		return v
	}
	return p.list.source.wscope != nil && !p.list.source.wscope.all
}

pane_tree_set :: proc(p: ^Pane, path: string, on: bool) {
	if path in p.list.expanded {
		p.list.expanded[path] = on
	} else {
		p.list.expanded[strings.clone(path)] = on
	}
}

list_walk_fill :: proc(editor: ^Editor, p: ^Pane) {
	src := &p.list.source
	p.refill_due = false
	at := time.tick_now()
	keep := ""
	if p.list.sel >= 0 && p.list.sel < len(src.entries) {
		keep = strings.clone(src.entries[p.list.sel].path, context.temp_allocator)
	}
	walk_entries_free(&src.entries)
	p.list.anchor, p.list.more, p.list.filtered = nil, false, false
	clear(&p.list.matches)
	query := ""
	if f := pane_filter(p); f != nil {
		query = textfield_str(&f.field)
	}
	src.filtering = query != ""
	if src.filtering {
		list_walk_filter(editor, p, query)
	} else {
		walk_narrow_reset(src)
		list_walk_dir(editor, p, src.walk.root, 0)
	}
	p.list.sel = 0
	if keep != "" {
		for e, i in src.entries {
			if e.path == keep {
				p.list.sel = i
				break
			}
		}
	}
	p.list.stamp = list_stamp(editor, p)
	pane_scroll_fit(p, pane_geom(editor, p).list.h)
	if src.filtering {
		note := fmt.tprintf(" (walk %.0fms)", src.walk.walk_ms) if src.walk.walk_ms > 0 else ""
		ms := time.duration_milliseconds(time.tick_since(at))
		editor_log(editor, .Debug, "Filetree", fmt.tprintf("filter %q %.0fms%s  %d/%d", query, ms, note, len(src.entries), len(src.narrow_idx)))
	}
}

list_walk_filter :: proc(editor: ^Editor, p: ^Pane, query: string) {
	src := &p.list.source
	cands := walk_source_cands(editor, src)
	root := src.walk.root
	builds := src.wscope.builds if src.wscope != nil else src.walk.builds
	if len(cands) == 0 {
		walk_narrow_reset(src)
		return
	}
	// a longer query matches a subset of the shorter one's hits, so rank only those
	incremental := src.narrow_q != "" && src.narrow_builds == builds && len(query) > len(src.narrow_q) && strings.has_prefix(query, src.narrow_q)
	base := make([dynamic]int, 0, len(cands), context.temp_allocator)
	if incremental {
		append(&base, ..src.narrow_idx[:])
	} else {
		for i in 0 ..< len(cands) {
			append(&base, i)
		}
	}
	names := make([]string, len(base), context.temp_allocator)
	for ci, i in base {
		names[i] = walk_rel(cands[ci].path, root)
	}
	limit := p.list.max if p.list.max > 0 else FILETREE_FILTER_MAX_RESULTS
	f := fuzzy_begin(names)
	ranked := fuzzy_rank(&f, query)
	clear(&src.narrow_idx)
	for pos, i in ranked {
		ci := base[pos]
		append(&src.narrow_idx, ci)
		if i >= limit {
			continue
		}
		path := strings.clone(cands[ci].path)
		append(&src.entries, FileEntry{path, walk_rel(path, root), 0, cands[ci].is_dir})
	}
	fuzzy_end(&f)
	p.list.more = len(src.narrow_idx) > len(src.entries)
	delete(src.narrow_q)
	src.narrow_q = strings.clone(query)
	src.narrow_builds = builds
}

walk_rel :: proc(path, root: string) -> string {
	if strings.has_prefix(path, root) {
		return strings.trim_left(path[len(root):], "/")
	}
	return path
}

list_walk_dir :: proc(editor: ^Editor, p: ^Pane, dir: string, depth: int) {
	src := &p.list.source
	w := src.walk
	infos, _ := os.read_directory_by_path(dir, -1, context.temp_allocator)
	Row :: struct {
		path:   string,
		is_dir: bool,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for info in infos {
		append(&rows, Row{info.fullpath, info.type == .Directory})
	}
	if s := src.wscope; s != nil && len(s.virtual) > 0 {
		prefix := strings.concatenate({dir, "/"}, context.temp_allocator)
		virtual: for d in s.virtual {
			if !strings.has_prefix(d, prefix) {
				continue
			}
			slash := strings.index_byte(d[len(prefix):], '/')
			child := d if slash < 0 else d[:len(prefix) + slash]
			for r in rows {
				if r.path == child {
					continue virtual
				}
			}
			append(&rows, Row{child, slash >= 0})
		}
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.is_dir != b.is_dir {
			return a.is_dir
		}
		return a.path < b.path
	})
	for r in rows {
		if s := src.wscope; s != nil && (!s.all || r.path in s.closure) {
			if !walk_scope_has(s, r.path) {
				continue
			}
		} else {
			if !w.dotfiles && strings.has_prefix(filepath.base(r.path), ".") {
				continue
			}
			if !w.ignored && filetree_is_ignored(&editor.filetree, r.path) {
				continue
			}
		}
		path := strings.clone(r.path)
		append(&src.entries, FileEntry{path, path[strings.last_index_byte(path, '/') + 1:], depth, r.is_dir})
		if r.is_dir && pane_tree_expanded(p, path) {
			list_walk_dir(editor, p, path, depth + 1)
		}
	}
}

list_walk_files :: proc(editor: ^Editor, p: ^Pane, sel: []int) -> []string {
	src := &p.list.source
	seen := make(map[string]bool, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, seen: ^map[string]bool, path: string) {
		if path not_in seen {
			seen[path] = true
			append(out, path)
		}
	}
	for i in sel {
		if i < 0 || i >= len(src.entries) {
			continue
		}
		e := src.entries[i]
		if !e.is_dir || src.wscope == nil || src.wscope.all {
			add(&out, &seen, e.path)
			continue
		}
		prefix := strings.concatenate({e.path, "/"}, context.temp_allocator)
		for path in src.wscope.listed {
			if strings.has_prefix(path, prefix) {
				add(&out, &seen, path)
			}
		}
		for path in src.wscope.virtual {
			if strings.has_prefix(path, prefix) {
				add(&out, &seen, path)
			}
		}
	}
	return out[:]
}

pane_tree_reveal :: proc(editor: ^Editor, p: ^Pane, path: string) {
	root := p.list.source.walk.root
	for q := filetree_parent_dir(path); strings.has_prefix(q, root); {
		pane_tree_set(p, q, true)
		np := filetree_parent_dir(q)
		if q == root || np == q {
			break
		}
		q = np
	}
	list_walk_fill(editor, p)
	for e, i in p.list.source.entries {
		if e.path == path {
			p.list.sel = i
			pane_scroll_fit(p, pane_geom(editor, p).list.h)
			return
		}
	}
}

pane_tree_enter :: proc(editor: ^Editor, p: ^Pane) -> bool {
	src := &p.list.source
	if src.kind != .Walk || p.list.anchor != nil || p.list.sel < 0 || p.list.sel >= len(src.entries) {
		return false
	}
	e := src.entries[p.list.sel]
	if !e.is_dir {
		return false
	}
	dir := strings.clone(e.path, context.temp_allocator)
	on := true
	if f := pane_filter(p); f != nil && len(f.text) > 0 {
		textfield_reset(&f.field)
		pane_tree_set(p, dir, true)
		pane_tree_reveal(editor, p, dir)
	} else {
		on = !pane_tree_expanded(p, dir)
		pane_tree_set(p, dir, on)
		list_walk_fill(editor, p)
	}
	if p.on.expand != nil {
		p.on.expand(editor, p, dir, on)
	}
	return true
}

pane_tree_mark_expanded :: proc(editor: ^Editor, p: ^Pane, dir: string) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	w := p.list.source.walk
	for info in infos {
		if info.type != .Directory || filetree_is_ignored(&editor.filetree, info.fullpath) {
			continue
		}
		if !w.dotfiles && strings.has_prefix(info.name, ".") {
			continue
		}
		pane_tree_set(p, info.fullpath, true)
		pane_tree_mark_expanded(editor, p, info.fullpath)
	}
}

// expanding the whole walk needs the ignore set, or it would descend into node_modules
pane_tree_expand_all :: proc(editor: ^Editor, p: ^Pane, on: bool) -> bool {
	src := &p.list.source
	if src.wscope != nil && !src.wscope.all {
		if on {
			drop := make([dynamic]string, context.temp_allocator)
			for key, val in p.list.expanded {
				if !val {
					append(&drop, key)
				}
			}
			for key in drop {
				delete_key(&p.list.expanded, key)
				delete(key)
			}
		} else {
			for e in src.entries {
				if e.is_dir {
					pane_tree_set(p, e.path, false)
				}
			}
		}
	} else if on {
		if !editor.filetree.scanned {
			return false
		}
		pane_tree_mark_expanded(editor, p, src.walk.root)
	} else {
		walk_set_clear(&p.list.expanded)
	}
	list_walk_fill(editor, p)
	return true
}

FsError :: enum {
	None,
	Exists,
	Missing,
	Failed,
}

fs_error_text :: proc(err: FsError, path: string) -> string {
	switch err {
	case .None:
	case .Exists:
		return "exists"
	case .Missing:
		return "not found"
	case .Failed:
		return fmt.tprintf("failed: %s", path)
	}
	return ""
}

fs_lexists :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK
}

// symlinks are copied as links, modes kept
fs_copy_tree :: proc(src, dst: string) -> bool {
	csrc := strings.clone_to_cstring(src, context.temp_allocator)
	cdst := strings.clone_to_cstring(dst, context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(csrc, &st) != .OK {
		return false
	}
	if posix.S_ISLNK(st.st_mode) {
		buf: [4096]u8
		n := posix.readlink(csrc, raw_data(buf[:]), len(buf) - 1)
		if n < 0 {
			return false
		}
		buf[n] = 0
		return posix.symlink(cstring(raw_data(buf[:])), cdst) == .OK
	}
	if posix.S_ISDIR(st.st_mode) {
		if posix.mkdir(cdst, {.IRUSR, .IWUSR, .IXUSR}) != .OK {
			return false
		}
		infos, err := os.read_directory_by_path(src, -1, context.temp_allocator)
		ok := err == nil
		for child in infos {
			if !ok {
				break
			}
			ok = fs_copy_tree(child.fullpath, fmt.tprintf("%s/%s", dst, child.name))
		}
		posix.chmod(cdst, st.st_mode)
		return ok
	}
	data, rerr := os.read_entire_file(src, context.temp_allocator)
	if rerr != nil || os.write_entire_file(dst, data) != nil {
		return false
	}
	posix.chmod(cdst, st.st_mode)
	return true
}

fs_copy :: proc(editor: ^Editor, src, dst: string) -> FsError {
	if !fs_lexists(src) {
		return .Missing
	}
	if fs_lexists(dst) {
		return .Exists
	}
	path_ensure_parent_dir(dst)
	ok := fs_copy_tree(src, dst)
	walk_invalidate(editor)
	return .None if ok else .Failed
}

fs_rename :: proc(editor: ^Editor, src, dst: string) -> FsError {
	if !fs_lexists(src) {
		return .Missing
	}
	if fs_lexists(dst) {
		return .Exists
	}
	path_ensure_parent_dir(dst)
	if os.rename(src, dst) != nil {
		// across filesystems
		if !fs_copy_tree(src, dst) {
			walk_invalidate(editor)
			return .Failed
		}
		fs_remove_tree(src)
	}
	buffers_repath(editor, src, dst)
	walk_invalidate(editor)
	return .None
}

fs_remove_tree :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK {
		return false
	}
	if !posix.S_ISDIR(st.st_mode) {
		return posix.unlink(cpath) == .OK
	}
	infos, _ := os.read_directory_by_path(path, -1, context.temp_allocator)
	for child in infos {
		fs_remove_tree(child.fullpath)
	}
	return posix.rmdir(cpath) == .OK
}

fs_remove :: proc(editor: ^Editor, path: string) -> FsError {
	if !fs_lexists(path) {
		return .Missing
	}
	ok := fs_remove_tree(path)
	walk_invalidate(editor)
	return .None if ok else .Failed
}

fs_mkdir :: proc(editor: ^Editor, path: string) -> FsError {
	if fs_lexists(path) {
		return .Exists
	}
	if os.make_directory_all(path, os.perm(0o755)) != nil {
		return .Failed
	}
	walk_invalidate(editor)
	return .None
}

buffers_repath :: proc(editor: ^Editor, old, new: string) {
	prefix := strings.concatenate({old, "/"}, context.temp_allocator)
	for &b in editor.buffers {
		if b.path == "" {
			continue
		}
		np: string
		if b.path == old {
			np = strings.clone(new, context.temp_allocator)
		} else if strings.has_prefix(b.path, prefix) {
			np = strings.concatenate({new, b.path[len(old):]}, context.temp_allocator)
		} else {
			continue
		}
		if b.lsp_open {
			lsp_did_close(editor, &b)
		}
		delete(b.path)
		b.path = strings.clone(np)
		lang := language_of(np)
		if lang != b.language {
			b.language = lang
			highlight_destroy(&b.hl)
			b.hl = {}
		}
		diffbase_invalidate(&b)
	}
}

FileTreeMode :: enum {
	Nav,
	New,
	Rename,
}

FileTreeScope :: enum {
	All,
	Open,
	Changed,
	Unsaved,
}

FileTreeTab :: struct {
	label, cmd: string,
	scope:      FileTreeScope,
}

filetree_tabs := [?]FileTreeTab {
	{"All", "File Tree", .All},
	{"Open", "File Tree: Open", .Open},
	{"Changed", "File Tree: Changed", .Changed},
	{"Unsaved", "File Tree: Unsaved", .Unsaved},
}

FileTreeSize :: struct {
	added, removed: int,
}

FileTreeBaseState :: enum {
	None,
	Wanted,
	Text,
	Missing,
}

FileTreeProvider :: struct {
	owner:       string,
	refresh_ref: i32,
	preview_ref: i32,
	open_ref:    i32,
	base_path:   string,
	base_text:   string,
	base_state:  FileTreeBaseState,
}

FileTree :: struct {
	clipboard:     [dynamic]string,
	clip_cut:      bool,
	mode:          FileTreeMode,
	status:        map[string]DiffMark,
	ignored:       map[string]bool,
	diffsize:      map[string]FileTreeSize,
	renames:       map[string]string,
	deleted:       [dynamic]string,
	changed:       [dynamic]string,
	show_dotfiles: bool,
	show_ignored:  bool,
	diff_only:     bool,
	scope:         FileTreeScope,
	provider:      FileTreeProvider,
	scanned:       bool,
}

filetree_tab_visible :: proc(t: ^FileTree, scope: FileTreeScope) -> bool {
	return scope != .Changed || t.provider.owner != ""
}

filetree_pane :: proc(editor: ^Editor) -> ^Pane {
	p := pane_find(editor, "filetree")
	if p == nil || !pane_live(editor, p) {
		return nil
	}
	return p
}

filetree_active :: proc(editor: ^Editor) -> bool {
	return filetree_pane(editor) != nil
}

filetree_destroy :: proc(t: ^FileTree) {
	filetree_clear_status(t)
	delete(t.status)
	delete(t.ignored)
	delete(t.diffsize)
	delete(t.renames)
	delete(t.deleted)
	delete(t.changed)
	filetree_clip_clear(t)
	delete(t.clipboard)
	filetree_base_reset(t)
}

filetree_root_reset :: proc(editor: ^Editor) {
	t := &editor.filetree
	if s := pane_saved_find(editor, "filetree"); s != nil {
		delete(s.key)
		s.key = ""
		walk_set_clear(&s.expanded)
	}
	filetree_clear_status(t)
	filetree_base_reset(t)
	t.scanned = t.provider.owner == ""
	t.mode = .Nav
	walk_invalidate(editor)
	filetree_status_request(editor)
	p := filetree_pane(editor)
	if p == nil {
		return
	}
	walk_set_clear(&p.list.expanded)
	p.list.sel, p.list.scroll = 0, 0
	p.footer_input = false
	if f := pane_filter(p); f != nil {
		textfield_reset(&f.field)
	}
	filetree_source_sync(editor, p)
}

filetree_clear_status :: proc(t: ^FileTree) {
	for key in t.status {
		delete(key)
	}
	clear(&t.status)
	for key in t.ignored {
		delete(key)
	}
	clear(&t.ignored)
	for key in t.diffsize {
		delete(key)
	}
	clear(&t.diffsize)
	for key, old in t.renames {
		delete(key)
		delete(old)
	}
	clear(&t.renames)
	clear(&t.deleted)
	for p in t.changed {
		delete(p)
	}
	clear(&t.changed)
}

filetree_status_request :: proc(editor: ^Editor) {
	p := &editor.plugins
	owner := editor.filetree.provider.owner
	ref := editor.filetree.provider.refresh_ref
	if owner == "" || ref == 0 {
		return
	}
	for q in p.queue {
		if q.ref == ref {
			return
		}
	}
	plugin_queue(editor, {ref = ref, only = owner})
}

filetree_provider_live :: proc(editor: ^Editor, owner: string, ref: i32) -> bool {
	pv := &editor.filetree.provider
	return pv.owner == owner && (ref == pv.refresh_ref || ref == pv.preview_ref || ref == pv.open_ref)
}

filetree_provider_unref :: proc(editor: ^Editor, pv: ^FileTreeProvider) {
	L := editor.plugins.L
	for ref in ([3]i32{pv.refresh_ref, pv.preview_ref, pv.open_ref}) {
		if ref != 0 && L != nil {
			lua.L_unref(L, lua.REGISTRYINDEX, c.int(ref))
		}
	}
	pv.refresh_ref, pv.preview_ref, pv.open_ref = 0, 0, 0
}

filetree_base_reset :: proc(t: ^FileTree) {
	delete(t.provider.base_path)
	delete(t.provider.base_text)
	t.provider.base_path = ""
	t.provider.base_text = ""
	t.provider.base_state = .None
}

filetree_status_pushed :: proc(editor: ^Editor) {
	t := &editor.filetree
	delete(t.provider.base_text)
	t.provider.base_text = ""
	t.provider.base_state = .None
	for path, mark in t.status {
		if mark == .Deleted {
			append(&t.deleted, path)
		}
	}
	t.scanned = true
	walk_invalidate(editor)
	editor_log(editor, .Debug, "Files", fmt.tprintf("file tree status: %d path(s) from %s", len(t.status), t.provider.owner))
	if p := filetree_pane(editor); p != nil {
		filetree_source_sync(editor, p)
		filetree_preview_touch(p)
		walk_prewarm(editor, p.list.source.walk)
	}
}

filetree_provider_clear :: proc(editor: ^Editor) {
	t := &editor.filetree
	filetree_provider_unref(editor, &t.provider)
	filetree_base_reset(t)
	t.provider = {}
	filetree_clear_status(t)
	t.scanned = true
	walk_invalidate(editor)
	if t.scope == .Changed {
		t.scope = .All
	}
	if p := filetree_pane(editor); p != nil {
		filetree_source_sync(editor, p)
	}
}

filetree_provider_unload :: proc(editor: ^Editor, owner: string) {
	if editor.filetree.provider.owner == owner && owner != "" {
		filetree_provider_clear(editor)
	}
}

filetree_provider_set :: proc(editor: ^Editor) {
	if p := filetree_pane(editor); p != nil {
		filetree_source_sync(editor, p)
	}
}

filetree_base_set :: proc(editor: ^Editor, path: string, text: Maybe(string)) {
	t := &editor.filetree
	pv := &t.provider
	if pv.base_state != .Wanted || pv.base_path != path {
		return
	}
	if s, ok := text.?; ok {
		pv.base_text = strings.clone(s)
		pv.base_state = .Text
	} else {
		pv.base_state = .Missing
	}
	if p := filetree_pane(editor); p != nil {
		pane_preview_load(editor, p)
	}
}

filetree_entry_deleted :: proc(t: ^FileTree, path: string, is_dir: bool) -> bool {
	return !is_dir && t.status[path] == .Deleted && !os.exists(path)
}

filetree_is_ignored :: proc(t: ^FileTree, path: string) -> bool {
	for p := path; true; {
		if t.ignored[p] {
			return true
		}
		np := filetree_parent_dir(p)
		if np == p {
			return false
		}
		p = np
	}
	return false
}

filetree_status_add :: proc(t: ^FileTree, root, path: string, mark: DiffMark) {
	filetree_status_set(t, path, mark)
	append(&t.changed, strings.clone(path))
	up := DiffMark.Modified if mark == .Deleted else mark
	under := strings.concatenate({root, "/"}, context.temp_allocator)
	p := path
	for strings.has_prefix(p, under) {
		np := filetree_parent_dir(p)
		if np == p {
			break
		}
		p = np
		// an ancestor already at this mark had it propagated above it too
		if filetree_status_set(t, p, up) {
			break
		}
	}
}

filetree_status_set :: proc(t: ^FileTree, path: string, mark: DiffMark) -> (had: bool) {
	if existing, ok := t.status[path]; ok {
		if int(mark) > int(existing) {
			t.status[path] = mark
			return false
		}
		return true
	}
	t.status[strings.clone(path)] = mark
	return false
}

filetree_parent_dir :: proc(path: string) -> string {
	if idx := strings.last_index_byte(path, '/'); idx > 0 {
		return path[:idx]
	}
	return path
}

filetree_scope_paths :: proc(editor: ^Editor, scope: FileTreeScope) -> (within, virtual: []string) {
	t := &editor.filetree
	out := make([dynamic]string, context.temp_allocator)
	switch scope {
	case .All:
	case .Changed:
		return t.changed[:], t.deleted[:]
	case .Open, .Unsaved:
		for &b in editor.buffers {
			if b.path != "" && (scope == .Open || b.modified) && os.exists(b.path) {
				append(&out, b.path)
			}
		}
	}
	return out[:], nil
}

filetree_visible_scopes :: proc(t: ^FileTree) -> []FileTreeScope {
	out := make([dynamic]FileTreeScope, context.temp_allocator)
	for tab in filetree_tabs {
		if filetree_tab_visible(t, tab.scope) {
			append(&out, tab.scope)
		}
	}
	return out[:]
}

filetree_source_sync :: proc(editor: ^Editor, p: ^Pane) {
	t := &editor.filetree
	if !filetree_tab_visible(t, t.scope) {
		t.scope = .All
	}
	src := &p.list.source
	w := walk_acquire(editor, editor.working_root, t.show_dotfiles, t.show_ignored)
	walk_release(src.walk)
	src.walk = w
	walk_scope_release(src.wscope)
	src.wscope = nil
	if within, virtual := filetree_scope_paths(editor, t.scope); t.scope != .All {
		src.wscope = walk_scope_new(w.root, nil, within, virtual)
	}
	walk_narrow_reset(src)
	scopes := filetree_visible_scopes(t)
	tabs := make([]PaneTab, len(scopes), context.temp_allocator)
	for s, i in scopes {
		tabs[i] = {label = filetree_tabs[s].label, cmd = filetree_tabs[s].cmd}
		if s == t.scope {
			p.tab = i
		}
	}
	pane_tabs_set(p, tabs)
	chips := make([dynamic]PaneChip, context.temp_allocator)
	#partial switch t.scope {
	case .All:
		append(&chips, PaneChip{label = "ignored", cmd = "File Tree: Toggle Ignored", on = t.show_ignored})
		append(&chips, PaneChip{label = "dotfiles", cmd = "File Tree: Toggle Dotfiles", on = t.show_dotfiles})
	case .Changed:
		append(&chips, PaneChip{label = "diff", cmd = "File Tree: Toggle Diff", on = t.diff_only})
	}
	pane_chips_set(p, chips[:])
	filetree_marks_sync(editor, p)
	list_walk_fill(editor, p)
	filetree_preview_touch(p)
}

filetree_marks_sync :: proc(editor: ^Editor, p: ^Pane) {
	t := &editor.filetree
	pane_marks_clear(p)
	changed := t.scope == .Changed
	root := editor.working_root
	for path, mark in t.status {
		m: PaneMark
		switch mark {
		case .None:
		case .Added:
			m.bar = "git_added"
		case .Modified:
			m.bar = "git_modified"
		case .Deleted:
			m.bar = "git_deleted"
			if !os.exists(path) {
				m.fg = "git_deleted"
			}
		}
		if changed {
			if old, ok := t.renames[path]; ok {
				rel, _ := filepath.rel(root, old, context.temp_allocator)
				m.suffix = fmt.tprintf("%s %s", ICON_TREE_RENAMED, rel)
			}
			if size, ok := t.diffsize[path]; ok {
				m.added, m.removed, m.sizes = size.added, size.removed, true
			}
		}
		pane_mark_set(p, path, m)
	}
	for path in t.ignored {
		m := p.marks[path] or_else PaneMark{}
		m.dim = true
		pane_mark_set(p, path, m)
	}
}

filetree_preview_touch :: proc(p: ^Pane) {
	delete(p.preview_key)
	p.preview_key = ""
}

filetree_preview :: proc(editor: ^Editor, p: ^Pane, it: PaneItem) -> bool {
	t := &editor.filetree
	if t.scope != .Changed || t.provider.owner == "" || it.path == "" || it.dir {
		return false
	}
	pv := &t.provider
	h := pane_geom(editor, p).preview.h
	// a status push re-asks for the same path; its old rows stay up until the answer
	keep := pv.base_path == it.path && pv.base_state == .None
	if pv.base_path != it.path || pv.base_state == .None {
		filetree_base_reset(t)
		pv.base_path = strings.clone(it.path)
		if pv.preview_ref != 0 {
			pv.base_state = .Wanted
			plugin_queue(editor, {ref = pv.preview_ref, a = it.path, only = pv.owner})
		} else {
			pv.base_state = .Missing
		}
	}
	switch pv.base_state {
	case .Wanted:
		if !keep {
			preview_reset(&p.preview)
		}
		return true
	case .Text:
		preview_set_diff(&p.preview, it.path, h, t.diff_only, pv.base_text)
		return true
	case .Missing, .None:
	}
	return false
}

filetree_open_scope :: proc(editor: ^Editor, scope: FileTreeScope) {
	t := &editor.filetree
	if !filetree_tab_visible(t, scope) {
		return
	}
	t.scope = scope
	t.mode = .Nav
	editor_clear_message(editor)
	walk_invalidate(editor)
	hints := []PaneHint{{label = "←→ tabs"}, {label = "↑↓ select"}, {label = "Shift+↑↓ extend"}, {label = "commands", cmd = "Command Palette"}}
	spec := Pane {
		id = "filetree",
		place = .Split,
		size = .Tree,
		scope = "filetree",
		keep = true,
		auto_preview = true,
		fields = []PaneField{{mode = .Filter, count = true, hint = "type to filter", esc_clears = true}},
		has_list = true,
		list = {multi = true, tree = true, max = FILETREE_FILTER_MAX_RESULTS, source = {kind = .Walk}},
		footer = hints,
		on = {activate = filetree_activate, tab = filetree_tab_changed, submit = filetree_submit, preview = filetree_preview, close = filetree_closed},
	}
	p := pane_open(editor, spec)
	if p == nil {
		return
	}
	if s := pane_saved_find(editor, "filetree"); s != nil {
		for key, on in s.expanded {
			pane_tree_set(p, key, on)
		}
		if s.key != "" {
			p.list.restore = strings.clone(s.key)
		}
	}
	filetree_source_sync(editor, p)
	pane_restore(editor, p, pane_geom(editor, p).list.h)
	delete(p.list.restore)
	p.list.restore = ""
	filetree_status_request(editor)
	walk_prewarm(editor, p.list.source.walk)
}

filetree_open_all :: proc(editor: ^Editor) {filetree_open_scope(editor, .All)}
filetree_open_open :: proc(editor: ^Editor) {filetree_open_scope(editor, .Open)}
filetree_open_changed :: proc(editor: ^Editor) {filetree_open_scope(editor, .Changed)}
filetree_open_unsaved :: proc(editor: ^Editor) {filetree_open_scope(editor, .Unsaved)}

filetree_closed :: proc(editor: ^Editor, p: ^Pane) {
	editor.filetree.mode = .Nav
	pane_save(editor, p)
}

filetree_close :: proc(editor: ^Editor) {
	if p := filetree_pane(editor); p != nil {
		pane_end(editor, p.handle, false)
	}
}

filetree_tab_changed :: proc(editor: ^Editor, p: ^Pane) {
	scopes := filetree_visible_scopes(&editor.filetree)
	if p.tab < 0 || p.tab >= len(scopes) {
		return
	}
	editor.filetree.scope = scopes[p.tab]
	filetree_source_sync(editor, p)
	if editor.filetree.scope == .All {
		walk_prewarm(editor, p.list.source.walk)
	}
}

filetree_toggle_dotfiles :: proc(editor: ^Editor) {
	editor.filetree.show_dotfiles = !editor.filetree.show_dotfiles
	filetree_toggled(editor)
}

filetree_toggle_ignored :: proc(editor: ^Editor) {
	editor.filetree.show_ignored = !editor.filetree.show_ignored
	filetree_toggled(editor)
}

filetree_toggled :: proc(editor: ^Editor) {
	if p := filetree_pane(editor); p != nil {
		filetree_source_sync(editor, p)
		walk_prewarm(editor, p.list.source.walk)
	}
}

filetree_toggle_diff :: proc(editor: ^Editor) {
	editor.filetree.diff_only = !editor.filetree.diff_only
	if p := filetree_pane(editor); p != nil {
		for &c in p.chips {
			c.on = editor.filetree.diff_only
		}
		pane_preview_load(editor, p)
	}
}

filetree_toggle_expand_all :: proc(editor: ^Editor) {
	p := filetree_pane(editor)
	if p == nil {
		return
	}
	any := false
	for e in p.list.source.entries {
		if e.is_dir && pane_tree_expanded(p, e.path) {
			any = true
			break
		}
	}
	if !pane_tree_expand_all(editor, p, !any) {
		editor_log(editor, .Info, "Files", "File status is still loading")
	}
}

filetree_sel :: proc(editor: ^Editor) -> (p: ^Pane, entries: []FileEntry) {
	p = filetree_pane(editor)
	if p == nil || len(p.list.source.entries) == 0 {
		return nil, nil
	}
	n := len(p.list.source.entries)
	lo, hi := p.list.sel, p.list.sel
	if a, ok := p.list.anchor.?; ok {
		lo, hi = min(a, p.list.sel), max(a, p.list.sel)
	}
	lo, hi = clamp(lo, 0, n - 1), clamp(hi, 0, n - 1)
	return p, p.list.source.entries[lo:hi + 1]
}

filetree_sel_gone :: proc(editor: ^Editor) -> bool {
	_, sel := filetree_sel(editor)
	for e in sel {
		if !os.exists(e.path) {
			editor_log(editor, .Info, "Files", "Deleted file: restore it first")
			return true
		}
	}
	return false
}

filetree_activate :: proc(editor: ^Editor, p: ^Pane) {
	t := &editor.filetree
	_, sel := filetree_sel(editor)
	if len(sel) > 1 {
		paths := make([dynamic]string, context.temp_allocator)
		for e in sel {
			if !e.is_dir && !filetree_entry_deleted(t, e.path, false) {
				append(&paths, strings.clone(e.path, context.temp_allocator))
			}
		}
		if len(paths) == 0 {
			return
		}
		filetree_close(editor)
		opened := 0
		for path in paths {
			if editor_open_path(editor, path) {
				opened += 1
			}
		}
		if opened > 0 {
			editor_scroll(editor)
		}
		return
	}
	if len(sel) == 0 || sel[0].is_dir {
		return
	}
	if filetree_entry_deleted(t, sel[0].path, false) {
		if t.provider.open_ref != 0 {
			plugin_task_start(editor, t.provider.owner, .Command, {ref = t.provider.open_ref, args = .Ctx, user = true})
		} else {
			editor_log(editor, .Info, "Files", "Deleted file")
		}
		return
	}
	path := strings.clone(sel[0].path, context.temp_allocator)
	filetree_close(editor)
	if editor_open_path(editor, path) {
		editor_scroll(editor)
	}
}

filetree_cursor :: proc(editor: ^Editor) -> (FileEntry, bool) {
	p := filetree_pane(editor)
	if p == nil || len(p.list.source.entries) == 0 {
		return {}, false
	}
	return p.list.source.entries[clamp(p.list.sel, 0, len(p.list.source.entries) - 1)], true
}

filetree_target_dir :: proc(editor: ^Editor) -> string {
	e, ok := filetree_cursor(editor)
	if !ok {
		return editor.working_root
	}
	return e.path if e.is_dir else filetree_parent_dir(e.path)
}

filetree_reveal :: proc(editor: ^Editor, path: string) {
	filetree_status_request(editor)
	if p := filetree_pane(editor); p != nil {
		walk_invalidate(editor)
		pane_tree_reveal(editor, p, path)
	}
}

filetree_refresh :: proc(editor: ^Editor) {
	filetree_status_request(editor)
	if p := filetree_pane(editor); p != nil {
		walk_invalidate(editor)
		list_walk_fill(editor, p)
	}
}

filetree_prompt_begin :: proc(editor: ^Editor, mode: FileTreeMode) {
	p := filetree_pane(editor)
	if p == nil {
		return
	}
	editor.filetree.mode = mode
	if mode == .Rename {
		e, _ := filetree_cursor(editor)
		pane_footer_input(p, "Rename: ", filepath.base(e.path) if e.path != "" else "")
	} else {
		pane_footer_input(p, "New: ", "")
	}
	editor_clear_message(editor)
}

filetree_submit :: proc(editor: ^Editor, p: ^Pane, text: string, ok: bool) {
	t := &editor.filetree
	name := strings.trim_space(text)
	mode := t.mode
	t.mode = .Nav
	if mode == .Nav || !ok {
		return
	}
	if name == "" {
		editor_log(editor, .Error, "Files", "Empty name")
		return
	}
	switch mode {
	case .Nav:
	case .New:
		is_dir := strings.has_suffix(name, "/")
		clean := strings.trim_right(name, "/")
		if clean == "" {
			editor_log(editor, .Error, "Files", "Empty name")
			return
		}
		full, _ := filepath.join({filetree_target_dir(editor), clean}, context.temp_allocator)
		if os.exists(full) {
			editor_log(editor, .Error, "Files", "Already exists")
			return
		}
		if is_dir {
			if fs_mkdir(editor, full) != .None {
				editor_log(editor, .Error, "Files", "Create failed")
				return
			}
		} else {
			path_ensure_parent_dir(full)
			f, err := os.open(full, {.Write, .Create, .Excl}, os.perm(0o644))
			if err != nil {
				editor_log(editor, .Error, "Files", "Create failed")
				return
			}
			os.close(f)
		}
		filetree_reveal(editor, full)
	case .Rename:
		e, ok := filetree_cursor(editor)
		if !ok {
			return
		}
		full, _ := filepath.join({filetree_parent_dir(e.path), name}, context.temp_allocator)
		old := strings.clone(e.path, context.temp_allocator)
		if full == old {
			return
		}
		switch fs_rename(editor, old, full) {
		case .None:
		case .Exists:
			editor_log(editor, .Error, "Files", "Already exists")
			return
		case .Missing, .Failed:
			editor_log(editor, .Error, "Files", "Rename failed")
			return
		}
		filetree_reveal(editor, full)
	}
}

filetree_clip_clear :: proc(t: ^FileTree) {
	for p in t.clipboard {
		delete(p)
	}
	clear(&t.clipboard)
}

filetree_clip_capture :: proc(editor: ^Editor, cut: bool) {
	t := &editor.filetree
	_, sel := filetree_sel(editor)
	if len(sel) == 0 {
		return
	}
	filetree_clip_clear(t)
	for e in sel {
		append(&t.clipboard, strings.clone(e.path))
	}
	t.clip_cut = cut
	verb := "Cut" if cut else "Copied"
	if len(t.clipboard) == 1 {
		editor_log(editor, .Info, "Files", fmt.tprintf("%s %s", verb, filepath.base(t.clipboard[0])))
	} else {
		editor_log(editor, .Info, "Files", fmt.tprintf("%s %d items", verb, len(t.clipboard)))
	}
}

filetree_dest_path :: proc(dir, name: string) -> string {
	full, _ := filepath.join({dir, name}, context.temp_allocator)
	if !fs_lexists(full) {
		return full
	}
	stem, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem, ext = name[:dot], name[dot:]
	}
	for i in 1 ..< 1000 {
		cand := fmt.tprintf("%s (copy)%s", stem, ext) if i == 1 else fmt.tprintf("%s (copy %d)%s", stem, i, ext)
		full, _ = filepath.join({dir, cand}, context.temp_allocator)
		if !fs_lexists(full) {
			return full
		}
	}
	return full
}

filetree_clip_paste :: proc(editor: ^Editor) {
	t := &editor.filetree
	if len(t.clipboard) == 0 {
		editor_log(editor, .Info, "Files", "Nothing to paste")
		return
	}
	dst_dir := filetree_target_dir(editor)
	if !os.is_dir(dst_dir) {
		editor_log(editor, .Info, "Files", "Deleted directory: restore a file in it first")
		return
	}
	cut := t.clip_cut
	done := 0
	last := ""
	for src in t.clipboard {
		if !fs_lexists(src) {
			continue
		}
		dest := filetree_dest_path(dst_dir, filepath.base(src))
		if (fs_rename(editor, src, dest) if cut else fs_copy(editor, src, dest)) != .None {
			editor_log(editor, .Error, "Files", "Paste failed")
			continue
		}
		done += 1
		last = strings.clone(dest, context.temp_allocator)
	}
	if cut {
		filetree_clip_clear(t)
	}
	if last != "" {
		filetree_reveal(editor, last)
	} else {
		filetree_refresh(editor)
	}
	verb := "Moved" if cut else "Pasted"
	if done == 1 {
		editor_log(editor, .Info, "Files", fmt.tprintf("%s %s", verb, filepath.base(last)))
	} else if done > 1 {
		editor_log(editor, .Info, "Files", fmt.tprintf("%s %d items", verb, done))
	}
}

filetree_delete_actions := [?]string{"Cancel", "Delete"}

filetree_delete_question :: proc(editor: ^Editor) -> string {
	_, sel := filetree_sel(editor)
	if len(sel) > 1 {
		return fmt.tprintf("Delete %d items?", len(sel))
	}
	if len(sel) == 0 {
		return "Delete?"
	}
	if sel[0].is_dir {
		return fmt.tprintf("Delete %s/ and its contents?", filepath.base(sel[0].path))
	}
	return fmt.tprintf("Delete %s?", filepath.base(sel[0].path))
}

filetree_delete_execute :: proc(editor: ^Editor, d: ^Pane) {
	if d.list.sel != 1 {
		return
	}
	p, sel := filetree_sel(editor)
	if p == nil {
		return
	}
	lo := min(p.list.sel, p.list.anchor.? or_else p.list.sel)
	paths := make([dynamic]string, context.temp_allocator)
	for e in sel {
		append(&paths, strings.clone(e.path, context.temp_allocator))
	}
	failed := 0
	for path in paths {
		if fs_remove(editor, path) != .None {
			failed += 1
		}
	}
	p.list.sel, p.list.anchor = max(0, lo - 1), nil
	delete(p.list.restore)
	p.list.restore = ""
	filetree_refresh(editor)
	deleted := len(paths) - failed
	if failed > 0 {
		editor_log(editor, .Error, "Files", fmt.tprintf("Deleted %d, %d failed", deleted, failed))
	} else if deleted == 1 {
		editor_log(editor, .Info, "Files", "Deleted")
	} else {
		editor_log(editor, .Info, "Files", fmt.tprintf("Deleted %d items", deleted))
	}
}

filetree_close_actions := [?]string{"Cancel", "Close all"}

filetree_close_targets :: proc(editor: ^Editor) -> (total, unsaved: int) {
	_, sel := filetree_sel(editor)
	for e in sel {
		if idx := editor_find_buffer(editor, e.path); idx >= 0 {
			total += 1
			if editor.buffers[idx].modified {
				unsaved += 1
			}
		}
	}
	return
}

filetree_close_commit :: proc(editor: ^Editor) {
	p, sel := filetree_sel(editor)
	if p == nil {
		return
	}
	paths := make([dynamic]string, context.temp_allocator)
	for e in sel {
		if editor_find_buffer(editor, e.path) >= 0 {
			append(&paths, strings.clone(e.path, context.temp_allocator))
		}
	}
	closed := 0
	for path in paths {
		if idx := editor_find_buffer(editor, path); idx >= 0 {
			editor_close_index(editor, idx)
			closed += 1
		}
	}
	if p = filetree_pane(editor); p != nil {
		filetree_source_sync(editor, p)
	}
	if closed == 1 {
		editor_log(editor, .Info, "Files", "Closed buffer")
	} else if closed > 1 {
		editor_log(editor, .Info, "Files", fmt.tprintf("Closed %d buffers", closed))
	}
}

filetree_close_execute :: proc(editor: ^Editor, d: ^Pane) {
	if d.list.sel == 1 {
		filetree_close_commit(editor)
	}
}

filetree_confirm :: proc(editor: ^Editor, id, question: string, actions: []string, execute: PaneHandler) {
	p := filetree_pane(editor)
	if p == nil {
		return
	}
	spec := dialog_pane(question, actions, 0)
	spec.id, spec.kind, spec.parent = id, .Child, p.handle
	spec.on.activate = execute
	pane_open(editor, spec)
}

filetree_select_all :: proc(editor: ^Editor) {
	p := filetree_pane(editor)
	if p == nil || len(p.list.source.entries) == 0 {
		return
	}
	p.list.anchor = 0
	p.list.sel = len(p.list.source.entries) - 1
	pane_scroll_fit(p, pane_geom(editor, p).list.h)
}

filetree_cmd_copy :: proc(editor: ^Editor) {
	if !filetree_sel_gone(editor) {
		filetree_clip_capture(editor, false)
	}
}

filetree_cmd_cut :: proc(editor: ^Editor) {
	if !filetree_sel_gone(editor) {
		filetree_clip_capture(editor, true)
	}
}

filetree_cmd_rename :: proc(editor: ^Editor) {
	if !filetree_sel_gone(editor) {
		filetree_prompt_begin(editor, .Rename)
	}
}

filetree_cmd_new :: proc(editor: ^Editor) {filetree_prompt_begin(editor, .New)}

filetree_cmd_delete :: proc(editor: ^Editor) {
	if filetree_sel_gone(editor) {
		return
	}
	if _, sel := filetree_sel(editor); len(sel) > 0 {
		filetree_confirm(editor, "filetree_delete", filetree_delete_question(editor), filetree_delete_actions[:], filetree_delete_execute)
	}
}

filetree_cmd_close :: proc(editor: ^Editor) {
	total, unsaved := filetree_close_targets(editor)
	if total == 0 {
		editor_log(editor, .Info, "Files", "No open buffers in selection")
		return
	}
	if unsaved == 0 {
		filetree_close_commit(editor)
		return
	}
	filetree_confirm(editor, "filetree_close", close_question(total, unsaved), filetree_close_actions[:], filetree_close_execute)
}
