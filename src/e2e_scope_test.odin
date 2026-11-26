package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(private = "file")
scope_bare :: proc(e: ^E2E, ch: rune) {
	e2e_key(e, tb2.Key(0), {}, ch)
}

@(private = "file")
scope_log_cmd :: proc(id: string) -> ^Command {
	for &cmd in scoped_commands {
		if cmd.scope == "log" && cmd.id == id {
			return &cmd
		}
	}
	return nil
}

@(test)
e2e_scope_line_list_large_stays_cheap :: proc(t: ^testing.T) {
	N :: 100_000
	e := e2e_start(strings.repeat("some line\n", N, context.temp_allocator))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	testing.expect_value(t, len(b.lines), N + 1)
	b.cursor = {N / 2, 0}

	test_list_built = 0
	e2e_key(&e, .Ctrl_G)
	e2e_ui_settle(&e)
	rows := node_rect(&e.ed, "goto_rows").h
	testing.expect(t, rows > 0, "Go to: Line opens over a line list")
	node := ui_find(&e.ed.ui, "#goto/goto_rows")
	list := ui_list_find(&e.ed.ui, node.list)
	testing.expect(t, list != nil && list.lines != nil, "over a line list")
	testing.expect_value(t, ui_list_count(list), N + 1)
	testing.expect(t, !list.lines.filtered && len(list.lines.matches) == 0, "an empty query builds no index")
	testing.expect_value(t, ui_node_state_peek(&e.ed.ui, node).highlighted, fmt.tprintf("%d", N / 2 + 1))
	testing.expectf(t, test_list_built <= 3 * rows, "open + render build only visible rows, built %d", test_list_built)

	built := test_list_built
	e2e_type(&e, ":90000:3")
	e2e_ui_settle(&e)
	testing.expect_value(t, ui_list_count(list), 1)
	testing.expect_value(t, ui_lines_row(list.lines, 0), 90000 - 1)
	testing.expectf(t, test_list_built - built <= 2 * rows, "a jump spec builds a handful, built %d", test_list_built - built)

	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, node_rect(&e.ed, "goto_rows").h == 0, "Enter closes")
	testing.expect_value(t, b.cursor, Cursor{90000 - 1, 2})
}

@(test)
e2e_scope_line_list_live :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)
	e2e_key(&e, .Ctrl_G)
	testing.expect_value(t, len(goto_state(&e.ed).labels), 2)
	b := editor_buffer(&e.ed)
	buffer_insert(b, {1, 4}, "\ngamma")
	testing.expect_value(t, len(goto_state(&e.ed).labels), 3)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "3 gamma"), "an edit shows at once, numbered")
	e2e_key(&e, .Esc)
}

@(test)
e2e_scope_line_list_filtered_shrink :: proc(t: ^testing.T) {
	e := e2e_start("a1\na2\na3\nb\na4")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, "a")
	testing.expect_value(t, len(goto_state(&e.ed).labels), 4)
	for _ in 0 ..< 3 {
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect_value(t, goto_state(&e.ed).selected, "a4")
	delete(buffer_delete(b, {1, 0}, {4, 2}))
	e2e_render(&e)
	state := goto_state(&e.ed)
	testing.expect_value(t, len(state.labels), 1)
	testing.expect_value(t, state.selected, "a1")
	e2e_key(&e, .Enter)
	testing.expect(t, !goto_state(&e.ed).open, "Enter still works after the shrink")
	testing.expect_value(t, b.cursor.row, 0)
}

@(test)
e2e_scope_line_list_stale_jump :: proc(t: ^testing.T) {
	e := e2e_start(strings.repeat("x\n", 9, context.temp_allocator))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, ":9")
	testing.expect_value(t, goto_state(&e.ed).count, 1)
	list := ui_list_find(&e.ed.ui, ui_find(&e.ed.ui, "#goto/goto_rows").list)
	testing.expect_value(t, ui_lines_row(list.lines, 0), 8)
	delete(buffer_delete(b, {3, 0}, {9, 0}))
	e2e_render(&e)
	testing.expect_value(t, goto_state(&e.ed).count, 1)
	testing.expect_value(t, ui_lines_row(list.lines, 0), 3)
	e2e_key(&e, .Enter)
	testing.expect_value(t, b.cursor.row, 3)
}

@(test)
e2e_scope_line_list_closed_buffer :: proc(t: ^testing.T) {
	e := e2e_start("one\ntwo")
	defer e2e_stop(&e)
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, "o")
	testing.expect_value(t, len(goto_state(&e.ed).labels), 2)
	editor_close_index(&e.ed, e.ed.current)
	e2e_render(&e)
	state := goto_state(&e.ed)
	testing.expect(t, state.open, "the view stays")
	testing.expect_value(t, len(state.labels), 0)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	e2e_key(&e, .Esc)
	testing.expect(t, !goto_state(&e.ed).open, "Esc closes")
}

@(test)
e2e_scope_line_list_narrows :: proc(t: ^testing.T) {
	e := e2e_start("xa\nxab\nba\nxyb\nq")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	labels :: proc(e: ^E2E) -> string {
		return strings.join(goto_state(&e.ed).labels, ",", context.temp_allocator)
	}
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, "x")
	testing.expect_value(t, labels(&e), "xa,xab,xyb")
	e2e_type(&e, "b")
	testing.expect_value(t, labels(&e), "xab,xyb")
	buffer_insert(b, {4, 1}, "xb")
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, goto_state(&e.ed).query, "x")
	testing.expect_value(t, labels(&e), "xa,xab,xyb,qxb")
	e2e_type(&e, "b")
	testing.expect_value(t, labels(&e), "xab,xyb,qxb")
	buffer_insert(b, {2, 0}, "x")
	e2e_type(&e, "a")
	testing.expect_value(t, labels(&e), "xba")
	e2e_key(&e, .Esc)
}
