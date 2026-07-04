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
	tx:     int,
}

g_tx_seq: int

tx_next :: proc() -> int {
	g_tx_seq += 1
	return g_tx_seq
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
	cursor_goal_sync(b)
}

buffer_insert_rune :: proc(b: ^Buffer, r: rune) {
	bytes, n := utf8.encode_rune(r)
	buffer_insert_text(b, string(bytes[:n]), .Insert)
}

buffer_newline :: proc(b: ^Buffer) {
	row := b.cursor.row
	line := b.lines[row].text[:]
	indent_len := 0
	for indent_len < len(line) && (line[indent_len] == ' ' || line[indent_len] == '\t') {
		indent_len += 1
	}
	indent_len = min(indent_len, b.cursor.col)
	text := strings.concatenate({"\n", string(line[:indent_len])}, context.temp_allocator)

	edit_open(b, .Atomic)
	end := buffer_insert(b, b.cursor, text)
	append(&b.open.edits, Edit{.Delete, b.cursor, strings.clone(text)})

	prev := b.lines[row].text[:]
	if len(prev) > 0 && line_is_blank(prev) {
		removed := buffer_delete(b, {row, 0}, {row, len(prev)})
		append(&b.open.edits, Edit{.Insert, {row, 0}, removed})
	}
	buffer_undo_commit(b)

	b.cursor = end
	cursor_goal_sync(b)
}

line_is_blank :: proc(text: []u8) -> bool {
	for c in text {
		if c != ' ' && c != '\t' {
			return false
		}
	}
	return true
}

line_indent_len :: proc(text: []u8) -> int {
	n := 0
	for n < len(text) && (text[n] == ' ' || text[n] == '\t') {
		n += 1
	}
	return n
}

comment_shift_col :: proc(col, row, target_row, at, delta: int) -> int {
	if row != target_row {
		return col
	}
	if delta >= 0 {
		return col + delta if col >= at else col
	}
	m := -delta
	if col <= at {
		return col
	}
	if col >= at + m {
		return col - m
	}
	return at
}

buffer_toggle_comment :: proc(b: ^Buffer) {
	token := LANGUAGES[b.language].comment
	if token == "" {
		return
	}
	from, to, sel := selection_range(b)
	first_row := b.cursor.row
	last_row := b.cursor.row
	if sel {
		first_row = from.row
		last_row = to.row
		if to.col == 0 && to.row > from.row {
			last_row -= 1
		}
	}

	all_commented := true
	any := false
	min_indent := max(int)
	for row in first_row ..= last_row {
		text := b.lines[row].text[:]
		if line_is_blank(text) {
			continue
		}
		any = true
		ind := line_indent_len(text)
		min_indent = min(min_indent, ind)
		if !strings.has_prefix(string(text[ind:]), token) {
			all_commented = false
		}
	}
	if !any {
		return
	}

	cur := b.cursor
	anchor, has_anchor := b.selection.?
	new_cur_col := cur.col
	new_anchor_col := anchor.col

	edit_open(b, .Atomic)
	if all_commented {
		for row in first_row ..= last_row {
			text := b.lines[row].text[:]
			if line_is_blank(text) {
				continue
			}
			ind := line_indent_len(text)
			n := len(token)
			if ind + n < len(text) && text[ind + n] == ' ' {
				n += 1
			}
			at := Cursor{row, ind}
			removed := buffer_delete(b, at, {row, ind + n})
			append(&b.open.edits, Edit{.Insert, at, removed})
			new_cur_col = comment_shift_col(new_cur_col, row, cur.row, ind, -n)
			new_anchor_col = comment_shift_col(new_anchor_col, row, anchor.row, ind, -n)
		}
	} else {
		insert := strings.concatenate({token, " "}, context.temp_allocator)
		shift := len(insert)
		for row in first_row ..= last_row {
			text := b.lines[row].text[:]
			if line_is_blank(text) {
				continue
			}
			at := Cursor{row, min_indent}
			buffer_insert(b, at, insert)
			append(&b.open.edits, Edit{.Delete, at, strings.clone(insert)})
			new_cur_col = comment_shift_col(new_cur_col, row, cur.row, min_indent, shift)
			new_anchor_col = comment_shift_col(new_anchor_col, row, anchor.row, min_indent, shift)
		}
	}
	buffer_undo_commit(b)

	b.cursor.col = new_cur_col
	cursor_goal_sync(b)
	if has_anchor {
		anchor.col = new_anchor_col
		b.selection = anchor
	}
}

