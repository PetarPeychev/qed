package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

PREVIEW_HEX_BYTES :: 16
PREVIEW_EMPTY_TEXT :: "(empty file)"
PREVIEW_MAX_LINES :: 4000
PREVIEW_PARSE_AHEAD :: 64

PreviewRowKind :: enum {
	Content,
	Added,
	Modified,
	Ghost,
	Gap,
}

PreviewRow :: struct {
	text:   string,
	colors: [dynamic]tb2.Color,
	lineno: int,
	kind:   PreviewRowKind,
	span:   [2]int,
}

// A scrollable, syntax-highlighted preview of a file, buffer, or git diff. Content
// mode highlights line 1 → viewport + lookahead, extending as it scrolls; diff mode
// builds the changed hunks (+ context) up front in the inline-diff-view style.
Preview :: struct {
	rows:         [dynamic]PreviewRow,
	src:          [dynamic]string,
	scroll:       int,
	focus:        int,
	numw:         int,
	language:     Language,
	parsed_to:    int,
	diff:         bool,
	no_highlight: bool,
	path:         string,
	complete:     bool,
	width:        int,
	hex:          bool,
	empty:        bool,
}

preview_rows_clear :: proc(p: ^Preview) {
	for &r in p.rows {
		delete(r.colors)
		delete(r.text)
	}
	clear(&p.rows)
	p.parsed_to = 0
}

preview_reset :: proc(p: ^Preview) {
	preview_rows_clear(p)
	for s in p.src {
		delete(s)
	}
	clear(&p.src)
	if p.path != "" {
		delete(p.path)
		p.path = ""
	}
	p.scroll = 0
	p.focus = 0
	p.numw = 0
	p.width = 0
	p.diff = false
	p.no_highlight = false
	p.complete = false
	p.hex = false
	p.empty = false
}

preview_destroy :: proc(p: ^Preview) {
	preview_reset(p)
	delete(p.rows)
	delete(p.src)
}

preview_total :: proc(p: ^Preview) -> int {
	return len(p.rows) if p.diff else len(p.src)
}

preview_set_file :: proc(p: ^Preview, path: string, focus, view_h: int) {
	preview_reset(p)
	p.path = strings.clone(path)
	p.language = language_of(path)
	p.focus = focus

	if data, ok := preview_file_bytes(p.path, PREVIEW_HEX_BYTES * PREVIEW_MAX_LINES); ok {
		if len(data) == 0 {
			p.empty = true
			return
		}
		if preview_is_binary(data) {
			preview_hex_fill(p, data)
			return
		}
	}

	p.scroll = max(0, (focus - 1) - view_h / 2) if focus > 0 else 0
	preview_ensure(p, view_h)
}

preview_file_bytes :: proc(path: string, limit: int) -> (data: []u8, ok: bool) {
	fd, err := os.open(path)
	if err != nil {
		return nil, false
	}
	defer os.close(fd)
	buf := make([]u8, limit, context.temp_allocator)
	total := 0
	for total < limit {
		n, rerr := os.read(fd, buf[total:])
		if n > 0 {
			total += n
			continue
		}
		if rerr != nil && rerr != io.Error.EOF {
			return nil, false
		}
		break
	}
	return buf[:total], true
}

preview_is_binary :: proc(data: []u8) -> bool {
	for b in data {
		if b == 0 {
			return true
		}
	}
	return false
}

preview_hex_fill :: proc(p: ^Preview, data: []u8) {
	p.hex = true
	p.no_highlight = true
	p.complete = true
	p.numw = 0
	for off := 0; off < len(data) && len(p.src) < PREVIEW_MAX_LINES; off += PREVIEW_HEX_BYTES {
		end := min(off + PREVIEW_HEX_BYTES, len(data))
		append(&p.src, hex_dump_line(data[off:end], off))
	}
	for s in p.src {
		append(&p.rows, PreviewRow{text = strings.clone(s), lineno = 0, kind = .Content})
	}
	p.parsed_to = len(p.src)
}

