package main

import "core:strings"
import "core:testing"
import "lib:tb2"

ut_node :: proc(kind: UiKind, children: ..^UiNode) -> ^UiNode {
	node := new(UiNode)
	node.kind = kind
	node.owner = "test"
	for child, i in children {
		append(&node.children, child)
		append(&node.child_slots, i + 1)
	}
	return node
}

ut_text :: proc(text: string) -> ^UiNode {
	node := ut_node(.Text)
	append(&node.spans, UiSpan{text = strings.clone(text)})
	return node
}

ut_mount :: proc(e: ^E2E, root: ^UiNode, outlet := "base") -> u64 {
	handle := ui_mount_add(&e.ed, "test", outlet, root)
	e2e_render(e)
	return handle
}

@(test)
ui_column_fixed_and_grow :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_bare(&e)
	top := ut_text("top")
	middle := ut_text("middle")
	middle.grow, middle.grow_set = 1, true
	bottom := ut_text("bottom")
	bottom.height = {form = .Cells, value = 2}
	ut_mount(&e, ut_node(.Column, top, middle, bottom))
	testing.expect_value(t, top.rect, Rect{0, 0, E2E_W, 1})
	testing.expect_value(t, middle.rect, Rect{0, 1, E2E_W, E2E_H - 3})
	testing.expect_value(t, bottom.rect, Rect{0, E2E_H - 2, E2E_W, 2})
	testing.expect_value(t, e2e_row_text(&e, 0), "top")
	testing.expect_value(t, e2e_row_text(&e, E2E_H - 2), "bottom")
}

@(test)
ui_row_grow_weights_percent_and_clamp :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	a := ut_text("a")
	a.grow, a.grow_set = 1, true
	b := ut_text("b")
	b.grow, b.grow_set = 2, true
	c := ut_text("c")
	c.width = {form = .Percent, value = 25}
	d := ut_text("d")
	d.width = {form = .Percent, value = 50, max = 8}
	ut_mount(&e, ut_node(.Row, a, b, c, d))
	testing.expect_value(t, c.rect.w, 20)
	testing.expect_value(t, d.rect.w, 8)
	testing.expect_value(t, a.rect.w, 17)
	testing.expect_value(t, b.rect.w, 35)
	testing.expect_value(t, d.rect.x, 72)
	testing.expect_value(t, a.rect.h, E2E_H)
}

@(test)
ui_row_drop_hides_highest_first :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	path := ut_text(strings.repeat("p", 60, context.temp_allocator))
	branch := ut_text("branch-name")
	branch.drop = 1
	lang := ut_text("language-name")
	lang.drop = 2
	ut_mount(&e, ut_node(.Row, path, branch, lang))
	testing.expect(t, lang.hidden, "the highest drop goes first")
	testing.expect(t, !branch.hidden, "the lower drop stays while it fits")
	testing.expect_value(t, branch.rect.x, 60)
}

@(test)
ui_float_center_snap_and_margin :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	box := ut_node(.Box, ut_text("hello"))
	box.border = true
	box.float = .Screen
	box.width = {form = .Cells, value = 21}
	box.height = {form = .Fit}
	ut_mount(&e, box, "pane")
	testing.expect_value(t, box.rect, Rect{29, 10, 21, 3})
	testing.expect_value(t, e2e_cell(&e, 30, 11), 'h')

	percent := ut_text("p")
	percent.float = .Screen
	percent.width = {form = .Percent, value = 49}
	percent.height = {form = .Cells, value = 1}
	ut_mount(&e, percent, "pane")
	testing.expect_value(t, percent.rect.w, 38)
	testing.expect_value(t, percent.rect.x, 21)

	corner := ut_text("toast")
	corner.float = .Screen
	corner.anchor = .Bottom_Right
	corner.margin = {1, 1, 1, 1}
	ut_mount(&e, corner, "notification")
	testing.expect_value(t, corner.rect, Rect{E2E_W - 6, E2E_H - 2, 5, 1})
}