buffer_insert_tab :: proc(b: ^Buffer) {
	if b.indent == .Tabs {
		buffer_insert_text(b, "\t", .Atomic)
		return
	}
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
		from = {c.row, grapheme_prev(b.lines[c.row].text[:], c.col)}
	} else if c.row > 0 {
		from = {c.row - 1, len(b.lines[c.row - 1].text)}
	} else {
		return
	}
	buffer_delete_range(b, from, c, .Delete)
	b.cursor = from
	cursor_goal_sync(b)
}

buffer_delete_forward :: proc(b: ^Buffer) {
	c := b.cursor
	to := c
	if c.col < len(b.lines[c.row].text) {
		to = {c.row, grapheme_next(b.lines[c.row].text[:], c.col)}
	} else if c.row < len(b.lines) - 1 {
		to = {c.row + 1, 0}
	} else {
		return
	}
	buffer_delete_range(b, c, to, .Delete)
	cursor_goal_sync(b)
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
	cursor_goal_sync(b)
	b.selection = nil
}

buffer_paste :: proc(b: ^Buffer, text: string) {
	if selection_active(b) {
		buffer_replace_selection(b, text)
	} else {
		buffer_insert_text(b, text, .Atomic)
	}
}

buffer_delete_selection :: proc(b: ^Buffer) {
	from, to, ok := selection_range(b)
	if !ok {
		return
	}
	buffer_delete_range(b, from, to, .Atomic)
	b.cursor = from
	cursor_goal_sync(b)
	b.selection = nil
}

buffer_delete_line :: proc(b: ^Buffer) {
	r := b.cursor.row
	col := b.cursor.col
	if len(b.lines) == 1 {
		buffer_delete_range(b, {r, 0}, {r, len(b.lines[r].text)}, .Atomic)
		b.cursor = {0, 0}
	} else if r < len(b.lines) - 1 {
		buffer_delete_range(b, {r, 0}, {r + 1, 0}, .Atomic)
		b.cursor = {r, min(col, len(b.lines[r].text))}
	} else {
		prev_len := len(b.lines[r - 1].text)
		buffer_delete_range(b, {r - 1, prev_len}, {r, len(b.lines[r].text)}, .Atomic)
		b.cursor = {r - 1, min(col, len(b.lines[r - 1].text))}
	}
	cursor_goal_sync(b)
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
	indent := "\t" if b.indent == .Tabs else strings.repeat(" ", TAB_WIDTH, context.temp_allocator)
	shift := len(indent)

	edit_open(b, .Atomic)
	for row in from.row ..= last_row {
		at := Cursor{row, 0}
		buffer_insert(b, at, indent)
		append(&b.open.edits, Edit{.Delete, at, strings.clone(indent)})
	}
	buffer_undo_commit(b)

	anchor, _ := b.selection.?
	if anchor.row >= from.row && anchor.row <= last_row {
		anchor.col += shift
	}
	b.selection = anchor
	if b.cursor.row >= from.row && b.cursor.row <= last_row {
		b.cursor.col += shift
	}
	cursor_goal_sync(b)
}

dedent_count :: proc(text: []u8) -> int {
	if len(text) > 0 && text[0] == '\t' {
		return 1
	}
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
	cursor_goal_sync(b)
	if ok {
		anchor.col = max(0, anchor.col - anchor_removed)
		b.selection = anchor
	}
}

