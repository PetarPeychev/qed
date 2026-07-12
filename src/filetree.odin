package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

FileTreeMode :: enum {
	Nav,
	New,
	Rename,
	ConfirmDelete,
}

FileTreeScope :: enum {
	All,
	Open,
	Git,
	Unsaved,
}

FileTreeTab :: struct {
	label: string,
	scope: FileTreeScope,
}

filetree_tabs := [?]FileTreeTab{{"All", .All}, {"Open", .Open}, {"Git", .Git}, {"Unsaved", .Unsaved}}

FileEntry :: struct {
	path:   string,
	name:   string,
	depth:  int,
	is_dir: bool,
}

FileTree :: struct {
	active:          bool,
	entries:         [dynamic]FileEntry,
	expanded:        map[string]bool,
	selected:        int,
	anchor:          Maybe(int),
	clipboard:       [dynamic]string,
	clip_cut:        bool,
	scroll:          int,
	mode:            FileTreeMode,
	field:           TextField,
	filter:          TextField,
	delete_selected: int,
	preview:         Preview,
	status:          map[string]GitMark,
	ignored:         map[string]bool,
	show_dotfiles:   bool,
	show_ignored:    bool,
	scope:           FileTreeScope,
	scope_paths:     map[string]bool,
	scan_sub:        Subprocess,
	scanned:         bool,
}

FileTreeLayout :: struct {
	box, inner:                        Rect,
	body_top, body_h:                  int,
	preview_top, preview_h:            int,
	filter_y, footer_y:                int,
	tab_y:                             int,
	title_sep_y, filter_sep_y, footer_sep_y, div_x: int,
	left_w, right_x, right_w:          int,
}

filetree_layout :: proc(editor: ^Editor) -> FileTreeLayout {
	lay := overlay_layout(editor)
	inner := lay.inner
	tab_y := inner.y
	title_sep_y := inner.y + 1
	filter_y := inner.y + 2
	filter_sep_y := inner.y + 3
	body_top := inner.y + 4
	footer_y := inner.y + inner.h - 1
	footer_sep_y := inner.y + inner.h - 2
	body_h := max(1, footer_sep_y - body_top)
	preview_top := title_sep_y + 1
	preview_h := max(1, footer_sep_y - preview_top)
	left_w := (inner.w - 1) / 2
	div_x := inner.x + left_w
	right_x := div_x + 1
	right_w := max(0, inner.x + inner.w - right_x)
	return FileTreeLayout {
		box = lay.box,
		inner = inner,
		body_top = body_top,
		body_h = body_h,
		preview_top = preview_top,
		preview_h = preview_h,
		filter_y = filter_y,
		footer_y = footer_y,
		tab_y = tab_y,
		title_sep_y = title_sep_y,
		filter_sep_y = filter_sep_y,
		footer_sep_y = footer_sep_y,
		div_x = div_x,
		left_w = left_w,
		right_x = right_x,
		right_w = right_w,
	}
}

filetree_destroy :: proc(t: ^FileTree) {
	subprocess_kill(&t.scan_sub)
	filetree_clear_entries(t)
	delete(t.entries)
	for key in t.expanded {
		delete(key)
	}
	delete(t.expanded)
	textfield_destroy(&t.field)
	textfield_destroy(&t.filter)
	preview_destroy(&t.preview)
	filetree_clear_status(t)
	delete(t.status)
	delete(t.ignored)
	filetree_paths_clear(&t.scope_paths)
	delete(t.scope_paths)
	filetree_clip_clear(t)
	delete(t.clipboard)
}

filetree_paths_set :: proc(set: ^map[string]bool, path: string) {
	if path not_in set^ {
		set^[strings.clone(path)] = true
	}
}

filetree_paths_add :: proc(set: ^map[string]bool, root, path: string) {
	filetree_paths_set(set, path)
	p := path
	for strings.has_prefix(p, root) && p != root {
		np := filetree_parent_dir(p)
		if np == p {
			break
		}
		p = np
		filetree_paths_set(set, p)
	}
}

filetree_paths_clear :: proc(set: ^map[string]bool) {
	for key in set^ {
		delete(key)
	}
	clear(set)
}

filetree_sel_range :: proc(t: ^FileTree) -> (lo, hi: int) {
	lo, hi = t.selected, t.selected
	if a, ok := t.anchor.?; ok {
		lo, hi = min(a, t.selected), max(a, t.selected)
	}
	return
}

filetree_unsaved :: proc(editor: ^Editor, e: FileEntry) -> bool {
	if !e.is_dir {
		if idx := editor_find_buffer(editor, e.path); idx >= 0 {
			return editor.buffers[idx].modified
		}
		return false
	}
	prefix := strings.concatenate({e.path, "/"}, context.temp_allocator)
	for &b in editor.buffers {
		if b.modified && strings.has_prefix(b.path, prefix) {
			return true
		}
	}
	return false
}

