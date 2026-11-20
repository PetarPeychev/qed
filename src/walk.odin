package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

WALK_FILTER_DEBOUNCE_MS :: 100
WALK_PREVIEW_DEBOUNCE_MS :: 80
WALK_FILTER_MAX_RESULTS :: 500
WALK_THREADS :: 0
WALK_PREWARM :: true

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
	ignore:            map[string]bool,
	ignore_ready:      bool,
	cands:             [dynamic]FileEntry,
	built, stale:      bool,
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
	seen:    u64,
	builds:  u64,
}

walk_entries_free :: proc(entries: ^[dynamic]FileEntry) {
	for e in entries {
		delete(e.path)
	}
	clear(entries)
}

walk_admit :: proc(a: ^WalkAdmit, name, p: string) -> bool {
	if a.scope != nil {
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
		n = WALK_THREADS
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
	w.ignore_ready = true
	for o in editor.walks {
		if o.root == root {
			walk_set_copy(&w.ignore, o.ignore)
			w.ignore_ready = o.ignore_ready
			break
		}
	}
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
	walk_set_clear(&w.ignore)
	delete(w.ignore)
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

walk_valid :: proc(w: ^Walk) -> bool {
	return w.built && !w.stale
}

walk_stale :: proc(w: ^Walk) {
	w.stale = true
	w.gen += 1
}

walk_invalidate :: proc(editor: ^Editor, path: string) {
	for w in editor.walks {
		if path == w.root || path_under(path, w.root) || path_under(w.root, path) {
			walk_stale(w)
			if w.refs > 0 {
				walk_prewarm(editor, w)
			}
		}
	}
}

walk_set_copy :: proc(dst: ^map[string]bool, src: map[string]bool) {
	walk_set_clear(dst)
	for key in src {
		dst^[strings.clone(key)] = true
	}
}

walk_ignore_set :: proc(editor: ^Editor, root: string, paths: map[string]bool, ready: bool) {
	for w in editor.walks {
		if w.root != root {
			continue
		}
		same := len(w.ignore) == len(paths)
		for key in paths {
			if !same {
				break
			}
			same = key in w.ignore
		}
		w.ignore_ready = ready
		if !same {
			walk_set_copy(&w.ignore, paths)
			if !w.ignored {
				walk_stale(w)
			}
		}
	}
}

walk_ignored :: proc(w: ^Walk, path: string) -> bool {
	if w.ignored || len(w.ignore) == 0 {
		return false
	}
	for p := path; true; {
		if w.ignore[p] {
			return true
		}
		np := path_parent(p)
		if np == p {
			return false
		}
		p = np
	}
	return false
}

walk_can_prewarm :: proc(w: ^Walk) -> bool {
	return WALK_PREWARM && (w.ignore_ready || w.ignored)
}

// a stale walk keeps serving its old candidates while the prewarm reruns it; only a first walk blocks
walk_cands :: proc(editor: ^Editor, w: ^Walk) -> []FileEntry {
	w.walk_ms = 0
	if walk_valid(w) {
		return w.cands[:]
	}
	if w.built && walk_can_prewarm(w) {
		walk_prewarm(editor, w)
		return w.cands[:]
	}
	if w.pw.active {
		if walk_prewarm_finish(editor, w) && walk_valid(w) {
			return w.cands[:]
		}
		w.pw.restart = false
	}
	walk_entries_free(&w.cands)
	at := time.tick_now()
	admit := WalkAdmit{dotfiles = w.dotfiles, ignored = w.ignored, ignore = &w.ignore}
	walk_run(&admit, w.root, &w.cands)
	w.walk_ms = time.duration_milliseconds(time.tick_since(at))
	w.built, w.stale = true, false
	w.builds += 1
	return w.cands[:]
}

walk_refresh :: proc(editor: ^Editor, w: ^Walk) {
	walk_stale(w)
	walk_prewarm(editor, w)
}

walk_prewarm :: proc(editor: ^Editor, w: ^Walk) {
	pw := &w.pw
	if !walk_can_prewarm(w) || walk_valid(w) {
		return
	}
	if pw.active {
		pw.restart = pw.restart || pw.gen != w.gen
		return
	}
	walk_set_copy(&pw.ignore, w.ignore)
	pw.admit = {dotfiles = w.dotfiles, ignored = w.ignored, ignore = &pw.ignore}
	pw.root = strings.clone(w.root)
	pw.heap = context.allocator
	pw.gen = w.gen
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
	walk_set_clear(&pw.ignore)
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

// adopting a new candidate set bumps the stamp, so open lists refill from it
walk_prewarm_finish :: proc(editor: ^Editor, w: ^Walk) -> bool {
	pw := &w.pw
	walk_prewarm_join(pw)
	if pw.gen != w.gen {
		walk_prewarm_release(pw)
		return false
	}
	walk_entries_free(&w.cands)
	delete(w.cands)
	w.cands = pw.staging
	pw.staging = {}
	w.built, w.stale = true, false
	w.builds += 1
	w.gen += 1
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
		landed = walk_prewarm_finish(editor, w) || landed
		if (w.pw.restart || !walk_valid(w)) && w.refs > 0 {
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
		walk_set_copy(&s.listed, base.listed)
		walk_set_copy(&s.closure, base.closure)
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
		np := path_parent(p)
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
		np := path_parent(q)
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
	if s.all {
		base := walk_cands(editor, w)
		if s.valid && s.seen == w.gen {
			return s.cands[:]
		}
		walk_entries_free(&s.cands)
		for e in base {
			append(&s.cands, FileEntry{strings.clone(e.path), "", 0, e.is_dir})
		}
	} else {
		w.walk_ms = 0
		if s.valid && s.seen == w.gen {
			return s.cands[:]
		}
		walk_entries_free(&s.cands)
		at := time.tick_now()
		admit := WalkAdmit {
			scope = s,
		}
		walk_run(&admit, w.root, &s.cands)
		w.walk_ms = time.duration_milliseconds(time.tick_since(at))
	}
	under := strings.concatenate({w.root, "/"}, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for d in s.virtual {
		for p := d; strings.has_prefix(p, under) && !(p in seen) && !os.exists(p); p = path_parent(p) {
			seen[p] = true
			append(&s.cands, FileEntry{strings.clone(p), "", 0, p != d})
		}
	}
	s.valid, s.seen = true, w.gen
	s.builds += 1
	return s.cands[:]
}

walk_ready :: proc(editor: ^Editor, src: ^ListSource) -> bool {
	if src.wscope != nil && !src.wscope.all {
		return true
	}
	return walk_valid(src.walk) && !src.walk.pw.active
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
	keep, keep_anchor := "", ""
	if p.list.sel >= 0 && p.list.sel < len(src.entries) {
		keep = strings.clone(src.entries[p.list.sel].path, context.temp_allocator)
	}
	if a, ok := p.list.anchor.?; ok && a >= 0 && a < len(src.entries) {
		keep_anchor = strings.clone(src.entries[a].path, context.temp_allocator)
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
	for e, i in src.entries {
		if e.path == keep {
			p.list.sel = i
		}
		if e.path == keep_anchor {
			p.list.anchor = i
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
	limit := p.list.max if p.list.max > 0 else WALK_FILTER_MAX_RESULTS
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
			if walk_ignored(w, r.path) {
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

pane_tree_reveal :: proc(editor: ^Editor, p: ^Pane, path: string) -> bool {
	root := p.list.source.walk.root
	for q := path_parent(path); strings.has_prefix(q, root); {
		pane_tree_set(p, q, true)
		np := path_parent(q)
		if q == root || np == q {
			break
		}
		q = np
	}
	list_walk_fill(editor, p)
	for e, i in p.list.source.entries {
		if e.path == path {
			p.list.sel, p.list.anchor, p.list.moved = i, nil, true
			pane_scroll_fit(p, pane_geom(editor, p).list.h)
			return true
		}
	}
	return false
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
		if info.type != .Directory || walk_ignored(w, info.fullpath) {
			continue
		}
		if !w.dotfiles && strings.has_prefix(info.name, ".") {
			continue
		}
		pane_tree_set(p, info.fullpath, true)
		pane_tree_mark_expanded(editor, p, info.fullpath)
	}
}

pane_tree_any_expanded :: proc(p: ^Pane) -> bool {
	for e in p.list.source.entries {
		if e.is_dir && pane_tree_expanded(p, e.path) {
			return true
		}
	}
	return false
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
		if !src.walk.ignore_ready && !src.walk.ignored {
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
	Into,
	Special,
	Root,
	Failed,
}

fs_error_text :: proc(err: FsError, path: string) -> string {
	switch err {
	case .None:
	case .Exists:
		return "exists"
	case .Missing:
		return "not found"
	case .Into:
		return "into itself"
	case .Special:
		return "not a file, dir or link"
	case .Root:
		return "the root"
	case .Failed:
		return fmt.tprintf("failed: %s", path)
	}
	return ""
}

fs_lstat :: proc(path: string) -> (st: posix.stat_t, ok: bool) {
	ok = posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK
	return
}

fs_lexists :: proc(path: string) -> bool {
	_, ok := fs_lstat(path)
	return ok
}

fs_into :: proc(src, dst: string) -> bool {
	s, _ := filepath.clean(src, context.temp_allocator)
	d, _ := filepath.clean(dst, context.temp_allocator)
	return d == s || path_under(d, s)
}

fs_copy_file :: proc(src, dst: string, st: posix.stat_t) -> bool {
	in_fd := posix.open(strings.clone_to_cstring(src, context.temp_allocator), {})
	if in_fd < 0 {
		return false
	}
	defer posix.close(in_fd)
	out_fd := posix.open(strings.clone_to_cstring(dst, context.temp_allocator), {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if out_fd < 0 {
		return false
	}
	defer posix.close(out_fd)
	buf: [64 * 1024]u8
	for {
		n := posix.read(in_fd, raw_data(buf[:]), len(buf))
		if n < 0 {
			return false
		}
		if n == 0 {
			break
		}
		for off := 0; off < n; {
			w := posix.write(out_fd, raw_data(buf[off:]), uint(n - off))
			if w <= 0 {
				return false
			}
			off += w
		}
	}
	return true
}

fs_times :: proc(path: string, st: posix.stat_t) {
	times := [2]posix.timespec{st.st_atim, st.st_mtim}
	posix.utimensat(posix.AT_FDCWD, strings.clone_to_cstring(path, context.temp_allocator), &times, {.SYMLINK_NOFOLLOW})
}

// fifos, sockets and devices are skipped: reading one could block forever
fs_copy_tree :: proc(src, dst: string, keep_times := false) -> bool {
	st, ok := fs_lstat(src)
	if !ok {
		return false
	}
	cdst := strings.clone_to_cstring(dst, context.temp_allocator)
	switch {
	case posix.S_ISLNK(st.st_mode):
		buf: [4096]u8
		n := posix.readlink(strings.clone_to_cstring(src, context.temp_allocator), raw_data(buf[:]), len(buf) - 1)
		if n < 0 {
			return false
		}
		buf[n] = 0
		if posix.symlink(cstring(raw_data(buf[:])), cdst) != .OK {
			return false
		}
	case posix.S_ISDIR(st.st_mode):
		infos, err := os.read_directory_by_path(src, -1, context.temp_allocator)
		if err != nil || posix.mkdir(cdst, {.IRUSR, .IWUSR, .IXUSR}) != .OK {
			return false
		}
		for child in infos {
			if !fs_copy_tree(child.fullpath, fmt.tprintf("%s/%s", dst, child.name), keep_times) {
				return false
			}
		}
		posix.chmod(cdst, st.st_mode)
	case posix.S_ISREG(st.st_mode):
		if !fs_copy_file(src, dst, st) {
			return false
		}
		posix.chmod(cdst, st.st_mode)
	case:
		return true
	}
	if keep_times {
		fs_times(dst, st)
	}
	return true
}

fs_check :: proc(src, dst: string) -> FsError {
	st, ok := fs_lstat(src)
	switch {
	case !ok:
		return .Missing
	case fs_lexists(dst):
		return .Exists
	case fs_into(src, dst):
		return .Into
	case !posix.S_ISLNK(st.st_mode) && !posix.S_ISDIR(st.st_mode) && !posix.S_ISREG(st.st_mode):
		return .Special
	}
	return .None
}

fs_copy :: proc(editor: ^Editor, src, dst: string) -> FsError {
	if err := fs_check(src, dst); err != .None {
		return err
	}
	path_ensure_parent_dir(dst)
	ok := fs_copy_tree(src, dst)
	if !ok {
		fs_remove_tree(dst)
	}
	walk_invalidate(editor, dst)
	return .None if ok else .Failed
}

fs_rename :: proc(editor: ^Editor, src, dst: string) -> FsError {
	if err := fs_check(src, dst); err != .None {
		return err
	}
	path_ensure_parent_dir(dst)
	if posix.rename(strings.clone_to_cstring(src, context.temp_allocator), strings.clone_to_cstring(dst, context.temp_allocator)) != 0 {
		if posix.errno() != .EXDEV {
			return .Failed
		}
		if !fs_copy_tree(src, dst, true) {
			fs_remove_tree(dst)
			return .Failed
		}
		if !fs_remove_tree(src) {
			fs_remove_tree(dst)
			walk_invalidate(editor, src)
			return .Failed
		}
	}
	buffers_repath(editor, src, dst)
	walk_invalidate(editor, src)
	walk_invalidate(editor, dst)
	return .None
}

fs_remove_tree :: proc(path: string) -> bool {
	st, ok := fs_lstat(path)
	if !ok {
		return false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if !posix.S_ISDIR(st.st_mode) {
		return posix.unlink(cpath) == .OK
	}
	infos, _ := os.read_directory_by_path(path, -1, context.temp_allocator)
	all := true
	for child in infos {
		all = fs_remove_tree(child.fullpath) && all
	}
	return posix.rmdir(cpath) == .OK && all
}

fs_remove :: proc(editor: ^Editor, path: string) -> FsError {
	if !fs_lexists(path) {
		return .Missing
	}
	if clean, _ := filepath.clean(path, context.temp_allocator); clean == editor.working_root || path_under(editor.working_root, clean) {
		return .Root
	}
	ok := fs_remove_tree(path)
	walk_invalidate(editor, path)
	return .None if ok else .Failed
}

fs_mkdir :: proc(editor: ^Editor, path: string) -> FsError {
	if fs_lexists(path) {
		return .Exists
	}
	if os.make_directory_all(path, os.perm(0o755)) != nil {
		return .Failed
	}
	walk_invalidate(editor, path)
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

path_parent :: proc(path: string) -> string {
	if idx := strings.last_index_byte(path, '/'); idx > 0 {
		return path[:idx]
	}
	return path
}
