package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "lib:tb2"

@(private = "file")
e2e_mouse_seq: int

// Unique scratch paths; every caller runs while holding e2e_lock (e2e_start), so
// the bare counter never races another session.
e2e_mouse_scratch :: proc(suffix: string) -> string {
	e2e_mouse_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	return fmt.aprintf("%s/qed_e2e_mouse_%d_%d%s", tmp, posix.getpid(), e2e_mouse_seq, suffix)
}

// -- Buffer mouse -----------------------------------------------------------

@(test)
e2e_mouse_drag_select :: proc(t: ^testing.T) {
	e := e2e_start("hello world")
	defer e2e_stop(&e)
	e2e_render(&e)

	b := editor_buffer(&e.ed)
	g := editor_gutter_width(&e.ed)

	// Press, then motion moves extend the selection from the press anchor.
	e2e_mouse(&e, g + 0, 0)
	testing.expect(t, !selection_active(b), "a bare press does not select")
	e2e_mouse(&e, g + 5, 0, .Mouse_Left, motion = true)
	testing.expect(t, selection_active(b), "a drag sets the anchor and selects")
	from, to, _ := selection_range(b)
	testing.expect_value(t, from.col, 0)
	testing.expect_value(t, to.col, 5)

	e2e_mouse(&e, g + 9, 0, .Mouse_Left, motion = true)
	_, to2, _ := selection_range(b)
	testing.expect_value(t, to2.col, 9)
}

@(test)
e2e_mouse_wheel_scroll :: proc(t: ^testing.T) {
	e := e2e_start(strings.repeat("x\n", 60, context.temp_allocator))
	defer e2e_stop(&e)
	e2e_render(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	g := editor_gutter_width(&e.ed)

	// The wheel moves the viewport; the cursor stays put.
	e2e_mouse(&e, g + 0, 3, .Mouse_Wheel_Down)
	testing.expect(t, main_view(&e).scroll_row > 0, "wheel-down scrolls the viewport")
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 0)

	e2e_mouse(&e, g + 0, 3, .Mouse_Wheel_Up)
	testing.expect_value(t, main_view(&e).scroll_row, 0)
	testing.expect_value(t, b.cursor.row, 0)
}

@(test)
e2e_mouse_wheel_coalesce :: proc(t: ^testing.T) {
	e := e2e_start(strings.repeat("x\n", 200, context.temp_allocator))
	defer e2e_stop(&e)
	e2e_render(&e)

	b := editor_buffer(&e.ed)
	g := editor_gutter_width(&e.ed)
	down := tb2.Event{type = .Mouse, key = .Mouse_Wheel_Down, x = i32(g), y = 3}
	up := down
	up.key = .Mouse_Wheel_Up

	e2e_step(&e, down, down, down, down)
	testing.expect_value(t, main_view(&e).scroll_row, 4 * WHEEL_SCROLL_LINES)
	testing.expect_value(t, e2e_peek_pos, e2e_peek_len)

	e2e_step(&e, down, down, up, tb2.Event{type = .Key, key = .Arrow_Down})
	testing.expect_value(t, main_view(&e).scroll_row, 6 * WHEEL_SCROLL_LINES - WHEEL_SCROLL_LINES)
	testing.expect_value(t, e2e_peek_pos, 2)
	testing.expect_value(t, b.cursor.row, 0)

	moved := down
	moved.y = 4
	e2e_step(&e, up, up, moved)
	testing.expect_value(t, main_view(&e).scroll_row, 5 * WHEEL_SCROLL_LINES - 2 * WHEEL_SCROLL_LINES + WHEEL_SCROLL_LINES)
}

