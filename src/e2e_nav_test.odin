package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "lib:tb2"

// Navigation & UI e2e sessions. Some cases need a working root the plain
// e2e_start can't give (pickers / project-search / file-tree read
// editor.working_root, which for a file arg is the process cwd), so these local
// starters open under a scratch dir and point the root at it; e2e_stop removes it.

e2e_root_start :: proc(primary := "") -> E2E {
	e2e_enter()
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.aprintf("%s/qed_e2e_nav_%d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(dir)
	file := fmt.aprintf("%s/main.txt", dir)
	_ = os.write_entire_file(file, transmute([]u8)primary)
	ed := editor_init(file, headless = true)
	e2e_old_ui(&ed)
	delete(ed.working_root)
	ed.working_root = strings.clone(dir)
	return E2E{ed = ed, path = file, dir = dir}
}

e2e_welcome_start :: proc() -> E2E {
	e2e_enter()
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.aprintf("%s/qed_e2e_welcome_%d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(dir)
	ed := editor_init("", headless = true)
	e2e_old_ui(&ed)
	delete(ed.working_root)
	ed.working_root = strings.clone(dir)
	return E2E{ed = ed, dir = dir}
}

palette_open_now :: proc(e: ^E2E) -> bool {
	p := pane_focus(&e.ed)
	return p != nil && p.id == "palette" && !p.ctx.lua
}

palette_selected :: proc(e: ^E2E) -> string {
	p := pane_find(&e.ed, "palette")
	if p == nil || pane_count(&e.ed, p) == 0 {
		return ""
	}
	return test_pane_label(&e.ed, p, p.list.sel)
}

palette_labels :: proc(e: ^E2E) -> string {
	labels := make([dynamic]string, context.temp_allocator)
	if p := pane_find(&e.ed, "palette"); p != nil {
		for it in test_pane_items(&e.ed, p) {
			append(&labels, it.label)
		}
	}
	return fmt.tprintf("|%s|", strings.join(labels[:], "|", context.temp_allocator))
}

nav_alt :: proc(e: ^E2E, ch: rune) {
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = ch, mod = .Alt})
	pane_stack_sync(&e.ed)
	plugin_flush(&e.ed)
}

nav_write :: proc(path, content: string) {
	_ = os.write_entire_file(path, transmute([]u8)content)
}

// headless tests never reach the main loop's pump, which delivers the git plugin's status
nav_scan :: proc(e: ^E2E) {
	e2e_git_settle(e)
}

// the Git tab asks git for a base from a debounced change task
nav_preview :: proc(e: ^E2E) {
	ft_preview_settle(&e.ed)
}

e2e_row :: proc(e: ^E2E, y: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for x in 0 ..< int(tb2.width()) {
		r := e2e_cell(e, x, y)
		strings.write_rune(&sb, ' ' if r == 0 else r)
	}
	return strings.to_string(sb)
}

@(test)
e2e_nav_soft_wrap :: proc(t: ^testing.T) {
	e := e2e_start("alpha bravo charlie delta echo foxtrot golf\nTAIL")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	cursor_goal_sync(b)
	gutter := editor_gutter_width(&e.ed)

	e2e_resize(&e, 22, E2E_H)
	e2e_render(&e)

	// Row 0 is the logical line's first visual row (gutter shows "1"); row 1 is a
	// continuation, so its whole gutter is blank yet still carries wrapped text.
	testing.expect_value(t, e2e_cell(&e, 1, 0), '1')
	testing.expect_value(t, e2e_cell(&e, 1, 1), ' ')
	testing.expect(t, e2e_cell(&e, gutter, 1) != ' ', "continuation row should carry wrapped text")

	// Down/Up move by visual row within the one logical line.
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect(t, b.cursor.col > 0, "Down should advance to the next visual row of the same line")

	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 0)
}

@(test)
e2e_nav_arrow_clamp_buffer_edges :: proc(t: ^testing.T) {
	e := e2e_start("first\nsecond")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)

	// Wrap off so the plain (non-visual) vertical paths are exercised.
	e2e_key(&e, .Ctrl_P)
	e2e_type(&e, "line wrap")
	e2e_key(&e, .Enter)
	testing.expect(t, !b.wrap, "wrap turned off")

	// Down on the last line clamps to line end and resets the goal column.
	b.cursor = {1, 2}
	cursor_goal_sync(b)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, len(b.lines[1].text))
	testing.expect_value(t, b.goal_col, visual_col(b.lines[1].text[:], b.cursor.col))

	// Already at end-of-last-line: a second Down is a no-op.
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, len(b.lines[1].text))

	// Down then Enter appends a fresh line from the clamped end.
	e2e_key(&e, .Enter)
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, b.cursor.row, 2)
	testing.expect_value(t, b.cursor.col, 0)
	testing.expect_value(t, len(b.lines[2].text), 0)

	// Up on the first line clamps to column 0 and resets the goal column.
	b.cursor = {0, 3}
	cursor_goal_sync(b)
	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 0)
	testing.expect_value(t, b.goal_col, 0)

	// Already at col 0 of the first line: a second Up is a no-op.
	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 0)
}

@(test)
e2e_nav_arrow_clamp_wrapped_last_line :: proc(t: ^testing.T) {
	e := e2e_start("TOP\nalpha bravo charlie delta echo foxtrot golf")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect(t, b.wrap, "wrap on by default")

	e2e_resize(&e, 22, E2E_H)
	e2e_render(&e)

	last := b.lines[1].text[:]
	rows := len(line_wrap(last, b.wrap_width))
	testing.expect(t, rows >= 2, "last line should wrap into multiple visual rows")

	// From the first visual row, Down steps within the logical line first.
	b.cursor = {1, 0}
	cursor_goal_sync(b)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect(t, b.cursor.col > 0, "Down advances to the next visual row of the last line")

	// Exhausting the visual rows lands the caret at the logical line end.
	for _ in 0 ..< rows {
		e2e_key(&e, .Arrow_Down)
	}
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, len(last))
}

@(test)
e2e_nav_shift_down_last_line :: proc(t: ^testing.T) {
	e := e2e_start("first\nsecond")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {1, 2}
	cursor_goal_sync(b)

	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift)
	testing.expect(t, selection_active(b), "Shift+Down extends a selection")
	from, to, ok := selection_range(b)
	testing.expect(t, ok, "selection range present")
	testing.expect_value(t, from, Cursor{1, 2})
	testing.expect_value(t, to, Cursor{1, len(b.lines[1].text)})
}

@(test)
e2e_nav_horizontal_scroll :: proc(t: ^testing.T) {
	e := e2e_start("")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect(t, b.wrap, "wrap is on by default")

	// Flip wrap off via the *Toggle Line Wrap* command (no default keybind).
	e2e_key(&e, .Ctrl_P)
	e2e_type(&e, "line wrap")
	e2e_key(&e, .Enter)
	testing.expect(t, !b.wrap, "palette command should turn wrap off")

	long := strings.repeat("a", 100, context.temp_allocator)
	e2e_type(&e, long)
	testing.expect(t, e.ed.scroll_col > 0, "cursor past the right edge scrolls horizontally")
	testing.expect_value(t, e.ed.scroll_sub, 0)
}

