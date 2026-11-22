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

e2e_ui_settle :: proc(e: ^E2E) {
	plugin_flush(&e.ed)
	e2e_render(e)
}

@(test)
e2e_ui_layout_shows_editor_and_status :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	testing.expect(t, ui_layer_used(&e.ed.ui, "base"), "layout mounts into base")
	testing.expect_value(t, e2e_row_text(&e, 0), " 1 alpha")
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 2), "1:1"), "status shows the position")
	e2e_type(&e, "x")
	e2e_key(&e, .Arrow_Down)
	e2e_ui_settle(&e)
	testing.expect_value(t, e2e_row_text(&e, 0), " 1 xalpha")
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 2), "2:2"), "status follows the cursor")
	testing.expect(t, strings.contains(e2e_row_text(&e, E2E_H - 2), "●"), "modified flag")
}

@(test)
e2e_ui_palette_filters_and_runs :: proc(t: ^testing.T) {
	e := e2e_start("alpha")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_P, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Command Palette") >= 0, "the palette opens")
	e2e_type(&e, "togglelinewr")
	e2e_ui_settle(&e)
	row := e2e_ui_find_row(&e, "Toggle Line Wrap")
	testing.expect(t, row >= 0, "the fuzzy list shows the match")
	wrap_before := editor_buffer(&e.ed).wrap
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Command Palette") < 0, "Enter closes the palette")
	testing.expect_value(t, editor_buffer(&e.ed).wrap, !wrap_before)
	testing.expect_value(t, e2e_row_text(&e, 0), " 1 alpha")
}