@(test)
e2e_mouse_wheel_sideways :: proc(t: ^testing.T) {
	long := strings.repeat("x", 200, context.temp_allocator)
	e := e2e_start(fmt.tprintf("short\n\n\n%s\n%s", long, strings.repeat("y\n", 60, context.temp_allocator)))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	g_line_wrap = false
	e2e_render(&e)
	g := editor_gutter_width(&e.ed)
	node := ui_find(&e.ed.ui, "#layout/main_editor")
	width := ui_editor_text_width(node, b)
	limit := 200 - width + min(SCROLL_MARGIN, width / 4) + 1

	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Down, mod = .Alt)
	testing.expect_value(t, main_view(&e).scroll_col, WHEEL_SCROLL_COLUMNS)
	testing.expect_value(t, main_view(&e).scroll_row, 0)
	testing.expect_value(t, b.cursor, Cursor{0, 0})
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Right)
	testing.expect_value(t, main_view(&e).scroll_col, 2 * WHEEL_SCROLL_COLUMNS)
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Left)
	testing.expect_value(t, main_view(&e).scroll_col, WHEEL_SCROLL_COLUMNS)
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Up, mod = .Alt)
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Up, mod = .Alt)
	testing.expect_value(t, main_view(&e).scroll_col, 0)

	right := tb2.Event{type = .Mouse, key = .Mouse_Wheel_Right, x = i32(g + 1), y = 3}
	for _ in 0 ..< 60 {
		e2e_step(&e, right)
	}
	testing.expect_value(t, main_view(&e).scroll_col, limit)
	testing.expect_value(t, b.cursor, Cursor{0, 0})

	e2e_key(&e, .Arrow_Right)
	testing.expect_value(t, b.cursor, Cursor{0, 1})
	testing.expect_value(t, main_view(&e).scroll_col, 0)

	b.cursor = {3, 200}
	e2e_render(&e)
	testing.expect_value(t, main_view(&e).scroll_col, limit)
	e2e_step(&e, right)
	testing.expect_value(t, main_view(&e).scroll_col, limit)

	b.cursor = {0, 0}
	e2e_render(&e)
	g_line_wrap = true
	e2e_render(&e)
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Down, mod = .Alt)
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Right)
	testing.expect_value(t, main_view(&e).scroll_col, 0)
	testing.expect_value(t, main_view(&e).scroll_row, 0)
	testing.expect_value(t, main_view(&e).scroll_sub, 0)
	e2e_mouse(&e, g + 1, 3, .Mouse_Wheel_Down)
	testing.expect(t, main_view(&e).scroll_row > 0, "with wrap on the plain wheel still scrolls")
}

@(test)
e2e_mouse_triple_click_line :: proc(t: ^testing.T) {
	e := e2e_start("hello world")
	defer e2e_stop(&e)
	e2e_render(&e)

	b := editor_buffer(&e.ed)
	g := editor_gutter_width(&e.ed)

	// Three quick clicks (same thread → within DOUBLE_CLICK_MS) select the line.
	e2e_mouse(&e, g + 4, 0)
	e2e_mouse(&e, g + 4, 0)
	e2e_mouse(&e, g + 4, 0)
	testing.expect(t, selection_active(b), "triple click selects")
	from, to, _ := selection_range(b)
	testing.expect_value(t, from.col, 0)
	testing.expect_value(t, to.col, len(b.lines[0].text))
}

// -- Pane mouse -------------------------------------------------------------

// Command palette: the wheel scrolls the list.
@(test)
e2e_mouse_palette_wheel :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	e2e_key(&e, .Ctrl_P)
	testing.expect(t, palette_open_now(&e), "Ctrl+P opens the palette")
	testing.expect(t, strings.count(palette_labels(&e), "|") - 1 > PICKER_MAX_ROWS, "more commands than fit")
	box := node_rect(&e.ed, "palette")
	e2e_render(&e)
	top := e2e_row(&e, box.y + 3)

	e2e_mouse(&e, box.x + 2, box.y + 4, .Mouse_Wheel_Down)
	e2e_render(&e)
	testing.expect(t, e2e_row(&e, box.y + 3) != top, "wheel-down scrolls the palette")
	e2e_mouse(&e, box.x + 2, box.y + 4, .Mouse_Wheel_Up)
	e2e_render(&e)
	testing.expect_value(t, e2e_row(&e, box.y + 3), top)
}

// Line jump (Ctrl+G): a single click selects the row under the pointer.
@(test)
e2e_mouse_linefind_click_row :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta\ngamma\ndelta\nepsilon")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	e2e_key(&e, .Ctrl_G)
	e2e_ui_settle(&e)
	testing.expect_value(t, goto_state(&e.ed).selected, "alpha")

	rows := node_rect(&e.ed, "goto_rows")
	e2e_mouse(&e, rows.x + 1, rows.y + 2)
	e2e_ui_settle(&e)
	state := goto_state(&e.ed)
	testing.expect(t, state.open, "a single click only selects, stays open")
	testing.expect_value(t, state.selected, "gamma")
}

