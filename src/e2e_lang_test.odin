package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "lib:tb2"

e2e_lang_start :: proc(content: string, name: string) -> E2E {
	e2e_enter()
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_lang_%d_%d_%s", tmp, posix.getpid(), e2e_seq, name)
	_ = os.write_entire_file(path, transmute([]u8)content)
	ed := editor_init(path, headless = true)
	return E2E{ed = ed, path = path}
}

@(test)
e2e_highlight_keyword :: proc(t: ^testing.T) {
	e := e2e_lang_start("package main", "hl.odin")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect_value(t, b.language, Language.Odin)

	// Small buffers parse synchronously inside highlight_update, so one render is
	// enough to have the tree ready and painted.
	e2e_render(&e)
	testing.expect(t, !highlight_busy(b), "small buffer should parse synchronously")

	gutter := editor_gutter_width(&e.ed)
	// 'p' of the `package` keyword carries the keyword color; 'm' of the `main`
	// identifier does not.
	testing.expect_value(t, e2e_cell(&e, gutter+0, 0), 'p')
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter+0, 0)), e2e_rgb(COLOR_SYN_KEYWORD))
	testing.expect_value(t, e2e_cell(&e, gutter+8, 0), 'm')
	testing.expect(t, e2e_rgb(e2e_cell_fg(&e, gutter+8, 0)) != e2e_rgb(COLOR_SYN_KEYWORD), "identifier is not keyword-colored")
}

CONFLICT_SEED :: "top\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\ntail"

@(test)
e2e_conflict_tints :: proc(t: ^testing.T) {
	e := e2e_start(CONFLICT_SEED)
	defer e2e_stop(&e)

	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)

	// A cell past a line's text keeps the row's line background untinted by any
	// word-diff / selection, so it reads the pure ours/theirs tint.
	ours_bg := e2e_cell_bg(&e, gutter+10, 2)
	theirs_bg := e2e_cell_bg(&e, gutter+10, 4)
	tail_bg := e2e_cell_bg(&e, gutter+10, 6)

	testing.expect_value(t, ours_bg, color_over(COLOR_BG, COLOR_CONFLICT_OURS, CONFLICT_TINT))
	testing.expect_value(t, theirs_bg, color_over(COLOR_BG, COLOR_CONFLICT_THEIRS, CONFLICT_TINT))
	testing.expect_value(t, tail_bg, COLOR_BG)
	testing.expect(t, ours_bg != COLOR_BG, "ours tint differs from normal bg")
	testing.expect(t, theirs_bg != COLOR_BG, "theirs tint differs from normal bg")
	testing.expect(t, ours_bg != theirs_bg, "ours and theirs tints differ")
}

@(test)
e2e_conflict_resolve_keep_ours :: proc(t: ^testing.T) {
	e := e2e_start(CONFLICT_SEED)
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect_value(t, len(b.lines), 7)

	// Cursor outside the block: Alt+m jumps to the next block instead of resolving.
	b.cursor = {0, 0}
	e2e_key(&e, tb2.Key(0), .Alt, 'm')
	testing.expect(t, !e.ed.merge_dialog.active, "Alt+m outside a block should not open the dialog")
	testing.expect_value(t, b.cursor.row, 1)

	// Now inside the block, Alt+m opens the resolve dialog.
	e2e_key(&e, tb2.Key(0), .Alt, 'm')
	testing.expect(t, e.ed.merge_dialog.active, "Alt+m inside a block opens the dialog")

	// Keep Ours is the default selection; Enter executes it.
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.merge_dialog.active, "executing closes the dialog")
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, string(b.lines[0].text[:]), "top")
	testing.expect_value(t, string(b.lines[1].text[:]), "ours")
	testing.expect_value(t, string(b.lines[2].text[:]), "tail")

	// The whole resolve is a single undo group.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, len(b.lines), 7)
	testing.expect_value(t, string(b.lines[1].text[:]), "<<<<<<< HEAD")
	testing.expect_value(t, string(b.lines[4].text[:]), "theirs")
}

