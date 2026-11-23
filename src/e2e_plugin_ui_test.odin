package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:path/filepath"
import "core:sys/posix"
import "core:time"

@(private = "file")
UI_PLUGIN :: `
local pane, last
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
	qed.meta{display_name = "UI"}
	cmd("Strings", function()
		local r, err = qed.pick{items = {"alpha", "beta", "gamma"}, selected = 2}
		show(r or err)
	end)
	cmd("Tables", function()
		local r = qed.pick{items = {{label = "one", detail = "D1", value = 7}, {label = "two", detail = "D2", value = 8}}, selected = "two"}
		show(r and r.value)
	end)
	cmd("Change", function()
		local r = qed.pick{items = {"a", "b", "c"}, on = {change = function(_, item) qed.log("chg " .. item) end}}
		show(r)
	end)
	cmd("Multi", function()
		local v = qed.ui.open{kind = "child", modal = true, fields = {{}}, list = {items = {"a", "b", "c", "d"}, multi = true}}
		local items = v:wait()
		v:close()
		show(items)
	end)
	cmd("Paths", function()
		local dir = qed.path.dir(qed.buf.current():path())
		local r = qed.pick{items = {{path = qed.path.join(dir, "p1.txt"), pos = {row = 2, col = 1}}, {label = "second", detail = "DET2", path = qed.path.join(dir, "p2.txt")}}}
		show(r and r.label)
	end)
	cmd("Prompt", function()
		show(qed.prompt{prompt = "Name:", text = "x"})
	end)
	cmd("Confirm", function()
		show(qed.confirm{question = "Sure?", choices = {"A", "B", "C"}})
	end)
	cmd("Confirm Default", function()
		show(qed.confirm{question = "Ok?"})
	end)
	cmd("Pane", function()
		pane = qed.ui.open{place = "full", title = "Pane Title", text = {"line one", {text = "line two", color = "error_foreground"}}, footer = {hints = {{label = "my footer"}}}}
	end)
	cmd("Pane Set", function()
		local ok, err = pane:text({"line three"})
		show(ok or err)
	end)
	cmd("Pane Close", function() pane:close() end)
	cmd("Chain", function()
		local a = qed.pick{items = {"x", "y"}}
		local b = qed.pick{items = {"p", "q"}}
		show(tostring(a) .. tostring(b))
	end)
	cmd("Persist", function()
		local ok, err = qed.theme.set(qed.opt("theme"), {persist = true})
		show(tostring(ok) .. " " .. tostring(err))
	end)
	qed.command{name = "Query", key = "Alt+q", run = function()
		local v, err = qed.ui.open{kind = "child", modal = true, place = "split", preview = "auto", list = {},
			fields = {{text = "ab", mode = "query", count = true}},
			on = {change = function(_, it) qed.log("chg " .. it.label) end, query = function(picker, q)
			qed.log("query " .. q)
			last = picker
			if q == "slow" then
				qed.spawn{cmd = "sleep 5"}
				qed.log("slow done")
			end
			if q == "" then
				picker:set({}, {hint = "type something"})
				return
			end
			picker:set({{label = q .. "1"}, {label = q .. "2"}, {label = q .. "3"}}, {selected = 2, more = q == "more"})
		end}}
		if not v then
			return show(err)
		end
		local items, _, q = v:wait()
		v:close()
		show(items and items[1].label or ("q " .. tostring(q)))
	end}
	cmd("Stale", function() show(select(2, last:set({"x"}))) end)
	cmd("Query Static", function()
		local v = qed.ui.open{kind = "child", modal = true, fields = {{text = "gam"}}, list = {items = {"alpha", "beta", "gamma"}}}
		local items = v:wait()
		v:close()
		show(items and items[1])
	end)
	qed.command{name = "Tree Confirm", scope = "filetree", run = function()
		show(qed.confirm{question = "Tree?", choices = {"One", "Two"}})
	end}
end}`

@(private = "file")
ui_run :: proc(t: ^testing.T, e: ^E2E, name: string, loc := #caller_location) {
	cmd, ok := plugin_test_command(&e.ed, name)
	testing.expectf(t, ok, "%s registered", name, loc = loc)
	command_run(&e.ed, cmd)
}

@(private = "file")
ui_selected :: proc(e: ^E2E) -> string {
	if dialog, ok := test_dialog(&e.ed); ok {
		return dialog.selected
	}
	return test_view_selected(&e.ed)
}

@(private = "file")
ui_open :: proc(e: ^E2E) -> bool {
	_, dialog := test_dialog(&e.ed)
	return dialog || test_view(&e.ed) != nil
}

