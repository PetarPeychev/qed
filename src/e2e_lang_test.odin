package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
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
	_, asked := test_dialog(&e.ed)
	testing.expect(t, !asked, "Alt+m outside a block should not open the dialog")
	testing.expect_value(t, b.cursor.row, 1)

	e2e_key(&e, tb2.Key(0), .Alt, 'm')
	dialog, opened := test_dialog(&e.ed)
	testing.expect(t, opened && dialog.question == "Resolve merge conflict:", "Alt+m inside a block opens the dialog")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Resolve merge conflict:"), "the dialog asks")
	testing.expect(t, e2e_grid_has(&e, "Keep Theirs"), "the dialog lists the choices")

	e2e_key(&e, .Enter)
	_, asked = test_dialog(&e.ed)
	testing.expect(t, !asked, "executing closes the dialog")
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

@(private = "file")
diff_node_row :: proc(e: ^E2E, needle: string) -> (y, x: int) {
	for y in 0 ..< int(tb2.height()) {
		row := e2e_row(e, y)
		if at := strings.index(row, needle); at >= 0 {
			return y, strings.rune_count(row[:at])
		}
	}
	return -1, -1
}

@(private = "file")
diff_node_mount :: proc(e: ^E2E, diff: string) {
	ft_lua(&e.ed, fmt.tprintf(`
		if not _G.dn_buffer then
			local base, text = {{}}, {{}}
			for i = 1, 40 do
				base[i] = "row " .. i
				text[#text + 1] = i == 10 and "row 10 changed" or "row " .. i
				if i == 30 then text[#text + 1] = "added" end
			end
			_G.dn_buffer = qed.buf.create{{internal = true}}
			dn_buffer:set_text(table.concat(text, "\n"))
			dn_buffer:set_base(table.concat(base, "\n"))
		end
		if _G.dn_mount then dn_mount:unmount() end
		_G.dn_mount = qed.ui.mount("pane", qed.ui.box{{float = "screen", width = 40, height = 22,
			qed.ui.editor{{id = "dn_view", buffer = dn_buffer, line_numbers = true, diff = %s}}}})
		return 0`, diff))
	e2e_render(e)
	e2e_render(e)
}

@(test)
e2e_editor_node_diff_view :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	saved := g_diff_view
	defer g_diff_view = saved
	g_diff_view = false

	diff_node_mount(&e, "false")
	testing.expect(t, !e2e_grid_has(&e, "⋮"), "no gap rows without diff")
	y, _ := diff_node_row(&e, "row 10 changed")
	ghost, _ := diff_node_row(&e, "row 10 ")
	testing.expect(t, y > 0 && ghost == y, "no ghost row: the global diff view is off")

	diff_node_mount(&e, "true")
	y, _ = diff_node_row(&e, "row 10 changed")
	ghost_y, ghost_x := diff_node_row(&e, "row 10 ")
	testing.expect_value(t, ghost_y, y - 1)
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, ghost_x, ghost_y)), e2e_rgb(COLOR_GHOST_FG))
	testing.expect(t, strings.contains(e2e_row(&e, y), "10 row 10 changed"), "the live line keeps its line number")
	_, x := diff_node_row(&e, "row 10 changed")
	tinted := e2e_rgb(e2e_cell_bg(&e, x, y))
	testing.expect(t, tinted != e2e_rgb(e2e_cell_bg(&e, x, y + 1)), "the modified row is tinted")
	testing.expect(t, e2e_rgb(e2e_cell_bg(&e, x + 7, y)) != tinted, "its changed span is emphasized")
	testing.expect(t, e2e_grid_has(&e, " 1 row 1 "), "the whole file from the top")

	diff_node_mount(&e, `"changes"`)
	testing.expect(t, !e2e_grid_has(&e, " row 1 "), "rows far from a change are hidden")
	first, _ := diff_node_row(&e, "row 7")
	testing.expect(t, strings.contains(e2e_row(&e, first), " 7 row 7"), "the view starts at the first change's context")
	testing.expect(t, !e2e_grid_has(&e, "row 6"), "nothing above the first change's context")
	ghost_y, ghost_x = diff_node_row(&e, "row 10 ")
	y, _ = diff_node_row(&e, "row 10 changed")
	testing.expect_value(t, ghost_y, y - 1)
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, ghost_x, ghost_y)), e2e_rgb(COLOR_GHOST_FG))
	gap, _ := diff_node_row(&e, "⋮")
	testing.expect_value(t, gap, y + 4)
	testing.expect(t, strings.contains(e2e_row(&e, gap + 1), "28 row 28"), "real line numbers after the gap")
	added, added_x := diff_node_row(&e, "added")
	testing.expect(t, strings.contains(e2e_row(&e, added), "31 added"), "the added line keeps its number")
	testing.expect(t, e2e_rgb(e2e_cell_bg(&e, added_x, added)) != e2e_rgb(e2e_cell_bg(&e, added_x, added + 1)), "the added row is tinted")
	testing.expect(t, !e2e_grid_has(&e, "row 20"), "a hidden run is one gap row")
}

