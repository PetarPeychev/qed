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
import lua "lib:lua"

QED_STUB :: #load("../plugins/meta/qed.lua", string)

PluginEdit :: struct {
	id:      u64,
	started: bool,
}

@(private = "file")
qed_api := [?]lua.L_Reg {
	{"log", qed_log},
	{"message", qed_message},
	{"command", qed_command},
	{"run", qed_run},
	{"edit", qed_edit},
	{"open", qed_open},
	{"save", qed_save},
	{"close", qed_close},
	{"jump", qed_jump},
	{"root", qed_root},
	{"config", qed_config},
	{"opt", qed_opt},
	{"shell_quote", qed_shell_quote},
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
	{"rev", qed_buf_rev},
	{"line_count", qed_buf_line_count},
	{"lines", qed_buf_lines},
	{"line", qed_buf_line},
	{"text", qed_buf_text},
	{"insert", qed_buf_insert},
	{"delete", qed_buf_delete},
	{"replace", qed_buf_replace},
	{"cursor", qed_buf_cursor},
	{"set_cursor", qed_buf_set_cursor},
	{"selection", qed_buf_selection},
	{"set_selection", qed_buf_set_selection},
	{"set_language", qed_buf_set_language},
	{"set_indent", qed_buf_set_indent},
	{nil, nil},
}

@(private = "file")
qed_fs_api := [?]lua.L_Reg {
	{"read", qed_fs_read},
	{"write", qed_fs_write},
	{"exists", qed_fs_exists},
	{"stat", qed_fs_stat},
	{"list", qed_fs_list},
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
qed_text_api := [?]lua.L_Reg {
	{"width", qed_text_width},
	{nil, nil},
}

plugin_qed_push :: proc(L: ^lua.State, name: string) {
	lua.newtable(L)
	lua.pushodinstring(L, name)
	lua.L_setfuncs(L, raw_data(qed_api[:]), 1)
	lua.pushodinstring(L, VERSION)
	lua.setfield(L, -2, "version")
	subs := [?]struct {
		name: cstring,
		regs: []lua.L_Reg,
	}{{"buf", qed_buf_api[:]}, {"fs", qed_fs_api[:]}, {"json", qed_json_api[:]}, {"path", qed_path_api[:]}, {"text", qed_text_api[:]}}
	for s in subs {
		lua.newtable(L)
		lua.pushodinstring(L, name)
		lua.L_setfuncs(L, raw_data(s.regs), 1)
		lua.setfield(L, -2, s.name)
	}
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
	text := api_string(L, idx)
	if strings.contains_rune(text, '\r') {
		text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
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

api_edit_begin :: proc(p: ^Plugins, b: ^Buffer) {
	if p.edit.id == b.id {
		if !p.edit.started || !b.has_open {
			edit_open(b, .Atomic)
			p.edit.started = true
		}
		return
	}
	edit_open(b, .Atomic)
}

api_edit_end :: proc(p: ^Plugins, b: ^Buffer) {
	if p.edit.id != b.id {
		buffer_undo_commit(b)
	}
	cursor_goal_sync(b)
}

api_edit_finish :: proc(b: ^Buffer, ok: bool) {
	if !b.has_open {
		return
	}
	if ok && len(b.open.edits) > 0 {
		buffer_undo_commit(b)
	} else {
		group := b.open
		b.open = {}
		b.has_open = false
		b.open_kind = .None
		inv := buffer_apply_inverse(b, group)
		group_destroy(&inv)
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
	p := &entry.editor.plugins
	b, _ := api_buf(L, entry.editor, 1)
	at := api_pos(L, 2, b)
	text := api_text_arg(L, 3)
	if text == "" {
		api_pos_push(L, at)
		return 1
	}
	api_edit_begin(p, b)
	end := edit_insert(b, at, text)
	api_marks_insert(b, at, end)
	api_edit_end(p, b)
	api_pos_push(L, end)
	return 1
}

qed_buf_delete :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	b, _ := api_buf(L, entry.editor, 1)
	from, to := api_range(L, 2, b)
	if from == to {
		lua.pushodinstring(L, "")
		return 1
	}
	api_edit_begin(p, b)
	edit_delete(b, from, to)
	lua.pushodinstring(L, b.open.edits[len(b.open.edits) - 1].text)
	api_marks_delete(b, from, to)
	api_edit_end(p, b)
	return 1
}

qed_buf_replace :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	b, _ := api_buf(L, entry.editor, 1)
	from, to := api_range(L, 2, b)
	text := api_text_arg(L, 4)
	if from == to && text == "" {
		api_pos_push(L, from)
		return 1
	}
	api_edit_begin(p, b)
	if from != to {
		edit_delete(b, from, to)
		api_marks_delete(b, from, to)
	}
	end := from
	if text != "" {
		end = edit_insert(b, from, text)
		api_marks_insert(b, from, end)
	}
	api_edit_end(p, b)
	api_pos_push(L, end)
	return 1
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
			editor_set_language(entry.editor, b, lang)
			return 0
		}
	}
	return plugin_raise(L, fmt.tprintf("unknown language '%s'", name))
}

