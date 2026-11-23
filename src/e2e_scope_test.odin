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
scope_log_cmd :: proc(config_name: string) -> ^Command {
	for &cmd in pane_commands {
		if cmd.scope == "log" && cmd.config_name == config_name {
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
e2e_scope_plugin_pane_command :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "sc", `return {setup = function()
		qed.command{name = "Open", key = "Alt+k", run = function()
			qed.ui.open{scope = "sc", list = {items = {"a", "b"}}}
		end}
		qed.command{name = "Mark", scope = "sc", key = "x", run = function(ctx)
			qed.message("view " .. tostring(ctx.view ~= nil))
		end}
		qed.command{name = "Field", scope = "sc", key = "Alt+j", run = function(ctx)
			qed.message("field " .. tostring(ctx.view ~= nil))
		end}
	end}`)
	e2e_alt(&e, 'k')
	testing.expect(t, test_view(&e.ed) != nil && test_view(&e.ed).scope == "sc", "the scoped view opens")
	scope_bare(&e, 'x')
	testing.expect_value(t, e.ed.message, "view true")
	e2e_key(&e, .Ctrl_P)
	pal := pane_focus(&e.ed)
	testing.expect(t, pal != nil && pal.id == "palette" && pal.list.source.scope == "sc", "scoped palette over the view")
	e2e_type(&e, "field")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.message, "field true")
	e2e_key(&e, .Esc)
	scope_bare(&e, 'x')
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "xabc")
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
e2e_scope_ctx_items :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "own", `return {setup = function()
		qed.command{name = "Open", key = "Alt+k", run = function()
			qed.ui.open{scope = "shared", list = {items = {{label = "a", path = "/x/a"}, {label = "b"}, {label = "c", path = "/x/c"}}, multi = true}}
		end}
	end}`)
	e2e_plugin(&e, "other", `return {setup = function()
		qed.command{name = "Peek", scope = "shared", key = "p", run = function(ctx)
			local labels = {}
			for _, it in ipairs(ctx.items) do labels[#labels + 1] = it.label end
			qed.message(("%s|%s|%s"):format(table.concat(labels, ","), table.concat(ctx.files, ","), tostring(ctx.view)))
		end}
	end}`)
	e2e_alt(&e, 'k')
	e2e_key(&e, .Arrow_Down, mod = .Shift)
	e2e_key(&e, .Arrow_Down, mod = .Shift)
	scope_bare(&e, 'p')
	testing.expect_value(t, e.ed.message, "a,b,c|/x/a,/x/c|nil")
	e2e_key(&e, .Esc)
}

@(test)
e2e_scope_ctx_snapshot :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "own", `return {setup = function()
		qed.command{name = "Open", key = "Alt+k", run = function()
			qed.ui.open{scope = "snap", list = {items = {{label = "a", path = "/x/a"}, {label = "b", path = "/x/b"}, {label = "c", path = "/x/c"}}, multi = true}}
		end}
		qed.command{name = "Later", scope = "snap", key = "p", run = function(ctx)
			qed.sleep(20)
			local labels = {}
			for _, it in ipairs(ctx.items) do labels[#labels + 1] = it.label end
			qed.message(("%s|%s|%s"):format(table.concat(labels, ","), table.concat(ctx.files, ","), tostring(ctx.item.path) .. "," .. tostring(ctx.item == ctx.items[2])))
		end}
	end}`)
	e2e_alt(&e, 'k')
	e2e_key(&e, .Arrow_Down, mod = .Shift)
	scope_bare(&e, 'p')
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Esc)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return len(e.ed.plugins.tasks) > 0})
	testing.expect_value(t, e.ed.message, "a,b|/x/a,/x/b|/x/b,true")
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
