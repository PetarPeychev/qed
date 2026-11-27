package main

import "core:strings"
import "core:testing"
import "lib:tb2"

e2e_ui_find_row :: proc(e: ^E2E, text: string) -> int {
	for y in 0 ..< int(tb2.height()) {
		if strings.contains(e2e_row_text(e, y), text) {
			return y
		}
	}
	return -1
}

e2e_ui_palette_row :: proc(e: ^E2E) -> int {
	node := ui_find(&e.ed.ui, "#palette/palette")
	return node.rect.y if node != nil && !node.hidden else -1
}

e2e_ui_settle :: proc(e: ^E2E) {
	plugin_flush(&e.ed)
	plugin_pump(&e.ed)
	e2e_render(e)
}

@(test)
e2e_ui_layout_shows_editor_and_status :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	testing.expect(t, ui_layer_used(&e.ed.ui, "base"), "layout mounts into base")
	testing.expect_value(t, e2e_row_text(&e, 0), " 1 alpha")
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 2), "1/2"), "status shows the position")
	e2e_type(&e, "x")
	e2e_key(&e, .Arrow_Down)
	e2e_ui_settle(&e)
	testing.expect_value(t, e2e_row_text(&e, 0), " 1 xalpha")
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 2), "2/2"), "status follows the cursor")
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 2), ICON_MODIFIED), "modified flag")
}

@(test)
e2e_ui_palette_filters_and_runs :: proc(t: ^testing.T) {
	e := e2e_start("alpha")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_P, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_palette_row(&e) >= 0, "the palette opens")
	e2e_type(&e, "w")
	e2e_ui_settle(&e)
	e2e_key(&e, .Backspace2)
	e2e_ui_settle(&e)
	e2e_type(&e, "togglelinewr")
	e2e_ui_settle(&e)
	row := e2e_ui_find_row(&e, "Toggle Line Wrap")
	testing.expect(t, row >= 0, "the fuzzy list shows the match")
	wrap_before := g_line_wrap
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_palette_row(&e) < 0, "Enter closes the palette")
	testing.expect_value(t, g_line_wrap, !wrap_before)
	testing.expect_value(t, e2e_row_text(&e, 0), " 1 alpha")
}

ut_run :: proc(e: ^E2E, bare: string) {
	for command in e.ed.plugins.commands {
		if command.bare == bare && command.owner == "uitest" {
			plugin_command_run(&e.ed, command)
		}
	}
	e2e_ui_settle(e)
}

@(test)
e2e_ui_state_survives_update_by_identity :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local handle
local function build(extra)
	local rows = {}
	for i = 1, 30 do rows[#rows + 1] = ui.text{key = "r" .. i, "row " .. i} end
	return ui.column{float = "screen", width = 20, height = 6, anchor = "top_left",
		extra and ui.text{"extra"} or false,
		ui.scroll{id = "list_scroll", height = 4, ui.column{id = "rows", highlight_style = {bg = "pane_selection_background"}, table.unpack(rows)}},
		ui.scroll{height = 2, ui.column{ui.text{"a"}, ui.text{"b"}, ui.text{"c"}}}}
end
return {setup = function()
	qed.command{id = "open", name = "Open", run = function()
		handle = ui.mount("pane", build(false))
		ui.node("rows"):set_state{highlighted = "r20"}
	end}
	qed.command{id = "update", name = "Update", run = function() handle:update(build(true)) end}
	qed.command{id = "check", name = "Check", run = function()
		qed.message(("%s %d"):format(ui.node("rows"):state().highlighted, ui.node("list_scroll"):state().offset))
	end}
end}`)
	ut_run(&e, "Open")
	ut_run(&e, "Check")
	testing.expect_value(t, e.ed.message, "r20 16")
	testing.expect_value(t, e2e_row_text(&e, 3), "row 20")
	ut_run(&e, "Update")
	ut_run(&e, "Check")
	testing.expect_value(t, e.ed.message, "r20 16")
	testing.expect_value(t, e2e_row_text(&e, 0), "extra")
	testing.expect_value(t, e2e_row_text(&e, 4), "row 20")
}

@(test)
e2e_ui_key_routing_innermost_first :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local log = {}
local handle
local field = qed.buf.create{internal = true}
local function on_key(name, takes)
	return function(event)
		log[#log + 1] = name .. ":" .. (event.chord or "")
		return event.chord == takes
	end
end
return {setup = function()
	qed.command{id = "hit", name = "Hit", scope = "outer", key = "Ctrl+e", run = function() log[#log + 1] = "scope:outer" end}
	qed.command{id = "inner", name = "Inner", scope = "inner", key = "Down", run = function() log[#log + 1] = "scope:inner" end}
	qed.command{id = "open", name = "Open", run = function()
		handle = ui.mount("pane", ui.box{id = "outer", float = "screen", width = 30, height = 5, scope = "outer",
			on = {key = on_key("outer", "Ctrl+r")},
			ui.column{id = "middle", on = {key = on_key("middle", "Ctrl+u")},
				ui.editor{id = "field", buffer = field, height = 1, scope = {"inner", "editor"}}}})
		ui.node("field"):focus()
	end}
	qed.command{id = "close", name = "Close", run = function() handle:unmount() end}
	qed.command{id = "log", name = "Log", run = function() qed.message(table.concat(log, " ") .. " |" .. field:text()) log = {} end}
end}`)
	ut_run(&e, "Open")
	e2e_key(&e, .Ctrl_U, tb2.Mod.Ctrl)
	e2e_key(&e, .Ctrl_E, tb2.Mod.Ctrl)
	e2e_key(&e, .Arrow_Down)
	e2e_type(&e, "hi")
	e2e_key(&e, .Arrow_Left)
	e2e_type(&e, "X")
	ut_run(&e, "Log")
	testing.expect_value(t, e.ed.message, "middle:Ctrl+u middle:Ctrl+e scope:outer scope:inner |hXi")
	main_before := editor_buffer(&e.ed).cursor
	ut_run(&e, "Close")
	focused := ui_focused(&e.ed)
	testing.expect(t, focused != nil && focused.id == "main_editor", "focus falls back to the main editor from the history")
	e2e_key(&e, .Arrow_Right)
	testing.expect(t, editor_buffer(&e.ed).cursor != main_before, "keys reach the main editor again")
}

