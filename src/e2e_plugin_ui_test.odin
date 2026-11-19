package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:path/filepath"

@(private = "file")
UI_PLUGIN :: `
local pane
local function show(v)
	if type(v) == "table" then
		local parts = {}
		for _, x in ipairs(v) do parts[#parts + 1] = type(x) == "table" and x.label or x end
		v = table.concat(parts, ",")
	end
	qed.message(tostring(v))
end
local function cmd(name, run) qed.command{name = name, run = run} end
return {setup = function()
	cmd("UI: Strings", function()
		local r, err = qed.pick{items = {"alpha", "beta", "gamma"}, initial = 2}
		show(r or err)
	end)
	cmd("UI: Tables", function()
		local r = qed.pick{items = {{label = "one", detail = "D1", value = 7}, {label = "two", detail = "D2", value = 8}}, initial = "two"}
		show(r and r.value)
	end)
	cmd("UI: Change", function()
		local r = qed.pick{items = {"a", "b", "c"}, on_change = function(item) qed.log("info", "chg " .. item) end}
		show(r)
	end)
	cmd("UI: Multi", function()
		show(qed.pick{items = {"a", "b", "c", "d"}, multi = true})
	end)
	cmd("UI: Paths", function()
		local dir = qed.path.dir(qed.buf.path())
		local r = qed.pick{items = {{path = qed.path.join(dir, "p1.txt"), pos = {row = 2, col = 1}}, {label = "second", path = qed.path.join(dir, "p2.txt")}}}
		show(r and r.label)
	end)
	cmd("UI: Prompt", function()
		show(qed.prompt{prompt = "Name:", text = "x"})
	end)
	cmd("UI: Confirm", function()
		show(qed.confirm("Sure?", {"A", "B", "C"}))
	end)
	cmd("UI: Confirm Default", function()
		show(qed.confirm("Ok?"))
	end)
	cmd("UI: Pane", function()
		pane = qed.pane{title = "Pane Title", lines = {"line one", {text = "line two", color = "error_foreground"}}, footer = "my footer"}
	end)
	cmd("UI: Pane Set", function() show(pane:set({"line three"})) end)
	cmd("UI: Pane Close", function() pane:close() end)
end}`

@(private = "file")
ui_run :: proc(t: ^testing.T, e: ^E2E, name: string, loc := #caller_location) {
	cmd, ok := plugin_test_command(&e.ed, name)
	testing.expectf(t, ok, "%s registered", name, loc = loc)
	command_run(&e.ed, cmd)
}

@(private = "file")
ui_selected :: proc(e: ^E2E) -> string {
	ui := &e.ed.plugins.ui
	return ui.labels[ui.matches[ui.selected]]
}

@(private = "file")
ui_start :: proc(t: ^testing.T) -> (E2E, ^Plugin) {
	e := e2e_start("abc")
	pl := e2e_plugin(&e, "ui", UI_PLUGIN)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	return e, pl
}

@(test)
e2e_plugin_ui_pick_strings :: proc(t: ^testing.T) {
	e, pl := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Strings")
	ui := &e.ed.plugins.ui
	testing.expect(t, ui.active, "qed.pick opens the overlay")
	testing.expect_value(t, ui_selected(&e), "beta")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "gamma"), "items are listed")
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, ui_selected(&e), "gamma")
	e2e_key(&e, .Enter)
	testing.expect(t, !ui.active, "Enter closes")
	testing.expect_value(t, e.ed.message, "gamma")
	testing.expect_value(t, e.ed.message_source, "ui")
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
	testing.expect_value(t, pl.last_error, "")

	ui_run(t, &e, "UI: Strings")
	e2e_type(&e, "alp")
	testing.expect_value(t, ui_selected(&e), "alpha")
	e2e_key(&e, .Esc)
	testing.expect(t, !ui.active, "Esc closes")
	testing.expect_value(t, e.ed.message, "nil")
	testing.expect_value(t, ui.items_ref, 0)
}

@(test)
e2e_plugin_ui_pick_tables :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Tables")
	testing.expect_value(t, ui_selected(&e), "two")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "D1"), "details render")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "8")
}

@(test)
e2e_plugin_ui_pick_on_change :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Change")
	count := proc(e: ^E2E, text: string) -> int {
		n := 0
		for l in e.ed.log {
			if l.source == "ui" && l.text == text {
				n += 1
			}
		}
		return n
	}
	testing.expect_value(t, count(&e, "chg a"), 0)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, count(&e, "chg b"), 1)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, count(&e, "chg c"), 1)
	e2e_type(&e, "a")
	testing.expect_value(t, count(&e, "chg a"), 1)
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "nil")
}

@(test)
e2e_plugin_ui_pick_multi :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Multi")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down, .Shift)
	e2e_key(&e, .Arrow_Down, .Shift)
	e2e_render(&e)
	box := pane_center(&e.ed, PALETTE_WIDTH, 2 + 4)
	testing.expect_value(t, e2e_cell_bg(&e, box.x + 2, box.y + 4), COLOR_PANE_SEL_BG)
	testing.expect_value(t, e2e_cell_bg(&e, box.x + 2, box.y + 3), COLOR_PANE_BG)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "b,c,d")

	ui_run(t, &e, "UI: Multi")
	e2e_key(&e, .Arrow_Down, .Shift)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "c")
}

