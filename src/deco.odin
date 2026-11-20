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
	tint:            u8,
	bold, underline: bool,
	above, blend:    bool,
}

DecoMark :: struct {
	id:       u64,
	ns:       u32,
	from, to: Cursor,
}

DecoStore :: struct {
	items:       [dynamic]Deco,
	ghosts:      [dynamic]Deco,
	marks:       [dynamic]DecoMark,
	inline:      Deco,
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
	blend:          bool,
	alpha:          f32,
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
	delete(s.marks)
	delete(s.inline.text)
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
	w := 0
	for m in b.deco.marks {
		if m.ns == ns && m.from.row <= hi && m.to.row >= lo {
			continue
		}
		b.deco.marks[w] = m
		w += 1
	}
	resize(&b.deco.marks, w)
	if b.deco.inline.ns == ns && b.deco.inline.from.row >= lo && b.deco.inline.from.row <= hi {
		inline_clear(b)
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
	inline_clear(b)
	w := 0
	for m in b.deco.marks {
		m := m
		if cursor_before(m.from, at) && cursor_before(at, m.to) {
			continue
		}
		if !cursor_before(at, m.to) && m.from != m.to {
			b.deco.marks[w] = m
			w += 1
			continue
		}
		m.to = pos_shift_insert(m.to, at, end)
		m.from = pos_shift_insert(m.from, at, end)
		b.deco.marks[w] = m
		w += 1
	}
	resize(&b.deco.marks, w)
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
	inline_clear(b)
	w := 0
	for m in b.deco.marks {
		m := m
		if cursor_before(from, m.to) && cursor_before(m.from, to) {
			continue
		}
		m.from = pos_shift_delete(m.from, from, to)
		m.to = pos_shift_delete(m.to, from, to)
		b.deco.marks[w] = m
		w += 1
	}
	resize(&b.deco.marks, w)
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
	return diff_above(b, row) + deco_ghost_count(b, row, true)
}

ghost_below :: proc(b: ^Buffer, row: int) -> int {
	return diff_below(b, row) + deco_ghost_count(b, row, false)
}

deco_palette :: proc(keys: []string) -> []tb2.Color {
	pal := make([]tb2.Color, len(keys) + 1, context.temp_allocator)
	pal[0] = COLOR_FG
	for k, i in keys {
		pal[i + 1] = g_theme_colors[k] or_else COLOR_FG
	}
	return pal
}

deco_alpha :: proc(d: Deco) -> f32 {
	return config_tints[d.tint - 1].ptr^ if d.tint > 0 else d.alpha
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
				append(&rows[r - lo].tints, RowTint{pal[d.color], deco_alpha(d)})
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
					blend  = d.blend,
					alpha  = deco_alpha(d),
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

inline_clear :: proc(b: ^Buffer) {
	delete(b.deco.inline.text)
	b.deco.inline = {}
}

inline_set :: proc(b: ^Buffer, ns: u32, at: Cursor, text: string) {
	inline_clear(b)
	b.deco.inline = Deco {
		ns   = ns,
		from = at,
		to   = at,
		text = strings.clone(text),
	}
}

inline_active :: proc(editor: ^Editor) -> bool {
	b := editor_buffer(editor)
	return len(b.deco.inline.text) > 0 && b.cursor == b.deco.inline.from && !selection_active(b)
}

// Extra screen rows the shown ghost reserves below the cursor line (its inline
// first line adds none), so continuation lines land on blank rows.
inline_gap :: proc(editor: ^Editor) -> int {
	if !inline_active(editor) {
		return 0
	}
	return strings.count(editor_buffer(editor).deco.inline.text, "\n")
}

inline_dismiss :: proc(editor: ^Editor) {
	inline_clear(editor_buffer(editor))
}

inline_key :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	#partial switch ev.key {
	case .Tab:
		inline_accept(editor)
		return true
	case .Esc:
		inline_dismiss(editor)
		return true
	case .Arrow_Right:
		if ev_ctrl(ev) {
			inline_accept_word(editor)
			return true
		}
	}
	return false
}

inline_accept :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	text := strings.clone(b.deco.inline.text, context.temp_allocator)
	buffer_insert_text(b, text, .Atomic)
	editor_scroll(editor)
}

inline_accept_word :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	ghost := strings.clone(b.deco.inline.text, context.temp_allocator)
	ns := b.deco.inline.ns
	n := inline_word_len(ghost)
	buffer_insert_text(b, ghost[:n], .Atomic)
	if rest := ghost[n:]; len(strings.trim_space(rest)) > 0 {
		inline_set(b, ns, b.cursor, rest)
	}
	editor_scroll(editor)
}

// One accept step: leading blanks + a single same-class token, or a newline plus
// its following indentation. Rune-safe so a multibyte char is never split.
inline_word_len :: proc(s: string) -> int {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	if i < len(s) && s[i] == '\n' {
		i += 1
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
			i += 1
		}
		return i
	}
	if i >= len(s) {
		return i
	}
	r0, n0 := utf8.decode_rune(s[i:])
	cls := char_class(r0)
	i += n0
	for i < len(s) {
		if s[i] == ' ' || s[i] == '\t' || s[i] == '\n' {
			break
		}
		r, n := utf8.decode_rune(s[i:])
		if char_class(r) != cls {
			break
		}
		i += n
	}
	return i
}

inline_render :: proc(editor: ^Editor, cx, cy: int) {
	b := editor_buffer(editor)
	gutter := editor_gutter_width(editor)
	_, vh := editor_viewport(editor)
	full_w := int(tb2.width())
	drow := deco_rows(b, b.cursor.row, b.cursor.row + 1, deco_palette(editor.plugins.colors[:]))
	line_bg := editor_line_bg(true, diff_mark_at(b, b.cursor.row), diff_view_on(), drow[0].tints[:])

	emit :: proc(text: string, gutter, full_w, y, bx: int, fg, bg: tb2.Color) -> int {
		bx := bx
		for r in text {
			if r == '\t' {
				bx = gutter + ((bx - gutter) / TAB_WIDTH + 1) * TAB_WIDTH
				continue
			}
			if bx >= full_w {
				break
			}
			if bx >= gutter {
				tb2.set_cell(i32(bx), i32(y), r, fg, bg)
			}
			bx += 1
		}
		return bx
	}

	y := cy
	bx := cx
	for line, li in strings.split(b.deco.inline.text, "\n", context.temp_allocator) {
		if li > 0 {
			y += 1
			if y >= vh {
				return
			}
			bx = gutter
		}
		bg := line_bg if y == cy else COLOR_BG
		bx = emit(line, gutter, full_w, y, bx, COLOR_GHOST_FG, bg)
	}

	// The buffer render stopped the cursor line at the caret; re-emit its suffix
	// after the ghost so a mid-line ghost no longer overwrites the rest of the line.
	suffix := string(b.lines[b.cursor.row].text[b.cursor.col:])
	if len(suffix) > 0 {
		bg := line_bg if y == cy else COLOR_BG
		emit(suffix, gutter, full_w, y, bx, COLOR_FG, bg)
	}
}
