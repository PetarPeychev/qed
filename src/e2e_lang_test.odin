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
	testing.expect(t, e.ed.message_error, "missing formatter reports an error")
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
	e2e_key(&e, tb2.Key(0), .Alt, 'g')
	testing.expect(t, g_diff_view, "Alt+g enables diff view")
	e2e_render(&e)

	gutter := editor_gutter_width(&e.ed)
	// Screen rows: 0 alpha, 1 bravo, 2 ghost "charlie", 3 live "charlieX".
	testing.expect_value(t, e2e_cell(&e, 0, 2), '▌')
	testing.expect_value(t, e2e_cell(&e, gutter+0, 2), 'c')
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter+0, 2)), e2e_rgb(COLOR_GHOST_FG))
}
