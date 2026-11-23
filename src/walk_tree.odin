package main

import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import "core:time"
import lua "lib:lua"

// the visible rows of a walk as a list a virtual_column reads: expansion, narrowing and reveal are list operations
WalkTree :: struct {
	source:    ListSource,
	expanded:  map[string]bool,
	query:     string,
	max:       int,
	more:      bool,
	expanding: bool,
	capped:    bool,
	due:       bool,
	stamp:     u64,
	gen:       u64,
}

walk_tree_new :: proc(walk: ^Walk, scope: ^WalkScope) -> ^WalkTree {
	tree := new(WalkTree)
	walk.refs += 1
	if scope != nil {
		scope.refs += 1
	}
	tree.source = ListSource{kind = .Walk, walk = walk, wscope = scope}
	tree.due = true
	return tree
}

walk_tree_free :: proc(tree: ^WalkTree) {
	list_source_free(&tree.source)
	for path in tree.expanded {
		delete(path)
	}
	delete(tree.expanded)
	delete(tree.query)
	free(tree)
}

walk_tree_expanded :: proc(tree: ^WalkTree, path: string) -> bool {
	if on, ok := tree.expanded[path]; ok {
		return on
	}
	return tree.source.wscope != nil && !tree.source.wscope.all
}

walk_tree_set :: proc(tree: ^WalkTree, path: string, on: bool) {
	if path in tree.expanded {
		tree.expanded[path] = on
	} else {
		tree.expanded[strings.clone(path)] = on
	}
	tree.due = true
}

walk_tree_stamp :: proc(tree: ^WalkTree) -> u64 {
	return tree.source.walk.gen + 1
}

// one slice of reading: dirs not read in time stay pending and the next prepare continues
walk_tree_fill :: proc(editor: ^Editor, tree: ^WalkTree) {
	src := &tree.source
	tree.due = false
	tree.stamp = walk_tree_stamp(tree)
	tree.gen += 1
	clear(&src.entries)
	clear(&src.pending)
	vmem.arena_free_all(&src.names)
	tree.more = false
	src.filtering = tree.query != ""
	if src.filtering {
		if !walk_ready(editor, src) {
			walk_prewarm(editor, src.walk)
			tree.due = true
			return
		}
		walk_tree_filter(editor, tree)
		return
	}
	walk_narrow_reset(src)
	kids := walk_virtual_kids(src.wscope, src.walk.root)
	fill := WalkFill {
		kids     = &kids,
		deadline = time.tick_add(time.tick_now(), time.Duration(walk_fill_slice_ms) * time.Millisecond),
	}
	walk_tree_dir(editor, tree, src.walk.root, 0, &fill)
	if fill.capped && !tree.capped {
		tree.capped = true
		editor_log(editor, .Warn, "Filetree", fmt.tprintf("Expand All stopped at %d rows", WALK_EXPAND_MAX_ROWS))
	}
	if len(src.pending) > 0 {
		tree.due = true
	} else {
		tree.expanding = false
	}
}

walk_tree_dir :: proc(editor: ^Editor, tree: ^WalkTree, dir: string, depth: int, fill: ^WalkFill) -> bool {
	src := &tree.source
	rows_of :: proc(src: ^ListSource, dir: string, fill: ^WalkFill, read: bool) -> ([]WalkRow, bool) {
		if src.wscope != nil {
			return walk_scope_rows(src, dir, fill.kids, read)
		}
		return list_walk_cached_rows(src, dir, fill.kids, read)
	}
	rows, ok := rows_of(src, dir, fill, false)
	if !ok && (fill.reads == 0 || time.tick_diff(time.tick_now(), fill.deadline) > 0) {
		rows, ok = rows_of(src, dir, fill, true)
		fill.reads += 1
	}
	if !ok {
		return false
	}
	for row in rows {
		path := row.path if src.wscope == nil else strings.clone(row.path, vmem.arena_allocator(&src.names))
		append(&src.entries, FileEntry{path, path[row.name:], depth, row.is_dir})
		if !row.is_dir {
			continue
		}
		if tree.expanding && path not_in tree.expanded {
			if len(src.entries) < WALK_EXPAND_MAX_ROWS {
				tree.expanded[strings.clone(path)] = true
			} else {
				fill.capped, tree.expanding = true, false
			}
		}
		if walk_tree_expanded(tree, path) && !walk_tree_dir(editor, tree, path, depth + 1, fill) {
			src.pending[path] = true
		}
	}
	return true
}

