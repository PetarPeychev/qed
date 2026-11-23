package main

import "core:c"
import "core:strings"
import "core:text/regex"
import "core:unicode"
import lua "lib:lua"

FIND_MAX_MATCHES :: 5000

FindMatch :: struct {
	row, from, to: int,
}

Find :: struct {
	active:         bool,
	buffer:         u64,
	query:          string,
	regex:          bool,
	case_sensitive: bool,
	invalid:        bool,
	matches:        [dynamic]FindMatch,
	current:        int,
	origin:         Cursor,
}

find_destroy :: proc(find: ^Find) {
	delete(find.query)
	delete(find.matches)
}

find_close :: proc(editor: ^Editor) {
	editor.find.active = false
	clear(&editor.find.matches)
}

find_ci :: proc(find: ^Find, query: string) -> bool {
	return !find.case_sensitive && smart_case_insensitive(query)
}

smart_case_insensitive :: proc(query: string) -> bool {
	for character in query {
		if unicode.is_upper(character) {
			return false
		}
	}
	return true
}

find_eq :: proc(left, right: string, insensitive: bool) -> bool {
	if !insensitive {
		return left == right
	}
	for i in 0 ..< len(left) {
		if ascii_lower(left[i]) != ascii_lower(right[i]) {
			return false
		}
	}
	return true
}

find_scan :: proc(editor: ^Editor) {
	find := &editor.find
	clear(&find.matches)
	find.invalid = false
	find.current = -1
	query := find.query
	buffer := ui_buffer(editor, find.buffer)
	if len(query) == 0 || buffer == nil {
		return
	}
	insensitive := find_ci(find, query)
	if find.regex {
		flags: regex.Flags
		if insensitive {
			flags += {.Case_Insensitive}
		}
		pattern, err := regex.create(query, flags, context.temp_allocator, context.temp_allocator)
		if err != nil {
			find.invalid = true
			return
		}
		captures := regex.preallocate_capture(context.temp_allocator)
		regex_rows: for line, row in buffer.lines {
			text := string(line.text[:])
			offset := 0
			for offset <= len(text) {
				_, ok := regex.match_with_preallocated_capture(pattern, text[offset:], &captures, context.temp_allocator)
				if !ok {
					break
				}
				from := offset + captures.pos[0][0]
				to := offset + captures.pos[0][1]
				if to <= from {
					offset = from + 1
					continue
				}
				append(&find.matches, FindMatch{row, from, to})
				if len(find.matches) >= FIND_MAX_MATCHES {
					break regex_rows
				}
				offset = to
			}
		}
	} else {
		length := len(query)
		first := ascii_lower(query[0]) if insensitive else query[0]
		plain_rows: for line, row in buffer.lines {
			text := string(line.text[:])
			start := 0
			for start + length <= len(text) {
				byte_at := ascii_lower(text[start]) if insensitive else text[start]
				if byte_at != first {
					start += 1
					continue
				}
				if find_eq(text[start:start + length], query, insensitive) {
					append(&find.matches, FindMatch{row, start, start + length})
					if len(find.matches) >= FIND_MAX_MATCHES {
						break plain_rows
					}
					start += length
				} else {
					start += 1
				}
			}
		}
	}
	find_pick_current(find)
}

find_pick_current :: proc(find: ^Find) {
	find.current = -1
	for match, i in find.matches {
		if match.row > find.origin.row || (match.row == find.origin.row && match.to >= find.origin.col) {
			find.current = i
			return
		}
	}
	if len(find.matches) > 0 {
		find.current = 0
	}
}

find_jump :: proc(editor: ^Editor) {
	find := &editor.find
	buffer := ui_buffer(editor, find.buffer)
	if buffer == nil || find.current < 0 || find.current >= len(find.matches) {
		return
	}
	match := find.matches[find.current]
	buffer.selection = Cursor{match.row, match.from}
	buffer.cursor = {match.row, match.to}
	cursor_goal_sync(buffer)
	if !editor.welcome && editor_buffer(editor) == buffer {
		editor_scroll(editor)
	}
}