@(test)
e2e_editor_node_diff_scrolls_sideways :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	ft_lua(&e.ed, `
		local buffer = qed.buf.create{internal = true}
		buffer:set_text("top\n0123456789ABCDEFGH new tail\nend")
		buffer:set_base("top\n0123456789ABCDEFGH old tail\nend")
		_G.ds_mount = qed.ui.mount("pane", qed.ui.box{float = "screen", width = 40, height = 8,
			qed.ui.editor{id = "ds_view", buffer = buffer, line_numbers = true, wrap = false, diff = true}})
		return 0`)
	e2e_render(&e)
	e2e_render(&e)
	node := ui_find(&e.ed.ui, "#fthelper/ds_view")
	testing.expect(t, node != nil, "the view is mounted")
	if node == nil {
		return
	}
	ui_node_state(&e.ed.ui, node).scroll_col = 10
	e2e_render(&e)
	live_y, live_x := diff_node_row(&e, "ABCDEFGH new")
	ghost_y, ghost_x := diff_node_row(&e, "ABCDEFGH old")
	testing.expect(t, live_y > 0, "the live row scrolled")
	testing.expect_value(t, ghost_y, live_y - 1)
	testing.expect_value(t, ghost_x, live_x)
	testing.expect(t, !e2e_grid_has(&e, "0123"), "nothing left of the scroll shows")
	testing.expect(t, e2e_rgb(e2e_cell_bg(&e, ghost_x + 9, ghost_y)) != e2e_rgb(e2e_cell_bg(&e, ghost_x, ghost_y)), "the ghost's changed word stays on it")
	testing.expect(t, e2e_rgb(e2e_cell_bg(&e, live_x + 9, live_y)) != e2e_rgb(e2e_cell_bg(&e, live_x, live_y)), "the live row's changed word stays on it")
}