@(test)
e2e_nav_welcome :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)

	testing.expect(t, e.ed.welcome, "a no-file session shows the welcome screen")
	e2e_render(&e)

	// Plain typing is ignored on the welcome screen.
	e2e_type(&e, "abc")
	testing.expect(t, e.ed.welcome, "typing does not leave the welcome screen")
	testing.expect_value(t, len(editor_buffer(&e.ed).lines), 1)
	testing.expect_value(t, len(editor_buffer(&e.ed).lines[0].text), 0)

	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f opens the file tree from welcome")
	e2e_key(&e, .Ctrl_P)
	e2e_ui_settle(&e)
	testing.expect(t, strings.contains(palette_ui_labels(&e), "|File Tree: Copy|"), "the tree's palette lists its commands on welcome")
	e2e_key(&e, .Esc)
	e2e_key(&e, .Esc)
	testing.expect(t, !filetree_active(&e.ed), "Esc closes the file tree")

	e2e_key(&e, .Ctrl_P)
	testing.expect(t, palette_open_now(&e), "Ctrl+P opens the command palette from welcome")
	e2e_key(&e, .Esc)
	testing.expect(t, !palette_open_now(&e), "Esc closes the palette")
}

@(test)
e2e_nav_welcome_status :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)

	editor_log(&e.ed, .Warn, "", "config: bad knob")
	e2e_render(&e)

	status_row := e2e_row(&e, E2E_H - 2)
	testing.expect(t, strings.contains(status_row, fmt.tprintf("qed %s", VERSION)), "welcome status bar shows the version")
	testing.expect(t, strings.contains(status_row, "qed_e2e_welcome"), "welcome status bar shows the working root")
	testing.expect(t, strings.contains(e2e_row(&e, E2E_H - 1), "config: bad knob"), "startup message renders on the message row")
}

@(test)
e2e_nav_welcome_log :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)

	testing.expect(t, e.ed.welcome, "a no-file session shows the welcome screen")

	nav_alt(&e, 'l')
	plugin_flush(&e.ed)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Message Log"), "Alt+l opens the log over welcome")

	nav_alt(&e, 'l')
	plugin_flush(&e.ed)
	e2e_render(&e)
	testing.expect(t, !e2e_grid_has(&e, "Message Log"), "Alt+l again closes it on welcome")
	nav_alt(&e, 'l')
	plugin_flush(&e.ed)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Message Log"), "and reopens it")

	e2e_key(&e, .Esc)
	testing.expect(t, !test_pane_open(&e.ed, "log"), "Esc closes the log pane")
	testing.expect(t, e.ed.welcome, "closing returns to the welcome screen")
}

@(test)
e2e_nav_palette :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, palette_open_now(&e), "Ctrl+P opens the palette")

	p := pane_find(&e.ed, "palette")
	rows := min(pane_count(&e.ed, p), PALETTE_MAX_ROWS)
	box := pane_center(&e.ed, PALETTE_WIDTH, 2 + rows)
	border_x := box.x + box.w - 1
	testing.expect(t, pane_count(&e.ed, p) > rows, "the command list should overflow the palette")
	testing.expect_value(t, pane_geom(&e.ed, p).box, box)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, border_x, box.y + 3), '┃')
	testing.expect_value(t, e2e_cell_fg(&e, border_x, box.y + 3), COLOR_PANE_FG)
	testing.expect(t, e2e_grid_has(&e, "Ctrl+q"), "the shortcut column shows live binds")

	e2e_type(&e, "line wrap")
	testing.expect(t, pane_count(&e.ed, p) > 0, "fuzzy query should match a command")
	testing.expect_value(t, palette_selected(&e), "Toggle Line Wrap")

	rows = min(pane_count(&e.ed, p), PALETTE_MAX_ROWS)
	box = pane_center(&e.ed, PALETTE_WIDTH, 2 + rows)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, box.x + box.w - 1, box.y + 3), '│')

	e2e_key(&e, .Enter)
	testing.expect(t, !palette_open_now(&e), "Enter closes the palette")
	testing.expect(t, !b.wrap, "the selected command actually ran")

	e2e_key(&e, .Ctrl_P)
	e2e_type(&e, "zzzzqqq")
	e2e_key(&e, .Enter)
	testing.expect(t, palette_open_now(&e), "Enter with no match keeps the palette open")
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, !palette_open_now(&e), "the palette's own chord closes it")
	e2e_key(&e, .Ctrl_P)
	e2e_paste(&e, "line wrap")
	testing.expect_value(t, palette_selected(&e), "Toggle Line Wrap")
	e2e_render(&e)
	g := pane_geom(&e.ed, pane_find(&e.ed, "palette"))
	e2e_mouse(&e, g.box.x + g.box.w + 2, g.box.y)
	testing.expect(t, !palette_open_now(&e), "a click outside closes it")
}

@(test)
e2e_nav_palette_welcome_filter :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)

	testing.expect(t, e.ed.welcome, "a no-file session shows the welcome screen")
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, palette_open_now(&e), "Ctrl+P opens the palette from welcome")

	has := proc(ed: ^Editor, name: string) -> bool {
		for it in test_pane_items(ed, pane_find(ed, "palette")) {
			if it.label == name {
				return true
			}
		}
		return false
	}
	testing.expect(t, !has(&e.ed, "Save"), "a buffer-only command is hidden on welcome")
	testing.expect(t, !has(&e.ed, "Toggle Comment"), "editing commands are hidden on welcome")
	testing.expect(t, !has(&e.ed, "LSP: Go to Definition"), "LSP commands are hidden on welcome")
	testing.expect(t, !has(&e.ed, "Settings: Language"), "buffer-only plugin commands are hidden on welcome")
	testing.expect(t, !has(&e.ed, "Format: Document"), "plugin commands without welcome are hidden")
	testing.expect(t, has(&e.ed, "File Tree: All"), "File Tree: All stays available on welcome")
	testing.expect(t, has(&e.ed, "Settings: Theme"), "Settings: Theme stays available on welcome")
	testing.expect(t, has(&e.ed, "Quit"), "Quit stays available on welcome")
}

@(test)
e2e_nav_file_open_and_close :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "second body")

	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f opens the file tree")
	e2e_type(&e, "second")
	testing.expect(t, len(ft_entries(&e.ed)) > 0, "the filter lists the match")
	e2e_key(&e, .Enter)
	plugin_flush(&e.ed)

	testing.expect(t, !filetree_active(&e.ed), "tree closes after opening")
	testing.expect_value(t, len(e.ed.buffers), 2)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "second.txt"), "second.txt is now current")

	// Close Buffer (Ctrl+w) returns to the other buffer.
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "main.txt"), "closing returns to main.txt")
}

@(test)
e2e_nav_scrollbar :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	for i in 0 ..< 20 {
		path := fmt.tprintf("%s/f%02d.txt", e.ed.working_root, i)
		nav_write(path, "body")
	}

	e2e_resize(&e, 200, E2E_H)
	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f opens the file tree")
	nav_preview(&e)

	lay := ft_layout(&e.ed)
	testing.expect(t, len(ft_entries(&e.ed)) > lay.body_h, "20 files should overflow the tree's body")
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, lay.bar_x, lay.body_top), '┃')
	testing.expect_value(t, e2e_cell(&e, lay.div_x, lay.body_top), '│')

	e2e_type(&e, "f00")
	testing.expect(t, len(ft_entries(&e.ed)) <= lay.body_h, "a narrow query should fit without a scrollbar")
	nav_preview(&e)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, lay.bar_x, lay.body_top), ' ')
	testing.expect_value(t, e2e_cell(&e, lay.div_x, lay.body_top), '│')

	e2e_key(&e, .Esc)
	testing.expect(t, ft_query(&e.ed) == "", "Esc first clears the filter")
	e2e_key(&e, .Esc)
	testing.expect(t, !filetree_active(&e.ed), "Esc then closes the tree")
}

