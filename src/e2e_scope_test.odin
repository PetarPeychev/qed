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
	N :: 1_000_000
	e := e2e_start(strings.repeat("some line\n", N, context.temp_allocator))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	testing.expect_value(t, len(b.lines), N + 1)
	b.cursor = {N / 2, 0}

	test_list_built = 0
	e2e_key(&e, .Ctrl_G)
	p := test_view(&e.ed)
	testing.expect(t, p != nil && p.list.source.kind == .Lines, "Go to: Line opens over a line list")
	e2e_render(&e)
	rows := pane_geom(&e.ed, p).list.h
	testing.expect_value(t, pane_count(&e.ed, p), N + 1)
	testing.expect_value(t, len(p.list.items), 0)
	testing.expect_value(t, len(p.list.matches), 0)
	testing.expect(t, !p.list.filtered, "an empty query builds no index")
	testing.expect_value(t, p.list.sel, N / 2)
	testing.expectf(t, test_list_built <= 3 * rows, "open + render build only visible rows, built %d", test_list_built)

	built := test_list_built
	e2e_type(&e, ":900000:3")
	p = test_view(&e.ed)
	testing.expect_value(t, pane_count(&e.ed, p), 1)
	testing.expect_value(t, pane_item_index(p, 0), 900000 - 1)
	e2e_render(&e)
	testing.expectf(t, test_list_built - built <= 2 * rows, "a jump spec builds a handful, built %d", test_list_built - built)
	testing.expect_value(t, len(p.list.items), 0)

	e2e_key(&e, .Enter)
	testing.expect(t, test_view(&e.ed) == nil, "Enter closes")
	testing.expect_value(t, b.cursor, Cursor{900000 - 1, 2})
}

@(test)
e2e_scope_line_list_live :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)
	e2e_key(&e, .Ctrl_G)
	p := test_view(&e.ed)
	testing.expect_value(t, pane_count(&e.ed, p), 2)
	b := editor_buffer(&e.ed)
	buffer_insert(b, {1, 4}, "\ngamma")
	testing.expect_value(t, pane_count(&e.ed, p), 3)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "3  gamma"), "an edit shows at once, numbered")
	e2e_key(&e, .Esc)
}

@(test)
e2e_scope_log_commands_rebind :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	editor_log(&e.ed, .Debug, "LSP", "a trace line")
	cmd_message_log(&e.ed)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "d debug  i info  w warn  e error  h history"), "chips show their live keys")

	toggle := scope_log_cmd("Message Log: Toggle Debug")
	saved_ch, saved_sc := toggle.ch, toggle.shortcut
	toggle.ch, toggle.shortcut = 'x', "x"
	defer {
		toggle.ch, toggle.shortcut = saved_ch, saved_sc
	}
	scope_bare(&e, 'd')
	testing.expect(t, !e.ed.logview.filter[.Debug], "the old key no longer toggles")
	scope_bare(&e, 'x')
	testing.expect(t, e.ed.logview.filter[.Debug], "the rebound key toggles")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "x debug  i info"), "the chip follows the rebind")
	testing.expect(t, e2e_grid_has(&e, "a trace line"), "the toggle refilters")
	scope_bare(&e, 'x')
	testing.expect(t, !e.ed.logview.filter[.Debug], "and back")
}

@(test)
e2e_scope_log_chip_click :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	cmd_message_log(&e.ed)
	e2e_render(&e)
	p := pane_find(&e.ed, "log")
	g := pane_geom(&e.ed, p)
	row := e2e_row(&e, g.footer_y)
	x := strings.index(row, "h history")
	testing.expect(t, x >= 0, "the history chip renders")
	testing.expect_value(t, e2e_cell_fg(&e, x, g.footer_y), COLOR_PANE_SHORTCUT_FG)
	e2e_mouse(&e, x + 2, g.footer_y)
	testing.expect(t, e.ed.logview.history, "a click on a chip runs its command")
	e2e_render(&e)
	testing.expect_value(t, e2e_cell_fg(&e, x, g.footer_y), COLOR_PANE_PROMPT_FG)
	testing.expect(t, test_pane_open(&e.ed, "log"), "the pane stays open")
	e2e_mouse(&e, x + 2, g.footer_y)
	testing.expect(t, !e.ed.logview.history, "a second click toggles back")
}

@(test)
e2e_scope_log_palette :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	cmd_message_log(&e.ed)
	log := pane_find(&e.ed, "log").handle
	e2e_key(&e, .Ctrl_P)
	pal := pane_focus(&e.ed)
	testing.expect(t, pal != nil && pal.id == "palette", "Ctrl+P in the log opens a palette")
	testing.expect(t, pal.kind == .Child && pal.parent == log, "as a child of the log")
	testing.expect_value(t, pal.list.source.scope, "log")
	labels := make([dynamic]string, context.temp_allocator)
	for it in test_pane_items(&e.ed, pal) {
		append(&labels, it.label)
	}
	names := strings.join(labels[:], "|", context.temp_allocator)
	testing.expect_value(t, names, "Copy|Toggle Debug|Toggle Info|Toggle Warn|Toggle Error|Toggle History")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Toggle Debug") && e2e_grid_has(&e, "Ctrl+c"), "rows show live shortcuts")
	e2e_type(&e, "toggle hist")
	e2e_key(&e, .Enter)
	testing.expect(t, e.ed.logview.history, "the picked scoped command runs")
	testing.expect(t, pane_focus(&e.ed) != nil && pane_focus(&e.ed).id == "log", "back on the log")
	e2e_key(&e, .Ctrl_P)
	e2e_alt(&e, 'l')
	testing.expect(t, len(e.ed.panes) == 0, "the log's chord closes it from its palette")
}

