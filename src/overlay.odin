package main

import "core:unicode/utf8"
import "lib:tb2"

FuzzyList :: struct {
	active:   bool,
	query:    [dynamic]u8,
	matches:  [dynamic]int,
	selected: int,
	scroll:   int,
	fuzzy:    Fuzzy,
}

fuzzy_list_destroy :: proc(l: ^FuzzyList) {
	fuzzy_end(&l.fuzzy)
	delete(l.query)
	delete(l.matches)
}

fuzzy_list_reset :: proc(l: ^FuzzyList) {
	clear(&l.query)
	l.selected = 0
	l.scroll = 0
}

fuzzy_list_refilter :: proc(l: ^FuzzyList) {
	clear(&l.matches)
	l.selected = 0
	l.scroll = 0
	for idx in fuzzy_rank(&l.fuzzy, string(l.query[:])) {
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

// Returns true when the query changed, so the caller re-filters (and reloads any preview).
query_edit_key :: proc(query: ^[dynamic]u8, ev: tb2.Event) -> bool {
	#partial switch ev.key {
	case .Backspace, .Backspace2:
		if len(query) > 0 {
			resize(query, len(query) - 1)
			return true
		}
	case:
		if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			append(query, ..bytes[:n])
			return true
		}
	}
	return false
}

// Draw a single-line caret-editable input in the column span [x, x+w), scrolled
// horizontally so the caret is always visible, and place the hardware cursor.
input_line_render :: proc(x, y, w: int, input: []u8, caret: int) {
	if w <= 0 {
		return
	}
	start := 0
	for start < caret && visual_width(input[start:caret]) >= w {
		start = grapheme_next(input, start)
	}
	pane_text(x, y, w, string(input[start:]), COLOR_PANE_FG, COLOR_PANE_BG)
	tb2.set_cursor(i32(x + visual_width(input[start:caret])), i32(y))
}

overlay_cursor :: proc(inner: Rect, query_len: int) {
	cx := min(inner.x + 3 + query_len, inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(inner.y))
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
