package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import lua "lib:lua"

api_test_editor :: proc(code: string, lines: ..string, cfg_user: json.Object = nil) -> ^Editor {
	ed := new(Editor)
	ed.headless = true
	ed.working_root = strings.clone("/tmp")
	append(&ed.buffers, test_buffer(..lines))
	src := strings.concatenate({`return {
		defaults = {opt = 1, nested = {x = "y"}},
		setup = function(cfg)
			qed.command{name = "T: Run", run = function(ctx)
`, code, `
			end}
		end,
	}`}, context.temp_allocator)
	if cfg_user != nil {
		ed.plugins.config_override = cfg_user
	}
	editor_plugins_start(ed, {{"t.lua", src}}, "", PLUGIN_TEST_MEM)
	return ed
}

api_test_destroy :: proc(ed: ^Editor) {
	delete(ed.working_root)
	jump_destroy(&ed.jumps)
	plugin_test_destroy(ed)
}

api_test_run :: proc(t: ^testing.T, ed: ^Editor, loc := #caller_location) {
	pl := plugin_find(&ed.plugins, "t")
	testing.expect_value(t, pl.state, PluginState.Enabled, loc = loc)
	cmd, ok := plugin_test_command(ed, "T: Run")
	if !testing.expectf(t, ok, "test command registered: %s", pl.last_error, loc = loc) {
		return
	}
	command_run(ed, cmd)
	testing.expect_value(t, pl.last_error, "", loc = loc)
}

api_test_text :: proc(b: ^Buffer) -> string {
	last := len(b.lines) - 1
	return buffer_text_range(b, {0, 0}, {last, len(b.lines[last].text)})
}

