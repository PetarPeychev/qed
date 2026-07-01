package main

import "core:strings"
import "core:unicode/utf8"

EditKind :: enum {
	Insert,
	Delete,
}

Edit :: struct {
	kind: EditKind,
	at:   Cursor,
	text: string,
}

EditGroup :: struct {
	edits:  [dynamic]Edit,
	cursor: Cursor,
}

Coalesce :: enum {
	None,
	Insert,
	Delete,
	Atomic,
}

group_destroy :: proc(group: ^EditGroup) {
	for edit in group.edits {
		delete(edit.text)
	}
	delete(group.edits)
	group^ = {}
}

redo_clear :: proc(b: ^Buffer) {
	for &group in b.redo {
		group_destroy(&group)
	}
	clear(&b.redo)
}

buffer_undo_commit :: proc(b: ^Buffer) {
	if b.has_open {
		append(&b.undo, b.open)
		b.open = {}
		b.has_open = false
		b.open_kind = .None
	}
}

edit_open :: proc(b: ^Buffer, kind: Coalesce) {
	if kind == .Atomic || b.open_kind != kind {
		buffer_undo_commit(b)
	}
	redo_clear(b)
	if !b.has_open {
		b.open = EditGroup {
			cursor = b.cursor,
		}
		b.has_open = true
	}
	b.open_kind = kind
}

cursor_advance :: proc(at: Cursor, text: string) -> Cursor {
	end := at
	nl := strings.last_index_byte(text, '\n')
	if nl < 0 {
		end.col = at.col + len(text)
	} else {
		end.row = at.row + strings.count(text, "\n")
		end.col = len(text) - nl - 1
	}
	return end
}

buffer_insert_text :: proc(b: ^Buffer, text: string, kind: Coalesce = .Insert) {
	edit_open(b, kind)
	end := buffer_insert(b, b.cursor, text)
	append(&b.open.edits, Edit{.Delete, b.cursor, strings.clone(text)})
	if kind == .Atomic {
		buffer_undo_commit(b)
	}
	b.cursor = end
	b.goal_col = end.col
}

buffer_insert_rune :: proc(b: ^Buffer, r: rune) {
	bytes, n := utf8.encode_rune(r)
	buffer_insert_text(b, string(bytes[:n]), .Insert)
}

buffer_newline :: proc(b: ^Buffer) {
	buffer_insert_text(b, "\n", .Atomic)
}

buffer_insert_tab :: proc(b: ^Buffer) {
	n := TAB_WIDTH - b.cursor.col % TAB_WIDTH
	buffer_insert_text(b, strings.repeat(" ", n, context.temp_allocator), .Atomic)
}

buffer_delete_range :: proc(b: ^Buffer, from, to: Cursor, kind: Coalesce) {
	edit_open(b, kind)
	removed := buffer_delete(b, from, to)
	append(&b.open.edits, Edit{.Insert, from, removed})
	if kind == .Atomic {
		buffer_undo_commit(b)
	}
}

buffer_backspace :: proc(b: ^Buffer) {
	c := b.cursor
	from := c
	if c.col > 0 {
		from = {c.row, c.col - 1}
	} else if c.row > 0 {
		from = {c.row - 1, len(b.lines[c.row - 1].text)}
	} else {
		return
	}
	buffer_delete_range(b, from, c, .Delete)
	b.cursor = from
	b.goal_col = from.col
}

buffer_delete_forward :: proc(b: ^Buffer) {
	c := b.cursor
	to := c
	if c.col < len(b.lines[c.row].text) {
		to = {c.row, c.col + 1}
	} else if c.row < len(b.lines) - 1 {
		to = {c.row + 1, 0}
	} else {
		return
	}
	buffer_delete_range(b, c, to, .Delete)
	b.goal_col = c.col
}

buffer_type_rune :: proc(b: ^Buffer, r: rune) {
	if selection_active(b) {
		bytes, n := utf8.encode_rune(r)
		buffer_replace_selection(b, string(bytes[:n]))
	} else {
		buffer_insert_rune(b, r)
	}
}

