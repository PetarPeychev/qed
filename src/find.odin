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

Search :: struct {
	id:             u64,
	owner:          string,
	buffer:         u64,
	query:          string,
	regex:          bool,
	case_sensitive: bool,
	invalid:        bool,
	capped:         bool,
	matches:        [dynamic]FindMatch,
	current:        int,
	origin:         Cursor,
	rev:            u64,
}

search_free :: proc(search: ^Search) {
	delete(search.query)
	delete(search.matches)
	free(search)
}

searches_destroy :: proc(editor: ^Editor) {
	for search in editor.searches {
		search_free(search)
	}
	delete(editor.searches)
}

search_find :: proc(editor: ^Editor, id: u64) -> ^Search {
	for search in editor.searches {
		if search.id == id {
			return search
		}
	}
	return nil
}

search_close :: proc(editor: ^Editor, id: u64) {
	for search, i in editor.searches {
		if search.id == id {
			search_free(search)
			ordered_remove(&editor.searches, i)
			return
		}
	}
}

searches_buffer_closed :: proc(editor: ^Editor, buffer: u64) {
	for i := len(editor.searches) - 1; i >= 0; i -= 1 {
		if editor.searches[i].buffer == buffer {
			search_free(editor.searches[i])
			ordered_remove(&editor.searches, i)
		}
	}
}

searches_unload :: proc(editor: ^Editor, owner: string) {
	for i := len(editor.searches) - 1; i >= 0; i -= 1 {
		if editor.searches[i].owner == owner {
			search_free(editor.searches[i])
			ordered_remove(&editor.searches, i)
		}
	}
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

search_scan :: proc(editor: ^Editor, search: ^Search) {
	clear(&search.matches)
	search.invalid = false
	search.capped = false
	search.current = -1
	buffer := ui_buffer(editor, search.buffer)
	if buffer == nil {
		return
	}
	search.rev = buffer.rev
	query := search.query
	if len(query) == 0 {
		return
	}
	insensitive := !search.case_sensitive && smart_case_insensitive(query)
	if search.regex {
		flags: regex.Flags
		if insensitive {
			flags += {.Case_Insensitive}
		}
		pattern, err := regex.create(query, flags, context.temp_allocator, context.temp_allocator)
		if err != nil {
			search.invalid = true
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
				append(&search.matches, FindMatch{row, from, to})
				if len(search.matches) >= FIND_MAX_MATCHES {
					search.capped = true
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
					append(&search.matches, FindMatch{row, start, start + length})
					if len(search.matches) >= FIND_MAX_MATCHES {
						search.capped = true
						break plain_rows
					}
					start += length
				} else {
					start += 1
				}
			}
		}
	}
	search.current = -1
	for match, i in search.matches {
		if match.row > search.origin.row || (match.row == search.origin.row && match.to >= search.origin.col) {
			search.current = i
			break
		}
	}
	if search.current < 0 && len(search.matches) > 0 {
		search.current = 0
	}
}

search_fresh :: proc(editor: ^Editor, search: ^Search) -> ^Buffer {
	buffer := ui_buffer(editor, search.buffer)
	if buffer == nil {
		clear(&search.matches)
		search.current = -1
		return nil
	}
	if buffer.rev != search.rev {
		if search.current >= 0 && search.current < len(search.matches) {
			match := search.matches[search.current]
			search.origin = buffer_pos_clamp(buffer, {match.row, match.from})
		}
		search_scan(editor, search)
	}
	return buffer
}

search_select :: proc(editor: ^Editor, search: ^Search, buffer: ^Buffer) {
	if search.current < 0 || search.current >= len(search.matches) {
		return
	}
	match := search.matches[search.current]
	buffer.selection = Cursor{match.row, match.from}
	buffer.cursor = {match.row, match.to}
	cursor_goal_sync(buffer)
}

search_replace :: proc(editor: ^Editor, search: ^Search, replacement: string, all: bool) -> int {
	buffer := search_fresh(editor, search)
	if buffer == nil || len(search.matches) == 0 || (!all && (search.current < 0 || search.current >= len(search.matches))) {
		return 0
	}
	targets := search.matches[:] if all else search.matches[search.current:search.current + 1]
	for match in targets {
		if match.row >= len(buffer.lines) || match.to > len(buffer.lines[match.row].text) {
			return 0
		}
	}
	edit_open(buffer, .Atomic)
	#reverse for match in targets {
		edit_delete(buffer, {match.row, match.from}, {match.row, match.to})
		edit_insert(buffer, {match.row, match.from}, replacement)
	}
	count := len(targets)
	if all {
		search.origin = buffer.cursor
	} else {
		search.origin = {targets[0].row, targets[0].from + len(replacement)}
	}
	buffer_undo_commit(buffer)
	search_scan(editor, search)
	search_select(editor, search, buffer)
	return count
}

