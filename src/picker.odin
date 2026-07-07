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
	colors:     [dynamic][dynamic]tb2.Color,
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
	for &row in p.colors {
		delete(row)
	}
	clear(&p.colors)
}

picker_destroy :: proc(p: ^Picker) {
	fuzzy_list_destroy(&p.list)
	picker_clear_files(p)
	picker_clear_preview(p)
	delete(p.files)
	delete(p.preview)
	delete(p.colors)
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
	lines := max(1, overlay_layout(editor).body_h)
	cmd := fmt.ctprintf("head -n %d %s 2>/dev/null", lines, shell_quote(full))
	out, ok := shell_capture(cmd)
	if !ok {
		return
	}
	for line in strings.split_lines_iterator(&out) {
		append(&p.preview, strings.clone(line))
	}
	highlight_lines(language_of(rel), p.preview[:], &p.colors)
}

picker_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.picker
	fuzzy_list_move(&p.list, delta, overlay_layout(editor).body_h)
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
	case:
		if textfield_key(&p.field, ev) {
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

picker_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.picker
	idx, activate := overlay_list_mouse(editor, ev, overlay_layout(editor), len(p.matches), &p.scroll, &p.field, picker_close)
	if idx < 0 {
		return
	}
	p.selected = idx
	picker_load_preview(editor)
	if activate {
		picker_open_selected(editor)
	}
}

picker_render :: proc(editor: ^Editor) {
	p := &editor.picker
	lay := overlay_layout(editor)
	inner := pane_draw_box(lay.box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &p.field)
	pane_hline(lay.box, lay.title_sep_y)

	end := min(p.scroll + lay.body_h, len(p.matches))
	for i in p.scroll ..< end {
		rel := p.files[p.matches[i]]
		y := lay.body_top + (i - p.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, lay.left_w, fg, bg)
		}
		label := rel
		if picker_file_modified(editor, rel) {
			label = fmt.tprintf("%s ●", rel)
		}
		pane_text(inner.x + 1, y, lay.left_w - 1, label, fg, bg)
	}

	for line, i in p.preview {
		if i >= lay.body_h {
			break
		}
		colors := p.colors[i][:] if i < len(p.colors) else nil
		pane_text_colored(lay.right_x + 1, lay.body_top + i, lay.right_w - 1, line, colors, 0, COLOR_PANE_FG, COLOR_PANE_BG)
	}

	overlay_divider(lay)
}