hex_dump_line :: proc(data: []u8, offset: int, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "%08x  ", offset)
	for j in 0 ..< PREVIEW_HEX_BYTES {
		if j == PREVIEW_HEX_BYTES / 2 {
			strings.write_byte(&sb, ' ')
		}
		if j < len(data) {
			fmt.sbprintf(&sb, "%02x ", data[j])
		} else {
			strings.write_string(&sb, "   ")
		}
	}
	strings.write_string(&sb, " |")
	for b in data {
		c: u8 = '.'
		if b >= 0x20 && b < 0x7f {
			c = b
		}
		strings.write_byte(&sb, c)
	}
	strings.write_byte(&sb, '|')
	return strings.to_string(sb)
}

preview_set_buffer :: proc(p: ^Preview, b: ^Buffer, focus, view_h: int) {
	preview_reset(p)
	p.language = b.language
	p.no_highlight = b.big
	p.complete = true
	p.focus = focus
	if len(b.lines) == 1 && len(b.lines[0].text) == 0 {
		p.empty = true
		return
	}
	for line, i in b.lines {
		if i >= PREVIEW_MAX_LINES {
			break
		}
		append(&p.src, strings.clone(string(line.text[:])))
	}
	p.scroll = max(0, (focus - 1) - view_h / 2)
	preview_ensure(p, view_h)
}

preview_file_reload :: proc(p: ^Preview, want: int) {
	cmd := fmt.ctprintf("head -n %d %s 2>/dev/null", want, shell_quote(p.path))
	out, ok := shell_capture(cmd)
	if !ok {
		p.complete = true
		return
	}
	for s in p.src {
		delete(s)
	}
	clear(&p.src)
	p.parsed_to = 0
	count := 0
	for line in strings.split_lines_iterator(&out) {
		append(&p.src, strings.clone(line))
		count += 1
	}
	p.complete = count < want
}

preview_ensure :: proc(p: ^Preview, view_h: int) {
	if p.diff {
		return
	}
	want := min(PREVIEW_MAX_LINES, p.scroll + view_h + PREVIEW_PARSE_AHEAD)
	if p.path != "" && !p.complete && want > len(p.src) {
		preview_file_reload(p, want)
	}
	p.scroll = clamp(p.scroll, 0, preview_max_scroll(p, view_h))
	preview_content_extend(p, view_h)
}

preview_content_extend :: proc(p: ^Preview, view_h: int) {
	need := min(len(p.src), p.scroll + view_h + PREVIEW_PARSE_AHEAD)
	if need <= p.parsed_to && len(p.rows) >= need {
		return
	}
	preview_rows_clear(p)
	p.numw = digit_count(max(1, len(p.src)))
	if need == 0 {
		return
	}

	if p.no_highlight {
		for i in 0 ..< need {
			append(&p.rows, PreviewRow{text = strings.clone(p.src[i]), lineno = i + 1, kind = .Content})
		}
		p.parsed_to = need
		return
	}

	bytes := 0
	for i in 0 ..< need {
		bytes += len(p.src[i]) + 1
	}

	tmp: [dynamic][dynamic]tb2.Color
	if bytes >= HIGHLIGHT_ASYNC_BYTES {
		// Above the async gate, color only the window (occasionally imprecise at
		// the top edge) to bound keypress latency, like project-search.
		highlight_lines(p.language, p.src[p.scroll:need], &tmp)
		for i in 0 ..< need {
			row: PreviewRow = {text = strings.clone(p.src[i]), lineno = i + 1, kind = .Content}
			w := i - p.scroll
			if w >= 0 && w < len(tmp) {
				row.colors = tmp[w]
				tmp[w] = nil
			}
			append(&p.rows, row)
		}
	} else {
		highlight_lines(p.language, p.src[:need], &tmp)
		for i in 0 ..< need {
			row: PreviewRow = {text = strings.clone(p.src[i]), lineno = i + 1, kind = .Content}
			if i < len(tmp) {
				row.colors = tmp[i]
				tmp[i] = nil
			}
			append(&p.rows, row)
		}
	}
	for row in tmp {
		delete(row)
	}
	delete(tmp)
	p.parsed_to = need
}

