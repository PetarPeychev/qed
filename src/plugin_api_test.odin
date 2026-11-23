package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import lua "lib:lua"

api_test_editor :: proc(code: string, lines: ..string, cfg_user: json.Object = nil) -> ^Editor {
	ed := new(Editor)
	ed.headless = true
	ed.working_root = strings.clone("/tmp")
	append(&ed.buffers, test_buffer(..lines))
	src := strings.concatenate({`return {
		setup = function()
			qed.options{opt = 1, nested = {x = "y"}}
			qed.command{name = "Run", run = function(ctx)
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
plugin_api_set_text_and_lsp_format :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	ed := api_test_editor(`
		local b = qed.buf.current()
		b:set_cursor({row = 3, col = 2})
		local rev = b:rev()
		assert(not b:set_text("x", {rev = rev + 1}), "stale rev refused")
		assert(b:text() == "one\ntwo\nthree", "untouched")
		assert(b:set_text("zero\r\none\nTWO\nthree", {rev = rev}), "fresh rev applies")
		assert(b:text() == "zero\none\nTWO\nthree", "CRLF normalized")
		local c = b:cursor()
		assert(c.row == 4 and c.col == 2, "the cursor follows its line")
		assert(not pcall(b.set_text, b, "\xff"), "invalid UTF-8 rejected")
		local ok, err = qed.lsp.format(b)
		assert(ok == nil and err == "no server", "no server: " .. tostring(err))
		assert(not pcall(qed.edit, b, function() qed.lsp.format(b) end), "cannot wait inside qed.edit")
	`, "one", "two", "three")
	defer api_test_destroy(ed)
	ed.buffers[0].language = .Plain
	api_test_run(t, ed)
	testing.expect_value(t, len(ed.buffers[0].undo), 1)
}

@(test)
plugin_api_buf_read :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local b = qed.buf.current()
		assert(ctx.buf == b, "ctx.buf is the current id")
		assert(b:valid(), "valid")
		local ids = qed.buf.list()
		assert(#ids == 2 and ids[1] == b, "list in buffer order")
		local other = ids[2]
		assert(b:path() == "" and b:language() == "text", "path/language " .. b:language())
		assert(qed.buf.current():modified() == false and qed.buf.current():rev() == 0, "modified/rev, nil and 0 mean current")
		assert(b:line_count() == 3 and other:line_count() == 1, "line_count")
		local all = b:lines()
		assert(#all == 3 and all[1] == "héllo" and all[2] == "" and all[3] == "end", "lines default to the whole buffer")
		local mid = b:lines(2, 3)
		assert(#mid == 2 and mid[1] == "" and mid[2] == "end", "lines from..to inclusive")
		assert(#b:lines(2, 1) == 0, "to = from - 1 is empty")
		assert(not pcall(b.lines, b, 0), "row 0 rejected")
		assert(not pcall(b.lines, b, 1, 4), "past the end rejected")
		assert(b:line(1) == "héllo" and other:line(1) == "", "line")
		assert(not pcall(b.line, b, 4), "line out of range")
		assert(b:text() == "héllo\n\nend" and other:text() == "", "text joins rows with \\n")
		assert(not pcall(qed.edit, 7, function() end), "an id is not a buffer")
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
		local line = b:line(1)
		local e = b:insert({row = 1, col = #line + 1}, "!")
		assert(e.row == 1 and e.col == #line + 2, "end-of-line caret insert returns the end")
		assert(b:line(1) == "héllo!", "appended")
		assert(not pcall(b.insert, b, {row = 1, col = 3}, "x"), "col inside a multi-byte char rejected")
		assert(not pcall(b.insert, b, {row = 1, col = 9}, "x"), "col past the caret rejected")
		assert(not pcall(b.insert, b, {row = 9, col = 1}, "x"), "row out of range rejected")
		assert(not pcall(b.insert, b, {1, 1}, "x"), "positions are named")
		assert(not pcall(b.insert, b, {row = 1, col = 1}, "\xff"), "invalid UTF-8 rejected")
		local s, f = b:line(1):find("llo")
		assert(b:delete({row = 1, col = s}, {row = 1, col = f + 1}) == "llo", "half-open delete")
		assert(b:line(1) == "hé!", "deleted")
		local e2 = b:insert({row = 1, col = 1}, "a\r\nb\rc")
		assert(e2.row == 3 and e2.col == 2, "multi-line insert end, CRLF and lone CR normalized")
		assert(b:text() == "a\nb\nché!\nsecond", "text " .. b:text())
		assert(b:delete({row = 1, col = 2}, {row = 3, col = 2}) == "\nb\nc", "multi-line delete")
		assert(not pcall(b.delete, b, {row = 1, col = 2}, {row = 1, col = 1}), "reversed range rejected")
		assert(b:delete({row = 1, col = 1}, {row = 1, col = 1}) == "", "empty range")
		local r = b:replace({row = 1, col = 1}, {row = 1, col = 2}, "XY")
		assert(r.row == 1 and r.col == 3 and b:line(1) == "XYhé!", "replace")
	`, "héllo", "second")
	defer api_test_destroy(ed)
	api_test_run(t, ed)
	b := &ed.buffers[0]
	testing.expect_value(t, len(b.undo), 5)
}

@(test)
plugin_api_empty_buffer :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		assert(qed.buf.current():line_count() == 1 and qed.buf.current():line(1) == "", "empty buffer is one empty row")
		assert(qed.buf.current():text() == "", "empty text")
		local e = qed.buf.current():insert({row = 1, col = 1}, "x\n")
		assert(e.row == 2 and e.col == 1, "insert into empty buffer")
		local c = qed.buf.current():cursor()
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
		local rev = b:rev()
		assert(qed.edit(b, function()
			b:insert({row = 1, col = 1}, "1")
			b:insert({row = 1, col = 1}, "2")
			b:delete({row = 1, col = 3}, {row = 1, col = 4})
			qed.edit(b, function() b:insert({row = 1, col = 1}, "3") end)
		end, {rev = rev}) == true, "edit returns true")
		assert(b:line(1) == "321bc", "edits applied " .. b:line(1))
		local stale, why = qed.edit(b, function() error("must not run") end, {rev = rev})
		assert(stale == nil and why == "stale", "stale rev fails without running fn")
		local ok, err = pcall(qed.edit, b, function()
			b:insert({row = 1, col = 1}, "zzz")
			error("halfway")
		end)
		assert(not ok and err:find("halfway"), "error propagates")
		assert(b:line(1) == "321bc", "a failed edit rolls back")
		assert(qed.edit(b, function() end), "empty edit")
	`, "abc")
	defer api_test_destroy(ed)
	b := &ed.buffers[0]
	b.cursor = {0, 3}
	api_test_run(t, ed)
	testing.expect_value(t, len(b.undo), 1)
	testing.expect_value(t, len(b.redo), 0)
	testing.expect_value(t, ed.plugins.edit_depth, 0)
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
		local kept, why = qed.close(third)
		assert(kept == nil and why == "unsaved", "a modified buffer stays open")
		assert(qed.close(second) == true, "an unmodified buffer closes")
		assert(not second:valid(), "closed id is invalid")
		local ok, err = pcall(second.line, second, 1)
		assert(not ok and err:find("buffer closed"), "closed buffer raises: " .. tostring(err))
		assert(third:line(1) == "three", "ids survive reallocation")
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
		assert(b:selection() == nil, "no selection")
		b:set_selection({row = 2, col = 3}, {row = 1, col = 2})
		local from, to = b:selection()
		assert(from.row == 1 and from.col == 2 and to.row == 2 and to.col == 3, "selection is ordered")
		local c = b:cursor()
		assert(c.row == 1 and c.col == 2, "cursor is the moving end")
		b:insert({row = 1, col = 1}, ">>")
		from, to = b:selection()
		assert(from.col == 4 and to.col == 3, "marks follow an insert before them")
		b:set_cursor({row = 2, col = 4})
		assert(b:selection() == nil, "set_cursor clears the selection")
		assert(b:set_language("lua") == true, "set_language")
		assert(b:language() == "lua", "set_language")
		assert(b:set_language("lua") == true, "the same language succeeds")
		local ok, err = b:set_language("Klingon")
		assert(ok == nil and err:find("unknown language"), "unknown language fails softly")
		local langs = qed.languages()
		local has_lua = false
		for _, l in ipairs(langs) do has_lua = has_lua or l == "lua"; assert(l ~= "markdown_inline", "injection-only languages hidden") end
		assert(has_lua, "qed.languages lists lua")
		b:set_indent("spaces", 3)
		b:set_indent("tabs")
		local style, width = b:indent()
		assert(style == "tabs" and width == 3, "set_indent without width keeps the width")
		b:set_indent("auto")
		assert((b:indent()) == "spaces", "auto detects spaces on unindented text")
		b:set_indent("spaces", 2)
		assert(not pcall(b.set_indent, b, "both"), "bad indent style")
		local names = qed.theme.list()
		local has_default = false
		for _, n in ipairs(names) do has_default = has_default or n == "default" end
		assert(has_default, "theme.list includes the bundled default")
		assert(type(qed.theme.current()) == "string", "theme.current")
		ok, err = qed.theme.set("no-such-theme")
		assert(ok == nil and err:find("unknown theme"), "unknown theme fails softly")
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
		assert(b:path():sub(-6) == "/a.txt", "relative to the root")
		qed.jump(first, {row = 1, col = 1})
		assert(qed.buf.current() == first, "jump switches")
		qed.jump(b, {row = 30, col = 3})
		local c = b:cursor()
		assert(c.row == 30 and c.col == 3, "jump moves the cursor")
		qed.jump(b, {row = 99, col = 99})
		c = b:cursor()
		assert(c.row == 40 and c.col == 8, "jump clamps to the buffer")
		qed.jump(b, {row = 30, col = 3})
		b:insert({row = 1, col = 1}, "x")
		assert(b:modified(), "modified")
		qed.save(b)
		assert(not b:modified(), "saved")
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
		local h = qed.text.diff({"a", "b", "c", "d"}, {"a", "x", "c", "d", "e"})
		assert(#h == 2 and h[1].a == 2 and h[1].a_count == 1 and h[1].b == 2 and h[1].b_count == 1, "a changed row")
		assert(h[2].a == 5 and h[2].a_count == 0 and h[2].b == 5 and h[2].b_count == 1, "an appended row")
		assert(#qed.text.diff({}, {}) == 0 and qed.text.diff({}, {"a", "b"})[1].b_count == 2 and not pcall(qed.text.diff, {"a"}, {1}), "empty and non-string lists")
		local c = qed.config()
		assert(c.opt == 1 and c.nested.x == "z", "merged config")
		c.opt = 99
		assert(qed.config().opt == 1, "config copies are read-only")
		assert(qed.opt("tab_width") == TAB and qed.opt("line_wrap") ~= nil and type(qed.opt("theme")) == "string", "core knobs")
		assert(type(qed.opt("lsp.completion_max_rows")) == "number", "lsp knob")
		assert(not pcall(qed.opt, "nope") and not pcall(qed.opt, "modules.ai.chat_command") and not pcall(qed.opt, "modules.x.y") and not pcall(qed.opt, "modules.lsp.enabled") and not pcall(qed.opt, "lsp.nope"), "unknown knob")

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
		assert(qed.json.encode({1, x = 2}) == '{"1":1,"x":2}', "mixed tables encode as objects")
		assert(qed.json.encode({[1] = "a", [3] = "c"}) == '{"1":"a","3":"c"}', "sparse tables encode as objects")
		assert(not pcall(qed.json.encode, {[1.5] = 1}), "float keys rejected")
		local deep = {}
		for _ = 1, 32 do deep = {deep} end
		assert(qed.json.encode(deep):sub(1, 3) == "[[[", "deep nesting within the limit")
		local ok, derr = pcall(qed.json.encode, {deep, deep, {deep}})
		assert(not ok and derr:find("nested too deeply"), "nesting past the limit is an error")
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
	stub := Plugin{name = "stub"}
	plugin_qed_push(L, &stub)
	want := make([dynamic]string, context.temp_allocator)
	api_test_walk(L, "qed", &want)
	lua.pop(L, 1)
	testing.expect(t, len(want) > 50, "walked the qed table")
	testing.expect(t, strings.has_prefix(QED_STUB, "---@meta"), "stub is a meta file")
	for w in want {
		method_form, _ := strings.replace(w, "function qed.", "function qed:", 1, context.temp_allocator)
		testing.expectf(t, strings.contains(QED_STUB, w) || strings.contains(QED_STUB, method_form), "plugins/meta/qed.lua is missing `%s`", w)
	}
	have := strings.join(want[:], "\n", context.temp_allocator)
	for line in strings.split_lines(QED_STUB, context.temp_allocator) {
		if strings.has_prefix(line, "function qed.") {
			decl := line[:strings.index_byte(line, '(') + 1]
			testing.expectf(t, strings.contains(have, decl), "the stub declares `%s` but qed has no such function", decl)
		}
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
plugin_api_lsp_lua_scoped :: proc(t: ^testing.T) {
	cfg := config_dir(config_path())
	testing.expect_value(t, lsp_config_for_section("Lua", "/somewhere/else"), "null")
	testing.expect_value(t, lsp_lua_entry("/somewhere/else"), "")
	testing.expect_value(t, lsp_config_for_section("Lua", fmt.tprintf("%s-other", cfg)), "null")
	for root in ([?]string{cfg, fmt.tprintf("%s/plugins", cfg)}) {
		v, err := json.parse_string(lsp_config_for_section("Lua", root), allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "Lua settings for %s are valid JSON", root)
		obj := v.(json.Object)
		testing.expect_value(t, string(obj["runtime"].(json.Object)["version"].(json.String)), "Lua 5.4")
		testing.expect_value(t, string(obj["workspace"].(json.Object)["library"].(json.Array)[0].(json.String)), plugin_stub_dir())
		testing.expect(t, strings.has_prefix(lsp_lua_entry(root), `,"Lua":{`), "the push includes Lua under the config dir")
	}
	repo, rerr := os.read_entire_file("../.luarc.json", context.temp_allocator)
	if rerr != nil {
		repo, rerr = os.read_entire_file(".luarc.json", context.temp_allocator)
	}
	testing.expect(t, rerr == nil && strings.contains(string(repo), `"plugins/meta"`), "the repo .luarc.json points at the stub")
}

@(test)
plugin_api_edit_rollback_selection :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local b = qed.buf.current()
		b:set_selection({row = 1, col = 6}, {row = 1, col = 4})
		local ok = pcall(qed.edit, b, function()
			b:insert({row = 1, col = 1}, "xxxx\nyyyy\n")
			b:delete({row = 3, col = 1}, {row = 3, col = 3})
			error("boom")
		end)
		assert(not ok, "edit failed")
		local from, to = b:selection()
		assert(from.row == 1 and from.col == 4 and to.col == 6, "selection restored after rollback")
	`, "abcdef")
	defer api_test_destroy(ed)
	api_test_run(t, ed)
	b := &ed.buffers[0]
	testing.expect_value(t, api_test_text(b), "abcdef")
	testing.expect_value(t, b.selection, Maybe(Cursor)(Cursor{0, 5}))
	testing.expect_value(t, b.cursor, Cursor{0, 3})
	testing.expect_value(t, len(b.undo), 0)
}