@(test)
e2e_nav_open_tab_inmemory_preview :: proc(t: ^testing.T) {
	e := e2e_root_start("alpha one\nalpha two")
	defer e2e_stop(&e)
	e2e_resize(&e, 200, E2E_H)

	// Unsaved in-memory edit to the current buffer.
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	cursor_goal_sync(b)
	e2e_type(&e, "X")

	// The Open tab previews the open buffer's in-memory content, not disk.
	nav_alt(&e, 'o')
	testing.expect_value(t, ft_scope(&e.ed), "Open")
	for entry, i in ft_entries(&e.ed) {
		if entry.name == "main.txt" {
			ft_set_sel(&e.ed, i)
		}
	}
	nav_preview(&e)
	testing.expect_value(t, ft_preview_line(&e.ed, 0), "Xalpha one")
}

@(test)
e2e_nav_open_tab_switch_and_close :: proc(t: ^testing.T) {
	e := e2e_root_start("alpha one")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "bravo one")
	editor_open_path(&e.ed, second)
	testing.expect_value(t, e.ed.current, 1)

	// Open tab → filter → Enter switches to the other open buffer.
	nav_alt(&e, 'o')
	testing.expect(t, filetree_active(&e.ed), "Alt+o opens the Open tab")
	e2e_type(&e, "main")
	e2e_key(&e, .Enter)
	testing.expect(t, !filetree_active(&e.ed), "Enter switches and closes the tree")
	testing.expect_value(t, e.ed.current, 0)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "main.txt"), "switched to main.txt")

	// Ctrl+W on an all-clean selection closes immediately, no dialog.
	nav_alt(&e, 'o')
	for entry, i in ft_entries(&e.ed) {
		if entry.name == "second.txt" {
			ft_set_sel(&e.ed, i)
		}
	}
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "main.txt"), "main.txt remains")
}

@(test)
e2e_nav_open_tab_close_unsaved_confirms :: proc(t: ^testing.T) {
	e := e2e_root_start("alpha one")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "bravo one")
	editor_open_path(&e.ed, second)
	testing.expect_value(t, e.ed.current, 1)

	// Unsaved in-memory edit to second.txt.
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	cursor_goal_sync(b)
	e2e_type(&e, "Z")
	testing.expect(t, editor_buffer(&e.ed).modified, "second.txt is unsaved")

	nav_alt(&e, 'o')
	for entry, i in ft_entries(&e.ed) {
		if entry.name == "second.txt" {
			ft_set_sel(&e.ed, i)
		}
	}

	// An unsaved buffer in the selection routes Ctrl+W through the confirm dialog.
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.ConfirmClose)
	e2e_key(&e, .Enter) // default action is "Cancel"
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect_value(t, len(e.ed.buffers), 2)

	// Reopen, confirm "Close All" discards the unsaved buffer.
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.ConfirmClose)
	e2e_key(&e, .Arrow_Down) // move to "Close All"
	e2e_key(&e, .Enter)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "main.txt"), "main.txt remains")
}

@(test)
e2e_nav_line_jump_selection_prefill :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta\nalpha2\nalpha3")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.selection = Cursor{0, 0}
	b.cursor = {0, 5} // select "alpha"

	e2e_key(&e, .Ctrl_G)
	e2e_ui_settle(&e)
	state := goto_state(&e.ed)
	testing.expect_value(t, state.query, "alpha")
	testing.expect_value(t, len(state.labels), 3) // filter ran on the pre-fill
	e2e_type(&e, "beta")
	testing.expect_value(t, goto_state(&e.ed).query, "beta") // the pre-fill was selected
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_line_jump :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta\ngamma\nalpha2\ndelta\nalpha3")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	// :N exact line jump.
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, ":3")
	e2e_key(&e, .Enter)
	testing.expect_value(t, b.cursor.row, 2)

	// :N:C exact line+column jump.
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, ":2:4")
	e2e_key(&e, .Enter)
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, 3)

	// Fuzzy content match, in file order.
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, "alpha")
	labels := goto_state(&e.ed).labels
	testing.expect_value(t, len(labels), 3)
	testing.expect_value(t, strings.join(labels, ",", context.temp_allocator), "alpha,alpha2,alpha3")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_jump_list :: proc(t: ^testing.T) {
	body := strings.repeat("line\n", 40, context.temp_allocator)
	e := e2e_start(body)
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	// A >JUMP_THRESHOLD line jump pushes onto the jump list.
	e2e_key(&e, .Ctrl_G)
	e2e_type(&e, ":30")
	e2e_key(&e, .Enter)
	testing.expect_value(t, b.cursor.row, 29)

	nav_alt(&e, ',') // Jump Back
	testing.expect_value(t, b.cursor.row, 0)
	nav_alt(&e, '.') // Jump Forward
	testing.expect_value(t, b.cursor.row, 29)
}

@(test)
e2e_nav_filetree_expand_open :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	sub := fmt.aprintf("%s/sub", e.ed.working_root)
	defer delete(sub)
	os.make_directory(sub)
	inner := fmt.aprintf("%s/inner.txt", sub)
	defer delete(inner)
	nav_write(inner, "inner body")

	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f opens the file tree")

	testing.expect_value(t, ft_entries(&e.ed)[0].name, "sub") // dirs sort first
	e2e_key(&e, .Enter) // expand the folder
	testing.expect_value(t, ft_entries(&e.ed)[1].name, "inner.txt")

	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter) // open the file
	testing.expect(t, !filetree_active(&e.ed), "opening a file closes the tree")
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "inner.txt"), "inner.txt is now current")
}