preview_set_diff :: proc(p: ^Preview, path: string, view_h: int, diff_only: bool) {
	preview_reset(p)
	p.language = language_of(path)
	base_text, cur, marks, hunks, ok := git_diff_file(path)
	if !ok {
		return
	}

	changed := false
	for m in marks {
		if m != .None {
			changed = true
			break
		}
	}
	if !changed && len(hunks) == 0 {
		// Selected file matches HEAD after all — show plain content.
		p.language = language_of(path)
		p.complete = true
		for s, i in cur {
			if i >= PREVIEW_MAX_LINES {
				break
			}
			append(&p.src, strings.clone(s))
		}
		preview_ensure(p, view_h)
		return
	}

	p.diff = true
	p.complete = true
	n := len(cur)
	ctx := PREVIEW_DIFF_CONTEXT
	visible := make([]bool, n, context.temp_allocator)
	mark_row := proc(vis: []bool, r, ctx: int) {
		for j in max(0, r - ctx) ..= min(len(vis) - 1, r + ctx) {
			vis[j] = true
		}
	}
	if diff_only {
		for m, i in marks {
			if m != .None {
				mark_row(visible, i, ctx)
			}
		}
		for h in hunks {
			mark_row(visible, clamp(h.row, 0, n - 1), ctx)
		}
	} else {
		for i in 0 ..< n {
			visible[i] = true
		}
	}

	emitted := false
	gap_pending := false
	for i in 0 ..< n {
		if !visible[i] {
			if emitted {
				gap_pending = true
			}
			continue
		}
		if gap_pending {
			append(&p.rows, PreviewRow{kind = .Gap})
			gap_pending = false
		}
		for h in hunks {
			if h.above && clamp(h.row, 0, n - 1) == i {
				preview_emit_ghosts(p, h, base_text, cur, true)
			}
		}
		span := [2]int{}
		if marks[i] == .Modified {
			if old, okp := preview_pair_old(hunks, base_text, i); okp {
				_, ns := git_word_span(old, cur[i])
				span = ns
			}
		}
		kind := PreviewRowKind.Content
		#partial switch marks[i] {
		case .Added:
			kind = .Added
		case .Modified:
			kind = .Modified
		}
		append(&p.rows, PreviewRow{text = strings.clone(cur[i]), lineno = i + 1, kind = kind, span = span})
		emitted = true
		for h in hunks {
			if !h.above && clamp(h.row, 0, n - 1) == i {
				preview_emit_ghosts(p, h, base_text, cur, false)
			}
		}
	}

	last := 0
	for r in p.rows {
		if r.kind != .Ghost && r.kind != .Gap && r.lineno > last {
			last = r.lineno
		}
	}
	p.numw = digit_count(max(1, last))

	bytes := 0
	for i in 0 ..< min(last, n) {
		bytes += len(cur[i]) + 1
	}
	if last > 0 && bytes < HIGHLIGHT_ASYNC_BYTES {
		tmp: [dynamic][dynamic]tb2.Color
		highlight_lines(p.language, cur[:last], &tmp)
		for &r in p.rows {
			if r.kind == .Ghost || r.kind == .Gap {
				continue
			}
			idx := r.lineno - 1
			if idx >= 0 && idx < len(tmp) {
				r.colors = tmp[idx]
				tmp[idx] = nil
			}
		}
		for row in tmp {
			delete(row)
		}
		delete(tmp)
	}
}

preview_emit_ghosts :: proc(p: ^Preview, h: GitHunk, base_text, cur: []string, above: bool) {
	for gi in 0 ..< h.hi - h.lo {
		bi := h.lo + gi
		if bi >= len(base_text) {
			break
		}
		span := [2]int{}
		if above && gi < h.new_n && h.row + gi < len(cur) {
			os, _ := git_word_span(base_text[bi], cur[h.row + gi])
			span = os
		}
		append(&p.rows, PreviewRow{text = strings.clone(base_text[bi]), kind = .Ghost, span = span})
	}
}

