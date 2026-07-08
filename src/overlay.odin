package main

import "core:time"
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

fuzzy_list_move :: proc(l: ^FuzzyList, delta, rows: int) {
	n := len(l.matches)
	if n == 0 {
		return
	}
	l.selected = clamp(l.selected + delta, 0, n - 1)
	fuzzy_list_scroll(l, rows)
}

// 0-based row index under a click within a list area (the row rows occupy), or -1.
overlay_row_off :: proc(ev: tb2.Event, area: Rect) -> int {
	if !mouse_in_rect(ev, area) {
		return -1
	}
	return int(ev.y) - area.y
}

overlay_scroll_by :: proc(scroll: ^int, delta, count, rows: int) {
	scroll^ = clamp(scroll^ + delta, 0, max(0, count - rows))
}

// A left click on `idx` is an activation when it's the second click on the same
// row within the double-click window; otherwise it merely selects.
overlay_double_click :: proc(editor: ^Editor, idx: int) -> bool {
	recent :=
		editor.overlay_click_idx == idx &&
		time.duration_milliseconds(time.tick_since(editor.overlay_click_tick)) <= f64(DOUBLE_CLICK_MS)
	editor.overlay_click_tick = time.tick_now()
	editor.overlay_click_idx = idx
	return recent
}

// Caret placement / drag-select for the "> " query field, given the same x/y/w
// passed to overlay_prompt_render (the field itself sits past the 2-cell prefix).
overlay_prompt_mouse :: proc(f: ^TextField, x, y, w: int, ev: tb2.Event) {
	textfield_mouse(f, x + 2, y, w - 2, ev)
}

ev_motion :: proc(ev: tb2.Event) -> bool {
	return (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0
}

ev_ctrl :: proc(ev: tb2.Event) -> bool {
	return (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0
}

ev_shift :: proc(ev: tb2.Event) -> bool {
	return (u8(ev.mod) & u8(tb2.Mod.Shift)) != 0
}

ev_alt :: proc(ev: tb2.Event) -> bool {
	return (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
}

// Mouse handling shared by every centered fuzzy picker (palette-style): wheel
// scrolls, a click on the query field places/drags the caret, a click selects a
// row (drag re-highlights), a double click runs `activate`, a click outside `close`s.
fuzzy_list_center_mouse :: proc(
	editor: ^Editor,
	l: ^FuzzyList,
	ev: tb2.Event,
	activate, close: proc(editor: ^Editor),
) {
	rows := min(len(l.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		overlay_scroll_by(&l.scroll, -WHEEL_SCROLL_LINES, len(l.matches), rows)
	case .Mouse_Wheel_Down:
		overlay_scroll_by(&l.scroll, WHEEL_SCROLL_LINES, len(l.matches), rows)
	case .Mouse_Left:
		motion := ev_motion(ev)
		if !mouse_in_rect(ev, box) {
			if !motion {
				close(editor)
			}
			return
		}
		if int(ev.y) == box.y + 1 {
			overlay_prompt_mouse(&l.field, box.x + 2, box.y + 1, box.w - 4, ev)
			return
		}
		off := overlay_row_off(ev, Rect{box.x + 1, box.y + 3, box.w - 2, rows})
		if off < 0 {
			return
		}
		idx := l.scroll + off
		if idx >= len(l.matches) {
			return
		}
		l.selected = idx
		if !motion && overlay_double_click(editor, idx) {
			activate(editor)
		}
	}
}

// Shared mouse for an overlay_layout picker's left list. Wheel scrolls, a click
// outside the box `close`s. Returns the clicked item index (-1 if no row was
// hit) and whether the click was an activation; the caller applies selection
// side effects (preview load, execute) since those differ per picker.
overlay_list_mouse :: proc(
	editor: ^Editor,
	ev: tb2.Event,
	lay: OverlayLayout,
	count: int,
	scroll: ^int,
	field: ^TextField,
	close: proc(editor: ^Editor),
) -> (idx: int, activate: bool) {
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		overlay_scroll_by(scroll, -WHEEL_SCROLL_LINES, count, lay.body_h)
	case .Mouse_Wheel_Down:
		overlay_scroll_by(scroll, WHEEL_SCROLL_LINES, count, lay.body_h)
	case .Mouse_Left:
		motion := ev_motion(ev)
		if !mouse_in_rect(ev, lay.box) {
			if !motion {
				close(editor)
			}
			return -1, false
		}
		if int(ev.y) == lay.inner.y {
			overlay_prompt_mouse(field, lay.inner.x + 1, lay.inner.y, lay.inner.w - 2, ev)
			return -1, false
		}
		off := overlay_row_off(ev, Rect{lay.inner.x, lay.body_top, lay.left_w, lay.body_h})
		if off < 0 {
			return -1, false
		}
		i := scroll^ + off
		if i >= count {
			return -1, false
		}
		return i, !motion && overlay_double_click(editor, i)
	}
	return -1, false
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
