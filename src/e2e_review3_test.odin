package main

import "core:strings"
import "core:testing"
import "lib:tb2"

@(test)
e2e_find_stale_matches_rescan_before_replace :: proc(t: ^testing.T) {
	e := e2e_start("cat cat cat")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_H, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_type(&e, "cat")
	e2e_ui_settle(&e)
	e2e_key(&e, .Tab)
	e2e_type(&e, "dog")
	e2e_key(&e, .Arrow_Down)
	e2e_ui_settle(&e)
	buffer := editor_buffer(&e.ed)
	buffer_set_text(buffer, "cat")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "dog")
}

@(test)
e2e_find_follows_current_buffer_and_toggles_replace :: proc(t: ^testing.T) {
	e := e2e_start("alpha one")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_F, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_type(&e, "one")
	e2e_ui_settle(&e)
	first := editor_buffer(&e.ed).id
	ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function() qed.new_buf{text = "beta one one"} end}
end}`)
	e2e_ui_settle(&e)
	testing.expect(t, editor_buffer(&e.ed).id != first, "switched")
	e2e_key(&e, .Ctrl_F, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_type(&e, "one")
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "/2"), find_box_row(&e))
	testing.expect_value(t, len(e.ed.searches), 1)
	e2e_key(&e, .Ctrl_H, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Repl ") >= 0, "Ctrl+H shows the replace row")
	e2e_key(&e, .Ctrl_H, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Repl ") < 0, "Ctrl+H again hides it")
}

@(test)
e2e_find_paste_flattens_and_selection_rules :: proc(t: ^testing.T) {
	e := e2e_start("a b a b\n  \nx")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	buffer := editor_buffer(&e.ed)
	buffer.selection = Cursor{1, 0}
	buffer.cursor = {1, 2}
	e2e_key(&e, .Ctrl_F, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "Find    ") || !strings.contains(find_box_row(&e), "Find  "), "whitespace selections do not prefill")
	e2e_paste(&e, "a\nb")
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "a b"), find_box_row(&e))
	testing.expect(t, strings.contains(find_box_row(&e), "/2"), "the flattened query matches")
}

@(test)
e2e_find_cap_shows_plus :: proc(t: ^testing.T) {
	e := e2e_start(strings.repeat("x ", FIND_MAX_MATCHES + 10, context.temp_allocator))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_F, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_type(&e, "x")
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "5000+"), find_box_row(&e))
}

@(test)
e2e_search_handles_owned_and_closed_on_unload :: proc(t: ^testing.T) {
	e := e2e_start("one two one")
	defer e2e_stop(&e)
	message := ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function()
		local buffer = qed.buf.current()
		local first = buffer:find("one")
		local second = buffer:find("two")
		local index, count = first:result()
		local _, other = second:result()
		qed.message(("%d %d %d"):format(index, count, other))
	end}
end}`)
	testing.expect_value(t, message, "1 2 1")
	testing.expect_value(t, len(e.ed.searches), 2)
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "uitest"))
	testing.expect_value(t, len(e.ed.searches), 0)
}

@(test)
e2e_buffer_objects_interned_and_owned_by_caller :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "maker", `
local made
return {setup = function()
	qed.export{make = function()
		made = made or qed.buf.create{internal = true}
		return made
	end}
end}`)
	message := ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function()
		local foreign = qed.plugin("maker").make()
		local current = qed.buf.current()
		local again = qed.buf.list()[1]
		local seen = {}
		seen[current] = true
		local got
		foreign:on("change", function(buffer) got = buffer end)
		foreign:set_text("hi")
		qed.message(tostring(current == again) .. " " .. tostring(seen[again]) .. " " .. tostring(current.id) .. "=" .. tostring(current))
	end}
end}`)
	parts := strings.split(message, " ", context.temp_allocator)
	testing.expect_value(t, parts[0], "true")
	testing.expect_value(t, parts[1], "true")
	owner := ""
	for hook in e.ed.plugins.hooks {
		if hook.buf != 0 {
			owner = hook.owner
		}
	}
	testing.expect_value(t, owner, "uitest")
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "uitest"))
	for hook in e.ed.plugins.hooks {
		testing.expect(t, hook.buf == 0, "the caller's hook goes with the caller")
	}
}

@(test)
e2e_buffer_on_change_args_are_objects :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	ut_plugin_run(&e, `
seen = ""
return {setup = function()
	qed.command{name = "Run", run = function()
		local field = qed.buf.create{internal = true}
		field:on("change", function(buffer) seen = tostring(buffer == field) .. " " .. type(buffer) end)
		field:set_text("y")
	end}
	qed.command{name = "Read", run = function() qed.message(seen) end}
end}`)
	plugin_flush(&e.ed)
	ut_run(&e, "Read")
	testing.expect_value(t, e.ed.message, "true table")
}

@(test)
e2e_caret_area_follows_the_node :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_render(&e)
	area := editor_caret_area(&e.ed)
	testing.expect_value(t, area.h, E2E_H - 2)
	testing.expect_value(t, area.gutter, 3)
	clips := highlight_clips_view(editor_buffer(&e.ed), 10, 5, 0, 0, 0, false, 0, 1)
	testing.expect_value(t, len(clips), 0)
}

@(test)
e2e_owner_is_the_running_entry :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "own", `
local function bare(buffer) return buffer:find("x") end
return {setup = function()
	qed.export{bare = bare}
end}`)
	message := ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function()
		local buffer = qed.buf.current()
		qed.plugin("own").bare(buffer)
		local wrapped = coroutine.wrap(function() return buffer:find("x") end)()
		qed.message(tostring(wrapped ~= nil))
	end}
end}`)
	testing.expect_value(t, message, "true")
	owners := make(map[string]int, 4, context.temp_allocator)
	for search in e.ed.searches {
		owners[search.owner] += 1
	}
	testing.expect_value(t, owners["own"], 1)
	testing.expect_value(t, owners["uitest"], 1)
}
