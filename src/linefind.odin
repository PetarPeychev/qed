package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

LineFind :: struct {
	active:   bool,
	query:    [dynamic]u8,
	lines:    [dynamic]string,
	matches:  [dynamic]int,
	selected: int,
	scroll:   int,
	fuzzy:    Fuzzy,
}

linefind_destroy :: proc(p: ^LineFind) {
	fuzzy_end(&p.fuzzy)
	delete(p.lines)
	delete(p.query)
	delete(p.matches)
}

linefind_open :: proc(editor: ^Editor) {
	p := &editor.linefind
	p.active = true
	clear(&p.query)
	editor.message = ""
	editor.message_error = false

	b := editor_buffer(editor)
	clear(&p.lines)
	for &line in b.lines {
		append(&p.lines, string(line.text[:]))
	}
	p.fuzzy = fuzzy_begin(p.lines[:])
	linefind_filter(editor)

	p.selected = clamp(b.cursor.row, 0, max(0, len(p.matches) - 1))
	list_h := linefind_layout(editor).list_h
	p.scroll = max(0, p.selected - list_h / 2)
}

linefind_close :: proc(editor: ^Editor) {
	p := &editor.linefind
	p.active = false
	fuzzy_end(&p.fuzzy)
	clear(&p.lines)
}

linefind_filter :: proc(editor: ^Editor) {
	p := &editor.linefind
	clear(&p.matches)
	p.selected = 0
	p.scroll = 0
	ranked := fuzzy_rank(&p.fuzzy, string(p.query[:]))
	for idx in ranked {
		append(&p.matches, idx)
	}
}

linefind_layout :: proc(editor: ^Editor) -> PickerLayout {
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

linefind_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.linefind
	if len(p.matches) == 0 {
		return
	}
	p.selected = clamp(p.selected + delta, 0, len(p.matches) - 1)
	list_h := linefind_layout(editor).list_h
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if list_h > 0 && p.selected >= p.scroll + list_h {
		p.scroll = p.selected - list_h + 1
	}
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
	if alt && ev.ch == 'f' {
		linefind_close(editor)
		return
	}
	#partial switch ev.key {
	case .Esc:
		linefind_close(editor)
	case .Enter:
		linefind_execute(editor)
	case .Arrow_Down:
		linefind_move(editor, 1)
	case .Arrow_Up:
		linefind_move(editor, -1)
	case .Pgdn:
		linefind_move(editor, linefind_layout(editor).list_h)
	case .Pgup:
		linefind_move(editor, -linefind_layout(editor).list_h)
	case .Backspace, .Backspace2:
		if len(p.query) > 0 {
			resize(&p.query, len(p.query) - 1)
			linefind_filter(editor)
		}
	case:
		if ev.ch >= 0x20 && !alt {
			bytes, n := utf8.encode_rune(ev.ch)
			append(&p.query, ..bytes[:n])
			linefind_filter(editor)
		}
	}
}

linefind_number_width :: proc(count: int) -> int {
	w := 1
	for n := count; n >= 10; n /= 10 {
		w += 1
	}
	return w
}

linefind_label :: proc(numw, row: int, text: string) -> string {
	num := fmt.tprintf("%d", row + 1)
	pad := strings.repeat(" ", max(0, numw - len(num)), context.temp_allocator)
	return fmt.tprintf("%s%s  %s", pad, num, text)
}

linefind_render :: proc(editor: ^Editor) {
	p := &editor.linefind
	lay := linefind_layout(editor)
	inner := pane_draw_box(lay.box)
	numw := linefind_number_width(len(p.lines))

	prompt := fmt.tprintf("> %s", string(p.query[:]))
	pane_text(inner.x + 1, inner.y, inner.w - 2, prompt, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_hline(lay.box, inner.y + 1)

	end := min(p.scroll + lay.list_h, len(p.matches))
	for i in p.scroll ..< end {
		row := p.matches[i]
		y := lay.list_top + (i - p.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, linefind_label(numw, row, p.lines[row]), fg, bg)
	}

	pane_hline(lay.box, lay.sep_y)

	if len(p.matches) > 0 && lay.preview_h > 0 {
		focus := p.matches[p.selected]
		start := clamp(focus - lay.preview_h / 2, 0, max(0, len(p.lines) - lay.preview_h))
		for i in 0 ..< lay.preview_h {
			row := start + i
			if row >= len(p.lines) {
				break
			}
			y := lay.preview_top + i
			fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
			if row == focus {
				fg = COLOR_PANE_PROMPT_FG
			}
			pane_text(inner.x + 1, y, inner.w - 2, linefind_label(numw, row, p.lines[row]), fg, bg)
		}
	}

	cx := min(inner.x + 3 + len(p.query), inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(inner.y))
}
