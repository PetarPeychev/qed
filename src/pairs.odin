package main

import "core:strings"

pair_close_for_open :: proc(c: u8) -> (u8, bool) {
	switch c {
	case '(':
		return ')', true
	case '[':
		return ']', true
	case '{':
		return '}', true
	case '"':
		return '"', true
	case '\'':
		return '\'', true
	case '`':
		return '`', true
	}
	return 0, false
}

is_close_bracket :: proc(c: u8) -> bool {
	return c == ')' || c == ']' || c == '}'
}

is_quote :: proc(c: u8) -> bool {
	return c == '"' || c == '\'' || c == '`'
}

is_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// Auto-close typing. Returns true when it consumed the rune (inserted a pair,
// surrounded the selection, or typed over an existing closer); false to fall
// back to plain insertion.
buffer_type_pair :: proc(b: ^Buffer, r: rune) -> bool {
	if !AUTO_CLOSE_PAIRS || r > 0x7f {
		return false
	}
	c := u8(r)

	if selection_active(b) {
		if close, ok := pair_close_for_open(c); ok {
			buffer_surround(b, c, close)
			return true
		}
		return false
	}

	line := b.lines[b.cursor.row].text[:]
	col := b.cursor.col
	next: u8 = line[col] if col < len(line) else 0
	prev: u8 = line[col - 1] if col > 0 else 0

	if is_close_bracket(c) {
		if next == c {
			buffer_pair_skip(b)
			return true
		}
		return false
	}
	if is_quote(c) {
		if next == c {
			buffer_pair_skip(b)
			return true
		}
		if is_word_byte(prev) || is_word_byte(next) {
			return false
		}
		buffer_insert_pair(b, c, c)
		return true
	}
	if close, ok := pair_close_for_open(c); ok {
		if is_word_byte(next) {
			return false
		}
		buffer_insert_pair(b, c, close)
		return true
	}
	return false
}

buffer_insert_pair :: proc(b: ^Buffer, open, close: u8) {
	buf := [2]u8{open, close}
	buffer_insert_text(b, string(buf[:]), .Atomic)
	b.cursor.col -= 1
	cursor_goal_sync(b)
}

buffer_pair_skip :: proc(b: ^Buffer) {
	buffer_undo_commit(b)
	b.cursor.col += 1
	cursor_goal_sync(b)
	b.selection = nil
}

// Wrap the selection in open/close as one undo group. Insert open first so the
// close offset shifts with it on a single-row selection; recorded inverses then
// undo right-to-left without positions drifting.
buffer_surround :: proc(b: ^Buffer, open, close: u8) {
	from, to, _ := selection_range(b)
	ob := [1]u8{open}
	cb := [1]u8{close}

	close_at := to
	if to.row == from.row {
		close_at.col += 1
	}

	edit_open(b, .Atomic)
	buffer_insert(b, from, string(ob[:]))
	append(&b.open.edits, Edit{.Delete, from, strings.clone(string(ob[:]))})
	buffer_insert(b, close_at, string(cb[:]))
	append(&b.open.edits, Edit{.Delete, close_at, strings.clone(string(cb[:]))})
	buffer_undo_commit(b)

	b.selection = Cursor{from.row, from.col + 1}
	b.cursor = close_at
	cursor_goal_sync(b)
}

// Backspace over an empty auto-closed pair deletes both halves. Returns true
// when it handled the backspace.
buffer_backspace_pair :: proc(b: ^Buffer) -> bool {
	if !AUTO_CLOSE_PAIRS {
		return false
	}
	c := b.cursor
	if c.col == 0 {
		return false
	}
	line := b.lines[c.row].text[:]
	prev := line[c.col - 1]
	close, ok := pair_close_for_open(prev)
	if !ok || c.col >= len(line) || line[c.col] != close {
		return false
	}
	from := Cursor{c.row, c.col - 1}
	buffer_delete_range(b, from, {c.row, c.col + 1}, .Atomic)
	b.cursor = from
	cursor_goal_sync(b)
	return true
}

bracket_pair :: proc(c: u8) -> (open, close: u8, is_open, ok: bool) {
	switch c {
	case '(':
		return '(', ')', true, true
	case ')':
		return '(', ')', false, true
	case '[':
		return '[', ']', true, true
	case ']':
		return '[', ']', false, true
	case '{':
		return '{', '}', true, true
	case '}':
		return '{', '}', false, true
	}
	return 0, 0, false, false
}

// Locate the bracket the cursor sits on (preferring the char after the caret,
// then the char before) and its nesting partner. Plain byte scan with per-type
// depth counting — no string/comment awareness.
bracket_match :: proc(b: ^Buffer) -> (self, partner: Cursor, ok: bool) {
	line := b.lines[b.cursor.row].text[:]
	col := b.cursor.col
	pos := Cursor{-1, -1}
	if col < len(line) {
		if _, _, _, is := bracket_pair(line[col]); is {
			pos = {b.cursor.row, col}
		}
	}
	if pos.row < 0 && col > 0 {
		if _, _, _, is := bracket_pair(line[col - 1]); is {
			pos = {b.cursor.row, col - 1}
		}
	}
	if pos.row < 0 {
		return {}, {}, false
	}

	open, close, is_open, _ := bracket_pair(b.lines[pos.row].text[pos.col])
	m: Cursor
	found: bool
	if is_open {
		m, found = bracket_scan_forward(b, pos, open, close)
	} else {
		m, found = bracket_scan_backward(b, pos, open, close)
	}
	if !found {
		return {}, {}, false
	}
	return pos, m, true
}

bracket_scan_forward :: proc(b: ^Buffer, start: Cursor, open, close: u8) -> (Cursor, bool) {
	depth := 0
	c := start.col
	for r in start.row ..< len(b.lines) {
		line := b.lines[r].text[:]
		for c < len(line) {
			switch line[c] {
			case open:
				depth += 1
			case close:
				depth -= 1
				if depth == 0 {
					return {r, c}, true
				}
			}
			c += 1
		}
		c = 0
	}
	return {}, false
}

bracket_scan_backward :: proc(b: ^Buffer, start: Cursor, open, close: u8) -> (Cursor, bool) {
	depth := 0
	c := start.col
	for r := start.row; r >= 0; r -= 1 {
		line := b.lines[r].text[:]
		for c >= 0 {
			if c < len(line) {
				switch line[c] {
				case close:
					depth += 1
				case open:
					depth -= 1
					if depth == 0 {
						return {r, c}, true
					}
				}
			}
			c -= 1
		}
		if r > 0 {
			c = len(b.lines[r - 1].text) - 1
		}
	}
	return {}, false
}