preview_pair_old :: proc(hunks: []GitHunk, base_text: []string, row: int) -> (string, bool) {
	for h in hunks {
		if !h.above || h.new_n == 0 {
			continue
		}
		off := row - h.row
		if off >= 0 && off < h.new_n && h.lo + off < h.hi && h.lo + off < len(base_text) {
			return base_text[h.lo + off], true
		}
	}
	return "", false
}

preview_row_str :: proc(p: ^Preview, i: int) -> (string, PreviewRowKind) {
	if p.diff {
		return p.rows[i].text, p.rows[i].kind
	}
	return p.src[i], .Content
}

preview_visual_h :: proc(p: ^Preview, i, textw: int) -> int {
	text, kind := preview_row_str(p, i)
	if p.hex || kind == .Gap || textw <= 0 {
		return 1
	}
	return len(line_wrap(transmute([]u8)text, textw))
}

// Largest scroll (top logical row) that still pins the last visual row to the
// bottom, so a soft-wrapped tail stays reachable. Falls back to whole-row math
// until the first render records the pane width.
preview_max_scroll :: proc(p: ^Preview, view_h: int) -> int {
	total := preview_total(p)
	textw := p.width - (p.numw + 2)
	if p.width <= 0 || textw <= 0 {
		return max(0, total - view_h)
	}
	acc, top := 0, total
	for i := total - 1; i >= 0; i -= 1 {
		hgt := preview_visual_h(p, i, textw)
		if acc + hgt > view_h {
			break
		}
		acc += hgt
		top = i
	}
	return min(top, max(0, total - 1))
}

preview_scroll_by :: proc(p: ^Preview, delta, view_h: int) {
	p.scroll = clamp(p.scroll + delta, 0, preview_max_scroll(p, view_h))
	preview_ensure(p, view_h)
}

preview_wheel :: proc(p: ^Preview, ev: tb2.Event, right: Rect, view_h: int) -> bool {
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		if mouse_in_rect(ev, right) {
			preview_scroll_by(p, -WHEEL_SCROLL_LINES, view_h)
			return true
		}
	case .Mouse_Wheel_Down:
		if mouse_in_rect(ev, right) {
			preview_scroll_by(p, WHEEL_SCROLL_LINES, view_h)
			return true
		}
	}
	return false
}

// Screen columns spanned by `text[:upto]`, tab-aware; every other cluster counts
// as width 1 (the preview's simple model, matching `preview_draw_seg`).
preview_vcol :: proc(text: string, upto: int) -> int {
	col, i := 0, 0
	for i < upto && i < len(text) {
		r, sz := utf8.decode_rune(text[i:])
		if r == '\t' {
			col = (col / TAB_WIDTH + 1) * TAB_WIDTH
		} else {
			col += 1
		}
		i += sz
	}
	return col
}

preview_draw_gutter :: proc(x, y, numw, lineno: int, fg, bg: tb2.Color) {
	s: string
	if lineno <= 0 {
		s = strings.repeat(" ", numw + 2, context.temp_allocator)
	} else {
		num := fmt.tprintf("%d", lineno)
		pad := strings.repeat(" ", max(0, numw - len(num)), context.temp_allocator)
		s = fmt.tprintf("%s%s  ", pad, num)
	}
	col := 0
	for r in s {
		tb2.set_cell(i32(x + col), i32(y), r, fg, bg)
		col += 1
	}
}