@(test)
plugin_api_edit_one_step :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/qed_api_step_%d.lua", tmp, posix.getpid())
	_ = os.write_entire_file(path, transmute([]u8)string("a\nb"))
	defer os.remove(path)
	ed := api_test_editor(`
		local b = qed.buf.current()
		local other = qed.buf.list()[2]
		qed.edit(b, function()
			b:insert({row = 1, col = 1}, "1")
			assert(qed.save(b) == true, "save inside an edit")
			b:insert({row = 1, col = 1}, "2")
			qed.run("Toggle Comment")
			local ok = pcall(qed.edit, b, function()
				b:insert({row = 2, col = 1}, "lost")
				error("inner")
			end)
			assert(not ok, "inner failed")
			qed.edit(other, function()
				other:insert({row = 1, col = 1}, "o")
				b:insert({row = 2, col = 1}, "3")
			end)
		end)
		assert(b:lines()[2] == "3b", "the failed nested edit inverted only its own part: " .. b:lines()[2])
		local ok = pcall(qed.edit, b, function()
			b:insert({row = 1, col = 1}, "x")
			qed.save(b)
			qed.run("Toggle Comment")
			error("outer")
		end)
		assert(not ok and b:line(1) == "-- 21a", "a failed edit rolls back across saves and builtin edits: " .. b:line(1))
	`, "x")
	defer api_test_destroy(ed)
	other := test_buffer("other")
	append(&ed.buffers, other)
	buffer_destroy(&ed.buffers[0])
	ed.buffers[0] = buffer_new()
	buffer_open(&ed.buffers[0], path)
	api_test_run(t, ed)
	b := &ed.buffers[0]
	testing.expect_value(t, len(b.undo), 1)
	testing.expect_value(t, len(ed.buffers[1].undo), 1)
	editor_undo(ed)
	testing.expect_value(t, api_test_text(b), "a\nb")
	testing.expect(t, b.modified, "undo past the save point is modified")
}

