package main

import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

DecoKind :: enum u8 {
	Gutter,
	Tint,
	Ghost,
	Span,
	Eol,
}

Deco :: struct {
	from, to:        Cursor,
	text:            string,
	alpha:           f32,
	glyph:           rune,
	ns:              u32,
	lines:           int,
	color, bg:       u16,
	kind:            DecoKind,
	bold, underline: bool,
	above:           bool,
}

DecoStore :: struct {
	items:       [dynamic]Deco,
	ghosts:      [dynamic]Deco,
	above:       [dynamic]int,
	below:       [dynamic]int,
	ghost_dirty: bool,
}

RowTint :: struct {
	color: tb2.Color,
	alpha: f32,
}

RowSpan :: struct {
	from, to:       int,
	fg, bg:         tb2.Color,
	has_fg, has_bg: bool,
	attrs:          u64,
}

RowEol :: struct {
	text:  string,
	color: tb2.Color,
}

DecoRow :: struct {
	glyph:    rune,
	glyph_fg: tb2.Color,
	tints:    [dynamic]RowTint,
	spans:    [dynamic]RowSpan,
	eols:     [dynamic]RowEol,
}

deco_store_destroy :: proc(s: ^DecoStore) {
	for d in s.items {
		delete(d.text)
	}
	for d in s.ghosts {
		delete(d.text)
	}
	delete(s.items)
	delete(s.ghosts)
	delete(s.above)
	delete(s.below)
}

deco_add :: proc(b: ^Buffer, d: Deco) {
	d := d
	d.text = strings.clone(d.text)
	append(&b.deco.ghosts if d.kind == .Ghost else &b.deco.items, d)
	b.deco.ghost_dirty = true
}

deco_clear :: proc(b: ^Buffer, ns: u32, lo := 0, hi := max(int)) {
	b.deco.ghost_dirty = true
	for list in ([2]^[dynamic]Deco{&b.deco.items, &b.deco.ghosts}) {
		w := 0
		for &d, i in list {
			if d.ns == ns && d.from.row <= hi && d.to.row >= lo {
				delete(d.text)
				continue
			}
			if w != i {
				list[w] = d
			}
			w += 1
		}
		resize(list, w)
	}
}

deco_insert_row :: proc(r, at, k: int, moves: bool) -> int {
	if r > at || (r == at && moves) {
		return r + k
	}
	return r
}

deco_after_insert :: proc(b: ^Buffer, at, end: Cursor) {
	k := end.row - at.row
	b.deco.ghost_dirty = true
	// a col-0 insert into a row that was empty (a replaced hunk) keeps its decorations on that row
	moves := at.col == 0 && end.col < len(b.lines[end.row].text)
	for list in ([2]^[dynamic]Deco{&b.deco.items, &b.deco.ghosts}) {
		w := 0
		for &d, i in list {
			if d.kind == .Span {
				if d.from.row <= at.row && d.to.row >= at.row {
					delete(d.text)
					continue
				}
				if d.from.row > at.row {
					d.from.row += k
					d.to.row += k
				}
			} else if k > 0 {
				d.from.row = deco_insert_row(d.from.row, at.row, k, moves)
				d.to.row = deco_insert_row(d.to.row, at.row, k, moves)
			}
			if w != i {
				list[w] = d
			}
			w += 1
		}
		resize(list, w)
	}
}

deco_delete_row :: proc(r: int, from, to: Cursor, whole: bool) -> (int, bool) {
	k := to.row - from.row
	switch {
	case r < from.row:
		return r, true
	case r > to.row:
		return r - k, true
	case k == 0:
		return r, true
	case whole:
		return from.row, r == to.row
	}
	return r, r == from.row
}

deco_after_delete :: proc(b: ^Buffer, from, to: Cursor) {
	b.deco.ghost_dirty = true
	whole := to.row > from.row && from.col == 0 && to.col == 0
	for list in ([2]^[dynamic]Deco{&b.deco.items, &b.deco.ghosts}) {
		w := 0
		for &d, i in list {
			if d.kind == .Span && d.from.row <= to.row && d.to.row >= from.row {
				delete(d.text)
				continue
			}
			lo, lok := deco_delete_row(d.from.row, from, to, whole)
			hi, hok := deco_delete_row(d.to.row, from, to, whole)
			if d.kind == .Tint {
				if !lok {
					lo = from.row if whole else from.row + 1
				}
				if !hok {
					hi = from.row - 1 if whole else from.row
				}
			}
			if !lok && d.kind != .Tint || lo > hi {
				delete(d.text)
				continue
			}
			d.from.row = lo
			d.to.row = hi
			if w != i {
				list[w] = d
			}
			w += 1
		}
		resize(list, w)
	}
}

deco_after_reload :: proc(b: ^Buffer) {
	b.deco.ghost_dirty = true
	last := len(b.lines) - 1
	for list in ([2]^[dynamic]Deco{&b.deco.items, &b.deco.ghosts}) {
		w := 0
		for &d, i in list {
			if d.kind == .Span || d.from.row > last {
				delete(d.text)
				continue
			}
			d.to.row = min(d.to.row, last)
			if w != i {
				list[w] = d
			}
			w += 1
		}
		resize(list, w)
	}
}

