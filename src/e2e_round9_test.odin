package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(private = "file")
r9_lines :: proc(count: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 1 ..= count {
		fmt.sbprintf(&sb, "line %d\n", i)
	}
	return strings.to_string(sb)
}

@(test)
e2e_round9_a_jump_centres_its_own_view_only :: proc(t: ^testing.T) {
	e := e2e_start(r9_lines(2000))
	defer e2e_stop(&e)
	ft_lua(&e.ed, `
		qed.ui.mount("pane", qed.ui.box{float = "screen", anchor = "bottom_right", width = 30, height = 8,
			qed.ui.editor{id = "r9_second", buffer = qed.buf.current()}})
		return 0`)
	e2e_render(&e)
	editor_goto(&e.ed, 1499, 0)
	view := main_view(&e)
	node := ui_find(&e.ed.ui, "#layout/main_editor")
	testing.expectf(t, abs(1499 - view.scroll_row - node.rect.h / 2) <= 1, "the main view centres: top %d", view.scroll_row)
	second := ui_find(&e.ed.ui, "#fthelper/r9_second")
	testing.expect(t, second != nil && !ui_node_state_peek(&e.ed.ui, second).center, "the other view of the buffer is not told to centre")
}

@(test)
e2e_round9_a_jump_into_a_just_opened_file_centres :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_render(&e)
	path := fmt.tprintf("%s.other.txt", e.path)
	_ = os.write_entire_file(path, transmute([]u8)r9_lines(2000))
	defer os.remove(path)
	testing.expect(t, editor_open_path(&e.ed, path), "opens")
	editor_goto(&e.ed, 1499, 0)
	e2e_ui_settle(&e)
	view := main_view(&e)
	node := ui_find(&e.ed.ui, "#layout/main_editor")
	testing.expectf(t, abs(1499 - view.scroll_row - node.rect.h / 2) <= 1, "centred once the view shows it: top %d", view.scroll_row)

}

@(test)
e2e_round9_follow_scrolls_start_at_their_end :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	ft_lua(&e.ed, `
		local rows = {}
		for i = 1, 50 do rows[i] = qed.ui.text{"follow row " .. i} end
		qed.ui.mount("pane", qed.ui.box{float = "screen", width = 30, height = 8,
			qed.ui.scroll{id = "r9_follow", follow = true, qed.ui.column(rows)}})
		return 0`)
	e2e_render(&e)
	e2e_render(&e)
	testing.expect(t, e2e_ui_find_row(&e, "follow row 50") >= 0, "a follow scroll opens on its last row")
}

@(test)
e2e_round9_log_reopens_at_the_end_after_a_scroll :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	for i in 0 ..< 200 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %04d", i), show = false)
	}
	e2e_step(&e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	y := e2e_ui_find_row(&e, "entry 0199")
	testing.expect(t, y >= 0, "opens at the end")
	for _ in 0 ..< 5 {
		e2e_mouse(&e, 20, y, .Mouse_Wheel_Up)
	}
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "entry 0199") < 0, "scrolled up")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	e2e_step(&e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "entry 0199") >= 0, "reopens at the end")
	editor_log(&e.ed, .Info, "", "late arrival", show = false)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "late arrival") >= 0, "and follows new entries")
}

@(private = "file")
R9_SWAP :: `return {setup = function()
	local ui = qed.ui
	local view
	local function build(list)
		return ui.box{id = "swap_box", float = "screen", width = 30, height = 10, scope = "list",
			ui.column{
				ui.editor{id = "swap_query", buffer = view.query, height = 1, scope = "editor"},
				ui.virtual_column{id = "swap_rows", data = list, item = function(record) return ui.text{record.name} end}}}
	end
	local function list_of(prefix)
		local list = qed.list.new{key = "name"}
		for i = 1, 5 do list:append{name = prefix .. i} end
		return list
	end
	qed.command{name = "Swap Open", run = function(ctx)
		view = {query = qed.buf.create{internal = true}, mode = ctx and ctx.line or "replace"}
		view.handle = ui.mount("pane", build(list_of("old ")))
		view.query:on("change", function()
			if view.mode == "unmount" then
				view.handle:unmount()
			else
				view.handle:update(build(list_of("new ")))
			end
		end)
		ui.node("swap_query"):focus()
	end}
	qed.command{name = "Swap Unmounting", run = function() view.mode = "unmount" end}
end}`

