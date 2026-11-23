package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "lib:tb2"

@(private = "file")
VIEW_PLUGIN :: `
local v
local function note(s) qed.log(s) end
local function cmd(name, run, key) qed.command{name = name, run = run, key = key} end
return {setup = function()
	qed.meta{display_name = "V"}
	cmd("Center", function()
		v = qed.ui.open{title = "Center Title", fields = {{}}, list = {items = {"alpha", "beta", "gamma"}}, on = {
			activate = function(view, items) note("act " .. (type(items[1]) == "table" and items[1].label or items[1])); view:close() end,
			change = function(_, item) note("chg " .. item) end,
			close = function() note("closed") end,
		}}
	end, "Alt+k")
	cmd("Full", function()
		v = qed.ui.open{place = "full", title = "Full Title", text = {"body one", {text = "body two", color = "error_foreground"}},
			footer = {hints = {{label = "my hint"}, {label = "palette", cmd = "Command Palette"}}}}
	end)
	cmd("Split", function()
		local dir = qed.path.dir(qed.buf.current():path())
		v = qed.ui.open{place = "split", preview = "auto", fields = {{count = true}},
			list = {items = {{label = "one", path = qed.path.join(dir, "u1.txt"), pos = {row = 2, col = 1}}}}}
	end)
	cmd("Input", function()
		local view = qed.ui.open{fields = {{prompt = "Name: ", mode = "input", text = "x"}}}
		local items, i, text = view:wait()
		view:close()
		note(("input %s %s %s"):format(tostring(items and #items), tostring(i), tostring(text)))
	end)
	cmd("Query", function()
		v = qed.ui.open{place = "split", fields = {{mode = "query"}}, list = {}, on = {query = function(view, q)
			note("q " .. q)
			if q == "slow" then
				qed.spawn_bg{cmd = "sleep 5"}
				qed.spawn{cmd = "sleep 5"}
				note("slow done")
			end
			view:set({q .. "1", q .. "2"})
		end}}
	end)
	cmd("Set", function() local ok, err = v:set({"x", "y", "z"}, {selected = 2, more = true}); note("set " .. tostring(ok or err)) end)
	cmd("Append", function() note("append " .. tostring(v:append({"w"}))) end)
	cmd("Update", function() local ok, err = v:update("y", {label = "Y", detail = "D"}); note("update " .. tostring(ok or err)) end)
	cmd("Wait", function()
		local items, i, text = v:wait()
		note(("wait %s %s %s"):format(items and items[1] or "nil", tostring(i), tostring(text)))
	end)
	cmd("Persist", function()
		v = qed.ui.open{id = "keep", fields = {{}}, list = {items = {"one", "two", "three"}}, on = {close = function() note("persist closed") end}}
	end)
	cmd("Stream", function()
		v = qed.ui.open{id = "stream", fields = {{}}, list = {}}
		v:append({"one"})
		qed.sleep(30)
		v:append({"two", "three"})
		note("streamed")
	end)
	cmd("Other", function() qed.ui.open{list = {items = {"o"}}} end)
	cmd("Child", function(ctx)
		local c = qed.ui.open{parent = ctx.view, list = {items = {"c"}}}
		note(("child %s %s"):format(tostring(c ~= nil), tostring(ctx.view and ctx.view.id)))
	end)
	cmd("Passive", function() v = qed.ui.open{focus = false, text = {"passive text"}} end)
	cmd("Md", function()
		local lines = {"# Doc", ""}
		for i = 1, 60 do lines[#lines + 1] = "line " .. i .. "\n" end
		v = qed.ui.open{place = "full", max_width = 50, markdown = table.concat(lines, "\n")}
	end)
	cmd("Md Set", function() note("md " .. tostring(v:markdown("# New"))) end)
	cmd("Md Big", function()
		local lines = {}
		for i = 1, 300 do lines[#lines + 1] = ("## Part %d\n\nbody %d [l](http://x/%d)\n"):format(i, i, i) end
		v = qed.ui.open{place = "full", markdown = table.concat(lines, "\n")}
		local s = v:source_scroll(4 * 250 + 1)
		note(("big %d %d"):format(s, v:scroll()))
	end)
	cmd("Narrow", function() v = qed.ui.open{list = {items = {"a"}}, max_width = 20} end)
	cmd("Bad Md", function() qed.ui.open{markdown = "x"} end)
	cmd("Dim", function() v = qed.ui.open{list = {items = {"a"}}, backdrop = "dim"} end)
	cmd("Blank", function() v = qed.ui.open{list = {items = {"a"}}, backdrop = "blank"} end)
	cmd("Linked", function()
		v = qed.ui.open{place = "full", markdown = "[out](https://x.y/z) and [up](#top)\n\n# Top", on = {link = function(_, target) note("link " .. target) end}}
	end)
	cmd("Plain", function()
		v = qed.ui.open{place = "full", markdown = "[out](https://x.y/z) and [up](#top)\n\n# Top"}
	end)
	cmd("Busy", function()
		local r, err = qed.ui.open{list = {items = {"b"}}}
		note(("busy %s %s"):format(tostring(r), tostring(err)))
	end)
end}`