@(test)
e2e_ui_list_and_fuzzy :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local function check(cond, what) if not cond then error(what, 2) end end
return {setup = function()
	qed.command{id = "run", name = "Run", run = function()
		local files = qed.list.new{key = "path"}
		files:append{path = "src/main.odin", size = 3}
		files:append{path = "README.md", size = 1}
		files:insert(1, {path = "build.sh", size = 2})
		check(files:count() == 3 and files:at(1).path == "build.sh", "insert at 1")
		check(files:index_of("README.md") == 3 and files:get("nope") == nil, "index_of, absent get")
		files:sort("size")
		check(files:at(1).path == "README.md" and files:at(3).path == "src/main.odin", "sort by number")
		files:append{path = "x.txt", size = 0}
		check(files:at(1).path == "x.txt", "a sorted list inserts in place")
		check(not pcall(files.insert, files, 1, {path = "y"}), "insert on a sorted list raises")
		check(not pcall(files.append, files, {path = "x.txt"}), "duplicate key raises")
		local matches = qed.fuzzy.list(files, {field = "path"})
		check(matches:count() == 4, "empty query keeps every record")
		matches:set_query("mn")
		check(matches:count() == 1 and matches:at(1).path == "src/main.odin", "filtered")
		local positions = matches:positions("src/main.odin")
		check(positions[1] == 5 and positions[2] == 8 and matches:at(1).positions == nil, "1-based matched byte offsets")
		files:append{path = "lib/mine.lua", size = 9}
		check(matches:count() == 2, "a live list follows its source")
		check(not pcall(files.set, files, "lib/mine.lua", {path = "lib/other.lua"}), "set cannot change the key field")
		files:remove("lib/mine.lua")
		check(matches:count() == 1, "remove follows")
		files:remove("src/main.odin")
		check(matches:count() == 0, "remove follows again")
		check(not pcall(matches.append, matches, {path = "z"}), "a fuzzy list is read-only")
		files:clear()
		check(files:count() == 0 and matches:count() == 0, "clear")
		qed.message("list ok")
	end}
end}`)
	ut_run(&e, "Run")
	testing.expect_value(t, e.ed.message, "list ok")
}

@(test)
e2e_ui_virtual_list_builds_visible_and_caches :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local records = qed.list.new{key = "id"}
for i = 1, 1000 do records:append{id = i, label = "item " .. i} end
local function row(record) return ui.text{record.label} end
local handle
local function build()
	return ui.scroll{id = "vscroll", float = "screen", anchor = "top_left", width = 30, height = 10,
		ui.virtual_column{id = "vlist", data = records, item = row, highlight_style = {bg = "pane_selection_background"}}}
end
return {setup = function()
	qed.command{id = "open", name = "Open", run = function() handle = ui.mount("pane", build()) end}
	qed.command{id = "rebuild", name = "Rebuild", run = function() handle:update(build()) end}
	qed.command{id = "change", name = "Change", run = function() records:set(3, {label = "changed"}) end}
	qed.command{id = "jump", name = "Jump", run = function() ui.node("vlist"):set_state{highlighted = 500} end}
end}`)
	ut_run(&e, "Open")
	testing.expect_value(t, e.ed.ui.builds, 10)
	testing.expect_value(t, e2e_row_text(&e, 0)[:6], "item 1")
	ut_run(&e, "Rebuild")
	testing.expect_value(t, e.ed.ui.builds, 10)
	ut_run(&e, "Change")
	testing.expect_value(t, e.ed.ui.builds, 11)
	testing.expect_value(t, e2e_row_text(&e, 2)[:7], "changed")
	ut_run(&e, "Jump")
	testing.expect_value(t, e2e_row_text(&e, 9)[:8], "item 500")
	testing.expect_value(t, e.ed.ui.builds, 21)
	e2e_mouse(&e, 3, 3, .Mouse_Wheel_Up)
	e2e_render(&e)
	testing.expect_value(t, e2e_row_text(&e, 9)[:8], "item 497")
}