@(test)
e2e_scope_log_follows_new_entries :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	for i in 0 ..< 40 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %02d", i), show = false)
	}
	cmd_message_log(&e.ed)
	e2e_render(&e)
	p := pane_find(&e.ed, "log")
	n := pane_count(&e.ed, p)
	testing.expect_value(t, p.list.sel, n - 1)
	editor_log(&e.ed, .Info, "", "late entry", show = false)
	e2e_render(&e)
	testing.expect_value(t, p.list.sel, n)
	testing.expect(t, e2e_grid_has(&e, "late entry"), "a stuck log shows the newest entry")
	e2e_key(&e, .Arrow_Up)
	editor_log(&e.ed, .Info, "", "later entry", show = false)
	e2e_render(&e)
	testing.expect_value(t, p.list.sel, n - 1)
	testing.expect(t, !p.list.stick, "moving off the end unsticks")
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
	p := test_view(&e.ed)
	testing.expect_value(t, pane_count(&e.ed, p), 4)
	for _ in 0 ..< 3 {
		e2e_key(&e, .Arrow_Down)
	}
	delete(buffer_delete(b, {1, 0}, {4, 2}))
	e2e_render(&e)
	p = test_view(&e.ed)
	testing.expect_value(t, pane_count(&e.ed, p), 1)
	testing.expect_value(t, pane_item_index(p, 0), 0)
	testing.expect_value(t, p.list.sel, 0)
	e2e_key(&e, .Enter)
	testing.expect(t, test_view(&e.ed) == nil, "Enter still works after the shrink")
	testing.expect_value(t, b.cursor.row, 0)
}

@(test)
e2e_scope_line_list_stale_jump :: proc(t: ^testing.T) {
	e := e2e_start(strings.repeat("x\n", 9, context.temp_allocator))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, ":9")
	p := test_view(&e.ed)
	testing.expect_value(t, pane_item_index(p, 0), 8)
	delete(buffer_delete(b, {3, 0}, {9, 0}))
	e2e_render(&e)
	p = test_view(&e.ed)
	testing.expect_value(t, pane_item_index(p, 0), 3)
	e2e_key(&e, .Enter)
	testing.expect_value(t, b.cursor.row, 3)
}

@(test)
e2e_scope_line_list_closed_buffer :: proc(t: ^testing.T) {
	e := e2e_start("one\ntwo")
	defer e2e_stop(&e)
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, "o")
	p := test_view(&e.ed)
	testing.expect_value(t, pane_count(&e.ed, p), 2)
	editor_close_index(&e.ed, e.ed.current)
	e2e_render(&e)
	p = test_view(&e.ed)
	testing.expect(t, p != nil, "the view stays")
	testing.expect_value(t, pane_count(&e.ed, p), 0)
	testing.expect_value(t, list_text(&e.ed, p, 0), "")
	testing.expect_value(t, list_item(&e.ed, p, 1).label, "")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	e2e_key(&e, .Esc)
	testing.expect(t, test_view(&e.ed) == nil, "Esc closes")
}

@(test)
e2e_scope_log_eviction_keeps_selection :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved_reg := clipboard_register
	clipboard_register = ""
	defer {
		delete(clipboard_register)
		clipboard_register = saved_reg
	}
	for i in 0 ..< LOG_MAX {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %04d", i), show = false)
	}
	cmd_message_log(&e.ed)
	e2e_render(&e)
	for _ in 0 ..< 5 {
		e2e_key(&e, .Arrow_Up)
	}
	e2e_key(&e, .Arrow_Up, mod = .Shift)
	p := pane_find(&e.ed, "log")
	testing.expect(t, strings.has_suffix(test_pane_label(&e.ed, p, p.list.sel), "entry 0993"), "the selection starts on entry 0993")
	for i in 0 ..< 3 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("late %d", i), show = false)
	}
	e2e_render(&e)
	testing.expect(t, strings.has_suffix(test_pane_label(&e.ed, p, p.list.sel), "entry 0993"), "eviction keeps the selected entry")
	e2e_key(&e, .Ctrl_C)
	testing.expect_value(t, clipboard_register, "entry 0993\nentry 0994")
}

@(test)
e2e_scope_log_stuck_range_stays :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	for i in 0 ..< 10 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %d", i), show = false)
	}
	cmd_message_log(&e.ed)
	e2e_render(&e)
	e2e_key(&e, .Arrow_Up, mod = .Shift)
	e2e_key(&e, .Arrow_Down, mod = .Shift)
	p := pane_find(&e.ed, "log")
	sel, anchor := p.list.sel, p.list.anchor
	editor_log(&e.ed, .Info, "", "late", show = false)
	e2e_render(&e)
	testing.expect_value(t, p.list.sel, sel)
	testing.expect(t, p.list.anchor == anchor, "a range does not follow new entries")
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
			qed.message(("%s|%s|%s"):format(table.concat(labels, ","), table.concat(ctx.files, ","), tostring(ctx.file)))
		end}
	end}`)
	e2e_alt(&e, 'k')
	e2e_key(&e, .Arrow_Down, mod = .Shift)
	scope_bare(&e, 'p')
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Esc)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return len(e.ed.plugins.tasks) > 0})
	testing.expect_value(t, e.ed.message, "a,b|/x/a,/x/b|/x/b")
}
