package main

import "core:fmt"
import "core:testing"
import "lib:tb2"

@(private = "file")
R11_FOLLOW :: `local ui = qed.ui
local rows = qed.list.new{key = "name"}
local function add(from, to) for i = from, to do rows:append{name = ("row %03d"):format(i)} end end
add(1, 200)
return {setup = function()
	qed.command{name = "F Open", run = function()
		ui.mount("pane", ui.box{float = "screen", width = 30, height = 12, scope = "list",
			ui.scroll{id = "f_scroll", follow = true,
				ui.virtual_column{id = "f_rows", data = rows, item = function(record) return ui.text{record.name} end}}})
		ui.node("f_rows"):focus()
	end}
	qed.command{name = "F Top", run = function() ui.node("f_scroll"):set_state{offset = 0} end}
	qed.command{name = "F Far", run = function() ui.node("f_scroll"):set_state{offset = 100000} end}
	qed.command{name = "F More", run = function() add(201, 230) end}
	qed.command{name = "F Offset", run = function() qed.message(tostring(ui.node("f_scroll"):state().offset)) end}
end}`

@(test)
e2e_round11_set_state_offset_on_a_follow_scroll :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "f", R11_FOLLOW)
	ft_run(&e.ed, "F Open")
	e2e_ui_settle(&e)
	ft_run(&e.ed, "F Top")
	e2e_ui_settle(&e)
	ft_run(&e.ed, "F Offset")
	testing.expect_value(t, e.ed.message, "0")
	ft_run(&e.ed, "F Far")
	e2e_ui_settle(&e)
	e2e_key(&e, .End)
	for _ in 0 ..< 3 {
		e2e_key(&e, .Arrow_Up)
	}
	ft_run(&e.ed, "F Far")
	e2e_ui_settle(&e)
	ft_run(&e.ed, "F More")
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "row 230") >= 0, "setting the offset to the end unparks: new rows follow")
}

@(private = "file")
R11_REPARENT :: `local ui = qed.ui
local view
local function field()
	return ui.editor{id = "rp_field", buffer = view.query, height = 1, scope = "editor"}
end
local function parent(child)
	return ui.box{id = "rp_p", scope = "rp_zz", child}
end
local function counter(child)
	return ui.column{id = "rp_c", on = {key = function() view.count = view.count + 1 return false end}, child}
end
local function build(swapped)
	local inner = swapped and counter(parent(field())) or parent(counter(field()))
	return ui.box{id = "rp_root", float = "screen", width = 30, height = 6, inner}
end
return {setup = function()
	qed.command{name = "RP Open", run = function()
		view = {query = qed.buf.create{internal = true}, count = 0}
		view.handle = ui.mount("pane", build(false))
		view.query:on("change", function() view.handle:update(build(true)) end)
		ui.node("rp_field"):focus()
	end}
	qed.command{name = "Never", scope = "rp_zz", key = "F8", when = function() return false end, run = function() end}
	qed.command{name = "RP Count", run = function() qed.message(tostring(view.count)) end}
end}`

@(test)
e2e_round11_a_key_visits_each_node_once :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "rp", R11_REPARENT)
	ft_run(&e.ed, "RP Open")
	e2e_ui_settle(&e)
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'x'})
	editor_dispatch(&e.ed, tb2.Event{type = .Key, key = .F8})
	e2e_ui_settle(&e)
	ft_run(&e.ed, "RP Count")
	testing.expect_value(t, e.ed.message, "1")
}

@(private = "file")
R11_TERM :: `local ui = qed.ui
local handle
local function build(name)
	return ui.box{float = "screen", width = 40, height = 6,
		ui.terminal{id = "ts_term", session = name, scope = "ts_zz"}}
end
return {setup = function()
	qed.command{name = "TS Open", run = function()
		qed.term.create{name = "ts_a", cmd = "cat"}
		qed.term.create{name = "ts_b", cmd = "cat"}
		handle = ui.mount("pane", build("ts_a"))
		ui.node("ts_term"):focus()
	end}
	qed.command{name = "TS Arm", run = function() handle:update(build("ts_b")) end}
	qed.command{name = "Never", scope = "ts_zz", key = "q", when = function() return false end, run = function() end}
end}`

@(test)
e2e_round11_a_key_after_a_swap_goes_to_the_new_session :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "ts", R11_TERM)
	ft_run(&e.ed, "TS Open")
	e2e_ui_settle(&e)
	arm, _ := plugin_test_command(&e.ed, "TS Arm")
	plugin_command_run(&e.ed, arm)
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'q'})
	e2e_ui_settle(&e)
	b := term_find(&e.ed, "ts_b")
	a := term_find(&e.ed, "ts_a")
	testing.expect(t, a != nil && b != nil, "both sessions run")
	if a == nil || b == nil {
		return
	}
	got := e2e_term_until(&e, 2000, proc(t: ^Terminal) -> bool {return e2e_term_screen_has(t, "q")}, b)
	testing.expect(t, got, "the key the swap's flush let pass reaches the session the node now shows")
	testing.expect(t, !e2e_term_screen_has(a, "q"), "not the one it showed before")
}

@(test)
e2e_round11_a_typed_filter_previews_at_once :: proc(t: ^testing.T) {
	e := e2e_root_start("main")
	defer e2e_stop(&e)
	nav_write(fmt.tprintf("%s/alpha.txt", e.dir), "alpha body\n")
	nav_write(fmt.tprintf("%s/zulu.txt", e.dir), "zulu body\n")
	filetree_open_all(&e.ed)
	ft_trees_settle(&e.ed)
	e2e_type(&e, "zulu")
	plugin_flush(&e.ed)
	e2e_render(&e)
	testing.expect_value(t, ft_preview_line(&e.ed, 0), "zulu body")
}
