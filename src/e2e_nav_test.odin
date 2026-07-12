package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
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
	delete(ed.working_root)
	ed.working_root = strings.clone(dir)
	return E2E{ed = ed, dir = dir}
}

nav_alt :: proc(e: ^E2E, ch: rune) {
	editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = ch, mod = .Alt})
}

nav_write :: proc(path, content: string) {
	_ = os.write_entire_file(path, transmute([]u8)content)
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
	rows := wrap_rows(last, b.wrap_width)
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
	testing.expect(t, e.ed.filetree.active, "Alt+f opens the file tree from welcome")
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.filetree.active, "Esc closes the file tree")

	e2e_key(&e, .Ctrl_P)
	testing.expect(t, e.ed.palette.active, "Ctrl+P opens the command palette from welcome")
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.palette.active, "Esc closes the palette")
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
	testing.expect(t, e.ed.logview.active, "Alt+l opens the log pane from welcome")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Message Log"), "the log pane renders over welcome")

	nav_alt(&e, 'l')
	testing.expect(t, !e.ed.logview.active, "Alt+l again closes the pane on welcome")
	nav_alt(&e, 'l')
	testing.expect(t, e.ed.logview.active, "and reopens it")

	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.logview.active, "Esc closes the log pane")
	testing.expect(t, e.ed.welcome, "closing returns to the welcome screen")
}

@(test)
e2e_nav_palette :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, e.ed.palette.active, "Ctrl+P opens the palette")

	p := &e.ed.palette
	rows := min(len(p.matches), PALETTE_MAX_ROWS)
	box := pane_center(&e.ed, PALETTE_WIDTH, 2 + rows)
	border_x := box.x + box.w - 1
	testing.expect(t, len(p.matches) > rows, "the command list should overflow the palette")
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, border_x, box.y + 3), '┃')
	testing.expect_value(t, e2e_cell_fg(&e, border_x, box.y + 3), COLOR_PANE_FG)

	e2e_type(&e, "line wrap")
	testing.expect(t, len(p.matches) > 0, "fuzzy query should match a command")
	testing.expect_value(t, palette_command(p, p.selected).name, "Toggle Line Wrap")

	rows = min(len(p.matches), PALETTE_MAX_ROWS)
	box = pane_center(&e.ed, PALETTE_WIDTH, 2 + rows)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, box.x + box.w - 1, box.y + 3), '│')

	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.palette.active, "Enter closes the palette")
	testing.expect(t, !b.wrap, "the selected command actually ran")
}

@(test)
e2e_nav_palette_welcome_filter :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)

	testing.expect(t, e.ed.welcome, "a no-file session shows the welcome screen")
	e2e_key(&e, .Ctrl_P)
	p := &e.ed.palette
	testing.expect(t, p.active, "Ctrl+P opens the palette from welcome")

	has := proc(p: ^Palette, name: string) -> bool {
		for i in p.indices {
			if commands[i].name == name {
				return true
			}
		}
		return false
	}
	testing.expect(t, !has(p, "Save"), "a buffer-only command is hidden on welcome")
	testing.expect(t, !has(p, "Toggle Comment"), "editing commands are hidden on welcome")
	testing.expect(t, !has(p, "LSP: Go to Definition"), "LSP commands are hidden on welcome")
	testing.expect(t, has(p, "File Tree"), "File Tree stays available on welcome")
	testing.expect(t, has(p, "Set Theme"), "Set Theme stays available on welcome")
	testing.expect(t, has(p, "Quit"), "Quit stays available on welcome")
}

@(test)
e2e_nav_file_open_and_close :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "second body")

	nav_alt(&e, 'f')
	testing.expect(t, e.ed.filetree.active, "Alt+f opens the file tree")
	e2e_type(&e, "second")
	e2e_key(&e, .Enter)

	testing.expect(t, !e.ed.filetree.active, "tree closes after opening")
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

	nav_alt(&e, 'f')
	testing.expect(t, e.ed.filetree.active, "Alt+f opens the file tree")

	tr := &e.ed.filetree
	lay := filetree_layout(&e.ed)
	testing.expect(t, len(tr.entries) > lay.body_h, "20 files should overflow the tree's body")
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, lay.div_x, lay.body_top), '┃')

	e2e_type(&e, "f00")
	testing.expect(t, len(tr.entries) <= lay.body_h, "a narrow query should fit without a scrollbar")
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, lay.div_x, lay.body_top), '│')

	e2e_key(&e, .Esc)
	testing.expect(t, len(tr.filter.text) == 0, "Esc first clears the filter")
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.filetree.active, "Esc then closes the tree")
}

