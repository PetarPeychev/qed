package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "lib:tb2"

@(private = "file")
r7_lines :: proc(count: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 1 ..= count {
		fmt.sbprintf(&sb, "line %d with a few words\n", i)
	}
	return strings.to_string(sb)
}

@(test)
e2e_round7_long_jump_with_wrap_is_fast :: proc(t: ^testing.T) {
	e := e2e_start(r7_lines(100000))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	testing.expect(t, b.wrap, "wrap is on by default")
	e2e_render(&e)
	b.cursor = {99990, 0}
	start := time.tick_now()
	e2e_render(&e)
	ms := ms_since(start)
	testing.expectf(t, ms < 50, "a 100k-line jump renders in %.1f ms", ms)
	view := main_view(&e)
	testing.expect(t, view.scroll_row > 99000, "the view follows the cursor")
}

@(test)
e2e_round7_jumps_centre_and_keep_the_margin :: proc(t: ^testing.T) {
	e := e2e_start(r7_lines(2000))
	defer e2e_stop(&e)
	e2e_render(&e)
	editor_goto(&e.ed, 1499, 0)
	view := main_view(&e)
	node := ui_find(&e.ed.ui, "#layout/main_editor")
	height := node.rect.h
	testing.expectf(t, abs(1499 - view.scroll_row - height / 2) <= 1, "the jump target is centred: top %d, height %d", view.scroll_row, height)
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	e2e_render(&e)
	for _ in 0 ..< height - 1 {
		e2e_key(&e, .Arrow_Down)
		time.sleep(time.Duration(CURSOR_ACCEL_INTERVAL_MS + 5) * time.Millisecond)
	}
	view = main_view(&e)
	margin := min(SCROLL_MARGIN, (height - 1) / 2)
	testing.expectf(t, b.cursor.row - view.scroll_row <= height - 1 - margin, "scroll_margin rows stay below the cursor: row %d top %d", b.cursor.row, view.scroll_row)
}

@(test)
e2e_round7_editor_motions :: proc(t: ^testing.T) {
	e := e2e_start("alpha beta gamma\n\nsecond para\nmore\n\nthird")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	e2e_key(&e, .Arrow_Down, tb2.Mod.Ctrl)
	testing.expect_value(t, b.cursor.row, 1)
	e2e_key(&e, .Arrow_Down, tb2.Mod.Ctrl)
	testing.expect_value(t, b.cursor.row, 4)
	e2e_key(&e, .Arrow_Up, tb2.Mod.Ctrl)
	testing.expect_value(t, b.cursor.row, 1)
	b.cursor = {0, 0}
	e2e_key(&e, .Arrow_Right, tb2.Mod(u8(tb2.Mod.Ctrl) | u8(tb2.Mod.Shift)))
	from, to, ok := selection_range(b)
	testing.expect(t, ok && from == Cursor{0, 0} && to.col > 0, "Ctrl+Shift+Right selects a word")
	b.selection = nil
	b.cursor = {0, 6}
	e2e_key(&e, .Arrow_Right, tb2.Mod(u8(tb2.Mod.Alt) | u8(tb2.Mod.Shift)))
	from, to, ok = selection_range(b)
	testing.expect(t, ok && from == Cursor{0, 6} && to == Cursor{0, 16}, "Alt+Shift+Right selects to the line end")
	b.selection = nil
	b.cursor = {0, 0}
	e2e_key(&e, .Arrow_Down, tb2.Mod(u8(tb2.Mod.Ctrl) | u8(tb2.Mod.Shift)))
	from, to, ok = selection_range(b)
	testing.expect(t, ok && to.row == 1, "Ctrl+Shift+Down selects a paragraph")
}

@(test)
e2e_round7_mouse_words_lines_and_popups :: proc(t: ^testing.T) {
	e := e2e_start(strings.concatenate({"hello world\nsecond line\n", strings.repeat("x\n", 60, context.temp_allocator)}, context.temp_allocator))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	e2e_render(&e)
	g := editor_gutter_width(&e.ed)
	e2e_mouse(&e, g + 7, 0)
	e2e_mouse(&e, g + 7, 0)
	from, to, ok := selection_range(b)
	testing.expect(t, ok && from == Cursor{0, 6} && to == Cursor{0, 11}, "a double click selects the word")
	e2e_mouse(&e, g + 7, 0)
	from, to, ok = selection_range(b)
	testing.expect(t, ok && from == Cursor{0, 0} && to == Cursor{1, 0}, "a triple click selects the line")
	e.ed.hover_active = true
	e2e_mouse(&e, g + 2, 1)
	testing.expect(t, !e.ed.hover_active, "a click dismisses the hover")
	b.cursor = {30, 0}
	e2e_render(&e)
	top := main_view(&e).scroll_row
	e2e_mouse(&e, g + 1, 5)
	e2e_mouse(&e, g + 1, -1, motion = true)
	e2e_render(&e)
	testing.expect(t, main_view(&e).scroll_row < top, "dragging above the view scrolls up")
	saved := WHEEL_SCROLL_LINES
	WHEEL_SCROLL_LINES = 7
	defer WHEEL_SCROLL_LINES = saved
	before := main_view(&e).scroll_row
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Down)
	testing.expect_value(t, main_view(&e).scroll_row, before + 7)
}

@(test)
e2e_round7_esc_closes_inspect :: proc(t: ^testing.T) {
	e := e2e_start("int x;")
	defer e2e_stop(&e)
	e.ed.inspect.active = true
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.inspect.active, "Esc closes Inspect Tokens")
}

@(test)
e2e_round7_status_bar_shows_core_and_plugin_segments :: proc(t: ^testing.T) {
	e := e2e_start("a\nb")
	defer e2e_stop(&e)
	e2e_plugin(&e, "uitest", `return {setup = function()
		qed.command{name = "Seg", run = function() qed.status.set("branch", {text = "main*"}) end}
	end}`)
	ut_run(&e, "Seg")
	e2e_render(&e)
	row := e2e_row(&e, E2E_H - 2)
	testing.expectf(t, strings.contains(row, "main*"), "a qed.status segment draws in the layout's status row: %q", row)
	testing.expectf(t, strings.contains(row, "Spaces:4") && strings.contains(row, "1/2"), "core segments draw too: %q", row)
}