@(test)
e2e_format_on_save :: proc(t: ^testing.T) {
	e := e2e_start("hello\nworld")
	defer e2e_stop(&e)

	stub := e2e_stub_script("tr 'a-z' 'A-Z'")
	defer {
		os.remove(stub)
		delete(stub)
	}

	b := editor_buffer(&e.ed)
	old_fmt := LANGUAGES[.Plain].formatter
	LANGUAGES[.Plain].formatter = stub
	old_fos := e.ed.format_on_save
	e.ed.format_on_save = true
	defer {
		LANGUAGES[.Plain].formatter = old_fmt
		e.ed.format_on_save = old_fos
	}

	e2e_key(&e, .Ctrl_S)
	testing.expect_value(t, string(b.lines[0].text[:]), "HELLO")
	testing.expect_value(t, string(b.lines[1].text[:]), "WORLD")

	// Format-on-save writes the formatted bytes to disk.
	data, rerr := os.read_entire_file(e.path, context.temp_allocator)
	testing.expect(t, rerr == nil, "file should exist on disk")
	testing.expect_value(t, string(data), "HELLO\nWORLD")

	// The formatter output is one undo group: a single Ctrl+Z restores the input.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "hello")
	testing.expect_value(t, string(b.lines[1].text[:]), "world")
}

@(test)
e2e_format_run_logs_debug :: proc(t: ^testing.T) {
	e := e2e_start("hello\nworld")
	defer e2e_stop(&e)

	stub := e2e_stub_script("tr 'a-z' 'A-Z'")
	defer {
		os.remove(stub)
		delete(stub)
	}

	old := LANGUAGES[.Plain].formatter
	LANGUAGES[.Plain].formatter = stub
	defer LANGUAGES[.Plain].formatter = old

	format_document(&e.ed)

	// The user-facing message-line behaviour is unchanged.
	testing.expect(t, strings.contains(e.ed.message, "Formatted"), "format still messages the line")

	// The silent internal run leaves a Debug trail entry in the ring.
	found := false
	for entry in e.ed.log {
		if entry.level == .Debug && entry.source == "Format" {
			found = true
		}
	}
	testing.expect(t, found, "format run logged a Debug trail entry")
}

@(test)
e2e_trim_trailing_whitespace :: proc(t: ^testing.T) {
	e := e2e_start("foo   \n\tbar\t\n   \nbaz")
	defer e2e_stop(&e)

	e.ed.trim_trailing_whitespace_on_save = true

	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_S)

	testing.expect_value(t, string(b.lines[0].text[:]), "foo")
	testing.expect_value(t, string(b.lines[1].text[:]), "\tbar")
	testing.expect_value(t, string(b.lines[2].text[:]), "")
	testing.expect_value(t, string(b.lines[3].text[:]), "baz")

	data, rerr := os.read_entire_file(e.path, context.temp_allocator)
	testing.expect(t, rerr == nil, "file should exist on disk")
	testing.expect_value(t, string(data), "foo\n\tbar\n\nbaz")

	// One undo step restores the pre-save whitespace.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "foo   ")
	testing.expect_value(t, string(b.lines[1].text[:]), "\tbar\t")
	testing.expect_value(t, string(b.lines[2].text[:]), "   ")
}

@(test)
e2e_trim_cursor_clamped :: proc(t: ^testing.T) {
	e := e2e_start("word    \nnext")
	defer e2e_stop(&e)

	e.ed.trim_trailing_whitespace_on_save = true

	b := editor_buffer(&e.ed)
	b.cursor = {0, 7}
	e2e_key(&e, .Ctrl_S)

	testing.expect_value(t, string(b.lines[0].text[:]), "word")
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 4)
}

@(test)
e2e_ensure_final_newline :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)

	e.ed.ensure_final_newline_on_save = true

	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_S)
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, string(b.lines[2].text[:]), "")

	data, _ := os.read_entire_file(e.path, context.temp_allocator)
	testing.expect_value(t, string(data), "alpha\nbeta\n")

	// An already-terminated buffer gains no second empty line.
	e2e_key(&e, .Ctrl_S)
	testing.expect_value(t, len(b.lines), 3)
}

