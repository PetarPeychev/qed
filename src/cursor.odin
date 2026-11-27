package main

import "core:unicode/utf8"
import "lib:tb2"

CharClass :: enum {
	Whitespace,
	Word,
	Punct,
}

char_class :: proc(r: rune) -> CharClass {
	switch r {
	case ' ', '\t':
		return .Whitespace
	case '_', 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return .Word
	case:
		return .Word if r >= 0x80 else .Punct
	}
}

grapheme_class :: proc(text: []u8, at: int) -> CharClass {
	r, _ := utf8.decode_rune(text[at:])
	return char_class(r)
}

grapheme_next :: proc(text: []u8, col: int) -> int {
	if col >= len(text) {
		return len(text)
	}
	i := grapheme_sync(text, col)
	for i <= col && i < len(text) {
		i = cluster_end(text, i)
	}
	return i
}

grapheme_prev :: proc(text: []u8, col: int) -> int {
	if col <= 0 || len(text) == 0 {
		return 0
	}
	i := grapheme_sync(text, col - 1)
	for {
		e := cluster_end(text, i)
		if e >= col || e >= len(text) {
			return i
		}
		i = e
	}
}

// An ASCII byte after an ASCII non-CR byte always starts a grapheme cluster (UAX #29 GB3-GB9b).
grapheme_sync :: proc(text: []u8, i: int) -> int {
	j := min(i, len(text) - 1)
	for j > 0 && !(text[j] < 0x80 && text[j - 1] < 0x80 && text[j - 1] != '\r') {
		j -= 1
	}
	return max(j, 0)
}

// `i` must start a cluster.
cluster_end :: proc(text: []u8, i: int) -> int {
	if text[i] < 0x80 && text[i] != '\r' && (i + 1 == len(text) || text[i + 1] < 0x80) {
		return i + 1
	}
	it := utf8.decode_grapheme_iterator_make(string(text[i:]))
	_, _, _ = utf8.decode_grapheme_iterate(&it)
	_, g, ok := utf8.decode_grapheme_iterate(&it)
	return i + g.byte_index if ok else len(text)
}

// termbox's own measure: present() advances by it, so any other value drifts the row
cluster_width :: proc(cluster: []u8) -> int {
	buf: [32]rune = ---
	runes := buf[:]
	n := utf8.rune_count(cluster)
	if n > len(buf) {
		runes = make([]rune, n, context.temp_allocator)
	}
	i := 0
	for r in string(cluster) {
		runes[i] = r
		i += 1
	}
	return max(int(tb2.cluster_width(raw_data(runes), uint(i))), 1)
}

seg_width :: proc(text: []u8, start, end, v: int) -> int {
	if text[start] == '\t' {
		return (v / TAB_WIDTH + 1) * TAB_WIDTH - v
	}
	if end == start + 1 && text[start] < 0x80 {
		return 1
	}
	return cluster_width(text[start:end])
}

visual_col :: proc(text: []u8, col: int) -> int {
	return visual_col_from(text, 0, 0, col)
}

// `from` must be a grapheme boundary whose visual column is `v`.
visual_col_from :: proc(text: []u8, from, v, col: int) -> int {
	v := v
	i := from
	for i < len(text) && i < col {
		c := text[i]
		if c >= 0x20 && c < 0x7f && (i + 1 == len(text) || text[i + 1] < 0x80) {
			v += 1
			i += 1
			continue
		}
		e := cluster_end(text, i)
		v += seg_width(text, i, e, v)
		i = e
	}
	return v
}

visual_width :: proc(text: []u8) -> int {
	return visual_col(text, len(text))
}

col_at_visual :: proc(text: []u8, target: int) -> int {
	if target <= 0 {
		return 0
	}
	v, i := 0, 0
	for i < len(text) {
		c := text[i]
		if c >= 0x20 && c < 0x7f && (i + 1 == len(text) || text[i + 1] < 0x80) {
			if target == v {
				return i
			}
			v += 1
			i += 1
			continue
		}
		e := cluster_end(text, i)
		w := seg_width(text, i, e, v)
		if target < v + w {
			return i if target - v <= v + w - target else e
		}
		v += w
		i = e
	}
	return len(text)
}

cursor_goal_sync :: proc(b: ^Buffer) {
	text := b.lines[b.cursor.row].text[:]
	if b.wrap_width > 0 {
		seg := wrap_seg_start(buffer_line_wrap(b, b.cursor.row, b.wrap_width), b.cursor.col)
		b.goal_col = visual_col(text, b.cursor.col) - visual_col(text, seg)
	} else {
		b.goal_col = visual_col(text, b.cursor.col)
	}
}

