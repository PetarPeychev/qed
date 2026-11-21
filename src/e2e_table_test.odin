package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
TABLE_PLUGIN :: `
return {setup = function()
	qed.command{name = "Table", run = function()
		local items = {}
		for i = 1, 1500 do
			local name = i == 1200 and "a-much-longer-name-than-the-rest" or ("item" .. i)
			items[i] = {label = name, cells = {name, "k" .. i % 3, "note " .. i}}
		end
		items[2].cells[1] = "row-two-is-wide"
		qed.ui.open{place = "full", list = {items = items, columns = {
			{title = "Name", width = "fit", max = 40}, {title = "Kind", width = 4, right = true}, {title = "Note"},
		}}}
	end}
	local function rows(wide, at)
		local items = {}
		for i = 1, 100 do
			local name = i == at and wide or ("k" .. (100 + i))
			items[i] = {label = name, cells = {name, "x"}}
		end
		return items
	end
	local v
	qed.command{name = "Sorted", run = function()
		v = qed.ui.open{place = "full", list = {items = rows(), sort = true, columns = {{title = "Name", width = "fit"}, {title = "X", width = "fill"}}}}
	end}
	qed.command{name = "Reset", run = function() v:set(rows("k150-reset-wide-reset-wide", 50)) end}
	qed.command{name = "Add", run = function() v:append({{label = "k150-append-wide-append-wide-append", cells = {"k150-append-wide-append-wide-append", "x"}}}) end}
	qed.command{name = "Off", run = function()
		v = qed.ui.open{place = "full", list = {items = rows("k150-a-sampled-but-offscreen-name-that-is-really-quite-long", 50), columns = {{title = "Name", width = "fit"}, {title = "X", width = "fill"}}}}
	end}
	for _, place in ipairs({"Full", "Split", "Center"}) do
		qed.command{name = "Rich " .. place, run = function()
			qed.ui.open{place = place:lower(), preview = place == "Split" and "auto" or nil, title = place == "Center" and "Rich" or nil,
				tabs = place ~= "Center" and {"One", "Two"} or nil, fields = {{}}, footer = {hints = {{label = "hint"}}},
				list = {items = rows(), columns = {{title = "Name", width = 4}, {title = "X"}}}}
		end}
	end
	qed.command{name = "Center", run = function()
		qed.ui.open{list = {items = {{cells = {"a", "b"}}}, columns = {{title = "One", width = "fit"}, {width = "fill"}}}}
	end}
	qed.command{name = "Bad", run = function()
		local errs = {}
		for _, c in ipairs({
			{width = 0}, {width = "wide"}, {width = 1.5}, {width = 5, min = 2}, {max = 4},
			{width = "fit", min = 5, max = 3}, {width = "fit", max = 0}, {width = "fill", min = -1},
			{title = 3}, {right = 1},
		}) do
			local ok, err = pcall(qed.ui.open, {list = {items = {}, columns = {c}}})
			errs[#errs + 1] = tostring(err):match("columns[^\n]*")
		end
		qed.log("info", table.concat(errs, ";"))
	end}
end}`

@(private = "file")
table_run :: proc(e: ^E2E, name: string) {
	cmd, _ := plugin_test_command(&e.ed, name)
	command_run(&e.ed, cmd)
}

