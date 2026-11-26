package main

import "core:testing"

@(private = "file")
R12_ASKER :: `return {setup = function()
	qed.command{id = "r12_pick", name = "R12 Pick", run = function()
		local choice, err = qed.pick{items = {"one", "two"}}
		qed.message("pick " .. tostring(choice) .. " " .. tostring(err))
	end}
	qed.command{id = "r12_mount", name = "R12 Mount", run = function()
		local _, err = qed.ui.mount("alert", qed.ui.box{float = "screen", width = 20, height = 3,
			qed.ui.text{id = "r12_note", "plugin alert"}})
		qed.ui.node("r12_note"):focus()
		qed.message("mounted " .. tostring(err))
	end}
end}`

@(test)
e2e_round12_ctrl_q_inside_a_dialog_does_not_quit :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "r12", R12_ASKER)
	ft_run(&e.ed, "R12 Pick")
	e2e_ui_settle(&e)
	_, asked := test_dialog(&e.ed)
	testing.expect(t, asked, "the pick is open")
	e2e_key(&e, .Ctrl_Q)
	e2e_ui_settle(&e)
	testing.expect(t, !e.ed.quit && !safety_open(&e.ed), "the dialog keeps Ctrl+Q: no quit, no quit dialog")
	_, still := test_dialog(&e.ed)
	testing.expect(t, still, "the pick stays open")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
}

@(test)
e2e_round12_a_plugin_mounts_into_alert_under_a_safety_dialog :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "r12", R12_ASKER)
	e2e_type(&e, "changed")
	e2e_key(&e, .Ctrl_Q)
	e2e_ui_settle(&e)
	testing.expect(t, safety_open(&e.ed), "the quit dialog shows over the modified buffer")
	ft_run(&e.ed, "R12 Mount")
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "mounted nil")
	testing.expect(t, ui_find(&e.ed.ui, "#r12/r12_note") != nil, "the plugin's alert mount is in the tree")
	last := e.ed.ui.mounts[len(e.ed.ui.mounts) - 1]
	testing.expect(t, last.handle == e.ed.safety.handle, "the safety dialog stays the top mount")
	testing.expect_value(t, e.ed.ui.focus, "#/safety_choices")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect(t, !safety_open(&e.ed), "Esc closes the safety dialog")
	testing.expect_value(t, e.ed.ui.focus, "#r12/r12_note")
}