@(private = "file")
ui_type :: proc(e: ^E2E, s: string) {
	e2e_type(e, s)
	plugin_flush(&e.ed)
}

@(private = "file")
ui_click :: proc(e: ^E2E, x, y: int) {
	e2e_mouse(e, x, y)
	pane_stack_sync(&e.ed)
	plugin_flush(&e.ed)
}

@(private = "file")
ui_prompt_open :: proc(e: ^E2E) -> bool {
	dialog, ok := test_dialog(&e.ed)
	return ok && dialog.kind == "prompt"
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
	testing.expect(t, ui_open(&e), "qed.pick opens a pane")
	testing.expect_value(t, ui_selected(&e), "beta")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "gamma"), "items are listed")
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, ui_selected(&e), "gamma")
	e2e_key(&e, .Enter)
	testing.expect(t, !ui_open(&e), "Enter closes")
	testing.expect_value(t, e.ed.message, "gamma")
	testing.expect_value(t, e.ed.message_source, "UI")
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
	testing.expect_value(t, pl.last_error, "")

	ui_run(t, &e, "UI: Strings")
	ui_type(&e, "alp")
	testing.expect_value(t, ui_selected(&e), "alpha")
	e2e_key(&e, .Esc)
	testing.expect(t, !ui_open(&e), "Esc closes")
	testing.expect_value(t, e.ed.message, "nil")
	testing.expect_value(t, len(e.ed.plugins.views), 0)
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
			if l.source == "UI" && l.text == text {
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
	ui_type(&e, "a")
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
	e2e_ui_settle(&e)
	_, asked := test_dialog(&e.ed)
	testing.expect(t, asked && ui_find(&e.ed.ui, "#dialog/dialog_preview") != nil, "path items use the list + preview layout")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "focus here"), "the preview shows the file")
	e2e_key(&e, .Arrow_Down)
	// past the preview debounce
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return len(e.ed.plugins.timers) > 0}, 300)
	e2e_ui_settle(&e)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "second body"), "moving reloads the preview")
	testing.expect(t, e2e_grid_has(&e, "second"), "labels render")
	testing.expect(t, e2e_grid_has(&e, "DET2"), "details render in the list")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
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
	testing.expect(t, ui_open(&e), "a full pane opens")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Pane Title"), "title")
	testing.expect(t, e2e_grid_has(&e, "line two"), "lines")
	testing.expect(t, e2e_grid_has(&e, "my footer"), "footer")
	ui_run(t, &e, "UI: Pane Set")
	testing.expect_value(t, e.ed.message, "true")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "line three"), "view:text replaces the lines")
	testing.expect(t, !e2e_grid_has(&e, "line one"), "old lines are gone")
	ui_run(t, &e, "UI: Pane Close")
	testing.expect(t, !ui_open(&e), "view:close closes")
	ui_run(t, &e, "UI: Pane Set")
	testing.expect_value(t, e.ed.message, "closed")

	ui_run(t, &e, "UI: Pane")
	e2e_key(&e, .Esc)
	testing.expect(t, !ui_open(&e), "Esc closes the pane")
}

@(test)
e2e_plugin_ui_unload_closes :: proc(t: ^testing.T) {
	e, pl := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Change")
	testing.expect_value(t, len(e.ed.plugins.tasks), 1)
	plugin_unload(&e.ed, pl)
	plugin_flush(&e.ed)
	testing.expect(t, !ui_open(&e), "unloading the owner closes the modal")
	testing.expect_value(t, len(e.ed.plugins.views), 0)
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
	e2e_key(&e, .Esc)
}

@(test)
e2e_plugin_ui_mouse :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Change")
	e2e_render(&e)
	row := e2e_ui_find_row(&e, "│ b ")
	ui_click(&e, 10, row)
	testing.expect_value(t, ui_selected(&e), "b")
	has_chg := false
	for l in e.ed.log {
		has_chg ||= l.text == "chg b"
	}
	testing.expect(t, has_chg, "a click fires on_change")
	ui_click(&e, 10, row)
	testing.expect(t, !ui_open(&e), "a double click activates")
	testing.expect_value(t, e.ed.message, "b")

	ui_run(t, &e, "UI: Strings")
	ui_click(&e, 0, 0)
	testing.expect(t, !ui_open(&e), "a click outside dismisses")
	testing.expect_value(t, e.ed.message, "nil")
}