@(test)
e2e_markdown_save_fixups :: proc(t: ^testing.T) {
	e := e2e_lang_start("break2  \nbreak3   \none \ntab \t\n   \nlast", "notes.md")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect_value(t, b.language, Language.Markdown)

	e.ed.trim_trailing_whitespace_on_save = true
	e.ed.ensure_final_newline_on_save = true

	e2e_key(&e, .Ctrl_S)

	// 2+ trailing spaces on a content line are a hard break: untouched, never normalized.
	testing.expect_value(t, string(b.lines[0].text[:]), "break2  ")
	testing.expect_value(t, string(b.lines[1].text[:]), "break3   ")
	// One trailing space or a tab-ended run is no hard break: trimmed.
	testing.expect_value(t, string(b.lines[2].text[:]), "one")
	testing.expect_value(t, string(b.lines[3].text[:]), "tab")
	// Whitespace-only lines always trim to empty.
	testing.expect_value(t, string(b.lines[4].text[:]), "")
	// The final newline still applies to markdown.
	testing.expect_value(t, len(b.lines), 7)
	testing.expect_value(t, string(b.lines[6].text[:]), "")

	data, _ := os.read_entire_file(e.path, context.temp_allocator)
	testing.expect_value(t, string(data), "break2  \nbreak3   \none\ntab\n\nlast\n")
}

@(test)
e2e_trim_newline_no_double :: proc(t: ^testing.T) {
	e := e2e_start("end\n   ")
	defer e2e_stop(&e)

	e.ed.trim_trailing_whitespace_on_save = true
	e.ed.ensure_final_newline_on_save = true

	b := editor_buffer(&e.ed)
	e2e_key(&e, .Ctrl_S)

	// The trimmed-empty last line already is the final newline: nothing is appended.
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, string(b.lines[1].text[:]), "")
	testing.expect_value(t, e2e_read_disk(e.path), "end\n")
}

@(test)
e2e_save_fixups_off_identical :: proc(t: ^testing.T) {
	seed := "keep  \ntrailing\t\nno newline"
	e := e2e_start(seed)
	defer e2e_stop(&e)

	e.ed.trim_trailing_whitespace_on_save = false
	e.ed.ensure_final_newline_on_save = false

	b := editor_buffer(&e.ed)
	undo_before := len(b.undo)
	e2e_key(&e, .Ctrl_S)

	testing.expect_value(t, len(b.undo), undo_before)
	data, _ := os.read_entire_file(e.path, context.temp_allocator)
	testing.expect_value(t, string(data), seed)
}

@(test)
e2e_trim_before_format :: proc(t: ^testing.T) {
	e := e2e_start("foo   \nbar\t")
	defer e2e_stop(&e)

	tmp, _ := os.temp_dir(context.temp_allocator)
	sidecar := fmt.aprintf("%s/qed_e2e_fmtin_%d_%d", tmp, posix.getpid(), e2e_seq)
	defer {
		os.remove(sidecar)
		delete(sidecar)
	}
	stub := e2e_stub_script(fmt.tprintf("tee %s", shell_quote(sidecar)))
	defer {
		os.remove(stub)
		delete(stub)
	}

	old_fmt := LANGUAGES[.Plain].formatter
	LANGUAGES[.Plain].formatter = stub
	defer LANGUAGES[.Plain].formatter = old_fmt
	e.ed.trim_trailing_whitespace_on_save = true
	e.ed.format_on_save = true

	e2e_key(&e, .Ctrl_S)

	// The formatter's stdin is already trimmed: trim runs before format-on-save.
	seen, serr := os.read_entire_file(sidecar, context.temp_allocator)
	testing.expect(t, serr == nil, "formatter should have run and teed its stdin")
	testing.expect_value(t, string(seen), "foo\nbar")
}

@(test)
e2e_quit_save_all_fixups_format :: proc(t: ^testing.T) {
	e := e2e_start("foo  \nbar")
	defer e2e_stop(&e)

	stub := e2e_stub_script("tr 'a-z' 'A-Z'")
	defer {
		os.remove(stub)
		delete(stub)
	}
	old_fmt := LANGUAGES[.Plain].formatter
	LANGUAGES[.Plain].formatter = stub
	defer LANGUAGES[.Plain].formatter = old_fmt
	e.ed.format_on_save = true
	e.ed.trim_trailing_whitespace_on_save = true
	e.ed.ensure_final_newline_on_save = true

	e2e_type(&e, "z")
	testing.expect(t, editor_buffer(&e.ed).modified, "typing dirties the buffer")

	e2e_key(&e, .Ctrl_Q)
	testing.expect(t, e.ed.quit_dialog.active, "Ctrl+Q on a modified buffer opens the quit dialog")
	e2e_key(&e, .Enter)

	testing.expect(t, e.ed.quit, "Save All quits after the saves complete")
	testing.expect_value(t, e2e_read_disk(e.path), "ZFOO\nBAR\n")
}