@(test)
e2e_table_columns :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "tbl", TABLE_PLUGIN)
	table_run(&e, "Tbl: Table")
	p := test_view(&e.ed)
	testing.expect(t, p != nil, "the table opens")
	e2e_render(&e)
	g := pane_geom(&e.ed, p)
	testing.expect_value(t, g.head_y, g.list.y - 1)
	x := g.list.x + 1
	head := e2e_row_text(&e, g.head_y)
	testing.expect(t, strings.contains(head, "Name             Kind  Note"), "titles sit over columns sized by the sampled widest cell")
	testing.expect_value(t, e2e_cell_fg(&e, x, g.head_y), color_attr(COLOR_PANE_FG, .Bold))
	testing.expect_value(t, e2e_cell(&e, x + 15 + 2, g.head_y), 'K')
	testing.expect_value(t, e2e_cell(&e, x + 15 + 2 + 2, g.list.y), 'k')

	p.list.scroll = 1195
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_row_text(&e, g.head_y), fmt.tprintf("Name%*s  Kind  Note", 32 - 4, "")), "the header stays put while the list scrolls and follows the grown column")
	testing.expect(t, e2e_grid_has(&e, "a-much-longer-name-than-the-rest    k0"), "a drawn row past the sample grows the fit column")
	p.list.scroll = 0
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, fmt.tprintf("item1%*s    k1", 32 - 5, "")), "the fit column never shrinks back")

	sel := p.list.sel
	e2e_mouse(&e, x + 2, g.head_y)
	testing.expect(t, test_view(&e.ed) != nil, "a header click keeps the pane open")
	testing.expect_value(t, p.list.sel, sel)

	e2e_resize(&e, 44, E2E_H)
	e2e_render(&e)
	g = pane_geom(&e.ed, p)
	lw := g.list.w - 2
	testing.expect(t, lw - 8 < 32 && lw - 8 > 15, "the pane is narrower than the table")
	row := e2e_row_text(&e, g.list.y)
	testing.expect(t, strings.contains(e2e_row_text(&e, g.list.y + 1), "row-two-is-wide"), "a cell that still fits stays whole")
	testing.expect(t, strings.contains(row, fmt.tprintf("item1%*s    k1", lw - 8 - 5, "")) && !strings.contains(row, "note"), "the fill column goes first, then the fit column shrinks")
	e2e_resize(&e, 24, E2E_H)
	e2e_render(&e)
	g = pane_geom(&e.ed, p)
	name_w := max(4, g.list.w - 2 - 8)
	testing.expect(t, name_w < 15, "narrow enough to clip")
	testing.expect(t, strings.contains(e2e_row_text(&e, g.list.y + 1), status_clip("row-two-is-wide", name_w)), "a clipped cell ends in an ellipsis")
	e2e_key(&e, .Esc)

	e2e_resize(&e, E2E_W, E2E_H)
	table_run(&e, "Tbl: Center")
	p = test_view(&e.ed)
	testing.expect_value(t, pane_geom(&e.ed, p).box, pane_center(&e.ed, PALETTE_WIDTH, 1 + 1))
	e2e_key(&e, .Esc)
}

@(test)
e2e_table_column_errors :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "tbl", TABLE_PLUGIN)
	table_run(&e, "Tbl: Bad")
	want := strings.join({
		`columns[1].width must be a positive integer, "fit" or "fill"`,
		`columns[1].width must be a positive integer, "fit" or "fill"`,
		`columns[1].width must be a positive integer, "fit" or "fill"`,
		`columns[1].min needs width = "fit" or "fill"`,
		`columns[1].max needs width = "fit"`,
		`columns[1].min is above its max`,
		`columns[1].max must be a positive integer`,
		`columns[1].min must be a non-negative integer`,
		`columns[1].title must be a string`,
		`columns[1].right must be a boolean`,
	}, ";", context.temp_allocator)
	got := ""
	for l in e.ed.log {
		if l.source == "Tbl" {
			got = l.text
		}
	}
	testing.expect_value(t, got, want)
}

@(private = "file")
table_x_col :: proc(e: ^E2E, p: ^Pane) -> int {
	e2e_render(e)
	g := pane_geom(&e.ed, p)
	row := e2e_row_text(e, g.head_y)
	name := strings.index(row, "Name")
	return strings.rune_count(row[name:strings.index(row, "X")])
}