@(test)
e2e_nav_filetree_scope_and_dotfiles :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	hidden := fmt.aprintf("%s/.hidden.txt", e.ed.working_root)
	defer delete(hidden)
	nav_write(hidden, "secret")

	nav_alt(&e, 'f')

	has_hidden :: proc(ed: ^Editor) -> bool {
		for entry in ft_entries(ed) {
			if entry.name == ".hidden.txt" {
				return true
			}
		}
		return false
	}

	testing.expect(t, !has_hidden(&e.ed), "dotfiles hidden by default")
	filetree_toggle_dotfiles(&e.ed) // palette command
	testing.expect(t, ft_walk(&e.ed).dotfiles, "toggle enables dotfiles")
	testing.expect(t, has_hidden(&e.ed), "dotfile now visible")

	// Scope tab bar: Right cycles All -> Open.
	testing.expect_value(t, ft_scope(&e.ed), "All")
	e2e_key(&e, .Arrow_Right)
	testing.expect_value(t, ft_scope(&e.ed), "Open")
	e2e_key(&e, .Arrow_Left)
	testing.expect_value(t, ft_scope(&e.ed), "All")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_options_hot_reload :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	nav_write(fmt.tprintf("%s/.hidden.txt", e.ed.working_root), "secret")

	nav_alt(&e, 'f')
	walk_dotfiles :: proc(ed: ^Editor) -> bool {return ft_walk(ed).dotfiles}
	testing.expect(t, !walk_dotfiles(&e.ed) && !ft_chip(&e.ed, "dotfiles"), "dotfiles off by default")
	e2e_plugin_config(&e, "filetree", `{"show_dotfiles": true}`, hot = true)
	plugin_flush(&e.ed)
	testing.expect(t, walk_dotfiles(&e.ed) && ft_chip(&e.ed, "dotfiles"), "a config edit applies to the open tree")

	filetree_toggle_dotfiles(&e.ed)
	testing.expect(t, !walk_dotfiles(&e.ed), "the live toggle wins")
	e2e_plugin_config(&e, "filetree", `{"show_dotfiles": true, "show_ignored": true}`, hot = true)
	plugin_flush(&e.ed)
	testing.expect(t, !walk_dotfiles(&e.ed), "an unchanged knob keeps the live toggle")
	testing.expect(t, ft_walk(&e.ed).ignored && ft_chip(&e.ed, "ignored"), "a changed knob applies")
	testing.expect(t, !plugin_test_logged(&e.ed, .Info, "File Tree", "reloaded"), "the tree is not reloaded")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_filter_dotfile_toggle :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_write(fmt.tprintf("%s/aaa.txt", e.ed.working_root), "x")
	nav_write(fmt.tprintf("%s/.aaa.txt", e.ed.working_root), "y")

	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f opens the file tree")

	count_named :: proc(ed: ^Editor, name: string) -> int {
		n := 0
		for entry in ft_entries(ed) {
			if entry.name == name {
				n += 1
			}
		}
		return n
	}

	e2e_type(&e, "aaa")
	testing.expect(t, count_named(&e.ed, "aaa.txt") == 1, "visible file matches the filter")
	testing.expect_value(t, count_named(&e.ed, ".aaa.txt"), 0) // dotfile excluded while off

	// Toggle dotfiles ON mid-filter: the cached candidate set must re-collect.
	nav_alt(&e, '.')
	testing.expect(t, ft_walk(&e.ed).dotfiles, "Alt+. turns dotfiles on")
	testing.expect_value(t, count_named(&e.ed, ".aaa.txt"), 1)
	testing.expect_value(t, count_named(&e.ed, "aaa.txt"), 1)

	// Toggle back OFF: the dotfile drops out of the filtered results again.
	nav_alt(&e, '.')
	testing.expect(t, !ft_walk(&e.ed).dotfiles, "Alt+. turns dotfiles off")
	testing.expect_value(t, count_named(&e.ed, ".aaa.txt"), 0)
	testing.expect_value(t, count_named(&e.ed, "aaa.txt"), 1)

	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_open_filter_close :: proc(t: ^testing.T) {
	e := e2e_root_start("alpha one")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "bravo one")
	editor_open_path(&e.ed, second)

	nav_alt(&e, 'o')
	testing.expect_value(t, ft_scope(&e.ed), "Open")

	count_named :: proc(ed: ^Editor, name: string) -> int {
		n := 0
		for entry in ft_entries(ed) {
			if entry.name == name {
				n += 1
			}
		}
		return n
	}

	e2e_type(&e, "txt") // matches both open buffers
	testing.expect_value(t, count_named(&e.ed, "main.txt"), 1)
	testing.expect_value(t, count_named(&e.ed, "second.txt"), 1)

	for entry, i in ft_entries(&e.ed) {
		if entry.name == "second.txt" {
			ft_set_sel(&e.ed, i)
		}
	}
	e2e_key(&e, .Ctrl_W) // clean buffer closes without a dialog
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	// close_commit must invalidate the filter cache: the closed buffer drops out.
	testing.expect_value(t, count_named(&e.ed, "second.txt"), 0)
	testing.expect_value(t, count_named(&e.ed, "main.txt"), 1)

	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_git :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("committed\n")
	defer e2e_stop(&e)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)

	newf := fmt.aprintf("%s/new.txt", e.dir)
	defer delete(newf)
	nav_write(newf, "fresh")
	ignore := fmt.aprintf("%s/.gitignore", e.dir)
	defer delete(ignore)
	nav_write(ignore, "*.log\n")
	logf := fmt.aprintf("%s/debug.log", e.dir)
	defer delete(logf)
	nav_write(logf, "noise")

	nav_alt(&e, 'f') // first open kicks off the async git-status scan
	nav_scan(&e)

	entry_named :: proc(ed: ^Editor, name: string) -> bool {
		for entry in ft_entries(ed) {
			if entry.name == name {
				return true
			}
		}
		return false
	}

	// Ignored file hidden until toggled on (palette command).
	testing.expect(t, !entry_named(&e.ed, "debug.log"), "gitignored file hidden by default")
	filetree_toggle_ignored(&e.ed)
	testing.expect(t, ft_walk(&e.ed).ignored, "toggle enables ignored")
	testing.expect(t, entry_named(&e.ed, "debug.log"), "ignored file now visible")

	// the Git tab prunes to changed files; the untracked add shows up.
	e2e_key(&e, .Arrow_Right)
	e2e_key(&e, .Arrow_Right)
	testing.expect_value(t, ft_scope(&e.ed), "Git")
	testing.expect(t, entry_named(&e.ed, "new.txt"), "the Git tab lists the untracked add")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_git_diffsize :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("committed\n")
	defer e2e_stop(&e)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)

	nav_write(e.path, "changed\nextra\n")
	newf := fmt.aprintf("%s/new.txt", e.dir)
	defer delete(newf)
	nav_write(newf, "n1\nn2")
	ignore := fmt.aprintf("%s/.gitignore", e.dir)
	defer delete(ignore)
	nav_write(ignore, "*.log\n")
	logf := fmt.aprintf("%s/debug.log", e.dir)
	defer delete(logf)
	nav_write(logf, "a\nb\nc\n")
	binf := fmt.aprintf("%s/blob.dat", e.dir)
	defer delete(binf)
	nav_write(binf, "\x00\x01\n\x02\n")

	nav_alt(&e, 'g')
	nav_scan(&e)
	testing.expect_value(t, ft_scope(&e.ed), "Git")
	m := ft_mark(&e.ed, e.path)
	testing.expect(t, m.sizes && m.added == 2 && m.removed == 1, "modified file sizes")
	m = ft_mark(&e.ed, newf)
	testing.expect(t, m.sizes && m.added == 2 && m.removed == 0, "untracked file sizes")
	testing.expect(t, !ft_mark(&e.ed, binf).sizes, "binary untracked skipped")
	testing.expect(t, !ft_mark(&e.ed, logf).sizes, "ignored file skipped")
	e2e_render(&e)
	lay := ft_layout(&e.ed)
	found := 0
	for y in lay.body_top ..< lay.body_top + lay.body_h {
		row := e2e_row(&e, y)
		want := ""
		if strings.contains(row, "new.txt") {
			want = "+2  -0"
		} else if strings.contains(row, "file.txt") {
			want = "+2  -1"
		} else {
			continue
		}
		off := strings.index(row, want)
		testing.expectf(t, off >= 0, "Git tab row shows per-file diff size: %q", row)
		if off >= 0 {
			x := visual_width(transmute([]u8)row[:off])
			testing.expect_value(t, x + len(want), lay.bar_x)
			testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, x, y)), e2e_rgb(COLOR_GIT_ADD))
			testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, x + 4, y)), e2e_rgb(COLOR_GIT_DEL))
			found += 1
		}
	}
	testing.expect_value(t, found, 2)
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_git_diff_toggle :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	seed := "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\nline 08\nline 09\nline 10\nline 11\nline 12\nline 13\nline 14\nline 15\nline 16\nline 17\nline 18\nline 19\nline 20\n"
	e := e2e_git_start(seed)
	defer e2e_stop(&e)
	e2e_resize(&e, 200, E2E_H)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)

	nav_write(e.path, "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\nline 08\nline 09\nCHANGED\nline 11\nline 12\nline 13\nline 14\nline 15\nline 16\nline 17\nline 18\nline 19\nline 20\n")
	// a preview copies the open buffer, so it takes the disk change first, as the disk poll would
	editor_reload_buffer(&e.ed, editor_buffer(&e.ed))

	nav_alt(&e, 'f')
	nav_scan(&e)

	e2e_key(&e, .Arrow_Right)
	e2e_key(&e, .Arrow_Right)
	testing.expect_value(t, ft_scope(&e.ed), "Git")
	for entry, i in ft_entries(&e.ed) {
		if entry.name == "file.txt" {
			ft_set_sel(&e.ed, i)
		}
	}
	e2e_git_settle(&e)
	nav_preview(&e)

	testing.expect(t, ft_chip(&e.ed, "diff"), "diff-only on by default")
	testing.expect(t, ft_preview(&e.ed) != nil && ft_preview_line(&e.ed, 0) != "line 01", "the collapsed view starts at the change's context")
	collapsed := len(ft_preview(&e.ed).lines) if ft_preview(&e.ed) != nil else 0

	nav_alt(&e, 'd') // File Tree: Toggle Diff
	testing.expect(t, !ft_chip(&e.ed, "diff"), "Alt+d turns full diff on (diff-only off)")
	nav_preview(&e)
	full := len(ft_preview(&e.ed).lines) if ft_preview(&e.ed) != nil else 0

	testing.expect(t, full > collapsed, "full diff shows more rows than the collapsed view")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_shift_range :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	for name in ([?]string{"a.txt", "b.txt", "c.txt"}) {
		path := fmt.tprintf("%s/%s", e.ed.working_root, name)
		nav_write(path, "body")
	}

	nav_alt(&e, 'f')
	testing.expect_value(t, ft_entries(&e.ed)[0].name, "a.txt")

	// Shift+Down twice extends a contiguous range a..c.
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift)
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift)
	lo, hi := ft_sel_range(&e.ed)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, 2)

	// A plain move collapses the range back to one selection.
	e2e_key(&e, .Arrow_Down)
	lo, hi = ft_sel_range(&e.ed)
	testing.expect(t, lo == hi, "plain move clears the anchor")
	testing.expect_value(t, ft_sel(&e.ed), 3)
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_copy_paste :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	src := fmt.aprintf("%s/a.txt", e.ed.working_root)
	defer delete(src)
	nav_write(src, "original")

	nav_alt(&e, 'f')
	testing.expect_value(t, ft_entries(&e.ed)[0].name, "a.txt")

	e2e_key(&e, .Ctrl_C) // copy a.txt
	e2e_key(&e, .Ctrl_V) // paste into the working root (a.txt's parent)

	copy := fmt.aprintf("%s/a (copy).txt", e.ed.working_root)
	defer delete(copy)
	testing.expect(t, os.exists(copy), "collision suffix copy created")
	testing.expect(t, os.exists(src), "original survives a copy")

	sel, ok := ft_selected(&e.ed)
	testing.expect(t, ok, "a row stays selected after paste")
	testing.expect(t, strings.has_suffix(sel.path, "a (copy).txt"), "paste reveals the new copy")

	// A copy clipboard persists: pasting again makes a second suffixed copy.
	e2e_key(&e, .Ctrl_V)
	copy2 := fmt.aprintf("%s/a (copy 2).txt", e.ed.working_root)
	defer delete(copy2)
	testing.expect(t, os.exists(copy2), "copy clipboard persists for repeated paste")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_cut_paste_repaths_buffer :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	sub := fmt.aprintf("%s/sub", e.ed.working_root)
	defer delete(sub)
	os.make_directory(sub)
	foo := fmt.aprintf("%s/foo.txt", e.ed.working_root)
	defer delete(foo)
	nav_write(foo, "foo body")
	editor_open_path(&e.ed, foo)
	testing.expect(t, editor_find_buffer(&e.ed, foo) >= 0, "foo.txt is open")

	nav_alt(&e, 'f')
	testing.expect_value(t, ft_entries(&e.ed)[0].name, "sub") // dirs sort first

	e2e_key(&e, .Arrow_Down) // onto foo.txt
	e2e_key(&e, .Ctrl_X) // cut foo.txt
	e2e_key(&e, .Arrow_Up) // onto sub/
	e2e_key(&e, .Ctrl_V) // paste into sub

	moved := fmt.aprintf("%s/foo.txt", sub)
	defer delete(moved)
	testing.expect(t, os.exists(moved), "cut+paste moves the file into the directory")
	testing.expect(t, !os.exists(foo), "the original path is gone after a move")
	testing.expect(t, editor_find_buffer(&e.ed, moved) >= 0, "open buffer repathed to the new location")
	testing.expect(t, editor_find_buffer(&e.ed, foo) < 0, "no buffer left at the old path")

	// A cut clipboard is consumed: a second paste does nothing.
	e2e_key(&e, .Ctrl_V)
	testing.expect_value(t, e.ed.message, "Nothing to paste")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_footer_single_row :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	e2e_render(&e)

	lay := ft_layout(&e.ed)
	footer := e2e_row(&e, lay.footer_y)

	// One line of how-to-select/run, not per-command hints; the All scope also
	// shows the right-aligned ignored/dotfiles toggle chips (hint clips to fit).
	for hint in ([?]string{"tabs", "select", "ignored", "dotfiles"}) {
		testing.expect(t, strings.contains(footer, hint), fmt.tprintf("footer shows %q", hint))
	}
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_filter_prunes :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	for name in ([?]string{"editor.odin", "edit.odin", "buffer.odin"}) {
		nav_write(fmt.tprintf("%s/%s", e.ed.working_root, name), "body")
	}

	nav_alt(&e, 'f')

	entry_named :: proc(ed: ^Editor, name: string) -> bool {
		for entry in ft_entries(ed) {
			if entry.name == name {
				return true
			}
		}
		return false
	}

	// Typing prunes the tree to fuzzy matches; unrelated files drop out.
	e2e_type(&e, "edt")
	testing.expect(t, entry_named(&e.ed, "editor.odin"), "filter keeps a fuzzy match")
	testing.expect(t, entry_named(&e.ed, "edit.odin"), "filter keeps another fuzzy match")
	testing.expect(t, !entry_named(&e.ed, "buffer.odin"), "filter prunes a non-match")

	// Esc clears a non-empty query first, then closes.
	e2e_key(&e, .Esc)
	testing.expect_value(t, ft_query(&e.ed), "")
	testing.expect(t, entry_named(&e.ed, "buffer.odin"), "cleared filter restores the full tree")
	testing.expect(t, filetree_active(&e.ed), "first Esc only clears the query")
	e2e_key(&e, .Esc)
	testing.expect(t, !filetree_active(&e.ed), "second Esc closes the pane")
}