filetree_is_current :: proc(editor: ^Editor, e: FileEntry) -> bool {
	if e.is_dir || editor.welcome || len(editor.buffers) == 0 {
		return false
	}
	return editor_buffer(editor).path == e.path
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
}

filetree_scan_cmd :: proc(root: string) -> cstring {
	q := shell_quote(root)
	return fmt.ctprintf(
		"git -C %s rev-parse --show-toplevel 2>/dev/null && git -C %s status --porcelain --ignored --untracked-files=all 2>/dev/null",
		q,
		q,
	)
}

filetree_scan_status :: proc(editor: ^Editor) {
	root := editor.working_root
	if root == "" {
		filetree_clear_status(&editor.filetree)
		editor.filetree.scanned = true
		return
	}
	out, ok := shell_capture(filetree_scan_cmd(root))
	if !ok {
		return
	}
	filetree_scan_apply(editor, out)
}

filetree_scan_start :: proc(editor: ^Editor) {
	t := &editor.filetree
	if t.scan_sub.running {
		subprocess_kill(&t.scan_sub)
	}
	root := editor.working_root
	if root == "" {
		filetree_clear_status(t)
		t.scanned = true
		return
	}
	sub, serr, ok := subprocess_start(string(filetree_scan_cmd(root)), nil, root)
	if !ok {
		editor_log(editor, .Debug, "Files", fmt.tprintf("git scan spawn failed (%v)", serr))
		return
	}
	t.scan_sub = sub
}

filetree_scanning :: proc(editor: ^Editor) -> bool {
	return editor.filetree.scan_sub.running
}

filetree_scan_pump :: proc(editor: ^Editor) -> bool {
	t := &editor.filetree
	if !t.scan_sub.running {
		return false
	}
	if !subprocess_drain(&t.scan_sub) {
		return false
	}
	filetree_scan_apply(editor, subprocess_output(&t.scan_sub))
	subprocess_destroy(&t.scan_sub)
	if t.active {
		filetree_rebuild(editor)
	}
	return true
}

filetree_scan_apply :: proc(editor: ^Editor, output: string) {
	t := &editor.filetree
	filetree_clear_status(t)
	t.scanned = true
	root := editor.working_root
	out := output
	top, top_ok := strings.split_lines_iterator(&out)
	top = strings.trim_space(top)
	if !top_ok || top == "" {
		return
	}
	for line in strings.split_lines_iterator(&out) {
		if len(line) < 4 {
			continue
		}
		code := line[:2]
		rel := line[3:]
		if idx := strings.index(rel, " -> "); idx >= 0 {
			rel = rel[idx + 4:]
		}
		rel = strings.trim_space(rel)
		rel = strings.trim(rel, "\"")
		rel = strings.trim_right(rel, "/")
		if rel == "" {
			continue
		}
		abs, _ := filepath.join({top, rel}, context.temp_allocator)
		if code == "!!" {
			t.ignored[strings.clone(abs)] = true
			continue
		}
		filetree_status_add(t, root, abs, filetree_status_mark(code))
	}
}

filetree_is_ignored :: proc(t: ^FileTree, path: string) -> bool {
	p := path
	for {
		if t.ignored[p] {
			return true
		}
		np := filetree_parent_dir(p)
		if np == p {
			break
		}
		p = np
	}
	return false
}

filetree_status_mark :: proc(code: string) -> GitMark {
	if code == "??" || code[0] == 'A' || code[1] == 'A' {
		return .Added
	}
	return .Modified
}

filetree_status_add :: proc(t: ^FileTree, root, path: string, mark: GitMark) {
	filetree_status_set(t, path, mark)
	p := path
	for strings.has_prefix(p, root) && p != root {
		np := filetree_parent_dir(p)
		if np == p {
			break
		}
		p = np
		filetree_status_set(t, p, mark)
	}
}

filetree_status_set :: proc(t: ^FileTree, path: string, mark: GitMark) {
	if existing, ok := t.status[path]; ok {
		if int(mark) > int(existing) {
			t.status[path] = mark
		}
		return
	}
	t.status[strings.clone(path)] = mark
}

filetree_build_scope :: proc(editor: ^Editor) {
	t := &editor.filetree
	filetree_paths_clear(&t.scope_paths)
	root := editor.working_root
	switch t.scope {
	case .All:
	case .Git:
		for path in t.status {
			filetree_paths_set(&t.scope_paths, path)
		}
	case .Open:
		for &b in editor.buffers {
			if b.path != "" && os.exists(b.path) {
				filetree_paths_add(&t.scope_paths, root, b.path)
			}
		}
	case .Unsaved:
		for &b in editor.buffers {
			if b.modified && b.path != "" && os.exists(b.path) {
				filetree_paths_add(&t.scope_paths, root, b.path)
			}
		}
	}
}

