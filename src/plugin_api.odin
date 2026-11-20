package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import lua "lib:lua"

QED_STUB :: #load("../plugins/meta/qed.lua", string)

ApiEditMark :: struct {
	undo:      int,
	cursor:    Cursor,
	selection: Maybe(Cursor),
}

@(private = "file")
qed_api := [?]lua.L_Reg {
	{"log", qed_log},
	{"message", qed_message},
	{"command", qed_command},
	{"run", qed_run},
	{"shortcut", qed_shortcut},
	{"edit", qed_edit},
	{"open", qed_open},
	{"save", qed_save},
	{"close", qed_close},
	{"jump", qed_jump},
	{"root", qed_root},
	{"open_url", qed_open_url},
	{"set_root", qed_set_root},
	{"config", qed_config},
	{"options", qed_options},
	{"meta", qed_meta},
	{"opt", qed_opt},
	{"shell_quote", qed_shell_quote},
	{"parse_locations", qed_parse_locations},
	{"on", qed_on},
	{"emit", qed_emit},
	{"export", qed_export},
	{"plugin", qed_plugin},
	{"caller", qed_caller},
	{"spawn", qed_spawn},
	{"spawn_bg", qed_spawn_bg},
	{"sleep", qed_sleep},
	{"defer", qed_defer},
	{"every", qed_every},
	{"languages", qed_languages},
	{nil, nil},
}

@(private = "file")
qed_buf_api := [?]lua.L_Reg {
	{"current", qed_buf_current},
	{"list", qed_buf_list},
	{"valid", qed_buf_valid},
	{"path", qed_buf_path},
	{"language", qed_buf_language},
	{"modified", qed_buf_modified},
	{"big", qed_buf_big},
	{"rev", qed_buf_rev},
	{"line_count", qed_buf_line_count},
	{"lines", qed_buf_lines},
	{"line", qed_buf_line},
	{"find_lines", qed_buf_find_lines},
	{"text", qed_buf_text},
	{"insert", qed_buf_insert},
	{"delete", qed_buf_delete},
	{"replace", qed_buf_replace},
	{"set_text", qed_buf_set_text},
	{"cursor", qed_buf_cursor},
	{"set_cursor", qed_buf_set_cursor},
	{"selection", qed_buf_selection},
	{"set_selection", qed_buf_set_selection},
	{"set_language", qed_buf_set_language},
	{"set_indent", qed_buf_set_indent},
	{"indent", qed_buf_indent},
	{"set_base", qed_buf_set_base},
	{"line_list", qed_buf_line_list},
	{nil, nil},
}

@(private = "file")
qed_fs_api := [?]lua.L_Reg {
	{"read", qed_fs_read},
	{"write", qed_fs_write},
	{"exists", qed_fs_exists},
	{"stat", qed_fs_stat},
	{"list", qed_fs_list},
	{"dirs", qed_fs_dirs},
	{"walk", qed_fs_walk},
	{"copy", qed_fs_copy},
	{"rename", qed_fs_rename},
	{"remove", qed_fs_remove},
	{"mkdir", qed_fs_mkdir},
	{nil, nil},
}

@(private = "file")
qed_json_api := [?]lua.L_Reg {
	{"decode", qed_json_decode},
	{"encode", qed_json_encode},
	{nil, nil},
}

@(private = "file")
qed_path_api := [?]lua.L_Reg {
	{"join", qed_path_join},
	{"dir", qed_path_dir},
	{"base", qed_path_base},
	{"rel", qed_path_rel},
	{"abs", qed_path_abs},
	{nil, nil},
}

@(private = "file")
qed_lsp_api := [?]lua.L_Reg {
	{"format", qed_lsp_format},
	{nil, nil},
}

@(private = "file")
qed_theme_api := [?]lua.L_Reg {
	{"set", qed_theme_set},
	{"list", qed_theme_list},
	{"current", qed_theme_current},
	{"icon", qed_theme_icon},
	{nil, nil},
}

@(private = "file")
qed_term_api := [?]lua.L_Reg {
	{"create", qed_term_create},
	{"show", qed_term_show},
	{"hide", qed_term_hide},
	{"kill", qed_term_kill},
	{"restart", qed_term_restart},
	{"send", qed_term_send},
	{"state", qed_term_state},
	{"list", qed_term_list},
	{"close", qed_term_close},
	{nil, nil},
}

@(private = "file")
qed_deco_api := [?]lua.L_Reg {
	{"ns", qed_deco_ns},
	{"gutter", qed_deco_gutter},
	{"tint", qed_deco_tint},
	{"ghost", qed_deco_ghost},
	{"span", qed_deco_span},
	{"eol", qed_deco_eol},
	{"mark", qed_deco_mark},
	{"range", qed_deco_range},
	{"inline", qed_deco_inline},
	{"clear", qed_deco_clear},
	{nil, nil},
}

@(private = "file")
qed_status_api := [?]lua.L_Reg {
	{"set", qed_status_set},
	{"clear", qed_status_clear},
	{nil, nil},
}

@(private = "file")
qed_clipboard_api := [?]lua.L_Reg {
	{"get", qed_clipboard_get},
	{"set", qed_clipboard_set},
	{nil, nil},
}

@(private = "file")
qed_ui_api := [?]lua.L_Reg {
	{"open", qed_ui_open},
	{nil, nil},
}

@(private = "file")
qed_text_api := [?]lua.L_Reg {
	{"width", qed_text_width},
	{"diff", qed_text_diff},
	{"diff_rows", qed_text_diff_rows},
	{nil, nil},
}

plugin_qed_push :: proc(L: ^lua.State, pl: ^Plugin) {
	lua.newtable(L)
	plugin_key_push(L, pl)
	lua.L_setfuncs(L, raw_data(qed_api[:]), 1)
	lua.pushodinstring(L, VERSION)
	lua.setfield(L, -2, "version")
	subs := [?]struct {
		name: cstring,
		regs: []lua.L_Reg,
	}{{"buf", qed_buf_api[:]}, {"fs", qed_fs_api[:]}, {"json", qed_json_api[:]}, {"path", qed_path_api[:]}, {"text", qed_text_api[:]}, {"lsp", qed_lsp_api[:]}, {"theme", qed_theme_api[:]}, {"term", qed_term_api[:]}, {"clipboard", qed_clipboard_api[:]}, {"deco", qed_deco_api[:]}, {"status", qed_status_api[:]}, {"ui", qed_ui_api[:]}}
	for s in subs {
		lua.newtable(L)
		plugin_key_push(L, pl)
		lua.L_setfuncs(L, raw_data(s.regs), 1)
		lua.setfield(L, -2, s.name)
	}
	plugin_prelude_install(L)
}

api_enter :: proc "c" (L: ^lua.State) -> ^PluginEntry {
	e := plugin_entry(L)
	if e == nil {
		plugin_unavailable(L)
	}
	return e
}

api_int :: proc(L: ^lua.State, idx: c.int, what: cstring) -> int {
	isnum: b32
	n := lua.tointeger(L, idx, &isnum)
	if !isnum {
		lua.L_argerror(L, idx, what)
	}
	return int(n)
}

api_string :: proc(L: ^lua.State, idx: c.int) -> string {
	if lua.type(L, idx) != .STRING {
		lua.L_argerror(L, idx, "string expected")
	}
	s, _ := lua.toodinstring(L, idx)
	return s
}

api_buf_find :: proc(editor: ^Editor, id: u64) -> (^Buffer, int) {
	if editor.welcome {
		return nil, -1
	}
	for &b, i in editor.buffers {
		if b.id == id {
			return &b, i
		}
	}
	return nil, -1
}

api_buf :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> (^Buffer, int) {
	id: u64
	if lua.type(L, idx) > .NIL {
		n := api_int(L, idx, "buffer id expected")
		if n < 0 {
			lua.L_argerror(L, idx, "buffer id expected")
		}
		id = u64(n)
	}
	if id == 0 {
		if editor.welcome {
			plugin_raise(L, "no current buffer")
		}
		return editor_buffer(editor), editor.current
	}
	b, i := api_buf_find(editor, id)
	if b == nil {
		plugin_raise(L, "buffer closed")
	}
	return b, i
}

api_field_int :: proc(L: ^lua.State, t: c.int, key: string) -> (int, bool) {
	lua.pushodinstring(L, key)
	lua.rawget(L, t)
	isnum: b32
	n := lua.tointeger(L, -1, &isnum)
	lua.pop(L, 1)
	return int(n), bool(isnum)
}

api_pos :: proc(L: ^lua.State, idx: c.int, b: ^Buffer) -> Cursor {
	if lua.type(L, idx) != .TABLE {
		lua.L_argerror(L, idx, "position {row, col} expected")
	}
	t := lua.absindex(L, idx)
	row, rok := api_field_int(L, t, "row")
	col, cok := api_field_int(L, t, "col")
	if !rok || !cok {
		lua.L_argerror(L, idx, "position {row, col} expected")
	}
	if row < 1 || row > len(b.lines) {
		lua.L_argerror(L, idx, fmt.ctprintf("row %d out of range 1..%d", row, len(b.lines)))
	}
	text := b.lines[row - 1].text[:]
	if col < 1 || col > len(text) + 1 {
		lua.L_argerror(L, idx, fmt.ctprintf("col %d out of range 1..%d", col, len(text) + 1))
	}
	if col <= len(text) && text[col - 1] & 0xC0 == 0x80 {
		lua.L_argerror(L, idx, fmt.ctprintf("col %d splits a UTF-8 sequence", col))
	}
	return {row - 1, col - 1}
}

api_range :: proc(L: ^lua.State, idx: c.int, b: ^Buffer) -> (from, to: Cursor) {
	from = api_pos(L, idx, b)
	to = api_pos(L, idx + 1, b)
	if cursor_before(to, from) {
		lua.L_argerror(L, idx + 1, "range end is before its start")
	}
	return
}

api_pos_push :: proc(L: ^lua.State, p: Cursor) {
	lua.createtable(L, 0, 2)
	lua.pushinteger(L, lua.Integer(p.row + 1))
	lua.setfield(L, -2, "row")
	lua.pushinteger(L, lua.Integer(p.col + 1))
	lua.setfield(L, -2, "col")
}

api_text_arg :: proc(L: ^lua.State, idx: c.int) -> string {
	if !utf8.valid_string(api_string(L, idx)) {
		lua.L_argerror(L, idx, "text is not valid UTF-8")
	}
	return api_bytes_arg(L, idx)
}