@(test)
plugin_api_save_conflict :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/qed_api_conflict_%d.txt", tmp, posix.getpid())
	_ = os.write_entire_file(path, transmute([]u8)string("disk"))
	defer os.remove(path)
	ed := api_test_editor(`
		local other = qed.buf.list()[2]
		local ok, err = qed.save(other)
		assert(ok == nil and err == "changed on disk", "a conflicting background save fails: " .. tostring(err))
		local ok2, err2 = qed.save(qed.buf.current())
		assert(ok2 == nil and err2 == "no file name", "unnamed buffer")
	`, "x")
	defer api_test_destroy(ed)
	b := buffer_new()
	buffer_open(&b, path)
	b.disk.mtime -= 1000
	append(&ed.buffers, b)
	api_test_run(t, ed)
	testing.expect(t, pane_find(ed, "conflict") == nil, "no dialog for a non-current buffer")
}

@(test)
plugin_api_edit_error_traceback :: proc(t: ^testing.T) {
	ed := api_test_editor(`qed.edit(qed.buf.current(), function() error("inside edit") end)`, "x")
	defer api_test_destroy(ed)
	cmd, _ := plugin_test_command(ed, "T: Run")
	command_run(ed, cmd)
	pl := plugin_find(&ed.plugins, "t")
	testing.expect(t, strings.contains(pl.last_error, "inside edit"), "the error reaches the command")
	testing.expect(t, !strings.contains(pl.last_error, "traceback"), "the message carries no traceback")
	logged := false
	for e in ed.log {
		if e.level == .Debug && e.source == "T" {
			logged = true
			testing.expect_value(t, strings.count(e.text, "stack traceback:"), 1)
		}
	}
	testing.expect(t, logged, "the traceback is logged")
}

