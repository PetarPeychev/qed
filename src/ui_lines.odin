package main

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import lua "lib:lua"

UI_LINES_LIST_META :: "qed.LinesList"

UiLines :: struct {
	buf:           u64,
	query:         string,
	stamp:         u64,
	total:         int,
	filtered:      bool,
	lead:          int,
	jump_col:      int,
	matches:       [dynamic]int,
	narrow_query:  string,
	narrow_rows:   [dynamic]int,
	narrow_stamp:  u64,
}

ui_lines_methods := [?]lua.L_Reg {
	{"get", qed_list_get},
	{"at", qed_list_at},
	{"index_of", qed_list_index_of},
	{"count", qed_list_count},
	{"set_query", qed_lines_set_query},
}

ui_lines_free :: proc(lines: ^UiLines) {
	delete(lines.query)
	delete(lines.matches)
	delete(lines.narrow_query)
	delete(lines.narrow_rows)
	free(lines)
}

// ":N" and ":N:M" keep that row alone; a bare number leads the fuzzy matches; other text keeps buffer order
ui_lines_settle :: proc(editor: ^Editor, list: ^UiList) {
	lines := list.lines
	buffer, _ := api_buf_find(editor, lines.buf)
	stamp := buffer.rev + 1 if buffer != nil else 0
	if stamp == lines.stamp {
		return
	}
	lines.stamp = stamp
	lines.total = len(buffer.lines) if buffer != nil else 0
	list.rev += 1
	clear(&lines.matches)
	lines.filtered, lines.lead, lines.jump_col = false, -1, -1
	query := lines.query
	if buffer == nil || len(buffer.lines) == 0 || query == "" {
		return
	}
	count := len(buffer.lines)
	lines.filtered = true
	if len(query) >= 2 && query[0] == ':' {
		rest := query[1:]
		col := -1
		spec := true
		if at := strings.index_byte(rest, ':'); at >= 0 {
			if col_text := rest[at + 1:]; col_text != "" {
				value, ok := strconv.parse_int(col_text, 10)
				spec = ok && all_digits(col_text)
				col = max(0, value - 1)
			}
			rest = rest[:at]
		}
		if spec && all_digits(rest) {
			if row, ok := strconv.parse_int(rest, 10); ok {
				lines.lead = clamp(row - 1, 0, count - 1)
				lines.jump_col = col
				append(&lines.matches, lines.lead)
				return
			}
		}
	}
	if all_digits(query) {
		if row, ok := strconv.parse_int(query, 10); ok {
			lines.lead = clamp(row - 1, 0, count - 1)
			append(&lines.matches, lines.lead)
		}
	}
	// a longer query matches a subset of the shorter one's hits, so only those are rescanned
	incremental := lines.narrow_query != "" && lines.narrow_stamp == stamp && strings.has_prefix(query, lines.narrow_query)
	hits := make([dynamic]int, 0, len(lines.narrow_rows) if incremental else count / 4)
	if incremental {
		for row in lines.narrow_rows {
			if fuzzy_has(query, string(buffer.lines[row].text[:])) {
				append(&hits, row)
			}
		}
	} else {
		for line, row in buffer.lines {
			if fuzzy_has(query, string(line.text[:])) {
				append(&hits, row)
			}
		}
	}
	delete(lines.narrow_rows)
	lines.narrow_rows = hits
	delete(lines.narrow_query)
	lines.narrow_query = strings.clone(query)
	lines.narrow_stamp = stamp
	for row in hits {
		if row != lines.lead {
			append(&lines.matches, row)
		}
	}
}

ui_lines_count :: proc(lines: ^UiLines) -> int {
	return len(lines.matches) if lines.filtered else lines.total
}

ui_lines_row :: proc(lines: ^UiLines, i: int) -> int {
	return lines.matches[i] if lines.filtered else i
}

ui_lines_position :: proc(lines: ^UiLines, key: string) -> (int, bool) {
	value, ok := strconv.parse_int(key, 10)
	if !ok {
		return 0, false
	}
	row := value - 1
	if !lines.filtered {
		return row, row >= 0 && row < lines.total
	}
	if len(lines.matches) > 0 && lines.matches[0] == row {
		return 0, true
	}
	start := 1 if lines.lead >= 0 else 0
	low, high := start, len(lines.matches)
	for low < high {
		mid := (low + high) / 2
		if lines.matches[mid] < row {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low, low < len(lines.matches) && lines.matches[low] == row
}

ui_lines_record_push :: proc(L: ^lua.State, editor: ^Editor, lines: ^UiLines, i: int) {
	buffer, _ := api_buf_find(editor, lines.buf)
	row := ui_lines_row(lines, i)
	if buffer == nil || row >= len(buffer.lines) {
		lua.pushnil(L)
		return
	}
	when ODIN_TEST {
		test_list_built += 1
	}
	text := buffer.lines[row].text[:]
	col := line_indent_len(text)
	if row == lines.lead && lines.jump_col >= 0 {
		col = min(lines.jump_col, len(text))
	}
	lua.createtable(L, 0, 4)
	lua.pushodinstring(L, fmt.tprintf("%d", row + 1))
	lua.setfield(L, -2, "key")
	lua.pushinteger(L, lua.Integer(row + 1))
	lua.setfield(L, -2, "row")
	lua.pushinteger(L, lua.Integer(col + 1))
	lua.setfield(L, -2, "col")
	lua.pushodinstring(L, string(text))
	lua.setfield(L, -2, "label")
}

qed_lines_set_query :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	list := api_ui_list_self(L, entry.editor)
	if list.lines == nil {
		lua.L_argerror(L, 1, "line list expected")
	}
	query := api_string(L, 2)
	if query != list.lines.query {
		delete(list.lines.query)
		list.lines.query = strings.clone(query)
		list.lines.stamp = max(u64)
	}
	return 0
}

qed_buf_line_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	id := b.id
	plugin := api_loaded(L, editor)
	lua.settop(L, 0)
	list := api_ui_list_push(L, editor, plugin.name, false, lines = true)
	list.lines = new(UiLines)
	list.lines.buf = id
	list.lines.stamp = max(u64)
	ui_lines_settle(editor, list)
	return 1
}