@(test)
plugin_api_buf_read :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local b = qed.buf.current()
		assert(ctx.buf == b, "ctx.buf is the current id")
		assert(qed.buf.valid(b) and not qed.buf.valid(b + 1000) and not qed.buf.valid(nil), "valid")
		local ids = qed.buf.list()
		assert(#ids == 2 and ids[1] == b, "list in buffer order")
		local other = ids[2]
		assert(qed.buf.path(b) == "" and qed.buf.language(b) == "text", "path/language " .. qed.buf.language(b))
		assert(qed.buf.modified() == false and qed.buf.rev(0) == 0, "modified/rev, nil and 0 mean current")
		assert(qed.buf.line_count(b) == 3 and qed.buf.line_count(other) == 1, "line_count")
		local all = qed.buf.lines(b)
		assert(#all == 3 and all[1] == "héllo" and all[2] == "" and all[3] == "end", "lines default to the whole buffer")
		local mid = qed.buf.lines(b, 2, 3)
		assert(#mid == 2 and mid[1] == "" and mid[2] == "end", "lines from..to inclusive")
		assert(#qed.buf.lines(b, 2, 1) == 0, "to = from - 1 is empty")
		assert(not pcall(qed.buf.lines, b, 0), "row 0 rejected")
		assert(not pcall(qed.buf.lines, b, 1, 4), "past the end rejected")
		assert(qed.buf.line(b, 1) == "héllo" and qed.buf.line(other, 1) == "", "line")
		assert(not pcall(qed.buf.line, b, 4), "line out of range")
		assert(qed.buf.text(b) == "héllo\n\nend" and qed.buf.text(other) == "", "text joins rows with \\n")
		assert(not pcall(qed.buf.path, "x"), "non-integer id rejected")
	`, "héllo", "", "end")
	defer api_test_destroy(ed)
	append(&ed.buffers, test_buffer())
	ed.buffers[0].language = .Plain
	api_test_run(t, ed)
}

@(test)
plugin_api_indexing :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local b = qed.buf.current()
		local line = qed.buf.line(b, 1)
		local e = qed.buf.insert(b, {row = 1, col = #line + 1}, "!")
		assert(e.row == 1 and e.col == #line + 2, "end-of-line caret insert returns the end")
		assert(qed.buf.line(b, 1) == "héllo!", "appended")
		assert(not pcall(qed.buf.insert, b, {row = 1, col = 3}, "x"), "col inside a multi-byte char rejected")
		assert(not pcall(qed.buf.insert, b, {row = 1, col = 9}, "x"), "col past the caret rejected")
		assert(not pcall(qed.buf.insert, b, {row = 9, col = 1}, "x"), "row out of range rejected")
		assert(not pcall(qed.buf.insert, b, {1, 1}, "x"), "positions are named")
		local s, f = qed.buf.line(b, 1):find("llo")
		assert(qed.buf.delete(b, {row = 1, col = s}, {row = 1, col = f + 1}) == "llo", "half-open delete")
		assert(qed.buf.line(b, 1) == "hé!", "deleted")
		local e2 = qed.buf.insert(b, {row = 1, col = 1}, "a\r\nb\nc")
		assert(e2.row == 3 and e2.col == 2, "multi-line insert end, CRLF normalized")
		assert(qed.buf.text(b) == "a\nb\nché!\nsecond", "text " .. qed.buf.text(b))
		assert(qed.buf.delete(b, {row = 1, col = 2}, {row = 3, col = 2}) == "\nb\nc", "multi-line delete")
		assert(not pcall(qed.buf.delete, b, {row = 1, col = 2}, {row = 1, col = 1}), "reversed range rejected")
		assert(qed.buf.delete(b, {row = 1, col = 1}, {row = 1, col = 1}) == "", "empty range")
		local r = qed.buf.replace(b, {row = 1, col = 1}, {row = 1, col = 2}, "XY")
		assert(r.row == 1 and r.col == 3 and qed.buf.line(b, 1) == "XYhé!", "replace")
	`, "héllo", "second")
	defer api_test_destroy(ed)
	api_test_run(t, ed)
	b := &ed.buffers[0]
	testing.expect_value(t, len(b.undo), 5)
}

@(test)
plugin_api_empty_buffer :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		assert(qed.buf.line_count() == 1 and qed.buf.line(nil, 1) == "", "empty buffer is one empty row")
		assert(qed.buf.text() == "", "empty text")
		local e = qed.buf.insert(nil, {row = 1, col = 1}, "x\n")
		assert(e.row == 2 and e.col == 1, "insert into empty buffer")
		local c = qed.buf.cursor()
		assert(c.row == 2 and c.col == 1, "cursor at the insert point follows the text")
	`)
	defer api_test_destroy(ed)
	api_test_run(t, ed)
	testing.expect_value(t, api_test_text(&ed.buffers[0]), "x\n")
}

@(test)
plugin_api_edit_group :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local b = qed.buf.current()
		local rev = qed.buf.rev(b)
		assert(qed.edit(b, function()
			qed.buf.insert(b, {row = 1, col = 1}, "1")
			qed.buf.insert(b, {row = 1, col = 1}, "2")
			qed.buf.delete(b, {row = 1, col = 3}, {row = 1, col = 4})
			qed.edit(b, function() qed.buf.insert(b, {row = 1, col = 1}, "3") end)
		end, {rev = rev}) == true, "edit returns true")
		assert(qed.buf.line(b, 1) == "321bc", "edits applied " .. qed.buf.line(b, 1))
		local stale = qed.edit(b, function() error("must not run") end, {rev = rev})
		assert(stale == false, "stale rev returns false without running fn")
		local ok, err = pcall(qed.edit, b, function()
			qed.buf.insert(b, {row = 1, col = 1}, "zzz")
			error("halfway")
		end)
		assert(not ok and err:find("halfway"), "error propagates")
		assert(qed.buf.line(b, 1) == "321bc", "a failed edit rolls back")
		assert(qed.edit(b, function() end), "empty edit")
	`, "abc")
	defer api_test_destroy(ed)
	b := &ed.buffers[0]
	b.cursor = {0, 3}
	api_test_run(t, ed)
	testing.expect_value(t, len(b.undo), 1)
	testing.expect_value(t, len(b.redo), 0)
	testing.expect_value(t, ed.plugins.edit, PluginEdit{})
	testing.expect_value(t, b.cursor, Cursor{0, 5})
	editor_undo(ed)
	testing.expect_value(t, api_test_text(b), "abc")
	testing.expect_value(t, b.cursor, Cursor{0, 3})
	testing.expect_value(t, len(b.undo), 0)
}