@(test)
e2e_plugin_ui_wait_refused_in_setup :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	pl := e2e_plugin(&e, "eager", `return {setup = function() qed.pick{items = {"a"}} end}`)
	testing.expect_value(t, pl.state, PluginState.Errored)
	testing.expect_value(t, len(e.ed.panes), 0)
}

@(private = "file")
ui_logged :: proc(e: ^E2E, text: string) -> bool {
	for l in e.ed.log {
		if l.source == "UI" && l.text == text {
			return true
		}
	}
	return false
}

@(private = "file")
ui_pump :: proc(e: ^E2E, ms: int) {
	start := time.tick_now()
	for ms_since(start) < f64(ms) {
		plugin_pump(&e.ed)
		time.sleep(time.Millisecond)
	}
}

@(test)
e2e_plugin_ui_chained_pick :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Chain")
	e2e_key(&e, .Enter)
	testing.expect(t, ui_open(&e), "the continuation opens a second pick")
	testing.expect_value(t, ui_selected(&e), "p")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "xq")
	testing.expect(t, !ui_open(&e), "both picks resolved")
	testing.expect_value(t, len(e.ed.plugins.views), 0)
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
}

@(test)
e2e_plugin_ui_persist_failure :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Persist")
	testing.expect_value(t, e.ed.message, "nil cannot write the theme to config.json")
}

@(test)
e2e_plugin_ui_filetree_confirm :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	filetree_open_all(&e.ed)
	testing.expect(t, filetree_active(&e.ed), "the tree is open")
	cmd: Command
	for c in e.ed.plugins.commands {
		if c.name == "UI: Tree Confirm" {
			cmd = c
		}
	}
	plugin_command_run(&e.ed, cmd)
	_, asked := test_dialog(&e.ed)
	testing.expect(t, asked, "a tree command can open a modal over the tree")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Tree?"), "the dialog renders over the tree")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "2")
	testing.expect(t, filetree_active(&e.ed), "the tree stays open")
}

@(private = "file")
ui_ask_wait :: proc(e: ^E2E) -> ^Pane {
	e2e_pump_while(e, proc(e: ^E2E) -> bool {
		p := pane_focus(&e.ed)
		return p == nil || p.owner != "ui" || p.parent == 0
	})
	return pane_focus(&e.ed)
}

@(test)
e2e_plugin_ui_busy_under_safety :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	e2e_plugin(&e, "asker", `return {setup = function()
		qed.command{name = "Confirm", run = function() local r, err = qed.confirm{question = "Q?"}; qed.message(tostring(r) .. " " .. tostring(err)) end}
		qed.command{name = "Prompt", run = function() local r, err = qed.prompt{prompt = "P:"}; qed.message(tostring(r) .. " " .. tostring(err)) end}
	end}`)
	e2e_type(&e, "x")
	editor_request_quit(&e.ed)
	ui_run(t, &e, "Asker: Confirm")
	testing.expect_value(t, e.ed.message, "nil busy")
	ui_run(t, &e, "Asker: Prompt")
	testing.expect_value(t, e.ed.message, "nil busy")
	testing.expect_value(t, safety_dialog(&e.ed), "quit")
	e2e_key(&e, .Esc)
	testing.expect_value(t, safety_dialog(&e.ed), "")
	ui_run(t, &e, "Asker: Confirm")
	_, asked := test_dialog(&e.ed)
	testing.expect(t, asked, "once the safety dialog is gone the confirm opens")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "1 nil")
}

@(test)
e2e_plugin_ui_unload_restores_theme :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	pl := plugin_find(&e.ed.plugins, "settings")
	bg := COLOR_BG
	cmd, _ := plugin_test_command(&e.ed, "Settings: Theme")
	command_run(&e.ed, cmd)
	ui_type(&e, "solarized-light")
	testing.expect_value(t, editor_theme_current(&e.ed), "solarized-light")
	testing.expect(t, COLOR_BG != bg, "the preview applied")
	plugin_unload(&e.ed, pl)
	plugin_flush(&e.ed)
	testing.expect(t, !ui_open(&e), "the picker closed")
	testing.expect_value(t, e.ed.theme_shown, "")
	testing.expect_value(t, COLOR_BG, bg)
	testing.expect_value(t, editor_theme_current(&e.ed), THEME)
}

