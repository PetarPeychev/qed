package main

import "core:strings"
import "core:testing"
import "lib:tb2"

find_box_row :: proc(e: ^E2E) -> string {
	row := e2e_ui_find_row(e, "Find ")
	return e2e_row_text(e, row) if row >= 0 else ""
}

find_open_with :: proc(e: ^E2E, query: string) {
	e2e_key(e, .Ctrl_F, tb2.Mod.Ctrl)
	e2e_ui_settle(e)
	e2e_type(e, query)
	e2e_ui_settle(e)
}

@(test)
e2e_find_navigates_and_highlights :: proc(t: ^testing.T) {
	e := e2e_start("alpha beta\nbeta gamma\nBETA")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	find_open_with(&e, "beta")
	testing.expect(t, strings.contains(find_box_row(&e), "1/3"), find_box_row(&e))
	testing.expect_value(t, editor_buffer(&e.ed).cursor, Cursor{0, 10})
	testing.expect_value(t, e2e_cell_bg(&e, 3, 1), COLOR_FIND_MATCH_BG)
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "2/3"), "Enter steps")
	e2e_key(&e, .Arrow_Up)
	e2e_key(&e, .Arrow_Up)
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "3/3"), "Up wraps")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect(t, find_box_row(&e) == "", "Esc closes")
	testing.expect(t, len(e.ed.searches) == 0, "closing clears the highlights")
	testing.expect(t, ui_focused(&e.ed) != nil && ui_focused(&e.ed).id == "main_editor", "focus returns to the editor")
}

@(test)
e2e_find_smart_case_and_regex :: proc(t: ^testing.T) {
	e := e2e_start("Foo foo FOO f.o")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	find_open_with(&e, "foo")
	testing.expect(t, strings.contains(find_box_row(&e), "/3"), "lowercase matches every case")
	e2e_key(&e, .Backspace2)
	e2e_key(&e, .Backspace2)
	e2e_key(&e, .Backspace2)
	e2e_type(&e, "Foo")
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "1/1"), "an uppercase letter turns case on")
	e2e_key(&e, .Backspace2)
	e2e_key(&e, .Backspace2)
	e2e_key(&e, .Backspace2)
	e2e_type(&e, "f.o")
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "/1"), "plain text by default")
	e2e_step(&e, tb2.Event{type = .Key, ch = 'r', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "/4"), "Alt+r: regex")
	e2e_type(&e, "(")
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "invalid"), "an invalid pattern says so")
}

@(test)
e2e_find_replace_one_and_all :: proc(t: ^testing.T) {
	e := e2e_start("cat cat cat")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e2e_key(&e, .Ctrl_H, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	e2e_type(&e, "cat")
	e2e_key(&e, .Tab)
	e2e_type(&e, "dog")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "dog cat cat")
	e2e_step(&e, tb2.Event{type = .Key, ch = 'a', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "dog dog dog")
	testing.expect_value(t, e.ed.message, "Replaced 2 matches")
	e2e_key(&e, .Ctrl_Z, tb2.Mod.Ctrl)
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "dog dog dog")
}

@(test)
e2e_find_selection_prefill_and_paste :: proc(t: ^testing.T) {
	e := e2e_start("one two three two")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	buffer := editor_buffer(&e.ed)
	buffer.selection = Cursor{0, 4}
	buffer.cursor = {0, 7}
	e2e_key(&e, .Ctrl_F, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "two"), "a one-line selection prefills the query")
	testing.expect(t, strings.contains(find_box_row(&e), "1/2"), find_box_row(&e))
	e2e_paste(&e, "three")
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(find_box_row(&e), "three") && !strings.contains(find_box_row(&e), "twothree"), "typing replaces the prefilled selection")
}

@(test)
e2e_find_long_line_highlights :: proc(t: ^testing.T) {
	line := strings.repeat("x", 300, context.temp_allocator)
	e := e2e_start(strings.concatenate({line, "needle", line}, context.temp_allocator))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	find_open_with(&e, "needle")
	testing.expect(t, strings.contains(find_box_row(&e), "1/1"), find_box_row(&e))
	found := false
	for y in 0 ..< E2E_H - 2 {
		for x in 0 ..< E2E_W {
			found ||= e2e_cell(&e, x, y) == 'n' && e2e_cell_bg(&e, x, y) != COLOR_BG
		}
	}
	testing.expect(t, found, "the match on a wrapped long line is highlighted")
}