// Draws the byte range [seg_start, seg_end) of `text` on one visual row.
// `x_origin` is the absolute screen column of `seg_start` (0 for the first
// segment, past-the-break for wrap continuations) so tab stops stay aligned.
// `colors` and `span` are indexed by absolute byte offset into `text`.
preview_draw_seg :: proc(x, y, w: int, text: string, colors: []tb2.Color, seg_start, seg_end, x_origin: int, base_fg, bg: tb2.Color, span: [2]int, span_bg: tb2.Color) {
	col := 0
	i := seg_start
	for i < seg_end && col < w {
		r, sz := utf8.decode_rune(text[i:])
		fg := base_fg
		if i < len(colors) {
			fg = colors[i]
		}
		cell_bg := bg
		if span[0] != span[1] && i >= span[0] && i < span[1] {
			cell_bg = span_bg
		}
		if r == '\t' {
			abs := x_origin + col
			next := (abs / TAB_WIDTH + 1) * TAB_WIDTH - x_origin
			for col < next && col < w {
				tb2.set_cell(i32(x + col), i32(y), ' ', fg, cell_bg)
				col += 1
			}
		} else {
			tb2.set_cell(i32(x + col), i32(y), r, fg, cell_bg)
			col += 1
		}
		i += sz
	}
	for col < w {
		tb2.set_cell(i32(x + col), i32(y), ' ', base_fg, bg)
		col += 1
	}
}

preview_render :: proc(p: ^Preview, x, y, w, h: int) {
	p.width = w
	if p.empty {
		preview_draw_seg(x + 2, y, max(0, w - 2), PREVIEW_EMPTY_TEXT, nil, 0, len(PREVIEW_EMPTY_TEXT), 0, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG, {}, COLOR_PANE_BG)
		return
	}
	add_bg := color_over(COLOR_PANE_BG, COLOR_GIT_ADD, GIT_HUNK_TINT)
	mod_bg := color_over(COLOR_PANE_BG, COLOR_GIT_MOD, GIT_HUNK_TINT)
	ghost_bg := color_over(COLOR_PANE_BG, COLOR_GIT_DEL, GIT_DIFF_GHOST_TINT)
	ghost_word := color_over(COLOR_PANE_BG, COLOR_GIT_DEL, GIT_DIFF_WORD_TINT)
	mod_word := color_over(COLOR_PANE_BG, COLOR_GIT_MOD, GIT_DIFF_WORD_TINT)

	gutterw := p.numw + 2
	textw := max(0, w - gutterw)
	sy := 0
	ri := p.scroll
	for sy < h && ri < len(p.rows) {
		row := p.rows[ri]
		ri += 1
		if row.kind == .Gap {
			preview_draw_gutter(x, y + sy, p.numw, 0, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
			preview_draw_seg(x + gutterw, y + sy, textw, ICON_PREVIEW_MORE, nil, 0, len(ICON_PREVIEW_MORE), 0, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG, {}, COLOR_PANE_BG)
			sy += 1
			continue
		}

		base_fg := COLOR_PANE_FG
		bg := COLOR_PANE_BG
		word_bg := COLOR_PANE_BG
		colors := row.colors[:]
		if p.focus > 0 && !p.diff && row.lineno == p.focus {
			base_fg = COLOR_PANE_SEL_FG
			bg = COLOR_PANE_SEL_BG
		} else {
			#partial switch row.kind {
			case .Ghost:
				base_fg = COLOR_GHOST_FG
				bg = ghost_bg
				word_bg = ghost_word
				colors = nil
			case .Added:
				bg = add_bg
			case .Modified:
				bg = mod_bg
				word_bg = mod_word
			}
		}

		if p.hex {
			preview_draw_gutter(x, y + sy, p.numw, 0, base_fg, bg)
			preview_draw_seg(x + gutterw, y + sy, textw, row.text, colors, 0, len(row.text), 0, base_fg, bg, row.span, word_bg)
			sy += 1
			continue
		}

		segs := line_wrap(transmute([]u8)row.text, textw)
		for s in 0 ..< len(segs) {
			if sy >= h {
				break
			}
			seg_start := segs[s]
			seg_end := segs[s + 1] if s + 1 < len(segs) else len(row.text)
			x_origin := preview_vcol(row.text, seg_start)
			preview_draw_gutter(x, y + sy, p.numw, row.lineno if s == 0 else 0, base_fg, bg)
			preview_draw_seg(x + gutterw, y + sy, textw, row.text, colors, seg_start, seg_end, x_origin, base_fg, bg, row.span, word_bg)
			sy += 1
		}
	}
}