@(test)
plugin_api_closed_buffer :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local ids = qed.buf.list()
		local second, third = ids[2], ids[3]
		assert(qed.close(third) == false, "a modified buffer stays open")
		assert(qed.close(second) == true, "an unmodified buffer closes")
		assert(not qed.buf.valid(second), "closed id is invalid")
		local ok, err = pcall(qed.buf.line, second, 1)
		assert(not ok and err:find("buffer closed"), "closed buffer raises: " .. tostring(err))
		assert(qed.buf.line(third, 1) == "three", "ids survive reallocation")
	`, "one")
	defer api_test_destroy(ed)
	append(&ed.buffers, test_buffer("two"))
	append(&ed.buffers, test_buffer("three"))
	ed.buffers[2].modified = true
	api_test_run(t, ed)
	testing.expect_value(t, len(ed.buffers), 2)
}

@(test)
plugin_api_cursor_selection :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local b = qed.buf.current()
		assert(qed.buf.selection(b) == nil, "no selection")
		qed.buf.set_selection(b, {row = 2, col = 3}, {row = 1, col = 2})
		local from, to = qed.buf.selection(b)
		assert(from.row == 1 and from.col == 2 and to.row == 2 and to.col == 3, "selection is ordered")
		local c = qed.buf.cursor(b)
		assert(c.row == 1 and c.col == 2, "cursor is the moving end")
		qed.buf.insert(b, {row = 1, col = 1}, ">>")
		from, to = qed.buf.selection(b)
		assert(from.col == 4 and to.col == 3, "marks follow an insert before them")
		qed.buf.set_cursor(b, {row = 2, col = 4})
		assert(qed.buf.selection(b) == nil, "set_cursor clears the selection")
		qed.buf.set_language(b, "lua")
		assert(qed.buf.language(b) == "lua", "set_language")
		assert(not pcall(qed.buf.set_language, b, "Klingon"), "unknown language")
		qed.buf.set_indent(b, "tabs")
		qed.buf.set_indent(b, "spaces", 2)
		assert(not pcall(qed.buf.set_indent, b, "both"), "bad indent style")
	`, "abcd", "efgh")
	defer api_test_destroy(ed)
	api_test_run(t, ed)
	b := &ed.buffers[0]
	testing.expect_value(t, b.language, Language.Lua)
	testing.expect_value(t, b.indent, IndentStyle.Spaces)
	testing.expect_value(t, b.indent_width, 2)
}

@(test)
plugin_api_open_jump_save :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_api_test_%d", tmp, posix.getpid())
	os.make_directory(dir)
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	lines := make([dynamic]string, context.temp_allocator)
	for i in 1 ..= 40 {
		append(&lines, fmt.tprintf("line %d", i))
	}
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", dir), transmute([]u8)strings.join(lines[:], "\n", context.temp_allocator))
	ed := api_test_editor(`
		local first = qed.buf.current()
		local b = assert(qed.open("a.txt"))
		assert(qed.buf.current() == b and b ~= first, "open switches to the new buffer")
		assert(qed.open("a.txt") == b, "reopening returns the same id")
		assert(qed.buf.path(b):sub(-6) == "/a.txt", "relative to the root")
		qed.jump(first, {row = 1, col = 1})
		assert(qed.buf.current() == first, "jump switches")
		qed.jump(b, {row = 30, col = 3})
		local c = qed.buf.cursor(b)
		assert(c.row == 30 and c.col == 3, "jump moves the cursor")
		qed.buf.insert(b, {row = 1, col = 1}, "x")
		assert(qed.buf.modified(b), "modified")
		qed.save(b)
		assert(not qed.buf.modified(b), "saved")
	`, "scratch")
	defer api_test_destroy(ed)
	delete(ed.working_root)
	ed.working_root = strings.clone(dir)
	ed.buffers[0].modified = true
	api_test_run(t, ed)
	data, _ := os.read_entire_file(fmt.tprintf("%s/a.txt", dir), context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(data), "xline 1\n"), "save wrote the file")
	if testing.expect(t, len(ed.jumps.entries) >= 2, "jump records a jump list entry") {
		testing.expect_value(t, ed.jumps.entries[ed.jumps.index].row, 29)
	}
}

