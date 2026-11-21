package main

import "core:os"
import "core:slice"

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

	v := 0 // running absolute visual column
	seg_start_v := 0 // absolute visual column at the current segment start
	last_break := -1 // byte offset just after the most recent space in this segment
	last_break_v := 0
	seg_start := 0

	for cs := 0; cs < len(text); {
		ce, cw := cs + 1, 1
		if c := text[cs]; c < 0x20 || c >= 0x7f || (ce < len(text) && text[ce] >= 0x80) {
			ce = cluster_end(text, cs)
			cw = seg_width(text, cs, ce, v)
		}
		if v + cw - seg_start_v > width && cs > seg_start {
			if last_break > seg_start {
				append(&segs, last_break)
				seg_start_v = last_break_v
			} else {
				append(&segs, cs)
				seg_start_v = v
			}
			last_break = -1
			seg_start = segs[len(segs) - 1]
		}
		v += cw
		if text[cs] == ' ' || text[cs] == '\t' {
			last_break = ce
			last_break_v = v
		}
		cs = ce
	}
	return segs
}

WRAP_MEMO_MIN_BYTES :: 4096

WrapMemo :: struct {
	id, rev:          u64,
	row, width, tab: int,
	segs:             [dynamic]int,
}

@(thread_local)
g_wrap_memo: [4]WrapMemo
@(thread_local)
g_wrap_memo_next: int

// Keyed on buffer rev, which every line mutation bumps; id 0 (bare test buffers) is not unique, so never memoized.
buffer_line_wrap :: proc(b: ^Buffer, row, width: int) -> []int {
	text := b.lines[row].text[:]
	if len(text) < WRAP_MEMO_MIN_BYTES || b.id == 0 {
		return line_wrap(text, width)[:]
	}
	for &m in g_wrap_memo {
		if len(m.segs) > 0 && m.id == b.id && m.rev == b.rev && m.row == row && m.width == width && m.tab == TAB_WIDTH {
			return slice.clone(m.segs[:], context.temp_allocator)
		}
	}
	segs := line_wrap(text, width)
	m := &g_wrap_memo[g_wrap_memo_next]
	g_wrap_memo_next = (g_wrap_memo_next + 1) % len(g_wrap_memo)
	if m.segs.allocator.procedure == nil {
		m.segs = make([dynamic]int, os.heap_allocator())
	}
	clear(&m.segs)
	append(&m.segs, ..segs[:])
	m.id, m.rev, m.row, m.width, m.tab = b.id, b.rev, row, width, TAB_WIDTH
	return segs[:]
}

wrap_subrow :: proc(segs: []int, col: int) -> int {
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

wrap_seg_start :: proc(segs: []int, col: int) -> int {
	return segs[wrap_subrow(segs, col)]
}

wrap_segment :: proc(segs: []int, text_len, sub: int) -> (start, end: int) {
	s := clamp(sub, 0, len(segs) - 1)
	start = segs[s]
	end = segs[s + 1] if s + 1 < len(segs) else text_len
	return
}

line_rows :: proc(b: ^Buffer, width, row: int) -> int {
	if b.wrap && width > 0 {
		return len(buffer_line_wrap(b, row, width))
	}
	return 1
}

// ghost rows count as steps but are never landed on
vpos_up :: proc(b: ^Buffer, width, row, sub, k: int) -> (int, int) {
	row, sub, k := row, sub, k
	for k > 0 {
		if sub > 0 {
			sub -= 1
			k -= 1
			continue
		}
		if row == 0 {
			break
		}
		ghosts := ghost_above(b, row) + ghost_below(b, row - 1)
		if k <= ghosts {
			row -= 1
			sub = line_rows(b, width, row) - 1
			break
		}
		k -= ghosts
		row -= 1
		sub = line_rows(b, width, row) - 1
		k -= 1
	}
	return row, sub
}

// Move k screen rows down from real (row, sub); clamps at the buffer bottom.
vpos_down :: proc(b: ^Buffer, width, row, sub, k: int) -> (int, int) {
	row, sub, k := row, sub, k
	for k > 0 {
		rows := line_rows(b, width, row)
		if sub < rows - 1 {
			sub += 1
			k -= 1
			continue
		}
		if row >= len(b.lines) - 1 {
			break
		}
		ghosts := ghost_below(b, row) + ghost_above(b, row + 1)
		if k <= ghosts {
			row += 1
			sub = 0
			break
		}
		k -= ghosts
		row += 1
		sub = 0
		k -= 1
	}
	return row, sub
}

// r0's above-ghosts are hidden: r0 anchors the viewport top
vpos_dist :: proc(b: ^Buffer, width, r0, s0, r1, s1: int, limit := max(int)) -> int {
	if r0 == r1 {
		return s1 - s0
	}
	total := line_rows(b, width, r0) - s0 + ghost_below(b, r0)
	for r in r0 + 1 ..< r1 {
		total += ghost_above(b, r) + line_rows(b, width, r) + ghost_below(b, r)
		if total >= limit {
			return total
		}
	}
	return total + ghost_above(b, r1) + s1
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
cursor_place_in_subrow :: proc(b: ^Buffer, row, width, sub, goal_x: int) -> int {
	text := b.lines[row].text[:]
	start, end := wrap_segment(buffer_line_wrap(b, row, width), len(text), sub)
	base := visual_col(text, start)
	col := clamp(col_at_visual(text, base + goal_x), start, end)
	if end < len(text) && col == end {
		col = max(grapheme_prev(text, end), start)
	}
	return col
}
