package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
r6_lines :: proc(count: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 1 ..= count {
		fmt.sbprintf(&sb, "line %d\n", i)
	}
	return strings.to_string(sb)
}

@(private = "file")
r6_preview :: proc(e: ^E2E, identity: string) -> (node: ^UiNode, buffer: ^Buffer) {
	// past the preview debounce
	e2e_pump_while(e, proc(e: ^E2E) -> bool {return len(e.ed.plugins.timers) > 0}, 300)
	e2e_ui_settle(e)
	e2e_render(e)
	node = ui_find(&e.ed.ui, identity)
	if node != nil && node.kind == .Editor {
		buffer = ui_buffer(&e.ed, node.buffer)
	}
	return
}

@(private = "file")
r6_pick_plugin :: proc(e: ^E2E, items: string) {
	e2e_plugin(e, "uitest", strings.concatenate({`return {setup = function()
		qed.command{name = "Pick", run = function() qed.pick{items = `, items, `} end}
	end}`}, context.temp_allocator))
	ut_run(e, "Pick")
}

@(test)
e2e_review6_pick_preview_follows_same_file_hits :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	path := fmt.tprintf("%s/hits.txt", e.ed.working_root)
	nav_write(path, r6_lines(60))
	r6_pick_plugin(&e, strings.concatenate({`{{label = "a", path = `, lua_quote(path), `, pos = {row = 5}}, {label = "b", path = `, lua_quote(path), `, pos = {row = 40}}}`}, context.temp_allocator))
	_, buffer := r6_preview(&e, "#dialog/dialog_preview")
	testing.expect(t, buffer != nil && buffer.cursor.row == 4, "the first hit's row")
	e2e_key(&e, .Arrow_Down)
	_, buffer = r6_preview(&e, "#dialog/dialog_preview")
	testing.expect(t, buffer != nil && buffer.cursor.row == 39, "the second hit in the same file moves the preview")
	e2e_key(&e, .Esc)
}

@(test)
e2e_review6_disk_preview_reaches_deep_rows :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	path := fmt.tprintf("%s/big.txt", e.ed.working_root)
	nav_write(path, r6_lines(20000))
	r6_pick_plugin(&e, strings.concatenate({`{{label = "deep", path = `, lua_quote(path), `, pos = {row = 15000}}}`}, context.temp_allocator))
	_, buffer := r6_preview(&e, "#dialog/dialog_preview")
	testing.expect(t, buffer != nil, "a preview")
	if buffer != nil {
		testing.expect_value(t, buffer.cursor.row, 14999)
		testing.expect_value(t, string(buffer.lines[buffer.cursor.row].text[:]), "line 15000")
		last := string(buffer.lines[len(buffer.lines) - 2].text[:])
		testing.expect(t, strings.has_prefix(last, "line ") && len(last) > 6, "the read stops at a whole line")
	}
	e2e_key(&e, .Esc)
}

@(test)
e2e_review6_goto_preview_is_the_live_buffer :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	path := fmt.tprintf("%s/main.txt", e.ed.working_root)
	nav_write(path, r6_lines(20000))
	editor_reload_buffer(&e.ed, editor_buffer(&e.ed))
	b := editor_buffer(&e.ed)
	buffer_insert(b, {0, 0}, "edited ")
	b.cursor = {14999, 0}
	e2e_key(&e, .Ctrl_G)
	_, preview := r6_preview(&e, "#goto/goto_preview")
	testing.expect(t, preview != nil, "a preview")
	if preview != nil {
		testing.expect_value(t, string(preview.lines[0].text[:]), "edited line 1")
		testing.expect_value(t, preview.cursor.row, 14999)
		testing.expect_value(t, string(preview.lines[preview.cursor.row].text[:]), "line 15000")
	}
	testing.expect_value(t, goto_state(&e.ed).selected, "line 15000")
	e2e_key(&e, .Esc)
}

@(test)
e2e_review6_image_previews_as_an_image :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	path := fmt.tprintf("%s/pic.png", e.ed.working_root)
	nav_write(path, "\x89PNG\r\n\x1a\n not decoded")
	r6_pick_plugin(&e, strings.concatenate({`{{label = "pic", path = `, lua_quote(path), `}}`}, context.temp_allocator))
	node, _ := r6_preview(&e, "#dialog/dialog_preview")
	testing.expect(t, node != nil && node.kind == .Image, "an image file previews through ui.image")
	e2e_key(&e, .Esc)
}

@(test)
e2e_review6_tree_filter_survives_a_rewalk :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	for i in 0 ..< 12 {
		nav_write(fmt.tprintf("%s/zq%02d.txt", e.ed.working_root, i), "z")
	}
	nav_alt(&e, 'f')
	e2e_type(&e, "zq")
	testing.expect_value(t, len(ft_entries(&e.ed)), 12)
	walk_refresh(&e.ed, ft_walk(&e.ed))
	e2e_type(&e, "0")
	walk_trees_settle(&e.ed)
	list := ft_tree_list(&e.ed)
	testing.expect(t, len(list.tree.source.entries) > 0, "the last candidates serve the filter while the walk reruns")
	testing.expect(t, !walk_trees_busy(&e.ed), "no tree spins waiting for the rewalk")
	testing.expect_value(t, len(ft_entries(&e.ed)), 11)
	e2e_key(&e, .Esc)
	e2e_key(&e, .Esc)
}

@(test)
e2e_review6_tree_lists_die_with_their_tab :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	nav_alt(&e, 'f')
	for _ in 0 ..< 4 {
		nav_alt(&e, '.')
	}
	e2e_render(&e)
	e2e_render(&e)
	trees := 0
	for list in e.ed.ui.lists {
		trees += int(list.tree != nil)
	}
	testing.expect_value(t, trees, 1)
	e2e_key(&e, .Esc)
}

@(test)
e2e_review6_modified_preview_frees_its_snapshot :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	path := fmt.tprintf("%s/main.txt", e.ed.working_root)
	b := editor_buffer(&e.ed)
	buffer_insert(b, {0, 0}, "changed ")
	r6_pick_plugin(&e, strings.concatenate({`{{label = "m", path = `, lua_quote(path), `}}`}, context.temp_allocator))
	_, buffer := r6_preview(&e, "#dialog/dialog_preview")
	testing.expect(t, buffer != nil && strings.has_prefix(string(buffer.lines[0].text[:]), "changed "), "the live copy")
	e2e_key(&e, .Esc)
}

@(test)
e2e_review6_run_takes_an_explicit_scope :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `return {setup = function()
		qed.command{name = "Same", run = function() qed.message("global") end}
		qed.command{name = "Same", scope = "filetree", run = function() qed.message("scoped") end}
		qed.command{name = "Go", run = function() qed.run("Uitest: Same", {scope = "filetree"}) end}
		qed.command{name = "Plain", run = function() qed.run("Uitest: Same") end}
	end}`)
	ut_run(&e, "Go")
	testing.expect_value(t, e.ed.message, "scoped")
	ut_run(&e, "Plain")
	testing.expect_value(t, e.ed.message, "global")
}
