package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
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
	using list: FuzzyList,
	files:      [dynamic]string,
	preview:    [dynamic]string,
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
	fuzzy_list_destroy(&p.list)
	picker_clear_files(p)
	picker_clear_preview(p)
	delete(p.files)
	delete(p.preview)
}

picker_open :: proc(editor: ^Editor) {
	p := &editor.picker
	p.active = true
	fuzzy_list_reset(&p.list)
	editor_set_message(editor, "")

	picker_clear_files(p)
	files_list(editor.working_root, &p.files)
	p.fuzzy = fuzzy_begin(p.files[:])
	fuzzy_list_refilter(&p.list)
	picker_load_preview(editor)
}

picker_close :: proc(editor: ^Editor) {
	p := &editor.picker
	p.active = false
	fuzzy_end(&p.fuzzy)
	picker_clear_files(p)
	picker_clear_preview(p)
}

picker_load_preview :: proc(editor: ^Editor) {
	p := &editor.picker
	picker_clear_preview(p)
	if len(p.matches) == 0 {
		return
	}
	rel := p.files[p.matches[p.selected]]
	full, _ := filepath.join({editor.working_root, rel}, context.temp_allocator)
	lines := max(1, overlay_layout(editor).preview_h)
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
	fuzzy_list_move_clamp(&p.list, delta, overlay_layout(editor).list_h)
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
		picker_move(editor, overlay_layout(editor).list_h)
	case .Pgup:
		picker_move(editor, -overlay_layout(editor).list_h)
	case:
		if query_edit_key(&p.query, ev) {
			fuzzy_list_refilter(&p.list)
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
	lay := overlay_layout(editor)
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

	overlay_cursor(inner, len(p.query))
}
