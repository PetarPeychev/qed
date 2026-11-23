package main

import "core:strings"
import "core:testing"
import "core:time"
import "lib:tb2"

ut_plugin_run :: proc(e: ^E2E, source: string) -> string {
	e2e_plugin(e, "uitest", source)
	ut_run(e, "Run")
	return e.ed.message
}

@(test)
e2e_ui_hits_cleared_after_last_mount :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)
	ut_run_owner(&e, "palette", "Open")
	testing.expect(t, e2e_ui_find_row(&e, "Command Palette") >= 0, "the palette opens over the old editor")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect_value(t, len(e.ed.ui.hits), 0)
	testing.expect(t, !e.ed.ui.caret_shown, "no stale caret after the last mount closes")
	e2e_plugin(&e, "uitest", `return {setup = function()
	qed.command{name = "Run", run = function()
		qed.ui.mount("notification", qed.ui.text{float = "screen", anchor = "bottom_right", width = 5, height = 1, "toast"})
	end}
end}`)
	ut_run_owner(&e, "uitest", "Run")
	e2e_mouse(&e, 1, 1)
	testing.expect_value(t, editor_buffer(&e.ed).cursor.row, 1)
}

@(test)
e2e_ui_unload_keeps_hits_valid_until_next_frame :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `return {setup = function()
	qed.command{name = "Run", run = function()
		qed.ui.mount("pane", qed.ui.text{float = "screen", anchor = "top_left", width = 10, height = 2,
			on = {click = function() return true end}, "clickable"})
	end}
end}`)
	ut_run_owner(&e, "uitest", "Run")
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "uitest"))
	testing.expect(t, len(e.ed.ui.graveyard) > 0, "unload leaves freeing to the next frame")
	e2e_mouse(&e, 2, 0)
	e2e_render(&e)
	testing.expect_value(t, len(e.ed.ui.graveyard), 0)
}

@(test)
e2e_ui_list_append_is_linear :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	start := time.tick_now()
	message := ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function()
		local records = qed.list.new{key = "id"}
		local matches = qed.fuzzy.list(records, {field = "path"})
		for i = 1, 100000 do records:append{id = i, path = "src/file_" .. i .. ".odin"} end
		matches:set_query("f9")
		qed.message(("%d %d"):format(records:count(), matches:count()))
	end}
end}`)
	testing.expect(t, strings.has_prefix(message, "100000 "), message)
	testing.expectf(t, ms_since(start) < 4000, "100k appends took %.0f ms", ms_since(start))
}

@(test)
e2e_ui_bug_fixes_lua :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	message := ut_plugin_run(&e, `
local ui = qed.ui
local function check(cond, what) if not cond then error(what, 2) end end
local function raises(fn, needle)
	local ok, err = pcall(fn)
	check(not ok, "expected an error: " .. needle)
	check(tostring(err):find(needle, 1, true), "error '" .. tostring(err) .. "' lacks '" .. needle .. "'")
end
return {setup = function()
	qed.command{name = "Run", run = function()
		local field = qed.buf.create{internal = true}
		raises(function() qed.jump(field, {row = 1, col = 1}) end, "internal buffer")
		raises(function() ui.mount("pane", ui.text{on = {function() end}, "x"}) end, "handlers are named")
		raises(function() ui.mount("pane", ui.column{ui.text{key = "a", "1"}, ui.text{key = "a", "2"}}) end, "duplicate key")
		raises(function() ui.mount("pane", ui.row{align = "left", ui.text{"x"}}) end, "row takes top, center or bottom")
		raises(function() ui.mount("pane", ui.text{margin = {1, 2, 3, 4}, "x"}) end, "named sides")
		raises(function() ui.mount("pane", ui.column{scope = "editor", ui.text{"x"}}) end, "only goes on an editor")
		raises(function() qed.on("startup", function() end) end, "qed:on")
		check(field.text and field.close and not field.create and not field.list, "buffer objects carry per-buffer methods only")
		check(field:close() == true and not field:valid(), "buffer:close frees an internal buffer")
		local probe = ui.mount("pane", ui.text{scope = "no_such_scope", "x"})
		probe:unmount()
		qed.message("fixes ok")
	end}
end}`)
	testing.expect_value(t, message, "fixes ok")
	warned := false
	for entry in e.ed.log {
		warned ||= entry.text == "scope 'no_such_scope' has no commands"
	}
	testing.expect(t, warned, "an unknown scope warns")
}

@(test)
e2e_ui_fuzzy_survives_source_owner_unload :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "source", `
local records = qed.list.new{key = "id"}
for i = 1, 50 do records:append{id = i, label = "row " .. i} end
return {setup = function() qed.export{records = function() return records end} end}`)
	message := ut_plugin_run(&e, `