@(test)
e2e_nav_open_tab_inmemory_preview :: proc(t: ^testing.T) {
	e := e2e_root_start("alpha one\nalpha two")
	defer e2e_stop(&e)

	// Unsaved in-memory edit to the current buffer.
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	cursor_goal_sync(b)
	e2e_type(&e, "X")

	// The Open tab previews the open buffer's in-memory content, not disk.
	nav_alt(&e, 'o')
	testing.expect_value(t, e.ed.filetree.scope, FileTreeScope.Open)
	tr := &e.ed.filetree
	for entry, i in tr.entries {
		if entry.name == "main.txt" {
			tr.selected = i
		}
	}
	filetree_load_preview(&e.ed)
	testing.expect_value(t, string(tr.preview.src[0]), "Xalpha one")
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
	testing.expect(t, e.ed.filetree.active, "Alt+o opens the Open tab")
	e2e_type(&e, "main")
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.filetree.active, "Enter switches and closes the tree")
	testing.expect_value(t, e.ed.current, 0)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "main.txt"), "switched to main.txt")

	// Ctrl+W on an all-clean selection closes immediately, no dialog.
	nav_alt(&e, 'o')
	tr := &e.ed.filetree
	for entry, i in tr.entries {
		if entry.name == "second.txt" {
			tr.selected = i
		}
	}
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.Nav)
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
	tr := &e.ed.filetree
	for entry, i in tr.entries {
		if entry.name == "second.txt" {
			tr.selected = i
		}
	}

	// An unsaved buffer in the selection routes Ctrl+W through the confirm dialog.
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.ConfirmClose)
	e2e_key(&e, .Enter) // default action is "Cancel"
	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.Nav)
	testing.expect_value(t, len(e.ed.buffers), 2)

	// Reopen, confirm "Close all" discards the unsaved buffer.
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.ConfirmClose)
	e2e_key(&e, .Arrow_Down) // move to "Close all"
	e2e_key(&e, .Enter)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "main.txt"), "main.txt remains")
}

@(test)
e2e_nav_find_navigation :: proc(t: ^testing.T) {
	e := e2e_start("foo\nbar\nfoo")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}
	gutter := editor_gutter_width(&e.ed)

	e2e_key(&e, .Ctrl_F)
	e2e_type(&e, "foo")
	testing.expect_value(t, len(e.ed.find.matches), 2)

	// The non-current match (row 2) renders with the find-match background.
	e2e_render(&e)
	testing.expect_value(t, e2e_cell_bg(&e, gutter, 2), COLOR_FIND_MATCH_BG)

	// Enter/arrows step next with wrap-around.
	testing.expect_value(t, b.cursor.row, 0)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 2)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 0)
	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, b.cursor.row, 2)
}

@(test)
e2e_nav_find_smart_case :: proc(t: ^testing.T) {
	e := e2e_start("foo bar foo\nFOO baz\nfoo")
	defer e2e_stop(&e)

	f := &e.ed.find
	e2e_key(&e, .Ctrl_F)
	e2e_type(&e, "foo")
	testing.expect_value(t, len(f.matches), 4) // smart-case: lowercase query is insensitive

	nav_alt(&e, 'c') // Aa on -> case-sensitive drops FOO
	testing.expect(t, f.case_sensitive, "Alt+c enables case-sensitive")
	testing.expect_value(t, len(f.matches), 3)

	nav_alt(&e, 'c')
	testing.expect_value(t, len(f.matches), 4)
}

@(test)
e2e_nav_find_regex :: proc(t: ^testing.T) {
	e := e2e_start("foo\nFOO\nbar")
	defer e2e_stop(&e)

	f := &e.ed.find
	e2e_key(&e, .Ctrl_F)
	e2e_type(&e, "f.o")
	testing.expect_value(t, len(f.matches), 0) // literal: no dot in the text

	nav_alt(&e, 'r') // .* toggle: now a regex, ci matches foo + FOO
	testing.expect(t, f.regex, "Alt+r enables regex")
	testing.expect_value(t, len(f.matches), 2)
}

