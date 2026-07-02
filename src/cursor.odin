package main

CharClass :: enum {
	Whitespace,
	Word,
	Punct,
}

char_class :: proc(c: u8) -> CharClass {
	switch c {
	case ' ', '\t':
		return .Whitespace
	case '_', 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return .Word
	case:
		return .Punct
	}
}

visual_col :: proc(text: []u8, col: int) -> int {
	v := 0
	for i in 0 ..< col {
		if text[i] == '\t' {
			v = (v / TAB_WIDTH + 1) * TAB_WIDTH
		} else {
			v += 1
		}
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
	for i in 0 ..< len(text) {
		width := 1
		if text[i] == '\t' {
			width = (v / TAB_WIDTH + 1) * TAB_WIDTH - v
		}
		if target < v + width {
			return i if target - v <= v + width - target else i + 1
		}
		v += width
	}
	return len(text)
}

cursor_goal_sync :: proc(b: ^Buffer) {
	b.goal_col = visual_col(b.lines[b.cursor.row].text[:], b.cursor.col)
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
	col := min(at.col, len(text) - 1)
	cls := char_class(text[col])
	start := col
	for start > 0 && char_class(text[start - 1]) == cls {
		start -= 1
	}
	end := col
	for end < len(text) && char_class(text[end]) == cls {
		end += 1
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
		c.col -= 1
	} else if c.row > 0 {
		c.row -= 1
		c.col = len(b.lines[c.row].text)
	}
	cursor_goal_sync(b)
}

cursor_move_right :: proc(b: ^Buffer) {
	c := &b.cursor
	if c.col < len(b.lines[c.row].text) {
		c.col += 1
	} else if c.row < len(b.lines) - 1 {
		c.row += 1
		c.col = 0
	}
	cursor_goal_sync(b)
}

cursor_move_up_n :: proc(b: ^Buffer, n: int) {
	c := &b.cursor
	c.row = max(0, c.row - n)
	c.col = col_at_visual(b.lines[c.row].text[:], b.goal_col)
}

cursor_move_down_n :: proc(b: ^Buffer, n: int) {
	c := &b.cursor
	c.row = min(len(b.lines) - 1, c.row + n)
	c.col = col_at_visual(b.lines[c.row].text[:], b.goal_col)
}

cursor_move_home :: proc(b: ^Buffer) {
	b.cursor.col = 0
	cursor_goal_sync(b)
}

cursor_move_end :: proc(b: ^Buffer) {
	b.cursor.col = len(b.lines[b.cursor.row].text)
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

cursor_move_word_left :: proc(b: ^Buffer) {
	c := &b.cursor
	if c.col == 0 {
		if c.row > 0 {
			c.row -= 1
			c.col = len(b.lines[c.row].text)
		}
		cursor_goal_sync(b)
		return
	}

	text := b.lines[c.row].text[:]
	cls := char_class(text[c.col - 1])
	for c.col > 0 && char_class(text[c.col - 1]) == cls {
		c.col -= 1
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
		cursor_goal_sync(b)
		return
	}

	cls := char_class(text[c.col])
	for c.col < len(text) && char_class(text[c.col]) == cls {
		c.col += 1
	}
	cursor_goal_sync(b)
}