@(test)
e2e_ui_outlet_mount_and_unload :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "segment", `
return {setup = function()
	qed.command{id = "add", name = "Add", run = function() qed.ui.mount("bar_slot", qed.ui.text{fg = "warn_foreground", "[seg]"}) end}
end}`)
	ut_run_owner(&e, "segment", "Add")
	e2e_plugin(&e, "uitest", `
return {setup = function()
	qed.command{id = "open", name = "Open", run = function()
		qed.ui.mount("pane", qed.ui.row{float = "screen", anchor = "top_left", width = 40, height = 1,
			qed.ui.text{"left"}, qed.ui.outlet{id = "bar_slot"}, qed.ui.text{"right"}})
	end}
end}`)
	testing.expect(t, e2e_ui_find_row(&e, "[seg]") < 0, "a mount waits for its outlet")
	ut_run(&e, "Open")
	testing.expect_value(t, e2e_row_text(&e, 0)[:14], "left[seg]right")
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "segment"))
	e2e_render(&e)
	testing.expect_value(t, e2e_row_text(&e, 0)[:9], "leftright")
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "uitest"))
	for mount in e.ed.ui.mounts {
		testing.expect_value(t, mount.owner, "layout")
	}
}

ut_run_owner :: proc(e: ^E2E, owner, bare: string) {
	for command in e.ed.plugins.commands {
		if command.bare == bare && command.owner == owner {
			plugin_command_run(&e.ed, command)
		}
	}
	e2e_ui_settle(e)
}

@(test)
e2e_ui_palette_outside_click_and_esc :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_P, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	box := e2e_ui_palette_row(&e)
	testing.expect(t, box >= 0, "the palette opens")
	e2e_mouse(&e, 40, box + 1)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_palette_row(&e) >= 0, "a click inside keeps it")
	e2e_mouse(&e, 1, E2E_H - 3)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_palette_row(&e) < 0, "a click outside closes it")
	e2e_key(&e, .Ctrl_P, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_palette_row(&e) < 0, "Esc closes it")
	testing.expect_value(t, editor_buffer(&e.ed).cursor, Cursor{0, 0})
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, editor_buffer(&e.ed).cursor.row, 1)
}

@(test)
e2e_ui_palette_fast_typing :: proc(t: ^testing.T) {
	e := e2e_start("alpha")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_P, tb2.Mod.Ctrl)
	for character in "wrap" {
		e2e_step(&e, tb2.Event{type = .Key, ch = character})
	}
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Toggle Line Wrap") >= 0, "typing before a frame still filters")
}

@(test)
e2e_ui_editor_scope_undo_targets_the_field :: proc(t: ^testing.T) {
	e := e2e_start("alpha")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_type(&e, "x")
	e2e_ui_settle(&e)
	e2e_key(&e, .Ctrl_P, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_type(&e, "ab")
	e2e_key(&e, .Ctrl_Z, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, !strings.contains(e2e_row_text(&e, e2e_ui_palette_row(&e) + 1), "> a"), "undo empties the query")
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "xalpha")
}