@(private = "file")
view_start :: proc(t: ^testing.T) -> (E2E, ^Plugin) {
	e := e2e_start("abc")
	pl := e2e_plugin(&e, "v", VIEW_PLUGIN)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	return e, pl
}

@(private = "file")
view_run :: proc(t: ^testing.T, e: ^E2E, name: string, loc := #caller_location) {
	cmd, ok := plugin_test_command(&e.ed, name)
	testing.expectf(t, ok, "%s registered", name, loc = loc)
	command_run(&e.ed, cmd)
}

@(private = "file")
view_count :: proc(e: ^E2E, text: string) -> int {
	n := 0
	for l in e.ed.log {
		if l.source == "V" && l.text == text {
			n += 1
		}
	}
	return n
}

@(private = "file")
view_logged :: proc(e: ^E2E, text: string) -> bool {
	return view_count(e, text) > 0
}

@(private = "file")
view_pump :: proc(e: ^E2E, ms: int) {
	start := time.tick_now()
	for ms_since(start) < f64(ms) {
		plugin_pump(&e.ed)
		time.sleep(time.Millisecond)
	}
}

@(test)
e2e_ui_open_center :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Center")
	v := test_view(&e.ed)
	testing.expect(t, v != nil && v.place == .Center && v.kind == .Exclusive, "a centered exclusive pane opens")
	testing.expect_value(t, pane_geom(&e.ed, v).box, pane_center(&e.ed, PALETTE_WIDTH, 1 + 1 + 1 + 3))
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Center Title") && e2e_grid_has(&e, "gamma"), "title and items render")
	e2e_type(&e, "ga")
	plugin_flush(&e.ed)
	testing.expect_value(t, test_view_selected(&e.ed), "gamma")
	testing.expect_value(t, pane_count(&e.ed, test_view(&e.ed)), 1)
	testing.expect_value(t, view_count(&e, "chg gamma"), 1)
	e2e_key(&e, .Enter)
	testing.expect(t, view_logged(&e, "act gamma") && view_logged(&e, "closed"), "activate runs, its handler closes the pane")
	testing.expect(t, test_view(&e.ed) == nil, "closed")
	testing.expect_value(t, len(e.ed.plugins.views), 0)
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
}

@(test)
e2e_ui_open_change_coalesced :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Center")
	e2e_key(&e, .Esc)
	view_run(t, &e, "V: Center")
	testing.expect_value(t, view_count(&e, "chg alpha"), 0)
	editor_dispatch(&e.ed, {type = .Key, key = .Arrow_Down})
	editor_dispatch(&e.ed, {type = .Key, key = .Arrow_Down})
	testing.expect(t, !view_logged(&e, "chg beta"), "no Lua runs during dispatch")
	plugin_flush(&e.ed)
	testing.expect(t, !view_logged(&e, "chg beta"), "two moves before a flush are one change")
	testing.expect_value(t, view_count(&e, "chg gamma"), 1)
	e2e_key(&e, .Esc)
}

@(test)
e2e_ui_open_full :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Full")
	v := test_view(&e.ed)
	testing.expect(t, v != nil && v.place == .Full, "a full pane opens")
	testing.expect_value(t, pane_geom(&e.ed, v).box, overlay_layout(&e.ed).box)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Full Title"), "title")
	testing.expect(t, e2e_grid_has(&e, "my hint  Ctrl+p palette"), "footer hints, a cmd hint with its live shortcut")
	g := pane_geom(&e.ed, v)
	testing.expect_value(t, e2e_cell_fg(&e, g.text.x, g.text.y + 1), g_theme_colors["error_foreground"])
	e2e_key(&e, .Esc)
	testing.expect(t, test_view(&e.ed) == nil, "Esc closes")
}