@(test)
e2e_line_wrap_toggle_is_global :: proc(t: ^testing.T) {
	e := e2e_start("main")
	defer e2e_stop(&e)
	testing.expect_value(t, g_line_wrap, LINE_WRAP)
	ft_lua(&e.ed, `
		local buffer = qed.buf.create{internal = true}
		buffer:set_text("alpha bravo charlie delta echo foxtrot golf hotel india juliet")
		_G.lw_mount = qed.ui.mount("pane", qed.ui.box{float = "screen", width = 30, height = 14, qed.ui.column{
			qed.ui.editor{id = "lw_field", buffer = buffer, height = 1},
			qed.ui.editor{id = "lw_view", buffer = buffer, height = 4},
			qed.ui.editor{id = "lw_on", buffer = buffer, height = 4, wrap = true},
			qed.ui.editor{id = "lw_off", buffer = buffer, height = 4, wrap = false}}})
		return 0`)
	// the second screen row of each view shows the line's tail only when that view wraps
	wraps :: proc(e: ^E2E, id: string) -> bool {
		e2e_render(e)
		node := ui_find(&e.ed.ui, fmt.tprintf("#fthelper/%s", id))
		return node != nil && strings.contains(e2e_row(e, node.rect.y + 1), "golf")
	}
	for on in ([2]bool{false, true}) {
		if g_line_wrap != on {
			cmd_toggle_line_wrap(&e.ed)
		}
		testing.expect_value(t, wraps(&e, "lw_view"), on)
		testing.expect(t, wraps(&e, "lw_on"), "wrap = true forces it, beside other views of the same buffer")
		testing.expect(t, !wraps(&e, "lw_off"), "wrap = false forces it off")
		testing.expect(t, !wraps(&e, "lw_field"), "a one-row field never wraps")
	}
}

@(test)
e2e_editor_node_diff_changes_wraps :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	ft_lua(&e.ed, `
		local base, text = {}, {}
		for i = 1, 30 do
			base[i] = "row " .. i
			text[i] = i == 10 and "row 10 alpha bravo charlie delta echo foxtrot golf hotel india" or "row " .. i
		end
		text[25] = "row 25 changed"
		local buffer = qed.buf.create{internal = true}
		buffer:set_text(table.concat(text, "\n"))
		buffer:set_base(table.concat(base, "\n"))
		_G.dw_mount = qed.ui.mount("pane", qed.ui.box{float = "screen", width = 40, height = 22,
			qed.ui.editor{id = "dw_view", buffer = buffer, line_numbers = true, wrap = true, diff = "changes"}})
		return 0`)
	e2e_render(&e)
	e2e_render(&e)
	live, _ := diff_node_row(&e, "row 10 alpha")
	ghost, _ := diff_node_row(&e, "row 10 ")
	testing.expect_value(t, ghost, live - 1)
	tail, _ := diff_node_row(&e, "india")
	testing.expect(t, tail > live, "the long changed line wraps onto continuation rows")
	next, _ := diff_node_row(&e, "11 row 11")
	testing.expect_value(t, next, tail + 1)
	gap, _ := diff_node_row(&e, "⋮")
	testing.expect_value(t, gap, next + 3)
	testing.expect(t, strings.contains(e2e_row(&e, gap + 1), "22 row 22"), "real line numbers after the gap")
	testing.expect(t, !e2e_grid_has(&e, "row 18"), "rows away from the changes stay hidden while wrapping")
}

@(test)
e2e_highlight_background_job :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/qed_e2e_bgjob_%d.py", tmp, posix.getpid())
	big := strings.repeat("def f(a, b):\n    return a + b\n", 12000, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)big)
	defer os.remove(path)

	testing.expect(t, editor_open_path(&e.ed, path), "open")
	b := editor_buffer(&e.ed)
	id := b.id
	e2e_render(&e)
	testing.expect(t, highlight_busy(b), "a large buffer parses in the background")
	buffer_reload(b)
	testing.expect(t, !highlight_busy(b), "a reload cancels the in-flight parse")
	e2e_render(&e)
	testing.expect(t, highlight_busy(b), "the reloaded text parses again")

	e.ed.current = 0
	for _ in 0 ..< 1000 {
		if !highlight_busy(&e.ed.buffers[1]) {
			break
		}
		highlight_jobs_pump(&e.ed)
		time.sleep(5 * time.Millisecond)
	}
	b = &e.ed.buffers[1]
	testing.expect_value(t, b.id, id)
	testing.expect(t, !highlight_busy(b), "a background buffer's finished parse is adopted")

	_ = os.write_entire_file(path, transmute([]u8)string("changed\n"))
	editor_poll_disk(&e.ed)
	testing.expect_value(t, string(e.ed.buffers[1].lines[0].text[:]), "changed")
}