selection_active :: proc(b: ^Buffer) -> bool {
	anchor, has := b.selection.?
	return has && anchor != b.cursor
}

selection_range :: proc(b: ^Buffer) -> (from, to: Cursor, ok: bool) {
	anchor, has := b.selection.?
	if !has || anchor == b.cursor {
		return {}, {}, false
	}
	if anchor.row < b.cursor.row || (anchor.row == b.cursor.row && anchor.col < b.cursor.col) {
		return anchor, b.cursor, true
	}
	return b.cursor, anchor, true
}

// Last row a selection touches for whole-line edits: an endpoint at col 0 of a
// later row selects the line break, not that row's content.
selection_last_row :: proc(from, to: Cursor) -> int {
	if to.col == 0 && to.row > from.row {
		return to.row - 1
	}
	return to.row
}

selection_set_anchor :: proc(b: ^Buffer) {
	if _, has := b.selection.?; !has {
		b.selection = b.cursor
	}
}

cursor_select_all :: proc(b: ^Buffer) {
	last := len(b.lines) - 1
	b.selection = Cursor{0, 0}
	b.cursor = {last, len(b.lines[last].text)}
	cursor_goal_sync(b)
}

word_range_at :: proc(b: ^Buffer, at: Cursor) -> (from, to: Cursor) {
	text := b.lines[at.row].text[:]
	if len(text) == 0 {
		return at, at
	}
	col := at.col if at.col < len(text) else grapheme_prev(text, len(text))
	cls := grapheme_class(text, col)
	start := col
	for start > 0 {
		p := grapheme_prev(text, start)
		if grapheme_class(text, p) != cls {
			break
		}
		start = p
	}
	end := grapheme_next(text, col)
	for end < len(text) && grapheme_class(text, end) == cls {
		end = grapheme_next(text, end)
	}
	return {at.row, start}, {at.row, end}
}

cursor_move_left :: proc(b: ^Buffer) {
	c := &b.cursor
	if c.col > 0 {
		c.col = grapheme_prev(b.lines[c.row].text[:], c.col)
	} else if c.row > 0 {
		c.row -= 1
		c.col = len(b.lines[c.row].text)
	}
	cursor_goal_sync(b)
}

cursor_move_right :: proc(b: ^Buffer) {
	c := &b.cursor
	if c.col < len(b.lines[c.row].text) {
		c.col = grapheme_next(b.lines[c.row].text[:], c.col)
	} else if c.row < len(b.lines) - 1 {
		c.row += 1
		c.col = 0
	}
	cursor_goal_sync(b)
}

cursor_move_up_n :: proc(b: ^Buffer, n: int) {
	if b.wrap_width > 0 {
		for _ in 0 ..< n {
			cursor_visual_up(b)
		}
		return
	}
	c := &b.cursor
	if c.row - n < 0 {
		c.row = 0
		if c.col != 0 {
			c.col = 0
			cursor_goal_sync(b)
		}
	} else {
		c.row -= n
		c.col = col_at_visual(b.lines[c.row].text[:], b.goal_col)
	}
}

cursor_move_down_n :: proc(b: ^Buffer, n: int) {
	if b.wrap_width > 0 {
		for _ in 0 ..< n {
			cursor_visual_down(b)
		}
		return
	}
	c := &b.cursor
	last := len(b.lines) - 1
	if c.row + n > last {
		c.row = last
		end := len(b.lines[last].text)
		if c.col != end {
			c.col = end
			cursor_goal_sync(b)
		}
	} else {
		c.row += n
		c.col = col_at_visual(b.lines[c.row].text[:], b.goal_col)
	}
}

cursor_visual_up :: proc(b: ^Buffer) {
	w := b.wrap_width
	c := &b.cursor
	sub := wrap_subrow(buffer_line_wrap(b, c.row, w), c.col)
	if sub > 0 {
		c.col = cursor_place_in_subrow(b, c.row, w, sub - 1, b.goal_col)
	} else if c.row > 0 {
		c.row -= 1
		c.col = cursor_place_in_subrow(b, c.row, w, line_rows(b, w, c.row) - 1, b.goal_col)
	} else if c.col != 0 {
		c.col = 0
		cursor_goal_sync(b)
	}
}