// Open tab (Alt+o): a double click on a row switches to that buffer, same as Enter.
@(test)
e2e_mouse_open_tab_double_click :: proc(t: ^testing.T) {
	e := e2e_root_start("first buffer")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "second buffer")
	editor_open_path(&e.ed, second)
	testing.expect_value(t, e.ed.current, 1)

	nav_alt(&e, 'o')
	testing.expect(t, filetree_active(&e.ed), "Alt+o opens the Open tab")

	lay := ft_layout(&e.ed)
	target := -1
	for entry, i in ft_entries(&e.ed) {
		if entry.name == "main.txt" {
			target = i
		}
	}
	testing.expect(t, target >= 0, "main.txt is listed in the Open tab")
	y := lay.body_top + (target - ft_scroll(&e.ed))
	e2e_mouse(&e, lay.inner.x + 1, y)
	e2e_ui_settle(&e)
	e2e_mouse(&e, lay.inner.x + 1, y)
	e2e_ui_settle(&e)
	testing.expect(t, !filetree_active(&e.ed), "double click activates and closes the tree")
	testing.expect_value(t, e.ed.current, 0)
}

// File tree (Alt+f): a click outside the box dismisses it.
@(test)
e2e_mouse_filetree_click_away :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	// An empty scratch root keeps the tree scan off the (large) real cwd.
	root := e2e_mouse_scratch("")
	os.make_directory(root)
	saved_root := e.ed.working_root
	e.ed.working_root = root
	defer {
		e.ed.working_root = saved_root
		os.remove(root)
		delete(root)
	}

	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f opens the file tree")

	// (0,0) is outside the pane box; a click there closes it.
	e2e_render(&e)
	e2e_mouse(&e, 0, 0)
	e2e_ui_settle(&e)
	testing.expect(t, !filetree_active(&e.ed), "click outside dismisses the file tree")
}

// Find bar (Ctrl+F): a click in the query field places the caret; a button-held
// drag selects text in the field.
// -- Terminal pane ----------------------------------------------------------

e2e_term_row :: proc(e: ^E2E, inner: Rect, ry: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for cx in 0 ..< inner.w {
		r := e2e_cell(e, inner.x + cx, inner.y + ry)
		strings.write_rune(&sb, r if r != 0 else ' ')
	}
	return strings.to_string(sb)
}

// The grid row whose right-trimmed content equals `exact` — the pure echo output
// line, distinct from the command-echo line that merely contains the marker.
e2e_term_find_row :: proc(e: ^E2E, exact: string) -> (sc, gy: int, ok: bool) {
	e2e_render(e)
	area := e.ed.terminal.area
	for ry in 0 ..< area.h {
		row := e2e_term_row(e, area, ry)
		if strings.trim_right(row, " ") == exact {
			return strings.index(row, exact), ry, true
		}
	}
	return 0, 0, false
}

e2e_term_wait_row :: proc(e: ^E2E, exact: string, timeout_ms: int) -> (sc, gy: int, ok: bool) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(timeout_ms) {
		term_pump(&e.ed)
		if sc, gy, ok = e2e_term_find_row(e, exact); ok {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	term_pump(&e.ed)
	return e2e_term_find_row(e, exact)
}

e2e_term_settle :: proc(e: ^E2E, ms: int) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		term_pump(&e.ed)
		time.sleep(5 * time.Millisecond)
	}
}

@(test)
e2e_terminal_pane :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	// Force the in-process clipboard register so the drag auto-copy is assertable.
	saved_tool := clipboard_tool
	saved_reg := clipboard_register
	clipboard_tool = .None
	clipboard_register = ""
	defer {
		delete(clipboard_register)
		clipboard_register = saved_reg
		clipboard_tool = saved_tool
	}

	e2e_term_alt_t(&e)
	if e.ed.terminal.shown == nil || !e.ed.terminal.shown.alive {
		return // shell failed to spawn in this environment; nothing to drive.
	}
	testing.expect(t, e.ed.terminal.active, "Alt+t opens the terminal")

	e2e_term_settle(&e, 300) // let the initial prompt appear
	e2e_type(&e, "echo qed_e2e_marker\n")
	sc, gy, ok := e2e_term_wait_row(&e, "qed_e2e_marker", 4000)
	testing.expect(t, ok, "shell echoes the marker on its own row")

	// Drag over the echoed text: press, motion, release auto-copies the trimmed run.
	area := e.ed.terminal.area
	ec := sc + len("qed_e2e_marker") - 1
	e2e_mouse(&e, area.x + sc, area.y + gy)
	e2e_mouse(&e, area.x + ec, area.y + gy, .Mouse_Left, motion = true)
	e2e_mouse(&e, area.x + ec, area.y + gy, .Mouse_Release)
	testing.expect_value(t, clipboard_register, "qed_e2e_marker")

	// Esc at a plain shell prompt defocuses the pane (the shell survives).
	e2e_key(&e, .Esc)
	e2e_term_sync(&e)
	testing.expect(t, !e.ed.terminal.active, "Esc closes the terminal at the prompt")
}