@(test)
e2e_ui_open_split :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	path := fmt.tprintf("%s/u1.txt", filepath.dir(e.ed.buffers[0].path))
	_ = os.write_entire_file(path, transmute([]u8)string("first\nfocus line\n"))
	defer os.remove(path)
	e2e_resize(&e, 160, 40)
	view_run(t, &e, "V: Split")
	v := test_view(&e.ed)
	testing.expect(t, preview_loaded(&v.preview), "the preview loads at open")
	g := pane_geom(&e.ed, v)
	testing.expect(t, g.has_preview, "wide enough for the preview")
	testing.expect_value(t, g.preview.y, g.inner.y)
	testing.expect_value(t, g.field_w, g.div_x - g.inner.x - 1)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "focus line"), "the preview renders the item's file")
	testing.expect(t, e2e_grid_has(&e, "1│"), "the count renders by the divider")
	e2e_key(&e, .Esc)
}

@(test)
e2e_ui_open_input_wait :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Input")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Name: x"), "an input field starts with its text, caret at the end")
	e2e_type(&e, "yz")
	e2e_key(&e, .Enter)
	testing.expect(t, view_logged(&e, "input 0 nil xyz"), "Enter resolves the wait with no items and the text")
	view_run(t, &e, "V: Input")
	e2e_key(&e, .Esc)
	testing.expect(t, view_logged(&e, "input nil nil x"), "Esc resolves it with nil and the text")
	testing.expect_value(t, len(e.ed.plugins.views), 0)
}

@(test)
e2e_ui_open_set_append_update :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Center")
	view_run(t, &e, "V: Set")
	testing.expect(t, view_logged(&e, "set true"), "set on an open view")
	v := test_view(&e.ed)
	testing.expect_value(t, pane_count(&e.ed, v), 3)
	testing.expect_value(t, test_view_selected(&e.ed), "y")
	testing.expect(t, v.list.more, "more")
	view_run(t, &e, "V: Append")
	testing.expect_value(t, pane_count(&e.ed, v), 4)
	testing.expect_value(t, test_view_selected(&e.ed), "y")
	view_run(t, &e, "V: Update")
	testing.expect(t, view_logged(&e, "update true"), "update finds the key")
	testing.expect_value(t, v.list.items[1].label, "Y")
	testing.expect_value(t, v.list.items[1].detail, "D")
	view_run(t, &e, "V: Update")
	testing.expect(t, view_logged(&e, "update not found"), "the old key is gone")
	e2e_key(&e, .Enter)
	testing.expect(t, view_logged(&e, "act Y"), "activate gets the updated item, now a table")
	view_run(t, &e, "V: Set")
	testing.expect(t, view_logged(&e, "set closed"), "set on a closed view")
}

@(test)
e2e_ui_open_query_debounce_kill :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Query")
	view_pump(&e, 5)
	testing.expect_value(t, view_count(&e, "q "), 1)
	e2e_type(&e, "slow")
	testing.expect(t, !view_logged(&e, "q s"), "typing only arms the debounce")
	view_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect_value(t, view_count(&e, "q slow"), 1)
	testing.expect_value(t, len(e.ed.plugins.procs), 2)
	e2e_type(&e, "er")
	view_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	testing.expect_value(t, len(e.ed.plugins.procs), 1)
	testing.expect(t, e.ed.plugins.procs[0].bg, "the superseded task's spawn is killed, its spawn_bg is the plugin's to kill")
	testing.expect_value(t, test_view_selected(&e.ed), "slower1")
	testing.expect(t, !view_logged(&e, "slow done"), "the superseded query never resumes")
	e2e_key(&e, .Esc)
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
}

@(test)
e2e_ui_open_wait_close :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Center")
	view_run(t, &e, "V: Wait")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, view_logged(&e, "wait beta 2 "), "wait returns the items, the index and the field text")
	view_run(t, &e, "V: Center")
	view_run(t, &e, "V: Wait")
	e2e_type(&e, "zz")
	e2e_key(&e, .Esc)
	testing.expect(t, view_logged(&e, "wait nil nil zz"), "a close resolves the wait with nil and the text")
	view_run(t, &e, "V: Wait")
	testing.expect(t, view_logged(&e, "wait nil nil nil"), "waiting on a closed view returns at once")
	testing.expect_value(t, len(e.ed.plugins.tasks), 0)
}