cursor_visual_down :: proc(b: ^Buffer) {
	w := b.wrap_width
	c := &b.cursor
	text := b.lines[c.row].text[:]
	segs := buffer_line_wrap(b, c.row, w)
	sub := wrap_subrow(segs, c.col)
	if sub < len(segs) - 1 {
		c.col = cursor_place_in_subrow(b, c.row, w, sub + 1, b.goal_col)
	} else if c.row < len(b.lines) - 1 {
		c.row += 1
		c.col = cursor_place_in_subrow(b, c.row, w, 0, b.goal_col)
	} else if c.col != len(text) {
		c.col = len(text)
		cursor_goal_sync(b)
	}
}

cursor_move_home_smart :: proc(b: ^Buffer) {
	c := &b.cursor
	text := b.lines[c.row].text[:]
	first := 0
	for first < len(text) && (text[first] == ' ' || text[first] == '\t') {
		first += 1
	}
	if b.wrap_width > 0 {
		seg := wrap_seg_start(buffer_line_wrap(b, c.row, b.wrap_width), c.col)
		primary := first if seg == 0 else seg
		if c.col != primary {
			c.col = primary
		} else if c.col != 0 {
			c.col = 0
		} else {
			c.col = first
		}
	} else {
		c.col = home_smart_col(text, c.col)
	}
	cursor_goal_sync(b)
}

cursor_move_end :: proc(b: ^Buffer) {
	text := b.lines[b.cursor.row].text[:]
	if b.wrap_width > 0 {
		segs := buffer_line_wrap(b, b.cursor.row, b.wrap_width)
		_, end := wrap_segment(segs, len(text), wrap_subrow(segs, b.cursor.col))
		row_end := max(grapheme_prev(text, end), 0) if end < len(text) else len(text)
		b.cursor.col = len(text) if b.cursor.col == row_end else row_end
	} else {
		b.cursor.col = len(text)
	}
	cursor_goal_sync(b)
}

cursor_move_buffer_start :: proc(b: ^Buffer) {
	b.cursor = {0, 0}
	cursor_goal_sync(b)
}

cursor_move_buffer_end :: proc(b: ^Buffer) {
	b.cursor.row = len(b.lines) - 1
	b.cursor.col = len(b.lines[b.cursor.row].text)
	cursor_goal_sync(b)
}

cursor_paragraph_prev :: proc(b: ^Buffer) {
	r := b.cursor.row - 1
	for r > 0 {
		if line_is_blank(b.lines[r].text[:]) {
			b.cursor = {r, 0}
			cursor_goal_sync(b)
			return
		}
		r -= 1
	}
	cursor_move_buffer_start(b)
}

cursor_paragraph_next :: proc(b: ^Buffer) {
	r := b.cursor.row + 1
	for r < len(b.lines) {
		if line_is_blank(b.lines[r].text[:]) {
			b.cursor = {r, 0}
			cursor_goal_sync(b)
			return
		}
		r += 1
	}
	cursor_move_buffer_end(b)
}

word_left_col :: proc(text: []u8, col: int) -> int {
	col := col
	if col <= 0 {
		return 0
	}
	prev := grapheme_prev(text, col)
	cls := grapheme_class(text, prev)
	col = prev
	for col > 0 {
		p := grapheme_prev(text, col)
		if grapheme_class(text, p) != cls {
			break
		}
		col = p
	}
	return col
}

word_right_col :: proc(text: []u8, col: int) -> int {
	col := col
	if col >= len(text) {
		return len(text)
	}
	cls := grapheme_class(text, col)
	for col < len(text) && grapheme_class(text, col) == cls {
		col = grapheme_next(text, col)
	}
	return col
}

home_smart_col :: proc(text: []u8, col: int) -> int {
	first := 0
	for first < len(text) && (text[first] == ' ' || text[first] == '\t') {
		first += 1
	}
	return 0 if col == first else first
}

cursor_move_word_left :: proc(b: ^Buffer) {
	c := &b.cursor
	if c.col == 0 {
		if c.row > 0 {
			c.row -= 1
			c.col = len(b.lines[c.row].text)
		}
	} else {
		c.col = word_left_col(b.lines[c.row].text[:], c.col)
	}
	cursor_goal_sync(b)
}

cursor_move_word_right :: proc(b: ^Buffer) {
	c := &b.cursor
	text := b.lines[c.row].text[:]
	if c.col >= len(text) {
		if c.row < len(b.lines) - 1 {
			c.row += 1
			c.col = 0
		}
	} else {
		c.col = word_right_col(text, c.col)
	}
	cursor_goal_sync(b)
}

line_range_at :: proc(b: ^Buffer, row: int) -> (from, to: Cursor) {
	if row < len(b.lines) - 1 {
		return {row, 0}, {row + 1, 0}
	}
	return {row, 0}, {row, len(b.lines[row].text)}
}