api_bytes_arg :: proc(L: ^lua.State, idx: c.int) -> string {
	text := api_string(L, idx)
	if strings.contains_rune(text, '\r') {
		text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
		text, _ = strings.replace_all(text, "\r", "\n", context.temp_allocator)
	}
	return text
}

pos_shift_insert :: proc(p, at, end: Cursor) -> Cursor {
	if cursor_before(p, at) {
		return p
	}
	if p.row == at.row {
		return {end.row, end.col + p.col - at.col}
	}
	return {p.row + end.row - at.row, p.col}
}

pos_shift_delete :: proc(p, from, to: Cursor) -> Cursor {
	if !cursor_before(from, p) {
		return p
	}
	if cursor_before(p, to) {
		return from
	}
	if p.row == to.row {
		return {from.row, from.col + p.col - to.col}
	}
	return {p.row - (to.row - from.row), p.col}
}

api_marks_insert :: proc(b: ^Buffer, at, end: Cursor) {
	b.cursor = pos_shift_insert(b.cursor, at, end)
	if anchor, ok := b.selection.?; ok {
		b.selection = pos_shift_insert(anchor, at, end)
	}
}

api_marks_delete :: proc(b: ^Buffer, from, to: Cursor) {
	b.cursor = pos_shift_delete(b.cursor, from, to)
	if anchor, ok := b.selection.?; ok {
		b.selection = pos_shift_delete(anchor, from, to)
	}
}

api_edit_begin :: proc(b: ^Buffer) {
	edit_open(b, .Atomic)
}

api_edit_end :: proc(b: ^Buffer) {
	buffer_undo_commit(b)
	cursor_goal_sync(b)
}

api_edit_mark :: proc(b: ^Buffer) -> ApiEditMark {
	buffer_undo_commit(b)
	return {len(b.undo), b.cursor, b.selection}
}

api_edit_close :: proc(b: ^Buffer, mark: ApiEditMark, ok: bool) {
	buffer_undo_commit(b)
	start := min(mark.undo, len(b.undo))
	if ok {
		if len(b.undo) == start {
			return
		}
		merged := EditGroup {
			cursor = mark.cursor,
		}
		for i in start ..< len(b.undo) {
			append(&merged.edits, ..b.undo[i].edits[:])
			delete(b.undo[i].edits)
		}
		resize(&b.undo, start)
		if len(merged.edits) > 0 {
			append(&b.undo, merged)
		} else {
			delete(merged.edits)
		}
		return
	}
	for len(b.undo) > start {
		inv := buffer_apply_inverse(b, pop(&b.undo))
		group_destroy(&inv)
	}
	b.cursor = buffer_pos_clamp(b, mark.cursor)
	b.selection = nil
	if anchor, has := mark.selection.?; has {
		b.selection = buffer_pos_clamp(b, anchor)
	}
	cursor_goal_sync(b)
}

qed_buf_current :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if editor.welcome {
		lua.pushnil(L)
	} else {
		lua.pushinteger(L, lua.Integer(editor_buffer(editor).id))
	}
	return 1
}

qed_buf_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if editor.welcome {
		lua.newtable(L)
		return 1
	}
	lua.createtable(L, c.int(len(editor.buffers)), 0)
	for b, i in editor.buffers {
		lua.pushinteger(L, lua.Integer(b.id))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

qed_buf_valid :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	isnum: b32
	n := lua.tointeger(L, 1, &isnum)
	valid := false
	if isnum && n > 0 {
		b, _ := api_buf_find(entry.editor, u64(n))
		valid = b != nil
	}
	lua.pushboolean(L, b32(valid))
	return 1
}

qed_buf_path :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	lua.pushodinstring(L, b.path)
	return 1
}

qed_buf_language :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	lua.pushodinstring(L, LANGUAGES[b.language].name)
	return 1
}

qed_buf_modified :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	lua.pushboolean(L, b32(b.modified))
	return 1
}

qed_buf_big :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	lua.pushboolean(L, b32(b.big))
	return 1
}

qed_buf_rev :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	lua.pushinteger(L, lua.Integer(b.rev))
	return 1
}

qed_buf_line_count :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	lua.pushinteger(L, lua.Integer(len(b.lines)))
	return 1
}

qed_buf_lines :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	n := len(b.lines)
	from := api_int(L, 2, "row expected") if lua.type(L, 2) > .NIL else 1
	to := api_int(L, 3, "row expected") if lua.type(L, 3) > .NIL else n
	if from < 1 || from > n {
		lua.L_argerror(L, 2, fmt.ctprintf("row %d out of range 1..%d", from, n))
	}
	if to < from - 1 || to > n {
		lua.L_argerror(L, 3, fmt.ctprintf("row %d out of range %d..%d", to, from - 1, n))
	}
	lua.createtable(L, c.int(to - from + 1), 0)
	for r in from ..= to {
		lua.pushodinstring(L, string(b.lines[r - 1].text[:]))
		lua.rawseti(L, -2, lua.Integer(r - from + 1))
	}
	return 1
}

qed_buf_line :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	row := api_int(L, 2, "row expected")
	if row < 1 || row > len(b.lines) {
		lua.L_argerror(L, 2, fmt.ctprintf("row %d out of range 1..%d", row, len(b.lines)))
	}
	lua.pushodinstring(L, string(b.lines[row - 1].text[:]))
	return 1
}

qed_buf_find_lines :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	prefixes: []string
	listed := lua.type(L, 2) == .TABLE
	if listed {
		prefixes = api_lines_arg(L, 2)
	} else {
		prefixes = {api_string(L, 2)}
	}
	word := lua.type(L, 3) == .TABLE && api_opt_bool(L, 3, "word")
	lua.newtable(L)
	if listed {
		lua.newtable(L)
	}
	n := 0
	for line, r in b.lines {
		text := string(line.text[:])
		for p, k in prefixes {
			if !strings.has_prefix(text, p) || (word && len(text) > len(p) && text[len(p)] != ' ') {
				continue
			}
			n += 1
			lua.pushinteger(L, lua.Integer(r + 1))
			lua.rawseti(L, -2 - c.int(listed), lua.Integer(n))
			if listed {
				lua.pushinteger(L, lua.Integer(k + 1))
				lua.rawseti(L, -2, lua.Integer(n))
			}
			break
		}
	}
	return 1 + c.int(listed)
}

qed_buf_text :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	last := len(b.lines) - 1
	lua.pushodinstring(L, buffer_text_range(b, {0, 0}, {last, len(b.lines[last].text)}))
	return 1
}

qed_buf_insert :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	at := api_pos(L, 2, b)
	text := api_text_arg(L, 3)
	if text == "" {
		api_pos_push(L, at)
		return 1
	}
	api_edit_begin(b)
	end := edit_insert(b, at, text)
	api_marks_insert(b, at, end)
	api_edit_end(b)
	api_pos_push(L, end)
	return 1
}

qed_buf_delete :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	from, to := api_range(L, 2, b)
	if from == to {
		lua.pushodinstring(L, "")
		return 1
	}
	api_edit_begin(b)
	edit_delete(b, from, to)
	removed := strings.clone(b.open.edits[len(b.open.edits) - 1].text, context.temp_allocator)
	api_marks_delete(b, from, to)
	api_edit_end(b)
	lua.pushodinstring(L, removed)
	return 1
}

qed_buf_replace :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	from, to := api_range(L, 2, b)
	text := api_text_arg(L, 4)
	if from == to && text == "" {
		api_pos_push(L, from)
		return 1
	}
	api_edit_begin(b)
	if from != to {
		edit_delete(b, from, to)
		api_marks_delete(b, from, to)
	}
	end := from
	if text != "" {
		end = edit_insert(b, from, text)
		api_marks_insert(b, from, end)
	}
	api_edit_end(b)
	api_pos_push(L, end)
	return 1
}

api_rev_stale :: proc(L: ^lua.State, idx: c.int, b: ^Buffer) -> bool {
	t := lua.type(L, idx)
	if t == .NIL || t == .NONE {
		return false
	}
	if t != .TABLE {
		lua.L_argerror(L, idx, "options table expected")
	}
	lua.pushodinstring(L, "rev")
	defer lua.pop(L, 1)
	if lua.rawget(L, idx) <= .NIL {
		return false
	}
	isnum: b32
	rev := lua.tointeger(L, -1, &isnum)
	if !isnum {
		plugin_raise(L, "opts.rev must be an integer")
	}
	return u64(rev) != b.rev
}

qed_buf_set_text :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, idx := api_buf(L, editor, 1)
	text := api_text_arg(L, 2)
	if api_rev_stale(L, 3, b) {
		lua.pushboolean(L, false)
		return 1
	}
	if buffer_set_text(b, text) && idx == editor.current {
		editor_scroll(editor)
	}
	lua.pushboolean(L, true)
	return 1
}

qed_lsp_format :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	b, _ := api_buf(L, editor, 1)
	task := api_await(L, p, "qed.lsp.format").id
	reason := lsp_format_unavailable(b)
	token := plugin_next_id(p)
	if reason == "" && !lsp_send_format(editor, b, token) {
		reason = "unavailable"
	}
	if reason != "" {
		lua.pushboolean(L, false)
		lua.pushodinstring(L, reason)
		return 2
	}
	p.tasks[plugin_task_index(p, task)].wait = {kind = .Lsp, id = token, until = plugin_tick_add(time.tick_now(), PLUGIN_HOOK_TIMEOUT_MS)}
	return lua.yieldk(L, 0, lua.KContext(token), qed_lsp_format_k)
}

qed_lsp_format_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_lsp_format_k)
	}
	context = entry.ctx
	r, found := plugin_lsp_result(&entry.editor.plugins, u64(ctx))
	if found && r.ok {
		lua.pushboolean(L, true)
		return 1
	}
	lua.pushboolean(L, false)
	lua.pushodinstring(L, r.reason if found else "error")
	return 2
}

qed_buf_cursor :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	api_pos_push(L, b.cursor)
	return 1
}

qed_buf_set_cursor :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, idx := api_buf(L, editor, 1)
	b.cursor = api_pos(L, 2, b)
	b.selection = nil
	cursor_goal_sync(b)
	if idx == editor.current {
		editor_scroll(editor)
	}
	return 0
}

