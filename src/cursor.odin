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
	b.goal_col = b.cursor.col
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
	b.goal_col = c.col
}

cursor_move_right :: proc(b: ^Buffer) {
	c := &b.cursor
	if c.col < len(b.lines[c.row].text) {
		c.col += 1
	} else if c.row < len(b.lines) - 1 {
		c.row += 1
		c.col = 0
	}
	b.goal_col = c.col
}

cursor_move_up_n :: proc(b: ^Buffer, n: int) {
	c := &b.cursor
	c.row = max(0, c.row - n)
	c.col = min(b.goal_col, len(b.lines[c.row].text))
}

cursor_move_down_n :: proc(b: ^Buffer, n: int) {
	c := &b.cursor
	c.row = min(len(b.lines) - 1, c.row + n)
	c.col = min(b.goal_col, len(b.lines[c.row].text))
}

cursor_move_home :: proc(b: ^Buffer) {
	b.cursor.col = 0
	b.goal_col = 0
}

cursor_move_end :: proc(b: ^Buffer) {
	b.cursor.col = len(b.lines[b.cursor.row].text)
	b.goal_col = b.cursor.col
}

cursor_move_buffer_start :: proc(b: ^Buffer) {
	b.cursor = {0, 0}
	b.goal_col = 0
}

cursor_move_buffer_end :: proc(b: ^Buffer) {
	b.cursor.row = len(b.lines) - 1
	b.cursor.col = len(b.lines[b.cursor.row].text)
	b.goal_col = b.cursor.col
}

cursor_move_word_left :: proc(b: ^Buffer) {
	c := &b.cursor
	if c.col == 0 {
		if c.row > 0 {
			c.row -= 1
			c.col = len(b.lines[c.row].text)
		}
		b.goal_col = c.col
		return
	}

	text := b.lines[c.row].text[:]
	cls := char_class(text[c.col - 1])
	for c.col > 0 && char_class(text[c.col - 1]) == cls {
		c.col -= 1
	}
	b.goal_col = c.col
}

cursor_move_word_right :: proc(b: ^Buffer) {
	c := &b.cursor
	text := b.lines[c.row].text[:]
	if c.col >= len(text) {
		if c.row < len(b.lines) - 1 {
			c.row += 1
			c.col = 0
		}
		b.goal_col = c.col
		return
	}

	cls := char_class(text[c.col])
	for c.col < len(text) && char_class(text[c.col]) == cls {
		c.col += 1
	}
	b.goal_col = c.col
}