@(test)
e2e_nav_find_replace :: proc(t: ^testing.T) {
	e := e2e_start("foo bar foo\nfoo")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	e2e_key(&e, .Ctrl_H)
	testing.expect(t, e.ed.find.active && e.ed.find.replacing, "Ctrl+H opens find in replace mode")
	e2e_type(&e, "foo")
	e2e_key(&e, .Tab) // focus the replace field
	e2e_type(&e, "X")

	e2e_key(&e, .Enter) // replace the current match
	testing.expect_value(t, string(b.lines[0].text[:]), "X bar foo")

	nav_alt(&e, 'a') // replace all remaining
	testing.expect_value(t, string(b.lines[0].text[:]), "X bar X")
	testing.expect_value(t, string(b.lines[1].text[:]), "X")
}

@(test)
e2e_nav_find_selection_prefill :: proc(t: ^testing.T) {
	e := e2e_start("foo bar foo\nbaz")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.selection = Cursor{0, 0}
	b.cursor = {0, 3} // single-line selection of "foo"

	e2e_key(&e, .Ctrl_F)
	f := &e.ed.find
	testing.expect_value(t, textfield_str(&f.field), "foo")
	testing.expect_value(t, len(f.matches), 2) // pre-fill highlights matches on open
	testing.expect_value(t, f.field.anchor, 0) // fully selected
	testing.expect_value(t, f.field.caret, 3)

	// Fully selected: one keystroke replaces the whole pre-filled query.
	e2e_type(&e, "z")
	testing.expect_value(t, textfield_str(&f.field), "z")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_find_selection_no_prefill :: proc(t: ^testing.T) {
	e := e2e_start("aa   bb\ncc")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)

	// A multi-line selection does not pre-fill.
	b.selection = Cursor{0, 0}
	b.cursor = {1, 2}
	e2e_key(&e, .Ctrl_F)
	testing.expect_value(t, textfield_str(&e.ed.find.field), "")
	e2e_key(&e, .Esc)

	// A whitespace-only selection counts as no selection.
	b.selection = Cursor{0, 2}
	b.cursor = {0, 5}
	e2e_key(&e, .Ctrl_F)
	testing.expect_value(t, textfield_str(&e.ed.find.field), "")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_line_jump_selection_prefill :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta\nalpha2\nalpha3")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.selection = Cursor{0, 0}
	b.cursor = {0, 5} // select "alpha"

	e2e_key(&e, .Ctrl_G)
	p := &e.ed.linefind
	testing.expect_value(t, textfield_str(&p.field), "alpha")
	testing.expect_value(t, len(p.matches), 3) // filter ran on the pre-fill
	testing.expect_value(t, p.field.anchor, 0) // fully selected
	testing.expect_value(t, p.field.caret, 5)
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_project_search_selection_prefill :: proc(t: ^testing.T) {
	if !shell_command_exists("rg") {
		return
	}
	e := e2e_root_start("needle_xyz here\nneedle_xyz again\nneedle_xyz third")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	p := &e.ed.projsearch

	nav_alt(&e, 'F')
	e2e_type(&e, "needle_xyz")
	testing.expect(t, len(p.matches) >= 2, "multiple hits for the query")
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, p.selected, 1)
	e2e_key(&e, .Esc)

	// Persisted-query reopen (no selection) restores the selected match.
	nav_alt(&e, 'F')
	testing.expect_value(t, p.selected, 1)
	e2e_key(&e, .Esc)

	// A pre-fill replaces the query, so the selection resets to the first match.
	b.selection = Cursor{0, 0}
	b.cursor = {0, 10} // select "needle_xyz"
	nav_alt(&e, 'F')
	testing.expect_value(t, textfield_str(&p.field), "needle_xyz")
	testing.expect(t, len(p.matches) > 0, "pre-filled query runs the search on open")
	testing.expect_value(t, p.field.anchor, 0) // fully selected
	testing.expect_value(t, p.field.caret, 10)
	testing.expect_value(t, p.selected, 0)
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
	p := &e.ed.linefind
	testing.expect_value(t, len(p.matches), 3)
	testing.expect_value(t, p.matches[0], 0)
	testing.expect_value(t, p.matches[1], 3)
	testing.expect_value(t, p.matches[2], 5)
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
e2e_nav_project_search :: proc(t: ^testing.T) {
	if !shell_command_exists("rg") {
		return
	}
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	hay := fmt.aprintf("%s/hay.txt", e.ed.working_root)
	defer delete(hay)
	nav_write(hay, "first line\nneedle_xyz here\n")

	nav_alt(&e, 'F') // Find in Files
	testing.expect(t, e.ed.projsearch.active, "Alt+F opens project search")
	e2e_type(&e, "needle_xyz")

	p := &e.ed.projsearch
	testing.expect(t, len(p.matches) > 0, "rg populates results")
	testing.expect(t, strings.has_suffix(p.matches[p.selected].path, "hay.txt"), "hit is in hay.txt")

	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.projsearch.active, "Enter closes the pane")
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "hay.txt"), "Enter opens the hit")
	testing.expect_value(t, editor_buffer(&e.ed).cursor.row, 1)
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
	testing.expect(t, e.ed.filetree.active, "Alt+f opens the file tree")

	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "sub") // dirs sort first
	e2e_key(&e, .Enter) // expand the folder
	testing.expect_value(t, tr.entries[1].name, "inner.txt")

	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter) // open the file
	testing.expect(t, !e.ed.filetree.active, "opening a file closes the tree")
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
	tr := &e.ed.filetree

	has_hidden :: proc(tr: ^FileTree) -> bool {
		for entry in tr.entries {
			if entry.name == ".hidden.txt" {
				return true
			}
		}
		return false
	}

	testing.expect(t, !has_hidden(tr), "dotfiles hidden by default")
	filetree_toggle_dotfiles(&e.ed) // palette command
	testing.expect(t, tr.show_dotfiles, "toggle enables dotfiles")
	testing.expect(t, has_hidden(tr), "dotfile now visible")

	// Scope tab bar: Right cycles All -> Open.
	testing.expect_value(t, tr.scope, FileTreeScope.All)
	e2e_key(&e, .Arrow_Right)
	testing.expect_value(t, tr.scope, FileTreeScope.Open)
	e2e_key(&e, .Arrow_Left)
	testing.expect_value(t, tr.scope, FileTreeScope.All)
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

	nav_alt(&e, 'f') // first open scans git status synchronously
	tr := &e.ed.filetree

	entry_named :: proc(tr: ^FileTree, name: string) -> bool {
		for entry in tr.entries {
			if entry.name == name {
				return true
			}
		}
		return false
	}

	// Ignored file hidden until toggled on (palette command).
	testing.expect(t, !entry_named(tr, "debug.log"), "gitignored file hidden by default")
	filetree_toggle_ignored(&e.ed)
	testing.expect(t, tr.show_ignored, "toggle enables ignored")
	testing.expect(t, entry_named(tr, "debug.log"), "ignored file now visible")

	// Git scope prunes to changed files; the untracked add shows up.
	e2e_key(&e, .Arrow_Right) // All -> Open
	e2e_key(&e, .Arrow_Right) // Open -> Git
	testing.expect_value(t, tr.scope, FileTreeScope.Git)
	testing.expect(t, entry_named(tr, "new.txt"), "Git scope lists the untracked add")
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
	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "a.txt")

	// Shift+Down twice extends a contiguous range a..c.
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift)
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift)
	lo, hi := filetree_sel_range(tr)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, 2)

	// A plain move collapses the range back to one selection.
	e2e_key(&e, .Arrow_Down)
	testing.expect(t, tr.anchor == nil, "plain move clears the anchor")
	lo, hi = filetree_sel_range(tr)
	testing.expect_value(t, lo, hi)
	testing.expect_value(t, tr.selected, 3)
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
	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "a.txt")

	e2e_key(&e, .Ctrl_C) // copy a.txt
	e2e_key(&e, .Ctrl_V) // paste into the working root (a.txt's parent)

	copy := fmt.aprintf("%s/a (copy).txt", e.ed.working_root)
	defer delete(copy)
	testing.expect(t, os.exists(copy), "collision suffix copy created")
	testing.expect(t, os.exists(src), "original survives a copy")

	sel, ok := filetree_selected(tr)
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
	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "sub") // dirs sort first

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
	testing.expect(t, len(tr.clipboard) == 0, "cut clipboard consumed on paste")
	e2e_key(&e, .Esc)
}