qed_buf_selection :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	from, to, ok := selection_range(b)
	if !ok {
		lua.pushnil(L)
		return 1
	}
	api_pos_push(L, from)
	api_pos_push(L, to)
	return 2
}

qed_buf_set_selection :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, idx := api_buf(L, editor, 1)
	anchor := api_pos(L, 2, b)
	b.cursor = api_pos(L, 3, b)
	b.selection = anchor
	cursor_goal_sync(b)
	if idx == editor.current {
		editor_scroll(editor)
	}
	return 0
}

qed_buf_set_language :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	name := api_string(L, 2)
	for info, lang in LANGUAGES {
		if lang != .MarkdownInline && info.name == name {
			lua.pushboolean(L, b32(editor_set_language(entry.editor, b, lang)))
			return 1
		}
	}
	return plugin_raise(L, fmt.tprintf("unknown language '%s'", name))
}

qed_buf_set_indent :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	style := api_string(L, 2)
	if style != "tabs" && style != "spaces" && style != "auto" {
		lua.L_argerror(L, 2, "\"tabs\", \"spaces\" or \"auto\" expected")
	}
	if style == "auto" {
		buffer_detect_indent(b)
		return 0
	}
	width := api_int(L, 3, "width expected") if lua.type(L, 3) > .NIL else b.indent_width
	if width < 1 || width > 16 {
		lua.L_argerror(L, 3, "width must be 1..16")
	}
	b.indent = .Tabs if style == "tabs" else .Spaces
	b.indent_width = width
	return 0
}

qed_buf_indent :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	lua.pushodinstring(L, "tabs" if b.indent == .Tabs else "spaces")
	lua.pushinteger(L, lua.Integer(b.indent_width))
	return 2
}

qed_edit :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	b, _ := api_buf(L, editor, 1)
	if lua.type(L, 2) != .FUNCTION {
		lua.L_argerror(L, 2, "function expected")
	}
	if api_rev_stale(L, 3, b) {
		lua.pushboolean(L, false)
		return 1
	}
	id := b.id
	lua.settop(L, 2)
	lua.pushcfunction(L, plugin_msgh)
	lua.pushvalue(L, 2)
	mark := api_edit_mark(b)
	p.edit_depth += 1
	status := lua.pcall(L, 0, 0, 3)
	p.edit_depth -= 1
	if bb, _ := api_buf_find(editor, id); bb != nil {
		api_edit_close(bb, mark, status == .OK)
	}
	if status != .OK {
		return lua.error(L)
	}
	lua.pushboolean(L, true)
	return 1
}

api_path :: proc(editor: ^Editor, path: string) -> string {
	if api_path_clean(path) {
		return path
	}
	if filepath.is_abs(path) {
		clean, _ := filepath.clean(path, context.temp_allocator)
		return clean
	}
	joined, _ := filepath.join({editor.working_root, path}, context.temp_allocator)
	return joined
}

api_path_clean :: proc(path: string) -> bool {
	if len(path) < 2 || path[0] != '/' || path[len(path) - 1] == '/' {
		return false
	}
	return !strings.contains(path, "//") && !strings.contains(path, "/./") && !strings.contains(path, "/../") && !strings.has_suffix(path, "/.") && !strings.has_suffix(path, "/..")
}

qed_open :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	path := api_path(editor, api_string(L, 1))
	if !editor_open_path(editor, path) {
		lua.pushnil(L)
		lua.pushodinstring(L, fmt.tprintf("cannot open %s", path))
		return 2
	}
	lua.pushinteger(L, lua.Integer(editor_buffer(editor).id))
	return 1
}

qed_save :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	b, idx := api_buf(L, editor, 1)
	if b.path == "" {
		return api_fail(L, "no file name")
	}
	if buffer_disk_changed(b) {
		if idx == editor.current {
			editor_save_full(editor, b)
		}
		return api_fail(L, "changed on disk")
	}
	id := b.id
	if plugin_save_pending(p, id) {
		return api_fail(L, "save in progress")
	}
	task: u64
	if t := plugin_task_of(p, L); t != nil && p.edit_depth == 0 && lua.isyieldable(L) {
		task = t.id
	}
	save := plugin_pre_save(editor, id)
	if save == 0 {
		editor_save_id(editor, id)
		return qed_save_result(L, editor, id)
	}
	i := plugin_task_index(p, task)
	if task == 0 || i < 0 {
		lua.pushboolean(L, true)
		return 1
	}
	p.tasks[i].wait = {kind = .Save, id = save}
	return lua.yieldk(L, 0, lua.KContext(id), qed_save_k)
}

qed_save_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_save_k)
	}
	context = entry.ctx
	return qed_save_result(L, entry.editor, u64(ctx))
}

qed_save_result :: proc(L: ^lua.State, editor: ^Editor, id: u64) -> c.int {
	if b, _ := api_buf_find(editor, id); b != nil && b.modified && buffer_disk_changed(b) {
		return api_fail(L, "changed on disk")
	}
	lua.pushboolean(L, true)
	return 1
}

qed_close :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, idx := api_buf(L, entry.editor, 1)
	discard := false
	if lua.type(L, 2) == .TABLE {
		if lua.getfield(L, 2, "discard") == .TABLE {
			for i in 1 ..= int(lua.rawlen(L, -1)) {
				lua.rawgeti(L, -1, lua.Integer(i))
				discard ||= u64(lua.tointeger(L, -1)) == b.id
				lua.pop(L, 1)
			}
		} else if lua.type(L, -1) != .NIL {
			plugin_raise(L, "discard must be a list of buffer ids")
		}
		lua.pop(L, 1)
	}
	if b.modified && !discard {
		lua.pushboolean(L, false)
		return 1
	}
	lock := entry.editor.jump_lock
	editor_close_index(entry.editor, idx)
	entry.editor.jump_lock = lock
	lua.pushboolean(L, true)
	return 1
}

qed_jump :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "position {row, col} expected")
	}
	row, rok := api_field_int(L, 2, "row")
	col, cok := api_field_int(L, 2, "col")
	if !rok || !cok {
		lua.L_argerror(L, 2, "position {row, col} expected")
	}
	origin := jump_here(editor)
	if lua.type(L, 1) == .STRING {
		path := api_path(editor, api_string(L, 1))
		if !editor_open_path(editor, path) {
			lua.pushnil(L)
			lua.pushodinstring(L, fmt.tprintf("cannot open %s", path))
			return 2
		}
	} else if _, idx := api_buf(L, editor, 1); idx != editor.current {
		editor_switch_to(editor, idx)
	}
	for i := len(editor.panes) - 1; i >= 0; i -= 1 {
		if i < len(editor.panes) && editor.panes[i].jump_closes {
			pane_end(editor, editor.panes[i].handle, false)
		}
	}
	b := editor_buffer(editor)
	r := clamp(row - 1, 0, len(b.lines) - 1)
	text := b.lines[r].text[:]
	cl := clamp(col - 1, 0, len(text))
	for cl > 0 && cl < len(text) && text[cl] & 0xC0 == 0x80 {
		cl -= 1
	}
	editor_goto(editor, r, cl)
	jump_record(editor, origin)
	return 0
}

LOCATION_SPACE :: " \t\n\v\f\r"

location_digits :: proc(line: string, from: int) -> int {
	i := from
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		i += 1
	}
	return i
}

location_number :: proc(digits: string) -> int {
	n := 0
	for ch in transmute([]u8)digits {
		n = min(n * 10 + int(ch - '0'), int(max(i32)))
	}
	return n
}

// Lua-pattern semantics: the shortest file wins per form, and an empty file skips to the next form.
location_parse :: proc(line: string) -> (file, row, col, msg: string, ok: bool) {
	for pat in 0 ..< 4 {
		with_col := pat < 2
		with_msg := pat % 2 == 0
		for i in 0 ..< len(line) {
			if line[i] != ':' {
				continue
			}
			r := location_digits(line, i + 1)
			if r == i + 1 {
				continue
			}
			j := r
			col_s := ""
			if with_col {
				if j >= len(line) || line[j] != ':' {
					continue
				}
				k := location_digits(line, j + 1)
				if k == j + 1 {
					continue
				}
				col_s = line[j + 1:k]
				j = k
			}
			msg_s := ""
			if with_msg {
				if j >= len(line) || line[j] != ':' {
					continue
				}
				msg_s = strings.trim_left(line[j + 1:], LOCATION_SPACE)
			} else if j != len(line) {
				continue
			}
			if i == 0 {
				break
			}
			return line[:i], line[i + 1:r], col_s, msg_s, true
		}
	}
	return
}

qed_parse_locations :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	text := api_string(L, 1)
	cwd := editor.working_root
	#partial switch lua.type(L, 2) {
	case .NIL, .NONE:
	case .TABLE:
		if dir, ok := api_field_string(L, 2, "cwd"); ok {
			cwd = api_path(editor, dir)
		}
	case:
		lua.L_argerror(L, 2, "table {cwd?} expected")
	}
	lua.L_checkstack(L, 4, "locations")
	lua.newtable(L)
	n := 0
	rest := text
	for line in strings.split_iterator(&rest, "\n") {
		file, row, col, msg, ok := location_parse(strings.trim_suffix(line, "\r"))
		if !ok {
			continue
		}
		path: string
		if strings.has_prefix(file, "/") {
			path, _ = filepath.clean(file, context.temp_allocator)
		} else {
			path, _ = filepath.join({cwd, file}, context.temp_allocator)
		}
		fi, err := os.stat(path, context.temp_allocator)
		if err != nil || fi.type != .Regular {
			continue
		}
		shown, rerr := filepath.rel(editor.working_root, path, context.temp_allocator)
		if rerr != .None {
			shown = path
		}
		label := fmt.tprintf("%s:%s", shown, row)
		if col != "" {
			label = fmt.tprintf("%s:%s", label, col)
		}
		if msg != "" {
			label = fmt.tprintf("%s: %s", label, msg)
		}
		lua.createtable(L, 0, 3)
		lua.pushodinstring(L, label)
		lua.setfield(L, -2, "label")
		lua.pushodinstring(L, path)
		lua.setfield(L, -2, "path")
		api_pos_push(L, {location_number(row) - 1, (location_number(col) if col != "" else 1) - 1})
		lua.setfield(L, -2, "pos")
		n += 1
		lua.rawseti(L, -2, lua.Integer(n))
	}
	return 1
}