@(test)
e2e_plugin_ui_pick_paths :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	dir := filepath.dir(e.ed.buffers[0].path)
	p1 := fmt.tprintf("%s/p1.txt", dir)
	p2 := fmt.tprintf("%s/p2.txt", dir)
	_ = os.write_entire_file(p1, transmute([]u8)string("first file\nfocus here\n"))
	_ = os.write_entire_file(p2, transmute([]u8)string("second body\n"))
	defer os.remove(p1)
	defer os.remove(p2)
	e2e_resize(&e, 160, 40)
	ui_run(t, &e, "UI: Paths")
	ui := &e.ed.plugins.ui
	testing.expect(t, ui.paths, "path items use the list + preview layout")
	testing.expect(t, preview_loaded(&ui.preview), "the preview loads")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "focus here"), "the preview shows the file")
	e2e_key(&e, .Arrow_Down)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "second body"), "moving reloads the preview")
	testing.expect(t, e2e_grid_has(&e, "second"), "labels render")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "second")
}

@(test)
e2e_plugin_ui_prompt :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Prompt")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Name: x"), "the prompt renders with its text")
	e2e_type(&e, "yz")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "xyz")
	ui_run(t, &e, "UI: Prompt")
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "nil")
}

@(test)
e2e_plugin_ui_confirm :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Confirm")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Sure?"), "the question renders")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "2")
	ui_run(t, &e, "UI: Confirm Default")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Yes") && e2e_grid_has(&e, "No"), "default choices")
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "nil")
}

@(test)
e2e_plugin_ui_pane :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Pane")
	testing.expect(t, e.ed.plugins.pane.active, "qed.pane opens")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Pane Title"), "title")
	testing.expect(t, e2e_grid_has(&e, "line two"), "lines")
	testing.expect(t, e2e_grid_has(&e, "my footer"), "footer")
	ui_run(t, &e, "UI: Pane Set")
	testing.expect_value(t, e.ed.message, "true")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "line three"), "pane:set replaces the lines")
	testing.expect(t, !e2e_grid_has(&e, "line one"), "old lines are gone")
	ui_run(t, &e, "UI: Pane Close")
	testing.expect(t, !e.ed.plugins.pane.active, "pane:close closes")
	ui_run(t, &e, "UI: Pane Set")
	testing.expect_value(t, e.ed.message, "false")

	ui_run(t, &e, "UI: Pane")
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.plugins.pane.active, "Esc closes the pane")
}

@(test)
e2e_plugin_ui_busy :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Prompt")
	ui_run(t, &e, "UI: Strings")
	testing.expect_value(t, e.ed.message, "busy")
	testing.expect_value(t, e.ed.plugins.ui.kind, PluginUiKind.Prompt)
	ui_run(t, &e, "UI: Pane")
	testing.expect(t, !e.ed.plugins.pane.active, "a pane is refused while a modal is open")
	e2e_key(&e, .Esc)
	e2e_key(&e, .Ctrl_P)
	ui_run(t, &e, "UI: Strings")
	testing.expect_value(t, e.ed.message, "busy")
}

@(test)
e2e_plugin_ui_unload_closes :: proc(t: ^testing.T) {
	e, pl := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Change")
	testing.expect_value(t, len(e.ed.plugins.tasks), 1)
	plugin_unload(&e.ed, pl)
	ui := &e.ed.plugins.ui
	testing.expect(t, !ui.active, "unloading the owner closes the modal")
	testing.expect_value(t, ui.id, 0)
	testing.expect_value(t, ui.change_ref, 0)
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
	e2e_key(&e, .Esc)
}

@(test)
e2e_plugin_ui_mouse :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Change")
	box := pane_center(&e.ed, PALETTE_WIDTH, 2 + 3)
	e2e_mouse(&e, box.x + 3, box.y + 4)
	testing.expect_value(t, ui_selected(&e), "b")
	has_chg := false
	for l in e.ed.log {
		has_chg ||= l.text == "chg b"
	}
	testing.expect(t, has_chg, "a click fires on_change")
	e2e_mouse(&e, box.x + 3, box.y + 4)
	testing.expect(t, !e.ed.plugins.ui.active, "a double click activates")
	testing.expect_value(t, e.ed.message, "b")

	ui_run(t, &e, "UI: Strings")
	e2e_mouse(&e, 0, 0)
	testing.expect(t, !e.ed.plugins.ui.active, "a click outside dismisses")
	testing.expect_value(t, e.ed.message, "nil")
}

@(test)
e2e_plugin_ui_wait_refused_in_setup :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	pl := e2e_plugin(&e, "eager", `return {setup = function() qed.pick{items = {"a"}} end}`)
	testing.expect_value(t, pl.state, PluginState.Errored)
	testing.expect(t, !e.ed.plugins.ui.active, "no overlay opens")
}