qed_buf_set_indent :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, _ := api_buf(L, entry.editor, 1)
	style := api_string(L, 2)
	if style != "tabs" && style != "spaces" {
		lua.L_argerror(L, 2, "\"tabs\" or \"spaces\" expected")
	}
	width := api_int(L, 3, "width expected") if lua.type(L, 3) > .NIL else TAB_WIDTH
	if width < 1 || width > 16 {
		lua.L_argerror(L, 3, "width must be 1..16")
	}
	b.indent = .Tabs if style == "tabs" else .Spaces
	b.indent_width = width
	return 0
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
	if t := lua.type(L, 3); t == .TABLE {
		lua.pushodinstring(L, "rev")
		if lua.rawget(L, 3) > .NIL {
			rev := api_int(L, -1, "rev must be an integer")
			if u64(rev) != b.rev {
				lua.pushboolean(L, false)
				return 1
			}
		}
	} else if t > .NIL {
		lua.L_argerror(L, 3, "options table expected")
	}
	id := b.id
	lua.settop(L, 2)
	lua.pushcfunction(L, plugin_msgh)
	lua.pushvalue(L, 2)
	prev := p.edit
	nested := prev.id == id
	if !nested {
		p.edit = {id = id}
	}
	status := lua.pcall(L, 0, 0, 3)
	if !nested {
		started := p.edit.started
		p.edit = prev
		if bb, _ := api_buf_find(editor, id); bb != nil && started {
			api_edit_finish(bb, status == .OK)
		}
	}
	if status != .OK {
		return lua.error(L)
	}
	lua.pushboolean(L, true)
	return 1
}

api_path :: proc(editor: ^Editor, path: string) -> string {
	if filepath.is_abs(path) {
		clean, _ := filepath.clean(path, context.temp_allocator)
		return clean
	}
	joined, _ := filepath.join({editor.working_root, path}, context.temp_allocator)
	return joined
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
	b, _ := api_buf(L, entry.editor, 1)
	editor_save_full(entry.editor, b)
	return 0
}

qed_close :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b, idx := api_buf(L, entry.editor, 1)
	if b.modified {
		lua.pushboolean(L, false)
		return 1
	}
	editor_close_index(entry.editor, idx)
	lua.pushboolean(L, true)
	return 1
}

qed_jump :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, idx := api_buf(L, editor, 1)
	pos := api_pos(L, 2, b)
	origin := jump_here(editor)
	if idx != editor.current {
		editor_switch_to(editor, idx)
	}
	editor_goto(editor, pos.row, pos.col)
	jump_record(editor, origin)
	return 0
}

qed_root :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	lua.pushodinstring(L, entry.editor.working_root)
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

qed_opt :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	key := api_string(L, 1)
	ints := config_ints[:]
	bools := config_bools[:]
	strs: []Config_Str
	name := key
	if strings.has_prefix(key, "modules.") {
		rest := key[len("modules."):]
		dot := strings.index_byte(rest, '.')
		def, ok := config_module_def(rest[:max(dot, 0)])
		if dot < 0 || !ok {
			return plugin_raise(L, fmt.tprintf("unknown option '%s'", key))
		}
		ints, bools, strs, name = def.ints, def.bools, def.strs, rest[dot + 1:]
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
	mode := os.perm(0o644)
	if fi, err := os.stat(path, context.temp_allocator); err == nil {
		mode = fi.mode
	}
	path_ensure_parent_dir(path)
	tmp := strings.concatenate({path, ".qed-tmp"}, context.temp_allocator)
	fd, open_err := os.open(tmp, {.Write, .Create, .Trunc}, mode)
	if open_err != nil {
		return api_fail(L, fmt.tprintf("cannot write %s: %v", path, open_err))
	}
	_, write_err := os.write(fd, transmute([]u8)data)
	os.close(fd)
	if write_err == nil {
		write_err = os.rename(tmp, path)
	}
	if write_err != nil {
		os.remove(tmp)
		return api_fail(L, fmt.tprintf("cannot write %s: %v", path, write_err))
	}
	lua.pushboolean(L, true)
	return 1
}

qed_fs_exists :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushboolean(L, b32(os.exists(api_path(entry.editor, api_string(L, 1)))))
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

api_json_write :: proc(L: ^lua.State, idx: c.int, sb: ^strings.Builder, depth: int) -> string {
	if depth > PLUGIN_TABLE_DEPTH_MAX {
		return "nested too deeply"
	}
	#partial switch lua.type(L, idx) {
	case .NIL:
		strings.write_string(sb, "null")
	case .BOOLEAN:
		strings.write_string(sb, "true" if lua.toboolean(L, idx) else "false")
	case .NUMBER:
		if lua.isinteger(L, idx) {
			fmt.sbprintf(sb, "%d", lua.tointeger(L, idx, nil))
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
		n := int(lua.rawlen(L, t))
		keys := make([dynamic]string, context.temp_allocator)
		count := 0
		lua.pushnil(L)
		for lua.next(L, t) != 0 {
			count += 1
			if lua.type(L, -2) == .STRING {
				k, _ := lua.toodinstring(L, -2)
				append(&keys, strings.clone(k, context.temp_allocator))
			}
			lua.pop(L, 1)
		}
		if n > 0 && count == n {
			strings.write_byte(sb, '[')
			for i in 1 ..= n {
				if i > 1 {
					strings.write_byte(sb, ',')
				}
				lua.rawgeti(L, t, lua.Integer(i))
				err := api_json_write(L, -1, sb, depth + 1)
				lua.pop(L, 1)
				if err != "" {
					return err
				}
			}
			strings.write_byte(sb, ']')
			return ""
		}
		if len(keys) != count {
			return "table keys must be all strings or a 1..n sequence"
		}
		slice.sort(keys[:])
		strings.write_byte(sb, '{')
		for k, i in keys {
			if i > 0 {
				strings.write_byte(sb, ',')
			}
			strings.write_string(sb, lsp_json_string(k))
			strings.write_byte(sb, ':')
			lua.pushodinstring(L, k)
			lua.rawget(L, t)
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