qed_open_url :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	url := strings.clone(api_string(L, 1), context.temp_allocator)
	if editor.headless {
		editor_log(editor, .Debug, "", fmt.tprintf("Open URL: %s", url))
		lua.pushboolean(L, true)
		return 1
	}
	opener, ok := url_opener()
	if !ok {
		return api_fail(L, "no URL opener found (xdg-open, wslview or explorer.exe)")
	}
	editor_log(editor, .Debug, "", fmt.tprintf("Open URL: %s %s", opener, url))
	if !url_open(fmt.tprintf("%s %s", opener, shell_quote(url))) {
		return api_fail(L, fmt.tprintf("cannot run %s", opener))
	}
	lua.pushboolean(L, true)
	return 1
}

qed_root :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, entry.editor.working_root)
	return 1
}

qed_set_root :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	path := api_path(editor, api_string(L, 1))
	discard := make([dynamic]u64, context.temp_allocator)
	#partial switch lua.type(L, 2) {
	case .NIL, .NONE:
	case .TABLE:
		#partial switch lua.getfield(L, 2, "discard") {
		case .TABLE:
			for i in 1 ..= int(lua.rawlen(L, -1)) {
				lua.rawgeti(L, -1, lua.Integer(i))
				append(&discard, u64(api_int(L, -1, "discard must be a list of buffer ids")))
				lua.pop(L, 1)
			}
		case .NIL:
		case:
			plugin_raise(L, "discard must be a list of buffer ids")
		}
		lua.pop(L, 1)
	case:
		lua.L_argerror(L, 2, "options table expected")
	}
	if !os.is_dir(path) {
		return api_fail(L, fmt.tprintf("not a directory: %s", path))
	}
	if path == editor.working_root {
		lua.pushboolean(L, true)
		return 1
	}
	total := 0
	unsaved := make([dynamic]u64, context.temp_allocator)
	refused := false
	for b in editor.buffers {
		if b.path == "" || path_under(b.path, path) {
			continue
		}
		total += 1
		if b.modified {
			append(&unsaved, b.id)
			refused ||= !slice.contains(discard[:], b.id)
		}
	}
	if refused {
		lua.pushnil(L)
		lua.pushstring(L, "unsaved")
		lua.createtable(L, 0, 3)
		lua.pushinteger(L, lua.Integer(total))
		lua.setfield(L, -2, "total")
		lua.pushinteger(L, lua.Integer(len(unsaved)))
		lua.setfield(L, -2, "unsaved")
		lua.createtable(L, c.int(len(unsaved)), 0)
		for id, i in unsaved {
			lua.pushinteger(L, lua.Integer(id))
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		lua.setfield(L, -2, "bufs")
		return 3
	}
	editor_change_root(editor, path)
	lua.pushboolean(L, true)
	return 1
}

qed_config :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	pl := plugin_owner(L, entry.editor)
	if pl == nil || pl.cfg == lua.NOREF {
		return plugin_raise(L, "qed.config() is available once setup runs")
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.cfg))
	plugin_table_copy(L, -1)
	return 1
}

qed_options :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	pl := plugin_owner(L, entry.editor)
	if pl == nil || entry.editor.plugins.setup != pl {
		return plugin_raise(L, "qed.options() is only callable during setup")
	}
	if pl.defaults != lua.NOREF {
		return plugin_raise(L, "qed.options() is callable once per load")
	}
	if lua.type(L, 1) != .TABLE {
		return lua.L_argerror(L, 1, "defaults table expected")
	}
	lua.settop(L, 1)
	for key in ([?]cstring{"enabled", "keybinds"}) {
		if lua.getfield(L, 1, key) != .NIL {
			return plugin_raise(L, fmt.tprintf("qed.options: '%s' is reserved", key))
		}
		lua.pop(L, 1)
	}
	plugin_table_copy(L, 1)
	pl.defaults = lua.L_ref(L, lua.REGISTRYINDEX)
	plugin_config_push(entry.editor, pl, 1)
	return 1
}

PLUGIN_RESERVED_LABELS :: [?]string{"Clipboard", "Config", "Diff", "Files", "Git", "Lang", "LSP", "Plugins", "Rename", "Save", "Startup", "Syntax", "Terminal"}

qed_meta :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	pl := plugin_owner(L, entry.editor)
	if pl == nil || p.setup != pl {
		return plugin_raise(L, "qed.meta() is only callable during setup")
	}
	if pl.meta_set {
		return plugin_raise(L, "qed.meta() is callable once per load")
	}
	for cmd in p.commands {
		if cmd.owner == pl.name {
			return plugin_raise(L, "qed.meta() must come before qed.command()")
		}
	}
	if lua.type(L, 1) != .TABLE {
		return lua.L_argerror(L, 1, "table {display_name?} expected")
	}
	lua.settop(L, 1)
	lua.pushnil(L)
	for lua.next(L, 1) != 0 {
		k: string
		if lua.type(L, -2) == .STRING {
			k, _ = lua.toodinstring(L, -2)
		}
		if k != "display_name" {
			return plugin_raise(L, fmt.tprintf("qed.meta: unknown field '%s'", lua.L_tostring(L, -2)))
		}
		lua.pop(L, 1)
	}
	display := pl.display
	if dt := lua.getfield(L, 1, "display_name"); dt != .NIL {
		s: string
		if dt == .STRING {
			s, _ = lua.toodinstring(L, -1)
		}
		if strings.trim_space(s) == "" {
			return lua.L_argerror(L, 1, "display_name must be a non-empty string")
		}
		display = s
	}
	for src in PLUGIN_RESERVED_LABELS {
		if strings.equal_fold(src, display) {
			return plugin_raise(L, fmt.tprintf("display_name '%s' is a core log label", display))
		}
	}
	for other in p.list {
		if other.name != pl.name && other.state == .Enabled && strings.equal_fold(other.display, display) {
			return plugin_raise(L, fmt.tprintf("display_name '%s' is taken by plugin '%s'", display, other.name))
		}
	}
	pl.meta_set = true
	if display != pl.display {
		display = strings.clone(display)
		delete(pl.display)
		pl.display = display
	}
	return 0
}

qed_opt :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	key := api_string(L, 1)
	ints := config_ints[:]
	bools := config_bools[:]
	strs: []Config_Str
	name := key
	if strings.has_prefix(key, "lsp.") {
		ints, bools, name = config_lsp.ints, config_lsp.bools, key[len("lsp."):]
	} else if key == "theme" {
		lua.pushodinstring(L, THEME)
		return 1
	}
	for o in ints {
		if o.key == name {
			lua.pushinteger(L, lua.Integer(o.ptr^))
			return 1
		}
	}
	for o in bools {
		if o.key == name {
			lua.pushboolean(L, b32(o.ptr^))
			return 1
		}
	}
	for o in strs {
		if o.key == name {
			lua.pushodinstring(L, o.ptr^)
			return 1
		}
	}
	return plugin_raise(L, fmt.tprintf("unknown option '%s'", key))
}

qed_shell_quote :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, shell_quote(api_string(L, 1)))
	return 1
}

api_term_push :: proc(L: ^lua.State, t: ^Terminal) {
	lua.createtable(L, 0, 5)
	lua.pushodinstring(L, t.name)
	lua.setfield(L, -2, "name")
	lua.pushboolean(L, b32(t.alive))
	lua.setfield(L, -2, "running")
	if t.exited {
		lua.pushinteger(L, lua.Integer(t.code))
		lua.setfield(L, -2, "code")
	}
	if t.alive {
		lua.pushinteger(L, lua.Integer(t.pid))
		lua.setfield(L, -2, "pid")
		lua.pushboolean(L, b32(term_busy(t)))
		lua.setfield(L, -2, "busy")
	}
}

qed_term_create :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table {name, cmd?, cwd?, env?, restart?, detach?} expected")
	}
	lua.settop(L, 1)
	lua.L_checkstack(L, 4, "term options")
	name, _ := api_field_string(L, 1, "name")
	if name == "" {
		return plugin_raise(L, "name must be a non-empty string")
	}
	if name == TERM_SHELL {
		return plugin_raise(L, `"shell" is the default session; use qed.term.show("shell")`)
	}
	spec := TermSpec{name = name}
	spec.cmd, _ = api_field_string(L, 1, "cmd")
	if len(spec.cmd) >= API_ARG_MAX {
		return plugin_raise(L, fmt.tprintf("cmd too long (%d bytes, limit %d KiB)", len(spec.cmd), API_ARG_MAX / 1024))
	}
	if cwd, has_cwd := api_field_string(L, 1, "cwd"); has_cwd {
		spec.cwd = api_path(editor, cwd)
	}
	env_t := lua.getfield(L, 1, "env")
	if env_t == .TABLE {
		spec.env = api_env_merge(L)
	} else if env_t != .NIL {
		return plugin_raise(L, "env must be a table")
	}
	lua.pop(L, 1)
	for kv in spec.env {
		if len(kv) >= API_ARG_MAX {
			return plugin_raise(L, fmt.tprintf("environment value %s too long (%d bytes, limit %d KiB)", kv[:strings.index_byte(kv, '=')], len(kv), API_ARG_MAX / 1024))
		}
	}
	lua.getfield(L, 1, "restart")
	restart := bool(lua.toboolean(L, -1))
	lua.getfield(L, 1, "detach")
	detach := bool(lua.toboolean(L, -1))
	lua.pop(L, 2)
	pl := api_loaded(L, editor)
	if !detach {
		spec.owner = pl.name
	}
	t := term_find(editor, name)
	if t != nil && t.alive && !restart {
		return api_fail(L, "already running")
	}
	if t == nil {
		ok: bool
		if t, ok = term_create(editor, spec); !ok {
			term_close(editor, t)
			return api_fail(L, "cannot start")
		}
	} else {
		term_stop(editor, t)
		term_spec_set(t, spec)
		if !term_spawn(editor, t) {
			return api_fail(L, "cannot start")
		}
	}
	lua.pushodinstring(L, name)
	return 1
}

api_term_named :: proc(L: ^lua.State, editor: ^Editor, guard := false) -> ^Terminal {
	name := api_string(L, 1)
	api_loaded(L, editor)
	if guard && name == TERM_SHELL {
		plugin_raise(L, `the "shell" session cannot be killed, restarted or closed by a plugin`)
	}
	return term_find(editor, name)
}