local ui = qed.ui
local matches
return {setup = function()
	qed.command{name = "Run", run = function()
		matches = qed.fuzzy.list(qed.plugin("source").records(), {field = "label"})
		ui.mount("pane", ui.scroll{float = "screen", anchor = "top_left", width = 20, height = 5,
			ui.virtual_column{id = "rows", data = matches, item = function(record) return ui.text{record.label} end}})
		qed.message(tostring(matches:count()))
	end}
	qed.command{name = "Count", run = function() qed.message("count " .. matches:count()) end}
end}`)
	testing.expect_value(t, message, "50")
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "source"))
	e2e_render(&e)
	e2e_render(&e)
	ut_run(&e, "Count")
	testing.expect_value(t, e.ed.message, "count 0")
}

@(test)
e2e_ui_modified_named_key_global_bind :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_plugin(&e, "uitest", `return {setup = function()
	qed.command{name = "Hit", key = "Shift+F5", run = function() qed.message("hit") end}
end}`)
	for command in e.ed.plugins.commands {
		if command.owner == "uitest" {
			testing.expect_value(t, command.shortcut, "Shift+F5")
		}
	}
	testing.expect_value(t, ui_chord_of_event({type = .Key, key = .F5, mod = tb2.Mod.Shift}), "Shift+F5")
	e2e_key(&e, .F5, tb2.Mod.Shift)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "hit")
}

@(test)
e2e_ui_editor_scroll_per_buffer :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 200 {
		strings.write_string(&sb, "line\n")
	}
	e := e2e_start(strings.to_string(sb))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	for _ in 0 ..< 20 {
		e2e_mouse(&e, 5, 5, .Mouse_Wheel_Down)
	}
	e2e_ui_settle(&e)
	testing.expect(t, e2e_row_text(&e, 0) != "  1 line", "the wheel scrolled the first buffer")
	message := ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function() qed.new_buf{text = "other\n"} end}
end}`)
	_ = message
	e2e_ui_settle(&e)
	testing.expect_value(t, e2e_row_text(&e, 0), " 1 other")
}

@(test)
e2e_ui_virtual_items_evicted :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local records = qed.list.new{key = "id"}
for i = 1, 2000 do records:append{id = i} end
return {setup = function()
	qed.command{name = "Run", run = function()
		ui.mount("pane", ui.scroll{id = "vs", float = "screen", anchor = "top_left", width = 20, height = 10,
			ui.virtual_column{data = records, item = function(record) return ui.text{"item " .. record.id} end}})
	end}
	qed.command{name = "Down", run = function()
		local offset = ui.node("vs"):state().offset
		ui.node("vs"):set_state{offset = offset + 10}
	end}
end}`)
	ut_run(&e, "Run")
	for _ in 0 ..< 100 {
		ut_run(&e, "Down")
	}
	for vc in e.ed.ui.virtuals {
		testing.expectf(t, len(vc.items) <= 10 + 2 * UI_ITEM_KEEP, "cache bounded, got %d", len(vc.items))
	}
}

@(test)
e2e_ui_item_mutating_list_is_safe :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local records = qed.list.new{key = "id"}
for i = 1, 20 do records:append{id = i} end
return {setup = function()
	qed.command{name = "Run", run = function()
		ui.mount("pane", ui.scroll{float = "screen", anchor = "top_left", width = 20, height = 10,
			ui.virtual_column{data = records, item = function(record)
				if record.id == 2 then records:clear() end
				return ui.text{"item " .. record.id}
			end}})
	end}
end}`)
	ut_run(&e, "Run")
	e2e_render(&e)
	testing.expect(t, true, "no panic")
}