@(test)
e2e_ui_open_exclusive_persist :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Persist")
	e2e_type(&e, "t")
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, test_view_selected(&e.ed), "three")
	view_run(t, &e, "V: Other")
	plugin_flush(&e.ed)
	testing.expect(t, view_logged(&e, "persist closed"), "an exclusive open closes the open exclusive pane")
	testing.expect_value(t, len(e.ed.panes), 1)
	e2e_key(&e, .Esc)
	view_run(t, &e, "V: Persist")
	v := test_view(&e.ed)
	testing.expect_value(t, textfield_str(&v.fields[0].field), "")
	testing.expect_value(t, pane_count(&e.ed, v), 3)
	testing.expect_value(t, test_view_selected(&e.ed), "three")
	e2e_key(&e, .Esc)
}

@(test)
e2e_ui_open_child_ctx_view :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Center")
	parent := test_view(&e.ed).handle
	view_run(t, &e, "V: Child")
	testing.expect(t, view_logged(&e, fmt.tprintf("child true %d", parent)), "commands in a pane get ctx.view")
	c := test_view(&e.ed)
	testing.expect(t, c.kind == .Child && c.parent == parent, "parent = ctx.view stacks a child")
	e2e_key(&e, .Esc)
	testing.expect_value(t, test_view(&e.ed).handle, parent)
	view_run(t, &e, "V: Child")
	pane_end(&e.ed, parent, false)
	testing.expect_value(t, len(e.ed.panes), 0)
}

@(test)
e2e_ui_open_passive :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Passive")
	testing.expect_value(t, len(e.ed.panes), 1)
	testing.expect(t, pane_focus(&e.ed) == nil, "a passive view never takes focus")
	e2e_type(&e, "z")
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "zabc")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "passive text"), "it draws")
	view_run(t, &e, "V: Center")
	testing.expect_value(t, len(e.ed.panes), 2)
	e2e_key(&e, .Esc)
	testing.expect_value(t, len(e.ed.panes), 1)
}

@(test)
e2e_ui_open_toggle :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	nav_alt(&e, 'k')
	testing.expect(t, test_view(&e.ed) != nil, "the chord opens the pane")
	nav_alt(&e, 'k')
	plugin_flush(&e.ed)
	testing.expect(t, test_view(&e.ed) == nil, "the opening command's chord closes it")
	testing.expect(t, view_logged(&e, "closed"), "close runs")
}

@(test)
e2e_ui_open_unload :: proc(t: ^testing.T) {
	e, pl := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Query")
	e2e_type(&e, "slow")
	view_pump(&e, PANE_QUERY_DEBOUNCE_MS + 60)
	p := &e.ed.plugins
	testing.expect_value(t, len(p.procs), 2)
	plugin_unload(&e.ed, pl)
	testing.expect(t, test_view(&e.ed) == nil, "the owner's view loses focus at once")
	testing.expect_value(t, len(p.views), 0)
	testing.expect_value(t, len(p.procs), 0)
	testing.expect_value(t, len(p.tasks), 0)
	pane_stack_sync(&e.ed)
	testing.expect_value(t, len(e.ed.panes), 0)
	testing.expect_value(t, len(p.queue), 1)
	testing.expect_value(t, p.queue[0].event, PluginEvent.Plugin_Unloaded)
	plugin_flush(&e.ed)
	testing.expect(t, !plugin_busy(&e.ed), "nothing left to pump")
}

@(test)
e2e_ui_open_waiter_replaced :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Center")
	view_run(t, &e, "V: Wait")
	view_run(t, &e, "V: Other")
	plugin_flush(&e.ed)
	testing.expect(t, view_logged(&e, "wait nil nil "), "a non-modal pane with a waiter is replaced, its wait resolves nil")
	testing.expect_value(t, test_view_selected(&e.ed), "o")
	e2e_key(&e, .Esc)
}

@(test)
e2e_ui_open_restore_while_streaming :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Stream")
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return !view_logged(e, "streamed")})
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, test_view_selected(&e.ed), "three")
	e2e_key(&e, .Esc)
	view_run(t, &e, "V: Stream")
	testing.expect_value(t, test_view_selected(&e.ed), "one")
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return view_count(e, "streamed") < 2})
	testing.expect_value(t, test_view_selected(&e.ed), "three")
	e2e_key(&e, .Esc)
}

