package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(private = "file")
deco_plugin :: proc(e: ^E2E, name, body: string) -> ^Plugin {
	return e2e_plugin(e, name, fmt.tprintf(`
		return {{setup = function()
			local ns = qed.deco.ns("t")
			%s
		end}}`, body))
}

@(test)
e2e_deco_gutter_tint_eol_span :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbravo\ncharlie\ndelta\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.wrap = false
	pl := deco_plugin(&e, "dp", `
		qed.deco.gutter(nil, ns, 2, "●", "git_added")
		qed.deco.tint(nil, ns, 3, 4, "error_foreground", 0.5)
		qed.deco.eol(nil, ns, 1, "note", "warn_foreground")
		qed.deco.eol(nil, ns, 1, "more", "git_deleted")
		qed.deco.span(nil, ns, {row = 2, col = 2}, {row = 2, col = 4}, {fg = "git_modified", bold = true, underline = true})
		qed.deco.span(nil, ns, {row = 3, col = 1}, {row = 3, col = 3}, {bg = "git_added"})`)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)

	testing.expect_value(t, e2e_cell(&e, 0, 1), '●')
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, 0, 1)), e2e_rgb(COLOR_GIT_ADD))
	testing.expect_value(t, e2e_cell(&e, 0, 0), ' ')

	want_bg := color_over(COLOR_BG, COLOR_ERROR_FG, 0.5)
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 6, 2)), e2e_rgb(want_bg))
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 6, 3)), e2e_rgb(want_bg))
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 6, 1)), e2e_rgb(COLOR_BG))

	row0 := e2e_row_text(&e, 0)
	testing.expect(t, strings.has_suffix(row0, "alpha note more"), "eol text follows the line after one gap, joined in push order")
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter + 6, 0)), e2e_rgb(COLOR_WARN_FG))
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter + 11, 0)), e2e_rgb(COLOR_GIT_DEL))
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 6, 0)), e2e_rgb(color_over(COLOR_BG, COLOR_CURRENT_LINE_BG, CURRENT_LINE_TINT)))

	fg := e2e_cell_fg(&e, gutter + 1, 1)
	testing.expect_value(t, e2e_rgb(fg), e2e_rgb(COLOR_GIT_MOD))
	testing.expect(t, u64(fg) & u64(tb2.Color.Bold) != 0, "span bold")
	testing.expect(t, u64(fg) & u64(tb2.Color.Underline) != 0, "span underline")
	testing.expect(t, u64(e2e_cell_fg(&e, gutter + 3, 1)) & u64(tb2.Color.Bold) == 0, "span ends at its to col")
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 0, 2)), e2e_rgb(COLOR_GIT_ADD))
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 2, 2)), e2e_rgb(want_bg))

	b.cursor = {1, 1}
	e2e_type(&e, "x")
	e2e_render(&e)
	testing.expect(t, u64(e2e_cell_fg(&e, gutter + 2, 1)) & u64(tb2.Color.Bold) == 0, "an edit on the row drops its span")
	testing.expect_value(t, e2e_cell(&e, 0, 1), '●')
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 0, 2)), e2e_rgb(COLOR_GIT_ADD))
}

@(test)
e2e_deco_eol_wide_and_wrap :: proc(t: ^testing.T) {
	gutter := 3
	w := 80 - gutter
	long := strings.repeat("a", w - 4, context.temp_allocator)
	e := e2e_start(fmt.tprintf("%s\nshort\n", long))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.wrap = false
	b.cursor = {1, 0}
	deco_plugin(&e, "dw", `qed.deco.eol(nil, ns, 1, "x日本", "warn_foreground")`)
	e2e_render(&e)
	testing.expect_value(t, editor_gutter_width(&e.ed), gutter)
	testing.expect_value(t, e2e_cell(&e, gutter + w - 3, 0), 'x')
	testing.expect_value(t, e2e_cell(&e, gutter + w - 2, 0), '日')
	testing.expect(t, !strings.contains(e2e_row_text(&e, 0), "本"), "a wide char that would cross the edge is clipped")

	e.ed.scroll_col = 10
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, gutter + w - 13, 0), 'x')
	testing.expect_value(t, e2e_cell(&e, gutter + w - 10, 0), '本')
	e.ed.scroll_col = 0

	b.wrap = true
	wide := strings.repeat("word ", 20, context.temp_allocator)
	buffer_insert(b, {1, 5}, fmt.tprintf(" %s", wide))
	deco_plugin(&e, "dw2", `qed.deco.eol(nil, ns, 2, "tail", "warn_foreground")`)
	e2e_render(&e)
	segs := line_wrap(b.lines[1].text[:], w)
	testing.expect_value(t, len(segs), 2)
	last := e2e_row_text(&e, 2)
	testing.expect(t, strings.has_suffix(last, "word  tail"), "on a wrapped line the eol follows the last visual row")
	testing.expect(t, !strings.contains(e2e_row_text(&e, 1), "tail"), "not the first")
}