qed_term_show :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	name := api_string(L, 1)
	api_loaded(L, editor)
	if editor.plugins.loading {
		return plugin_raise(L, "qed.term.show is unavailable while plugins load")
	}
	t: ^Terminal
	if name == TERM_SHELL {
		if t = term_shell(editor); t == nil {
			return api_fail(L, "terminal unavailable")
		}
	} else if t = term_find(editor, name); t == nil {
		return api_fail(L, "no such session")
	}
	term_show(editor, t)
	lua.pushboolean(L, true)
	return 1
}

qed_term_hide :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	api_loaded(L, entry.editor)
	entry.editor.terminal.active = false
	return 0
}

qed_term_kill :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	t := api_term_named(L, entry.editor, guard = true)
	if t == nil {
		return api_fail(L, "no such session")
	}
	term_kill(entry.editor, t)
	lua.pushboolean(L, true)
	return 1
}

qed_term_restart :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	t := api_term_named(L, entry.editor, guard = true)
	if t == nil {
		return api_fail(L, "no such session")
	}
	if !term_spawn(entry.editor, t) {
		return api_fail(L, "cannot start")
	}
	lua.pushboolean(L, true)
	return 1
}

qed_term_send :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	text := api_string(L, 2)
	t := api_term_named(L, entry.editor)
	if t == nil {
		return api_fail(L, "no such session")
	}
	if !t.alive {
		return api_fail(L, "not running")
	}
	term_send(t, transmute([]u8)text)
	lua.pushboolean(L, true)
	return 1
}

qed_term_state :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	t := api_term_named(L, entry.editor)
	if t == nil {
		lua.pushnil(L)
		return 1
	}
	api_term_push(L, t)
	return 1
}

qed_term_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	api_loaded(L, entry.editor)
	list := entry.editor.terminal.list
	lua.createtable(L, c.int(len(list)), 0)
	for t, i in list {
		api_term_push(L, t)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

qed_term_close :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	t := api_term_named(L, entry.editor, guard = true)
	if t == nil {
		return api_fail(L, "no such session")
	}
	term_close(entry.editor, t)
	lua.pushboolean(L, true)
	return 1
}

qed_clipboard_get :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, clipboard_get(context.temp_allocator))
	return 1
}

qed_clipboard_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	clipboard_set(strings.clone(api_string(L, 1), context.temp_allocator))
	return 0
}

api_fail :: proc(L: ^lua.State, msg: string) -> c.int {
	lua.pushnil(L)
	lua.pushodinstring(L, msg)
	return 2
}

qed_fs_read :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path := api_path(entry.editor, api_string(L, 1))
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return api_fail(L, fmt.tprintf("cannot read %s: %v", path, err))
	}
	lua.pushodinstring(L, string(data))
	return 1
}

qed_fs_write :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path := api_path(entry.editor, api_string(L, 1))
	data := api_string(L, 2)
	if lua.type(L, 3) == .TABLE && api_opt_bool(L, 3, "exclusive") {
		switch fs_create(entry.editor, path, data) {
		case .None:
			lua.pushboolean(L, true)
			return 1
		case .Exists:
			return api_fail(L, "exists")
		case .Missing, .Into, .Special, .Root, .Failed:
		}
		return api_fail(L, fmt.tprintf("cannot write %s", path))
	}
	mode := os.perm(0o644)
	if fi, err := os.stat(path, context.temp_allocator); err == nil {
		mode = fi.mode
	}
	path_ensure_parent_dir(path)
	if file_write_atomic(path, transmute([]u8)data, mode) != .None {
		return api_fail(L, fmt.tprintf("cannot write %s", path))
	}
	walk_invalidate(entry.editor, path)
	lua.pushboolean(L, true)
	return 1
}

api_fs_result :: proc(L: ^lua.State, err: FsError, path: string) -> c.int {
	if err != .None {
		return api_fail(L, fs_error_text(err, path))
	}
	lua.pushboolean(L, true)
	return 1
}

qed_fs_copy :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	src, dst := api_path(entry.editor, api_string(L, 1)), api_path(entry.editor, api_string(L, 2))
	return api_fs_result(L, fs_copy(entry.editor, src, dst), dst)
}

qed_fs_rename :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	src, dst := api_path(entry.editor, api_string(L, 1)), api_path(entry.editor, api_string(L, 2))
	return api_fs_result(L, fs_rename(entry.editor, src, dst), dst)
}

qed_fs_remove :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path := api_path(entry.editor, api_string(L, 1))
	return api_fs_result(L, fs_remove(entry.editor, path), path)
}

qed_fs_mkdir :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path := api_path(entry.editor, api_string(L, 1))
	return api_fs_result(L, fs_mkdir(entry.editor, path), path)
}

qed_fs_exists :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path := api_path(entry.editor, api_string(L, 1))
	follow := true
	if lua.type(L, 2) == .TABLE && lua.getfield(L, 2, "follow") != .NIL {
		follow = bool(lua.toboolean(L, -1))
	}
	lua.pushboolean(L, b32(os.exists(path) if follow else fs_lexists(path)))
	return 1
}

qed_fs_stat :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path := api_path(entry.editor, api_string(L, 1))
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return api_fail(L, fmt.tprintf("cannot stat %s: %v", path, err))
	}
	kind := "other"
	#partial switch fi.type {
	case .Regular:
		kind = "file"
	case .Directory:
		kind = "dir"
	case .Symlink:
		kind = "link"
	}
	lua.createtable(L, 0, 3)
	lua.pushinteger(L, lua.Integer(fi.size))
	lua.setfield(L, -2, "size")
	lua.pushnumber(L, lua.Number(f64(time.time_to_unix_nano(fi.modification_time)) / 1e9))
	lua.setfield(L, -2, "mtime")
	lua.pushodinstring(L, kind)
	lua.setfield(L, -2, "type")
	return 1
}

qed_fs_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path := api_path(entry.editor, api_string(L, 1))
	infos, err := os.read_directory_by_path(path, -1, context.temp_allocator)
	if err != nil {
		return api_fail(L, fmt.tprintf("cannot list %s: %v", path, err))
	}
	names := make([]string, len(infos), context.temp_allocator)
	for fi, i in infos {
		names[i] = fi.name
	}
	slice.sort(names)
	lua.createtable(L, c.int(len(names)), 0)
	for n, i in names {
		lua.pushodinstring(L, n)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

qed_json_decode :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	src := api_string(L, 1)
	v, err := json.parse_string(src, parse_integers = true, allocator = context.temp_allocator)
	if err != nil {
		return api_fail(L, fmt.tprintf("invalid JSON: %v", err))
	}
	plugin_json_push(L, v)
	return 1
}

ApiJsonKey :: struct {
	name:   string,
	is_int: bool,
	n:      lua.Integer,
}

api_json_write :: proc(L: ^lua.State, idx: c.int, sb: ^strings.Builder, depth: int) -> string {
	if depth > PLUGIN_TABLE_DEPTH_MAX {
		return "nested too deeply"
	}
	lua.L_checkstack(L, 3, "JSON value nested too deeply")
	#partial switch lua.type(L, idx) {
	case .NIL:
		strings.write_string(sb, "null")
	case .BOOLEAN:
		strings.write_string(sb, "true" if lua.toboolean(L, idx) else "false")
	case .NUMBER:
		if lua.isinteger(L, idx) {
			fmt.sbprintf(sb, "%d", lua.tointeger(L, idx))
			return ""
		}
		f := f64(lua.tonumberx(L, idx, nil))
		if math.is_nan(f) || math.is_inf(f) {
			return "cannot encode NaN or infinity"
		}
		fmt.sbprintf(sb, "%v", f)
	case .STRING:
		s, _ := lua.toodinstring(L, idx)
		strings.write_string(sb, lsp_json_string(s))
	case .TABLE:
		t := lua.absindex(L, idx)
		n := lua.Integer(lua.rawlen(L, t))
		keys := make([dynamic]ApiJsonKey, context.temp_allocator)
		seq := 0
		lua.pushnil(L)
		for lua.next(L, t) != 0 {
			#partial switch lua.type(L, -2) {
			case .STRING:
				k, _ := lua.toodinstring(L, -2)
				append(&keys, ApiJsonKey{name = strings.clone(k, context.temp_allocator)})
			case .NUMBER:
				if !lua.isinteger(L, -2) {
					lua.pop(L, 2)
					return "table keys must be strings or integers"
				}
				k := lua.tointeger(L, -2)
				if k >= 1 && k <= n {
					seq += 1
				}
				append(&keys, ApiJsonKey{name = fmt.tprintf("%d", k), is_int = true, n = k})
			case:
				lua.pop(L, 2)
				return "table keys must be strings or integers"
			}
			lua.pop(L, 1)
		}
		if n > 0 && seq == len(keys) {
			strings.write_byte(sb, '[')
			for i in 1 ..= n {
				if i > 1 {
					strings.write_byte(sb, ',')
				}
				lua.rawgeti(L, t, i)
				err := api_json_write(L, -1, sb, depth + 1)
				lua.pop(L, 1)
				if err != "" {
					return err
				}
			}
			strings.write_byte(sb, ']')
			return ""
		}
		slice.sort_by(keys[:], proc(a, b: ApiJsonKey) -> bool {return a.name < b.name})
		strings.write_byte(sb, '{')
		for k, i in keys {
			if i > 0 {
				strings.write_byte(sb, ',')
			}
			strings.write_string(sb, lsp_json_string(k.name))
			strings.write_byte(sb, ':')
			if k.is_int {
				lua.rawgeti(L, t, k.n)
			} else {
				lua.pushodinstring(L, k.name)
				lua.rawget(L, t)
			}
			err := api_json_write(L, -1, sb, depth + 1)
			lua.pop(L, 1)
			if err != "" {
				return err
			}
		}
		strings.write_byte(sb, '}')
	case:
		return fmt.tprintf("cannot encode a %s", lua.typename(L, lua.type(L, idx)))
	}
	return ""
}

qed_json_encode :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.settop(L, 1)
	sb := strings.builder_make(context.temp_allocator)
	if err := api_json_write(L, 1, &sb, 0); err != "" {
		return plugin_raise(L, err)
	}
	lua.pushodinstring(L, strings.to_string(sb))
	return 1
}