@(test)
e2e_nav_filetree_footer_single_row :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	e2e_render(&e)

	lay := filetree_layout(&e.ed)
	footer := e2e_row(&e, lay.footer_y)

	// One line of how-to-select/run, not per-command hints.
	for hint in ([?]string{"tabs", "select", "extend", "commands"}) {
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
	tr := &e.ed.filetree

	entry_named :: proc(tr: ^FileTree, name: string) -> bool {
		for entry in tr.entries {
			if entry.name == name {
				return true
			}
		}
		return false
	}

	// Typing prunes the tree to fuzzy matches; unrelated files drop out.
	e2e_type(&e, "edt")
	testing.expect(t, entry_named(tr, "editor.odin"), "filter keeps a fuzzy match")
	testing.expect(t, entry_named(tr, "edit.odin"), "filter keeps another fuzzy match")
	testing.expect(t, !entry_named(tr, "buffer.odin"), "filter prunes a non-match")

	// Esc clears a non-empty query first, then closes.
	e2e_key(&e, .Esc)
	testing.expect_value(t, len(tr.filter.text), 0)
	testing.expect(t, entry_named(tr, "buffer.odin"), "cleared filter restores the full tree")
	testing.expect(t, tr.active, "first Esc only clears the query")
	e2e_key(&e, .Esc)
	testing.expect(t, !tr.active, "second Esc closes the pane")
}