@(test)
e2e_ui_duplicate_outlet_places_once :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "other", `return {setup = function()
	qed.command{name = "Run", run = function()
		qed.ui.mount("pane", qed.ui.column{float = "screen", anchor = "top_left", width = 20, height = 1, qed.ui.outlet{id = "slot"}})
	end}
end}`)
	ut_run_owner(&e, "other", "Run")
	e2e_plugin(&e, "uitest", `return {setup = function()
	qed.command{name = "Run", run = function()
		qed.ui.mount("pane", qed.ui.column{float = "screen", anchor = "top_left", width = 20, height = 2, margin = {top = 1},
			qed.ui.outlet{id = "slot"}})
		qed.ui.mount("slot", qed.ui.text{"segment"})
	end}
end}`)
	ut_run(&e, "Run")
	testing.expect(t, strings.has_prefix(e2e_row_text(&e, 0), "segment"), "the first outlet in resolve order takes the mount")
	testing.expect(t, !strings.has_prefix(e2e_row_text(&e, 1), "segment"), "the mount sits only in the first outlet")
}

@(test)
e2e_ui_editor_without_scope_is_a_view :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	message := ut_plugin_run(&e, `
local view = qed.buf.create{internal = true}
return {setup = function()
	qed.command{name = "Run", run = function()
		qed.ui.mount("pane", qed.ui.editor{id = "view", float = "screen", anchor = "top_left", width = 20, height = 2, buffer = view})
		qed.ui.node("view"):focus()
	end}
	qed.command{name = "Read", run = function() qed.message("[" .. view:text() .. "]") end}
end}`)
	_ = message
	e2e_type(&e, "abc")
	ut_run(&e, "Read")
	testing.expect_value(t, e.ed.message, "[]")
}

@(test)
e2e_ui_typing_latency_gate :: proc(t: ^testing.T) {
	e := e2e_start("alpha")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	start := time.tick_now()
	for _ in 0 ..< 200 {
		e2e_step(&e, tb2.Event{type = .Key, ch = 'x'})
		plugin_pump(&e.ed)
		e2e_render(&e)
	}
	per_key := ms_since(start) / 200
	testing.expectf(t, per_key < 25, "typing with the layout costs %.2f ms per key", per_key)
}

@(test)
e2e_ui_editor_parity_pairs_move_lines_gutter :: proc(t: ^testing.T) {
	e := e2e_start("first\nsecond")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Arrow_Right, tb2.Mod.Alt)
	e2e_type(&e, "(")
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "first()")
	e2e_key(&e, .Arrow_Down, tb2.Mod.Alt)
	e2e_ui_settle(&e)
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[1].text[:]), "first()")
	buffer := editor_buffer(&e.ed)
	append(&buffer.diags, Diagnostic{from = {1, 0}, to = {1, 3}, severity = 1, message = strings.clone("bad")})
	e2e_render(&e)
	testing.expect(t, strings.has_prefix(e2e_row_text(&e, 1), " 2»"), "the gutter shows the diagnostic through the shared view renderer")
}

@(test)
e2e_ui_welcome_screen_from_layout :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	testing.expect(t, ui_layer_used(&e.ed.ui, "background"), "the welcome screen is a background mount")
	testing.expect(t, e2e_ui_find_row(&e, "Command palette") >= 0, "hints show")
	testing.expect(t, e2e_ui_find_row(&e, "MMmmMM") >= 0, "the art shows")
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 2), "qed "), "the welcome status row shows the version")
}

