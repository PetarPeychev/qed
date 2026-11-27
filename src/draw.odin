package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

Rect :: struct {
	x, y, w, h: int,
}

draw_box :: proc(r: Rect) -> Rect {
	for y in r.y ..< r.y + r.h {
		for x in r.x ..< r.x + r.w {
			tb2.set_cell(i32(x), i32(y), ' ', COLOR_PANE_BORDER, COLOR_PANE_BG)
		}
	}

	left := r.x
	right := r.x + r.w - 1
	top := r.y
	bottom := r.y + r.h - 1
	for x in left + 1 ..< right {
		tb2.set_cell(i32(x), i32(top), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
		tb2.set_cell(i32(x), i32(bottom), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	for y in top + 1 ..< bottom {
		tb2.set_cell(i32(left), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
		tb2.set_cell(i32(right), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(left), i32(top), '┌', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(right), i32(top), '┐', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(left), i32(bottom), '└', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(right), i32(bottom), '┘', COLOR_PANE_BORDER, COLOR_PANE_BG)

	return {r.x + 1, r.y + 1, r.w - 2, r.h - 2}
}

mouse_in_rect :: proc(ev: tb2.Event, r: Rect) -> bool {
	x, y := int(ev.x), int(ev.y)
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

scrollbar_thumb :: proc(offset, visible, total: int) -> (start, length: int) {
	if visible <= 0 || total <= visible {
		return 0, 0
	}
	length = min(visible, max(1, visible * visible / total))
	span := visible - length
	start = clamp(offset * span / (total - visible), 0, span)
	return
}

draw_fill_row :: proc(x, y, w: int, fg, bg: tb2.Color) {
	for col in 0 ..< w {
		tb2.set_cell(i32(x + col), i32(y), ' ', fg, bg)
	}
}

draw_text :: proc(x, y, w: int, text: string, fg, bg: tb2.Color) -> int {
	bytes := transmute([]u8)text
	col := 0
	i := 0
	for i < len(bytes) && col < w {
		e := cluster_end(bytes, i)
		if bytes[i] == '\t' {
			next := (col / TAB_WIDTH + 1) * TAB_WIDTH
			for col < next && col < w {
				tb2.set_cell(i32(x + col), i32(y), ' ', fg, bg)
				col += 1
			}
		} else {
			cw := cluster_width(bytes[i:e])
			if col + cw > w {
				break
			}
			cell_put_cluster(x + col, y, bytes[i:e], fg, bg)
			col += cw
		}
		i = e
	}
	return col
}

cell_put_cluster :: proc(x, y: int, cluster: []u8, fg, bg: tb2.Color) {
	r, n := utf8.decode_rune(cluster)
	tb2.set_cell(i32(x), i32(y), r, fg, bg)
	for rest := cluster[n:]; len(rest) > 0; {
		rr, m := utf8.decode_rune(rest)
		tb2.extend_cell(i32(x), i32(y), rr)
		rest = rest[m:]
	}
}

ev_motion :: proc(ev: tb2.Event) -> bool {
	return (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0
}

ev_wheel :: proc(ev: tb2.Event) -> bool {
	if ev.type != .Mouse {
		return false
	}
	#partial switch ev.key {
	case .Mouse_Wheel_Up, .Mouse_Wheel_Down, .Mouse_Wheel_Left, .Mouse_Wheel_Right:
		return true
	}
	return false
}

ev_wheel_sideways :: proc(ev: tb2.Event) -> bool {
	return ev.type == .Mouse && (ev.key == .Mouse_Wheel_Left || ev.key == .Mouse_Wheel_Right || (ev_alt(ev) && ev_wheel(ev)))
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

digit_count :: proc(n: int) -> int {
	d := 1
	for v := n; v >= 10; v /= 10 {
		d += 1
	}
	return d
}