deco_ghost_count :: proc(b: ^Buffer, row: int, above: bool) -> int {
	s := &b.deco
	if len(s.ghosts) == 0 {
		return 0
	}
	if s.ghost_dirty || len(s.above) != len(b.lines) {
		resize(&s.above, len(b.lines))
		resize(&s.below, len(b.lines))
		for i in 0 ..< len(b.lines) {
			s.above[i] = 0
			s.below[i] = 0
		}
		for d in s.ghosts {
			if d.from.row >= 0 && d.from.row < len(b.lines) {
				(&s.above if d.above else &s.below)[d.from.row] += d.lines
			}
		}
		s.ghost_dirty = false
	}
	if row < 0 || row >= len(b.lines) {
		return 0
	}
	return s.above[row] if above else s.below[row]
}

ghost_above :: proc(b: ^Buffer, row: int) -> int {
	return git_above(b, row) + deco_ghost_count(b, row, true)
}

ghost_below :: proc(b: ^Buffer, row: int) -> int {
	return git_below(b, row) + deco_ghost_count(b, row, false)
}

deco_palette :: proc(keys: []string) -> []tb2.Color {
	pal := make([]tb2.Color, len(keys) + 1, context.temp_allocator)
	pal[0] = COLOR_FG
	for k, i in keys {
		pal[i + 1] = g_theme_colors[k] or_else COLOR_FG
	}
	return pal
}

deco_rows :: proc(b: ^Buffer, lo, hi: int, pal: []tb2.Color) -> []DecoRow {
	rows := make([]DecoRow, max(hi - lo, 0), context.temp_allocator)
	if len(b.deco.items) == 0 {
		return rows
	}
	for &r in rows {
		r.tints.allocator = context.temp_allocator
		r.spans.allocator = context.temp_allocator
		r.eols.allocator = context.temp_allocator
	}
	for d in b.deco.items {
		if d.to.row < lo || d.from.row >= hi {
			continue
		}
		switch d.kind {
		case .Gutter:
			rows[d.from.row - lo].glyph = d.glyph
			rows[d.from.row - lo].glyph_fg = pal[d.color]
		case .Tint:
			for r in max(d.from.row, lo) ..= min(d.to.row, hi - 1) {
				append(&rows[r - lo].tints, RowTint{pal[d.color], d.alpha})
			}
		case .Eol:
			append(&rows[d.from.row - lo].eols, RowEol{d.text, pal[d.color]})
		case .Span:
			attrs: u64
			if d.bold {
				attrs |= u64(tb2.Color.Bold)
			}
			if d.underline {
				attrs |= u64(tb2.Color.Underline)
			}
			for r in max(d.from.row, lo) ..= min(d.to.row, hi - 1) {
				s := RowSpan {
					from   = d.from.col if r == d.from.row else 0,
					to     = d.to.col if r == d.to.row else max(int),
					fg     = pal[d.color],
					bg     = pal[d.bg],
					has_fg = d.color != 0,
					has_bg = d.bg != 0,
					attrs  = attrs,
				}
				append(&rows[r - lo].spans, s)
			}
		case .Ghost:
		}
	}
	return rows
}

editor_render_deco_ghosts :: proc(b: ^Buffer, row, gutter, w, h: int, above: bool, screen_y: int, pal: []tb2.Color) -> int {
	sy := screen_y
	for d in b.deco.ghosts {
		if d.from.row != row || d.above != above {
			continue
		}
		fg := pal[d.color] if d.color != 0 else COLOR_GHOST_FG
		for line in strings.split(d.text, "\n", context.temp_allocator) {
			if sy >= h {
				return sy
			}
			text := transmute([]u8)line
			ccol := make([]tb2.Color, len(text), context.temp_allocator)
			for &c in ccol {
				c = fg
			}
			editor_render_ghost_gutter(sy, gutter, ' ')
			editor_render_text_row(gutter, sy, w, text, ccol, 0, COLOR_BG, -1, -1, nil, 0, len(text))
			sy += 1
		}
	}
	return sy
}

editor_render_eol :: proc(gutter, y, w, x: int, eols: []RowEol, bg: tb2.Color) {
	x := x
	for e, i in eols {
		if i > 0 {
			x += 1
		}
		text := transmute([]u8)e.text
		for at := 0; at < len(text); {
			next := grapheme_next(text, at)
			cluster := text[at:next]
			at = next
			cw := cluster_width(cluster)
			if x + cw > w {
				return
			}
			if x >= 0 {
				r, n := utf8.decode_rune(cluster)
				tb2.set_cell(i32(gutter + x), i32(y), r, e.color, bg)
				rest := cluster[n:]
				for len(rest) > 0 {
					rr, m := utf8.decode_rune(rest)
					tb2.extend_cell(i32(gutter + x), i32(y), rr)
					rest = rest[m:]
				}
			}
			x += cw
		}
	}
}