filetree_collect :: proc(t: ^FileTree, dir: string, out: ^[dynamic]FileEntry) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	scoped := t.scope != .All
	for info in infos {
		p := info.fullpath
		is_dir := info.type == .Directory
		if scoped {
			if p not_in t.scope_paths {
				continue
			}
		} else {
			base := filepath.base(p)
			if !t.show_dotfiles && strings.has_prefix(base, ".") {
				continue
			}
			if !t.show_ignored && filetree_is_ignored(t, p) {
				continue
			}
		}
		append(out, FileEntry{p, "", 0, is_dir})
		if is_dir {
			filetree_collect(t, p, out)
		}
	}
}

filetree_apply_filter :: proc(editor: ^Editor) {
	t := &editor.filetree
	query := textfield_str(&t.filter)
	root := editor.working_root
	cands := make([dynamic]FileEntry, context.temp_allocator)
	filetree_collect(t, root, &cands)
	if len(cands) == 0 {
		return
	}
	names := make([dynamic]string, 0, len(cands), context.temp_allocator)
	for c in cands {
		rel := c.path
		if strings.has_prefix(c.path, root) {
			rel = strings.trim_left(c.path[len(root):], "/")
		}
		append(&names, rel)
	}
	f := fuzzy_begin(names[:])
	for idx in fuzzy_rank(&f, query) {
		cloned := strings.clone(cands[idx].path)
		rel := cloned
		if strings.has_prefix(cloned, root) {
			rel = strings.trim_left(cloned[len(root):], "/")
		}
		append(&t.entries, FileEntry{cloned, rel, 0, cands[idx].is_dir})
	}
	fuzzy_end(&f)
}

filetree_clear_entries :: proc(t: ^FileTree) {
	for e in t.entries {
		delete(e.path)
	}
	clear(&t.entries)
}

filetree_load_preview :: proc(editor: ^Editor) {
	t := &editor.filetree
	e, ok := filetree_selected(t)
	if !ok || e.is_dir {
		preview_reset(&t.preview)
		return
	}
	h := filetree_layout(editor).preview_h
	if t.scope == .Git {
		preview_set_diff(&t.preview, e.path, h)
		return
	}
	preview_set_file(&t.preview, e.path, 0, h)
}

filetree_set_expanded :: proc(t: ^FileTree, path: string, val: bool) {
	if path in t.expanded {
		t.expanded[path] = val
	} else {
		t.expanded[strings.clone(path)] = val
	}
}

filetree_dir_expanded :: proc(t: ^FileTree, path: string) -> bool {
	if val, present := t.expanded[path]; present {
		return val
	}
	return t.scope != .All
}

filetree_parent_dir :: proc(path: string) -> string {
	if idx := strings.last_index_byte(path, '/'); idx > 0 {
		return path[:idx]
	}
	return path
}

filetree_read_dir :: proc(t: ^FileTree, dir: string, depth: int) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	Row :: struct {
		path:   string,
		is_dir: bool,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for info in infos {
		append(&rows, Row{info.fullpath, info.type == .Directory})
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.is_dir != b.is_dir {
			return a.is_dir
		}
		return a.path < b.path
	})
	scoped := t.scope != .All
	for r in rows {
		if scoped {
			if r.path not_in t.scope_paths {
				continue
			}
		} else {
			base := filepath.base(r.path)
			if !t.show_dotfiles && strings.has_prefix(base, ".") {
				continue
			}
			if !t.show_ignored && filetree_is_ignored(t, r.path) {
				continue
			}
		}
		path := strings.clone(r.path)
		name := path
		if idx := strings.last_index_byte(path, '/'); idx >= 0 {
			name = path[idx + 1:]
		}
		append(&t.entries, FileEntry{path, name, depth, r.is_dir})
		if r.is_dir && filetree_dir_expanded(t, path) {
			filetree_read_dir(t, path, depth + 1)
		}
	}
}

filetree_rebuild :: proc(editor: ^Editor) {
	t := &editor.filetree
	keep := ""
	if t.selected >= 0 && t.selected < len(t.entries) {
		keep = strings.clone(t.entries[t.selected].path, context.temp_allocator)
	}
	filetree_clear_entries(t)
	t.anchor = nil
	filetree_build_scope(editor)
	if len(t.filter.text) > 0 {
		filetree_apply_filter(editor)
	} else {
		filetree_read_dir(t, editor.working_root, 0)
	}
	t.selected = 0
	if keep != "" {
		for e, i in t.entries {
			if e.path == keep {
				t.selected = i
				break
			}
		}
	}
	t.selected = clamp(t.selected, 0, max(0, len(t.entries) - 1))
	filetree_scroll(editor)
	filetree_load_preview(editor)
}

