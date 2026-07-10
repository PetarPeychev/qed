package main

import "core:testing"
import "lib:tb2"

@(test)
e2e_undo_redo_coalesced :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	e2e_type(&e, "hello world")
	testing.expect_value(t, string(b.lines[0].text[:]), "hello world")

	// A whole typed run is one coalesced group, so a single undo clears it all.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "")
	testing.expect_value(t, len(b.lines), 1)

	e2e_key(&e, .Ctrl_Y)
	testing.expect_value(t, string(b.lines[0].text[:]), "hello world")
}

@(test)
e2e_undo_compound_atomic :: proc(t: ^testing.T) {
	e := e2e_start("aaa\nbbb\nccc")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.selection = Cursor{0, 0}
	b.cursor = {1, 3}
	e2e_key(&e, .Tab)
	testing.expect_value(t, string(b.lines[0].text[:]), "    aaa")
	testing.expect_value(t, string(b.lines[1].text[:]), "    bbb")
	testing.expect_value(t, string(b.lines[2].text[:]), "ccc")

	// The block indent touched two lines but is one undo step.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "aaa")
	testing.expect_value(t, string(b.lines[1].text[:]), "bbb")
}

@(test)
e2e_selection :: proc(t: ^testing.T) {
	e := e2e_start("hello")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	e2e_key(&e, .Arrow_Right, .Shift)
	e2e_key(&e, .Arrow_Right, .Shift)
	e2e_key(&e, .Arrow_Right, .Shift)
	testing.expect(t, selection_active(b), "shift-arrows set the anchor")
	testing.expect_value(t, b.cursor.col, 3)

	e2e_render(&e)
	g := editor_gutter_width(&e.ed)
	testing.expect(t, e2e_cell_raw(&e, g + 0, 0).bg == COLOR_FG, "selected cell inverted")
	testing.expect(t, e2e_cell_raw(&e, g + 1, 0).bg == COLOR_FG, "selected cell inverted")
	testing.expect(t, e2e_cell_raw(&e, g + 2, 0).bg == COLOR_FG, "selected cell inverted")
	testing.expect(t, e2e_cell_raw(&e, g + 3, 0).bg != COLOR_FG, "unselected cell normal")

	// A plain move collapses the selection to its far end.
	e2e_key(&e, .Arrow_Right)
	testing.expect(t, !selection_active(b), "plain move clears the selection")
	testing.expect_value(t, b.cursor.col, 3)

	b.cursor = {0, 0}
	e2e_key(&e, .Arrow_Right, .Shift)
	e2e_key(&e, .Arrow_Right, .Shift)
	e2e_key(&e, .Arrow_Right, .Shift)
	e2e_type(&e, "X")
	testing.expect_value(t, string(b.lines[0].text[:]), "Xlo")
}

@(test)
e2e_block_indent_dedent :: proc(t: ^testing.T) {
	e := e2e_start("foo\nbar")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.selection = Cursor{0, 0}
	b.cursor = {1, 3}
	e2e_key(&e, .Tab)
	testing.expect_value(t, string(b.lines[0].text[:]), "    foo")
	testing.expect_value(t, string(b.lines[1].text[:]), "    bar")

	// Shift+Tab is the exact inverse of the block indent.
	e2e_key(&e, .Back_Tab)
	testing.expect_value(t, string(b.lines[0].text[:]), "foo")
	testing.expect_value(t, string(b.lines[1].text[:]), "bar")
}

@(test)
e2e_tabstop_backspace :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	e2e_key(&e, .Tab)
	e2e_key(&e, .Tab)
	testing.expect_value(t, string(b.lines[0].text[:]), "        ")
	testing.expect_value(t, b.cursor.col, 8)

	// Backspace in leading whitespace deletes a whole indent back to the tab stop.
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, string(b.lines[0].text[:]), "    ")
	testing.expect_value(t, b.cursor.col, 4)

	e2e_key(&e, .Backspace2)
	testing.expect_value(t, string(b.lines[0].text[:]), "")
	testing.expect_value(t, b.cursor.col, 0)
}

@(test)
e2e_autoindent :: proc(t: ^testing.T) {
	e := e2e_start("if x {")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.cursor = {0, 6}
	e2e_key(&e, .Enter)
	testing.expect_value(t, string(b.lines[0].text[:]), "if x {")
	testing.expect_value(t, string(b.lines[1].text[:]), "    ")
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, 4)
}

@(test)
e2e_autoindent_split :: proc(t: ^testing.T) {
	e := e2e_start("if x {}")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	// Enter between a matched pair splits it and aligns the closer under the opener.
	b.cursor = {0, 6}
	e2e_key(&e, .Enter)
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, string(b.lines[0].text[:]), "if x {")
	testing.expect_value(t, string(b.lines[1].text[:]), "    ")
	testing.expect_value(t, string(b.lines[2].text[:]), "}")
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, 4)
}