qed_path_join :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	n := lua.gettop(L)
	parts := make([]string, n, context.temp_allocator)
	for i in 1 ..= n {
		parts[i - 1] = api_string(L, i)
	}
	joined, _ := filepath.join(parts, context.temp_allocator)
	lua.pushodinstring(L, joined)
	return 1
}

qed_path_dir :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, filepath.dir(api_string(L, 1)))
	return 1
}

qed_path_base :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, filepath.base(api_string(L, 1)))
	return 1
}

qed_path_rel :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	target := api_path(editor, api_string(L, 1))
	base := api_path(editor, api_string(L, 2)) if lua.type(L, 2) > .NIL else editor.working_root
	rel, err := filepath.rel(base, target, context.temp_allocator)
	if err != .None {
		return api_fail(L, fmt.tprintf("cannot relate %s to %s", target, base))
	}
	lua.pushodinstring(L, rel)
	return 1
}

qed_path_abs :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, api_path(entry.editor, api_string(L, 1)))
	return 1
}

qed_text_width :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushinteger(L, lua.Integer(visual_width(transmute([]u8)api_string(L, 1))))
	return 1
}

api_lines_arg :: proc(L: ^lua.State, idx: c.int) -> []string {
	if lua.type(L, idx) != .TABLE {
		lua.L_argerror(L, idx, "list of strings expected")
	}
	n := int(lua.rawlen(L, idx))
	out := make([]string, n, context.temp_allocator)
	for i in 0 ..< n {
		if lua.rawgeti(L, idx, lua.Integer(i + 1)) != .STRING {
			lua.L_argerror(L, idx, "list of strings expected")
		}
		// the table keeps the string alive, so the view outlives the pop
		out[i], _ = lua.toodinstring(L, -1)
		lua.pop(L, 1)
	}
	return out
}

api_diff :: proc(a, b: []string) -> ([][4]int, bool) {
	ha := make([]u64, len(a), context.temp_allocator)
	for s, i in a {
		ha[i] = diff_hash(transmute([]u8)s)
	}
	hb := make([]u64, len(b), context.temp_allocator)
	for s, i in b {
		hb[i] = diff_hash(transmute([]u8)s)
	}
	ops, ok := diff_myers(ha, hb)
	if !ok {
		return nil, false
	}
	return diff_runs(ops, a, b), true
}

api_hunk_push :: proc(L: ^lua.State, h: [4]int, a0, b0: int) {
	lua.createtable(L, 0, 5)
	vals := [4]int{h[0] + a0, h[1], h[2] + b0, h[3]}
	for k, j in ([4]cstring{"a", "a_count", "b", "b_count"}) {
		lua.pushinteger(L, lua.Integer(vals[j]))
		lua.setfield(L, -2, k)
	}
}

qed_text_diff :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	hunks, ok := api_diff(api_lines_arg(L, 1), api_lines_arg(L, 2))
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, c.int(len(hunks)), 0)
	for h, i in hunks {
		api_hunk_push(L, h, 1, 1)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

qed_text_diff_rows :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	n := len(b.lines)
	rows :: proc(L: ^lua.State, b: ^Buffer, idx: c.int, n: int) -> []string {
		lo := api_int(L, idx, "row expected")
		hi := api_int(L, idx + 1, "row expected")
		if lo < 1 || hi > n || hi < lo - 1 {
			lua.L_argerror(L, idx, "row range out of bounds")
		}
		out := make([]string, hi - lo + 1, context.temp_allocator)
		for &s, i in out {
			s = string(b.lines[lo - 1 + i].text[:])
		}
		return out
	}
	ra := rows(L, b, 2, n)
	rb := rows(L, b, 4, n)
	a0, b0 := api_int(L, 2, "row expected"), api_int(L, 4, "row expected")
	words := lua.type(L, 6) == .TABLE && api_opt_bool(L, 6, "words")
	hunks, ok := api_diff(ra, rb)
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, c.int(len(hunks)), 0)
	for h, i in hunks {
		api_hunk_push(L, h, a0, b0)
		if words {
			pairs := min(h[1], h[3])
			lua.createtable(L, c.int(pairs), 0)
			for k in 0 ..< pairs {
				osp, tsp := diff_word_span(ra[h[0] + k], rb[h[2] + k])
				lua.createtable(L, 4, 0)
				for v, j in ([4]int{osp[0], osp[1], tsp[0], tsp[1]}) {
					lua.pushinteger(L, lua.Integer(v + 1))
					lua.rawseti(L, -2, lua.Integer(j + 1))
				}
				lua.rawseti(L, -2, lua.Integer(k + 1))
			}
			lua.setfield(L, -2, "spans")
		}
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

plugin_stub_dir :: proc(allocator := context.temp_allocator) -> string {
	if data := os.get_env("XDG_DATA_HOME", context.temp_allocator); data != "" {
		return fmt.aprintf("%s/qed/lua", data, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return fmt.aprintf("%s/.local/share/qed/lua", home, allocator = allocator)
}

plugin_stub_write :: proc(dir: string) -> bool {
	if dir == "" {
		return false
	}
	path := fmt.tprintf("%s/qed.lua", dir)
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(data) == QED_STUB {
		return false
	}
	os.make_directory_all(dir)
	return os.write_entire_file(path, transmute([]u8)string(QED_STUB)) == nil
}

api_loaded :: proc(L: ^lua.State, editor: ^Editor) -> ^Plugin {
	pl := plugin_owner(L, editor)
	if pl == nil || pl.state != .Enabled {
		plugin_raise(L, "plugin is not loaded")
	}
	return pl
}

api_handle_push :: proc(L: ^lua.State, id: u64, methods: []lua.L_Reg) {
	lua.createtable(L, 0, c.int(len(methods) + 1))
	lua.pushinteger(L, lua.Integer(id))
	lua.setfield(L, -2, "id")
	for m in methods {
		lua.pushvalue(L, lua.upvalueindex(1))
		lua.pushinteger(L, lua.Integer(id))
		lua.pushcclosure(L, m.func, 2)
		lua.setfield(L, -2, m.name)
	}
}

api_handle_id :: proc(L: ^lua.State) -> u64 {
	return u64(lua.tointeger(L, lua.upvalueindex(2)))
}

qed_on :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	name := api_string(L, 1)
	event: PluginEvent
	found := false
	custom := ""
	if i := strings.index_byte(name, ':'); i > 0 && i < len(name) - 1 {
		event, found, custom = .Custom, true, name
	}
	for n, e in plugin_event_names {
		if !found && e != .Custom && n == name {
			event, found = e, true
		}
	}
	if !found {
		lua.L_argerror(L, 1, fmt.ctprintf("unknown event '%s'", name))
	}
	if lua.type(L, 2) != .FUNCTION {
		lua.L_argerror(L, 2, "function expected")
	}
	pl := api_loaded(L, editor)
	lua.settop(L, 2)
	id := plugin_next_id(p)
	api_handle_push(L, id, {{"off", qed_hook_off}})
	lua.pushvalue(L, 2)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	append(&p.hooks, PluginHook{id = id, event = event, name = plugin_name_intern(p, custom) if custom != "" else "", owner = pl.name, ref = ref})
	p.subs[event] += 1
	return 1
}

qed_emit :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	name := api_string(L, 1)
	pl := api_loaded(L, editor)
	if i := strings.index_byte(name, ':'); i < 0 || name[:i] != pl.name || i == len(name) - 1 {
		return plugin_raise(L, fmt.tprintf("event name must be '%s:<event>'", pl.name))
	}
	subscribed := false
	for h in p.hooks {
		subscribed ||= h.event == .Custom && h.name == name
	}
	if !subscribed {
		return 0
	}
	lua.settop(L, 2)
	plugin_queue(editor, {event = .Custom, a = name, data = i32(lua.L_ref(L, lua.REGISTRYINDEX))})
	return 0
}

qed_export :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	pl := plugin_owner(L, entry.editor)
	if pl == nil || entry.editor.plugins.setup != pl {
		return plugin_raise(L, "qed.export() is only callable during setup")
	}
	if pl.exports != lua.NOREF {
		return plugin_raise(L, "qed.export() is callable once per load")
	}
	if lua.type(L, 1) != .TABLE {
		return lua.L_argerror(L, 1, "table of functions expected")
	}
	lua.settop(L, 1)
	lua.newtable(L)
	lua.pushnil(L)
	for lua.next(L, 1) != 0 {
		if lua.type(L, -2) != .STRING || lua.type(L, -1) != .FUNCTION {
			return plugin_raise(L, "qed.export: name = function expected")
		}
		lua.pushvalue(L, -2)
		lua.insert(L, -2)
		lua.rawset(L, 2)
	}
	pl.exports = lua.L_ref(L, lua.REGISTRYINDEX)
	return 0
}

qed_plugin :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	name := api_string(L, 1)
	if p.setup != nil {
		return plugin_raise(L, "qed.plugin() is unavailable during setup (call it from startup or plugin_loaded)")
	}
	pl := plugin_find(p, name)
	if pl == nil || pl.state != .Enabled {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 4)
	if pl.exports == lua.NOREF {
		return 1
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.exports))
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		lua.pop(L, 1)
		lua.pushvalue(L, -1)
		lua.pushodinstring(L, pl.name)
		lua.pushinteger(L, lua.Integer(pl.gen))
		lua.pushvalue(L, lua.upvalueindex(1))
		lua.pushvalue(L, -4)
		lua.pushcclosure(L, plugin_export_call, 4)
		lua.rawset(L, -5)
	}
	lua.pop(L, 1)
	return 1
}

plugin_export_call :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	owner, _ := lua.toodinstring(L, lua.upvalueindex(1))
	pl := plugin_find(p, owner)
	if pl == nil || pl.state != .Enabled || pl.gen != u64(lua.tointeger(L, lua.upvalueindex(2))) || pl.exports == lua.NOREF {
		return plugin_raise(L, fmt.tprintf("plugin '%s' was unloaded", owner))
	}
	if L != p.L && plugin_task_of(p, L) == nil {
		return plugin_raise(L, "exported functions can only be called from a command, handler or timer, not a coroutine of your own")
	}
	n := lua.gettop(L)
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.exports))
	lua.pushvalue(L, lua.upvalueindex(4))
	lua.rawget(L, -2)
	lua.remove(L, -2)
	lua.insert(L, 1)
	lua.pushcfunction(L, plugin_msgh)
	lua.insert(L, 1)
	caller, _ := plugin_key(L, lua.upvalueindex(3))
	append(&p.calls, PluginCall{co = L, owner = pl.name, caller = plugin_name_intern(p, caller)})
	status := lua.pcall(L, n, lua.MULTRET, 1, 0, plugin_export_k)
	return plugin_export_k(L, c.int(status), 0)
}