@(test)
e2e_close_save_fixups :: proc(t: ^testing.T) {
	e := e2e_start("baz  ")
	defer e2e_stop(&e)

	e.ed.trim_trailing_whitespace_on_save = true

	e2e_type(&e, "!")
	e2e_key(&e, .Ctrl_W)
	testing.expect(t, e.ed.close_dialog.active, "Ctrl+W on a modified buffer opens the close dialog")
	e2e_key(&e, .Enter)

	testing.expect_value(t, e2e_read_disk(e.path), "!baz")
	testing.expect(t, e.ed.welcome, "saving the last buffer closes it back to the welcome screen")
}

@(test)
e2e_conflict_overwrite_fixups_format :: proc(t: ^testing.T) {
	e := e2e_start("first  \nsecond")
	defer e2e_stop(&e)

	stub := e2e_stub_script("tr 'a-z' 'A-Z'")
	defer {
		os.remove(stub)
		delete(stub)
	}
	old_fmt := LANGUAGES[.Plain].formatter
	LANGUAGES[.Plain].formatter = stub
	defer LANGUAGES[.Plain].formatter = old_fmt
	e.ed.format_on_save = true
	e.ed.trim_trailing_whitespace_on_save = true

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	_ = os.write_entire_file(e.path, transmute([]u8)string("DISK\n"))
	editor_poll_disk(&e.ed)

	e2e_key(&e, .Ctrl_S)
	testing.expect(t, e.ed.conflict_dialog.active, "Ctrl+S should open the conflict dialog")

	e2e_key(&e, .Arrow_Down) // Cancel -> Overwrite
	e2e_key(&e, .Enter)

	testing.expect(t, !e.ed.conflict_dialog.active, "dialog closes after choosing")
	testing.expect_value(t, b.modified, false)
	testing.expect_value(t, b.disk_conflict, false)
	testing.expect_value(t, e2e_read_disk(e.path), "XFIRST\nSECOND")
}

@(test)
e2e_toggle_trim_empty_lines :: proc(t: ^testing.T) {
	e := e2e_start("top\n\n\nbottom")
	defer e2e_stop(&e)

	cmd_toggle_trim_whitespace_on_save(&e.ed)

	b := editor_buffer(&e.ed)
	b.cursor = {1, 0}
	e2e_type(&e, "  ")
	b.cursor = {2, 0}
	e2e_type(&e, "   ")
	testing.expect_value(t, string(b.lines[1].text[:]), "  ")
	testing.expect_value(t, string(b.lines[2].text[:]), "   ")

	e2e_key(&e, .Ctrl_S)

	testing.expect_value(t, string(b.lines[1].text[:]), "")
	testing.expect_value(t, string(b.lines[2].text[:]), "")
	testing.expect_value(t, b.cursor.row, 2)
	testing.expect_value(t, b.cursor.col, 0)
	testing.expect_value(t, e2e_read_disk(e.path), "top\n\n\nbottom")
}

@(test)
e2e_toggle_save_knobs :: proc(t: ^testing.T) {
	e := e2e_start("pad  ")
	defer e2e_stop(&e)

	e.ed.trim_trailing_whitespace_on_save = false
	e.ed.ensure_final_newline_on_save = false

	cmd_toggle_trim_whitespace_on_save(&e.ed)
	testing.expect(t, e.ed.trim_trailing_whitespace_on_save, "toggle flips the runtime knob on")
	testing.expect(t, strings.contains(e.ed.message, "Trim whitespace on save: on"), "toggle reports its state")
	cmd_toggle_final_newline_on_save(&e.ed)
	testing.expect(t, e.ed.ensure_final_newline_on_save, "toggle flips the runtime knob on")
	testing.expect(t, strings.contains(e.ed.message, "Final newline on save: on"), "toggle reports its state")

	// A config reload updates the globals but never clobbers the runtime toggles
	// (same semantics as format_on_save: the global only seeds editor_init).
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	cfg := fmt.aprintf("%s/qed_e2e_cfg_%d_%d.json", tmp, posix.getpid(), e2e_seq)
	defer {
		os.remove(cfg)
		delete(cfg)
	}
	_ = os.write_entire_file(
		cfg,
		transmute([]u8)string(`{"trim_trailing_whitespace_on_save": false, "ensure_final_newline_on_save": false}`),
	)
	_, cfg_err := config_load_from(cfg)
	testing.expect(t, !cfg_err, "knob-only config loads cleanly")
	testing.expect(t, !TRIM_TRAILING_WHITESPACE_ON_SAVE, "reload applied the config value to the global")
	testing.expect(t, e.ed.trim_trailing_whitespace_on_save, "runtime toggle survives the reload")
	testing.expect(t, e.ed.ensure_final_newline_on_save, "runtime toggle survives the reload")

	e2e_key(&e, .Ctrl_S)
	testing.expect_value(t, e2e_read_disk(e.path), "pad\n")
}

