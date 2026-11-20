package main

import "core:testing"

@(private = "file")
deco_test_rows :: proc(b: ^Buffer, kind: DecoKind) -> [dynamic]int {
	rows := make([dynamic]int, context.temp_allocator)
	for d in b.deco.items {
		if d.kind == kind {
			append(&rows, d.from.row)
		}
	}
	for d in b.deco.ghosts {
		if d.kind == kind {
			append(&rows, d.from.row)
		}
	}
	return rows
}

@(private = "file")
deco_test_buffer :: proc() -> Buffer {
	b := test_buffer("l0", "l1", "l2", "l3", "l4")
	for r in 0 ..< 5 {
		deco_add(&b, Deco{kind = .Gutter, ns = 1, from = {r, 0}, to = {r, 0}, glyph = rune('0' + r)})
	}
	return b
}

@(private = "file")
deco_glyph_at :: proc(b: ^Buffer, row: int) -> rune {
	g: rune
	for d in b.deco.items {
		if d.kind == .Gutter && d.from.row == row {
			g = d.glyph
		}
	}
	return g
}

@(test)
deco_insert_shifts_below :: proc(t: ^testing.T) {
	b := deco_test_buffer()
	defer buffer_destroy(&b)
	buffer_insert(&b, {2, 1}, "x\ny\n")
	testing.expect_value(t, deco_glyph_at(&b, 0), '0')
	testing.expect_value(t, deco_glyph_at(&b, 2), '2')
	testing.expect_value(t, deco_glyph_at(&b, 3), 0)
	testing.expect_value(t, deco_glyph_at(&b, 5), '3')
	testing.expect_value(t, deco_glyph_at(&b, 6), '4')
	buffer_insert(&b, {0, 0}, "top\n")
	testing.expect_value(t, deco_glyph_at(&b, 0), 0)
	testing.expect_value(t, deco_glyph_at(&b, 1), '0')
	testing.expect_value(t, deco_glyph_at(&b, 7), '4')
	buffer_insert(&b, {7, 2}, "\n")
	testing.expect_value(t, deco_glyph_at(&b, 7), '4')
	testing.expect_value(t, deco_glyph_at(&b, 8), 0)
}

@(test)
deco_delete_drops_and_shifts :: proc(t: ^testing.T) {
	b := deco_test_buffer()
	defer buffer_destroy(&b)
	delete(buffer_delete(&b, {1, 0}, {3, 0}))
	testing.expect_value(t, string(b.lines[1].text[:]), "l3")
	testing.expect_value(t, deco_glyph_at(&b, 0), '0')
	testing.expect_value(t, deco_glyph_at(&b, 1), '3')
	testing.expect_value(t, deco_glyph_at(&b, 2), '4')
	testing.expect_value(t, len(b.deco.items), 3)

	c := deco_test_buffer()
	defer buffer_destroy(&c)
	delete(buffer_delete(&c, {1, 2}, {2, 0}))
	testing.expect_value(t, string(c.lines[1].text[:]), "l1l2")
	testing.expect_value(t, deco_glyph_at(&c, 1), '1')
	testing.expect_value(t, deco_glyph_at(&c, 2), '3')
	testing.expect_value(t, len(c.deco.items), 4)

	d := deco_test_buffer()
	defer buffer_destroy(&d)
	delete(buffer_delete(&d, {0, 1}, {4, 1}))
	testing.expect_value(t, len(d.lines), 1)
	testing.expect_value(t, deco_glyph_at(&d, 0), '0')
	testing.expect_value(t, len(d.deco.items), 1)
}

@(test)
deco_edit_within_row_keeps_marks :: proc(t: ^testing.T) {
	b := deco_test_buffer()
	defer buffer_destroy(&b)
	deco_add(&b, Deco{kind = .Span, ns = 1, from = {2, 0}, to = {2, 2}})
	deco_add(&b, Deco{kind = .Span, ns = 1, from = {3, 0}, to = {4, 1}})
	deco_add(&b, Deco{kind = .Eol, ns = 1, from = {2, 0}, to = {2, 0}, text = "note"})
	buffer_insert(&b, {2, 1}, "zz")
	testing.expect_value(t, deco_glyph_at(&b, 2), '2')
	testing.expect_value(t, len(deco_test_rows(&b, .Span)), 1)
	testing.expect_value(t, len(deco_test_rows(&b, .Eol)), 1)
	buffer_insert(&b, {0, 2}, "\n")
	spans := deco_test_rows(&b, .Span)
	testing.expect_value(t, spans[0], 4)
	delete(buffer_delete(&b, {5, 0}, {5, 1}))
	testing.expect_value(t, len(deco_test_rows(&b, .Span)), 0)
}

