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

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, e.ed.picker.active, "Ctrl+O opens the file picker from welcome")
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.picker.active, "Esc closes the picker")

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

	e2e_type(&e, "line wrap")
	p := &e.ed.palette
	testing.expect(t, len(p.matches) > 0, "fuzzy query should match a command")
	testing.expect_value(t, commands[p.matches[p.selected]].name, "Toggle Line Wrap")

	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.palette.active, "Enter closes the palette")
	testing.expect(t, !b.wrap, "the selected command actually ran")
}

@(test)
e2e_nav_file_open_and_close :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "second body")

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, e.ed.picker.active, "Ctrl+O opens the picker")
	e2e_type(&e, "second")
	e2e_key(&e, .Enter)

	testing.expect(t, !e.ed.picker.active, "picker closes after opening")
	testing.expect_value(t, len(e.ed.buffers), 2)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "second.txt"), "second.txt is now current")

	// Close Buffer (Ctrl+w) returns to the other buffer.
	e2e_key(&e, .Ctrl_W)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "main.txt"), "closing returns to main.txt")
}

@(test)
e2e_nav_buffer_switcher :: proc(t: ^testing.T) {
	e := e2e_root_start("alpha one\nalpha two")
	defer e2e_stop(&e)

	second := fmt.aprintf("%s/second.txt", e.ed.working_root)
	defer delete(second)
	nav_write(second, "bravo one\nbravo two")
	editor_open_path(&e.ed, second)
	testing.expect_value(t, e.ed.current, 1)

	// Empty-query digit instant-jump: '1' selects the first buffer.
	nav_alt(&e, 'e')
	testing.expect(t, e.ed.bufswitch.active, "Alt+e opens the switcher")
	e2e_type(&e, "1")
	testing.expect_value(t, e.ed.current, 0)

	// Side preview follows the selection.
	nav_alt(&e, 'e')
	pv := &e.ed.bufswitch
	testing.expect_value(t, string(pv.preview.src[0]), "alpha one")
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, string(pv.preview.src[0]), "bravo one")
	e2e_key(&e, .Esc)
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
	e2e_type(&e, ".") // toggle dotfiles on
	testing.expect(t, tr.show_dotfiles, "'.' enables dotfiles")
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

	// Ignored file hidden until toggled on ('i').
	testing.expect(t, !entry_named(tr, "debug.log"), "gitignored file hidden by default")
	e2e_type(&e, "i")
	testing.expect(t, tr.show_ignored, "'i' enables ignored")
	testing.expect(t, entry_named(tr, "debug.log"), "ignored file now visible")

	// Git scope prunes to changed files; the untracked add shows up.
	e2e_key(&e, .Arrow_Right) // All -> Open
	e2e_key(&e, .Arrow_Right) // Open -> Git
	testing.expect_value(t, tr.scope, FileTreeScope.Git)
	testing.expect(t, entry_named(tr, "new.txt"), "Git scope lists the untracked add")
	e2e_key(&e, .Esc)
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
	testing.expect(t, e.ed.filetree.active, "Alt+f opens the file tree")
	nav_alt(&e, 'f')
	testing.expect(t, !e.ed.filetree.active, "Alt+f again closes it")
	nav_alt(&e, 'f')
	testing.expect(t, e.ed.filetree.active, "Alt+f reopens it")
}

@(test)
e2e_nav_bufswitch_alt_e_toggles_ctrl_e_inert :: proc(t: ^testing.T) {
	e := e2e_start("first buffer")
	defer e2e_stop(&e)

	path2 := e2e_mouse_scratch(".txt")
	defer {
		os.remove(path2)
		delete(path2)
	}
	_ = os.write_entire_file(path2, transmute([]u8)string("second buffer"))
	editor_open_path(&e.ed, path2)

	nav_alt(&e, 'e')
	testing.expect(t, e.ed.bufswitch.active, "Alt+e (the configured bind) opens the switcher")

	e2e_key(&e, .Ctrl_E)
	testing.expect(t, e.ed.bufswitch.active, "Ctrl+E is not the configured bind, so it no longer closes it")

	nav_alt(&e, 'e')
	testing.expect(t, !e.ed.bufswitch.active, "Alt+e again closes it")
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
	nav_alt(&e, 'f')
	testing.expect(t, e.ed.filetree.active, "the old chord no longer closes it")
	nav_alt(&e, 'z')
	testing.expect(t, !e.ed.filetree.active, "rebound chord closes it")
	nav_alt(&e, 'f')
	testing.expect(t, !e.ed.filetree.active, "the old chord no longer opens it")
}