find_step :: proc(editor: ^Editor, direction: int) {
	find := &editor.find
	count := len(find.matches)
	if count == 0 {
		return
	}
	if find.current < 0 {
		find.current = 0 if direction > 0 else count - 1
	} else {
		find.current = (find.current + direction + count) % count
	}
	find_jump(editor)
}

find_replace :: proc(editor: ^Editor, replacement: string, all: bool) -> int {
	find := &editor.find
	buffer := ui_buffer(editor, find.buffer)
	if buffer == nil || len(find.matches) == 0 || (!all && (find.current < 0 || find.current >= len(find.matches))) {
		return 0
	}
	edit_open(buffer, .Atomic)
	count := 0
	if all {
		#reverse for match in find.matches {
			edit_delete(buffer, {match.row, match.from}, {match.row, match.to})
			edit_insert(buffer, {match.row, match.from}, replacement)
			count += 1
		}
		find.origin = buffer.cursor
	} else {
		match := find.matches[find.current]
		edit_delete(buffer, {match.row, match.from}, {match.row, match.to})
		edit_insert(buffer, {match.row, match.from}, replacement)
		find.origin = {match.row, match.from + len(replacement)}
		count = 1
	}
	buffer_undo_commit(buffer)
	find_scan(editor)
	find_jump(editor)
	return count
}

find_row_spans :: proc(editor: ^Editor, row: int) -> [][2]int {
	find := &editor.find
	out := make([dynamic][2]int, context.temp_allocator)
	for match in find.matches {
		if match.row == row {
			append(&out, [2]int{match.from, match.to})
		}
	}
	return out[:]
}

find_shows :: proc(editor: ^Editor, buffer: ^Buffer) -> bool {
	return editor.find.active && buffer != nil && buffer.id == editor.find.buffer
}

find_result_push :: proc(L: ^lua.State, find: ^Find) -> c.int {
	lua.pushinteger(L, lua.Integer(find.current + 1 if find.current >= 0 else 0))
	lua.pushinteger(L, lua.Integer(len(find.matches)))
	return 2
}

qed_buf_find :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	buffer, _ := api_buf(L, editor, 1)
	query := api_string(L, 2)
	find := &editor.find
	find.regex, find.case_sensitive = false, false
	if lua.type(L, 3) == .TABLE {
		lua.getfield(L, 3, "regex")
		find.regex = bool(lua.toboolean(L, -1))
		lua.getfield(L, 3, "case_sensitive")
		find.case_sensitive = bool(lua.toboolean(L, -1))
		lua.pop(L, 2)
	}
	if !find.active || find.buffer != buffer.id {
		find.origin = buffer.cursor
		if from, _, ok := selection_range(buffer); ok {
			find.origin = from
		}
	}
	find.active = true
	find.buffer = buffer.id
	delete(find.query)
	find.query = strings.clone(query)
	find_scan(editor)
	find_jump(editor)
	if find.invalid {
		lua.pushnil(L)
		lua.pushstring(L, "invalid pattern")
		return 2
	}
	return find_result_push(L, find)
}

qed_buf_find_step :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	buffer, _ := api_buf(L, editor, 1)
	if !find_shows(editor, buffer) {
		lua.pushnil(L)
		return 1
	}
	find_step(editor, 1 if api_int(L, 2, "direction expected (1 or -1)") >= 0 else -1)
	return find_result_push(L, &editor.find)
}

qed_buf_find_replace :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	buffer, _ := api_buf(L, editor, 1)
	replacement := api_string(L, 2)
	all := false
	if lua.type(L, 3) == .TABLE {
		lua.getfield(L, 3, "all")
		all = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	}
	if !find_shows(editor, buffer) {
		lua.pushinteger(L, 0)
		return 1
	}
	lua.pushinteger(L, lua.Integer(find_replace(editor, replacement, all)))
	return 1
}

qed_buf_find_clear :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	buffer, _ := api_buf(L, editor, 1)
	if find_shows(editor, buffer) {
		find_close(editor)
	}
	return 0
}