buffer_replace_selection :: proc(b: ^Buffer, text: string) {
	from, to, ok := selection_range(b)
	if !ok {
		buffer_insert_text(b, text, .Atomic)
		return
	}
	edit_open(b, .Atomic)
	removed := buffer_delete(b, from, to)
	append(&b.open.edits, Edit{.Insert, from, removed})
	end := buffer_insert(b, from, text)
	append(&b.open.edits, Edit{.Delete, from, strings.clone(text)})
	buffer_undo_commit(b)
	b.cursor = end
	b.goal_col = end.col
	b.selection = nil
}

buffer_delete_selection :: proc(b: ^Buffer) {
	from, to, ok := selection_range(b)
	if !ok {
		return
	}
	buffer_delete_range(b, from, to, .Atomic)
	b.cursor = from
	b.goal_col = from.col
	b.selection = nil
}

buffer_indent :: proc(b: ^Buffer) {
	from, to, ok := selection_range(b)
	if !ok {
		buffer_insert_tab(b)
		return
	}
	last_row := to.row
	if to.col == 0 && to.row > from.row {
		last_row -= 1
	}
	indent := strings.repeat(" ", TAB_WIDTH, context.temp_allocator)

	edit_open(b, .Atomic)
	for row in from.row ..= last_row {
		at := Cursor{row, 0}
		buffer_insert(b, at, indent)
		append(&b.open.edits, Edit{.Delete, at, strings.clone(indent)})
	}
	buffer_undo_commit(b)

	anchor, _ := b.selection.?
	if anchor.row >= from.row && anchor.row <= last_row {
		anchor.col += TAB_WIDTH
	}
	b.selection = anchor
	if b.cursor.row >= from.row && b.cursor.row <= last_row {
		b.cursor.col += TAB_WIDTH
	}
	b.goal_col = b.cursor.col
}

dedent_count :: proc(text: []u8) -> int {
	lead := 0
	for lead < len(text) && text[lead] == ' ' {
		lead += 1
	}
	return min(lead, TAB_WIDTH)
}

buffer_dedent :: proc(b: ^Buffer) {
	from, to, ok := selection_range(b)
	first_row, last_row: int
	if ok {
		first_row = from.row
		last_row = to.row
		if to.col == 0 && to.row > from.row {
			last_row -= 1
		}
	} else {
		first_row = b.cursor.row
		last_row = b.cursor.row
	}

	any := false
	for row in first_row ..= last_row {
		if dedent_count(b.lines[row].text[:]) > 0 {
			any = true
			break
		}
	}
	if !any {
		return
	}

	anchor, _ := b.selection.?
	cursor_removed := 0
	anchor_removed := 0

	edit_open(b, .Atomic)
	for row in first_row ..= last_row {
		n := dedent_count(b.lines[row].text[:])
		if n == 0 {
			continue
		}
		at := Cursor{row, 0}
		removed := buffer_delete(b, at, {row, n})
		append(&b.open.edits, Edit{.Insert, at, removed})
		if row == b.cursor.row {
			cursor_removed = n
		}
		if row == anchor.row {
			anchor_removed = n
		}
	}
	buffer_undo_commit(b)

	b.cursor.col = max(0, b.cursor.col - cursor_removed)
	b.goal_col = b.cursor.col
	if ok {
		anchor.col = max(0, anchor.col - anchor_removed)
		b.selection = anchor
	}
}

buffer_apply_inverse :: proc(b: ^Buffer, group: EditGroup) -> EditGroup {
	result := EditGroup {
		cursor = b.cursor,
	}
	#reverse for edit in group.edits {
		switch edit.kind {
		case .Insert:
			buffer_insert(b, edit.at, edit.text)
			append(&result.edits, Edit{.Delete, edit.at, edit.text})
		case .Delete:
			to := cursor_advance(edit.at, edit.text)
			delete(buffer_delete(b, edit.at, to))
			append(&result.edits, Edit{.Insert, edit.at, edit.text})
		}
	}
	b.cursor = group.cursor
	b.goal_col = group.cursor.col
	delete(group.edits)
	return result
}

buffer_undo :: proc(b: ^Buffer) {
	buffer_undo_commit(b)
	if len(b.undo) == 0 {
		return
	}
	b.selection = nil
	group := pop(&b.undo)
	append(&b.redo, buffer_apply_inverse(b, group))
}

buffer_redo :: proc(b: ^Buffer) {
	buffer_undo_commit(b)
	if len(b.redo) == 0 {
		return
	}
	b.selection = nil
	group := pop(&b.redo)
	append(&b.undo, buffer_apply_inverse(b, group))
}
