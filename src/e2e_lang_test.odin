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
	e := e2e_start("top\n<<<<<<< HEAD\nkeep a\n=======\nkeep b\n>>>>>>> branch\ntail")
	defer e2e_stop(&e)
	plugin_pump(&e.ed)
	plugin_flush(&e.ed)
	editor_buffer(&e.ed).cursor = {6, 0}
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)

	ours_bg := color_over(COLOR_BG, COLOR_CONFLICT_OURS, CONFLICT_TINT)
	theirs_bg := color_over(COLOR_BG, COLOR_CONFLICT_THEIRS, CONFLICT_TINT)
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 10, 2), ours_bg)
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 10, 4), theirs_bg)
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 10, 0), COLOR_BG)
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 20, 1), color_over(COLOR_BG, COLOR_CONFLICT_OURS, CONFLICT_MARKER_TINT))
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 20, 5), color_over(COLOR_BG, COLOR_CONFLICT_THEIRS, CONFLICT_MARKER_TINT))
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter, 1)), e2e_rgb(COLOR_CONFLICT_OURS))
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter, 3)), e2e_rgb(COLOR_CONFLICT_THEIRS))
	testing.expect_value(t, e2e_cell_bg(&e, gutter, 2), ours_bg)
	testing.expect_value(t, e2e_cell_bg(&e, gutter, 4), theirs_bg)
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 4, 2), ours_bg)
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 5, 2), color_over(ours_bg, COLOR_CONFLICT_OURS, CONFLICT_WORD_TINT))
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 5, 4), color_over(theirs_bg, COLOR_CONFLICT_THEIRS, CONFLICT_WORD_TINT))
	testing.expect_value(t, e2e_cell_bg(&e, gutter + 6, 4), theirs_bg)
}

@(test)
e2e_conflict_resolve_keep_ours :: proc(t: ^testing.T) {
	e := e2e_start(CONFLICT_SEED)
	defer e2e_stop(&e)
	plugin_pump(&e.ed)
	plugin_flush(&e.ed)

	b := editor_buffer(&e.ed)
	testing.expect_value(t, len(b.lines), 7)

	b.cursor = {0, 0}
	e2e_key(&e, tb2.Key(0), .Alt, 'm')
	testing.expect(t, pane_focus(&e.ed) == nil, "Alt+m outside a block should not open the dialog")
	testing.expect_value(t, b.cursor.row, 1)

	e2e_key(&e, tb2.Key(0), .Alt, 'm')
	p := pane_focus(&e.ed)
	testing.expect(t, p != nil && p.owner == "conflict", "Alt+m inside a block opens the dialog")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Resolve merge conflict:"), "the dialog asks")
	testing.expect(t, e2e_grid_has(&e, "Keep Theirs"), "the dialog lists the choices")

	e2e_key(&e, .Enter)
	testing.expect(t, pane_focus(&e.ed) == nil, "executing closes the dialog")
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, string(b.lines[0].text[:]), "top")
	testing.expect_value(t, string(b.lines[1].text[:]), "ours")
	testing.expect_value(t, string(b.lines[2].text[:]), "tail")
	testing.expect_value(t, len(b.deco.items), 0)

	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, len(b.lines), 7)
	testing.expect_value(t, string(b.lines[1].text[:]), "<<<<<<< HEAD")
	testing.expect_value(t, string(b.lines[4].text[:]), "theirs")
	testing.expect(t, len(b.deco.items) > 0, "undo brings the highlight back")
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
	testing.expect_value(t, diff_mark_at(b, 0), DiffMark.Modified)
	testing.expect_value(t, diff_mark_at(b, 3), DiffMark.Added)
	testing.expect_value(t, diff_mark_at(b, 1), DiffMark.None)
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
	testing.expect_value(t, diff_mark_at(b, 0), DiffMark.Deleted)
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
	testing.expect_value(t, diff_mark_at(b, 2), DiffMark.Modified)

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
