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
	testing.expect(t, e.ed.scroll_row > 0, "wheel-down scrolls the viewport")
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 0)

	e2e_mouse(&e, g + 0, 3, .Mouse_Wheel_Up)
	testing.expect_value(t, e.ed.scroll_row, 0)
	testing.expect_value(t, b.cursor.row, 0)
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
	testing.expect(t, e.ed.palette.active, "Ctrl+P opens the palette")
	testing.expect(t, len(e.ed.palette.matches) > PALETTE_MAX_ROWS, "more commands than fit")

	e2e_mouse(&e, 0, 0, .Mouse_Wheel_Down)
	testing.expect(t, e.ed.palette.list.scroll > 0, "wheel-down scrolls the palette")
	e2e_mouse(&e, 0, 0, .Mouse_Wheel_Up)
	testing.expect_value(t, e.ed.palette.list.scroll, 0)
}

// Line jump (Ctrl+G): a single click selects the row under the pointer.
@(test)
e2e_mouse_linefind_click_row :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta\ngamma\ndelta\nepsilon")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	e2e_key(&e, .Ctrl_G)
	testing.expect(t, e.ed.linefind.active, "Ctrl+G opens line jump")
	testing.expect_value(t, e.ed.linefind.selected, 0)

	lay := overlay_layout(&e.ed)
	e2e_mouse(&e, lay.inner.x + 1, lay.body_top + 2)
	testing.expect_value(t, e.ed.linefind.selected, 2)
	testing.expect(t, e.ed.linefind.active, "a single click only selects, stays open")
}

// Buffer switcher (Alt+e): a double click activates the row, same as Enter.
@(test)
e2e_mouse_bufswitch_double_click :: proc(t: ^testing.T) {
	e := e2e_start("first buffer")
	defer e2e_stop(&e)

	path2 := e2e_mouse_scratch(".txt")
	defer {
		os.remove(path2)
		delete(path2)
	}
	_ = os.write_entire_file(path2, transmute([]u8)string("second buffer"))
	editor_open_path(&e.ed, path2)
	testing.expect_value(t, e.ed.current, 1)

	// Alt+e is the Switch Buffer bind (an alt-char command).
	e2e_step(&e, tb2.Event{type = .Key, mod = .Alt, ch = 'e'})
	testing.expect(t, e.ed.bufswitch.active, "Alt+e opens the switcher")

	lay := overlay_layout(&e.ed)
	e2e_mouse(&e, lay.inner.x + 1, lay.body_top)
	e2e_mouse(&e, lay.inner.x + 1, lay.body_top)
	testing.expect(t, !e.ed.bufswitch.active, "double click activates and closes")
	testing.expect_value(t, e.ed.current, 0)
}

// File-open picker (Ctrl+O): a click outside the box dismisses it.
@(test)
e2e_mouse_picker_click_away :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	// An empty scratch root keeps picker_open off the (large) real cwd.
	root := e2e_mouse_scratch("")
	os.make_directory(root)
	saved_root := e.ed.working_root
	e.ed.working_root = root
	defer {
		e.ed.working_root = saved_root
		os.remove(root)
		delete(root)
	}

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, e.ed.picker.active, "Ctrl+O opens the picker")

	// (0,0) is outside the centered pane box; a non-motion click there closes it.
	e2e_mouse(&e, 0, 0)
	testing.expect(t, !e.ed.picker.active, "click outside dismisses the picker")
}

// Find bar (Ctrl+F): a click in the query field places the caret; a button-held
// drag selects text in the field.
@(test)
e2e_mouse_find_field_caret_drag :: proc(t: ^testing.T) {
	e := e2e_start("hello world")
	defer e2e_stop(&e)

	e2e_key(&e, .Ctrl_F)
	testing.expect(t, e.ed.find.active, "Ctrl+F opens find")
	e2e_type(&e, "hello")
	testing.expect_value(t, textfield_str(&e.ed.find.field), "hello")

	box := find_box(&e.ed)
	tx := box.x + 1 + len(FIND_LABEL)
	fy := box.y + 1

	// A plain click drops the caret at that column, clearing any selection.
	e2e_mouse(&e, tx + 2, fy)
	testing.expect_value(t, e.ed.find.field.caret, 2)
	_, _, sel := textfield_selection(&e.ed.find.field)
	testing.expect(t, !sel, "a plain click leaves no field selection")

	// A button-held drag extends a selection from the caret.
	e2e_mouse(&e, tx + 4, fy, .Mouse_Left, motion = true)
	lo, hi, ok := textfield_selection(&e.ed.find.field)
	testing.expect(t, ok, "drag selects field text")
	testing.expect_value(t, lo, 2)
	testing.expect_value(t, hi, 4)
}

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
	lay := overlay_layout(&e.ed)
	for ry in 0 ..< lay.inner.h {
		row := e2e_term_row(e, lay.inner, ry)
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

	term_toggle(&e.ed)
	if !e.ed.terminal.alive {
		return // shell failed to spawn in this environment; nothing to drive.
	}
	testing.expect(t, e.ed.terminal.active, "Alt+t opens the terminal")

	e2e_term_settle(&e, 300) // let the initial prompt appear
	e2e_type(&e, "echo qed_e2e_marker\n")
	sc, gy, ok := e2e_term_wait_row(&e, "qed_e2e_marker", 4000)
	testing.expect(t, ok, "shell echoes the marker on its own row")

	// Drag over the echoed text: press, motion, release auto-copies the trimmed run.
	lay := overlay_layout(&e.ed)
	ec := sc + len("qed_e2e_marker") - 1
	e2e_mouse(&e, lay.inner.x + sc, lay.inner.y + gy)
	e2e_mouse(&e, lay.inner.x + ec, lay.inner.y + gy, .Mouse_Left, motion = true)
	e2e_mouse(&e, lay.inner.x + ec, lay.inner.y + gy, .Mouse_Release)
	testing.expect_value(t, clipboard_register, "qed_e2e_marker")

	// Esc at a plain shell prompt defocuses the pane (the shell survives).
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.terminal.active, "Esc closes the terminal at the prompt")
}
