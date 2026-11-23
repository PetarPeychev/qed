package main

import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"
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
WALK_EXPAND_MAX_ROWS :: 200_000

walk_fill_slice_ms := 6

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
	stales:            u64,
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
	gen:     u64,
	active:  bool,
	restart: bool,
	done:    bool,
}

// keys of listed/closure slice into text (paths and their prefixes), so a 50k-path scope is one buffer
WalkScope :: struct {
	refs:    int,
	all:     bool,
	base:    ^WalkScope,
	text:    []u8,
	paths:   []string,
	virtual: []string,
	listed:  map[string]bool,
	closure: map[string]i32,
	dirs:    [dynamic]string,
	parent:  []i32,
	cands:   [dynamic]FileEntry,
	valid:   bool,
	seen:    u64,
	builds:  u64,
	rows:       map[string][]WalkRow,
	rows_arena: vmem.Arena,
	rows_gen:   u64,
	kids:       map[string][dynamic]WalkRow,
}

walk_entries_free :: proc(entries: ^[dynamic]FileEntry) {
	for e in entries {
		delete(e.path, runtime.heap_allocator())
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

// walker threads allocate the paths: the heap is thread safe where a caller's allocator need not be
walk_run :: proc(a: ^WalkAdmit, root: string, out: ^[dynamic]FileEntry, threads := -1) {
	heap := runtime.heap_allocator()
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
	w.stales += 1
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
	pw.gen = w.gen
	pw.done, pw.restart, pw.active = false, false, true
	pw.thread = thread.create(walk_prewarm_run)
	pw.thread.data = pw
	thread.start(pw.thread)
}

walk_prewarm_run :: proc(th: ^thread.Thread) {
	pw := (^WalkPrewarm)(th.data)
	context.allocator = runtime.heap_allocator()
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
		base.refs += 1
		s.base = base
	}
	n := 0
	for p in within {
		n += len(p)
	}
	for p in virtual {
		n += len(p)
	}
	s.text = make([]u8, n)
	s.paths = make([]string, len(within))
	s.parent = make([]i32, len(within))
	s.virtual = make([]string, len(virtual))
	// a map grows at 3/4 full, so reserving the exact count would rehash once on the last quarter
	reserve(&s.listed, len(within) * 4 / 3 + 1)
	reserve(&s.closure, len(virtual) + 64)
	at := 0
	keep :: proc(s: ^WalkScope, at: ^int, p: string) -> string {
		copy(s.text[at^:], p)
		k := string(s.text[at^:at^ + len(p)])
		at^ += len(p)
		return k
	}
	for p, i in within {
		s.paths[i] = keep(s, &at, p)
		s.listed[s.paths[i]] = true
		s.parent[i] = walk_closure_add(s, root, path_parent(s.paths[i]))
	}
	for p, i in virtual {
		s.virtual[i] = keep(s, &at, p)
		walk_closure_add(s, root, s.virtual[i])
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
	walk_scope_release(s.base)
	delete(s.listed)
	delete(s.closure)
	delete(s.dirs)
	delete(s.parent)
	delete(s.paths)
	delete(s.virtual)
	delete(s.text)
	walk_entries_free(&s.cands)
	delete(s.cands)
	delete(s.rows)
	vmem.arena_destroy(&s.rows_arena)
	free(s)
}

walk_set_clear :: proc(set: ^map[string]bool) {
	for key in set^ {
		delete(key)
	}
	clear(set)
}

// ancestors are prefixes of path, so they share its storage
walk_closure_add :: proc(s: ^WalkScope, root, path: string) -> i32 {
	if i, ok := s.closure[path]; ok {
		return i
	}
	add :: proc(s: ^WalkScope, p: string) -> i32 {
		i := i32(len(s.dirs))
		s.closure[p] = i
		append(&s.dirs, p)
		return i
	}
	at := add(s, path)
	p := path
	for strings.has_prefix(p, root) && p != root {
		np := path_parent(p)
		if np == p || np in s.closure {
			break
		}
		p = np
		add(s, p)
	}
	return at
}

walk_scope_in_closure :: proc(s: ^WalkScope, p: string) -> bool {
	for sc := s; sc != nil; sc = sc.base {
		if p in sc.closure || p in sc.listed {
			return true
		}
	}
	return false
}

walk_scope_has :: proc(s: ^WalkScope, p: string) -> bool {
	if walk_scope_in_closure(s, p) {
		return true
	}
	for q := p; true; {
		np := path_parent(q)
		if np == q {
			return false
		}
		q = np
		for sc := s; sc != nil; sc = sc.base {
			if q in sc.listed {
				return true
			}
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
			append(&s.cands, FileEntry{strings.clone(e.path, runtime.heap_allocator()), "", 0, e.is_dir})
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
	for sc := s; sc != nil; sc = sc.base {
		for d in sc.virtual {
			for p := d; strings.has_prefix(p, under) && !(p in seen) && !os.exists(p); p = path_parent(p) {
				seen[p] = true
				append(&s.cands, FileEntry{strings.clone(p, runtime.heap_allocator()), "", 0, p != d})
			}
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

walk_rel :: proc(path, root: string) -> string {
	if strings.has_prefix(path, root) {
		return strings.trim_left(path[len(root):], "/")
	}
	return path
}

WalkRow :: struct {
	path:   string,
	name:   int,
	is_dir: bool,
}

// virtual children by parent dir, built once per fill so each dir finds its own in O(1)
walk_virtual_kids :: proc(s: ^WalkScope, root: string) -> map[string][dynamic]WalkRow {
	kids := make(map[string][dynamic]WalkRow, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for sc := s; sc != nil; sc = sc.base {
		for d in sc.virtual {
			p := d
			for strings.has_prefix(p, root) && p != root && !(p in seen) {
				seen[p] = true
				dir := path_parent(p)
				if dir not_in kids {
					kids[dir] = make([dynamic]WalkRow, context.temp_allocator)
				}
				append(&kids[dir], WalkRow{p, len(dir) + 1, p != d})
				p = dir
			}
		}
	}
	return kids
}

walk_readdir :: proc(dir: string, rows: ^[dynamic]WalkRow) {
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
		append(rows, WalkRow{strings.concatenate({dir, "/", name}, context.temp_allocator), len(dir) + 1, kind == .DIR})
	}
}

list_walk_rows :: proc(src: ^ListSource, dir: string, kids: ^map[string][dynamic]WalkRow) -> []WalkRow {
	w := src.walk
	rows := make([dynamic]WalkRow, context.temp_allocator)
	walk_readdir(dir, &rows)
	if v, ok := kids[dir]; ok {
		have := make(map[string]bool, len(rows), context.temp_allocator)
		for r in rows {
			have[r.path] = true
		}
		for r in v {
			if r.path not_in have {
				append(&rows, r)
			}
		}
	}
	// siblings share the dir prefix, so compare names
	slice.sort_by(rows[:], proc(a, b: WalkRow) -> bool {
		if a.is_dir != b.is_dir {
			return a.is_dir
		}
		return a.path[a.name:] < b.path[b.name:]
	})
	out := make([dynamic]WalkRow, 0, len(rows), context.temp_allocator)
	for r in rows {
		if s := src.wscope; s != nil && (!s.all || walk_scope_in_closure(s, r.path)) {
			if !walk_scope_has(s, r.path) {
				continue
			}
		} else {
			if !w.dotfiles && strings.has_prefix(r.path[r.name:], ".") {
				continue
			}
			if walk_ignored(w, r.path) {
				continue
			}
		}
		append(&out, r)
	}
	return out[:]
}

// a narrowed tree refills on every view switch: its dirs are read and sorted once per restale
walk_scope_rows :: proc(src: ^ListSource, dir: string, kids: ^map[string][dynamic]WalkRow, read := true) -> ([]WalkRow, bool) {
	s := src.wscope
	// a prewarm landing bumps gen without the disk changing; only a restale drops the rows
	if s.rows_gen != src.walk.stales + 1 {
		clear(&s.rows)
		vmem.arena_free_all(&s.rows_arena)
		s.kids = walk_scope_kids(s, src.walk.root, vmem.arena_allocator(&s.rows_arena))
		s.rows_gen = src.walk.stales + 1
	}
	if r, ok := s.rows[dir]; ok {
		return r, true
	}
	if !read {
		return nil, false
	}
	a := vmem.arena_allocator(&s.rows_arena)
	rows := walk_scope_known_rows(s, dir, a)
	if rows == nil {
		rows = slice.clone(list_walk_rows(src, dir, kids), a)
		for &r in rows {
			r.path = strings.clone(r.path, a)
		}
	}
	s.rows[strings.clone(dir, a)] = rows
	return rows, true
}

// a browsable tree refills on every expand and restale: each dir is read once per restale of its walk
list_walk_cached_rows :: proc(src: ^ListSource, dir: string, kids: ^map[string][dynamic]WalkRow, read: bool) -> ([]WalkRow, bool) {
	if src.dirs_walk != src.walk || src.dirs_stales != src.walk.stales {
		clear(&src.dirs)
		vmem.arena_free_all(&src.dirs_arena)
		src.dirs_walk, src.dirs_stales = src.walk, src.walk.stales
	}
	if r, ok := src.dirs[dir]; ok {
		return r, true
	}
	if !read {
		return nil, false
	}
	a := vmem.arena_allocator(&src.dirs_arena)
	rows := slice.clone(list_walk_rows(src, dir, kids), a)
	for &r in rows {
		r.path = strings.clone(r.path, a)
	}
	src.dirs[strings.clone(dir, a)] = rows
	return rows, true
}

// a listed path's parent was indexed when the scope was built, so only closure dirs are hashed here
walk_scope_kids :: proc(s: ^WalkScope, root: string, a: runtime.Allocator) -> map[string][dynamic]WalkRow {
	kids := make(map[string][dynamic]WalkRow, a)
	group :: proc(kids: ^map[string][dynamic]WalkRow, dir: string, a: runtime.Allocator) -> ^[dynamic]WalkRow {
		rows, ok := &kids[dir]
		if !ok {
			kids[dir] = make([dynamic]WalkRow, a)
			rows = &kids[dir]
		}
		return rows
	}
	for sc := s; sc != nil; sc = sc.base {
		for p in sc.dirs {
			if dir := path_parent(p); p != root && dir != p {
				append(group(&kids, dir, a), WalkRow{p, len(dir) + 1, true})
			}
		}
		count := make([]int, len(sc.dirs), context.temp_allocator)
		for d in sc.parent {
			count[d] += 1
		}
		for n, d in count {
			if n > 0 {
				reserve(group(&kids, sc.dirs[d], a), n)
			}
		}
		// no insert from here on, so the map keeps these value pointers in place
		slot := make([]^[dynamic]WalkRow, len(sc.dirs), context.temp_allocator)
		for n, d in count {
			if n > 0 {
				slot[d] = &kids[sc.dirs[d]]
			}
		}
		for p, i in sc.paths {
			dir := sc.dirs[sc.parent[i]]
			if p != root && dir != p {
				append(slot[sc.parent[i]], WalkRow{p, len(dir) + 1, false})
			}
		}
	}
	for _, &rows in kids {
		for &r in rows {
			r.is_dir = r.is_dir && r.path in kids
		}
	}
	return kids
}

// trusted only when the dir's link count (2 + subdirs) matches the scope's dirs there
walk_scope_known_rows :: proc(s: ^WalkScope, dir: string, a: runtime.Allocator) -> []WalkRow {
	for q := dir; true; {
		for sc := s; sc != nil; sc = sc.base {
			if q in sc.listed {
				return nil
			}
		}
		np := path_parent(q)
		if np == q {
			break
		}
		q = np
	}
	named := slice.clone(s.kids[dir][:], context.temp_allocator)
	// insertion sort: a dir's rows are few, and slice.sort_by's smoothsort costs more per compare
	for i in 1 ..< len(named) {
		r := named[i]
		k := i
		for k > 0 && r.path[r.name:] < named[k - 1].path[named[k - 1].name:] {
			named[k] = named[k - 1]
			k -= 1
		}
		named[k] = r
	}
	n, dirs := 0, 0
	for r in named {
		if n > 0 && named[n - 1].path == r.path {
			named[n - 1].is_dir ||= r.is_dir
			continue
		}
		named[n] = r
		n += 1
	}
	for r in named[:n] {
		dirs += int(r.is_dir)
	}
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(dir, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) || int(st.st_nlink) != dirs + 2 {
		return nil
	}
	rows := make([]WalkRow, n, a)
	k := 0
	for want in ([]bool{true, false}) {
		for r in named[:n] {
			if r.is_dir == want {
				rows[k] = r
				k += 1
			}
		}
	}
	return rows
}

WalkFill :: struct {
	kids:     ^map[string][dynamic]WalkRow,
	deadline: time.Tick,
	reads:    int,
	capped:   bool,
}

WalkSelected :: struct {
	path:   string,
	is_dir: bool,
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

// stat by path, never opening it: os.stat opens, which blocks on a fifo
fs_stat :: proc(path: string) -> (st: posix.stat_t, ok: bool) {
	ok = posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK
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

// O_EXCL also refuses a dangling symlink, which a rename over the name would replace
fs_create :: proc(editor: ^Editor, path, data: string) -> FsError {
	if fs_lexists(path) {
		return .Exists
	}
	path_ensure_parent_dir(path)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {
		return .Exists if posix.errno() == .EEXIST else .Failed
	}
	defer posix.close(fd)
	for off := 0; off < len(data); {
		rest: int = len(data) - off
		n := posix.write(fd, raw_data(data[off:]), uint(rest))
		if n <= 0 {
			return .Failed
		}
		off += n
	}
	walk_invalidate(editor, path)
	return .None
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
	for i := len(path) - 1; i > 0; i -= 1 {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return path
}

ListSourceKind :: enum {
	None,
	Commands,
	Dirs,
	Lines,
	Walk,
}

ListSource :: struct {
	kind:      ListSourceKind,
	scope:     string,
	path:      string,
	dotfiles:  bool,
	buf:       u64,
	cache_dir: string,
	cache:     [dynamic]string,
	ids:       [dynamic]u64,
	rows:      [dynamic]int,
	stamp:     u64,
	evicted:   int,
	walk:      ^Walk,
	wscope:    ^WalkScope,
	entries:   [dynamic]FileEntry,
	names:     vmem.Arena,
	filtering: bool,
	narrow_q:  string,
	narrow_idx: [dynamic]int,
	narrow_builds: u64,
	dirs:      map[string][]WalkRow,
	dirs_arena: vmem.Arena,
	dirs_walk: ^Walk,
	dirs_stales: u64,
	pending:   map[string]bool,
	expanding: bool,
	resume:    bool,
}

list_source_free :: proc(s: ^ListSource) {
	delete(s.scope)
	delete(s.path)
	list_source_uncache(s)
	delete(s.cache)
	delete(s.ids)
	delete(s.rows)
	walk_release(s.walk)
	walk_scope_release(s.wscope)
	delete(s.entries)
	vmem.arena_destroy(&s.names)
	delete(s.narrow_q)
	delete(s.narrow_idx)
	delete(s.dirs)
	vmem.arena_destroy(&s.dirs_arena)
	delete(s.pending)
	s^ = {}
}

list_source_uncache :: proc(s: ^ListSource) {
	for n in s.cache {
		delete(n)
	}
	clear(&s.cache)
	clear(&s.ids)
	clear(&s.rows)
	delete(s.cache_dir)
	s.cache_dir = ""
}

all_digits :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

path_under :: proc(path, root: string) -> bool {
	if root == "/" {
		return strings.has_prefix(path, "/")
	}
	return len(path) > len(root) && path[len(root)] == '/' && strings.has_prefix(path, root)
}