@(test)
e2e_autoindent_python_colon :: proc(t: ^testing.T) {
	e := e2e_start("if x:")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.language = .Python // per-buffer only; no global mutation, no LSP spawn in e2e

	b.cursor = {0, 5}
	e2e_key(&e, .Enter)
	testing.expect_value(t, string(b.lines[0].text[:]), "if x:")
	testing.expect_value(t, string(b.lines[1].text[:]), "    ")
	testing.expect_value(t, b.cursor.col, 4)
}

@(test)
e2e_autoindent_close_realign :: proc(t: ^testing.T) {
	e := e2e_start("{\n    ")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	// A typed closer on an all-blank line re-aligns to its opener's indentation.
	b.cursor = {1, 4}
	e2e_type(&e, "}")
	testing.expect_value(t, string(b.lines[0].text[:]), "{")
	testing.expect_value(t, string(b.lines[1].text[:]), "}")
	testing.expect_value(t, b.cursor.col, 1)
}

@(test)
e2e_pairs :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	e2e_type(&e, "(")
	testing.expect_value(t, string(b.lines[0].text[:]), "()")
	testing.expect_value(t, b.cursor.col, 1)

	// Typing the closer over the auto-inserted one just steps past it.
	e2e_type(&e, ")")
	testing.expect_value(t, string(b.lines[0].text[:]), "()")
	testing.expect_value(t, b.cursor.col, 2)
}

@(test)
e2e_pairs_backspace :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	e2e_type(&e, "\"")
	testing.expect_value(t, string(b.lines[0].text[:]), "\"\"")
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, string(b.lines[0].text[:]), "")

	e2e_type(&e, "`")
	testing.expect_value(t, string(b.lines[0].text[:]), "``")
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, string(b.lines[0].text[:]), "")
}

@(test)
e2e_pairs_surround :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.selection = Cursor{0, 0}
	b.cursor = {0, 3}
	e2e_type(&e, "(")
	testing.expect_value(t, string(b.lines[0].text[:]), "(abc)")
}

@(test)
e2e_comment_toggle :: proc(t: ^testing.T) {
	e := e2e_start("x = 1\ny = 2")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	// Plaintext's comment token is "//"; toggle is its own inverse.
	e2e_key(&e, .Ctrl_Slash)
	testing.expect_value(t, string(b.lines[0].text[:]), "// x = 1")
	e2e_key(&e, .Ctrl_Slash)
	testing.expect_value(t, string(b.lines[0].text[:]), "x = 1")

	b.selection = Cursor{0, 0}
	b.cursor = {1, 5}
	e2e_key(&e, .Ctrl_Slash)
	testing.expect_value(t, string(b.lines[0].text[:]), "// x = 1")
	testing.expect_value(t, string(b.lines[1].text[:]), "// y = 2")
}

@(test)
e2e_move_lines :: proc(t: ^testing.T) {
	e := e2e_start("one\ntwo\nthree")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.cursor = {1, 0}
	e2e_key(&e, .Arrow_Down, .Alt)
	testing.expect_value(t, string(b.lines[0].text[:]), "one")
	testing.expect_value(t, string(b.lines[1].text[:]), "three")
	testing.expect_value(t, string(b.lines[2].text[:]), "two")
	testing.expect_value(t, b.cursor.row, 2)

	e2e_key(&e, .Arrow_Up, .Alt)
	testing.expect_value(t, string(b.lines[1].text[:]), "two")
	testing.expect_value(t, string(b.lines[2].text[:]), "three")
	testing.expect_value(t, b.cursor.row, 1)
}

@(test)
e2e_move_lines_block :: proc(t: ^testing.T) {
	e := e2e_start("a\nb\nc\nd")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.selection = Cursor{0, 0}
	b.cursor = {1, 1}
	e2e_key(&e, .Arrow_Down, .Alt)
	testing.expect_value(t, string(b.lines[0].text[:]), "c")
	testing.expect_value(t, string(b.lines[1].text[:]), "a")
	testing.expect_value(t, string(b.lines[2].text[:]), "b")
	testing.expect_value(t, string(b.lines[3].text[:]), "d")
}

@(test)
e2e_clipboard :: proc(t: ^testing.T) {
	e := e2e_start("hello")
	defer e2e_stop(&e)
	// Force the in-process register fallback so no system tool is invoked. The
	// register is a shared global; detach it from any prior test's allocation and
	// free our own here so cross-test tracking-allocator frees don't collide.
	// These defers run before e2e_stop, while still holding e2e_lock.
	saved := clipboard_tool
	saved_reg := clipboard_register
	clipboard_tool = .None
	clipboard_register = ""
	defer {
		delete(clipboard_register)
		clipboard_register = saved_reg
		clipboard_tool = saved
	}
	b := editor_buffer(&e.ed)

	b.selection = Cursor{0, 0}
	b.cursor = {0, 5}
	e2e_key(&e, .Ctrl_C)
	testing.expect_value(t, clipboard_register, "hello")

	e2e_key(&e, .Ctrl_X)
	testing.expect_value(t, clipboard_register, "hello")
	testing.expect_value(t, string(b.lines[0].text[:]), "")

	e2e_key(&e, .Ctrl_V)
	testing.expect_value(t, string(b.lines[0].text[:]), "hello")
}

