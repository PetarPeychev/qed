package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
location_parse_forms :: proc(t: ^testing.T) {
	Case :: struct {
		line, file, row, col, msg: string,
		ok:                        bool,
	}
	cases := [?]Case {
		{"a.txt:2:3: in a char", "a.txt", "2", "3", "in a char", true},
		{"a.txt:2:3", "a.txt", "2", "3", "", true},
		{"a.txt:2: needle here", "a.txt", "2", "", "needle here", true},
		{"a.txt:2:needle", "a.txt", "2", "", "needle", true},
		{"a.txt:2", "a.txt", "2", "", "", true},
		{"a.txt:2:1: error: bad", "a.txt", "2", "1", "error: bad", true},
		{"src/x.c:10:\t  spaced", "src/x.c", "10", "", "spaced", true},
		{"a:b.txt:4: m", "a:b.txt", "4", "", "m", true},
		{"a.txt:2:3 x:4: m", "a.txt", "2", "", "3 x:4: m", true},
		{"12:30 meeting", "", "", "", "", false},
		{":12:3: empty file", "", "", "", "", false},
		{"no location here", "", "", "", "", false},
		{"a.txt:", "", "", "", "", false},
	}
	for c in cases {
		file, row, col, msg, ok := location_parse(c.line)
		testing.expectf(t, ok == c.ok && file == c.file && row == c.row && col == c.col && msg == c.msg, "%q: got %q %q %q %q %v", c.line, file, row, col, msg, ok)
	}
}

@(private = "file")
LOC_PLUGIN :: `
local function dump(items)
	local parts = {}
	for _, it in ipairs(items) do
		parts[#parts + 1] = ("%s|%d|%d|%s"):format(it.label, it.pos.row, it.pos.col, qed.path.rel(it.path))
	end
	return table.concat(parts, ";")
end
local function grep(name, text, scope)
	qed.command{name = name, scope = scope, run = function()
		local items = qed.parse_locations(text)
		local it = qed.pick{items = items, prompt = "Grep >"}
		if it then qed.jump(it.path, it.pos) end
		qed.message(it and it.label or "nil")
	end}
end
return {setup = function()
	local parsed = dump(qed.parse_locations("a.txt:2:needle here\r\nb.txt:3:needle\nmissing.txt:3: gone\n"))
	qed.command{name = "Setup", run = function() qed.message(parsed) end}
	qed.command{name = "Parse", run = function()
		qed.message(dump(qed.parse_locations("x.txt:1\n" .. qed.path.join(qed.root(), "a.txt") .. ":1:2: abs\n12:30 meeting\n", {cwd = "sub"})))
	end}
	qed.command{name = "Empty", run = function()
		qed.message(#qed.parse_locations("") .. " " .. #qed.parse_locations("nope.txt:1: gone\n12:30 meeting\n"))
	end}
	qed.command{name = "Bad", run = function()
		local ok, err = qed.jump("sub", {row = 1, col = 1})
		qed.message(tostring(ok) .. " " .. tostring(err))
	end}
	grep("Grep", "a.txt:2:needle here\nb.txt:3:needle\nmissing.txt:3: gone\n")
	grep("Cols", "c.txt:2:3: in a char\nc.txt:9:99: past the end\n")
	grep("Tree", "a.txt:2: needle\n", "filetree")
end}`

@(private = "file")
loc_start :: proc(t: ^testing.T) -> E2E {
	e := e2e_start("abc")
	tmp, _ := os.temp_dir(context.temp_allocator)
	e.dir = fmt.aprintf("%s/qed_e2e_loc_%d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(e.dir)
	os.make_directory(fmt.tprintf("%s/sub", e.dir))
	files := [?][2]string{{"a.txt", "one\nneedle here\nthree"}, {"b.txt", "x\ny\nneedle\n"}, {"c.txt", "abc\ndéf ghi\n"}, {"sub/x.txt", "in sub\n"}}
	for f in files {
		_ = os.write_entire_file(fmt.tprintf("%s/%s", e.dir, f[0]), transmute([]u8)f[1])
	}
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)
	pl := e2e_plugin(&e, "loc", LOC_PLUGIN)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	return e
}

@(private = "file")
loc_run :: proc(t: ^testing.T, e: ^E2E, name: string, loc := #caller_location) {
	for c in e.ed.plugins.commands {
		if c.name == name {
			plugin_command_run(&e.ed, c)
			return
		}
	}
	testing.expectf(t, false, "%s registered", name, loc = loc)
}


@(test)
e2e_plugin_parse_locations :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	loc_run(t, &e, "Loc: Setup")
	testing.expect_value(t, e.ed.message, "a.txt:2: needle here|2|1|a.txt;b.txt:3: needle|3|1|b.txt")
	loc_run(t, &e, "Loc: Parse")
	testing.expect_value(t, e.ed.message, "sub/x.txt:1|1|1|sub/x.txt;a.txt:1:2: abs|1|2|a.txt")
	loc_run(t, &e, "Loc: Empty")
	testing.expect_value(t, e.ed.message, "0 0")
}

@(test)
e2e_plugin_locations_pick_jump :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	e2e_resize(&e, 160, 40)
	loc_run(t, &e, "Loc: Grep")
	v := test_view(&e.ed)
	testing.expect(t, v != nil && v.place == .Split, "parsed items get the list + preview picker")
	testing.expect_value(t, pane_count(v), 2)
	testing.expect_value(t, test_view_selected(&e.ed), "a.txt:2: needle here")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "three"), "the preview shows the file")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, test_view(&e.ed) == nil, "Enter closes")
	b := editor_buffer(&e.ed)
	testing.expect_value(t, filepath.base(b.path), "b.txt")
	testing.expect_value(t, b.cursor, Cursor{2, 0})
	testing.expect_value(t, e.ed.message, "b.txt:3: needle")
	jl := &e.ed.jumps
	if testing.expect(t, jl.index >= 1, "the jump is recorded") {
		testing.expect_value(t, jl.entries[jl.index - 1].path, e.path)
	}

	loc_run(t, &e, "Loc: Grep")
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "nil")

	loc_run(t, &e, "Loc: Bad")
	testing.expect_value(t, e.ed.message, fmt.tprintf("nil cannot open %s/sub", e.dir))
	testing.expect_value(t, filepath.base(editor_buffer(&e.ed).path), "b.txt")
}

@(test)
e2e_plugin_locations_jump_clamps :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	loc_run(t, &e, "Loc: Cols")
	e2e_key(&e, .Enter)
	b := editor_buffer(&e.ed)
	testing.expect_value(t, filepath.base(b.path), "c.txt")
	testing.expect_value(t, b.cursor, Cursor{1, 1})
	loc_run(t, &e, "Loc: Cols")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, editor_buffer(&e.ed).cursor, Cursor{2, 0})
	testing.expect_value(t, e.ed.message, "c.txt:9:99: past the end")
}

@(test)
e2e_plugin_locations_filetree :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	filetree_open_all(&e.ed)
	loc_run(t, &e, "Loc: Tree")
	testing.expect(t, test_view(&e.ed) != nil, "a picker opens over the tree")
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.filetree.active, "the jump closes the tree")
	b := editor_buffer(&e.ed)
	testing.expect_value(t, filepath.base(b.path), "a.txt")
	testing.expect_value(t, b.cursor, Cursor{1, 0})
}