@(test)
plugin_api_misc :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_api_misc_%d", tmp, posix.getpid())
	os.make_directory(dir)
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	cfg := plugin_test_cfg(`{"plugins": {"t": {"nested": {"x": "z"}}}}`)
	ed := api_test_editor(`
		assert(qed.root() == ROOT, "root")
		assert(type(qed.version) == "string", "version")
		assert(qed.shell_quote("it's") == "'it'\\''s'", "shell_quote")
		assert(qed.text.width("héllo") == 5 and qed.text.width("日本") == 4, "display width")
		local c = qed.config()
		assert(c.opt == 1 and c.nested.x == "z", "merged config")
		c.opt = 99
		assert(qed.config().opt == 1, "config copies are read-only")
		assert(qed.opt("tab_width") == TAB and qed.opt("line_wrap") ~= nil and type(qed.opt("theme")) == "string", "core knobs")
		assert(type(qed.opt("modules.lsp.completion_max_rows")) == "number", "module knob")
		assert(not pcall(qed.opt, "nope") and not pcall(qed.opt, "modules.x.y"), "unknown knob")

		assert(qed.fs.write("sub/f.json", qed.json.encode({b = {1, 2, 3}, a = "x", c = true, d = 1.5})) == true, "write creates parents")
		assert(qed.fs.read("sub/f.json") == '{"a":"x","b":[1,2,3],"c":true,"d":1.5}', "encode is sorted and compact: " .. qed.fs.read("sub/f.json"))
		assert(qed.fs.exists(ROOT .. "/sub/f.json") and not qed.fs.exists("nope"), "exists")
		local st = qed.fs.stat("sub/f.json")
		assert(st.type == "file" and st.size > 0 and st.mtime > 0, "stat")
		assert(qed.fs.stat("sub").type == "dir", "stat dir")
		local d, derr = qed.fs.read("nope")
		assert(d == nil and derr:find("cannot read"), "read failure is nil, err")
		qed.fs.write("sub/a.txt", "")
		local names = qed.fs.list("sub")
		assert(#names == 2 and names[1] == "a.txt" and names[2] == "f.json", "list is sorted")
		local v = qed.json.decode('{"k": [1, null, "s"], "n": 2.5}')
		assert(v.k[1] == 1 and v.k[2] == nil and v.k[3] == "s" and v.n == 2.5, "decode")
		local bad, jerr = qed.json.decode("{")
		assert(bad == nil and jerr, "decode error")
		assert(qed.json.encode({}) == "{}", "empty table")
		assert(not pcall(qed.json.encode, {1, x = 2}), "mixed table rejected")
		assert(not pcall(qed.json.encode, {f = print}), "functions rejected")

		assert(qed.path.join("a", "b", "c.lua") == "a/b/c.lua", "join")
		assert(qed.path.dir("/a/b/c.lua") == "/a/b" and qed.path.base("/a/b/c.lua") == "c.lua", "dir/base")
		assert(qed.path.rel(ROOT .. "/sub/f.json") == "sub/f.json", "rel to root")
		assert(qed.path.rel("/x/y/z", "/x") == "y/z", "rel to base")
		assert(qed.path.abs("sub/../f") == ROOT .. "/f", "abs resolves against the root")
	`, cfg_user = cfg)
	defer api_test_destroy(ed)
	delete(ed.working_root)
	ed.working_root = strings.clone(dir)
	L := ed.plugins.L
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(plugin_find(&ed.plugins, "t").env))
	lua.pushodinstring(L, dir)
	lua.setfield(L, -2, "ROOT")
	lua.pushinteger(L, lua.Integer(TAB_WIDTH))
	lua.setfield(L, -2, "TAB")
	lua.pop(L, 1)
	api_test_run(t, ed)
}

