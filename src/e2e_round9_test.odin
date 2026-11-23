package main

import "core:fmt"
import "core:encoding/json"
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
		qed.ui.mount("background", qed.ui.box{float = "screen", anchor = "bottom_right", width = 30, height = 20,
			qed.ui.editor{id = "r9_second", buffer = qed.buf.current(), scope = "editor"}})
		return 0`)
	e2e_render(&e)
	editor_goto(&e.ed, 1499, 0)
	view := main_view(&e)
	node := ui_find(&e.ed.ui, "#layout/main_editor")
	testing.expectf(t, abs(1499 - view.scroll_row - node.rect.h / 2) <= 1, "the main view centres: top %d", view.scroll_row)
	second := ui_find(&e.ed.ui, "#fthelper/r9_second")
	testing.expect(t, second != nil, "the second view is mounted")
	if second == nil {
		return
	}
	top := ui_node_state_peek(&e.ed.ui, second).scroll_row
	margin := min(SCROLL_MARGIN, (second.rect.h - 1) / 2)
	testing.expectf(t, top == 1499 - (second.rect.h - 1 - margin), "the second view keeps the margin rule, not the centre: top %d, height %d", top, second.rect.h)
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
	for i in 0 ..< 20 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("late %d", i), show = false)
	}
	e2e_ui_settle(&e)
	testing.expect_value(t, ui_node_state_peek(&e.ed.ui, rows).highlighted, picked)
	_, present := ui_list_position(list, picked)
	testing.expect(t, present, "the selected entry is still listed after the oldest were evicted")
	testing.expect(t, e2e_ui_find_row(&e, "entry 0994") >= 0, "the view stays on the selection")
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

@(private = "file")
r9_completion :: proc(e: ^E2E, labels: []string, anchor: Cursor) {
	c := &e.ed.completion
	completion_clear_items(c)
	for label, i in labels {
		append(&c.items, CompletionItem{label = strings.clone(label), insert = strings.clone(label), filter = strings.clone(label)})
		append(&c.matches, i)
	}
	c.selected, c.scroll = 0, 0
	c.anchor_row, c.anchor_col = anchor.row, anchor.col
	c.active = true
}

@(private = "file")
r9_popup :: proc(e: ^E2E) -> ^UiNode {
	e2e_render(e)
	e2e_render(e)
	return caret_popup_root(&e.ed)
}

@(test)
e2e_round9_completion_shows_new_items_of_the_same_shape :: proc(t: ^testing.T) {
	e := e2e_start("x = al\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.cursor = {0, 6}
	r9_completion(&e, {"alpha", "alpine"}, {0, 4})
	r9_popup(&e)
	testing.expect(t, e2e_grid_has(&e, "alpine"), "the first response shows")
	r9_completion(&e, {"beta_one", "beta_two"}, {0, 4})
	r9_popup(&e)
	testing.expect(t, e2e_grid_has(&e, "beta_one") && !e2e_grid_has(&e, "alpine"), "a response with the same shape still replaces the rows")
}

@(test)
e2e_round9_completion_box_stays_at_the_word :: proc(t: ^testing.T) {
	e := e2e_start("x = al\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.cursor = {0, 6}
	r9_completion(&e, {"alpha", "alpine"}, {0, 4})
	popup := r9_popup(&e)
	testing.expect(t, popup != nil, "the menu shows")
	if popup == nil {
		return
	}
	word_x := popup.rect.x
	for ch in "pi" {
		buffer_insert_text(b, fmt.tprintf("%c", ch))
		popup = r9_popup(&e)
		testing.expect(t, popup != nil && popup.rect.x == word_x, "typing keeps the box at the word start")
	}
	// wrap off, the word scrolled out on the left: the box starts at the text's left edge
	b.wrap = false
	line := strings.concatenate({strings.repeat("y", 150, context.temp_allocator), " al"}, context.temp_allocator)
	buffer_set_text(b, line)
	b.cursor = {0, len(line)}
	r9_completion(&e, {"alpha", "alpine"}, {0, 0})
	popup = r9_popup(&e)
	node := ui_find(&e.ed.ui, "#layout/main_editor")
	left := node.rect.x + node.rect.w - ui_editor_text_width(node, b)
	testing.expect(t, popup != nil && popup.rect.x == left, "a word start scrolled out puts the box at the text's left edge")
	// wrap on, the word starting on an earlier segment: the left edge too
	b.wrap = true
	b.cursor = {0, len(line)}
	popup = r9_popup(&e)
	testing.expect(t, popup != nil && popup.rect.x == left, "a word start on an earlier wrap segment puts the box at the left edge")
	// wrap on, the word on a later segment with the caret: the box starts at the word on that segment
	second := strings.concatenate({strings.repeat("y ", 60, context.temp_allocator), "al"}, context.temp_allocator)
	buffer_set_text(b, second)
	b.cursor = {0, len(second)}
	r9_completion(&e, {"alpha", "alpine"}, {0, len(second) - 2})
	popup = r9_popup(&e)
	caret_x, _, _ := ui_editor_caret_pos(&e.ed, node)
	testing.expect(t, popup != nil && popup.rect.x == caret_x - 2, "a word on the caret's later segment starts the box at the word")
}

@(test)
e2e_round9_wheel_over_completion_or_diagnostic_closes_it :: proc(t: ^testing.T) {
	e := e2e_start(strings.concatenate({"x = al\n", r9_lines(100)}, context.temp_allocator))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.cursor = {0, 6}
	r9_completion(&e, {"alpha", "alpine"}, {0, 4})
	popup := r9_popup(&e)
	top := main_view(&e).scroll_row
	e2e_mouse(&e, popup.rect.x + 2, popup.rect.y + 1, .Mouse_Wheel_Down)
	testing.expect(t, !e.ed.completion.active, "the wheel closes the menu")
	testing.expect_value(t, main_view(&e).scroll_row, top)
	append(&b.diags, Diagnostic{from = {0, 0}, to = {0, 1}, severity = 1, message = strings.clone("an error here")})
	popup = r9_popup(&e)
	testing.expect(t, popup != nil && popup.id == "caret_diagnostic", "the diagnostic box shows")
	e2e_mouse(&e, popup.rect.x + 2, popup.rect.y + 1, .Mouse_Wheel_Down)
	testing.expect(t, r9_popup(&e) == nil, "the wheel closes the diagnostic box")
	testing.expect_value(t, main_view(&e).scroll_row, top)
	b.cursor = {0, 1}
	testing.expect(t, r9_popup(&e) != nil, "it comes back once the caret moves")
}

@(test)
e2e_round9_hover_of_the_same_length_is_new_content :: proc(t: ^testing.T) {
	e := e2e_start("x\n")
	defer e2e_stop(&e)
	reply :: proc(e: ^E2E, text: string) {
		v, _ := json.parse_string(fmt.tprintf(`{{"result": {{"contents": {{"kind": "markdown", "value": "%s"}}}}}}`, text), allocator = context.temp_allocator)
		lsp_apply_hover(&e.ed, v.(json.Object))
	}
	reply(&e, "first reply")
	r9_popup(&e)
	testing.expect(t, e2e_grid_has(&e, "first reply"), "the first hover shows")
	reply(&e, "other reply")
	r9_popup(&e)
	testing.expect(t, e2e_grid_has(&e, "other reply"), "a reply of the same length replaces it")
}

@(test)
e2e_round9_a_rejected_key_keeps_the_highlight :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	ft_lua(&e.ed, `
		_G.r9_keys = qed.list.new{key = "id"}
		for i = 1, 3 do r9_keys:append{id = i, label = "item " .. i} end
		qed.ui.mount("pane", qed.ui.box{float = "screen", width = 30, height = 10,
			qed.ui.virtual_column{id = "r9_rows", data = r9_keys, item = function(record) return qed.ui.text{record.label} end}})
		qed.ui.node("r9_rows"):set_state{highlighted = 2}
		return 0`)
	e2e_render(&e)
	ft_lua(&e.ed, `qed.ui.node("r9_rows"):set_state{highlighted = "3"}; return 0`)
	testing.expect_value(t, ft_lua(&e.ed, `return qed.ui.node("r9_rows"):state().highlighted`), "2")
}

@(test)
e2e_round9_welcome_keys_respect_when :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)
	e2e_plugin(&e, "wa", `local on = false
	return {setup = function()
		qed.command{name = "Gate", key = "F6", welcome = true, when = function() return on end, run = function() qed.message("ran") end}
		qed.command{name = "Arm", run = function() on = true end}
	end}`)
	e2e_key(&e, .F6)
	e2e_ui_settle(&e)
	testing.expect(t, e.ed.message != "ran", "a welcome command whose when fails does not run")
	ft_run(&e.ed, "Arm")
	e2e_key(&e, .F6)
	e2e_ui_settle(&e)
	testing.expect_value(t, e.ed.message, "ran")
}

@(test)
e2e_round9_palette_takes_pane_scopes_from_the_commands :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "scoped", `return {setup = function()
		qed.command{name = "Only Here", scope = "scoped_pane", key = "F7", run = function() end}
		qed.command{name = "Scoped Open", run = function()
			qed.ui.mount("pane", qed.ui.box{float = "screen", width = 20, height = 3, scope = {"scoped_pane", "list"},
				qed.ui.text{id = "scoped_field", "pane"}})
			qed.ui.node("scoped_field"):focus()
		end}
	end}`)
	ft_run(&e.ed, "Scoped Open")
	e2e_ui_settle(&e)
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, palette_open_now(&e), "the palette opens over the pane")
	labels := palette_labels(&e)
	testing.expect(t, strings.contains(labels, "Only Here"), labels)
	testing.expect(t, !strings.contains(labels, "List: Next") && !strings.contains(labels, "|Next|"), "core's list scope is not offered")
}