walk_tree_filter :: proc(editor: ^Editor, tree: ^WalkTree) {
	src := &tree.source
	cands := walk_source_cands(editor, src)
	root := src.walk.root
	builds := src.wscope.builds if src.wscope != nil else src.walk.builds
	if len(cands) == 0 {
		walk_narrow_reset(src)
		return
	}
	query := tree.query
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
	for candidate, i in base {
		names[i] = walk_rel(cands[candidate].path, root)
	}
	limit := tree.max if tree.max > 0 else WALK_FILTER_MAX_RESULTS
	matcher := fuzzy_begin(names)
	ranked := fuzzy_rank(&matcher, query)
	clear(&src.narrow_idx)
	for position, i in ranked {
		candidate := base[position]
		append(&src.narrow_idx, candidate)
		if i >= limit {
			continue
		}
		path := strings.clone(cands[candidate].path, vmem.arena_allocator(&src.names))
		append(&src.entries, FileEntry{path, walk_rel(path, root), 0, cands[candidate].is_dir})
	}
	fuzzy_end(&matcher)
	tree.more = len(src.narrow_idx) > len(src.entries)
	delete(src.narrow_q)
	src.narrow_q = strings.clone(query)
	src.narrow_builds = builds
}

walk_tree_reveal :: proc(tree: ^WalkTree, path: string) {
	root := tree.source.walk.root
	for dir := path_parent(path); strings.has_prefix(dir, root); {
		walk_tree_set(tree, dir, true)
		up := path_parent(dir)
		if dir == root || up == dir {
			break
		}
		dir = up
	}
}

// expanding the whole walk needs the ignore set, or it would descend into node_modules
walk_tree_expand_all :: proc(tree: ^WalkTree, on: bool) -> bool {
	src := &tree.source
	if src.wscope != nil && !src.wscope.all {
		if on {
			for path in tree.expanded {
				delete(path)
			}
			clear(&tree.expanded)
		} else {
			for entry in src.entries {
				if entry.is_dir {
					walk_tree_set(tree, entry.path, false)
				}
			}
		}
	} else if on {
		if !src.walk.ignore_ready && !src.walk.ignored {
			return false
		}
		tree.expanding = true
		tree.capped = false
	} else {
		for path in tree.expanded {
			delete(path)
		}
		clear(&tree.expanded)
	}
	if !on {
		tree.expanding = false
	}
	tree.due = true
	return true
}

walk_tree_record_push :: proc(L: ^lua.State, tree: ^WalkTree, pos: int) {
	entry := tree.source.entries[pos]
	lua.createtable(L, 0, 5)
	lua.pushodinstring(L, entry.path)
	lua.setfield(L, -2, "path")
	lua.pushodinstring(L, entry.name)
	lua.setfield(L, -2, "name")
	lua.pushinteger(L, lua.Integer(entry.depth))
	lua.setfield(L, -2, "depth")
	lua.pushboolean(L, b32(entry.is_dir))
	lua.setfield(L, -2, "dir")
	lua.pushboolean(L, b32(entry.is_dir && walk_tree_expanded(tree, entry.path)))
	lua.setfield(L, -2, "expanded")
}

// a tree list refills when asked or when its walk changed, one slice per prepare while dirs stay unread
walk_trees_settle :: proc(editor: ^Editor) {
	for list in editor.ui.lists {
		tree := list.tree
		if tree == nil || (!tree.due && tree.stamp == walk_tree_stamp(tree)) {
			continue
		}
		walk_tree_fill(editor, tree)
		clear(&list.positions)
		for entry, i in tree.source.entries {
			list.positions[entry.path] = i
		}
		ui_list_changed(editor, list)
	}
}

walk_trees_busy :: proc(editor: ^Editor) -> bool {
	for list in editor.ui.lists {
		if list.tree != nil && list.tree.due {
			return true
		}
	}
	return false
}
