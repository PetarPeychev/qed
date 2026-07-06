package main

import "core:unicode/utf8"

// Byte offsets where each visual row of a soft-wrapped line begins. The first
// element is always 0; a single element means the line occupies one screen row.
// Breaks prefer the last whitespace boundary that fits; a word wider than the
// available width hard-breaks. Widths are grapheme/tab-aware and measured with
// absolute visual columns (from the logical line start) so tab stops match the
// renderer.
line_wrap :: proc(text: []u8, width: int, allocator := context.temp_allocator) -> [dynamic]int {
	segs := make([dynamic]int, allocator)
	append(&segs, 0)
	if width <= 0 || len(text) == 0 {
		return segs
	}

	starts := make([dynamic]int, context.temp_allocator)
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		append(&starts, g.byte_index)
	}
	append(&starts, len(text))

	v := 0 // running absolute visual column
	seg_start_v := 0 // absolute visual column at the current segment start
	last_break := -1 // byte offset just after the most recent space in this segment
	last_break_v := 0

	for i in 0 ..< len(starts) - 1 {
		cs := starts[i]
		ce := starts[i + 1]
		cw := seg_width(text, cs, ce, v)
		seg_start := segs[len(segs) - 1]
		if v + cw - seg_start_v > width && cs > seg_start {
			if last_break > seg_start {
				append(&segs, last_break)
				seg_start_v = last_break_v
			} else {
				append(&segs, cs)
				seg_start_v = v
			}
			last_break = -1
		}
		v += cw
		if text[cs] == ' ' || text[cs] == '\t' {
			last_break = ce
			last_break_v = v
		}
	}
	return segs
}

wrap_rows :: proc(text: []u8, width: int) -> int {
	return len(line_wrap(text, width))
}

wrap_subrow :: proc(text: []u8, width, col: int) -> int {
	segs := line_wrap(text, width)
	sub := 0
	for i in 1 ..< len(segs) {
		if col >= segs[i] {
			sub = i
		} else {
			break
		}
	}
	return sub
}

wrap_seg_start :: proc(text: []u8, width, col: int) -> int {
	segs := line_wrap(text, width)
	start := 0
	for i in 1 ..< len(segs) {
		if col >= segs[i] {
			start = segs[i]
		} else {
			break
		}
	}
	return start
}

wrap_segment :: proc(text: []u8, width, sub: int) -> (start, end: int) {
	segs := line_wrap(text, width)
	s := clamp(sub, 0, len(segs) - 1)
	start = segs[s]
	end = segs[s + 1] if s + 1 < len(segs) else len(text)
	return
}

// Move k visual rows up from (row, sub); clamps at the buffer top.
vpos_up :: proc(b: ^Buffer, width, row, sub, k: int) -> (int, int) {
	row, sub, k := row, sub, k
	for k > 0 {
		if sub > 0 {
			sub -= 1
		} else if row > 0 {
			row -= 1
			sub = wrap_rows(b.lines[row].text[:], width) - 1
		} else {
			break
		}
		k -= 1
	}
	return row, sub
}

// Move k visual rows down from (row, sub); clamps at the buffer bottom.
vpos_down :: proc(b: ^Buffer, width, row, sub, k: int) -> (int, int) {
	row, sub, k := row, sub, k
	for k > 0 {
		rows := wrap_rows(b.lines[row].text[:], width)
		if sub < rows - 1 {
			sub += 1
		} else if row < len(b.lines) - 1 {
			row += 1
			sub = 0
		} else {
			break
		}
		k -= 1
	}
	return row, sub
}

// Visual-row count from (r0,s0) up to (r1,s1); assumes the first precedes the second.
vpos_dist :: proc(b: ^Buffer, width, r0, s0, r1, s1: int) -> int {
	if r0 == r1 {
		return s1 - s0
	}
	total := wrap_rows(b.lines[r0].text[:], width) - s0
	for r in r0 + 1 ..< r1 {
		total += wrap_rows(b.lines[r].text[:], width)
	}
	return total + s1
}

vpos_cmp :: proc(r0, s0, r1, s1: int) -> int {
	if r0 != r1 {
		return -1 if r0 < r1 else 1
	}
	if s0 != s1 {
		return -1 if s0 < s1 else 1
	}
	return 0
}

// Byte col for a target visual-x within visual row `sub` of `text`. Keeps the
// cursor off a soft-wrap boundary (which renders on the next row) so vertical
// motion and End land on the intended visual row.
cursor_place_in_subrow :: proc(text: []u8, width, sub, goal_x: int) -> int {
	start, end := wrap_segment(text, width, sub)
	base := visual_col(text, start)
	col := clamp(col_at_visual(text, base + goal_x), start, end)
	if end < len(text) && col == end {
		col = max(grapheme_prev(text, end), start)
	}
	return col
}