@(test)
plugin_api_message_source :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		qed.message("plain")
		assert(not pcall(qed.message, "x", {level = "warn"}), "the table form is gone")
		assert(not pcall(qed.message, "x", "loud"), "bad level")
		assert(not pcall(qed.log, "x", "loud"), "bad log level")
		qed.log("logged", "debug")
		qed.message("warned", "warn")
	`, "abc")
	defer api_test_destroy(ed)
	api_test_run(t, ed)
	testing.expect_value(t, ed.message, "warned")
	testing.expect_value(t, ed.message_source, "T")
	testing.expect_value(t, ed.message_level, LogLevel.Warn)
	found, logged := false, false
	for e in ed.log {
		found ||= e.text == "plain" && e.source == "T" && e.level == .Info
		logged ||= e.text == "logged" && e.level == .Debug
	}
	testing.expect(t, found, "messages are attributed to the plugin's display name")
	testing.expect(t, logged, "qed.log takes the level last")
}

@(test)
plugin_api_return_conventions :: proc(t: ^testing.T) {
	ed := api_test_editor(`
		local b = qed.buf.current()
		local ids = qed.buf.list()
		local spare, dirty = ids[2], ids[3]
		local ns = qed.deco.ns("t")
		local rev = b:rev()
		local v = assert(qed.ui.open{list = {items = {"a"}}})
		v:close()
		local cases = {
			{"close unsaved", "unsaved", function() return qed.close(dirty) end},
			{"close", true, function() return qed.close(spare) end},
			{"set_text stale", "stale", function() return b:set_text("x", {rev = rev + 1}) end},
			{"set_text", true, function() return b:set_text("abc") end},
			{"edit stale", "stale", function() return qed.edit(b, function() end, {rev = -1}) end},
			{"edit", true, function() return qed.edit(b, function() end) end},
			{"set_language unknown", "unknown language", function() return b:set_language("Klingon") end},
			{"set_language", true, function() return b:set_language("lua") end},
			{"new_buf unknown language", "unknown language", function() return qed.new_buf{language = "Klingon"} end},
			{"theme.set unknown", "unknown theme", function() return qed.theme.set("no-such-theme") end},
			{"save unnamed", "no file name", function() return qed.save(b) end},
			{"jump", true, function() return qed.jump(b, {row = 1, col = 1}) end},
			{"spawn missing", "cannot start", function() return qed.spawn{argv = {"/no/such/qed-prog"}} end},
			{"spawn_bg missing", "cannot start", function() return qed.spawn_bg{argv = {"/no/such/qed-prog"}} end},
			{"set_screen_row not current", "not current", function() return dirty:set_screen_row(1, 1) end},
			{"inline off cursor", "not at cursor", function() return qed.deco.inline(b, ns, {row = 1, col = 3}, "x") end},
			{"inline", true, function() return qed.deco.inline(b, ns, b:cursor(), "x") end},
			{"view closed set", "closed", function() return v:set({"b"}) end},
			{"view closed text", "closed", function() return v:text({"b"}) end},
			{"view closed select", "closed", function() return v:select(1) end},
			{"view closed scroll", "closed", function() return v:scroll(1) end},
			{"close bad arg", "raise", function() return qed.close("x") end},
			{"closed buffer", "raise", function() return spare:line(1) end},
			{"run unknown", "raise", function() return qed.run("No Such Command") end},
			{"spawn bad spec", "raise", function() return qed.spawn{} end},
			{"confirm positional", "raise", function() return qed.confirm("Sure?") end},
			{"pick query handler", "raise", function() return qed.pick{items = {}, on = {query = function() end}} end},
			{"pick bad selected", "raise", function() return qed.pick{items = {}, selected = {}} end},
			{"pick old initial", "raise", function() return qed.pick{items = {}, initial = 1} end},
			{"pick old multi", "raise", function() return qed.pick{items = {}, multi = true} end},
			{"prompt unknown field", "raise", function() return qed.prompt{prompt = "x", query = "y"} end},
			{"confirm unknown field", "raise", function() return qed.confirm{question = "x", text = "y"} end},
			{"set_base", true, function() return b:set_base("abc") end},
			{"set_base clear", true, function() return b:set_base(nil) end},
		}
		local bad = {}
		for _, c in ipairs(cases) do
			local name, want, fn = c[1], c[2], c[3]
			local ok, r, err = pcall(fn)
			local good
			if want == "raise" then
				good = not ok
			elseif want == true then
				good = ok and r == true and err == nil
			else
				good = ok and r == nil and type(err) == "string" and err:find(want, 1, true) ~= nil
			end
			if not good then
				bad[#bad + 1] = ("%s: %s %s %s"):format(name, tostring(ok), tostring(r), tostring(err))
			end
		end
		assert(#bad == 0, table.concat(bad, "; "))
		assert(qed.shortcut == nil and qed.pane == nil, "dead sugar is gone")
		local ok, err = pcall(qed.pick, {items = {}, on_change = print})
		assert(not ok and tostring(err):find("qed.pick: unknown field 'on_change'", 1, true), "the error names the field: " .. tostring(err))
		for _, c in ipairs({
			{"opts.alpha must be", function() qed.deco.tint(b, ns, 1, 1, {color = "git_added", alpha = 2}) end},
			{"opts.alpha: unknown theme tint", function() qed.deco.tint(b, ns, 1, 1, {color = "git_added", alpha = "nope"}) end},
			{"opts.color must be", function() qed.deco.eol(b, ns, 1, "x", {}) end},
			{"opts.color must be", function() qed.deco.ghost(b, ns, 1, "x", {color = 1}) end},
			{"style.alpha must be", function() qed.deco.span(b, ns, {row = 1, col = 1}, {row = 1, col = 2}, {bg = "git_added", alpha = 2}) end},
		}) do
			local ok, err = pcall(c[2])
			assert(not ok and tostring(err):find(c[1], 1, true), "deco error reads: " .. tostring(err))
		end
	`, "abc")
	defer api_test_destroy(ed)
	defer delete(ed.panes)
	append(&ed.buffers, test_buffer("two"))
	append(&ed.buffers, test_buffer("three"))
	ed.buffers[2].modified = true
	api_test_run(t, ed)
}

@(test)
plugin_api_run_respects_when :: proc(t: ^testing.T) {
	ed := new(Editor)
	ed.headless = true
	ed.working_root = strings.clone("/tmp")
	append(&ed.buffers, test_buffer("x"))
	editor_plugins_start(ed, {{"t.lua", `return {setup = function()
	qed.command{name = "Gated", when = function() return false end, run = function() qed.message("gated ran") end}
	qed.command{name = "Open", when = function() return true end, run = function() end}
	qed.command{name = "Run", run = function()
		local ok, err = qed.run("Gated")
		assert(ok == nil and err == "unavailable", "a false when refuses: " .. tostring(ok) .. " " .. tostring(err))
		assert(qed.run("Open") == true, "a true when runs")
	end}
end}`}}, "", PLUGIN_TEST_MEM)
	defer api_test_destroy(ed)
	api_test_run(t, ed)
	testing.expect(t, ed.message != "gated ran", "the gated command did not run")
}