@(test)
e2e_nav_filetree_filter_incremental :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	for name in ([?]string{"alpha.txt", "alps.txt", "beta.txt"}) {
		nav_write(fmt.tprintf("%s/%s", e.ed.working_root, name), "body")
	}

	nav_alt(&e, 'f')

	entry_named :: proc(ed: ^Editor, name: string) -> bool {
		for entry in ft_entries(ed) {
			if entry.name == name {
				return true
			}
		}
		return false
	}

	// Base query, ranked from scratch over every candidate.
	e2e_type(&e, "alp")
	testing.expect(t, entry_named(&e.ed, "alpha.txt"), "base keeps alpha")
	testing.expect(t, entry_named(&e.ed, "alps.txt"), "base keeps alps")
	testing.expect(t, !entry_named(&e.ed, "beta.txt"), "base drops beta")

	// Extending the query re-ranks only the prior match set: `alph` is a
	// subsequence of alpha but not alps, so a prior match must drop out.
	e2e_type(&e, "h")
	testing.expect(t, entry_named(&e.ed, "alpha.txt"), "incremental keeps alpha")
	testing.expect(t, !entry_named(&e.ed, "alps.txt"), "incremental drops a prior match that no longer matches")
	testing.expect(t, !entry_named(&e.ed, "beta.txt"), "incremental still drops beta")
}

