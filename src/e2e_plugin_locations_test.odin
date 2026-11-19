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
local function show(loc, err)
	qed.message(loc and ("%s|%d|%d|%s"):format(loc.label, loc.pos.row, loc.pos.col, qed.path.base(loc.path)) or tostring(err))
end
local function cmd(name, text, opts, scope)
	qed.command{name = name, scope = scope, run = function() show(qed.locations(text, opts)) end}
end
return {setup = function()
	cmd("Loc: Grep", "a.txt:2:needle here\nb.txt:3:needle\nmissing.txt:3: gone\n", {prompt = "Grep >"})
	cmd("Loc: Cols", "c.txt:2:3: in a char\r\nc.txt:9:99: past the end\r\n")
	cmd("Loc: Sub", "x.txt:1\n" .. qed.path.join(qed.root(), "a.txt") .. ":1: abs\n", {cwd = "sub"})
	cmd("Loc: Bare", "c.txt:2:3\nc.txt:1\n12:30 meeting\n")
	cmd("Loc: Empty", "")
	cmd("Loc: Missing", "nope.txt:1: gone\n12:30 meeting\n")
	cmd("Loc: Tree", "a.txt:2: needle\n", nil, "filetree")
	qed.command{name = "Loc: Prompt", run = function() qed.prompt{prompt = "P:"} end}
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

@(private = "file")
loc_selected :: proc(e: ^E2E) -> string {
	ui := &e.ed.plugins.ui
	return ui.labels[ui.matches[ui.selected]]
}

@(test)
e2e_plugin_locations_jump :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	e2e_resize(&e, 160, 40)
	loc_run(t, &e, "Loc: Grep")
	ui := &e.ed.plugins.ui
	testing.expect(t, ui.active && ui.paths, "a list + preview picker opens")
	testing.expect_value(t, len(ui.matches), 2)
	testing.expect_value(t, loc_selected(&e), "a.txt:2: needle here")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Grep >"), "the prompt renders")
	testing.expect(t, e2e_grid_has(&e, "three"), "the preview shows the file")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, !ui.active, "Enter closes")
	b := editor_buffer(&e.ed)
	testing.expect_value(t, filepath.base(b.path), "b.txt")
	testing.expect_value(t, b.cursor, Cursor{2, 0})
	testing.expect_value(t, e.ed.message, "b.txt:3: needle|3|1|b.txt")
	testing.expect_value(t, ui.items_ref, 0)
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)

	loc_run(t, &e, "Loc: Grep")
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "nil")
	testing.expect_value(t, filepath.base(editor_buffer(&e.ed).path), "b.txt")
}

@(test)
e2e_plugin_locations_columns :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	loc_run(t, &e, "Loc: Cols")
	testing.expect_value(t, loc_selected(&e), "c.txt:2:3: in a char")
	e2e_key(&e, .Enter)
	b := editor_buffer(&e.ed)
	testing.expect_value(t, filepath.base(b.path), "c.txt")
	testing.expect_value(t, b.cursor, Cursor{1, 1})
	testing.expect_value(t, e.ed.message, "c.txt:2:3: in a char|2|3|c.txt")
	loc_run(t, &e, "Loc: Cols")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, editor_buffer(&e.ed).cursor, Cursor{2, 0})
	testing.expect_value(t, e.ed.message, "c.txt:9:99: past the end|9|99|c.txt")

	loc_run(t, &e, "Loc: Bare")
	testing.expect_value(t, len(e.ed.plugins.ui.matches), 2)
	testing.expect_value(t, loc_selected(&e), "c.txt:2:3")
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, loc_selected(&e), "c.txt:1")
	e2e_key(&e, .Esc)
}

@(test)
e2e_plugin_locations_cwd :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	loc_run(t, &e, "Loc: Sub")
	testing.expect_value(t, len(e.ed.plugins.ui.matches), 2)
	testing.expect_value(t, loc_selected(&e), "sub/x.txt:1")
	e2e_key(&e, .Enter)
	testing.expect_value(t, editor_buffer(&e.ed).path, fmt.tprintf("%s/sub/x.txt", e.dir))
	loc_run(t, &e, "Loc: Sub")
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, loc_selected(&e), "a.txt:1: abs")
	e2e_key(&e, .Esc)
}

@(test)
e2e_plugin_locations_empty_busy :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	loc_run(t, &e, "Loc: Empty")
	testing.expect(t, !e.ed.plugins.ui.active, "no picker without locations")
	testing.expect_value(t, e.ed.message, "no locations")
	loc_run(t, &e, "Loc: Missing")
	testing.expect_value(t, e.ed.message, "no locations")
	loc_run(t, &e, "Loc: Prompt")
	loc_run(t, &e, "Loc: Grep")
	testing.expect_value(t, e.ed.message, "busy")
	testing.expect_value(t, e.ed.plugins.ui.kind, PluginUiKind.Prompt)
	e2e_key(&e, .Esc)
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
}

@(test)
e2e_plugin_locations_filetree :: proc(t: ^testing.T) {
	e := loc_start(t)
	defer e2e_stop(&e)
	filetree_open_all(&e.ed)
	loc_run(t, &e, "Loc: Tree")
	testing.expect(t, e.ed.plugins.ui.active, "a picker opens over the tree")
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.filetree.active, "the jump closes the tree")
	b := editor_buffer(&e.ed)
	testing.expect_value(t, filepath.base(b.path), "a.txt")
	testing.expect_value(t, b.cursor, Cursor{1, 0})
}