@(test)
e2e_ui_mouse_falls_through_unhandled :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta\ngamma")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_plugin(&e, "uitest", `
return {setup = function()
	qed.command{id = "open", name = "Open", run = function()
		qed.ui.mount("popup", qed.ui.text{float = "screen", anchor = "top_left", width = 10, height = 3, "overlay"})
	end}
end}`)
	ut_run(&e, "Open")
	testing.expect_value(t, e2e_row_text(&e, 0)[:7], "overlay")
	e2e_mouse(&e, 5, 2)
	e2e_mouse(&e, 5, 2, .Mouse_Release)
	testing.expect_value(t, editor_buffer(&e.ed).cursor, Cursor{2, 2})
}

@(test)
e2e_ui_palette_row_clicks :: proc(t: ^testing.T) {
	e := e2e_start("alpha")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_P, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_type(&e, "linewrap")
	e2e_ui_settle(&e)
	box := e2e_ui_palette_row(&e)
	e2e_mouse(&e, 30, box)
	e2e_ui_settle(&e)
	e2e_type(&e, "x")
	e2e_key(&e, .Backspace2)
	e2e_ui_settle(&e)
	row := e2e_ui_find_row(&e, "Toggle Line Wrap")
	testing.expect(t, row > box, "typing still reaches the query after a click on the border")
	wrap_before := g_line_wrap
	e2e_mouse(&e, 20, row)
	e2e_ui_settle(&e)
	e2e_mouse(&e, 20, row)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_palette_row(&e) < 0, "a double click runs the row")
	testing.expect_value(t, g_line_wrap, !wrap_before)
}

@(test)
e2e_ui_scroll_state_fires_on_user_scroll :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
return {setup = function()
	qed.command{id = "open", name = "Open", run = function()
		local rows = {}
		for i = 1, 50 do rows[i] = ui.text{"row " .. i} end
		ui.mount("pane", ui.scroll{id = "scroller", float = "screen", anchor = "top_left", width = 30, height = 10,
			scope = "list", on = {state = function(event) qed.message("offset " .. tostring(event.offset)) end},
			ui.column(rows)})
		ui.node("scroller"):focus()
	end}
	qed.command{id = "set", name = "Set", run = function() ui.node("scroller"):set_state{offset = 20} end}
end}`)
	ut_run(&e, "Open")
	e2e_mouse(&e, 3, 3, .Mouse_Wheel_Down)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "offset 3")
	e2e_key(&e, .Arrow_Down)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "offset 4")
	editor_clear_message(&e.ed)
	ut_run(&e, "Set")
	testing.expect_value(t, e.ed.message, "")
	e2e_mouse(&e, 3, 3, .Mouse_Wheel_Up)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "offset 17")
	editor_clear_message(&e.ed)
	ut_run(&e, "Set")
	e2e_ui_settle(&e)
	for _ in 0 ..< 30 {
		e2e_mouse(&e, 3, 3, .Mouse_Wheel_Down)
	}
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "offset 40")
	editor_clear_message(&e.ed)
	e2e_mouse(&e, 3, 3, .Mouse_Wheel_Down)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "")
}

@(test)
e2e_ui_view_scrolled_event :: proc(t: ^testing.T) {
	text := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 100 {
		strings.write_string(&text, "line\n")
	}
	e := e2e_start(strings.to_string(text))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_plugin(&e, "uitest", `
local count = 0
return {setup = function()
	qed:on("view_scrolled", function(buffer)
		count = count + 1
		qed.message(("scrolled %d %s"):format(count, tostring(buffer == qed.buf.current())))
	end)
	qed.command{id = "place", name = "Place", run = function(ctx) ctx.buf:set_screen_row(50, 1) end}
	qed.command{id = "report", name = "Report", run = function(ctx) qed.message(("scrolled %d top %s"):format(count, tostring(ctx.buf:top_row()))) end}
	qed.command{id = "pane", name = "Pane", run = function()
		qed.ui.mount("pane", qed.ui.text{id = "grab", float = "screen", "pane"})
		qed.ui.node("grab"):focus()
	end}
	qed.command{id = "back", name = "Back", run = function(ctx)
		local ok = ctx.buf:focus()
		qed.message(("focus %s %s"):format(tostring(ok), table.concat(qed.ui.focus_scopes(), ",")))
	end}
end}`)
	e2e_key(&e, .Arrow_Right)
	e2e_ui_settle(&e)
	ut_run(&e, "Report")
	testing.expect_value(t, e.ed.message, "scrolled 0 top 1.0")
	wheel := tb2.Event{type = .Mouse, key = .Mouse_Wheel_Down, x = 5, y = 5}
	e2e_step(&e, wheel, wheel, wheel)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "scrolled 1 true")
	ut_run(&e, "Report")
	testing.expect_value(t, e.ed.message, "scrolled 1 top 10.0")
	ut_run(&e, "Place")
	e2e_ui_settle(&e)
	ut_run(&e, "Report")
	testing.expect_value(t, e.ed.message, "scrolled 1 top 50.0")
	e2e_mouse(&e, 5, 5, .Mouse_Wheel_Up)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "scrolled 2 true")
	ut_run(&e, "Pane")
	ut_run(&e, "Back")
	testing.expect_value(t, e.ed.message, "focus true editor")
}