filetree_refresh :: proc(editor: ^Editor) {
	filetree_scan_status(editor)
	filetree_rebuild(editor)
}

filetree_scroll :: proc(editor: ^Editor) {
	t := &editor.filetree
	rows := filetree_layout(editor).body_h
	if t.selected < t.scroll {
		t.scroll = t.selected
	}
	if t.selected >= t.scroll + rows {
		t.scroll = t.selected - rows + 1
	}
	t.scroll = clamp(t.scroll, 0, max(0, len(t.entries) - rows))
}

filetree_move :: proc(editor: ^Editor, delta: int, extend := false) {
	t := &editor.filetree
	n := len(t.entries)
	if n == 0 {
		return
	}
	if !extend {
		t.anchor = nil
	} else if t.anchor == nil {
		t.anchor = t.selected
	}
	t.selected = clamp(t.selected + delta, 0, n - 1)
	filetree_scroll(editor)
	filetree_load_preview(editor)
}

filetree_selected :: proc(t: ^FileTree) -> (FileEntry, bool) {
	if t.selected < 0 || t.selected >= len(t.entries) {
		return {}, false
	}
	return t.entries[t.selected], true
}

filetree_open :: proc(editor: ^Editor) {
	t := &editor.filetree
	t.active = true
	t.mode = .Nav
	textfield_reset(&t.field)
	textfield_reset(&t.filter)
	editor_clear_message(editor)
	if t.scanned {
		filetree_rebuild(editor)
		filetree_scan_start(editor)
	} else {
		filetree_refresh(editor)
	}
}

filetree_open_scope :: proc(editor: ^Editor, scope: FileTreeScope) {
	editor.filetree.scope = scope
	filetree_open(editor)
}

filetree_open_all :: proc(editor: ^Editor) {filetree_open_scope(editor, .All)}
filetree_open_open :: proc(editor: ^Editor) {filetree_open_scope(editor, .Open)}
filetree_open_git :: proc(editor: ^Editor) {filetree_open_scope(editor, .Git)}
filetree_open_unsaved :: proc(editor: ^Editor) {filetree_open_scope(editor, .Unsaved)}

filetree_close :: proc(editor: ^Editor) {
	editor.filetree.active = false
	editor.filetree.mode = .Nav
	preview_reset(&editor.filetree.preview)
}

filetree_mark_expanded :: proc(t: ^FileTree, dir: string) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		if info.type != .Directory || filetree_is_ignored(t, info.fullpath) {
			continue
		}
		if !t.show_dotfiles && strings.has_prefix(filepath.base(info.fullpath), ".") {
			continue
		}
		filetree_set_expanded(t, info.fullpath, true)
		filetree_mark_expanded(t, info.fullpath)
	}
}

filetree_any_expanded :: proc(t: ^FileTree) -> bool {
	for e in t.entries {
		if e.is_dir && filetree_dir_expanded(t, e.path) {
			return true
		}
	}
	return false
}

filetree_expand_all :: proc(editor: ^Editor) {
	t := &editor.filetree
	if t.scope == .All {
		filetree_scan_status(editor)
		filetree_mark_expanded(t, editor.working_root)
		filetree_rebuild(editor)
		return
	}
	drop := make([dynamic]string, context.temp_allocator)
	for key, val in t.expanded {
		if !val {
			append(&drop, key)
		}
	}
	for key in drop {
		delete_key(&t.expanded, key)
		delete(key)
	}
	filetree_rebuild(editor)
}

filetree_collapse_all :: proc(editor: ^Editor) {
	t := &editor.filetree
	if t.scope != .All {
		for e in t.entries {
			if e.is_dir {
				filetree_set_expanded(t, e.path, false)
			}
		}
		filetree_rebuild(editor)
		return
	}
	for key in t.expanded {
		delete(key)
	}
	clear(&t.expanded)
	filetree_rebuild(editor)
}

filetree_toggle_expand_all :: proc(editor: ^Editor) {
	if filetree_any_expanded(&editor.filetree) {
		filetree_collapse_all(editor)
	} else {
		filetree_expand_all(editor)
	}
}

filetree_toggle_dotfiles :: proc(editor: ^Editor) {
	editor.filetree.show_dotfiles = !editor.filetree.show_dotfiles
	filetree_rebuild(editor)
}

filetree_toggle_ignored :: proc(editor: ^Editor) {
	editor.filetree.show_ignored = !editor.filetree.show_ignored
	filetree_rebuild(editor)
}

filetree_set_scope :: proc(editor: ^Editor, scope: FileTreeScope) {
	if editor.filetree.scope == scope {
		return
	}
	editor.filetree.scope = scope
	filetree_rebuild(editor)
}

filetree_tab_chord :: proc(editor: ^Editor, scope: FileTreeScope) {
	if editor.filetree.scope == scope {
		filetree_close(editor)
		return
	}
	filetree_set_scope(editor, scope)
}