buffer_move_lines :: proc(b: ^Buffer, delta: int) {
	from, to, sel := selection_range(b)
	top := b.cursor.row
	bot := b.cursor.row
	if sel {
		top = from.row
		bot = to.row
		if to.col == 0 && to.row > from.row {
			bot -= 1
		}
	}
	if delta < 0 && top == 0 {
		return
	}
	if delta > 0 && bot >= len(b.lines) - 1 {
		return
	}

	span_top, span_bot: int
	sb := strings.builder_make(context.temp_allocator)
	if delta < 0 {
		span_top = top - 1
		span_bot = bot
		for r in top ..= bot {
			strings.write_bytes(&sb, b.lines[r].text[:])
			strings.write_byte(&sb, '\n')
		}
		strings.write_bytes(&sb, b.lines[top - 1].text[:])
	} else {
		span_top = top
		span_bot = bot + 1
		strings.write_bytes(&sb, b.lines[bot + 1].text[:])
		for r in top ..= bot {
			strings.write_byte(&sb, '\n')
			strings.write_bytes(&sb, b.lines[r].text[:])
		}
	}

	del_from := Cursor{span_top, 0}
	del_to: Cursor
	insert_text: string
	if span_bot < len(b.lines) - 1 {
		del_to = Cursor{span_bot + 1, 0}
		insert_text = strings.concatenate({strings.to_string(sb), "\n"}, context.temp_allocator)
	} else {
		del_to = Cursor{span_bot, len(b.lines[span_bot].text)}
		insert_text = strings.to_string(sb)
	}

	edit_open(b, .Atomic)
	removed := buffer_delete(b, del_from, del_to)
	append(&b.open.edits, Edit{.Insert, del_from, removed})
	buffer_insert(b, del_from, insert_text)
	append(&b.open.edits, Edit{.Delete, del_from, strings.clone(insert_text)})
	buffer_undo_commit(b)

	b.cursor.row = clamp(b.cursor.row + delta, 0, len(b.lines) - 1)
	b.cursor.col = min(b.cursor.col, len(b.lines[b.cursor.row].text))
	if anchor, has := b.selection.?; has {
		anchor.row = clamp(anchor.row + delta, 0, len(b.lines) - 1)
		anchor.col = min(anchor.col, len(b.lines[anchor.row].text))
		b.selection = anchor
	}
	cursor_goal_sync(b)
}

buffer_apply_inverse :: proc(b: ^Buffer, group: EditGroup) -> EditGroup {
	result := EditGroup {
		cursor = b.cursor,
		tx     = group.tx,
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
	cursor_goal_sync(b)
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

// A transaction is intact only if no buffer holds a member group buried under a
// newer one; otherwise the step decomposes into a plain per-buffer undo/redo.
tx_intact :: proc(editor: ^Editor, tx: int, is_undo: bool) -> bool {
	for &b in editor.buffers {
		stack := b.undo if is_undo else b.redo
		for g, i in stack {
			if g.tx == tx && i != len(stack) - 1 {
				return false
			}
		}
	}
	return true
}

editor_undo :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	buffer_undo_commit(b)
	if len(b.undo) == 0 {
		return
	}
	tx := b.undo[len(b.undo) - 1].tx
	if tx == 0 {
		buffer_undo(b)
		return
	}
	for &bb in editor.buffers {
		buffer_undo_commit(&bb)
	}
	if !tx_intact(editor, tx, true) {
		buffer_undo(b)
		return
	}
	for &bb in editor.buffers {
		if len(bb.undo) > 0 && bb.undo[len(bb.undo) - 1].tx == tx {
			bb.selection = nil
			append(&bb.redo, buffer_apply_inverse(&bb, pop(&bb.undo)))
		}
	}
}

editor_redo :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	buffer_undo_commit(b)
	if len(b.redo) == 0 {
		return
	}
	tx := b.redo[len(b.redo) - 1].tx
	if tx == 0 {
		buffer_redo(b)
		return
	}
	for &bb in editor.buffers {
		buffer_undo_commit(&bb)
	}
	if !tx_intact(editor, tx, false) {
		buffer_redo(b)
		return
	}
	for &bb in editor.buffers {
		if len(bb.redo) > 0 && bb.redo[len(bb.redo) - 1].tx == tx {
			bb.selection = nil
			append(&bb.undo, buffer_apply_inverse(&bb, pop(&bb.redo)))
		}
	}
}
