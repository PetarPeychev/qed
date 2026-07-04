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
	input:    [dynamic]u8,
	caret:    int,
	preview:  [dynamic]string,
}

FileTreeLayout :: struct {
	box, inner:                            Rect,
	body_top, body_h, footer_y:           int,
	title_sep_y, footer_sep_y, div_x:     int,
	left_w, right_x, right_w:             int,
}

filetree_layout :: proc(editor: ^Editor) -> FileTreeLayout {
	lay := overlay_layout(editor)
	inner := lay.inner
	title_sep_y := inner.y + 1
	body_top := inner.y + 2
	footer_sep_y := inner.y + inner.h - 2
	footer_y := inner.y + inner.h - 1
	body_h := max(1, footer_sep_y - body_top)
	left_w := (inner.w - 1) / 2
	div_x := inner.x + left_w
	right_x := div_x + 1
	right_w := max(0, inner.x + inner.w - right_x)
	return {lay.box, inner, body_top, body_h, footer_y, title_sep_y, footer_sep_y, div_x, left_w, right_x, right_w}
}

filetree_destroy :: proc(t: ^FileTree) {
	filetree_clear_entries(t)
	delete(t.entries)
	for key in t.expanded {
		delete(key)
	}
	delete(t.expanded)
	delete(t.input)
	filetree_clear_preview(t)
	delete(t.preview)
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
	for r in rows {
		path := strings.clone(r.path)
		name := path
		if idx := strings.last_index_byte(path, '/'); idx >= 0 {
			name = path[idx + 1:]
		}
		append(&t.entries, FileEntry{path, name, depth, r.is_dir})
		if r.is_dir && t.expanded[path] {
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
	t.scroll = max(0, t.scroll)
}

filetree_move :: proc(editor: ^Editor, delta: int) {
	t := &editor.filetree
	if len(t.entries) == 0 {
		return
	}
	t.selected = clamp(t.selected + delta, 0, len(t.entries) - 1)
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
	clear(&t.input)
	t.caret = 0
	editor_set_message(editor, "")
	filetree_rebuild(editor)
}

filetree_close :: proc(editor: ^Editor) {
	editor.filetree.active = false
	editor.filetree.mode = .Nav
	filetree_clear_preview(&editor.filetree)
}

filetree_expand :: proc(editor: ^Editor) {
	t := &editor.filetree
	e, ok := filetree_selected(t)
	if !ok || !e.is_dir || t.expanded[e.path] {
		return
	}
	filetree_set_expanded(t, e.path, true)
	filetree_rebuild(editor)
}

filetree_collapse :: proc(editor: ^Editor) {
	t := &editor.filetree
	e, ok := filetree_selected(t)
	if !ok {
		return
	}
	if e.is_dir && t.expanded[e.path] {
		filetree_set_expanded(t, e.path, false)
		filetree_rebuild(editor)
		return
	}
	parent := filetree_parent_dir(e.path)
	for entry, i in t.entries {
		if entry.path == parent {
			t.selected = i
			filetree_scroll(editor)
			filetree_load_preview(editor)
			return
		}
	}
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
	clear(&t.input)
	if mode == .Rename {
		if e, ok := filetree_selected(t); ok {
			append(&t.input, ..transmute([]u8)e.name)
		}
	}
	t.caret = len(t.input)
	editor_set_message(editor, "")
}

filetree_prompt_commit :: proc(editor: ^Editor) {
	t := &editor.filetree
	name := strings.trim_space(string(t.input[:]))
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
	case .Arrow_Left:
		if t.caret > 0 {
			t.caret = grapheme_prev(t.input[:], t.caret)
		}
	case .Arrow_Right:
		if t.caret < len(t.input) {
			t.caret = grapheme_next(t.input[:], t.caret)
		}
	case .Home:
		t.caret = 0
	case .End:
		t.caret = len(t.input)
	case .Backspace, .Backspace2:
		if t.caret > 0 {
			prev := grapheme_prev(t.input[:], t.caret)
			remove_range(&t.input, prev, t.caret)
			t.caret = prev
		}
	case .Delete:
		if t.caret < len(t.input) {
			remove_range(&t.input, t.caret, grapheme_next(t.input[:], t.caret))
		}
	case:
		if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			inject_at(&t.input, t.caret, ..bytes[:n])
			t.caret += n
		}
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
	case .Pgdn:
		filetree_move(editor, filetree_layout(editor).body_h)
	case .Pgup:
		filetree_move(editor, -filetree_layout(editor).body_h)
	case .Arrow_Right:
		filetree_expand(editor)
	case .Arrow_Left:
		filetree_collapse(editor)
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
	pane_hline(lay.box, lay.title_sep_y)

	end := min(t.scroll + lay.body_h, len(t.entries))
	for i in t.scroll ..< end {
		e := t.entries[i]
		y := lay.body_top + (i - t.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == t.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, lay.left_w, fg, bg)
		}
		pane_text(inner.x + 1, y, lay.left_w - 1, filetree_row_label(t, e), fg, bg)
	}

	for line, i in t.preview {
		if i >= lay.body_h {
			break
		}
		pane_text(lay.right_x + 1, lay.body_top + i, lay.right_w - 1, line, COLOR_PANE_FG, COLOR_PANE_BG)
	}

	pane_hline(lay.box, lay.footer_sep_y)
	for y in lay.body_top ..< lay.footer_sep_y {
		tb2.set_cell(i32(lay.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.title_sep_y), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.div_x), i32(lay.footer_sep_y), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)

	filetree_render_footer(editor, inner, lay.footer_y)
}

filetree_render_footer :: proc(editor: ^Editor, inner: Rect, y: int) {
	t := &editor.filetree
	label, prompt := "", ""
	switch t.mode {
	case .Nav:
		pane_text(inner.x + 1, y, inner.w - 2, "n new  N folder  r rename  d delete", COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
		tb2.hide_cursor()
		return
	case .NewFile:
		label = "New file: "
	case .NewFolder:
		label = "New folder: "
	case .Rename:
		label = "Rename: "
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
	pane_text(inner.x + 1, y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner.x + 1 + len(label)
	tw := inner.x + inner.w - 1 - tx
	pane_text(tx, y, tw, string(t.input[:]), COLOR_PANE_FG, COLOR_PANE_BG)
	cx := min(tx + visual_width(t.input[:t.caret]), inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(y))
}