@(test)
ui_float_never_exceeds_area :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	big := ut_text("x")
	big.float = .Screen
	big.width = {form = .Cells, value = 500, min = 400}
	big.height = {form = .Percent, value = 100}
	big.margin = {2, 3, 2, 3}
	ut_mount(&e, big, "pane")
	testing.expect_value(t, big.rect, Rect{3, 2, E2E_W - 6, E2E_H - 4})
}

@(test)
ui_scroll_clips_and_reserves_bar :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	rows := ut_node(.Column)
	for i in 0 ..< 10 {
		row := ut_text(strings.clone(string([]u8{u8('0' + i)}), context.temp_allocator))
		append(&rows.children, row)
		append(&rows.child_slots, i + 1)
	}
	scroll := ut_node(.Scroll, rows)
	scroll.height = {form = .Cells, value = 4}
	ut_mount(&e, ut_node(.Column, scroll))
	testing.expect_value(t, rows.rect.w, E2E_W - 1)
	testing.expect_value(t, e2e_row_text(&e, 3)[:1], "3")
	testing.expect_value(t, e2e_row_text(&e, 4), "")
	ui_node_state(&e.ed.ui, scroll).offset = 8
	e2e_render(&e)
	testing.expect_value(t, ui_node_state(&e.ed.ui, scroll).offset, 6)
	testing.expect_value(t, e2e_row_text(&e, 0)[:1], "6")
	testing.expect_value(t, e2e_cell(&e, E2E_W - 1, 3), '┃')
}

@(test)
ui_text_truncates_with_ellipsis :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	long := ut_text("abcdefghij")
	long.width = {form = .Cells, value = 5}
	ut_mount(&e, ut_node(.Row, long))
	testing.expect_value(t, e2e_row_text(&e, 0), "abcd…")
}

@(test)
ui_chords :: proc(t: ^testing.T) {
	cases := []struct {
		ev:   tb2.Event,
		want: string,
	} {
		{{type = .Key, key = .Ctrl_S, mod = tb2.Mod.Ctrl}, "Ctrl+s"},
		{{type = .Key, key = .Enter, mod = tb2.Mod.Ctrl}, "Enter"},
		{{type = .Key, key = .Esc}, "Esc"},
		{{type = .Key, key = .Ctrl_H}, "Ctrl+h"},
		{{type = .Key, key = .Backspace2}, "Backspace"},
		{{type = .Key, key = .Back_Tab}, "Shift+Tab"},
		{{type = .Key, key = .Arrow_Up, mod = tb2.Mod.Shift}, "Shift+Up"},
		{{type = .Key, key = .Arrow_Left, mod = tb2.Mod(u8(tb2.Mod.Ctrl) | u8(tb2.Mod.Shift))}, "Ctrl+Shift+Left"},
		{{type = .Key, ch = 'F', mod = tb2.Mod.Alt}, "Alt+F"},
		{{type = .Key, ch = 'x'}, "x"},
		{{type = .Key, ch = ' '}, "Space"},
	}
	for c in cases {
		testing.expect_value(t, ui_chord_of_event(c.ev), c.want)
	}
	testing.expect_value(t, ui_chord_normalize("Shift+Ctrl+Left"), "Ctrl+Shift+Left")
	testing.expect_value(t, ui_chord_normalize("Ctrl+P"), "Ctrl+p")
	testing.expect_value(t, ui_chord_normalize("escape"), "Esc")
	testing.expect_value(t, ui_chord_normalize("Ctrl+Nope"), "")
	key, ok := ui_chord_named_key("Down")
	testing.expect(t, ok && key == .Arrow_Down)
	key, ok = ui_chord_named_key("Shift+Down")
	testing.expect(t, ok && key == UI_KEY_CHORD_ONLY)
	_, ok = ui_chord_named_key("Ctrl+p")
	testing.expect(t, !ok, "letters stay with the old parser")
}