plugin_export_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	context = plugin_entry(L).ctx
	p := &plugin_entry(L).editor.plugins
	for i := len(p.calls) - 1; i >= 0; i -= 1 {
		if p.calls[i].co == L {
			ordered_remove(&p.calls, i)
			break
		}
	}
	lua.remove(L, 1)
	if lua.Status(status) != .OK && lua.Status(status) != .YIELD {
		return lua.error(L)
	}
	return lua.gettop(L)
}

qed_caller :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	me, _ := plugin_key(L, lua.upvalueindex(1))
	for i := len(p.calls) - 1; i >= 0; i -= 1 {
		if c := p.calls[i]; c.co == L && c.owner == me {
			lua.pushodinstring(L, c.caller)
			return 1
		}
	}
	lua.pushnil(L)
	return 1
}

qed_hook_off :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	if i := plugin_hook_index(p, api_handle_id(L)); i >= 0 {
		plugin_hook_remove(p, i)
	}
	return 0
}

api_timer :: proc "c" (L: ^lua.State, every: bool) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	ms := api_int(L, 1, "milliseconds expected")
	if ms < (1 if every else 0) {
		lua.L_argerror(L, 1, "interval must be positive" if every else "delay must not be negative")
	}
	if lua.type(L, 2) != .FUNCTION {
		lua.L_argerror(L, 2, "function expected")
	}
	pl := api_loaded(L, editor)
	lua.settop(L, 2)
	id := plugin_next_id(p)
	api_handle_push(L, id, {{"stop", qed_timer_stop}})
	lua.pushvalue(L, 2)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	append(&p.timers, PluginTimer{id = id, owner = pl.name, ref = ref, every_ms = ms if every else 0, due = plugin_tick_add(time.tick_now(), ms)})
	return 1
}

qed_defer :: proc "c" (L: ^lua.State) -> c.int {
	return api_timer(L, false)
}

qed_every :: proc "c" (L: ^lua.State) -> c.int {
	return api_timer(L, true)
}

qed_timer_stop :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	if i := plugin_timer_index(p, api_handle_id(L)); i >= 0 {
		plugin_timer_remove(p, i)
	}
	return 0
}

qed_sleep :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	ms := api_int(L, 1, "milliseconds expected")
	if ms < 0 {
		lua.L_argerror(L, 1, "delay must not be negative")
	}
	t := api_await(L, p, "qed.sleep")
	t.wait = {kind = .Sleep, until = plugin_tick_add(time.tick_now(), ms)}
	return lua.yieldk(L, 0, 0, qed_sleep_k)
}

qed_sleep_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_sleep_k)
	}
	return 0
}

// Linux MAX_ARG_STRLEN: execve fails with E2BIG on any single longer string.
API_ARG_MAX :: 128 * 1024

ApiSpawn :: struct {
	argv:    []string,
	label:   string,
	stdin:   string,
	cwd:     string,
	env:     []string,
	on_line: bool,
}

api_field_string :: proc(L: ^lua.State, t: c.int, key: cstring) -> (string, bool) {
	tp := lua.getfield(L, t, key)
	defer lua.pop(L, 1)
	if tp == .NIL {
		return "", false
	}
	if tp != .STRING {
		plugin_raise(L, fmt.tprintf("%s must be a string", key))
	}
	s, _ := lua.toodinstring(L, -1)
	return strings.clone(s, context.temp_allocator), true
}

api_env_merge :: proc(L: ^lua.State) -> []string {
	overrides := make(map[string]string, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		if lua.type(L, -2) != .STRING || lua.type(L, -1) != .STRING {
			plugin_raise(L, "env must map strings to strings")
		}
		k, _ := lua.toodinstring(L, -2)
		v, _ := lua.toodinstring(L, -1)
		overrides[strings.clone(k, context.temp_allocator)] = strings.clone(v, context.temp_allocator)
		lua.pop(L, 1)
	}
	base, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, context.temp_allocator)
	for kv in base {
		eq := strings.index_byte(kv, '=')
		if eq > 0 && kv[:eq] in overrides {
			continue
		}
		append(&env, kv)
	}
	for k, v in overrides {
		append(&env, fmt.tprintf("%s=%s", k, v))
	}
	return env[:]
}

api_spawn_opts :: proc(L: ^lua.State, editor: ^Editor) -> (o: ApiSpawn) {
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table {cmd | argv, stdin?, cwd?, env?, on_line?} expected")
	}
	lua.settop(L, 1)
	lua.L_checkstack(L, 4, "spawn options")
	cmd, has_cmd := api_field_string(L, 1, "cmd")
	argv_t := lua.getfield(L, 1, "argv")
	if has_cmd == (argv_t == .TABLE) || (argv_t != .TABLE && argv_t != .NIL) {
		plugin_raise(L, "exactly one of cmd (string) or argv (table) is required")
	}
	if has_cmd {
		o.argv = make([]string, 3, context.temp_allocator)
		o.argv[0], o.argv[1], o.argv[2] = "sh", "-c", cmd
		o.label = cmd
	} else {
		n := int(lua.rawlen(L, -1))
		if n == 0 {
			plugin_raise(L, "argv must not be empty")
		}
		o.argv = make([]string, n, context.temp_allocator)
		for i in 1 ..= n {
			if lua.rawgeti(L, -1, lua.Integer(i)) != .STRING {
				plugin_raise(L, "argv entries must be strings")
			}
			s, _ := lua.toodinstring(L, -1)
			o.argv[i - 1] = strings.clone(s, context.temp_allocator)
			lua.pop(L, 1)
		}
		o.label = strings.join(o.argv, " ", context.temp_allocator)
	}
	lua.pop(L, 1)
	o.stdin, _ = api_field_string(L, 1, "stdin")
	cwd, has_cwd := api_field_string(L, 1, "cwd")
	o.cwd = api_path(editor, cwd) if has_cwd else editor.working_root
	env_t := lua.getfield(L, 1, "env")
	if env_t == .TABLE {
		o.env = api_env_merge(L)
	} else if env_t != .NIL {
		plugin_raise(L, "env must be a table")
	}
	lua.pop(L, 1)
	for a in o.argv {
		if len(a) >= API_ARG_MAX {
			plugin_raise(L, fmt.tprintf("command argument too long (%d bytes, limit %d KiB); pass large text on stdin", len(a), API_ARG_MAX / 1024))
		}
	}
	for kv in o.env {
		if len(kv) >= API_ARG_MAX {
			plugin_raise(L, fmt.tprintf("environment value %s too long (%d bytes, limit %d KiB)", kv[:strings.index_byte(kv, '=')], len(kv), API_ARG_MAX / 1024))
		}
	}
	line_t := lua.getfield(L, 1, "on_line")
	if line_t != .FUNCTION && line_t != .NIL {
		plugin_raise(L, "on_line must be a function")
	}
	lua.pop(L, 1)
	o.on_line = line_t == .FUNCTION
	return
}

api_spawn_start :: proc(L: ^lua.State, editor: ^Editor, pl: ^Plugin, o: ApiSpawn, id: u64, bg: bool) {
	p := &editor.plugins
	line_ref: i32
	if o.on_line {
		lua.getfield(L, 1, "on_line")
		line_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	}
	for f in p.fakes {
		if strings.contains(o.label, f.pattern) {
			sp := Subprocess{id = id, out = strings.builder_make(), err = strings.builder_make(), exit_code = f.code}
			strings.write_string(&sp.out, f.stdout)
			strings.write_string(&sp.err, f.stderr)
			append(&p.procs, PluginProc{id = id, owner = pl.name, sp = sp, line_ref = line_ref, bg = bg, fake = true, due = plugin_tick_add(time.tick_now(), f.delay_ms)})
			return
		}
	}
	sp, err, ok := subprocess_spawn(o.argv, transmute([]u8)o.stdin, o.cwd, o.env, true, group = true)
	if !ok {
		if line_ref != 0 {
			lua.L_unref(L, lua.REGISTRYINDEX, c.int(line_ref))
		}
		plugin_raise(L, fmt.tprintf("cannot start %s: %v", o.label, err))
	}
	append(&p.procs, PluginProc{id = id, owner = pl.name, sp = sp, line_ref = line_ref, bg = bg})
}

qed_spawn :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	o := api_spawn_opts(L, editor)
	pl := api_loaded(L, editor)
	task := api_await(L, p, "qed.spawn").id
	id := plugin_next_id(p)
	api_spawn_start(L, editor, pl, o, id, false)
	p.tasks[plugin_task_index(p, task)].wait = {kind = .Proc, id = id}
	return lua.yieldk(L, 0, lua.KContext(id), qed_spawn_k)
}

qed_spawn_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_spawn_k)
	}
	context = entry.ctx
	return api_proc_result(L, &entry.editor.plugins, u64(ctx))
}

api_proc_result :: proc(L: ^lua.State, p: ^Plugins, id: u64) -> c.int {
	i := plugin_proc_index(p, id)
	if i < 0 {
		return api_fail(L, "process is gone")
	}
	pr := &p.procs[i]
	lua.createtable(L, 0, 3)
	lua.pushinteger(L, lua.Integer(pr.sp.exit_code))
	lua.setfield(L, -2, "code")
	lua.pushodinstring(L, strings.to_string(pr.sp.out))
	lua.setfield(L, -2, "stdout")
	lua.pushodinstring(L, strings.to_string(pr.sp.err))
	lua.setfield(L, -2, "stderr")
	if len(plugin_waiters(p, .Proc, id)) == 0 {
		plugin_proc_free(p, i)
	}
	return 1
}

qed_spawn_bg :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	o := api_spawn_opts(L, editor)
	pl := api_loaded(L, editor)
	id := plugin_next_id(p)
	api_handle_push(L, id, {{"kill", qed_proc_kill}, {"wait", qed_proc_wait}})
	lua.createtable(L, 0, 1)
	lua.pushvalue(L, lua.upvalueindex(1))
	lua.pushinteger(L, lua.Integer(id))
	lua.pushcclosure(L, qed_proc_gc, 2)
	lua.setfield(L, -2, "__gc")
	lua.setmetatable(L, -2)
	api_spawn_start(L, editor, pl, o, id, true)
	if !p.procs[len(p.procs) - 1].fake {
		lua.pushinteger(L, lua.Integer(p.procs[len(p.procs) - 1].sp.process.pid))
		lua.setfield(L, 2, "pid")
	}
	return 1
}