@(test)
e2e_nav_filetree_palette_runs_command :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	src := fmt.aprintf("%s/a.txt", e.ed.working_root)
	defer delete(src)
	nav_write(src, "original")

	nav_alt(&e, 'f')
	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "a.txt")

	// Ctrl+P over the tree lists file commands, not the global set.
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, e.ed.palette.active, "Ctrl+P opens the palette over the tree")
	testing.expect(t, e.ed.palette.filetree, "palette sources the file-command table")
	e2e_type(&e, "copy")
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.palette.active, "running a command closes the palette")
	testing.expect_value(t, len(tr.clipboard), 1)

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
	tr := &e.ed.filetree
	for tr.entries[tr.selected].name != "run.sh" {
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
	tr := &e.ed.filetree
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift)
	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift) // range a..c

	e2e_key(&e, .Ctrl_D)
	testing.expect_value(t, tr.mode, FileTreeMode.ConfirmDelete)
	testing.expect_value(t, filetree_delete_question(tr), "Delete 3 items?")

	e2e_key(&e, .Arrow_Down) // Cancel -> Delete
	e2e_key(&e, .Enter) // one confirmation deletes all

	testing.expect_value(t, tr.mode, FileTreeMode.Nav)
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
	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "a.txt")

	e2e_key(&e, .Arrow_Down, tb2.Mod.Shift) // range a..b

	e2e_key(&e, .Enter) // batch open every file in the range
	testing.expect(t, !e.ed.filetree.active, "batch open closes the tree")
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
	testing.expect(t, e.ed.quit_dialog.active, "Ctrl+Q on a modified buffer opens the quit dialog")
	testing.expect(t, !e.ed.quit, "editor does not quit yet")

	// Choose the non-destructive Cancel action.
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.quit_dialog.active, "Cancel closes the dialog")
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

	nav_alt(&e, 'f')
	testing.expect(t, e.ed.filetree.active, "Alt+f opens the file tree on All")
	testing.expect_value(t, e.ed.filetree.scope, FileTreeScope.All)
	nav_alt(&e, 'g')
	testing.expect(t, e.ed.filetree.active, "Alt+g while open switches to Git, stays open")
	testing.expect_value(t, e.ed.filetree.scope, FileTreeScope.Git)
	nav_alt(&e, 'g')
	testing.expect(t, !e.ed.filetree.active, "Alt+g again (same tab) closes it")
	nav_alt(&e, 'f')
	testing.expect(t, e.ed.filetree.active, "Alt+f reopens it on All")
	testing.expect_value(t, e.ed.filetree.scope, FileTreeScope.All)
	nav_alt(&e, 'f')
	testing.expect(t, !e.ed.filetree.active, "Alt+f again (same tab) closes it")
}