@(test)
e2e_format_missing_tool :: proc(t: ^testing.T) {
	e := e2e_start("keep\nthis")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	old_fmt := LANGUAGES[.Plain].formatter
	LANGUAGES[.Plain].formatter = "qed_no_such_formatter_zzz --stdin"
	old_fos := e.ed.format_on_save
	e.ed.format_on_save = true
	defer {
		LANGUAGES[.Plain].formatter = old_fmt
		e.ed.format_on_save = old_fos
	}

	// A missing formatter reports an error and leaves the buffer untouched.
	format_document(&e.ed)
	testing.expect(t, e.ed.message_level == .Error, "missing formatter reports an error")
	testing.expect(t, strings.contains(e.ed.message, "not found"), "message names the missing tool")
	testing.expect_value(t, string(b.lines[0].text[:]), "keep")
	testing.expect_value(t, string(b.lines[1].text[:]), "this")

	// Format-on-save with the tool missing still saves, unformatted.
	e2e_key(&e, .Ctrl_S)
	data, rerr := os.read_entire_file(e.path, context.temp_allocator)
	testing.expect(t, rerr == nil, "file should exist on disk")
	testing.expect_value(t, string(data), "keep\nthis")
}

@(test)
e2e_git_marks_add_modify :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("alpha\nbravo\ncharlie\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)

	// Modify a committed line and append a fresh line.
	b.cursor = {0, len(b.lines[0].text)}
	e2e_type(&e, "X")
	b.cursor = {2, len(b.lines[2].text)}
	e2e_key(&e, .Enter)
	e2e_type(&e, "delta")
	e2e_render(&e)
	testing.expect_value(t, git_mark_at(b, 0), GitMark.Modified)
	testing.expect_value(t, git_mark_at(b, 3), GitMark.Added)
	testing.expect_value(t, git_mark_at(b, 1), GitMark.None)
}

@(test)
e2e_git_mark_delete :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("alpha\nbravo\ncharlie\n")
	defer e2e_stop(&e)

	// Deleting a whole committed line marks the surviving neighbour line.
	b := editor_buffer(&e.ed)
	b.cursor = {1, 0}
	for _ in 0 ..< 6 {
		e2e_key(&e, .Delete)
	}
	testing.expect_value(t, string(b.lines[1].text[:]), "charlie")
	e2e_render(&e)
	testing.expect_value(t, git_mark_at(b, 0), GitMark.Deleted)
}

@(test)
e2e_git_diff_view_ghost :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("alpha\nbravo\ncharlie\ndelta\n")
	defer e2e_stop(&e)

	saved_diff := g_diff_view
	defer g_diff_view = saved_diff

	b := editor_buffer(&e.ed)
	// Modify a non-top line so its ghost row can render above it (the top visible
	// row's above-ghost is intentionally suppressed).
	b.cursor = {2, len(b.lines[2].text)}
	e2e_type(&e, "X")
	e2e_render(&e)
	testing.expect_value(t, git_mark_at(b, 2), GitMark.Modified)

	// Toggle diff view on; the removed base line renders as a ghost row above the
	// live modified line, marked by the deletion gutter glyph.
	cmd_toggle_diff_view(&e.ed)
	testing.expect(t, g_diff_view, "the command enables diff view")
	e2e_render(&e)

	gutter := editor_gutter_width(&e.ed)
	// Screen rows: 0 alpha, 1 bravo, 2 ghost "charlie", 3 live "charlieX".
	testing.expect_value(t, e2e_cell(&e, 0, 2), '▌')
	testing.expect_value(t, e2e_cell(&e, gutter+0, 2), 'c')
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter+0, 2)), e2e_rgb(COLOR_GHOST_FG))
}
