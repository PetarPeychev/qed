package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

FileTool :: enum {
	Unknown,
	Fd,
	Fdfind,
	Find,
}

file_tool: FileTool = .Unknown

file_tool_detect :: proc() {
	switch {
	case shell_command_exists("fd"):
		file_tool = .Fd
	case shell_command_exists("fdfind"):
		file_tool = .Fdfind
	case:
		file_tool = .Find
	}
}

files_list :: proc(root: string, out: ^[dynamic]string) {
	if file_tool == .Unknown {
		file_tool_detect()
	}
	qroot := shell_quote(root)
	cmd: cstring
	switch file_tool {
	case .Fd:
		cmd = fmt.ctprintf("cd %s && fd --type f 2>/dev/null", qroot)
	case .Fdfind:
		cmd = fmt.ctprintf("cd %s && fdfind --type f 2>/dev/null", qroot)
	case .Find, .Unknown:
		cmd = fmt.ctprintf("cd %s && find . -type f -not -path './.git/*' 2>/dev/null", qroot)
	}
	result, ok := shell_capture(cmd)
	if !ok {
		return
	}
	for line in strings.split_lines_iterator(&result) {
		path := line
		if len(path) >= 2 && path[0] == '.' && path[1] == '/' {
			path = path[2:]
		}
		if len(path) == 0 {
			continue
		}
		append(out, strings.clone(path))
	}
}

Picker :: struct {
	active:   bool,
	query:    [dynamic]u8,
	files:    [dynamic]string,
	matches:  [dynamic]int,
	selected: int,
	scroll:   int,
	fuzzy:    Fuzzy,
	preview:  [dynamic]string,
}

picker_clear_files :: proc(p: ^Picker) {
	for s in p.files {
		delete(s)
	}
	clear(&p.files)
}

picker_clear_preview :: proc(p: ^Picker) {
	for s in p.preview {
		delete(s)
	}
	clear(&p.preview)
}

picker_destroy :: proc(p: ^Picker) {
	fuzzy_end(&p.fuzzy)
	picker_clear_files(p)
	picker_clear_preview(p)
	delete(p.files)
	delete(p.preview)
	delete(p.query)
	delete(p.matches)
}

picker_open :: proc(editor: ^Editor) {
	p := &editor.picker
	p.active = true
	clear(&p.query)
	p.selected = 0
	p.scroll = 0
	editor.message = ""
	editor.message_error = false

	picker_clear_files(p)
	files_list(editor.working_root, &p.files)
	p.fuzzy = fuzzy_begin(p.files[:])
	picker_filter(editor)
	picker_load_preview(editor)
}

picker_close :: proc(editor: ^Editor) {
	p := &editor.picker
	p.active = false
	fuzzy_end(&p.fuzzy)
	picker_clear_files(p)
	picker_clear_preview(p)
}

picker_filter :: proc(editor: ^Editor) {
	p := &editor.picker
	clear(&p.matches)
	p.selected = 0
	p.scroll = 0
	ranked := fuzzy_rank(&p.fuzzy, string(p.query[:]))
	for idx in ranked {
		append(&p.matches, idx)
	}
}

PickerLayout :: struct {
	box:         Rect,
	inner:       Rect,
	list_top:    int,
	list_h:      int,
	sep_y:       int,
	preview_top: int,
	preview_h:   int,
}

picker_layout :: proc(editor: ^Editor) -> PickerLayout {
	sw := int(tb2.width())
	sh := int(tb2.height())
	if !editor.welcome {
		sh -= STATUS_ROWS
	}
	box := Rect{PICKER_MARGIN_X, PICKER_MARGIN_Y, max(0, sw - 2 * PICKER_MARGIN_X), max(0, sh - 2 * PICKER_MARGIN_Y)}
	inner := Rect{box.x + 1, box.y + 1, box.w - 2, box.h - 2}
	list_top := inner.y + 2
	body_h := inner.h - 2
	list_h := max(0, body_h / 2)
	sep_y := list_top + list_h
	preview_top := sep_y + 1
	preview_h := max(0, body_h - list_h - 1)
	return {box, inner, list_top, list_h, sep_y, preview_top, preview_h}
}

