package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(private = "file")
e2e_log_screen :: proc(e: ^E2E) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for y in 0 ..< E2E_H {
		for x in 0 ..< E2E_W {
			strings.write_rune(&sb, e2e_cell(e, x, y))
		}
		strings.write_rune(&sb, '\n')
	}
	return strings.to_string(sb)
}

// Row y and starting column of the first occurrence of `needle`, or (-1, -1).
@(private = "file")
e2e_log_find :: proc(e: ^E2E, needle: string) -> (row, col: int) {
	for y in 0 ..< E2E_H {
		sb := strings.builder_make(context.temp_allocator)
		for x in 0 ..< E2E_W {
			strings.write_rune(&sb, e2e_cell(e, x, y))
		}
		if idx := strings.index(strings.to_string(sb), needle); idx >= 0 {
			return y, idx
		}
	}
	return -1, -1
}

@(test)
e2e_log_pane_renders_and_copies :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	// A background error entry (not shown on the line) plus a toggle confirmation.
	editor_log(&e.ed, .Error, "LSP", "boom", show = false)
	cmd_toggle_format_on_save(&e.ed)
	testing.expect(t, strings.contains(e.ed.message, "Format on save"), "toggle sets the message line")

	cmd_message_log(&e.ed)
	testing.expect(t, e.ed.logview.active, "command opens the log pane")
	e2e_render(&e)

	screen := e2e_log_screen(&e)
	testing.expect(t, strings.contains(screen, "Message Log"), "pane title renders")
	testing.expect(t, strings.contains(screen, "LSP: boom"), "error entry row renders")
	testing.expect(t, strings.contains(screen, "Format on save"), "info entry row renders")

	// The error row (not the selected last row) paints with the error colour.
	ey, ex := e2e_log_find(&e, "LSP: boom")
	testing.expect(t, ey >= 0, "found the error row")
	testing.expect_value(t, e2e_cell_fg(&e, ex, ey), COLOR_ERROR_FG)

	// Select the error row and copy it; the headless gate routes it to the register
	// (no tool spawned) and the confirmation lands on the message line.
	saved_reg := clipboard_register
	clipboard_register = ""
	defer {
		delete(clipboard_register)
		clipboard_register = saved_reg
	}
	e2e_key(&e, .Arrow_Up)
	e2e_render(&e)
	sy, sx := e2e_log_find(&e, "LSP: boom")
	testing.expect_value(t, e2e_cell_fg(&e, sx, sy), COLOR_ERROR_FG)
	testing.expect_value(t, e2e_cell_bg(&e, sx, sy), COLOR_PANE_SEL_BG)
	e2e_key(&e, .Ctrl_C)
	testing.expect_value(t, e.ed.message, "Copied to clipboard")
	testing.expect_value(t, clipboard_register, "LSP: boom")
}

@(test)
e2e_log_bind_toggles :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	e2e_alt(&e, 'l')
	testing.expect(t, e.ed.logview.active, "Alt+l opens the log pane")
	e2e_alt(&e, 'l')
	testing.expect(t, !e.ed.logview.active, "Alt+l again closes it")
	e2e_alt(&e, 'l')
	testing.expect(t, e.ed.logview.active, "and a third press reopens it")
}

@(test)
e2e_log_rebound_bind_toggles :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	idx := -1
	for cmd, i in commands {
		if cmd.name == "Debug: Message Log" {
			idx = i
			break
		}
	}
	testing.expect(t, idx >= 0, "command exists in the table")
	saved := commands[idx].alt_ch
	commands[idx].alt_ch = 'j'
	defer commands[idx].alt_ch = saved

	e2e_alt(&e, 'j')
	testing.expect(t, e.ed.logview.active, "rebound chord opens the pane")
	e2e_alt(&e, 'l')
	testing.expect(t, e.ed.logview.active, "the old chord no longer closes it")
	e2e_alt(&e, 'j')
	testing.expect(t, !e.ed.logview.active, "rebound chord closes it")
	e2e_alt(&e, 'l')
	testing.expect(t, !e.ed.logview.active, "the old chord no longer opens it")
}

@(test)
e2e_log_multiselect_copy :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved_reg := clipboard_register
	clipboard_register = ""
	defer {
		delete(clipboard_register)
		clipboard_register = saved_reg
	}

	editor_log(&e.ed, .Info, "", "one", show = false)
	editor_log(&e.ed, .Error, "Git", "two", show = false)
	editor_log(&e.ed, .Info, "", "three", show = false)
	cmd_message_log(&e.ed)

	e2e_key(&e, .Arrow_Up, mod = .Shift)
	e2e_key(&e, .Arrow_Up, mod = .Shift)
	e2e_render(&e)
	oy, ox := e2e_log_find(&e, "one")
	ey, ex := e2e_log_find(&e, "Git: two")
	ty, tx := e2e_log_find(&e, "three")
	testing.expect(t, oy >= 0 && ey >= 0 && ty >= 0, "all three rows render")
	testing.expect_value(t, e2e_cell_bg(&e, ox, oy), COLOR_PANE_SEL_BG)
	testing.expect_value(t, e2e_cell_bg(&e, ex, ey), COLOR_PANE_SEL_BG)
	testing.expect_value(t, e2e_cell_bg(&e, tx, ty), COLOR_PANE_SEL_BG)
	testing.expect_value(t, e2e_cell_fg(&e, ex, ey), COLOR_ERROR_FG)

	e2e_key(&e, .Ctrl_C)
	testing.expect_value(t, clipboard_register, "one\nGit: two\nthree")
	testing.expect_value(t, e.ed.message, "Copied 3 entries")

	e2e_key(&e, .Arrow_Down)
	testing.expect(t, e.ed.logview.anchor == nil, "plain arrow collapses the selection")
	e2e_key(&e, .Ctrl_C)
	testing.expect_value(t, clipboard_register, "Git: two")
	testing.expect_value(t, e.ed.message, "Copied to clipboard")

	e2e_key(&e, .Arrow_Up, mod = .Shift)
	testing.expect(t, e.ed.logview.anchor != nil, "shift re-anchors")
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'w'})
	testing.expect(t, e.ed.logview.anchor == nil, "filter toggle collapses the selection")
}

