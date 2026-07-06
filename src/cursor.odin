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
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if g.byte_index > col {
			return g.byte_index
		}
	}
	return len(text)
}

grapheme_prev :: proc(text: []u8, col: int) -> int {
	prev := 0
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if g.byte_index >= col {
			break
		}
		prev = g.byte_index
	}
	return prev
}

cluster_width :: proc(cluster: []u8) -> int {
	wmax := -1
	vs15, vs16, ri, zwj := 0, 0, 0, 0
	rest := cluster
	for len(rest) > 0 {
		r, n := utf8.decode_rune(rest)
		rest = rest[n:]
		switch r {
		case 0xfe0e:
			vs15 += 1
		case 0xfe0f:
			vs16 += 1
		case 0x200d:
			zwj += 1
		case:
			if r >= 0x1f1e6 && r <= 0x1f1ff {
				ri += 1
			}
		}
		w := int(tb2.wcwidth(r))
		if w > wmax {
			wmax = w
		}
	}
	if wmax >= 1 {
		if vs15 > 0 {
			return 1
		} else if vs16 > 0 || zwj > 0 || ri >= 2 {
			return 2
		}
	}
	return max(wmax, 1)
}

seg_width :: proc(text: []u8, start, end, v: int) -> int {
	if text[start] == '\t' {
		return (v / TAB_WIDTH + 1) * TAB_WIDTH - v
	}
	return cluster_width(text[start:end])
}

visual_col :: proc(text: []u8, col: int) -> int {
	v := 0
	start := -1
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if start >= 0 && start < col {
			v += seg_width(text, start, g.byte_index, v)
		}
		start = g.byte_index
	}
	if start >= 0 && start < col {
		v += seg_width(text, start, len(text), v)
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
	v := 0
	start := -1
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if start >= 0 {
			w := seg_width(text, start, g.byte_index, v)
			if target < v + w {
				return start if target - v <= v + w - target else g.byte_index
			}
			v += w
		}
		start = g.byte_index
	}
	if start >= 0 {
		w := seg_width(text, start, len(text), v)
		if target < v + w {
			return start if target - v <= v + w - target else len(text)
		}
	}
	return len(text)
}

cursor_goal_sync :: proc(b: ^Buffer) {
	text := b.lines[b.cursor.row].text[:]
	if b.wrap && b.wrap_width > 0 {
		seg := wrap_seg_start(text, b.wrap_width, b.cursor.col)
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

line_range_at :: proc(b: ^Buffer, row: int) -> (from, to: Cursor) {
	if row < len(b.lines) - 1 {
		return {row, 0}, {row + 1, 0}
	}
	return {row, 0}, {row, len(b.lines[row].text)}
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
	if b.wrap && b.wrap_width > 0 {
		for _ in 0 ..< n {
			cursor_visual_up(b)
		}
		return
	}
	c := &b.cursor
	c.row = max(0, c.row - n)
	c.col = col_at_visual(b.lines[c.row].text[:], b.goal_col)
}

cursor_move_down_n :: proc(b: ^Buffer, n: int) {
	if b.wrap && b.wrap_width > 0 {
		for _ in 0 ..< n {
			cursor_visual_down(b)
		}
		return
	}
	c := &b.cursor
	c.row = min(len(b.lines) - 1, c.row + n)
	c.col = col_at_visual(b.lines[c.row].text[:], b.goal_col)
}

cursor_visual_up :: proc(b: ^Buffer) {
	w := b.wrap_width
	c := &b.cursor
	text := b.lines[c.row].text[:]
	sub := wrap_subrow(text, w, c.col)
	if sub > 0 {
		c.col = cursor_place_in_subrow(text, w, sub - 1, b.goal_col)
	} else if c.row > 0 {
		c.row -= 1
		up := b.lines[c.row].text[:]
		c.col = cursor_place_in_subrow(up, w, wrap_rows(up, w) - 1, b.goal_col)
	}
}

cursor_visual_down :: proc(b: ^Buffer) {
	w := b.wrap_width
	c := &b.cursor
	text := b.lines[c.row].text[:]
	sub := wrap_subrow(text, w, c.col)
	if sub < wrap_rows(text, w) - 1 {
		c.col = cursor_place_in_subrow(text, w, sub + 1, b.goal_col)
	} else if c.row < len(b.lines) - 1 {
		c.row += 1
		c.col = cursor_place_in_subrow(b.lines[c.row].text[:], w, 0, b.goal_col)
	}
}

cursor_move_home_smart :: proc(b: ^Buffer) {
	c := &b.cursor
	text := b.lines[c.row].text[:]
	first := 0
	for first < len(text) && (text[first] == ' ' || text[first] == '\t') {
		first += 1
	}
	if b.wrap && b.wrap_width > 0 {
		seg := wrap_seg_start(text, b.wrap_width, c.col)
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
	if b.wrap && b.wrap_width > 0 {
		_, end := wrap_segment(text, b.wrap_width, wrap_subrow(text, b.wrap_width, b.cursor.col))
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