@(test)
e2e_ui_open_unload_saves :: proc(t: ^testing.T) {
	e, pl := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Persist")
	e2e_type(&e, "th")
	plugin_unload(&e.ed, pl)
	s := pane_saved_find(&e.ed, "keep")
	testing.expect(t, s != nil && s.key == "three", "an unload keeps the selection")
}

@(test)
e2e_ui_open_markdown :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Md")
	v := test_view(&e.ed)
	g := pane_geom(&e.ed, v)
	testing.expect_value(t, g.box.w, 50)
	testing.expect_value(t, g.box.x, (80 - 50) / 2)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Doc") && !e2e_grid_has(&e, "# Doc"), "rendered without the marker")
	rows := pane_body_rows(v, g)
	testing.expect(t, rows > g.text.h, "taller than the pane")
	e2e_mouse(&e, g.box.x + 5, g.box.y + 5, .Mouse_Wheel_Down)
	testing.expect_value(t, test_view(&e.ed).scroll, WHEEL_SCROLL_LINES)
	e2e_key(&e, .End)
	testing.expect_value(t, test_view(&e.ed).scroll, rows - g.text.h)
	e2e_key(&e, .Home)
	testing.expect_value(t, test_view(&e.ed).scroll, 0)
	for _ in 0 ..< 10 {
		e.ed.accel_tick = {}
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect_value(t, test_view(&e.ed).scroll, 10)
	e2e_key(&e, .Home)
	e.ed.accel_tick = {}
	for _ in 0 ..< 30 {
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect(t, test_view(&e.ed).scroll > 30, "held arrows accelerate like the buffer")
	e2e_key(&e, .Home)
	view_run(t, &e, "V: Md Set")
	plugin_flush(&e.ed)
	testing.expect(t, view_logged(&e, "md true"), "markdown replaces the body")
	testing.expect_value(t, pane_body_rows(test_view(&e.ed), g), 2)
	e2e_key(&e, .Esc)

	view_run(t, &e, "V: Narrow")
	testing.expect_value(t, pane_geom(&e.ed, test_view(&e.ed)).box.w, 20)
	e2e_key(&e, .Esc)
	view_run(t, &e, "V: Bad Md")
	plugin_flush(&e.ed)
	testing.expect(t, test_view(&e.ed) == nil, "markdown outside a full pane is refused")
}

@(test)
e2e_ui_open_markdown_in_steps :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	saved := md_slice_ms
	md_slice_ms = 0
	defer md_slice_ms = saved
	view_run(t, &e, "V: Md Big")
	v := test_view(&e.ed)
	testing.expect(t, v.md_job != nil && v.md_lines == nil, "a render past its slice keeps going in steps")
	testing.expect(t, !view_logged(&e, "big"), "source_scroll waits for the layout")
	e2e_render(&e)
	testing.expect(t, !e2e_grid_has(&e, "Part"), "nothing shows before the first render lands")
	for i := 0; i < 5000 && test_view(&e.ed).md_job != nil; i += 1 {
		pane_stack_pump(&e.ed, true)
		plugin_pump(&e.ed)
	}
	plugin_pump(&e.ed)
	v = test_view(&e.ed)
	testing.expect(t, v.md_job == nil, "the render finishes")
	testing.expect_value(t, v.md_lines[v.scroll].src, 1000)
	testing.expect_value(t, md_line_text(v.md_lines[v.scroll]), "Part 251")
	testing.expect(t, view_logged(&e, fmt.tprintf("big %d %d", v.scroll + 1, v.scroll + 1)), "source_scroll resumes with the scroll")
	whole := md_render(v.md, v.md_w, .Plain)
	testing.expect_value(t, len(v.md_lines), len(whole))
	testing.expect_value(t, md_line_text(v.md_lines[len(whole) - 1]), md_line_text(whole[len(whole) - 1]))
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Part 251"), "the target shows once rendered")
}