@(test)
e2e_ui_view_scrolled_after_rewrap :: proc(t: ^testing.T) {
	text := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 40 {
		strings.write_string(&text, "a long line of words that wraps over several rows when the editor gets narrow enough\n")
	}
	e := e2e_start(strings.to_string(text))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_plugin(&e, "uitest", `
local count = 0
return {setup = function()
	qed:on("view_scrolled", function() count = count + 1 end)
	qed.command{id = "report", name = "Report", run = function(ctx) qed.message(("scrolled %d"):format(count)) end}
	qed.command{id = "place", name = "Place", run = function(ctx) ctx.buf:set_screen_row(10.5, 1) end}
end}`)
	ut_run(&e, "Place")
	e2e_ui_settle(&e)
	e2e_apply_size(50, E2E_H)
	e.resized = true
	editor_dispatch(&e.ed, tb2.Event{type = .Resize, w = 50, h = i32(E2E_H)})
	plugin_flush(&e.ed)
	editor_render(&e.ed)
	testing.expect(t, plugin_busy(&e.ed), "a re-wrap that moved the view top keeps the loop polling")
	plugin_pump(&e.ed)
	testing.expect(t, !plugin_busy(&e.ed), "the flush took the move")
	ut_run(&e, "Report")
	testing.expect_value(t, e.ed.message, "scrolled 1")
}

// the newest message the test plugin showed since log entry `from`
ut_said :: proc(e: ^E2E, from: int) -> string {
	for i := len(e.ed.log) - 1; i >= from; i -= 1 {
		if e.ed.log[i].source == "Uitest" {
			return e.ed.log[i].text
		}
	}
	return ""
}

ut_start :: proc(e: ^E2E, bare: string) {
	for command in e.ed.plugins.commands {
		if command.bare == bare && command.owner == "uitest" {
			plugin_command_run(&e.ed, command)
		}
	}
}