@(test)
e2e_nav_filetree_filter_caps_display :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	total := WALK_FILTER_MAX_RESULTS + 20
	for i in 0 ..< total {
		nav_write(fmt.tprintf("%s/zqx%d.txt", e.ed.working_root, i), "b")
	}

	nav_alt(&e, 'f')
	e2e_type(&e, "zqx")

	// The visible list is capped, but the full ranked match set is retained so
	// incremental narrowing stays correct.
	testing.expect_value(t, len(ft_entries(&e.ed)), WALK_FILTER_MAX_RESULTS)
	testing.expect(
		t,
		len(ft_tree_list(&e.ed).tree.source.narrow_idx) > WALK_FILTER_MAX_RESULTS,
		"full match set is tracked beyond the display cap",
	)

	// When capped, the filter line shows the cap with a trailing +.
	nav_preview(&e)
	lay := ft_layout(&e.ed)
	e2e_render(&e)
	testing.expect(
		t,
		strings.contains(e2e_row(&e, lay.filter_y), fmt.tprintf("%d+", WALK_FILTER_MAX_RESULTS)),
		"capped filter shows the cap+ on the filter line",
	)
}

@(test)
e2e_nav_filetree_palette_runs_command :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	src := fmt.aprintf("%s/a.txt", e.ed.working_root)
	defer delete(src)
	nav_write(src, "original")

	nav_alt(&e, 'f')
	testing.expect_value(t, ft_entries(&e.ed)[0].name, "a.txt")

	// Ctrl+P over the tree lists file commands, not the global set.
	e2e_key(&e, .Ctrl_P)
	e2e_ui_settle(&e)
	labels := palette_ui_labels(&e)
	testing.expect(t, labels != "", "Ctrl+P opens the palette over the tree")
	testing.expect(t, strings.contains(labels, "|Workspace: Open Selected Directory|"), "tree-scoped plugin commands are listed")
	testing.expect(t, !strings.contains(labels, "|Save|"), "editor commands are not")
	testing.expect(t, filetree_active(&e.ed), "the palette sits over the tree")
	e2e_render(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Command Palette") >= 0, "the palette draws over the tree")
	tree_box := node_rect(&e.ed, "filetree")
	box := node_rect(&e.ed, "palette")
	testing.expect(t, tree_box.x < box.x && box.x + box.w < tree_box.x + tree_box.w, "the tree box is wider than the palette")
	testing.expect_value(t, e2e_cell(&e, box.x, box.y), '┌')
	testing.expect_value(t, e2e_cell(&e, tree_box.x, box.y + 1), '│')
	e2e_type(&e, "copy")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Command Palette") < 0, "running a command closes the palette")
	testing.expect(t, filetree_active(&e.ed), "the tree stays open")
	testing.expect_value(t, e.ed.message, "Copied a.txt")

	e2e_key(&e, .Ctrl_V) // paste the copy back
	copy := fmt.aprintf("%s/a (copy).txt", e.ed.working_root)
	defer delete(copy)
	testing.expect(t, os.exists(copy), "palette Copy + Ctrl+V pastes a copy")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_copy_preserves_mode :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	src := fmt.aprintf("%s/run.sh", e.ed.working_root)
	defer delete(src)
	nav_write(src, "#!/bin/sh\necho hi\n")
	os.chmod(src, os.perm(0o755))

	nav_alt(&e, 'f')
	for ft_entries(&e.ed)[ft_sel(&e.ed)].name != "run.sh" {
		e2e_key(&e, .Arrow_Down)
	}
	e2e_key(&e, .Ctrl_C)
	e2e_key(&e, .Ctrl_V)

	copy := fmt.aprintf("%s/run (copy).sh", e.ed.working_root)
	defer delete(copy)
	testing.expect(t, os.exists(copy), "executable copy created")
	info, serr := os.stat(copy, context.temp_allocator)
	testing.expect(t, serr == nil, "stat the copy")
	testing.expect(t, os.Permission_Flag.Execute_User in info.mode, "copied script keeps its +x bit")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_batch_delete :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	names := [?]string{"a.txt", "b.txt", "c.txt"}
	for name in names {
		path := fmt.tprintf("%s/%s", e.ed.working_root, name)
		nav_write(path, "body")
	}

	nav_alt(&e, 'f')
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift)
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift) // range a..c

	e2e_key(&e, .Ctrl_D)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.ConfirmDelete)
	testing.expect_value(t, ft_confirm_text(&e.ed), "Delete 3 items?")
	// a refill under the confirm (a status push, a write) must not shrink what it deletes
	walk_stale(ft_walk(&e.ed))
	nav_write(fmt.tprintf("%s/zz.txt", e.ed.working_root), "z")
	ft_trees_settle(&e.ed)
	lo, hi := ft_sel_range(&e.ed)
	testing.expect_value(t, hi - lo, 2)

	e2e_key(&e, .Arrow_Down) // Cancel -> Delete
	e2e_key(&e, .Enter) // one confirmation deletes all

	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	for name in names {
		path := fmt.tprintf("%s/%s", e.ed.working_root, name)
		testing.expect(t, !os.exists(path), "batch delete removed every selected entry")
	}
	testing.expect(t, os.exists(e.path), "main.txt outside the range survives")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_batch_open :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	a := fmt.aprintf("%s/a.txt", e.ed.working_root)
	defer delete(a)
	nav_write(a, "a body")
	b := fmt.aprintf("%s/b.txt", e.ed.working_root)
	defer delete(b)
	nav_write(b, "b body")

	nav_alt(&e, 'f')
	testing.expect_value(t, ft_entries(&e.ed)[0].name, "a.txt")

	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift) // range a..b

	e2e_key(&e, .Enter) // batch open every file in the range
	testing.expect(t, !filetree_active(&e.ed), "batch open closes the tree")
	testing.expect(t, editor_find_buffer(&e.ed, a) >= 0, "a.txt opened")
	testing.expect(t, editor_find_buffer(&e.ed, b) >= 0, "b.txt opened")
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "b.txt"), "last-opened buffer stays focused")
}

@(test)
e2e_nav_quit_guard :: proc(t: ^testing.T) {
	e := e2e_start("hello")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	testing.expect(t, b.modified, "buffer is now modified")

	e2e_key(&e, .Ctrl_Q)
	testing.expect(t, safety_dialog(&e.ed) == "quit", "Ctrl+Q on a modified buffer opens the quit dialog")
	testing.expect(t, !e.ed.quit, "editor does not quit yet")

	// Choose the non-destructive Cancel action.
	e2e_key(&e, .Arrow_Up)
	e2e_key(&e, .Enter)
	testing.expect(t, safety_dialog(&e.ed) != "quit", "Cancel closes the dialog")
	testing.expect(t, !e.ed.quit, "editor stays open")
	testing.expect(t, b.modified, "edit is preserved")
}

@(test)
e2e_nav_status_and_message :: proc(t: ^testing.T) {
	e := e2e_start("hello world")
	defer e2e_stop(&e)

	_, h := editor_viewport(&e.ed)
	status_y := h
	message_y := h + 1

	e2e_render(&e)
	status := e2e_row(&e, status_y)
	testing.expect(t, strings.contains(status, "1/1"), "status shows line/total")
	testing.expect(t, strings.contains(status, ".txt"), "status shows the path")
	testing.expect(t, !strings.contains(status, ICON_MODIFIED), "clean buffer has no modified flag")

	e2e_type(&e, "X")
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_row(&e, status_y), ICON_MODIFIED), "editing shows the modified flag")

	// A transient message lands on the message line and clears on the next input.
	nav_alt(&e, ',') // Jump Back with no history -> message
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_row(&e, message_y), "No earlier position"), "action message shows")

	e2e_type(&e, "y")
	e2e_render(&e)
	testing.expect(t, !strings.contains(e2e_row(&e, message_y), "No earlier position"), "message clears on next input")
}