@(test)
e2e_ui_open_backdrop :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	status_y := int(tb2.height()) - 2
	e2e_render(&e)
	text_fg := e2e_cell_fg(&e, editor_gutter_width(&e.ed), 0)
	status_fg := e2e_cell_fg(&e, 1, status_y)
	view_run(t, &e, "V: Dim")
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, editor_gutter_width(&e.ed), 0), 'a')
	testing.expect(t, e2e_cell_fg(&e, editor_gutter_width(&e.ed), 0) != text_fg, "dim fades the editor text")
	testing.expect_value(t, e2e_cell_fg(&e, 1, status_y), status_fg)
	e2e_key(&e, .Esc)
	view_run(t, &e, "V: Blank")
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, editor_gutter_width(&e.ed), 0), ' ')
	testing.expect(t, strings.trim_space(e2e_row_text(&e, status_y)) != "", "the status bar stays")
	e2e_key(&e, .Esc)

	e2e_key(&e, tb2.Key(0), .Alt, 'f')
	e2e_render(&e)
	tree_fg := e2e_cell_fg(&e, PICKER_MARGIN_X, PICKER_MARGIN_Y)
	view_run(t, &e, "V: Dim")
	e2e_render(&e)
	testing.expect(t, e2e_cell_fg(&e, PICKER_MARGIN_X, PICKER_MARGIN_Y) != tree_fg, "a pane underneath fades too")
	testing.expect_value(t, e2e_cell_fg(&e, 1, status_y), status_fg)
}

@(test)
e2e_ui_open_links :: proc(t: ^testing.T) {
	e, _ := view_start(t)
	defer e2e_stop(&e)
	view_run(t, &e, "V: Linked")
	v := test_view(&e.ed)
	g := pane_geom(&e.ed, v)
	pane_body_rows(v, g)
	e2e_mouse(&e, g.text.x + 1, g.text.y)
	plugin_flush(&e.ed)
	testing.expect(t, view_logged(&e, "link https://x.y/z"), "a link click reaches on.link")
	lines := md_texts(test_view(&e.ed).md_lines)
	top := -1
	for l, i in lines {
		if l == "Top" {
			top = i
		}
	}
	up := strings.index(lines[0], "up")
	e2e_mouse(&e, g.text.x + up, g.text.y)
	plugin_flush(&e.ed)
	e2e_render(&e)
	testing.expect(t, view_logged(&e, "link #top"), "with a link handler anchors reach it")
	testing.expect_value(t, test_view(&e.ed).scroll, 0)
	e2e_key(&e, .Esc)
	view_run(t, &e, "V: Plain")
	e2e_render(&e)
	e2e_mouse(&e, g.text.x + up, g.text.y)
	e2e_render(&e)
	testing.expect_value(t, test_view(&e.ed).scroll, min(top, max(0, len(lines) - g.text.h)))
	e2e_key(&e, .Esc)
}

@(test)
e2e_ui_open_shape_errors :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "shape", `return {setup = function()
		qed.command{name = "Bad", run = function()
			local errs = {}
			for _, o in ipairs({
				{text = {1}},
				{text = {"x"}, footer = {hints = {1}}},
				{text = {"x"}, footer = {chips = {1}}},
				{text = {"x"}, tabs = {1}},
				{list = {items = {}, columns = {1}}},
			}) do
				local ok, err = pcall(qed.ui.open, o)
				errs[#errs + 1] = tostring(err):match("must be [^\n]*")
			end
			qed.log(table.concat(errs, ";"))
		end}
	end}`)
	cmd, ok := plugin_test_command(&e.ed, "Shape: Bad")
	testing.expect(t, ok, "registered")
	command_run(&e.ed, cmd)
	want := "must be a string or {text, color};must be a table {label, cmd?};must be a table {label, cmd, on?};must be a label or {label, cmd?};must be a table {title?, width?, min?, max?, right?}"
	found := false
	for l in e.ed.log {
		found ||= l.source == "Shape" && l.text == want
	}
	testing.expect(t, found, "shape errors print their braces")
}

@(test)
e2e_ui_open_item_buf :: proc(t: ^testing.T) {
	e := e2e_start("saved line\n")
	defer e2e_stop(&e)
	e2e_resize(&e, 160, 40)
	e2e_type(&e, "unsaved ")
	e2e_plugin(&e, "live", `return {setup = function()
		qed.command{name = "Open", key = "Alt+k", run = function(ctx)
			qed.ui.open{place = "split", preview = "auto", list = {items = {{label = "here", buf = ctx.buf, pos = {row = 1, col = 3}, tag = "kept"}}},
				on = {activate = function(v, items) qed.message(items[1].tag .. " " .. items[1].pos.col); v:close() end}}
		end}
	end}`)
	e2e_alt(&e, 'k')
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "unsaved saved line"), "the preview shows the live buffer")
	e2e_key(&e, .Enter)
	plugin_flush(&e.ed)
	testing.expect_value(t, e.ed.message, "kept 3")
}