@(test)
e2e_clipboard_whole_line :: proc(t: ^testing.T) {
	e := e2e_start("aaa\nbbb")
	defer e2e_stop(&e)
	saved := clipboard_tool
	saved_reg := clipboard_register
	clipboard_tool = .None
	clipboard_register = ""
	defer {
		delete(clipboard_register)
		clipboard_register = saved_reg
		clipboard_tool = saved
	}
	b := editor_buffer(&e.ed)

	// With no selection, copy/cut act on the whole line (trailing newline kept).
	b.cursor = {0, 1}
	e2e_key(&e, .Ctrl_C)
	testing.expect_value(t, clipboard_register, "aaa\n")

	e2e_key(&e, .Ctrl_X)
	testing.expect_value(t, clipboard_register, "aaa\n")
	testing.expect_value(t, len(b.lines), 1)
	testing.expect_value(t, string(b.lines[0].text[:]), "bbb")
}

@(test)
e2e_motion_word_paragraph :: proc(t: ^testing.T) {
	e := e2e_start("foo bar baz\n\nqux")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	e2e_key(&e, .Arrow_Right, .Ctrl)
	testing.expect_value(t, b.cursor.col, 3)
	e2e_key(&e, .Arrow_Right, .Ctrl)
	testing.expect_value(t, b.cursor.col, 4)
	// Word motion stops at every class boundary: left off "bar" lands on the space.
	e2e_key(&e, .Arrow_Left, .Ctrl)
	testing.expect_value(t, b.cursor.col, 3)
	e2e_key(&e, .Arrow_Left, .Ctrl)
	testing.expect_value(t, b.cursor.col, 0)

	// Ctrl+Down/Up jump between blank-line paragraph boundaries.
	e2e_key(&e, .Arrow_Down, .Ctrl)
	testing.expect_value(t, b.cursor.row, 1)
	e2e_key(&e, .Arrow_Down, .Ctrl)
	testing.expect_value(t, b.cursor.row, 2)
	e2e_key(&e, .Arrow_Up, .Ctrl)
	testing.expect_value(t, b.cursor.row, 1)
}

@(test)
e2e_motion_smart_and_buffer :: proc(t: ^testing.T) {
	e := e2e_start("    hello\nmid\nlast")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.cursor = {0, 9}
	e2e_key(&e, .Arrow_Left, .Alt)
	testing.expect_value(t, b.cursor.col, 4)
	e2e_key(&e, .Arrow_Left, .Alt)
	testing.expect_value(t, b.cursor.col, 0)
	e2e_key(&e, .Arrow_Right, .Alt)
	testing.expect_value(t, b.cursor.col, 9)

	// Alt+}/{ jump to buffer end/start.
	e2e_key(&e, .Arrow_Left, .Alt, '}')
	testing.expect_value(t, b.cursor.row, 2)
	testing.expect_value(t, b.cursor.col, 4)
	e2e_key(&e, .Arrow_Left, .Alt, '{')
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 0)
}

@(test)
e2e_motion_goal_column :: proc(t: ^testing.T) {
	e := e2e_start("longlongline\nx\nanotherlong")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.cursor = {0, 10}
	cursor_goal_sync(b)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, 1) // clamped onto the short line

	// The goal column survives the short line and is restored below.
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 2)
	testing.expect_value(t, b.cursor.col, 10)
}

@(test)
e2e_bracket_underline :: proc(t: ^testing.T) {
	e := e2e_start("(x)")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	b.cursor = {0, 0}
	e2e_render(&e)
	g := editor_gutter_width(&e.ed)
	partner := e2e_cell_raw(&e, g + 2, 0)
	testing.expect_value(t, rune(partner.ch), ')')
	testing.expect(
		t,
		(u64(partner.fg) & u64(tb2.Color.Underline)) != 0,
		"matching bracket partner cell is underlined",
	)
}

@(test)
e2e_unicode_cluster :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	// "e" + combining acute (U+0301) is one grapheme (3 bytes) of display width 1.
	e2e_type(&e, "éx")
	testing.expect_value(t, b.cursor.col, 4)

	e2e_render(&e)
	g := editor_gutter_width(&e.ed)
	testing.expect_value(t, e2e_cell(&e, g + 0, 0), 'e')
	testing.expect_value(t, e2e_cell(&e, g + 1, 0), 'x') // trailing glyph after a 1-wide cluster

	// Backspace steps whole clusters, not bytes.
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, string(b.lines[0].text[:]), "é")
	testing.expect_value(t, b.cursor.col, 3)
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, string(b.lines[0].text[:]), "")
}