filetree_cycle_scope :: proc(editor: ^Editor, delta: int) {
	next := clamp(int(editor.filetree.scope) + delta, 0, len(filetree_tabs) - 1)
	filetree_set_scope(editor, FileTreeScope(next))
}

filetree_activate :: proc(editor: ^Editor) {
	t := &editor.filetree
	lo, hi := filetree_sel_range(t)
	if hi > lo {
		filetree_open_range(editor, lo, hi)
		return
	}
	e, ok := filetree_selected(t)
	if !ok {
		return
	}
	if e.is_dir {
		if len(t.filter.text) > 0 {
			dir := strings.clone(e.path, context.temp_allocator)
			textfield_reset(&t.filter)
			filetree_set_expanded(t, dir, true)
			filetree_reveal(editor, dir)
			return
		}
		filetree_set_expanded(t, e.path, !filetree_dir_expanded(t, e.path))
		filetree_rebuild(editor)
		return
	}
	path := strings.clone(e.path, context.temp_allocator)
	filetree_close(editor)
	if editor_open_path(editor, path) {
		editor_scroll(editor)
	}
}

filetree_open_range :: proc(editor: ^Editor, lo, hi: int) {
	t := &editor.filetree
	paths := make([dynamic]string, context.temp_allocator)
	for i in lo ..= hi {
		if !t.entries[i].is_dir {
			append(&paths, strings.clone(t.entries[i].path, context.temp_allocator))
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
}

filetree_target_dir :: proc(editor: ^Editor) -> string {
	t := &editor.filetree
	e, ok := filetree_selected(t)
	if !ok {
		return editor.working_root
	}
	if e.is_dir {
		return e.path
	}
	return filetree_parent_dir(e.path)
}

filetree_reveal :: proc(editor: ^Editor, path: string) {
	t := &editor.filetree
	root := editor.working_root
	p := filetree_parent_dir(path)
	for strings.has_prefix(p, root) {
		filetree_set_expanded(t, p, true)
		if p == root {
			break
		}
		np := filetree_parent_dir(p)
		if np == p {
			break
		}
		p = np
	}
	filetree_refresh(editor)
	for e, i in t.entries {
		if e.path == path {
			t.selected = i
			filetree_scroll(editor)
			filetree_load_preview(editor)
			return
		}
	}
}

filetree_prompt_begin :: proc(editor: ^Editor, mode: FileTreeMode) {
	t := &editor.filetree
	t.mode = mode
	textfield_reset(&t.field)
	if mode == .Rename {
		if e, ok := filetree_selected(t); ok {
			textfield_set(&t.field, e.name)
		}
	}
	editor_clear_message(editor)
}

filetree_prompt_commit :: proc(editor: ^Editor) {
	t := &editor.filetree
	name := strings.trim_space(textfield_str(&t.field))
	mode := t.mode
	t.mode = .Nav
	if name == "" {
		editor_log(editor, .Error, "Files", "Empty name")
		return
	}
	switch mode {
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
			if os.make_directory_all(full, os.perm(0o755)) != nil {
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
		e, ok := filetree_selected(t)
		if !ok {
			return
		}
		full, _ := filepath.join({filetree_parent_dir(e.path), name}, context.temp_allocator)
		old := strings.clone(e.path, context.temp_allocator)
		path_ensure_parent_dir(full)
		if os.rename(old, full) != nil {
			editor_log(editor, .Error, "Files", "Rename failed")
			return
		}
		filetree_repath_buffers(editor, old, full)
		filetree_reveal(editor, full)
	case .Nav, .ConfirmDelete:
	}
}

filetree_repath_buffers :: proc(editor: ^Editor, old, new: string) {
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
		git_invalidate(&b)
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
	lo, hi := filetree_sel_range(t)
	if lo < 0 || lo >= len(t.entries) {
		return
	}
	filetree_clip_clear(t)
	for i in lo ..= hi {
		append(&t.clipboard, strings.clone(t.entries[i].path))
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
	if !os.exists(full) {
		return full
	}
	stem, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem, ext = name[:dot], name[dot:]
	}
	for i in 1 ..< 1000 {
		cand: string
		if i == 1 {
			cand = fmt.tprintf("%s (copy)%s", stem, ext)
		} else {
			cand = fmt.tprintf("%s (copy %d)%s", stem, i, ext)
		}
		full, _ = filepath.join({dir, cand}, context.temp_allocator)
		if !os.exists(full) {
			return full
		}
	}
	return full
}

filetree_fs_copy :: proc(src, dst: string) -> bool {
	info, serr := os.stat(src, context.temp_allocator)
	if os.is_dir(src) {
		if os.make_directory_all(dst, os.perm(0o755)) != nil {
			return false
		}
		if serr == nil {
			os.chmod(dst, info.mode)
		}
		infos, err := os.read_directory_by_path(src, -1, context.temp_allocator)
		if err != nil {
			return false
		}
		for child in infos {
			cdst, _ := filepath.join({dst, filepath.base(child.fullpath)}, context.temp_allocator)
			if !filetree_fs_copy(child.fullpath, cdst) {
				return false
			}
		}
		return true
	}
	data, rerr := os.read_entire_file(src, context.temp_allocator)
	if rerr != nil {
		return false
	}
	if os.write_entire_file(dst, data) != nil {
		return false
	}
	if serr == nil {
		os.chmod(dst, info.mode)
	}
	return true
}

filetree_clip_paste :: proc(editor: ^Editor) {
	t := &editor.filetree
	if len(t.clipboard) == 0 {
		editor_log(editor, .Info, "Files", "Nothing to paste")
		return
	}
	dst_dir := filetree_target_dir(editor)
	cut := t.clip_cut
	done := 0
	last := ""
	for src in t.clipboard {
		if !os.exists(src) {
			continue
		}
		dest := filetree_dest_path(dst_dir, filepath.base(src))
		if cut {
			if os.rename(src, dest) != nil {
				if !filetree_fs_copy(src, dest) {
					editor_log(editor, .Error, "Files", "Paste failed")
					continue
				}
				os.remove_all(src)
			}
			filetree_repath_buffers(editor, src, dest)
		} else if !filetree_fs_copy(src, dest) {
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

filetree_delete_commit :: proc(editor: ^Editor) {
	t := &editor.filetree
	t.mode = .Nav
	lo, hi := filetree_sel_range(t)
	if lo < 0 || lo >= len(t.entries) {
		return
	}
	paths := make([dynamic]string, context.temp_allocator)
	for i in lo ..= hi {
		append(&paths, strings.clone(t.entries[i].path, context.temp_allocator))
	}
	failed := 0
	for path in paths {
		if os.remove_all(path) != nil {
			failed += 1
		}
	}
	t.selected = max(0, lo - 1)
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

filetree_delete_actions := [?]string{"Cancel", "Delete"}

filetree_delete_close :: proc(editor: ^Editor) {
	editor.filetree.mode = .Nav
}

filetree_delete_execute :: proc(editor: ^Editor) {
	switch editor.filetree.delete_selected {
	case 0:
		filetree_delete_close(editor)
	case 1:
		filetree_delete_commit(editor)
	}
}

filetree_delete_question :: proc(t: ^FileTree) -> string {
	lo, hi := filetree_sel_range(t)
	if hi > lo {
		return fmt.tprintf("Delete %d items?", hi - lo + 1)
	}
	e, ok := filetree_selected(t)
	if !ok {
		return "Delete?"
	}
	if e.is_dir {
		return fmt.tprintf("Delete %s/ and its contents?", e.name)
	}
	return fmt.tprintf("Delete %s?", e.name)
}

filetree_prompt_key :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.filetree
	if t.mode == .ConfirmDelete {
		dialog_key(editor, ev, &t.delete_selected, len(filetree_delete_actions), filetree_delete_execute, filetree_delete_close)
		return
	}
	#partial switch ev.key {
	case .Esc:
		t.mode = .Nav
	case .Enter:
		filetree_prompt_commit(editor)
	case:
		textfield_key(&t.field, ev)
	}
}

filetree_paste :: proc(editor: ^Editor, text: string) {
	t := &editor.filetree
	#partial switch t.mode {
	case .New, .Rename:
		textfield_insert_flat(&t.field, text)
	case .Nav:
		if textfield_insert_flat(&t.filter, text) {
			filetree_rebuild(editor)
		}
	}
}

filetree_select_all :: proc(editor: ^Editor) {
	t := &editor.filetree
	if len(t.entries) == 0 {
		return
	}
	t.anchor = 0
	t.selected = len(t.entries) - 1
	filetree_scroll(editor)
	filetree_load_preview(editor)
}

filetree_cmd_copy :: proc(editor: ^Editor) {filetree_clip_capture(editor, false)}
filetree_cmd_cut :: proc(editor: ^Editor) {filetree_clip_capture(editor, true)}
filetree_cmd_rename :: proc(editor: ^Editor) {filetree_prompt_begin(editor, .Rename)}
filetree_cmd_new :: proc(editor: ^Editor) {filetree_prompt_begin(editor, .New)}

filetree_cmd_delete :: proc(editor: ^Editor) {
	t := &editor.filetree
	if _, ok := filetree_selected(t); ok {
		t.mode = .ConfirmDelete
		t.delete_selected = 0
	}
}

filetree_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.filetree
	if t.mode != .Nav {
		filetree_prompt_key(editor, ev)
		return
	}
	if command_matches(ev, "File Tree") {
		filetree_tab_chord(editor, .All)
		return
	}
	if command_matches(ev, "File Tree: Open") {
		filetree_tab_chord(editor, .Open)
		return
	}
	if command_matches(ev, "File Tree: Git") {
		filetree_tab_chord(editor, .Git)
		return
	}
	if command_matches(ev, "File Tree: Unsaved") {
		filetree_tab_chord(editor, .Unsaved)
		return
	}
	if ev_alt(ev) && ev.ch != 0 {
		switch ev.ch {
		case '.':
			filetree_toggle_dotfiles(editor)
		case 'i':
			filetree_toggle_ignored(editor)
		case 'e':
			filetree_toggle_expand_all(editor)
		}
		return
	}
	#partial switch ev.key {
	case .Ctrl_P:
		palette_open(editor)
		return
	case .Ctrl_C:
		filetree_cmd_copy(editor)
		return
	case .Ctrl_X:
		filetree_cmd_cut(editor)
		return
	case .Ctrl_V:
		filetree_clip_paste(editor)
		return
	case .Ctrl_D:
		filetree_cmd_delete(editor)
		return
	case .Ctrl_R:
		filetree_cmd_rename(editor)
		return
	case .Ctrl_N:
		filetree_cmd_new(editor)
		return
	case .Ctrl_A:
		filetree_select_all(editor)
		return
	case .Esc:
		if len(t.filter.text) > 0 {
			textfield_reset(&t.filter)
			filetree_rebuild(editor)
		} else {
			filetree_close(editor)
		}
		return
	case .Arrow_Down:
		filetree_move(editor, 1, ev_shift(ev))
		return
	case .Arrow_Up:
		filetree_move(editor, -1, ev_shift(ev))
		return
	case .Arrow_Right:
		filetree_cycle_scope(editor, 1)
		return
	case .Arrow_Left:
		filetree_cycle_scope(editor, -1)
		return
	case .Enter:
		filetree_activate(editor)
		return
	}
	if textfield_key(&t.filter, ev) {
		filetree_rebuild(editor)
	}
}

filetree_row_label :: proc(t: ^FileTree, e: FileEntry) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< e.depth {
		strings.write_string(&sb, "  ")
	}
	if e.is_dir {
		expanded := len(t.filter.text) == 0 && filetree_dir_expanded(t, e.path)
		strings.write_string(&sb, ICON_TREE_EXPANDED if expanded else ICON_TREE_COLLAPSED)
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, e.name)
		strings.write_byte(&sb, '/')
	} else {
		strings.write_string(&sb, "  ")
		strings.write_string(&sb, e.name)
	}
	return strings.to_string(sb)
}