@(test)
e2e_round9_a_command_after_a_tree_swap_acts_on_the_new_tree :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "swap", R9_SWAP)
	ft_run(&e.ed, "Swap Open")
	e2e_ui_settle(&e)
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'x'})
	editor_dispatch(&e.ed, tb2.Event{type = .Key, key = .Arrow_Down})
	e2e_ui_settle(&e)
	rows := ui_find(&e.ed.ui, "#swap/swap_rows")
	testing.expect(t, rows != nil, "the replaced tree is mounted")
	if rows != nil {
		testing.expect_value(t, ui_node_state_peek(&e.ed.ui, rows).highlighted, "new 1")
	}
	ft_run(&e.ed, "Swap Unmounting")
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'y'})
	editor_dispatch(&e.ed, tb2.Event{type = .Key, key = .Arrow_Down})
	e2e_ui_settle(&e)
	testing.expect(t, ui_find(&e.ed.ui, "#swap/swap_rows") == nil, "the change handler unmounted the pane; Down had nothing to act on")
}

@(test)
e2e_round9_drag_selects_rows_only_in_range_lists :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	for i in 0 ..< 10 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %d", i), show = false)
	}
	e2e_step(&e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	from_y := e2e_ui_find_row(&e, "entry 3")
	to_y := e2e_ui_find_row(&e, "entry 6")
	testing.expect(t, from_y >= 0 && to_y > from_y, "the rows show")
	e2e_mouse(&e, 30, from_y)
	e2e_mouse(&e, 30, to_y, motion = true)
	e2e_mouse(&e, 30, to_y, .Mouse_Release)
	e2e_ui_settle(&e)
	rows := ui_find(&e.ed.ui, "#log/log_rows")
	state := ui_node_state_peek(&e.ed.ui, rows)
	list := ui_list_find(&e.ed.ui, rows.list)
	from_at, _ := ui_list_position(list, state.extend_from)
	to_at, _ := ui_list_position(list, state.highlighted)
	testing.expect_value(t, to_at - from_at, 3)
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, palette_open_now(&e), "the palette opens")
	e2e_render(&e)
	box := node_rect(&e.ed, "palette")
	e2e_mouse(&e, box.x + 4, box.y + 2)
	e2e_mouse(&e, box.x + 4, box.y + 5, motion = true)
	e2e_mouse(&e, box.x + 4, box.y + 5, .Mouse_Release)
	results := ui_find(&e.ed.ui, "#palette/palette_results")
	testing.expect_value(t, ui_node_state_peek(&e.ed.ui, results).extend_from, "")
}

@(test)
e2e_round9_markdown_renders_in_steps :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	saved := md_slice_ms
	md_slice_ms = 0
	defer md_slice_ms = saved
	ft_lua(&e.ed, `
		local parts = {}
		for i = 1, 400 do parts[#parts + 1] = ("## Part %d\n\nsome *text* for part %d with a [link](#part-1)\n"):format(i, i) end
		_G.r9_md = table.concat(parts, "\n")
		qed.ui.mount("pane", qed.ui.box{float = "screen", width = 60, height = 20,
			qed.ui.scroll{id = "r9_md_scroll", qed.markdown.parse(r9_md, {id = "r9_md"})}})
		return 0`)
	e2e_render(&e)
	md := e.ed.ui.markdowns["#fthelper/r9_md"]
	testing.expect(t, md != nil && md.job != nil, "a render past its slice keeps going in steps")
	testing.expect(t, !e2e_grid_has(&e, "Part 1"), "nothing shows before the first render lands")
	for i := 0; i < 5000 && md.job != nil; i += 1 {
		e2e_render(&e)
	}
	testing.expect(t, md.job == nil, "the render finishes")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Part 1"), "the document shows once rendered")
	whole := md_render(md.source, md.w, .Plain)
	testing.expect_value(t, len(md.lines), len(whole))
}

