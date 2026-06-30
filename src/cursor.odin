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