@(test)
e2e_table_fit_resample :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "tbl", TABLE_PLUGIN)
	table_run(&e, "Tbl: Sorted")
	p := test_view(&e.ed)
	testing.expect_value(t, table_x_col(&e, p), 4 + 2)
	table_run(&e, "Tbl: Reset")
	plugin_flush(&e.ed)
	testing.expect_value(t, table_x_col(&e, p), len("k150-reset-wide-reset-wide") + 2)
	table_run(&e, "Tbl: Add")
	plugin_flush(&e.ed)
	testing.expect_value(t, table_x_col(&e, p), len("k150-append-wide-append-wide-append") + 2)
	e2e_key(&e, .Esc)

	e2e_resize(&e, 40, E2E_H)
	table_run(&e, "Tbl: Off")
	p = test_view(&e.ed)
	e2e_render(&e)
	e2e_resize(&e, 120, E2E_H)
	testing.expect_value(t, table_x_col(&e, p), len("k150-a-sampled-but-offscreen-name-that-is-really-quite-long") + 2)
	e2e_key(&e, .Esc)
}

@(test)
e2e_table_list_accel :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "tbl", TABLE_PLUGIN)
	table_run(&e, "Tbl: Table")
	p := test_view(&e.ed)
	for _ in 0 ..< 10 {
		e.ed.accel_tick = {}
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect_value(t, p.list.sel, 10)
	e.ed.accel_tick = {}
	for _ in 0 ..< 30 {
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect(t, p.list.sel > 40, "held arrows accelerate the selection")
	sel := p.list.sel
	for _ in 0 ..< 30 {
		e2e_key(&e, .Arrow_Up)
	}
	testing.expect(t, sel - p.list.sel > 30, "and back up")
	e.ed.accel_tick = {}
	for _ in 0 ..< 200 {
		e2e_key(&e, .Arrow_Up)
	}
	testing.expect_value(t, p.list.sel, 0)
	e.ed.accel_tick = {}
	e2e_key(&e, .Pgdn)
	testing.expect_value(t, p.list.sel, pane_geom(&e.ed, p).list.h)
	e2e_key(&e, .Esc)
}

@(test)
e2e_table_empty_hint :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	saved := PANE_TABLE_BORDERS
	defer PANE_TABLE_BORDERS = saved
	for &on in e.ed.logview.filter {
		on = false
	}
	for mode in TableBorders {
		PANE_TABLE_BORDERS = mode
		cmd_message_log(&e.ed)
		p := pane_find(&e.ed, "log")
		e2e_render(&e)
		g := pane_geom(&e.ed, p)
		testing.expectf(t, pane_count(&e.ed, p) == 0, "%v: the log is empty", mode)
		testing.expectf(t, strings.contains(e2e_row_text(&e, g.list.y), "│ (no messages)"), "%v: the hint spans the list", mode)
		for r in 0 ..< g.list.h {
			row := e2e_row_text(&e, g.list.y + r)
			testing.expectf(t, strings.count(row, "│") <= 2, "%v: no separators on empty row %d: %s", mode, r, row)
		}
		if g.rule_y >= 0 {
			testing.expectf(t, !strings.contains(e2e_row_text(&e, g.rule_y), "┼"), "%v: nothing crosses the rule below", mode)
		}
		testing.expectf(t, !strings.contains(e2e_row_text(&e, g.list.y + g.list.h), "┴") || mode != .All, "%v: no join under an empty list", mode)
		e2e_key(&e, .Esc)
	}
}

@(test)
e2e_table_core_max_width :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_resize(&e, 200, E2E_H)
	full := overlay_layout(&e.ed).box
	cmd_message_log(&e.ed)
	box := pane_geom(&e.ed, pane_find(&e.ed, "log")).box
	testing.expect_value(t, box.w, MESSAGE_LOG_MAX_WIDTH)
	testing.expect_value(t, box.x, full.x + (full.w - MESSAGE_LOG_MAX_WIDTH) / 2)
	e2e_key(&e, .Esc)

	saved := PLUGINS_PANE_MAX_WIDTH
	defer PLUGINS_PANE_MAX_WIDTH = saved
	PLUGINS_PANE_MAX_WIDTH = 60
	pluginview_open(&e.ed)
	box = pane_geom(&e.ed, pane_find(&e.ed, "plugins")).box
	testing.expect_value(t, box.w, 60)
	testing.expect_value(t, box.x, full.x + (full.w - 60) / 2)
	e2e_key(&e, .Esc)
}