filetree_render :: proc(editor: ^Editor) {
	t := &editor.filetree
	lay := filetree_layout(editor)
	inner := pane_draw_box(lay.box)

	filetree_render_tabs(t, inner, lay.tab_y)
	pane_hline(lay.box, lay.title_sep_y)
	overlay_prompt_render(inner.x + 1, lay.filter_y, lay.left_w - 1, &t.filter)
	if len(t.filter.text) == 0 {
		pane_text(inner.x + 3, lay.filter_y, lay.left_w - 4, "type to filter", COLOR_FILETREE_IGNORED, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.box.x), i32(lay.filter_sep_y), '├', COLOR_PANE_BORDER, COLOR_PANE_BG)
	for x in lay.inner.x ..< lay.div_x {
		tb2.set_cell(i32(x), i32(lay.filter_sep_y), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}

	sel_lo, sel_hi := filetree_sel_range(t)
	end := min(t.scroll + lay.body_h, len(t.entries))
	for i in t.scroll ..< end {
		e := t.entries[i]
		y := lay.body_top + (i - t.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		in_sel := i >= sel_lo && i <= sel_hi
		if in_sel {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x + 1, y, lay.left_w - 1, fg, bg)
		}
		if mark, ok := t.status[e.path]; ok {
			bar := COLOR_GIT_ADD if mark == .Added else COLOR_GIT_MOD
			tb2.set_cell(i32(inner.x), i32(y), '▌', bar, COLOR_PANE_BG)
		}
		if filetree_is_current(editor, e) {
			fg = COLOR_PANE_PROMPT_FG
		} else if !in_sel && filetree_is_ignored(t, e.path) {
			fg = COLOR_FILETREE_IGNORED
		}
		label := filetree_row_label(t, e)
		if filetree_unsaved(editor, e) {
			label = strings.concatenate({label, " ", ICON_MODIFIED}, context.temp_allocator)
		}
		pane_text(inner.x + 1, y, lay.left_w - 1, label, fg, bg)
	}

	preview_render(&t.preview, lay.right_x + 1, lay.preview_top, lay.right_w - 1, lay.preview_h)

	pane_hline(lay.box, lay.footer_sep_y)
	for y in lay.title_sep_y + 1 ..< lay.footer_sep_y {
		tb2.set_cell(i32(lay.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.title_sep_y), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.div_x), i32(lay.filter_sep_y), '┤', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.div_x), i32(lay.footer_sep_y), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)
	pane_draw_scrollbar(lay.div_x, lay.body_top, lay.body_h, t.scroll, len(t.entries))

	filetree_render_footer(editor, lay)

	if t.mode == .ConfirmDelete {
		dialog_render(editor, filetree_delete_question(t), filetree_delete_actions[:], t.delete_selected)
	}
}

