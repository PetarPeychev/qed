package main

import "core:fmt"
import "core:strings"
import "lib:tb2"

LineFind :: struct {
	using list: FuzzyList,
	lines:      [dynamic]string,
}

linefind_destroy :: proc(p: ^LineFind) {
	fuzzy_list_destroy(&p.list)
	delete(p.lines)
}

linefind_open :: proc(editor: ^Editor) {
	p := &editor.linefind
	p.active = true
	fuzzy_list_reset(&p.list)
	editor_set_message(editor, "")

	b := editor_buffer(editor)
	clear(&p.lines)
	for &line in b.lines {
		append(&p.lines, string(line.text[:]))
	}
	p.fuzzy = fuzzy_begin(p.lines[:])
	fuzzy_list_refilter(&p.list)

	p.selected = clamp(b.cursor.row, 0, max(0, len(p.matches) - 1))
	body_h := overlay_layout(editor).body_h
	p.scroll = max(0, p.selected - body_h / 2)
}

linefind_close :: proc(editor: ^Editor) {
	p := &editor.linefind
	p.active = false
	fuzzy_end(&p.fuzzy)
	clear(&p.lines)
}

linefind_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.linefind
	fuzzy_list_move_clamp(&p.list, delta, overlay_layout(editor).body_h)
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
	text := b.lines[row].text[:]
	col := 0
	for col < len(text) && (text[col] == ' ' || text[col] == '\t') {
		col += 1
	}
	b.selection = nil
	b.cursor = {row, col}
	cursor_goal_sync(b)
	_, h := editor_viewport(editor)
	editor.scroll_row = row - h / 2
	editor_scroll(editor)
}

linefind_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.linefind
	alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
	#partial switch ev.key {
	case .Esc, .Ctrl_F:
		linefind_close(editor)
	case .Enter:
		linefind_execute(editor)
	case .Arrow_Down:
		linefind_move(editor, 1)
	case .Arrow_Up:
		linefind_move(editor, -1)
	case .Pgdn:
		linefind_move(editor, overlay_layout(editor).body_h)
	case .Pgup:
		linefind_move(editor, -overlay_layout(editor).body_h)
	case:
		if !alt && query_edit_key(&p.query, ev) {
			fuzzy_list_refilter(&p.list)
		}
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

	prompt := fmt.tprintf("> %s", string(p.query[:]))
	pane_text(inner.x + 1, inner.y, inner.w - 2, prompt, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
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

	if len(p.matches) > 0 && lay.body_h > 0 {
		focus := p.matches[p.selected]
		start := clamp(focus - lay.body_h / 2, 0, max(0, len(p.lines) - lay.body_h))
		for i in 0 ..< lay.body_h {
			row := start + i
			if row >= len(p.lines) {
				break
			}
			y := lay.body_top + i
			fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
			if row == focus {
				fg = COLOR_PANE_PROMPT_FG
			}
			pane_text(lay.right_x + 1, y, lay.right_w - 1, linefind_label(numw, row, p.lines[row]), fg, bg)
		}
	}

	overlay_divider(lay)
	overlay_cursor(inner, len(p.query))
}