@(test)
deco_tint_range_shrinks_and_grows :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c", "d", "e", "f")
	defer buffer_destroy(&b)
	deco_add(&b, Deco{kind = .Tint, ns = 1, from = {1, 0}, to = {3, 0}})
	buffer_insert(&b, {2, 1}, "\nnew")
	tint := b.deco.items[0]
	testing.expect_value(t, tint.from.row, 1)
	testing.expect_value(t, tint.to.row, 4)
	delete(buffer_delete(&b, {0, 0}, {2, 0}))
	tint = b.deco.items[0]
	testing.expect_value(t, tint.from.row, 0)
	testing.expect_value(t, tint.to.row, 2)
	delete(buffer_delete(&b, {0, 0}, {3, 0}))
	testing.expect_value(t, len(b.deco.items), 0)
}

@(test)
deco_undo_redo_follow :: proc(t: ^testing.T) {
	b := deco_test_buffer()
	defer buffer_destroy(&b)
	edit_open(&b, .Atomic)
	edit_insert(&b, {1, 0}, "a\nb\n")
	buffer_undo_commit(&b)
	testing.expect_value(t, deco_glyph_at(&b, 3), '1')
	buffer_undo(&b)
	testing.expect_value(t, deco_glyph_at(&b, 1), '1')
	testing.expect_value(t, deco_glyph_at(&b, 4), '4')
	buffer_redo(&b)
	testing.expect_value(t, deco_glyph_at(&b, 3), '1')
	testing.expect_value(t, deco_glyph_at(&b, 6), '4')

	edit_open(&b, .Atomic)
	edit_delete(&b, {3, 0}, {4, 0})
	buffer_undo_commit(&b)
	testing.expect_value(t, deco_glyph_at(&b, 3), '2')
	buffer_undo(&b)
	testing.expect_value(t, deco_glyph_at(&b, 3), 0)
	testing.expect_value(t, deco_glyph_at(&b, 4), '2')
}

@(test)
deco_ghosts_shift_and_count :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c")
	defer buffer_destroy(&b)
	deco_add(&b, Deco{kind = .Ghost, ns = 1, from = {1, 0}, to = {1, 0}, text = "g1\ng2", lines = 2})
	deco_add(&b, Deco{kind = .Ghost, ns = 2, from = {1, 0}, to = {1, 0}, text = "up", lines = 1, above = true})
	testing.expect_value(t, ghost_below(&b, 1), 2)
	testing.expect_value(t, ghost_above(&b, 1), 1)
	buffer_insert(&b, {0, 0}, "z\n")
	testing.expect_value(t, ghost_below(&b, 1), 0)
	testing.expect_value(t, ghost_below(&b, 2), 2)
	deco_clear(&b, 1)
	testing.expect_value(t, ghost_below(&b, 2), 0)
	testing.expect_value(t, ghost_above(&b, 2), 1)
	delete(buffer_delete(&b, {1, 0}, {3, 0}))
	testing.expect_value(t, len(b.deco.ghosts), 0)
}

@(test)
deco_clear_by_rows :: proc(t: ^testing.T) {
	b := deco_test_buffer()
	defer buffer_destroy(&b)
	deco_add(&b, Deco{kind = .Gutter, ns = 2, from = {2, 0}, to = {2, 0}, glyph = 'x'})
	deco_clear(&b, 1, 1, 3)
	testing.expect_value(t, deco_glyph_at(&b, 0), '0')
	testing.expect_value(t, deco_glyph_at(&b, 2), 'x')
	testing.expect_value(t, deco_glyph_at(&b, 4), '4')
	testing.expect_value(t, len(b.deco.items), 3)
}

@(test)
deco_set_text_keeps_first_row_of_hunk :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c", "d")
	defer buffer_destroy(&b)
	deco_add(&b, Deco{kind = .Gutter, ns = 1, from = {1, 0}, to = {1, 0}, glyph = 'b'})
	deco_add(&b, Deco{kind = .Gutter, ns = 1, from = {3, 0}, to = {3, 0}, glyph = 'd'})
	buffer_set_text(&b, "a\nX\nY\nZ\nd")
	testing.expect_value(t, deco_glyph_at(&b, 1), 'b')
	testing.expect_value(t, deco_glyph_at(&b, 3), 0)
	testing.expect_value(t, deco_glyph_at(&b, 4), 'd')

	c := test_buffer("x", "", "y")
	defer buffer_destroy(&c)
	deco_add(&c, Deco{kind = .Gutter, ns = 1, from = {1, 0}, to = {1, 0}, glyph = 'e'})
	buffer_insert(&c, {1, 0}, "p\nq")
	testing.expect_value(t, deco_glyph_at(&c, 1), 'e')
	testing.expect_value(t, deco_glyph_at(&c, 3), 0)
}