find_row_spans :: proc(editor: ^Editor, buffer: ^Buffer, row: int) -> [][2]int {
	out := make([dynamic][2]int, context.temp_allocator)
	for search in editor.searches {
		if search.buffer != buffer.id || buffer.rev != search.rev {
			continue
		}
		for match in search.matches {
			if match.row == row {
				append(&out, [2]int{match.from, match.to})
			} else if match.row > row {
				break
			}
		}
	}
	return out[:]
}

find_shows :: proc(editor: ^Editor, buffer: ^Buffer) -> bool {
	if buffer == nil {
		return false
	}
	shows := false
	for search in editor.searches {
		if search.buffer == buffer.id {
			search_fresh(editor, search)
			shows = true
		}
	}
	return shows
}

search_result_push :: proc(L: ^lua.State, search: ^Search) -> c.int {
	if search.invalid {
		lua.pushnil(L)
		lua.pushstring(L, "invalid pattern")
		return 2
	}
	lua.pushinteger(L, lua.Integer(search.current + 1 if search.current >= 0 else 0))
	lua.pushinteger(L, lua.Integer(len(search.matches)))
	lua.pushboolean(L, b32(search.capped))
	return 3
}

search_options :: proc(L: ^lua.State, idx: c.int, search: ^Search) {
	search.regex, search.case_sensitive = false, false
	if lua.type(L, idx) == .TABLE {
		lua.getfield(L, idx, "regex")
		search.regex = bool(lua.toboolean(L, -1))
		lua.getfield(L, idx, "case_sensitive")
		search.case_sensitive = bool(lua.toboolean(L, -1))
		lua.pop(L, 2)
	}
}

search_methods := [?]lua.L_Reg {
	{"update", qed_search_update},
	{"result", qed_search_result},
	{"step", qed_search_step},
	{"replace", qed_search_replace},
	{"close", qed_search_close},
}

qed_buf_find :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	buffer, _ := api_buf(L, editor, 1)
	query := api_string(L, 2)
	plugin := api_loaded(L, editor)
	search := new(Search)
	search.id = plugin_next_id(&editor.plugins)
	search.owner = plugin_name_intern(&editor.plugins, plugin.name)
	search.buffer = buffer.id
	search.query = strings.clone(query)
	search_options(L, 3, search)
	search.origin = buffer.cursor
	if from, _, ok := selection_range(buffer); ok {
		search.origin = from
	}
	search_scan(editor, search)
	search_select(editor, search, buffer)
	lua.settop(L, 0)
	append(&editor.searches, search)
	api_handle_push(L, search.id, search_methods[:])
	return 1
}

api_search :: proc(L: ^lua.State, editor: ^Editor) -> ^Search {
	search := search_find(editor, api_handle_id(L))
	if search == nil {
		plugin_raise(L, "search closed")
	}
	return search
}

qed_search_update :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	search := api_search(L, editor)
	query := api_string(L, 2)
	buffer := search_fresh(editor, search)
	if buffer == nil {
		return api_fail(L, "buffer closed")
	}
	delete(search.query)
	search.query = strings.clone(query)
	search_options(L, 3, search)
	search_scan(editor, search)
	search_select(editor, search, buffer)
	return search_result_push(L, search)
}

qed_search_result :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	search := api_search(L, entry.editor)
	search_fresh(entry.editor, search)
	return search_result_push(L, search)
}

qed_search_step :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	search := api_search(L, editor)
	direction := 1 if api_int(L, 2, "direction expected (1 or -1)") >= 0 else -1
	buffer := search_fresh(editor, search)
	count := len(search.matches)
	if buffer != nil && count > 0 {
		if search.current < 0 {
			search.current = 0 if direction > 0 else count - 1
		} else {
			search.current = (search.current + direction + count) % count
		}
		search_select(editor, search, buffer)
	}
	return search_result_push(L, search)
}

qed_search_replace :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	search := api_search(L, editor)
	replacement := api_string(L, 2)
	all := false
	if lua.type(L, 3) == .TABLE {
		lua.getfield(L, 3, "all")
		all = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	}
	lua.pushinteger(L, lua.Integer(search_replace(editor, search, replacement, all)))
	return 1
}

qed_search_close :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	search_close(entry.editor, api_handle_id(L))
	return 0
}