@(test)
e2e_plugin_term_shell :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_term_run_%d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(dir)
	defer os.remove(dir)
	pl := e2e_plugin(&e, "termrun", fmt.tprintf(`
local function type_in(cmd)
	local st = qed.term.state("shell")
	if st and st.busy then
		qed.message("busy")
		return
	end
	qed.message(tostring(qed.plugin("terminal").show("shell")))
	qed.term.send("shell", "\x15" .. cmd .. "\r")
end
return {{setup = function()
	qed.command{{name = "Term: Run", run = function() type_in("echo qed_run_$((40+2))") end}}
	qed.command{{name = "Term: Cwd", run = function() type_in("cd %s && basename \"$PWD\"") end}}
	qed.command{{name = "Term: Sleep", run = function() type_in("sleep 3") end}}
	qed.command{{name = "Term: Again", run = function() type_in("echo again") end}}
end}}`, dir))
	testing.expect_value(t, pl.state, PluginState.Enabled)
	ui_run(t, &e, "Term: Run")
	plugin_pump(&e.ed)
	e2e_term_sync(&e)
	sh := term_find(&e.ed, TERM_SHELL)
	if sh == nil || !sh.alive {
		return
	}
	testing.expect(t, e.ed.terminal.active, "showing the shell opens the pane")
	testing.expect(t, e.ed.terminal.shown == sh, "the shell is the shown session")
	testing.expect_value(t, e.ed.message, "true")
	_, _, ok := e2e_term_wait_row(&e, "qed_run_42", 4000)
	testing.expect(t, ok, "the sent command runs in the shell")

	e2e_key(&e, .Esc)
	e2e_term_sync(&e)
	testing.expect(t, !e.ed.terminal.active, "Esc hides the pane")
	ui_run(t, &e, "Term: Cwd")
	plugin_pump(&e.ed)
	e2e_term_sync(&e)
	testing.expect(t, e.ed.terminal.active, "a hidden pane is shown again")
	_, _, ok = e2e_term_wait_row(&e, filepath.base(dir), 4000)
	testing.expect(t, ok, "the shell runs the second command")

	ui_run(t, &e, "Term: Sleep")
	start := time.tick_now()
	for !term_busy(sh) && ms_since(start) < 3000 {
		term_pump(&e.ed)
		time.sleep(5 * time.Millisecond)
	}
	ui_run(t, &e, "Term: Again")
	plugin_pump(&e.ed)
	testing.expect_value(t, e.ed.message, "busy")
}

@(private = "file")
ui_count :: proc(e: ^E2E, text: string) -> int {
	n := 0
	for l in e.ed.log {
		if l.source == "UI" && l.text == text {
			n += 1
		}
	}
	return n
}

@(test)
e2e_plugin_ui_query_set :: proc(t: ^testing.T) {
	e, pl := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Query")
	v := test_view(&e.ed)
	testing.expect(t, v.place == .Split, "an on_query pick opens in the list + preview layout")
	testing.expect_value(t, textfield_str(&v.fields[0].field), "ab")
	testing.expect_value(t, v.fields[0].anchor, 0)
	testing.expect_value(t, v.fields[0].caret, 2)
	testing.expect_value(t, pane_count(&e.ed, v), 0)
	ui_pump(&e, 5)
	testing.expect_value(t, ui_count(&e, "query ab"), 1)
	testing.expect_value(t, pane_count(&e.ed, test_view(&e.ed)), 3)
	testing.expect_value(t, ui_selected(&e), "ab2")
	testing.expect(t, ui_logged(&e, "chg ab2"), "set fires on_change for the new highlight")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "ab3"), "pushed items render")
	testing.expect(t, e2e_grid_has(&e, "3│"), "the count renders by the divider")

	e2e_type(&e, "xyz")
	testing.expect_value(t, ui_count(&e, "query x"), 0)
	testing.expect_value(t, ui_selected(&e), "ab2")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect_value(t, ui_count(&e, "query xyz"), 1)
	testing.expect_value(t, ui_count(&e, "query x") + ui_count(&e, "query xy"), 0)
	testing.expect_value(t, ui_selected(&e), "xyz2")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, !ui_open(&e), "Enter closes")
	testing.expect_value(t, e.ed.message, "xyz3")
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
	testing.expect_value(t, len(e.ed.plugins.views), 0)
	testing.expect_value(t, pl.last_error, "")

	ui_run(t, &e, "UI: Stale")
	testing.expect_value(t, e.ed.message, "closed")
}

@(test)
e2e_plugin_ui_query_hint_more :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Query")
	ui_pump(&e, 5)
	e2e_key(&e, .Backspace2)
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect_value(t, pane_count(&e.ed, test_view(&e.ed)), 0)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "type something"), "the hint renders while the list is empty")
	e2e_type(&e, "more")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	e2e_render(&e)
	testing.expect(t, !e2e_grid_has(&e, "type something"), "items hide the hint")
	testing.expect(t, e2e_grid_has(&e, "3+│"), "more shows N+")
	e2e_paste(&e, "x")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect_value(t, ui_selected(&e), "morex2")
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "q morex")
}