@(test)
e2e_round9_settings_picks_a_plugin_declared_choice :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "choicey", `return {setup = function()
		qed.options({mode = "beta"}, {mode = {description = "A mode", choices = {"alpha", "beta", "gamma"}}})
	end}`)
	ft_run(&e.ed, "Settings: Open")
	e2e_ui_settle(&e)
	e2e_type(&e, "choicey.mode")
	e2e_ui_settle(&e)
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	dialog, asked := test_dialog(&e.ed)
	testing.expect(t, asked && dialog.kind == "pick", "Enter on a choices option opens a pick")
	testing.expect_value(t, len(dialog.labels), 3)
	testing.expect_value(t, dialog.selected, "beta")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	e2e_key(&e, .Esc)
}

@(test)
e2e_round9_set_root_return_contract :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	os.make_directory(fmt.tprintf("%s/sub", e.dir))
	editor_buffer(&e.ed).modified = true
	testing.expect_value(t, ft_lua(&e.ed, `local ok, err = qed.set_root(qed.root()); return tostring(ok) .. " " .. tostring(err)`), "true nil")
	testing.expect(t, strings.has_prefix(ft_lua(&e.ed, `local ok, err = qed.set_root("nope"); return tostring(ok) .. " " .. tostring(err)`), "nil not a directory: "), "a missing directory")
	testing.expect_value(t, ft_lua(&e.ed, `
		local ok, err, info = qed.set_root("sub")
		return ("%s %s %d %s"):format(tostring(ok), tostring(err), #info.bufs, qed.root() == qed.root() and "kept" or "")`), "nil unsaved 1 kept")
	testing.expect_value(t, e.ed.working_root, e.dir)
	testing.expect_value(t, ft_lua(&e.ed, `
		local _, _, info = qed.set_root("sub")
		local ok = qed.set_root("sub", {discard = info.bufs})
		return tostring(ok)`), "true")
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/sub", e.dir))
}

@(test)
e2e_round9_a_borrowed_bind_follows_the_core_command :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	core := -1
	for c, i in commands {
		if c.name == "Copy" {
			core = i
		}
	}
	testing.expect(t, core >= 0, "the core Copy command")
	if core < 0 {
		return
	}
	saved := commands[core].shortcut
	commands[core].shortcut = "Ctrl+b"
	defer {
		commands[core].shortcut = saved
		plugins_rebind(&e.ed)
	}
	plugins_rebind(&e.ed)
	log_copy := ""
	for cmd in e.ed.plugins.commands {
		if cmd.owner == "log" && cmd.config_name == "Copy" {
			log_copy = cmd.shortcut
		}
	}
	testing.expect_value(t, log_copy, "Ctrl+b")
}

@(test)
e2e_round9_log_eviction_keeps_the_selection :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	for i in 0 ..< LOG_MAX {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %04d", i), show = false)
	}
	e2e_step(&e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	for _ in 0 ..< 5 {
		e2e_key(&e, .Arrow_Up)
	}
	rows := ui_find(&e.ed.ui, "#log/log_rows")
	list := ui_list_find(&e.ed.ui, rows.list)
	picked := strings.clone(ui_node_state_peek(&e.ed.ui, rows).highlighted, context.temp_allocator)
	picked_text := strings.clone(list.texts[picked] or_else "", context.temp_allocator)
	for i in 0 ..< 20 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("late %d", i), show = false)
	}
	e2e_ui_settle(&e)
	testing.expect_value(t, ui_node_state_peek(&e.ed.ui, rows).highlighted, picked)
	_, present := ui_list_position(list, picked)
	testing.expect(t, present, "the selected entry is still listed after the oldest were evicted")
	testing.expect(t, e2e_ui_find_row(&e, "entry 0994") >= 0, "the view stays on the selection")
	_ = picked_text
}

@(test)
e2e_round9_log_follows_again_after_reopening_a_parked_view :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	for i in 0 ..< 200 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %04d", i), show = false)
	}
	e2e_step(&e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	for _ in 0 ..< 3 {
		e2e_key(&e, .Arrow_Up)
	}
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	e2e_step(&e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(&e)
	for i in 0 ..< 30 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("burst %02d", i), show = false)
	}
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "burst 29") >= 0, "reopened on the last row, the log follows a burst again")
}
