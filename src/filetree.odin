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
	NewFile,
	NewFolder,
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
	active:   bool,
	entries:  [dynamic]FileEntry,
	expanded: map[string]bool,
	selected: int,
	scroll:   int,
	mode:     FileTreeMode,
	field:    TextField,
	preview:  [dynamic]string,
	colors:   [dynamic][dynamic]tb2.Color,
	status:   map[string]GitMark,
	ignored:  map[string]bool,
	show_dotfiles: bool,
	show_ignored:  bool,
	scope:         FileTreeScope,
	scope_paths:   map[string]bool,
}

FileTreeLayout :: struct {
	box, inner:                        Rect,
	body_top, body_h, footer_y:        int,
	name_sep_y, tab_y:                 int,
	title_sep_y, footer_sep_y, div_x:  int,
	left_w, right_x, right_w:          int,
}

filetree_layout :: proc(editor: ^Editor) -> FileTreeLayout {
	lay := overlay_layout(editor)
	inner := lay.inner
	name_sep_y := inner.y + 1
	tab_y := inner.y + 2
	title_sep_y := inner.y + 3
	body_top := inner.y + 4
	footer_sep_y := inner.y + inner.h - 2
	footer_y := inner.y + inner.h - 1
	body_h := max(1, footer_sep_y - body_top)
	left_w := (inner.w - 1) / 2
	div_x := inner.x + left_w
	right_x := div_x + 1
	right_w := max(0, inner.x + inner.w - right_x)
	return FileTreeLayout {
		box = lay.box,
		inner = inner,
		body_top = body_top,
		body_h = body_h,
		footer_y = footer_y,
		name_sep_y = name_sep_y,
		tab_y = tab_y,
		title_sep_y = title_sep_y,
		footer_sep_y = footer_sep_y,
		div_x = div_x,
		left_w = left_w,
		right_x = right_x,
		right_w = right_w,
	}
}

