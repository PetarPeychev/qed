package main

import "lib:tb2"

FuzzyList :: struct {
	active:   bool,
	field:    TextField,
	matches:  [dynamic]int,
	selected: int,
	scroll:   int,
	fuzzy:    Fuzzy,
}

fuzzy_list_destroy :: proc(l: ^FuzzyList) {
	fuzzy_end(&l.fuzzy)
	textfield_destroy(&l.field)
	delete(l.matches)
}

fuzzy_list_reset :: proc(l: ^FuzzyList) {
	textfield_reset(&l.field)
	l.selected = 0
	l.scroll = 0
}

fuzzy_list_refilter :: proc(l: ^FuzzyList) {
	clear(&l.matches)
	l.selected = 0
	l.scroll = 0
	for idx in fuzzy_rank(&l.fuzzy, textfield_str(&l.field)) {
		append(&l.matches, idx)
	}
}

fuzzy_list_scroll :: proc(l: ^FuzzyList, rows: int) {
	if l.selected < l.scroll {
		l.scroll = l.selected
	}
	if rows > 0 && l.selected >= l.scroll + rows {
		l.scroll = l.selected - rows + 1
	}
}

fuzzy_list_move_wrap :: proc(l: ^FuzzyList, delta, rows: int) {
	n := len(l.matches)
	if n == 0 {
		return
	}
	l.selected = (l.selected + delta + n) % n
	fuzzy_list_scroll(l, rows)
}

// A "> " prompt prefix followed by the field, as every fuzzy overlay draws it.
overlay_prompt_render :: proc(x, y, w: int, f: ^TextField) {
	pane_text(x, y, 2, "> ", COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	textfield_render(x + 2, y, w - 2, f)
}

OverlayLayout :: struct {
	box, inner:                       Rect,
	body_top, body_h:                 int,
	title_sep_y:                      int,
	div_x, left_w, right_x, right_w:  int,
}

overlay_layout :: proc(editor: ^Editor) -> OverlayLayout {
	sw := int(tb2.width())
	sh := int(tb2.height())
	if !editor.welcome {
		sh -= STATUS_ROWS
	}
	box := Rect{PICKER_MARGIN_X, PICKER_MARGIN_Y, max(0, sw - 2 * PICKER_MARGIN_X), max(0, sh - 2 * PICKER_MARGIN_Y)}
	inner := Rect{box.x + 1, box.y + 1, box.w - 2, box.h - 2}
	title_sep_y := inner.y + 1
	body_top := inner.y + 2
	body_h := max(0, inner.h - 2)
	left_w := (inner.w - 1) / 2
	div_x := inner.x + left_w
	right_x := div_x + 1
	right_w := max(0, inner.x + inner.w - right_x)
	return {box, inner, body_top, body_h, title_sep_y, div_x, left_w, right_x, right_w}
}

overlay_divider :: proc(lay: OverlayLayout) {
	bottom := lay.box.y + lay.box.h - 1
	for y in lay.body_top ..< bottom {
		tb2.set_cell(i32(lay.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.title_sep_y), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.div_x), i32(bottom), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)
}

digit_count :: proc(n: int) -> int {
	d := 1
	for v := n; v >= 10; v /= 10 {
		d += 1
	}
	return d
}
