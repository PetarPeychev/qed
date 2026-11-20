package main

import "core:time"
import "lib:tb2"

PICKER_MARGIN_X :: 8
PICKER_MARGIN_Y :: 3

overlay_row_off :: proc(ev: tb2.Event, area: Rect) -> int {
	if !mouse_in_rect(ev, area) {
		return -1
	}
	return int(ev.y) - area.y
}

overlay_scroll_by :: proc(scroll: ^int, delta, count, rows: int) {
	scroll^ = clamp(scroll^ + delta, 0, max(0, count - rows))
}

overlay_double_click :: proc(editor: ^Editor, idx: int) -> bool {
	recent :=
		editor.overlay_click_idx == idx &&
		time.duration_milliseconds(time.tick_since(editor.overlay_click_tick)) <= f64(DOUBLE_CLICK_MS)
	editor.overlay_click_tick = time.tick_now()
	editor.overlay_click_idx = idx
	return recent
}

overlay_prompt_mouse :: proc(f: ^TextField, x, y, w: int, ev: tb2.Event, prefix := "> ") {
	pw := visual_width(transmute([]u8)prefix)
	textfield_mouse(f, x + pw, y, w - pw, ev)
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

overlay_prompt_render :: proc(x, y, w: int, f: ^TextField, prefix := "> ") {
	pw := visual_width(transmute([]u8)prefix)
	pane_text(x, y, pw, prefix, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	textfield_render(x + pw, y, w - pw, f)
}

overlay_row_selected :: proc(i, selected: int, anchor: Maybe(int)) -> bool {
	a, ok := anchor.?
	if !ok {
		return i == selected
	}
	return i >= min(a, selected) && i <= max(a, selected)
}

OverlayLayout :: struct {
	box, inner:                       Rect,
	body_top, body_h:                 int,
	title_sep_y:                      int,
	div_x, left_w, right_x, right_w:  int,
	preview:                          bool,
}

SplitList :: enum {
	None,
	FileTree,
	Code,
}

overlay_split :: proc(inner_w, lmin, lmax: int) -> (left_w, right_w: int, preview: bool) {
	w := inner_w - 1
	pmin, pmax := PREVIEW_MIN_WIDTH, PREVIEW_MAX_WIDTH
	if w >= lmax + pmax {
		return lmax, pmax, true
	}
	if w < lmin + pmin {
		return inner_w, 0, false
	}
	deficit := lmax + pmax - w
	list_loss := min(deficit / 2, lmax - lmin)
	if preview_loss := deficit - list_loss; preview_loss > pmax - pmin {
		list_loss += preview_loss - (pmax - pmin)
	}
	left_w = lmax - list_loss
	return left_w, w - left_w, true
}

overlay_layout :: proc(editor: ^Editor, list := SplitList.None) -> OverlayLayout {
	sw := int(tb2.width())
	sh := int(tb2.height())
	if !editor.welcome {
		sh -= STATUS_ROWS
	}
	box := Rect{PICKER_MARGIN_X, PICKER_MARGIN_Y, max(0, sw - 2 * PICKER_MARGIN_X), max(0, sh - 2 * PICKER_MARGIN_Y)}
	inner_w := box.w - 2
	left_w, right_w, preview := inner_w, 0, false
	switch list {
	case .None:
	case .FileTree:
		left_w, right_w, preview = overlay_split(inner_w, FILETREE_LIST_MIN_WIDTH, FILETREE_LIST_MAX_WIDTH)
	case .Code:
		left_w, right_w, preview = overlay_split(inner_w, CODE_LIST_MIN_WIDTH, CODE_LIST_MAX_WIDTH)
	}
	if preview && left_w + 1 + right_w < inner_w {
		w := left_w + 1 + right_w + 2
		box.x += (box.w - w) / 2
		box.w = w
	}
	inner := Rect{box.x + 1, box.y + 1, box.w - 2, box.h - 2}
	title_sep_y := inner.y + 1
	body_top := inner.y + 2
	body_h := max(0, inner.h - 2)
	div_x := inner.x + left_w
	right_x := div_x + 1
	return {box, inner, body_top, body_h, title_sep_y, div_x, left_w, right_x, right_w, preview}
}

digit_count :: proc(n: int) -> int {
	d := 1
	for v := n; v >= 10; v /= 10 {
		d += 1
	}
	return d
}