@(test)
e2e_log_debug_filter :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	editor_log(&e.ed, .Info, "", "an info line")
	// Debug never reaches the message line even with show defaulting to true.
	editor_log(&e.ed, .Debug, "LSP", "a trace line")
	testing.expect_value(t, e.ed.message, "an info line")

	cmd_message_log(&e.ed)
	e2e_render(&e)
	testing.expect(t, !strings.contains(e2e_log_screen(&e), "a trace line"), "Debug hidden by default")

	// `d` toggles Debug visibility on.
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'd'})
	testing.expect(t, e.ed.logview.filter[.Debug], "d enables the Debug filter")
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_log_screen(&e), "a trace line"), "Debug row revealed")

	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.logview.active, "Esc closes the pane")
	cmd_message_log(&e.ed)
	testing.expect(t, e.ed.logview.filter[.Debug], "Debug filter persists on reopen")
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_log_screen(&e), "a trace line"), "Debug still visible after reopen")
}

@(test)
e2e_log_wheel_scroll_and_thumb :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	for i in 0 ..< 30 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %02d", i), show = false)
	}
	cmd_message_log(&e.ed)
	e2e_render(&e)

	v := &e.ed.logview
	lay := logview_layout(&e.ed)
	h := logview_body_h(&e.ed)
	n := len(logview_filtered(&e.ed))
	border_x := lay.box.x + lay.box.w - 1
	testing.expect(t, n > h + WHEEL_SCROLL_LINES, "the log should overflow the pane")
	testing.expect_value(t, v.scroll, n - h)

	bottom_start, length := pane_scrollbar_thumb(v.scroll, h, n)
	testing.expect(t, length > 0, "an overflowing log shows a thumb")
	testing.expect_value(t, e2e_cell(&e, border_x, lay.body_top + bottom_start), '┃')
	testing.expect_value(t, e2e_cell(&e, border_x, lay.body_top), '│')

	e2e_mouse(&e, lay.inner.x + 2, lay.body_top + 1, .Mouse_Wheel_Up)
	e2e_render(&e)
	testing.expect(t, !v.stick, "wheel-up unsticks from the newest entry")
	testing.expect_value(t, v.scroll, n - h - WHEEL_SCROLL_LINES)
	testing.expect(t, strings.contains(e2e_row(&e, lay.body_top), fmt.tprintf("entry %02d", 30 - h - WHEEL_SCROLL_LINES)), "the top row scrolled up")

	up_start, _ := pane_scrollbar_thumb(v.scroll, h, n)
	testing.expect(t, up_start < bottom_start, "the thumb tracks the scroll upward")
	testing.expect_value(t, e2e_cell(&e, border_x, lay.body_top + up_start), '┃')

	e2e_mouse(&e, lay.inner.x + 2, lay.body_top + 1, .Mouse_Wheel_Down)
	e2e_render(&e)
	testing.expect_value(t, v.scroll, n - h)
	testing.expect(t, v.stick, "wheel-down to the end re-sticks")

	for _ in 0 ..< h {
		e2e_key(&e, .Arrow_Up)
	}
	e2e_render(&e)
	testing.expect_value(t, v.scroll, n - h - 1)
	arrow_start, _ := pane_scrollbar_thumb(v.scroll, h, n)
	testing.expect_value(t, e2e_cell(&e, border_x, lay.body_top + arrow_start), '┃')
}

@(test)
e2e_log_history_filter :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	editor_log_seed_text(
		&e.ed,
		"=== qed v0.9.0 — session started 2026-07-10 09:15:00 ===\n" +
		"2026-07-10 09:15:01 [INFO] a previous session line\n",
	)
	editor_log(&e.ed, .Info, "", "a live line")

	cmd_message_log(&e.ed)
	e2e_render(&e)
	testing.expect(t, !strings.contains(e2e_log_screen(&e), "a previous session line"), "history hidden by default")
	testing.expect(t, strings.contains(e2e_log_screen(&e), "a live line"), "live entries always show")

	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = 'h'})
	testing.expect(t, e.ed.logview.history, "h enables the history filter")
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_log_screen(&e), "a previous session line"), "history row revealed")
	testing.expect(t, strings.contains(e2e_log_screen(&e), "session started"), "old session marker revealed too")

	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.logview.active, "Esc closes the pane")
	cmd_message_log(&e.ed)
	testing.expect(t, e.ed.logview.history, "History filter persists on reopen")
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_log_screen(&e), "a previous session line"), "history still visible after reopen")
}