@(test)
e2e_nav_filetree_toggle_reopens :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	nav_scan(&e)

	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f opens the file tree on All")
	testing.expect_value(t, ft_scope(&e.ed), "All")
	nav_alt(&e, 'g')
	testing.expect(t, filetree_active(&e.ed), "Alt+g while open switches to Git, stays open")
	testing.expect_value(t, ft_scope(&e.ed), "Git")
	nav_alt(&e, 'g')
	testing.expect(t, !filetree_active(&e.ed), "Alt+g again (same tab) closes it")
	nav_alt(&e, 'f')
	testing.expect(t, filetree_active(&e.ed), "Alt+f reopens it on All")
	testing.expect_value(t, ft_scope(&e.ed), "All")
	nav_alt(&e, 'f')
	testing.expect(t, !filetree_active(&e.ed), "Alt+f again (same tab) closes it")
}

@(test)
e2e_nav_filetree_rebound_bind_toggles :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	e2e_plugin_config(&e, "filetree", `{"keybinds": {"All": "Alt+j"}}`, hot = true)
	nav_alt(&e, 'j')
	testing.expect(t, filetree_active(&e.ed), "rebound chord opens the pane")
	nav_alt(&e, 'j')
	testing.expect(t, !filetree_active(&e.ed), "rebound chord again (same tab) closes it")
	nav_alt(&e, 'f')
	testing.expect(t, !filetree_active(&e.ed), "the old chord no longer opens it")
}

@(test)
e2e_nav_filetree_borrowed_bind_follows :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	idx := -1
	for cmd, i in commands {
		if cmd.name == "Copy" {
			idx = i
		}
	}
	saved := commands[idx]
	defer commands[idx] = saved
	tree, _ := plugin_test_command(&e.ed, "File Tree: Copy")
	testing.expect_value(t, tree.shortcut, "Ctrl+c")
	commands[idx].key, commands[idx].shortcut = .Ctrl_B, "Ctrl+b"
	plugins_config_apply(&e.ed, false)
	tree, _ = plugin_test_command(&e.ed, "File Tree: Copy")
	testing.expect_value(t, tree.shortcut, "Ctrl+b")
	nav_alt(&e, 'f')
	e2e_key(&e, .Ctrl_B)
	testing.expect_value(t, e.ed.message, "Copied main.txt")
}

@(test)
e2e_nav_filetree_root_change_closed_resets :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	sub := fmt.tprintf("%s/sub", e.dir)
	os.make_directory(sub)
	nav_write(fmt.tprintf("%s/x.txt", sub), "x")
	nav_alt(&e, 'f')
	testing.expect(t, nav_select(&e.ed, "sub"))
	e2e_key(&e, .Enter)
	e2e_key(&e, .Esc)
	nav_alt(&e, 'f')
	testing.expect(t, ft_expanded_count(&e.ed) > 0 && nav_select(&e.ed, "x.txt"), "a reopened tree keeps its expanded dirs")
	e2e_key(&e, .Esc)
	editor_change_root(&e.ed, e.dir)
	editor_change_root(&e.ed, sub)
	plugin_flush(&e.ed)
	nav_alt(&e, 'f')
	testing.expect_value(t, ft_expanded_count(&e.ed), 0)
}

@(test)
e2e_nav_filetree_marks_current_buffer :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	other := fmt.aprintf("%s/other.txt", e.ed.working_root)
	defer delete(other)
	nav_write(other, "other body")

	nav_alt(&e, 'f')
	e2e_key(&e, .Arrow_Down) // move selection off "main.txt" (sorts before "other.txt")
	e2e_render(&e)

	lay := ft_layout(&e.ed)

	entry_cell :: proc(e: ^E2E, lay: FtLayout, name: string) -> (fg, bg: tb2.Color) {
		for entry, i in ft_entries(&e.ed) {
			if entry.name == name {
				y := lay.body_top + (i - ft_scroll(&e.ed))
				return e2e_cell_fg(e, lay.inner.x + 3, y), e2e_cell_bg(e, lay.inner.x + 3, y)
			}
		}
		return .Default, .Default
	}

	fg, _ := entry_cell(&e, lay, "main.txt")
	testing.expect_value(t, fg, COLOR_PANE_PROMPT_FG)
	fg, _ = entry_cell(&e, lay, "other.txt")
	testing.expect(t, fg != COLOR_PANE_PROMPT_FG, "non-current entry keeps the default color")

	e2e_key(&e, .Arrow_Up) // selection back onto "main.txt"
	e2e_render(&e)
	bg: tb2.Color
	fg, bg = entry_cell(&e, lay, "main.txt")
	testing.expect_value(t, fg, COLOR_PANE_PROMPT_FG)
	testing.expect_value(t, bg, COLOR_PANE_SEL_BG)
}

@(test)
e2e_nav_filetree_new_file_nested_dirs :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	e2e_key(&e, .Ctrl_N)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.New)
	e2e_type(&e, "a/b/c.txt")
	e2e_key(&e, .Enter)

	full := fmt.aprintf("%s/a/b/c.txt", e.ed.working_root)
	defer delete(full)
	testing.expect(t, os.exists(full), "nested new file exists on disk")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/a/b", e.ed.working_root)), "intermediate dirs were created")
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)

	sel, ok := ft_selected(&e.ed)
	testing.expect(t, ok, "a row is selected after reveal")
	testing.expect(t, strings.has_suffix(sel.path, "c.txt"), "reveal selects the new nested file")
}

@(test)
e2e_nav_filetree_delete_dialog_cancel :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	testing.expect_value(t, ft_entries(&e.ed)[0].name, "main.txt")

	e2e_key(&e, .Ctrl_D)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.ConfirmDelete)
	dialog, _ := test_dialog(&e.ed)
	testing.expect_value(t, dialog.selected, "Cancel")
	testing.expect_value(t, ft_confirm_text(&e.ed), "Delete main.txt?")

	e2e_key(&e, .Esc)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect(t, os.exists(e.path), "Esc cancels, file survives")
	testing.expect(t, filetree_active(&e.ed), "Esc on the dialog only closes the dialog, not the tree")
}

@(test)
e2e_nav_filetree_delete_dialog_default_enter_cancels :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	e2e_key(&e, .Ctrl_D)
	e2e_key(&e, .Enter) // default selection is Cancel

	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect(t, os.exists(e.path), "Enter on default Cancel does not delete")
}

@(test)
e2e_nav_filetree_delete_dialog_confirm_file :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	e2e_key(&e, .Ctrl_D)
	e2e_key(&e, .Arrow_Down) // Cancel -> Delete
	e2e_key(&e, .Enter)

	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect(t, !os.exists(e.path), "confirming Delete removes the file")
	testing.expect_value(t, e.ed.message_level, LogLevel.Info)
}