@(test)
plugin_api_config_before_setup :: proc(t: ^testing.T) {
	ed := plugin_test_editor({{"early.lua", `qed.config(); return {}`}})
	defer plugin_test_destroy(ed)
	pl := plugin_find(&ed.plugins, "early")
	testing.expect_value(t, pl.state, PluginState.Errored)
	testing.expect(t, strings.contains(pl.last_error, "once setup runs"), "config before setup is a clear error")
}

api_test_walk :: proc(L: ^lua.State, prefix: string, out: ^[dynamic]string) {
	t := lua.gettop(L)
	lua.pushnil(L)
	for lua.next(L, t) != 0 {
		key, _ := lua.toodinstring(L, -2)
		name := fmt.tprintf("%s.%s", prefix, key)
		#partial switch lua.type(L, -1) {
		case .FUNCTION:
			append(out, fmt.tprintf("function %s(", name))
		case .TABLE:
			append(out, fmt.tprintf("%s = {{}}", name))
			api_test_walk(L, name, out)
		case:
			append(out, fmt.tprintf("%s = ", name))
		}
		lua.pop(L, 1)
	}
}

@(test)
plugin_api_stub_complete :: proc(t: ^testing.T) {
	ed := plugin_test_editor({})
	defer plugin_test_destroy(ed)
	L := ed.plugins.L
	plugin_qed_push(L, "stub")
	want := make([dynamic]string, context.temp_allocator)
	api_test_walk(L, "qed", &want)
	lua.pop(L, 1)
	testing.expect(t, len(want) > 50, "walked the qed table")
	testing.expect(t, strings.has_prefix(QED_STUB, "---@meta"), "stub is a meta file")
	for w in want {
		testing.expectf(t, strings.contains(QED_STUB, w), "plugins/meta/qed.lua is missing `%s`", w)
	}
}

@(test)
plugin_api_stub_write :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_stub_test_%d/qed/lua", tmp, posix.getpid())
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(fmt.tprintf("%s/qed_stub_test_%d", tmp, posix.getpid()))))
	testing.expect(t, plugin_stub_write(dir), "first write creates the stub")
	testing.expect(t, !plugin_stub_write(dir), "unchanged content is not rewritten")
	path := fmt.tprintf("%s/qed.lua", dir)
	_ = os.write_entire_file(path, transmute([]u8)string("old"))
	testing.expect(t, plugin_stub_write(dir), "changed content is rewritten")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, string(data) == QED_STUB, "stub content")
}

@(test)
plugin_api_lsp_lua_config :: proc(t: ^testing.T) {
	v, err := json.parse_string(lsp_config_for_section("Lua"), allocator = context.temp_allocator)
	testing.expect(t, err == nil, "Lua settings are valid JSON")
	obj := v.(json.Object)
	lib := obj["workspace"].(json.Object)["library"].(json.Array)
	testing.expect_value(t, string(lib[0].(json.String)), plugin_stub_dir())
	testing.expect_value(t, string(obj["runtime"].(json.Object)["version"].(json.String)), "Lua 5.4")
	testing.expect_value(t, string(obj["diagnostics"].(json.Object)["globals"].(json.Array)[0].(json.String)), "qed")
}
