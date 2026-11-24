package main

import "core:strings"
import "core:testing"

@(test)
e2e_safety_dialog_core_nodes :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	editor_buffer(&e.ed).modified = true
	editor_request_quit(&e.ed)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Unsaved changes in"), "the quit dialog draws in the alert layer")
	row := e2e_ui_find_row(&e, "Discard All")
	testing.expect(t, row >= 0, "its choices draw")
	e2e_type(&e, "x")
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "abc")
	column := visual_width(transmute([]u8)e2e_row_text(&e, row)[:max(strings.index(e2e_row_text(&e, row), "Discard All"), 0)])
	e2e_mouse(&e, column, row)
	testing.expect_value(t, e.ed.safety.selected, 2)
	testing.expect(t, !e.ed.quit, "one click selects")
	e2e_mouse(&e, column, row)
	testing.expect(t, e.ed.quit, "a second click on it chooses")
}