@(test)
e2e_nav_filetree_delete_dialog_directory :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	sub := fmt.aprintf("%s/sub", e.ed.working_root)
	defer delete(sub)
	os.make_directory(sub)
	inner := fmt.aprintf("%s/inner.txt", sub)
	defer delete(inner)
	nav_write(inner, "inner body")

	nav_alt(&e, 'f')
	testing.expect_value(t, ft_entries(&e.ed)[0].name, "sub") // dirs sort first

	e2e_key(&e, .Ctrl_D)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.ConfirmDelete)
	testing.expect_value(t, ft_confirm_text(&e.ed), "Delete sub/ and its contents?")

	e2e_key(&e, .Arrow_Down) // Cancel -> Delete
	e2e_key(&e, .Enter)

	testing.expect(t, !os.exists(sub), "confirming Delete removes the directory recursively")
	testing.expect(t, !os.exists(inner), "nested file is gone too")
}

nav_select :: proc(ed: ^Editor, name: string) -> bool {
	for entry in ft_entries(ed) {
		if entry.name == name {
			ft_select_path(ed, entry.path)
			return true
		}
	}
	return false
}

nav_screen_find :: proc(e: ^E2E, text: string) -> (x, y: int, ok: bool) {
	for row in 0 ..< E2E_H {
		line := e2e_row(e, row)
		if i := strings.index(line, text); i >= 0 {
			return strings.rune_count(line[:i]), row, true
		}
	}
	return
}

@(test)
e2e_nav_git_deleted_file :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("one\n")
	defer e2e_stop(&e)
	e2e_resize(&e, 200, E2E_H)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)
	q := shell_quote(e.dir)
	gone := fmt.tprintf("%s/sub/gone.txt", e.dir)
	os.make_directory(fmt.tprintf("%s/sub", e.dir))
	nav_write(gone, "alpha\nbeta\n")
	e2e_run(fmt.tprintf("cd %s && git add sub && git commit -q -m sub && rm -r sub", q))

	nav_alt(&e, 'g')
	nav_scan(&e)
	testing.expect(t, nav_select(&e.ed, "sub"), "vanished dir listed virtually")
	testing.expect(t, nav_select(&e.ed, "gone.txt"), "deleted file listed under its old dir")
	testing.expect(t, ft_sel_deleted(&e.ed), "the deleted row is marked deleted")
	nav_preview(&e)
	testing.expect_value(t, ft_preview_line(&e.ed, 0), "alpha")
	testing.expect_value(t, ft_preview_line(&e.ed, 1), "beta")

	e2e_render(&e)
	x, y, found := nav_screen_find(&e, "gone.txt")
	testing.expect(t, found, "deleted row renders")
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, x, y)), e2e_rgb(COLOR_GIT_DEL))

	e2e_key(&e, .Ctrl_R)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect(t, strings.contains(e.ed.message, "restore it first"), "rename refuses a deleted entry")
	e2e_key(&e, .Ctrl_D)
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)

	e2e_key(&e, .Enter)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {
		_, asked := test_dialog(&e.ed)
		return !asked
	})
	dialog, asked := test_dialog(&e.ed)
	testing.expect(t, asked && len(dialog.labels) > 0, "the git plugin asks to confirm")
	testing.expect_value(t, dialog.question, "Restore gone.txt from HEAD?")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	e2e_git_settle(&e)
	data, err := os.read_entire_file(gone, context.temp_allocator)
	testing.expect(t, err == nil, "restored on disk")
	testing.expect_value(t, string(data), "alpha\nbeta\n")
	testing.expect(t, !nav_select(&e.ed, "gone.txt"), "restored file is clean again")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_git_renamed_file :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n", "old.txt")
	defer e2e_stop(&e)
	e2e_resize(&e, 200, E2E_H)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)
	q := shell_quote(e.dir)
	e2e_run(fmt.tprintf("cd %s && git mv old.txt new.txt", q))
	nav_write(fmt.tprintf("%s/new.txt", e.dir), "l1\nl2\nl3\nCHANGED\nl5\nl6\nl7\nl8\n")

	check :: proc(t: ^testing.T, e: ^E2E) {
		nav_alt(e, 'g')
		nav_scan(e)
		testing.expect(t, !nav_select(&e.ed, "old.txt"), "old path not listed")
		testing.expect(t, nav_select(&e.ed, "new.txt"), "rename listed at the new path")
		nav_preview(e)
		changed := false
		if preview := ft_preview(&e.ed); preview != nil {
			for line in 0 ..< len(preview.lines) {
				changed ||= string(preview.lines[line].text[:]) == "CHANGED"
			}
		}
		testing.expect(t, changed, "the diff-only preview shows the changed row of the rename")
		e2e_render(e)
		_, _, found := nav_screen_find(e, fmt.tprintf("new.txt  %s old.txt", ICON_TREE_RENAMED))
		testing.expect(t, found, "row label shows the old path")
		_, _, sized := nav_screen_find(e, "+1  -1")
		testing.expect(t, sized, "diff size is the rename diff, not a full add")
		e2e_key(e, .Esc)
	}
	check(t, &e)

	e2e_run(fmt.tprintf("cd %s && git commit -qam moved", q))
	for c in e.ed.plugins.commands {
		if c.name == "Git: Set Diff Base" {
			plugin_command_run(&e.ed, c)
		}
	}
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return test_view(&e.ed) == nil})
	e2e_type(&e, "seed")
	e2e_key(&e, .Enter)
	e2e_git_settle(&e)
	check(t, &e)
}

@(test)
e2e_nav_git_non_utf8 :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("one\n")
	defer e2e_stop(&e)
	e2e_resize(&e, 200, E2E_H)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)
	latin := fmt.tprintf("%s/latin.txt", e.dir)
	bin := fmt.tprintf("%s/bin.dat", e.dir)
	nav_write(latin, "caf\xe9\n")
	nav_write(bin, "a\x00b\n")
	e2e_run(fmt.tprintf("cd %s && git add . && git commit -q -m bytes", shell_quote(e.dir)))
	nav_write(latin, "caf\xe9 au lait\n")
	nav_write(bin, "a\x00c\n")

	testing.expect(t, editor_open_path(&e.ed, bin))
	e2e_git_settle(&e)
	git := plugin_find(&e.ed.plugins, "git")
	testing.expect_value(t, git.state, PluginState.Enabled)
	testing.expect_value(t, diffbase_owner(editor_buffer(&e.ed)), "git")

	nav_alt(&e, 'g')
	nav_scan(&e)
	testing.expect(t, nav_select(&e.ed, "latin.txt"))
	nav_preview(&e)
	testing.expect(t, ft_preview(&e.ed) != nil && strings.contains(ft_preview_line(&e.ed, 0), "lait"), "a Latin-1 file previews its changed row")
	testing.expect(t, nav_select(&e.ed, "bin.dat"))
	nav_preview(&e)
	testing.expect(t, strings.has_prefix(ft_preview_line(&e.ed, 0), "0000"), "a binary file previews as a hexdump")
	testing.expect_value(t, git.state, PluginState.Enabled)
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_git_deleted_unicode :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("one\n")
	defer e2e_stop(&e)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)
	gone := fmt.tprintf("%s/é.txt", e.dir)
	nav_write(gone, "x\n")
	e2e_run(fmt.tprintf("cd %s && git add . && git commit -q -m u && rm é.txt", shell_quote(e.dir)))

	nav_alt(&e, 'g')
	nav_scan(&e)
	testing.expect(t, nav_select(&e.ed, "é.txt"), "unicode deleted name listed verbatim")
	testing.expect(t, ft_sel_deleted(&e.ed), "the deleted row is marked deleted")

	nav_write(gone, "new\n")
	e2e_key(&e, .Enter)
	e2e_git_settle(&e)
	testing.expect(t, pane_focus(&e.ed) == nil, "no restore prompt over a recreated file")
	data, _ := os.read_entire_file(gone, context.temp_allocator)
	testing.expect_value(t, string(data), "new\n")
}