@(private = "file")
deco_row :: proc(e: ^E2E, y: int) -> string {
	return strings.trim_space(e2e_row_text(e, y))
}

@(test)
e2e_deco_ghost_rows_mapping :: proc(t: ^testing.T) {
	e := e2e_start("r0\nr1\nr2\nr3\nr4\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	deco_plugin(&e, "dg", `
		qed.deco.ghost(nil, ns, 2, {"g1", "g2"}, {color = "git_deleted"})
		qed.deco.ghost(nil, ns, 4, "up", {above = true})`)
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	testing.expect_value(t, deco_row(&e, 1), "2 r1")
	testing.expect_value(t, deco_row(&e, 2), "g1")
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter, 2)), e2e_rgb(COLOR_GIT_DEL))
	testing.expect_value(t, deco_row(&e, 3), "g2")
	testing.expect_value(t, deco_row(&e, 4), "3 r2")
	testing.expect_value(t, deco_row(&e, 5), "up")
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, gutter, 5)), e2e_rgb(COLOR_GHOST_FG))
	testing.expect_value(t, deco_row(&e, 6), "4 r3")

	w, h := editor_viewport(&e.ed)
	testing.expect_value(t, vpos_dist(b, w, 0, 0, 3, 0, h), 6)
	r, _ := vpos_down(b, w, 0, 0, 4)
	testing.expect_value(t, r, 2)
	r, _ = vpos_down(b, w, 0, 0, 2)
	testing.expect_value(t, r, 2)

	e2e_mouse(&e, gutter + 1, 6)
	testing.expect_value(t, b.cursor.row, 3)
	e2e_mouse(&e, gutter + 1, 3)
	testing.expect_value(t, b.cursor.row, 2)

	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, b.cursor.row, 1)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, b.cursor.row, 2)

	buffer_insert(b, {0, 0}, "new\n")
	e2e_render(&e)
	testing.expect_value(t, deco_row(&e, 3), "g1")
	testing.expect_value(t, deco_row(&e, 5), "4 r2")
}

@(test)
e2e_deco_ghost_scroll :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 60 {
		fmt.sbprintf(&sb, "line %d\n", i)
	}
	e := e2e_start(strings.to_string(sb))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	deco_plugin(&e, "gs", `
		for r = 1, 20 do qed.deco.ghost(nil, ns, r, {"a", "b"}) end`)
	_, h := editor_viewport(&e.ed)
	b.cursor = {15, 0}
	editor_scroll(&e.ed)
	e2e_render(&e)
	w, _ := editor_viewport(&e.ed)
	cy := vpos_dist(b, w, e.ed.scroll_row, e.ed.scroll_sub, b.cursor.row, 0, h)
	testing.expect(t, cy >= 0 && cy < h - SCROLL_MARGIN, "ghost rows push the scroll so the cursor stays inside the margin")
	testing.expect(t, e.ed.scroll_row > 0, "the view scrolled")
	row := e2e_row_text(&e, cy)
	testing.expect(t, strings.has_suffix(row, "line 15"), "the cursor's row is where the mapping says")
}

@(test)
e2e_deco_line_bg_order :: proc(t: ^testing.T) {
	tints := []RowTint{{COLOR_GIT_DEL, 0.3}, {COLOR_WARN_FG, 0.2}}
	got := editor_line_bg(true, .Modified, true, .Ours, false, tints)
	want := color_over(COLOR_BG, COLOR_GIT_MOD, GIT_HUNK_TINT)
	want = color_over(want, merge_side_color(.Ours), CONFLICT_TINT)
	want = color_over(want, COLOR_GIT_DEL, 0.3)
	want = color_over(want, COLOR_WARN_FG, 0.2)
	want = color_over(want, COLOR_CURRENT_LINE_BG, CURRENT_LINE_TINT)
	testing.expect_value(t, got, want)
	testing.expect_value(t, editor_line_bg(false, .None, false, .None, false), COLOR_BG)
}

@(test)
e2e_deco_default_tint_alpha :: proc(t: ^testing.T) {
	e := e2e_start("a\nb\n")
	defer e2e_stop(&e)
	deco_plugin(&e, "da", `qed.deco.tint(nil, ns, 2, 2, "git_added")`)
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 3, 1)), e2e_rgb(color_over(COLOR_BG, COLOR_GIT_ADD, DECO_TINT)))
}

@(test)
e2e_deco_namespaces_and_unload :: proc(t: ^testing.T) {
	e := e2e_start("a\nb\nc\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	one := e2e_plugin(&e, "one", `
		return {setup = function()
			local a, b = qed.deco.ns("a"), qed.deco.ns("b")
			assert(qed.deco.ns("a") == a, "same name, same id")
			qed.deco.gutter(nil, a, 1, "x", "git_added")
			qed.deco.gutter(nil, a, 2, "x", "git_added")
			qed.deco.ghost(nil, a, 3, "ghost")
			qed.deco.gutter(nil, b, 3, "y", "git_added")
			qed.deco.clear(nil, a, 2, 2)
			assert(not pcall(qed.deco.gutter, nil, a, 1, "xx", "git_added"), "two-char glyph refused")
			assert(not pcall(qed.deco.gutter, nil, a, 1, "日", "git_added"), "wide glyph refused")
			assert(not pcall(qed.deco.gutter, nil, a, 9, "x", "git_added"), "row out of range refused")
			assert(not pcall(qed.deco.gutter, nil, a, 1, "x", "#ff0000"), "hex color refused")
			assert(not pcall(qed.deco.gutter, nil, 999, 1, "x", "git_added"), "unknown namespace refused")
			assert(not pcall(qed.deco.tint, nil, a, 2, 1, "git_added"), "reversed tint refused")
			assert(not pcall(qed.deco.tint, nil, a, 1, 1, "git_added", 2), "alpha out of range refused")
			_G.one_ns = a
		end}`)
	testing.expect_value(t, one.state, PluginState.Enabled)
	testing.expect_value(t, len(b.deco.items), 2)
	testing.expect_value(t, len(b.deco.ghosts), 1)

	two := e2e_plugin(&e, "two", `
		return {setup = function()
			local mine = qed.deco.ns("a")
			qed.deco.gutter(nil, mine, 1, "z", "git_deleted")
			assert(not pcall(qed.deco.clear, nil, mine - 1), "another plugin's namespace is refused")
		end}`)
	testing.expect_value(t, two.state, PluginState.Enabled)
	testing.expect_value(t, len(b.deco.items), 3)

	plugin_unload(&e.ed, one)
	testing.expect_value(t, len(b.deco.items), 1)
	testing.expect_value(t, len(b.deco.ghosts), 0)
	testing.expect_value(t, b.deco.items[0].glyph, 'z')
	plugin_unload(&e.ed, two)
	testing.expect_value(t, len(b.deco.items), 0)
	testing.expect_value(t, len(e.ed.plugins.deco_ns), 0)
}

@(test)
e2e_deco_status_segments :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	pl := e2e_plugin(&e, "st", `
		return {setup = function()
			qed.status.set("l", {text = "LEFTSEG"})
			qed.status.set("r", {text = "RIGHTSEG", side = "right", color = "error_foreground", drop = 0})
			qed.status.set("d", {text = "DROPME", drop = 1})
			qed.status.set("l", {text = "LEFT2"})
			assert(not pcall(qed.status.set, "x", {text = "x", side = "up"}), "bad side")
			assert(not pcall(qed.status.set, "x", {text = "x", color = "nope"}), "unknown color")
			assert(not pcall(qed.status.set, "x", {}), "text required")
			qed.status.set("gone", {text = "GONE"})
			qed.status.clear("gone")
			qed.status.set("c", {text = {{text = "+1", color = "git_added"}, {text = " -2", color = "git_deleted"}}, sep = " "})
			assert(not pcall(qed.status.set, "x", {text = {{text = "x", color = "nope"}}}), "unknown chunk color")
			qed.status.set("e", {text = ""})
		end}`)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	owned := proc(e: ^E2E) -> int {
		n := 0
		for s in e.ed.plugins.status {
			n += 1 if s.owner == "st" else 0
		}
		return n
	}
	testing.expect_value(t, owned(&e), 5)
	e2e_resize(&e, 100, 24)
	_, h := editor_viewport(&e.ed)
	e2e_render(&e)
	row := e2e_row_text(&e, h)
	ci := strings.index(row, "DROPME +1 -2 ")
	testing.expectf(t, ci >= 0, "chunks join after a custom sep; an empty segment takes no room: %q", row)
	if ci >= 0 {
		cx := visual_width(transmute([]u8)row[:ci]) + len("DROPME ")
		testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, cx, h)), e2e_rgb(COLOR_GIT_ADD))
		testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, cx + 3, h)), e2e_rgb(COLOR_GIT_DEL))
	}
	testing.expectf(t, strings.contains(row, "LEFT2"), "a set replaces the same id: %q", row)
	testing.expect(t, !strings.contains(row, "LEFTSEG"), "old text gone")
	testing.expect(t, strings.contains(row, "DROPME"), "fits at full width")
	ri := strings.index(row, "RIGHTSEG")
	testing.expect(t, ri > strings.index(row, "DROPME"), "right segment on the right")
	testing.expect(t, ri < strings.index(row, "Spaces"), "plugin right segments sit left of the builtins")
	x := 0
	for e2e_cell(&e, x, h) != 'R' || e2e_cell(&e, x + 1, h) != 'I' {
		x += 1
	}
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, x, h)), e2e_rgb(COLOR_ERROR_FG))

	e2e_resize(&e, 46, 24)
	e2e_render(&e)
	_, h = editor_viewport(&e.ed)
	row = e2e_row_text(&e, h)
	testing.expect(t, strings.contains(row, "RIGHTSEG"), "drop 0 is never dropped")
	testing.expect(t, !strings.contains(row, "DROPME"), "drop 1 goes first")
	e2e_resize(&e, 80, 24)

	plugin_unload(&e.ed, pl)
	testing.expect_value(t, owned(&e), 0)
	e2e_render(&e)
	_, h = editor_viewport(&e.ed)
	testing.expect(t, !strings.contains(e2e_row_text(&e, h), "LEFT2"), "unload removes the segments")
}

@(test)
e2e_deco_set_base_no_git :: proc(t: ^testing.T) {
	e := e2e_start("one\nTWO\nthree\nfour\nfive\n")
	defer e2e_stop(&e)
	saved := g_diff_view
	defer g_diff_view = saved
	g_diff_view = true
	b := editor_buffer(&e.ed)
	pl := e2e_plugin(&e, "sb", `
		return {setup = function()
			qed.buf.set_base(nil, "zero\none\ntwo\nthree\nfive\n", {label = "saved"})
		end}`)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	e2e_render(&e)
	testing.expect_value(t, diff_mark_at(b, 0), DiffMark.Deleted)
	testing.expect_value(t, diff_mark_at(b, 1), DiffMark.Modified)
	testing.expect_value(t, diff_mark_at(b, 2), DiffMark.None)
	testing.expect_value(t, diff_mark_at(b, 3), DiffMark.Added)
	testing.expect_value(t, ghost_above(b, 1), 1)
	_, h := editor_viewport(&e.ed)
	testing.expect(t, strings.contains(e2e_row_text(&e, h), "saved"), "the label shows in the status bar")
	testing.expect(t, strings.has_suffix(deco_row(&e, 1), "two"), "the base line renders as a ghost row")

	b.cursor = {4, 0}
	diffbase_goto(&e.ed, -1)
	testing.expect_value(t, b.cursor.row, 3)
	diffbase_goto(&e.ed, -1)
	testing.expect_value(t, b.cursor.row, 0)
	diffbase_goto(&e.ed, +1)
	testing.expect_value(t, b.cursor.row, 3)

	b.cursor = {1, 0}
	diffbase_revert(&e.ed)
	testing.expect_value(t, string(b.lines[1].text[:]), "two")
	b.cursor = {3, 0}
	diffbase_revert(&e.ed)
	testing.expect_value(t, len(b.lines), 5)
	b.cursor = {0, 0}
	diffbase_revert(&e.ed)
	testing.expect_value(t, buffer_snapshot_tmp(b), "zero\none\ntwo\nthree\nfive\n")
	e2e_render(&e)
	for r in 0 ..< len(b.lines) {
		testing.expect_value(t, diff_mark_at(b, r), DiffMark.None)
	}

	plugin_unload(&e.ed, pl)
	testing.expect_value(t, diffbase_owner(b), "")
	b.cursor = {0, 0}
	e2e_type(&e, "x")
	e2e_render(&e)
	testing.expect_value(t, diff_mark_at(b, 0), DiffMark.None)
}

@(private = "file")
buffer_snapshot_tmp :: proc(b: ^Buffer) -> string {
	s := buffer_snapshot(b)
	out := strings.clone(s, context.temp_allocator)
	delete(s)
	return out
}

@(test)
e2e_deco_set_base_matches_git :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	seed := "a\nb\nc\nd\ne\nf\ng\n"
	e := e2e_git_start(seed)
	defer e2e_stop(&e)
	saved := g_diff_view
	defer g_diff_view = saved
	g_diff_view = true
	b := editor_buffer(&e.ed)
	b.cursor = {1, 1}
	e2e_type(&e, "X")
	delete(buffer_delete(b, {3, 0}, {4, 0}))
	buffer_insert(b, {5, 0}, "new\n")
	e2e_render(&e)
	testing.expect_value(t, diffbase_owner(b), "git")
	marks := make([]DiffMark, len(b.base.marks), context.temp_allocator)
	copy(marks, b.base.marks[:])
	hunks := make([]DiffHunk, len(b.base.hunks), context.temp_allocator)
	copy(hunks, b.base.hunks[:])
	changes := make([]DiffChange, len(b.base.changes), context.temp_allocator)
	copy(changes, b.base.changes[:])
	git_screen := make([]string, 8, context.temp_allocator)
	for y in 0 ..< 8 {
		git_screen[y] = strings.clone(deco_row(&e, y), context.temp_allocator)
	}

	pl := e2e_plugin(&e, "gb", fmt.tprintf(`return {{setup = function() qed.buf.set_base(nil, %q) end}}`, seed))
	testing.expect_value(t, pl.state, PluginState.Enabled)
	e2e_render(&e)
	testing.expect_value(t, diffbase_owner(b), "gb")
	testing.expect(t, slice_equal(marks, b.base.marks[:]), "same marks")
	testing.expect(t, slice_equal(hunks, b.base.hunks[:]), "same hunks")
	testing.expect(t, slice_equal(changes, b.base.changes[:]), "same changes")
	for y in 0 ..< 8 {
		testing.expect_value(t, deco_row(&e, y), git_screen[y])
	}

	editor_save(&e.ed)
	e2e_git_settle(&e)
	e2e_render(&e)
	testing.expect_value(t, diffbase_owner(b), "gb")

	plugin_unload(&e.ed, pl)
	e2e_render(&e)
	testing.expect_value(t, diffbase_owner(b), "git")
	testing.expect(t, slice_equal(marks, b.base.marks[:]), "git takes over again on unload")
}

@(private = "file")
slice_equal :: proc(a, b: []$T) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

@(test)
e2e_deco_set_base_ownership :: proc(t: ^testing.T) {
	e := e2e_start("one\ntwo\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	a := e2e_plugin(&e, "owna", `return {setup = function() assert(qed.buf.set_base(nil, "one\n") == true) end}`)
	testing.expect_value(t, a.state, PluginState.Enabled)
	other := e2e_plugin(&e, "ownb", `return {setup = function()
		assert(qed.buf.set_base(nil, "zzz\n") == true, "a later plugin's base goes on top")
		assert(qed.buf.set_base(nil, nil) == false, "clearing it")
		assert(qed.buf.set_base(nil, "zzz\n", {label = ""}) == true, "and setting it again")
	end}`)
	testing.expect_value(t, other.state, PluginState.Enabled)
	testing.expect_value(t, diffbase_owner(b), "ownb")
	testing.expect_value(t, diffbase_active(b).text, "zzz\n")
	e2e_render(&e)
	_, h0 := editor_viewport(&e.ed)
	testing.expect(t, !strings.contains(e2e_row_text(&e, h0), ICON_STATUS_DIFF_BASE), "an empty label shows no indicator")
	plugin_unload(&e.ed, other)
	testing.expect_value(t, diffbase_owner(b), "owna")
	testing.expect_value(t, diffbase_active(b).text, "one\n")
	e2e_render(&e)
	_, h := editor_viewport(&e.ed)
	testing.expect(t, strings.contains(e2e_row_text(&e, h), fmt.tprintf("%sbase", ICON_STATUS_DIFF_BASE)), "a label-less plugin base shows a generic indicator")
}

@(test)
e2e_deco_mark_follows_edits :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbravo charlie\ndelta\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	pl := deco_plugin(&e, "mk", `
		local m = qed.deco.mark(nil, ns, {row = 2, col = 7}, {row = 2, col = 14})
		local from, to = qed.deco.range(nil, ns, m)
		assert(from.row == 2 and from.col == 7 and to.col == 14, "range reads back")
		assert(qed.deco.range(nil, ns, m + 1) == nil, "unknown id")`)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	testing.expect_value(t, len(b.deco.marks), 1)

	buffer_insert(b, {0, 0}, "new\n")
	testing.expect_value(t, b.deco.marks[0].from, Cursor{2, 6})
	buffer_insert(b, {2, 0}, ">> ")
	testing.expect_value(t, b.deco.marks[0].from, Cursor{2, 9})
	testing.expect_value(t, b.deco.marks[0].to, Cursor{2, 16})
	buffer_insert(b, {2, 9}, "x")
	testing.expect_value(t, b.deco.marks[0].from, Cursor{2, 10})
	buffer_insert(b, {2, 17}, "y")
	testing.expect_value(t, b.deco.marks[0].to, Cursor{2, 17})
	delete(buffer_delete(b, {2, 0}, {2, 3}))
	testing.expect_value(t, b.deco.marks[0].from, Cursor{2, 7})
	testing.expect_value(t, b.deco.marks[0].to, Cursor{2, 14})
	delete(buffer_delete(b, {2, 14}, {2, 15}))
	testing.expect_value(t, len(b.deco.marks), 1)

	buffer_insert(b, {2, 10}, "!")
	testing.expect_value(t, len(b.deco.marks), 0)
}

@(test)
e2e_deco_mark_dies_on_overlap :: proc(t: ^testing.T) {
	e := e2e_start("one two three\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	deco_plugin(&e, "mk", `
		qed.deco.mark(nil, ns, {row = 1, col = 5}, {row = 1, col = 8})
		qed.deco.mark(nil, ns, {row = 1, col = 9}, {row = 1, col = 14})`)
	testing.expect_value(t, len(b.deco.marks), 2)
	delete(buffer_delete(b, {0, 2}, {0, 6}))
	testing.expect_value(t, len(b.deco.marks), 1)
	testing.expect_value(t, b.deco.marks[0].from, Cursor{0, 4})
	b.selection = Cursor{0, 3}
	b.cursor = {0, 6}
	e2e_type(&e, "Z")
	testing.expect_value(t, len(b.deco.marks), 0)
}

@(test)
e2e_deco_tint_theme_key :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbravo\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.wrap = false
	pl := deco_plugin(&e, "tk", `
		qed.deco.tint(nil, ns, 2, 2, "ai_edit_background", "ai_edit")
		assert(not pcall(qed.deco.tint, nil, ns, 1, 1, "ai_edit_background", "nope"), "unknown tint")`)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 6, 1)), e2e_rgb(color_over(COLOR_BG, COLOR_AI_EDIT_BG, AI_EDIT_TINT)))
	saved := AI_EDIT_TINT
	defer AI_EDIT_TINT = saved
	AI_EDIT_TINT = 0.8
	e2e_render(&e)
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, gutter + 6, 1)), e2e_rgb(color_over(COLOR_BG, COLOR_AI_EDIT_BG, 0.8)))
}

@(private = "file")
inline_start :: proc(t: ^testing.T, e: ^E2E, name := "gh") -> ^Buffer {
	b := editor_buffer(&e.ed)
	b.wrap = false
	b.cursor = {0, 2}
	pl := deco_plugin(e, name, `
		assert(not qed.deco.inline(nil, ns, {row = 1, col = 1}, "X"), "not at the cursor")
		assert(not qed.deco.inline(nil, ns, {row = 1, col = 3}, "X", {rev = qed.buf.rev() + 1}), "stale rev")
		assert(not qed.deco.inline(nil, ns, {row = 1, col = 3}, ""), "empty text")
		assert(qed.deco.inline(nil, ns, {row = 1, col = 3}, "AAA\nBBB", {rev = qed.buf.rev()}), "shown")`)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	testing.expect(t, inline_active(&e.ed), "ghost active at the cursor")
	return b
}

@(test)
e2e_deco_inline_renders_dimmed :: proc(t: ^testing.T) {
	e := e2e_start("ab")
	defer e2e_stop(&e)
	inline_start(t, &e)
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	testing.expect_value(t, e2e_cell(&e, gutter + 2, 0), 'A')
	testing.expect_value(t, e2e_cell_fg(&e, gutter + 2, 0), COLOR_GHOST_FG)
	testing.expect_value(t, e2e_cell(&e, gutter, 1), 'B')
	testing.expect_value(t, e2e_cell_fg(&e, gutter, 1), COLOR_GHOST_FG)
}

@(test)
e2e_deco_inline_tab_accepts_all :: proc(t: ^testing.T) {
	e := e2e_start("ab")
	defer e2e_stop(&e)
	b := inline_start(t, &e)
	e2e_key(&e, .Tab)
	testing.expect_value(t, string(b.lines[0].text[:]), "abAAA")
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, string(b.lines[1].text[:]), "BBB")
	testing.expect(t, !inline_active(&e.ed), "ghost consumed by accept")
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "ab")
	testing.expect_value(t, len(b.lines), 1)
}

@(test)
e2e_deco_inline_ctrl_right_accepts_word :: proc(t: ^testing.T) {
	e := e2e_start("ab")
	defer e2e_stop(&e)
	b := inline_start(t, &e)
	e2e_key(&e, .Arrow_Right, .Ctrl)
	testing.expect_value(t, string(b.lines[0].text[:]), "abAAA")
	testing.expect_value(t, len(b.lines), 1)
	testing.expect(t, inline_active(&e.ed), "the rest stays shown")
	testing.expect_value(t, b.deco.inline.text, "\nBBB")
}

@(test)
e2e_deco_inline_dismissed :: proc(t: ^testing.T) {
	e := e2e_start("ab")
	defer e2e_stop(&e)
	b := inline_start(t, &e)
	e2e_type(&e, "z")
	testing.expect(t, !inline_active(&e.ed), "an edit drops the ghost")
	testing.expect_value(t, string(b.lines[0].text[:]), "abz")
	testing.expect_value(t, len(b.lines), 1)

	b2 := inline_start(t, &e, "gh2")
	e2e_key(&e, .Esc)
	testing.expect(t, !inline_active(&e.ed), "Esc drops the ghost")
	testing.expect_value(t, string(b2.lines[0].text[:]), "abz")

	inline_start(t, &e, "gh3")
	e2e_key(&e, .Arrow_Left)
	e2e_key(&e, .Arrow_Right)
	testing.expect(t, !inline_active(&e.ed), "moving away drops it for good")
}
