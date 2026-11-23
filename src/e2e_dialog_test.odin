package main

import "core:testing"

DIALOG_ASKER :: `return {setup = function()
	qed.command{name = "Pick", run = function()
		local choice, err = qed.pick{items = {"one", "two"}}
		qed.message("pick " .. tostring(choice) .. " " .. tostring(err))
	end}
	qed.command{name = "Confirm", run = function()
		local choice, err = qed.confirm{question = "Sure?"}
		qed.message("confirm " .. tostring(choice) .. " " .. tostring(err))
	end}
	qed.command{name = "Pane", run = function()
		qed.ui.open{place = "full", title = "Under", list = {items = {"a", "b"}}}
	end}
	qed.command{name = "Prompt", run = function()
		qed.message("prompt " .. tostring(qed.prompt{prompt = "Name:"}))
	end}
	qed.command{name = "Wait", run = function()
		local handle = qed.ui.mount("pane", qed.ui.text{float = "screen", width = 10, height = 1, "waiting"})
		qed.defer(0, function() handle:unmount({answer = 42}) end)
		qed.message("waited " .. tostring(handle:wait().answer))
	end}
end}`

@(test)
e2e_dialog_one_at_a_time :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", DIALOG_ASKER)
	ut_run(&e, "Pick")
	dialog, asked := test_dialog(&e.ed)
	testing.expect(t, asked && dialog.kind == "pick", "the pick opens")
	ut_run(&e, "Confirm")
	testing.expect_value(t, e.ed.message, "confirm nil busy")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "pick two nil")
}

@(test)
e2e_dialog_over_an_old_pane :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", DIALOG_ASKER)
	ut_run(&e, "Pane")
	testing.expect(t, test_view(&e.ed) != nil, "the old pane opens")
	ut_run(&e, "Confirm")
	e2e_render(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Sure?") >= 0, "the confirm draws above the pane")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "confirm 2 nil")
	testing.expect(t, test_view(&e.ed) != nil, "the pane stays")
	e2e_key(&e, .Esc)
	testing.expect(t, test_view(&e.ed) == nil, "and takes keys again")
}

@(test)
e2e_dialog_closes_with_its_asker :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", DIALOG_ASKER)
	ut_run(&e, "Confirm")
	_, asked := test_dialog(&e.ed)
	testing.expect(t, asked, "the confirm opens")
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "uitest"))
	plugin_flush(&e.ed)
	_, asked = test_dialog(&e.ed)
	testing.expect(t, !asked, "unloading the asker closes it")
}

@(test)
e2e_mount_wait_returns_the_unmount_result :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", DIALOG_ASKER)
	ut_run(&e, "Wait")
	for _ in 0 ..< 10 {
		plugin_pump(&e.ed)
		plugin_flush(&e.ed)
	}
	testing.expect_value(t, e.ed.message, "waited 42")
}

@(test)
e2e_dialog_stopped_waiter_frees_the_dialog :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", DIALOG_ASKER)
	ut_run(&e, "Pick")
	for task in e.ed.plugins.tasks {
		if task.owner == "uitest" && task.wait.kind == .Mount {
			plugin_task_kill(&e.ed, task.id)
			break
		}
	}
	e2e_ui_settle(&e)
	ut_run(&e, "Confirm")
	dialog, asked := test_dialog(&e.ed)
	testing.expect(t, asked && dialog.kind == "confirm", "a stopped waiter does not leave the dialog plugin busy")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
}

@(test)
e2e_dialog_takes_clicks_and_keys_over_an_old_pane :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", DIALOG_ASKER)
	ut_run(&e, "Pane")
	pane := test_view(&e.ed)
	ut_run(&e, "Pick")
	e2e_render(&e)
	row := e2e_ui_find_row(&e, "│ two ")
	e2e_mouse(&e, 10, row)
	e2e_ui_settle(&e)
	testing.expect_value(t, pane.list.sel, 0)
	dialog, _ := test_dialog(&e.ed)
	testing.expect_value(t, dialog.selected, "two")
	e2e_type(&e, "x")
	editor_buffer(&e.ed).modified = true
	e2e_key(&e, .Ctrl_Q, .Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, safety_dialog(&e.ed) == "", "global keys do not reach under an open dialog")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
}

@(test)
e2e_dialog_prompt_flattens_a_paste :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", DIALOG_ASKER)
	ut_run(&e, "Prompt")
	e2e_paste(&e, "ab\ncd")
	e2e_ui_settle(&e)
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "prompt ab cd")
}