filetree_render_tabs :: proc(t: ^FileTree, inner: Rect, y: int) {
	x := inner.x + 1
	for tab, i in filetree_tabs {
		if i > 0 {
			pane_text(x, y, 3, " │ ", COLOR_PANE_BORDER, COLOR_PANE_BG)
			x += 3
		}
		fg := COLOR_PANE_PROMPT_FG if t.scope == tab.scope else COLOR_PANE_SHORTCUT_FG
		pane_text(x, y, len(tab.label), tab.label, fg, COLOR_PANE_BG)
		x += len(tab.label)
	}
}

filetree_tab_at_x :: proc(inner: Rect, cx: int) -> (FileTreeScope, bool) {
	x := inner.x + 1
	for tab, i in filetree_tabs {
		if i > 0 {
			x += 3
		}
		if cx >= x && cx < x + len(tab.label) {
			return tab.scope, true
		}
		x += len(tab.label)
	}
	return .All, false
}

filetree_footer_label :: proc(mode: FileTreeMode) -> string {
	switch mode {
	case .New:
		return "New: "
	case .Rename:
		return "Rename: "
	case .Nav, .ConfirmDelete:
	}
	return ""
}

filetree_render_footer :: proc(editor: ^Editor, lay: FileTreeLayout) {
	t := &editor.filetree
	inner := lay.inner
	switch t.mode {
	case .Nav, .ConfirmDelete:
		pane_text(
			inner.x + 1,
			lay.footer_y,
			inner.w - 2,
			"←→ tabs  ↑↓ select  Shift+↑↓ extend  Ctrl+P commands",
			COLOR_PANE_SHORTCUT_FG,
			COLOR_PANE_BG,
		)
		return
	case .New, .Rename:
	}
	label := filetree_footer_label(t.mode)
	pane_text(inner.x + 1, lay.footer_y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner.x + 1 + len(label)
	tw := inner.x + inner.w - 1 - tx
	textfield_render(tx, lay.footer_y, tw, &t.field)
}

filetree_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.filetree
	if t.mode == .ConfirmDelete {
		dialog_mouse(editor, ev, filetree_delete_question(t), filetree_delete_actions[:], &t.delete_selected, filetree_delete_execute, filetree_delete_close)
		return
	}
	lay := filetree_layout(editor)
	motion := ev_motion(ev)
	if !mouse_in_rect(ev, lay.box) {
		if ev.key == .Mouse_Left && !motion {
			filetree_close(editor)
		}
		return
	}
	if t.mode != .Nav {
		if ev.key == .Mouse_Left {
			if label := filetree_footer_label(t.mode); label != "" {
				tx := lay.inner.x + 1 + len(label)
				tw := lay.inner.x + lay.inner.w - 1 - tx
				textfield_mouse(&t.field, tx, lay.footer_y, tw, ev)
			}
		}
		return
	}
	if preview_wheel(&t.preview, ev, {lay.right_x, lay.preview_top, lay.right_w, lay.preview_h}, lay.preview_h) {
		return
	}
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		overlay_scroll_by(&t.scroll, -WHEEL_SCROLL_LINES, len(t.entries), lay.body_h)
	case .Mouse_Wheel_Down:
		overlay_scroll_by(&t.scroll, WHEEL_SCROLL_LINES, len(t.entries), lay.body_h)
	case .Mouse_Left:
		if !motion && int(ev.y) == lay.tab_y {
			if scope, ok := filetree_tab_at_x(lay.inner, int(ev.x)); ok {
				filetree_set_scope(editor, scope)
			}
			return
		}
		if int(ev.y) == lay.filter_y {
			overlay_prompt_mouse(&t.filter, lay.inner.x + 1, lay.filter_y, lay.left_w - 1, ev)
			return
		}
		off := overlay_row_off(ev, Rect{lay.inner.x, lay.body_top, lay.left_w, lay.body_h})
		if off < 0 {
			return
		}
		idx := t.scroll + off
		if idx >= len(t.entries) {
			return
		}
		t.selected = idx
		filetree_load_preview(editor)
		if !motion && overlay_double_click(editor, idx) {
			filetree_activate(editor)
		}
	}
}
