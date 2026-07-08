package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "lib:tb2"

LineFind :: struct {
	using list: FuzzyList,
	lines:      [dynamic]string,
	preview:    Preview,
}

linefind_destroy :: proc(p: ^LineFind) {
	fuzzy_list_destroy(&p.list)
	preview_destroy(&p.preview)
	delete(p.lines)
}

linefind_refilter :: proc(p: ^LineFind) {
	fuzzy_list_refilter(&p.list)
	slice.sort(p.matches[:])
}

linefind_open :: proc(editor: ^Editor) {
	p := &editor.linefind
	p.active = true
	textfield_select_all(&p.field)
	editor_set_message(editor, "")

	b := editor_buffer(editor)
	clear(&p.lines)
	for &line in b.lines {
		append(&p.lines, string(line.text[:]))
	}
	p.fuzzy = fuzzy_begin(p.lines[:])
	linefind_refilter(p)

	p.selected = 0
	best := max(int)
	for row, i in p.matches {
		if d := abs(row - b.cursor.row); d < best {
			best = d
			p.selected = i
		}
	}
	body_h := overlay_layout(editor).body_h
	p.scroll = max(0, p.selected - body_h / 2)
	linefind_load_preview(editor)
}

linefind_close :: proc(editor: ^Editor) {
	p := &editor.linefind
	p.active = false
	fuzzy_end(&p.fuzzy)
	clear(&p.lines)
	preview_reset(&p.preview)
}

linefind_load_preview :: proc(editor: ^Editor) {
	p := &editor.linefind
	if len(p.matches) == 0 {
		preview_reset(&p.preview)
		return
	}
	b := editor_buffer(editor)
	focus := p.matches[p.selected] + 1
	preview_set_buffer(&p.preview, b, focus, overlay_layout(editor).body_h)
}

linefind_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.linefind
	fuzzy_list_move(&p.list, delta, overlay_layout(editor).body_h)
	linefind_load_preview(editor)
}

linefind_execute :: proc(editor: ^Editor) {
	p := &editor.linefind
	if len(p.matches) == 0 {
		linefind_close(editor)
		return
	}
	row := p.matches[p.selected]
	b := editor_buffer(editor)
	linefind_close(editor)

	buffer_undo_commit(b)
	editor_goto(editor, row, line_indent_len(b.lines[row].text[:]))
}

linefind_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.linefind
	#partial switch ev.key {
	case .Esc, .Ctrl_F:
		linefind_close(editor)
	case .Enter:
		linefind_execute(editor)
	case .Arrow_Down:
		linefind_move(editor, 1)
	case .Arrow_Up:
		linefind_move(editor, -1)
	case:
		if textfield_key(&p.field, ev) {
			linefind_refilter(p)
			linefind_load_preview(editor)
		}
	}
}

linefind_paste :: proc(editor: ^Editor, text: string) {
	p := &editor.linefind
	if textfield_insert_flat(&p.field, text) {
		linefind_refilter(p)
		linefind_load_preview(editor)
	}
}

linefind_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.linefind
	lay := overlay_layout(editor)
	if preview_wheel(&p.preview, ev, {lay.right_x, lay.body_top, lay.right_w, lay.body_h}, lay.body_h) {
		return
	}
	idx, activate := overlay_list_mouse(editor, ev, lay, len(p.matches), &p.scroll, &p.field, linefind_close)
	if idx < 0 {
		return
	}
	p.selected = idx
	linefind_load_preview(editor)
	if activate {
		linefind_execute(editor)
	}
}

linefind_label :: proc(numw, row: int, text: string) -> string {
	num := fmt.tprintf("%d", row + 1)
	pad := strings.repeat(" ", max(0, numw - len(num)), context.temp_allocator)
	return fmt.tprintf("%s%s  %s", pad, num, text)
}

linefind_render :: proc(editor: ^Editor) {
	p := &editor.linefind
	lay := overlay_layout(editor)
	inner := pane_draw_box(lay.box)
	numw := digit_count(len(p.lines))

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &p.field)
	pane_hline(lay.box, lay.title_sep_y)

	end := min(p.scroll + lay.body_h, len(p.matches))
	for i in p.scroll ..< end {
		row := p.matches[i]
		y := lay.body_top + (i - p.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, lay.left_w, fg, bg)
		}
		pane_text(inner.x + 1, y, lay.left_w - 1, linefind_label(numw, row, p.lines[row]), fg, bg)
	}

	preview_render(&p.preview, lay.right_x + 1, lay.body_top, lay.right_w - 1, lay.body_h)

	overlay_divider(lay)
}