@(test)
e2e_ui_fuzzy_item_removing_records_is_safe :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local records = qed.list.new{key = "id"}
for i = 1, 9 do records:append{id = "k" .. i} end
local matches = qed.fuzzy.list(records, {field = "id"})
return {setup = function()
	qed.command{name = "Run", run = function()
		ui.mount("pane", ui.scroll{float = "screen", anchor = "top_left", width = 20, height = 9,
			ui.virtual_column{data = matches, item = function(record)
				if record.id == "k2" then records:remove("k5") records:remove("k2") end
				return ui.text{record.id}
			end}})
	end}
end}`)
	ut_run(&e, "Run")
	e2e_render(&e)
	testing.expect_value(t, plugin_find(&e.ed.plugins, "uitest").last_error, "")
	testing.expect(t, e2e_ui_find_row(&e, "k5") < 0, "the removed record is gone")
}

@(test)
e2e_ui_editor_clipped_from_the_top :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `
local ui = qed.ui
local view = qed.buf.create{internal = true}
view:set_text("L0\nL1\nL2\nL3\nL4\nL5\nL6\nL7")
return {setup = function()
	qed.command{name = "Run", run = function()
		ui.mount("pane", ui.scroll{id = "clip", float = "screen", anchor = "top_left", width = 20, height = 4,
			ui.column{ui.text{"a"}, ui.text{"b"}, ui.editor{height = 8, buffer = view}}})
		ui.node("clip"):set_state{offset = 4}
	end}
end}`)
	ut_run(&e, "Run")
	e2e_render(&e)
	testing.expect_value(t, e2e_row_text(&e, 0)[:2], "L2")
	testing.expect_value(t, e2e_row_text(&e, 3)[:2], "L5")
}

@(test)
e2e_ui_message_before_layout_shows :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	editor_log(&e.ed, .Warn, "", "early warning")
	e2e_new_ui(&e)
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 1), "early warning"), e2e_row_text(&e, E2E_H - 1))
}

@(test)
e2e_ui_chord_names_and_unseen :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_chord_of_event({type = .Key, key = .Ctrl_Tilde, mod = tb2.Mod.Ctrl}), "Ctrl+Space")
	_, ok := ui_chord_named_key("Ctrl+Enter")
	testing.expect(t, !ok, "Ctrl+Enter is indistinguishable from Enter")
	_, ok = ui_chord_named_key("Shift+Enter")
	testing.expect(t, !ok, "Shift+Enter too")
	_, ok = ui_chord_named_key("Ctrl+Space")
	testing.expect(t, ok, "Ctrl+Space binds")
}

@(test)
e2e_ui_buffer_hooks_drop_on_user_close :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function()
		local other = qed.new_buf{text = "y"}
		other:on("change", function() end)
	end}
end}`)
	hooks_before := 0
	for hook in e.ed.plugins.hooks {
		hooks_before += int(hook.buf != 0)
	}
	testing.expect_value(t, hooks_before, 1)
	editor_close_index(&e.ed, e.ed.current)
	hooks_after := 0
	for hook in e.ed.plugins.hooks {
		hooks_after += int(hook.buf != 0)
	}
	testing.expect_value(t, hooks_after, 0)
}

@(test)
e2e_ui_select_all_empty_then_type :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `return {setup = function()
	local query = qed.buf.create{internal = true}
	qed.command{name = "Show", run = function() qed.message("text " .. query:text()) end}
	qed.command{name = "Run", run = function()
		qed.ui.mount("pane", qed.ui.box{float = "screen", width = 30, height = 5, border = true,
			qed.ui.editor{id = "q", buffer = query, height = 1, scope = {"uit", "editor"}}})
		qed.ui.node("q"):focus()
	end}
end}`)
	ut_run(&e, "Run")
	e2e_key(&e, .Ctrl_A, .Ctrl)
	e2e_type(&e, "abc")
	ut_run(&e, "Show")
	testing.expect_value(t, e.ed.message, "text abc")
	e2e_key(&e, .Ctrl_A, .Ctrl)
	e2e_type(&e, "xyz")
	ut_run(&e, "Show")
	testing.expect_value(t, e.ed.message, "text xyz")
}


@(test)
e2e_scoped_command_pick_keeps_its_chord :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `return {setup = function()
	local query = qed.buf.create{internal = true}
	qed.command{name = "Run", run = function()
		qed.ui.mount("pane", qed.ui.box{float = "screen", width = 30, height = 5, border = true,
			qed.ui.editor{id = "q", buffer = query, height = 1, scope = {"uit", "editor"}}})
		qed.ui.node("q"):focus()
	end}
	qed.command{name = "Pick", scope = "uit", key = "Enter", run = function()
		local choice, err = qed.pick{items = {"none", "dim", "blank"}}
		qed.message("picked " .. tostring(choice) .. " " .. tostring(err))
	end}
end}`)
	ut_run(&e, "Run")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, pane_focus(&e.ed) != nil, "Enter in the scope opens the pick")
	e2e_type(&e, "dim\n")
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "picked dim nil")
}