qed_proc_kill :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	id := api_handle_id(L)
	if i := plugin_proc_index(p, id); i >= 0 && !p.procs[i].done {
		p.procs[i].killed = true
		plugin_proc_stop(&p.procs[i])
		plugin_proc_finish(entry.editor, id)
	}
	return 0
}

qed_proc_gc :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return 0
	}
	context = entry.ctx
	p := &entry.editor.plugins
	if i := plugin_proc_index(p, api_handle_id(L)); i >= 0 {
		p.procs[i].orphan = true
	}
	return 0
}

qed_proc_wait :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	id := api_handle_id(L)
	i := plugin_proc_index(p, id)
	if i < 0 || p.procs[i].done {
		return api_proc_result(L, p, id)
	}
	t := api_await(L, p, "proc:wait")
	t.wait = {kind = .Proc, id = id}
	return lua.yieldk(L, 0, lua.KContext(id), qed_spawn_k)
}

PluginNs :: struct {
	name, owner: string,
	id:          u32,
}

plugin_deco_unload :: proc(editor: ^Editor, owner: string) {
	p := &editor.plugins
	for i := len(p.deco_ns) - 1; i >= 0; i -= 1 {
		ns := p.deco_ns[i]
		if ns.owner != owner {
			continue
		}
		for &b in editor.buffers {
			deco_clear(&b, ns.id)
		}
		delete(ns.name)
		ordered_remove(&p.deco_ns, i)
	}
}

plugin_color_id :: proc(p: ^Plugins, key: string) -> u16 {
	for k, i in p.colors {
		if k == key {
			return u16(i + 1)
		}
	}
	append(&p.colors, strings.clone(key))
	return u16(len(p.colors))
}

api_color :: proc(L: ^lua.State, p: ^Plugins, idx: c.int) -> u16 {
	key := api_string(L, idx)
	api_theme_color(L, key)
	return plugin_color_id(p, key)
}

api_ns :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> u32 {
	n := api_int(L, idx, "namespace expected")
	pl := api_loaded(L, editor)
	for ns in editor.plugins.deco_ns {
		if int(ns.id) == n && ns.owner == pl.name {
			return ns.id
		}
	}
	plugin_raise(L, fmt.tprintf("unknown namespace %d", n))
	return 0
}

api_row :: proc(L: ^lua.State, idx: c.int, b: ^Buffer) -> int {
	row := api_int(L, idx, "row expected")
	if row < 1 || row > len(b.lines) {
		lua.L_argerror(L, idx, fmt.ctprintf("row %d out of range 1..%d", row, len(b.lines)))
	}
	return row - 1
}

qed_deco_ns :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	name := api_string(L, 1)
	pl := api_loaded(L, entry.editor)
	for ns in p.deco_ns {
		if ns.owner == pl.name && ns.name == name {
			lua.pushinteger(L, lua.Integer(ns.id))
			return 1
		}
	}
	p.ns_seq += 1
	append(&p.deco_ns, PluginNs{strings.clone(name), plugin_name_intern(p, pl.name), p.ns_seq})
	lua.pushinteger(L, lua.Integer(p.ns_seq))
	return 1
}

qed_deco_gutter :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	row := api_row(L, 3, b)
	glyph := api_string(L, 4)
	text := transmute([]u8)glyph
	if len(text) == 0 || grapheme_next(text, 0) != len(text) || cluster_width(text) != 1 || !utf8.valid_string(glyph) {
		lua.L_argerror(L, 4, "glyph must be one single-width character")
	}
	r, _ := utf8.decode_rune(text)
	color := api_color(L, &editor.plugins, 5)
	deco_add(b, Deco{kind = .Gutter, ns = ns, from = {row, 0}, to = {row, 0}, glyph = r, color = color})
	return 0
}

qed_deco_tint :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	lo := api_row(L, 3, b)
	hi := api_row(L, 4, b)
	if hi < lo {
		lua.L_argerror(L, 4, "to_row is before from_row")
	}
	color := api_color(L, &editor.plugins, 5)
	d := Deco{kind = .Tint, ns = ns, from = {lo, 0}, to = {hi, 0}, color = color, alpha = DECO_TINT}
	if lua.type(L, 6) > .NIL {
		d.alpha, d.tint = api_alpha(L, 6)
	}
	deco_add(b, d)
	return 0
}

api_alpha :: proc(L: ^lua.State, idx: c.int) -> (alpha: f32, tint: u8) {
	if lua.type(L, idx) == .STRING {
		key, _ := lua.toodinstring(L, idx)
		for t, i in config_tints {
			if t.key == key {
				return 0, u8(i + 1)
			}
		}
		lua.L_argerror(L, idx, fmt.ctprintf("unknown theme tint '%s'", key))
	}
	isnum: b32
	alpha = f32(lua.tonumberx(L, idx, &isnum))
	if !isnum || alpha < 0 || alpha > 1 {
		lua.L_argerror(L, idx, "alpha must be a number in 0..1 or a theme tint key")
	}
	return
}

qed_deco_mark :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	from, to := api_range(L, 3, b)
	editor.plugins.mark_seq += 1
	append(&b.deco.marks, DecoMark{editor.plugins.mark_seq, ns, from, to})
	lua.pushinteger(L, lua.Integer(editor.plugins.mark_seq))
	return 1
}

qed_deco_range :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	id := u64(api_int(L, 3, "mark id expected"))
	for m in b.deco.marks {
		if m.id == id && m.ns == ns {
			api_pos_push(L, m.from)
			api_pos_push(L, m.to)
			return 2
		}
	}
	lua.pushnil(L)
	return 1
}

qed_deco_inline :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	at := api_pos(L, 3, b)
	text := api_text_arg(L, 4)
	stale := api_rev_stale(L, 5, b)
	shown := !stale && at == b.cursor && !selection_active(b) && len(text) > 0
	if shown {
		inline_set(b, ns, at, text)
	}
	lua.pushboolean(L, b32(shown))
	return 1
}

qed_deco_ghost :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	row := api_row(L, 3, b)
	lines := make([dynamic]string, context.temp_allocator)
	#partial switch lua.type(L, 4) {
	case .STRING:
		append(&lines, api_text_arg(L, 4))
	case .TABLE:
		lua.L_checkstack(L, 2, "ghost lines")
		for i in 1 ..= int(lua.rawlen(L, 4)) {
			lua.rawgeti(L, 4, lua.Integer(i))
			append(&lines, api_text_arg(L, -1))
			lua.pop(L, 1)
		}
	case:
		lua.L_argerror(L, 4, "lines must be a string or a list of strings")
	}
	above := false
	color: u16
	if lua.type(L, 5) == .TABLE {
		lua.getfield(L, 5, "above")
		above = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		if lua.getfield(L, 5, "color") != .NIL {
			color = api_color(L, &editor.plugins, -1)
		}
		lua.pop(L, 1)
	} else if lua.type(L, 5) > .NIL {
		lua.L_argerror(L, 5, "options table expected")
	}
	text := strings.join(lines[:], "\n", context.temp_allocator)
	if len(lines) == 0 {
		return 0
	}
	n := strings.count(text, "\n") + 1
	deco_add(b, Deco{kind = .Ghost, ns = ns, from = {row, 0}, to = {row, 0}, text = text, lines = n, above = above, color = color})
	return 0
}

qed_deco_span :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	from, to := api_range(L, 3, b)
	if lua.type(L, 5) != .TABLE {
		lua.L_argerror(L, 5, "style {fg?, bg?, alpha?, bold?, underline?} expected")
	}
	d := Deco{kind = .Span, ns = ns, from = from, to = to}
	if lua.getfield(L, 5, "fg") != .NIL {
		d.color = api_color(L, &editor.plugins, -1)
	}
	if lua.getfield(L, 5, "bg") != .NIL {
		d.bg = api_color(L, &editor.plugins, -1)
	}
	if lua.getfield(L, 5, "alpha") != .NIL {
		if d.bg == 0 {
			plugin_raise(L, "alpha needs bg")
		}
		d.alpha, d.tint = api_alpha(L, -1)
		d.blend = true
	}
	lua.getfield(L, 5, "bold")
	d.bold = bool(lua.toboolean(L, -1))
	lua.getfield(L, 5, "underline")
	d.underline = bool(lua.toboolean(L, -1))
	lua.pop(L, 5)
	if from != to {
		deco_add(b, d)
	}
	return 0
}

qed_deco_eol :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	row := api_row(L, 3, b)
	text := api_one_line(api_text_arg(L, 4))
	color := api_color(L, &editor.plugins, 5)
	deco_add(b, Deco{kind = .Eol, ns = ns, from = {row, 0}, to = {row, 0}, text = text, color = color})
	return 0
}

qed_deco_clear :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	ns := api_ns(L, editor, 2)
	lo, hi := 0, max(int)
	if lua.type(L, 3) > .NIL {
		lo = api_row(L, 3, b)
	}
	if lua.type(L, 4) > .NIL {
		hi = api_row(L, 4, b)
	}
	deco_clear(b, ns, lo, hi)
	return 0
}

qed_buf_set_base :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	clear_base := lua.type(L, 2) <= .NIL
	text := "" if clear_base else api_bytes_arg(L, 2)
	label := "base"
	if lua.type(L, 3) == .TABLE {
		if v, ok := api_field_string(L, 3, "label"); ok {
			label = api_one_line(v)
		}
	} else if lua.type(L, 3) > .NIL {
		lua.L_argerror(L, 3, "options table expected")
	}
	pl := api_loaded(L, editor)
	if clear_base {
		diffbase_clear(b, pl.name)
	} else {
		diffbase_set(b, plugin_name_intern(&editor.plugins, pl.name), text, label)
	}
	lua.pushboolean(L, b32(diffbase_owner(b) == pl.name))
	return 1
}

qed_theme_icon :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	name := api_string(L, 1)
	for it in config_icons {
		if it.key == name {
			lua.pushodinstring(L, it.ptr^)
			return 1
		}
	}
	return plugin_raise(L, fmt.tprintf("unknown icon '%s'", name))
}