@(test)
e2e_ui_settled_waits_for_resolve :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local handle
local doc = {"# Top", ""}
for i = 1, 60 do doc[#doc + 1] = "filler " .. i .. "\n" end
doc[#doc + 1] = "## Deep"
doc = table.concat(doc, "\n")
local function settle(slug)
	ui.node("body"):set_state{heading = slug}
	local state = ui.node("body"):settled()
	qed.message(state and ("heading " .. tostring(state.heading)) or "gone")
end
return {setup = function()
	qed.command{id = "open", name = "Open", run = function()
		handle = ui.mount("pane", ui.scroll{float = "screen", anchor = "top_left", width = 40, height = 10,
			qed.markdown.parse(doc, {id = "body"})})
	end}
	qed.command{id = "deep", name = "Deep", run = function() settle("deep") end}
	qed.command{id = "missing", name = "Missing", run = function() settle("nowhere") end}
	qed.command{id = "fresh", name = "Fresh", run = function()
		handle:update(ui.scroll{float = "screen", anchor = "top_left", width = 40, height = 10,
			qed.markdown.parse(doc .. "\n\nmore", {id = "body"})})
		settle("deep")
	end}
	qed.command{id = "close", name = "Close", run = function() handle:unmount() end}
	qed.command{id = "remount", name = "Remount", run = function()
		handle:unmount()
		handle = ui.mount("pane", ui.scroll{float = "screen", anchor = "top_left", width = 40, height = 10,
			qed.markdown.parse(doc, {id = "body"})})
	end}
	qed.command{id = "loose", name = "Loose", run = function()
		ui.mount("pane", ui.column{float = "screen", anchor = "top_left", width = 20, height = 3,
			ui.text{id = "plain", "plain"}, qed.markdown.parse("# Loose", {id = "loose"})})
		ui.node("plain"):set_state{source = 5}
		qed.message("plain " .. tostring(ui.node("plain"):settled() ~= nil))
		ui.node("loose"):set_state{heading = "loose"}
		qed.message("loose " .. tostring(ui.node("loose"):settled() ~= nil))
	end}
end}`)
	ut_run(&e, "Open")
	mark := len(e.ed.log)
	ut_run(&e, "Deep")
	testing.expect_value(t, ut_said(&e, mark), "heading 123")
	ut_run(&e, "Missing")
	testing.expect_value(t, ut_said(&e, mark), "heading nil")
	mark = len(e.ed.log)
	ut_start(&e, "Fresh")
	testing.expect_value(t, ut_said(&e, mark), "")
	e2e_ui_settle(&e)
	testing.expect(t, plugin_busy(&e.ed), "a waiter whose node settled keeps the loop polling")
	// as the main loop's next pass after the frame that resolved it
	e2e_ui_settle(&e)
	testing.expect_value(t, ut_said(&e, mark), "heading 123")
	mark = len(e.ed.log)
	ut_start(&e, "Fresh")
	ut_start(&e, "Close")
	e2e_ui_settle(&e)
	testing.expect_value(t, ut_said(&e, mark), "gone")
	ut_run(&e, "Open")
	mark = len(e.ed.log)
	ut_start(&e, "Fresh")
	ut_start(&e, "Remount")
	e2e_ui_settle(&e)
	e2e_ui_settle(&e)
	testing.expect_value(t, ut_said(&e, mark), "gone")
	mark = len(e.ed.log)
	ut_start(&e, "Loose")
	testing.expect_value(t, ut_said(&e, mark), "loose true")
	ut_run(&e, "Close")
	ut_run(&e, "Open")
	mark = len(e.ed.log)
	ut_start(&e, "Fresh")
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "uitest"))
	e2e_ui_settle(&e)
	testing.expect_value(t, ut_said(&e, mark), "")
	for task in e.ed.plugins.tasks {
		testing.expect(t, task.wait.kind != .Settle, "the unloaded plugin's waiter is gone")
	}
}

@(test)
e2e_ui_view_top_after_deleting_under_it :: proc(t: ^testing.T) {
	text := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 200 {
		strings.write_string(&text, "line\n")
	}
	e := e2e_start(strings.to_string(text))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_plugin(&e, "uitest", `
local count = 0
return {setup = function()
	qed:on("view_scrolled", function() count = count + 1 end)
	qed.command{id = "chop", name = "Chop", run = function(ctx)
		ctx.buf:delete({row = 3, col = 1}, {row = 200, col = 1})
	end}
end}`)
	for _ in 0 ..< 60 {
		e2e_mouse(&e, 5, 5, .Mouse_Wheel_Down)
	}
	e2e_ui_settle(&e)
	ut_start(&e, "Chop")
	// the top row now lies past the end until the next layout reveals: both readers must cope
	plugin_busy(&e.ed)
	plugin_flush(&e.ed)
	e2e_ui_settle(&e)
	e2e_ui_settle(&e)
	testing.expect_value(t, len(editor_buffer(&e.ed).lines), 4)
}

@(test)
e2e_ui_wheel_handler_skips_sideways :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
return {setup = function()
	qed.command{id = "open", name = "Open", run = function()
		local rows = {}
		for i = 1, 50 do rows[i] = ui.text{"row " .. i} end
		ui.mount("pane", ui.scroll{id = "scroller", float = "screen", anchor = "top_left", width = 30, height = 10,
			on = {wheel = function() qed.message("wheel") return true end}, ui.column(rows)})
	end}
end}`)
	ut_run(&e, "Open")
	sideways := []tb2.Event {
		{type = .Mouse, key = .Mouse_Wheel_Down, mod = .Alt, x = 3, y = 3},
		{type = .Mouse, key = .Mouse_Wheel_Left, x = 3, y = 3},
		{type = .Mouse, key = .Mouse_Wheel_Right, x = 3, y = 3},
	}
	for ev in sideways {
		e2e_step(&e, ev)
		e2e_ui_settle(&e)
		testing.expectf(t, e.ed.message == "", "%v reached on.wheel", ev.key)
	}
	testing.expect(t, e2e_ui_find_row(&e, "row 1") >= 0, "a sideways wheel leaves the scroll put")
	e2e_mouse(&e, 3, 3, .Mouse_Wheel_Down)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "wheel")
}
