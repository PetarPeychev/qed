package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(test)
e2e_review2_inspect_draws_in_tree_mode :: proc(t: ^testing.T) {
	e := e2e_start("package main\n")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	inspect_toggle(&e.ed)
	e2e_render(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Inspect Tokens") >= 0, "Inspect draws over the layout plugin's editor")
}

@(test)
e2e_review2_shift_arrows_accelerate :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 300 {
		strings.write_string(&sb, "line\n")
	}
	e := e2e_start(strings.to_string(sb))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	e.ed.accel_tick = {}
	for _ in 0 ..< 40 {
		e2e_key(&e, .Arrow_Down, .Shift)
	}
	buffer := editor_buffer(&e.ed)
	testing.expect(t, buffer.cursor.row > 40, "held Shift+Down accelerates")
	testing.expect(t, buffer.selection != nil, "and selects")
}

@(test)
e2e_review2_horizontal_scroll_keeps_a_margin :: proc(t: ^testing.T) {
	e := e2e_start(strings.repeat("x", 300, context.temp_allocator))
	defer e2e_stop(&e)
	editor_buffer(&e.ed).wrap = false
	e2e_new_ui(&e)
	e2e_key(&e, .End)
	e2e_ui_settle(&e)
	testing.expect(t, e.ed.ui.caret_shown, "the caret shows")
	e2e_key(&e, .Home)
	e2e_ui_settle(&e)
	for _ in 0 ..< 85 {
		e2e_key(&e, .Arrow_Right)
	}
	e2e_ui_settle(&e)
	width := int(tb2.width())
	testing.expect(t, e.ed.ui.caret.x <= width - 1 - min(SCROLL_MARGIN, width / 4) + 1, "scrolling right keeps SCROLL_MARGIN columns after the caret")
}

@(test)
e2e_review2_resize_reveals_the_caret :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 100 {
		strings.write_string(&sb, "line\n")
	}
	e := e2e_start(strings.to_string(sb))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	for _ in 0 ..< 18 {
		e.ed.accel_tick = {}
		e2e_key(&e, .Arrow_Down)
	}
	e2e_ui_settle(&e)
	e2e_resize(&e, 80, 10)
	e2e_ui_settle(&e)
	testing.expect(t, e.ed.ui.caret_shown && e.ed.ui.caret.y < 10, "a shrink keeps the caret in view")
	e2e_resize(&e, 80, 24)
	e2e_ui_settle(&e)
}

@(test)
e2e_review2_orphaned_mount_drops_its_parent :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin(&e, "segment", `
return {setup = function()
	qed.command{id = "add", name = "Add", run = function() qed.ui.mount("bar_slot", qed.ui.text{"[seg]"}) end}
end}`)
	ut_run_owner(&e, "segment", "Add")
	e2e_plugin(&e, "uitest", `
local handle
return {setup = function()
	qed.command{id = "open", name = "Open", run = function()
		handle = qed.ui.mount("pane", qed.ui.row{float = "screen", anchor = "top_left", width = 40, height = 1,
			qed.ui.text{"left"}, qed.ui.outlet{id = "bar_slot"}})
	end}
	qed.command{id = "close", name = "Close", run = function() handle:unmount() end}
end}`)
	ut_run(&e, "Open")
	testing.expect(t, e2e_ui_find_row(&e, "[seg]") >= 0, "the mount shows in its outlet")
	ut_run(&e, "Close")
	for mount in e.ed.ui.mounts {
		if mount.outlet == "bar_slot" {
			testing.expect(t, mount.root.parent == nil, "the orphaned mount has no parent")
		}
	}
}

@(test)
e2e_review2_markdown_arrows_accelerate :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# Doc\n\n")
	for i in 0 ..< 200 {
		strings.write_string(&sb, fmt.tprintf("para %d\n\n", i))
	}
	e := e2e_start(strings.to_string(sb))
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	ut_run_owner(&e, "markdown", "Preview")
	offset := proc(e: ^E2E) -> int {
		e2e_ui_settle(e)
		node := ui_find(&e.ed.ui, "#markdown/markdown_scroll")
		return ui_node_state(&e.ed.ui, node).offset if node != nil else -1
	}
	testing.expect(t, e2e_pump_while(&e, proc(e: ^E2E) -> bool {
		e2e_render(e)
		node := ui_find(&e.ed.ui, "#markdown/markdown_body")
		if node == nil {
			return true
		}
		md, found := e.ed.ui.markdowns[node.identity]
		return !found || md.job != nil || len(md.lines) == 0
	}), "the preview renders")
	e2e_key(&e, .Home)
	testing.expect_value(t, offset(&e), 0)
	for _ in 0 ..< 10 {
		e.ed.accel_tick = {}
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect_value(t, offset(&e), 10)
	for _ in 0 ..< 10 {
		e.ed.accel_tick = {}
		e2e_key(&e, .Arrow_Up)
	}
	testing.expect_value(t, offset(&e), 0)
	e.ed.accel_tick = {}
	for _ in 0 ..< 30 {
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect(t, offset(&e) > 30, "held arrows accelerate like the buffer")
	e2e_key(&e, .Home)
	page := ui_find(&e.ed.ui, "#markdown/markdown_scroll").rect.h - 1
	e2e_key(&e, .Pgdn)
	e2e_key(&e, .Pgdn)
	testing.expect_value(t, offset(&e), 2 * page)
	e2e_key(&e, .End)
	testing.expect_value(t, offset(&e), ui_node_state(&e.ed.ui, ui_find(&e.ed.ui, "#markdown/markdown_scroll")).max_offset)
	e2e_key(&e, .Esc)
}
