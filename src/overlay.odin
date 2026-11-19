package main

import "core:time"
import "lib:tb2"

PICKER_MARGIN_X :: 8
PICKER_MARGIN_Y :: 3

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

fuzzy_list_center_mouse :: proc(
	editor: ^Editor,
	l: ^FuzzyList,
	ev: tb2.Event,
	activate, close: proc(editor: ^Editor),
	prefix := "> ",
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
			overlay_prompt_mouse(&l.field, box.x + 2, box.y + 1, box.w - 4, ev, prefix)
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

overlay_list_mouse :: proc(
	editor: ^Editor,
	ev: tb2.Event,
	lay: OverlayLayout,
	count: int,
	scroll: ^int,
	field: ^TextField,
	close: proc(editor: ^Editor),
	prefix := "> ",
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
			overlay_prompt_mouse(field, lay.inner.x + 1, lay.inner.y, lay.inner.w - 2, ev, prefix)
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

fuzzy_list_center_scrollbar :: proc(l: ^FuzzyList, box: Rect, rows: int) {
	pane_draw_scrollbar(box.x + box.w - 1, box.y + 3, rows, l.scroll, len(l.matches))
}

overlay_prompt_render :: proc(x, y, w: int, f: ^TextField, prefix := "> ") {
	pw := visual_width(transmute([]u8)prefix)
	pane_text(x, y, pw, prefix, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	textfield_render(x + pw, y, w - pw, f)
}

fuzzy_list_key :: proc(editor: ^Editor, l: ^FuzzyList, ev: tb2.Event, activate, close: proc(editor: ^Editor), rows := PALETTE_MAX_ROWS) -> (refiltered: bool) {
	#partial switch ev.key {
	case .Esc:
		close(editor)
	case .Enter:
		activate(editor)
	case .Arrow_Down:
		fuzzy_list_move(l, 1, rows)
	case .Arrow_Up:
		fuzzy_list_move(l, -1, rows)
	case:
		if textfield_key(&l.field, ev) {
			fuzzy_list_refilter(l)
			return true
		}
	}
	return false
}

overlay_row_selected :: proc(i, selected: int, anchor: Maybe(int)) -> bool {
	a, ok := anchor.?
	if !ok {
		return i == selected
	}
	return i >= min(a, selected) && i <= max(a, selected)
}

fuzzy_list_center_render :: proc(editor: ^Editor, l: ^FuzzyList, labels, details: []string, prefix := "> ", anchor: Maybe(int) = nil) {
	rows := min(len(l.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &l.field, prefix)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := l.scroll + i
		item := l.matches[idx]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		detail_fg := COLOR_PANE_SHORTCUT_FG
		if overlay_row_selected(idx, l.selected, anchor) {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			detail_fg = COLOR_PANE_SEL_FG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, labels[item], fg, bg)
		if item < len(details) && details[item] != "" {
			dw := visual_width(transmute([]u8)details[item])
			pane_text(inner.x + inner.w - 1 - dw, y, dw, details[item], detail_fg, bg)
		}
	}

	fuzzy_list_center_scrollbar(l, box, rows)
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

overlay_divider :: proc(lay: OverlayLayout, offset, total: int) {
	if !lay.preview {
		pane_draw_scrollbar(lay.div_x, lay.body_top, lay.body_h, offset, total)
		return
	}
	bottom := lay.box.y + lay.box.h - 1
	for y in lay.body_top ..< bottom {
		tb2.set_cell(i32(lay.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.title_sep_y), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.div_x), i32(bottom), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)
	pane_draw_scrollbar(lay.div_x, lay.body_top, lay.body_h, offset, total)
}

digit_count :: proc(n: int) -> int {
	d := 1
	for v := n; v >= 10; v /= 10 {
		d += 1
	}
	return d
}