@(test)
e2e_plugin_ui_query_kills_search :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Query")
	e2e_type(&e, "slow")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	p := &e.ed.plugins
	testing.expect_value(t, len(p.procs), 1)
	e2e_type(&e, "er")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect_value(t, len(p.procs), 0)
	testing.expect_value(t, ui_selected(&e), "slower2")

	e2e_key(&e, .Backspace2)
	e2e_key(&e, .Backspace2)
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect_value(t, len(p.procs), 1)
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "q slow")
	testing.expect_value(t, len(p.procs), 0)
	testing.expect_value(t, len(p.tasks), 0)
	testing.expect(t, !ui_logged(&e, "slow done"), "the killed search never resumes")
}

@(test)
e2e_plugin_ui_query_unload :: proc(t: ^testing.T) {
	e, pl := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Query")
	e2e_type(&e, "slow")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	p := &e.ed.plugins
	testing.expect_value(t, len(p.procs), 1)
	plugin_unload(&e.ed, pl)
	testing.expect(t, !ui_open(&e), "unloading the owner closes the picker")
	testing.expect_value(t, len(p.views), 0)
	testing.expect_value(t, len(p.procs), 0)
	testing.expect_value(t, len(p.tasks), 0)
	testing.expect_value(t, len(p.queue), 1)
	testing.expect_value(t, p.queue[0].event, PluginEvent.Plugin_Unloaded)
	plugin_flush(&e.ed)
	testing.expect(t, !plugin_busy(&e.ed), "nothing left to pump")
}

@(test)
e2e_plugin_ui_query_busy_chord :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	nav_alt(&e, 'q')
	testing.expect(t, ui_open(&e), "the chord opens the picker")
	e2e_type(&e, "slow")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	nav_alt(&e, 'q')
	testing.expect(t, !ui_open(&e), "the opening command's chord closes it")
	plugin_flush(&e.ed)
	testing.expect_value(t, e.ed.message, "q slow")
	testing.expect_value(t, len(e.ed.plugins.procs), 0)

	ui_run(t, &e, "UI: Query Static")
	v := test_view(&e.ed)
	testing.expect_value(t, textfield_str(&v.fields[0].field), "gam")
	testing.expect_value(t, ui_selected(&e), "gamma")
	testing.expect_value(t, pane_count(&e.ed, v), 1)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "gamma")
}

@(test)
e2e_plugin_ui_query_fast_close :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	ui_run(t, &e, "UI: Query")
	e2e_type(&e, "late")
	e2e_key(&e, .Esc)
	testing.expect_value(t, e.ed.message, "q late")
	testing.expect_value(t, ui_count(&e, "query late"), 0)

	ui_run(t, &e, "UI: Query")
	ui_pump(&e, 5)
	e2e_type(&e, "xyz")
	e2e_key(&e, .Enter)
	testing.expect(t, ui_open(&e), "Enter waits for the due query")
	ui_pump(&e, 20)
	testing.expect(t, !ui_open(&e), "the accept lands once the query set its items")
	testing.expect_value(t, ui_count(&e, "query xyz"), 1)
	testing.expect_value(t, e.ed.message, "xyz2")

	ui_run(t, &e, "UI: Query")
	ui_pump(&e, 5)
	e2e_type(&e, "slow")
	e2e_key(&e, .Enter)
	e2e_type(&e, "er")
	ui_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect(t, ui_open(&e), "typing after Enter drops the pending accept")
	e2e_key(&e, .Esc)
	testing.expect_value(t, len(e.ed.plugins.procs), 0)
}

@(test)
e2e_plugin_ui_query_prompt_click :: proc(t: ^testing.T) {
	e, _ := ui_start(t)
	defer e2e_stop(&e)
	e2e_resize(&e, 160, 40)
	ui_run(t, &e, "UI: Query")
	ui_pump(&e, 5)
	f := &test_view(&e.ed).fields[0]
	lay := overlay_layout(&e.ed, .Code)
	testing.expect(t, lay.preview, "wide enough for the preview")
	textfield_set(&f.field, "abcdef")
	e2e_mouse(&e, lay.right_x + 4, lay.inner.y)
	testing.expect_value(t, f.caret, 6)
	e2e_mouse(&e, lay.inner.x + 1 + 2 + 3, lay.inner.y)
	testing.expect_value(t, f.caret, 3)
	e2e_key(&e, .Esc)
}