picker_load_preview :: proc(editor: ^Editor) {
	p := &editor.picker
	picker_clear_preview(p)
	if len(p.matches) == 0 {
		return
	}
	rel := p.files[p.matches[p.selected]]
	full, _ := filepath.join({editor.working_root, rel}, context.temp_allocator)
	lines := max(1, picker_layout(editor).preview_h)
	cmd := fmt.ctprintf("head -n %d %s 2>/dev/null", lines, shell_quote(full))
	out, ok := shell_capture(cmd)
	if !ok {
		return
	}
	for line in strings.split_lines_iterator(&out) {
		append(&p.preview, strings.clone(line))
	}
}

picker_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.picker
	if len(p.matches) == 0 {
		return
	}
	p.selected = clamp(p.selected + delta, 0, len(p.matches) - 1)
	list_h := picker_layout(editor).list_h
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if list_h > 0 && p.selected >= p.scroll + list_h {
		p.scroll = p.selected - list_h + 1
	}
	picker_load_preview(editor)
}

picker_open_selected :: proc(editor: ^Editor) {
	p := &editor.picker
	if len(p.matches) == 0 {
		picker_close(editor)
		return
	}
	rel := p.files[p.matches[p.selected]]
	full, _ := filepath.join({editor.working_root, rel}, context.temp_allocator)
	picker_close(editor)
	editor_open_path(editor, full)
	editor_scroll(editor)
}

picker_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.picker
	#partial switch ev.key {
	case .Esc, .Ctrl_O:
		picker_close(editor)
	case .Enter:
		picker_open_selected(editor)
	case .Arrow_Down:
		picker_move(editor, 1)
	case .Arrow_Up:
		picker_move(editor, -1)
	case .Pgdn:
		picker_move(editor, picker_layout(editor).list_h)
	case .Pgup:
		picker_move(editor, -picker_layout(editor).list_h)
	case .Backspace, .Backspace2:
		if len(p.query) > 0 {
			resize(&p.query, len(p.query) - 1)
			picker_filter(editor)
			picker_load_preview(editor)
		}
	case:
		if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			append(&p.query, ..bytes[:n])
			picker_filter(editor)
			picker_load_preview(editor)
		}
	}
}

picker_file_modified :: proc(editor: ^Editor, rel: string) -> bool {
	full, _ := filepath.join({editor.working_root, rel}, context.temp_allocator)
	abs, err := filepath.abs(full, context.temp_allocator)
	if err != nil {
		abs = full
	}
	idx := editor_find_buffer(editor, abs)
	return idx >= 0 && editor.buffers[idx].modified
}

picker_render :: proc(editor: ^Editor) {
	p := &editor.picker
	lay := picker_layout(editor)
	inner := pane_draw_box(lay.box)

	prompt := fmt.tprintf("> %s", string(p.query[:]))
	pane_text(inner.x + 1, inner.y, inner.w - 2, prompt, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_hline(lay.box, inner.y + 1)

	end := min(p.scroll + lay.list_h, len(p.matches))
	for i in p.scroll ..< end {
		rel := p.files[p.matches[i]]
		y := lay.list_top + (i - p.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		label := rel
		if picker_file_modified(editor, rel) {
			label = fmt.tprintf("%s [*]", rel)
		}
		pane_text(inner.x + 1, y, inner.w - 2, label, fg, bg)
	}

	pane_hline(lay.box, lay.sep_y)

	for line, i in p.preview {
		if i >= lay.preview_h {
			break
		}
		pane_text(inner.x + 1, lay.preview_top + i, inner.w - 2, line, COLOR_PANE_FG, COLOR_PANE_BG)
	}

	cx := min(inner.x + 3 + len(p.query), inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(inner.y))
}