@(test)
e2e_nav_filetree_rebound_bind_toggles :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	idx := -1
	for cmd, i in commands {
		if cmd.name == "File Tree" {
			idx = i
			break
		}
	}
	testing.expect(t, idx >= 0, "command exists in the table")
	saved := commands[idx].alt_ch
	commands[idx].alt_ch = 'z'
	defer commands[idx].alt_ch = saved

	nav_alt(&e, 'z')
	testing.expect(t, e.ed.filetree.active, "rebound chord opens the pane")
	nav_alt(&e, 'z')
	testing.expect(t, !e.ed.filetree.active, "rebound chord again (same tab) closes it")
	nav_alt(&e, 'f')
	testing.expect(t, !e.ed.filetree.active, "the old chord no longer opens it")
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

	tr := &e.ed.filetree
	lay := filetree_layout(&e.ed)

	entry_cell :: proc(e: ^E2E, tr: ^FileTree, lay: FileTreeLayout, name: string) -> (fg, bg: tb2.Color) {
		for entry, i in tr.entries {
			if entry.name == name {
				y := lay.body_top + (i - tr.scroll)
				return e2e_cell_fg(e, lay.inner.x + 3, y), e2e_cell_bg(e, lay.inner.x + 3, y)
			}
		}
		return .Default, .Default
	}

	fg, _ := entry_cell(&e, tr, lay, "main.txt")
	testing.expect_value(t, fg, COLOR_PANE_PROMPT_FG)
	fg, _ = entry_cell(&e, tr, lay, "other.txt")
	testing.expect(t, fg != COLOR_PANE_PROMPT_FG, "non-current entry keeps the default color")

	e2e_key(&e, .Arrow_Up) // selection back onto "main.txt"
	e2e_render(&e)
	bg: tb2.Color
	fg, bg = entry_cell(&e, tr, lay, "main.txt")
	testing.expect_value(t, fg, COLOR_PANE_PROMPT_FG)
	testing.expect_value(t, bg, COLOR_PANE_SEL_BG)
}

@(test)
e2e_nav_filetree_new_file_nested_dirs :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	e2e_key(&e, .Ctrl_N)
	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.New)
	e2e_type(&e, "a/b/c.txt")
	e2e_key(&e, .Enter)

	full := fmt.aprintf("%s/a/b/c.txt", e.ed.working_root)
	defer delete(full)
	testing.expect(t, os.exists(full), "nested new file exists on disk")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/a/b", e.ed.working_root)), "intermediate dirs were created")
	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.Nav)

	sel, ok := filetree_selected(&e.ed.filetree)
	testing.expect(t, ok, "a row is selected after reveal")
	testing.expect(t, strings.has_suffix(sel.path, "c.txt"), "reveal selects the new nested file")
}

@(test)
e2e_nav_filetree_delete_dialog_cancel :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "main.txt")

	e2e_key(&e, .Ctrl_D)
	testing.expect_value(t, tr.mode, FileTreeMode.ConfirmDelete)
	testing.expect_value(t, tr.delete_selected, 0) // Cancel is default-selected
	testing.expect_value(t, filetree_delete_question(tr), "Delete main.txt?")

	e2e_key(&e, .Esc)
	testing.expect_value(t, tr.mode, FileTreeMode.Nav)
	testing.expect(t, os.exists(e.path), "Esc cancels, file survives")
	testing.expect(t, tr.active, "Esc on the dialog only closes the dialog, not the tree")
}

@(test)
e2e_nav_filetree_delete_dialog_default_enter_cancels :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	nav_alt(&e, 'f')
	e2e_key(&e, .Ctrl_D)
	e2e_key(&e, .Enter) // default selection is Cancel

	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.Nav)
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

	testing.expect_value(t, e.ed.filetree.mode, FileTreeMode.Nav)
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
	tr := &e.ed.filetree
	testing.expect_value(t, tr.entries[0].name, "sub") // dirs sort first

	e2e_key(&e, .Ctrl_D)
	testing.expect_value(t, tr.mode, FileTreeMode.ConfirmDelete)
	testing.expect_value(t, filetree_delete_question(tr), "Delete sub/ and its contents?")

	e2e_key(&e, .Arrow_Down) // Cancel -> Delete
	e2e_key(&e, .Enter)

	testing.expect(t, !os.exists(sub), "confirming Delete removes the directory recursively")
	testing.expect(t, !os.exists(inner), "nested file is gone too")
}
