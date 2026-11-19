package main

import "core:testing"

@(private = "file")
pane_test_hits: int

@(private = "file")
pane_test_hit :: proc(editor: ^Editor, p: ^Pane) {
	pane_test_hits += 1
}

@(test)
e2e_pane_passive_takes_no_input :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	text := []string{"passive here"}
	passive := pane_open(&e.ed, {id = "p", kind = .Passive, text = text}).handle
	testing.expect(t, pane_focus(&e.ed) == nil, "a passive pane never has focus")
	e2e_type(&e, "z")
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "zabc")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "passive here"), "a passive pane draws")

	merge_dialog_open(&e.ed)
	testing.expect_value(t, pane_focus(&e.ed).id, "merge")
	testing.expect(t, pane_find(&e.ed, "p") != nil, "an exclusive pane leaves passive ones open")
	e2e_key(&e, .Esc)
	testing.expect(t, pane_find(&e.ed, "merge") == nil, "Esc closes the focused pane")
	e2e_key(&e, .Esc)
	testing.expect(t, pane_find(&e.ed, "p") != nil, "Esc never reaches a passive pane")
	pane_end(&e.ed, passive, false)
	testing.expect_value(t, len(e.ed.panes), 0)
}

@(test)
e2e_pane_safety_on_top :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	pane_test_hits = 0
	items := []string{"Go"}
	pane_open(&e.ed, {id = "a", list = {items = items}, on = {close = pane_test_hit}})
	editor_buffer(&e.ed).modified = true
	editor_request_quit(&e.ed)
	testing.expect_value(t, pane_focus(&e.ed).id, "quit")
	pane_open(&e.ed, {id = "b", list = {items = items}, on = {activate = pane_test_hit}})
	testing.expect_value(t, pane_test_hits, 1)
	testing.expect(t, pane_find(&e.ed, "a") == nil, "an exclusive pane replaces the open one")
	testing.expect_value(t, pane_focus(&e.ed).id, "quit")
	e2e_key(&e, .Esc)
	testing.expect_value(t, pane_focus(&e.ed).id, "b")
	e2e_key(&e, .Enter)
	testing.expect_value(t, pane_test_hits, 2)
	testing.expect_value(t, len(e.ed.panes), 0)
}

@(test)
e2e_pane_safety_idempotent :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	editor_buffer(&e.ed).modified = true
	editor_request_quit(&e.ed)
	editor_request_quit(&e.ed)
	testing.expect_value(t, len(e.ed.panes), 1)
	b := editor_buffer(&e.ed)
	conflict_dialog_open(&e.ed, b)
	conflict_dialog_open(&e.ed, b)
	testing.expect_value(t, len(e.ed.panes), 2)
}

@(test)
e2e_pane_close_dialog_targets_its_buffer :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	first := editor_buffer(&e.ed).id
	editor_buffer(&e.ed).modified = true
	close_dialog_open(&e.ed)
	append(&e.ed.buffers, buffer_new())
	editor_switch_to(&e.ed, 1)
	second := editor_buffer(&e.ed).id
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect_value(t, e.ed.buffers[0].id, second)
	b, _ := api_buf_find(&e.ed, first)
	testing.expect(t, b == nil, "Discard closes the buffer the dialog named")

	editor_buffer(&e.ed).modified = true
	close_dialog_open(&e.ed)
	append(&e.ed.buffers, buffer_new())
	editor_close_index(&e.ed, 0)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "Buffer closed while the dialog was open")
	testing.expect_value(t, len(e.ed.buffers), 1)
}

@(test)
e2e_pane_child_of_safety :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	editor_buffer(&e.ed).modified = true
	editor_request_quit(&e.ed)
	quit := pane_find(&e.ed, "quit").handle
	items := []string{"Go"}
	pane_open(&e.ed, {id = "child", kind = .Child, parent = quit, list = {items = items}})
	pane_open(&e.ed, {id = "root", list = {items = items}})
	testing.expect_value(t, e.ed.panes[0].id, "root")
	testing.expect_value(t, e.ed.panes[1].id, "quit")
	testing.expect_value(t, e.ed.panes[2].id, "child")
	testing.expect_value(t, pane_focus(&e.ed).id, "child")
	e2e_key(&e, .Esc)
	testing.expect_value(t, pane_focus(&e.ed).id, "quit")
	pane_open(&e.ed, {id = "child", kind = .Child, parent = quit, list = {items = items}})
	pane_end(&e.ed, quit, false)
	testing.expect_value(t, len(e.ed.panes), 1)
	testing.expect_value(t, pane_focus(&e.ed).id, "root")
}
