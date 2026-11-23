package main

import "core:fmt"
import "core:testing"
import "lib:tb2"

@(private = "file")
r10_open_log :: proc(e: ^E2E, count: int) {
	for i in 0 ..< count {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %04d", i), show = false)
	}
	e2e_step(e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(e)
}

@(test)
e2e_round10_wheeling_back_to_the_end_follows_again :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	r10_open_log(&e, 200)
	for _ in 0 ..< 3 {
		e2e_key(&e, .Arrow_Up)
	}
	y := e2e_ui_find_row(&e, "entry 0190")
	for i := 0; i < 20 && e2e_ui_find_row(&e, "entry 0199") < 0; i += 1 {
		e2e_mouse(&e, 20, y, .Mouse_Wheel_Down)
		e2e_ui_settle(&e)
	}
	e2e_mouse(&e, 20, y, .Mouse_Wheel_Down)
	e2e_ui_settle(&e)
	for i in 0 ..< 30 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("burst %02d", i), show = false)
	}
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "burst 29") >= 0, "the user wheeled back to the end: the log follows again")
}

@(test)
e2e_round10_an_evicted_parked_row_unparks :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	r10_open_log(&e, 50)
	e2e_key(&e, .Home)
	e2e_ui_settle(&e)
	for i in 0 ..< LOG_MAX {
		editor_log(&e.ed, .Info, "", fmt.tprintf("late %04d", i), show = false)
	}
	e2e_ui_settle(&e)
	for i in 0 ..< 5 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("final %d", i), show = false)
	}
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "final 4") >= 0, "the parked row was evicted: the log follows again")
}

@(private = "file")
R10_PANE :: `local ui = qed.ui
local view
local rows = qed.list.new{key = "name"}
for i = 1, 50 do rows:append{name = "old " .. i} end
local function build()
	return ui.box{id = "r10_box", float = "screen", width = 30, height = 12, scope = {"r10", "list"},
		ui.column{
			ui.editor{id = "r10_query", buffer = view.query, height = 1, scope = "editor"},
			ui.scroll{grow = 1, ui.virtual_column{id = "r10_rows", data = rows, item = function(record) return ui.text{record.name} end}}}}
end
return {setup = function()
	qed.command{name = "R10 Open", run = function(ctx)
		view = {query = qed.buf.create{internal = true}, unmount = false}
		view.handle = ui.mount("pane", build())
		view.query:on("change", function()
			if view.unmount then
				view.handle:unmount()
			else
				view.handle:update(build())
			end
		end)
		ui.node("r10_query"):focus()
		ui.node("r10_rows"):set_state{highlighted = "old 24"}
	end}
	qed.command{name = "R10 Unmounting", run = function() view.unmount = true end}
	qed.command{name = "Mark", scope = "r10", key = "F8", run = function() qed.message("marked") end}
end}`

@(test)
e2e_round10_a_command_after_a_tree_swap_sees_a_laid_out_node :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "r10", R10_PANE)
	ft_run(&e.ed, "R10 Open")
	e2e_ui_settle(&e)
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'x'})
	editor_dispatch(&e.ed, tb2.Event{type = .Key, key = .Pgdn})
	e2e_ui_settle(&e)
	rows := ui_find(&e.ed.ui, "#r10/r10_rows")
	list := ui_list_find(&e.ed.ui, rows.list)
	at, _ := ui_list_position(list, ui_node_state_peek(&e.ed.ui, rows).highlighted)
	start := 23
	page := max(rows.clip.h - 1, 1)
	testing.expectf(t, at == start + page, "PgDn after the swap moves a page (%d rows) from index %d, not one row: now at %d", page, start, at)
}

@(test)
e2e_round10_a_plugin_command_whose_pane_went_does_not_run :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "r10", R10_PANE)
	ft_run(&e.ed, "R10 Open")
	ft_run(&e.ed, "R10 Unmounting")
	e2e_ui_settle(&e)
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'x'})
	editor_dispatch(&e.ed, tb2.Event{type = .Key, key = .F8})
	e2e_ui_settle(&e)
	testing.expect(t, e.ed.message != "marked", "the pane's command does not run once a change handler removed the pane")
}