filetree_destroy :: proc(t: ^FileTree) {
	filetree_clear_entries(t)
	delete(t.entries)
	for key in t.expanded {
		delete(key)
	}
	delete(t.expanded)
	textfield_destroy(&t.field)
	filetree_clear_preview(t)
	delete(t.preview)
	delete(t.colors)
	filetree_clear_status(t)
	delete(t.status)
	delete(t.ignored)
	filetree_clear_scope(t)
	delete(t.scope_paths)
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

filetree_scan_status :: proc(editor: ^Editor) {
	t := &editor.filetree
	filetree_clear_status(t)
	root := editor.working_root
	if root == "" || !shell_command_exists("git") {
		return
	}
	top_cmd := fmt.ctprintf("git -C %s rev-parse --show-toplevel 2>/dev/null", shell_quote(root))
	top, top_ok := shell_capture(top_cmd)
	top = strings.trim_space(top)
	if !top_ok || top == "" {
		return
	}
	status_cmd := fmt.ctprintf("git -C %s status --porcelain --ignored 2>/dev/null", shell_quote(root))
	out, ok := shell_capture(status_cmd)
	if !ok {
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

filetree_clear_scope :: proc(t: ^FileTree) {
	for key in t.scope_paths {
		delete(key)
	}
	clear(&t.scope_paths)
}

filetree_scope_set :: proc(t: ^FileTree, path: string) {
	if path not_in t.scope_paths {
		t.scope_paths[strings.clone(path)] = true
	}
}

filetree_scope_add :: proc(t: ^FileTree, root, path: string) {
	filetree_scope_set(t, path)
	p := path
	for strings.has_prefix(p, root) && p != root {
		np := filetree_parent_dir(p)
		if np == p {
			break
		}
		p = np
		filetree_scope_set(t, p)
	}
}

filetree_build_scope :: proc(editor: ^Editor) {
	t := &editor.filetree
	filetree_clear_scope(t)
	root := editor.working_root
	switch t.scope {
	case .All:
	case .Git:
		for path in t.status {
			filetree_scope_set(t, path)
		}
	case .Open:
		for &b in editor.buffers {
			if b.path != "" && os.exists(b.path) {
				filetree_scope_add(t, root, b.path)
			}
		}
	case .Unsaved:
		for &b in editor.buffers {
			if b.modified && b.path != "" && os.exists(b.path) {
				filetree_scope_add(t, root, b.path)
			}
		}
	}
}

filetree_clear_entries :: proc(t: ^FileTree) {
	for e in t.entries {
		delete(e.path)
	}
	clear(&t.entries)
}

filetree_clear_preview :: proc(t: ^FileTree) {
	for s in t.preview {
		delete(s)
	}
	clear(&t.preview)
	for &row in t.colors {
		delete(row)
	}
	clear(&t.colors)
}

filetree_load_preview :: proc(editor: ^Editor) {
	t := &editor.filetree
	filetree_clear_preview(t)
	e, ok := filetree_selected(t)
	if !ok || e.is_dir {
		return
	}
	lines := filetree_layout(editor).body_h
	cmd := fmt.ctprintf("head -n %d %s 2>/dev/null", lines, shell_quote(e.path))
	out, got := shell_capture(cmd)
	if !got {
		return
	}
	for line in strings.split_lines_iterator(&out) {
		append(&t.preview, strings.clone(line))
	}
	highlight_lines(language_of(e.path), t.preview[:], &t.colors)
}

filetree_set_expanded :: proc(t: ^FileTree, path: string, val: bool) {
	if path in t.expanded {
		t.expanded[path] = val
	} else if val {
		t.expanded[strings.clone(path)] = true
	}
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
		append(&rows, Row{info.fullpath, os.is_dir(info.fullpath)})
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
		if r.is_dir && (scoped || t.expanded[path]) {
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
	filetree_scan_status(editor)
	filetree_build_scope(editor)
	filetree_read_dir(t, editor.working_root, 0)
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

filetree_move :: proc(editor: ^Editor, delta: int) {
	t := &editor.filetree
	n := len(t.entries)
	if n == 0 {
		return
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
	editor_set_message(editor, "")
	filetree_rebuild(editor)
}

filetree_close :: proc(editor: ^Editor) {
	editor.filetree.active = false
	editor.filetree.mode = .Nav
	filetree_clear_preview(&editor.filetree)
}

filetree_mark_expanded :: proc(t: ^FileTree, dir: string) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		if !os.is_dir(info.fullpath) || filetree_is_ignored(t, info.fullpath) {
			continue
		}
		if !t.show_dotfiles && strings.has_prefix(filepath.base(info.fullpath), ".") {
			continue
		}
		filetree_set_expanded(t, info.fullpath, true)
		filetree_mark_expanded(t, info.fullpath)
	}
}

filetree_expand_all :: proc(editor: ^Editor) {
	t := &editor.filetree
	filetree_scan_status(editor)
	filetree_mark_expanded(t, editor.working_root)
	filetree_rebuild(editor)
}

filetree_collapse_all :: proc(editor: ^Editor) {
	t := &editor.filetree
	for key in t.expanded {
		delete(key)
	}
	clear(&t.expanded)
	filetree_rebuild(editor)
}

filetree_toggle_expand_all :: proc(editor: ^Editor) {
	t := &editor.filetree
	for _, open in t.expanded {
		if open {
			filetree_collapse_all(editor)
			return
		}
	}
	filetree_expand_all(editor)
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

filetree_cycle_scope :: proc(editor: ^Editor, delta: int) {
	next := clamp(int(editor.filetree.scope) + delta, 0, len(filetree_tabs) - 1)
	filetree_set_scope(editor, FileTreeScope(next))
}

filetree_activate :: proc(editor: ^Editor) {
	t := &editor.filetree
	e, ok := filetree_selected(t)
	if !ok {
		return
	}
	if e.is_dir {
		filetree_set_expanded(t, e.path, !t.expanded[e.path])
		filetree_rebuild(editor)
		return
	}
	path := strings.clone(e.path, context.temp_allocator)
	filetree_close(editor)
	editor_open_path(editor, path)
	editor_scroll(editor)
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
	filetree_rebuild(editor)
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
	editor_set_message(editor, "")
}

filetree_prompt_commit :: proc(editor: ^Editor) {
	t := &editor.filetree
	name := strings.trim_space(textfield_str(&t.field))
	mode := t.mode
	t.mode = .Nav
	if name == "" {
		editor_set_message(editor, "Empty name", true)
		return
	}
	switch mode {
	case .NewFile:
		full, _ := filepath.join({filetree_target_dir(editor), name}, context.temp_allocator)
		if os.exists(full) {
			editor_set_message(editor, "Already exists", true)
			return
		}
		f, err := os.open(full, {.Write, .Create, .Excl}, os.perm(0o644))
		if err != nil {
			editor_set_message(editor, "Create failed", true)
			return
		}
		os.close(f)
		filetree_reveal(editor, full)
	case .NewFolder:
		full, _ := filepath.join({filetree_target_dir(editor), name}, context.temp_allocator)
		if os.exists(full) {
			editor_set_message(editor, "Already exists", true)
			return
		}
		if os.make_directory(full) != nil {
			editor_set_message(editor, "Create failed", true)
			return
		}
		filetree_reveal(editor, full)
	case .Rename:
		e, ok := filetree_selected(t)
		if !ok {
			return
		}
		full, _ := filepath.join({filetree_parent_dir(e.path), name}, context.temp_allocator)
		old := strings.clone(e.path, context.temp_allocator)
		if os.rename(old, full) != nil {
			editor_set_message(editor, "Rename failed", true)
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

filetree_delete_commit :: proc(editor: ^Editor) {
	t := &editor.filetree
	e, ok := filetree_selected(t)
	t.mode = .Nav
	if !ok {
		return
	}
	path := strings.clone(e.path, context.temp_allocator)
	if os.remove_all(path) != nil {
		editor_set_message(editor, "Delete failed", true)
		return
	}
	t.selected = max(0, t.selected - 1)
	filetree_rebuild(editor)
	editor_set_message(editor, "Deleted")
}

filetree_prompt_key :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.filetree
	if t.mode == .ConfirmDelete {
		if ev.ch == 'y' || ev.ch == 'Y' {
			filetree_delete_commit(editor)
		} else {
			t.mode = .Nav
		}
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

filetree_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.filetree
	if t.mode != .Nav {
		filetree_prompt_key(editor, ev)
		return
	}
	if (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0 && ev.ch == 'f' {
		filetree_close(editor)
		return
	}
	#partial switch ev.key {
	case .Esc:
		filetree_close(editor)
	case .Arrow_Down:
		filetree_move(editor, 1)
	case .Arrow_Up:
		filetree_move(editor, -1)
	case .Arrow_Right:
		filetree_cycle_scope(editor, 1)
	case .Arrow_Left:
		filetree_cycle_scope(editor, -1)
	case .Enter:
		filetree_activate(editor)
	case:
		switch ev.ch {
		case 'n':
			filetree_prompt_begin(editor, .NewFile)
		case 'N':
			filetree_prompt_begin(editor, .NewFolder)
		case 'r':
			filetree_prompt_begin(editor, .Rename)
		case 'd':
			if _, ok := filetree_selected(t); ok {
				t.mode = .ConfirmDelete
			}
		case 'e':
			filetree_toggle_expand_all(editor)
		case '.':
			filetree_toggle_dotfiles(editor)
		case 'i':
			filetree_toggle_ignored(editor)
		}
	}
}

filetree_row_label :: proc(t: ^FileTree, e: FileEntry) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< e.depth {
		strings.write_string(&sb, "  ")
	}
	if e.is_dir {
		strings.write_string(&sb, "▾ " if t.expanded[e.path] else "▸ ")
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

	root := editor.working_root
	title := root
	if idx := strings.last_index_byte(root, '/'); idx >= 0 {
		title = root[idx + 1:]
	}
	pane_text(inner.x + 1, inner.y, lay.left_w - 1, strings.concatenate({title, "/"}, context.temp_allocator), COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	if e, ok := filetree_selected(t); ok && !e.is_dir {
		pane_text(lay.right_x + 1, inner.y, lay.right_w - 1, e.name, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	pane_hline(lay.box, lay.name_sep_y)
	filetree_render_tabs(t, inner, lay.tab_y)
	pane_hline(lay.box, lay.title_sep_y)

	end := min(t.scroll + lay.body_h, len(t.entries))
	for i in t.scroll ..< end {
		e := t.entries[i]
		y := lay.body_top + (i - t.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == t.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x + 1, y, lay.left_w - 1, fg, bg)
		}
		if mark, ok := t.status[e.path]; ok {
			bar := COLOR_GIT_ADD if mark == .Added else COLOR_GIT_MOD
			tb2.set_cell(i32(inner.x), i32(y), '▌', bar, COLOR_PANE_BG)
		}
		if i != t.selected && filetree_is_ignored(t, e.path) {
			fg = COLOR_FILETREE_IGNORED
		}
		label := filetree_row_label(t, e)
		if filetree_unsaved(editor, e) {
			label = strings.concatenate({label, " ●"}, context.temp_allocator)
		}
		pane_text(inner.x + 1, y, lay.left_w - 1, label, fg, bg)
	}

	for line, i in t.preview {
		if i >= lay.body_h {
			break
		}
		colors := t.colors[i][:] if i < len(t.colors) else nil
		pane_text_colored(lay.right_x + 1, lay.body_top + i, lay.right_w - 1, line, colors, 0, COLOR_PANE_FG, COLOR_PANE_BG)
	}

	pane_hline(lay.box, lay.footer_sep_y)
	for y in lay.body_top ..< lay.footer_sep_y {
		tb2.set_cell(i32(lay.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.title_sep_y), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.div_x), i32(lay.footer_sep_y), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)

	filetree_render_footer(editor, inner, lay.footer_y)
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
	pane_text(x, y, 5, "  ←→", COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
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
	case .NewFile:
		return "New file: "
	case .NewFolder:
		return "New folder: "
	case .Rename:
		return "Rename: "
	case .Nav, .ConfirmDelete:
	}
	return ""
}

filetree_render_footer :: proc(editor: ^Editor, inner: Rect, y: int) {
	t := &editor.filetree
	prompt := ""
	switch t.mode {
	case .Nav:
		any_expanded := false
		for _, open in t.expanded {
			if open {
				any_expanded = true
				break
			}
		}
		Toggle :: struct {
			label: string,
			on:    bool,
		}
		toggles := [?]Toggle{{"e expand", any_expanded}, {". dotfiles", t.show_dotfiles}, {"i ignored", t.show_ignored}}
		total := 0
		for tg, i in toggles {
			total += len(tg.label)
			if i > 0 {
				total += 2
			}
		}
		tx := inner.x + inner.w - 1 - total
		actions_w := max(0, tx - (inner.x + 1) - 1)
		pane_text(inner.x + 1, y, actions_w, "n new  N folder  r rename  d delete", COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
		for tg in toggles {
			fg := COLOR_PANE_PROMPT_FG if tg.on else COLOR_PANE_SHORTCUT_FG
			pane_text(tx, y, len(tg.label), tg.label, fg, COLOR_PANE_BG)
			tx += len(tg.label) + 2
		}
		tb2.hide_cursor()
		return
	case .NewFile, .NewFolder, .Rename:
	case .ConfirmDelete:
		if e, ok := filetree_selected(t); ok {
			if e.is_dir {
				prompt = strings.concatenate({"Delete ", e.name, "/ and its contents? (y/n)"}, context.temp_allocator)
			} else {
				prompt = strings.concatenate({"Delete ", e.name, "? (y/n)"}, context.temp_allocator)
			}
		}
		pane_text(inner.x + 1, y, inner.w - 2, prompt, COLOR_ERROR_FG, COLOR_PANE_BG)
		tb2.hide_cursor()
		return
	}
	label := filetree_footer_label(t.mode)
	pane_text(inner.x + 1, y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner.x + 1 + len(label)
	tw := inner.x + inner.w - 1 - tx
	textfield_render(tx, y, tw, &t.field)
}

filetree_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.filetree
	lay := filetree_layout(editor)
	motion := overlay_ev_motion(ev)
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