@(test)
e2e_table_borders :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	saved := PANE_TABLE_BORDERS
	defer PANE_TABLE_BORDERS = saved
	e2e_plugin(&e, "tbl", TABLE_PLUGIN)

	PANE_TABLE_BORDERS = .Header
	table_run(&e, "Tbl: Sorted")
	p := test_view(&e.ed)
	e2e_render(&e)
	g := pane_geom(&e.ed, p)
	testing.expect_value(t, g.rule_y, g.head_y + 1)
	testing.expect_value(t, g.list.y, g.rule_y + 1)
	testing.expect_value(t, e2e_cell(&e, g.box.x, g.rule_y), '├')
	testing.expect_value(t, e2e_cell(&e, g.list.x + 3, g.rule_y), '─')
	testing.expect_value(t, table_x_col(&e, p), 4 + 2)
	e2e_key(&e, .Esc)

	PANE_TABLE_BORDERS = .All
	table_run(&e, "Tbl: Sorted")
	p = test_view(&e.ed)
	e2e_render(&e)
	g = pane_geom(&e.ed, p)
	x := g.list.x + 1
	testing.expect_value(t, table_x_col(&e, p), 4 + 3)
	testing.expect_value(t, e2e_cell(&e, x + 4 + 1, g.head_y), '│')
	testing.expect_value(t, e2e_cell(&e, x + 4 + 1, g.rule_y), '┼')
	testing.expect_value(t, e2e_cell(&e, x + 4 + 1, g.list.y), '│')
	testing.expect_value(t, e2e_cell(&e, x + 4 + 1, g.list.y + g.list.h - 1), '│')
	testing.expect_value(t, g.head_y - 1, g.box.y)
	testing.expect_value(t, e2e_cell(&e, x + 4 + 1, g.box.y), '┬')
	testing.expect_value(t, g.list.y + g.list.h, g.box.y + g.box.h - 1)
	testing.expect_value(t, e2e_cell(&e, x + 4 + 1, g.box.y + g.box.h - 1), '┴')
	e2e_key(&e, .Esc)

	for name in ([]string{"Tbl: Rich Full", "Tbl: Rich Split", "Tbl: Rich Center"}) {
		e2e_resize(&e, 160, 40)
		table_run(&e, name)
		p = test_view(&e.ed)
		e2e_render(&e)
		g = pane_geom(&e.ed, p)
		sx := g.list.x + 1 + 4 + 1
		testing.expectf(t, e2e_cell(&e, sx, g.head_y - 1) == '┬', "%s: joins the line above the header", name)
		testing.expectf(t, e2e_cell(&e, sx, g.rule_y) == '┼', "%s: crosses the header rule", name)
		testing.expectf(t, e2e_cell(&e, sx, g.list.y + g.list.h) == '┴', "%s: joins the line below the list", name)
		testing.expectf(t, e2e_cell(&e, sx, g.list.y) == '│', "%s: separates the cells", name)
		e2e_key(&e, .Esc)
	}
	e2e_resize(&e, E2E_W, E2E_H)

	table_run(&e, "Tbl: Center")
	g = pane_geom(&e.ed, test_view(&e.ed))
	testing.expect_value(t, g.box, pane_center(&e.ed, PALETTE_WIDTH, 1 + 1 + 1))
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, g.list.x + 1 + 3 + 1, g.box.y), '┬')
	testing.expect_value(t, e2e_cell(&e, g.list.x + 1 + 3 + 1, g.box.y + g.box.h - 1), '┴')
	e2e_key(&e, .Esc)
	PANE_TABLE_BORDERS = .None
	table_run(&e, "Tbl: Sorted")
	g = pane_geom(&e.ed, test_view(&e.ed))
	testing.expect_value(t, g.rule_y, -1)
	testing.expect_value(t, g.list.y, g.head_y + 1)
}
