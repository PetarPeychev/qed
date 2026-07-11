package main

import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

// Everything here is temp-allocated and must be consumed within the frame that
// produced it: the returned spans point into per-frame scratch.

MdSpan :: struct {
	text: string,
	fg:   tb2.Color,
}

MdLine :: struct {
	spans: []MdSpan,
	rule:  bool,
}

MdCell :: struct {
	text:  string,
	fg:    tb2.Color,
	w:     int,
	space: bool,
}

md_render :: proc(src: string, width: int, default_lang: Language) -> []MdLine {
	out := make([dynamic]MdLine, context.temp_allocator)
	if width <= 0 {
		return out[:]
	}
	raw := strings.split(src, "\n", context.temp_allocator)

	i := 0
	prev_blank := true
	for i < len(raw) {
		line := raw[i]
		trimmed := strings.trim_space(line)

		if fence, info, ok := md_fence(trimmed); ok {
			i += 1
			code := make([dynamic]string, context.temp_allocator)
			for i < len(raw) {
				t := strings.trim_space(raw[i])
				if cf, cinfo, cok := md_fence(t); cok && cf == fence && cinfo == "" {
					i += 1
					break
				}
				append(&code, raw[i])
				i += 1
			}
			md_emit_code(&out, code[:], info, default_lang)
			prev_blank = false
			continue
		}

		if trimmed == "" {
			if !prev_blank {
				append(&out, MdLine{})
			}
			prev_blank = true
			i += 1
			continue
		}

		if _, ind := md_code_indent(line); ind && prev_blank {
			code := make([dynamic]string, context.temp_allocator)
			for i < len(raw) {
				l := raw[i]
				if strings.trim_space(l) == "" {
					j := i
					for j < len(raw) && strings.trim_space(raw[j]) == "" {
						j += 1
					}
					more := false
					if j < len(raw) {
						_, more = md_code_indent(raw[j])
					}
					if !more {
						break
					}
					for i < j {
						append(&code, "")
						i += 1
					}
					continue
				}
				rest, ok2 := md_code_indent(l)
				if !ok2 {
					break
				}
				append(&code, rest)
				i += 1
			}
			md_emit_code(&out, code[:], "", default_lang)
			prev_blank = false
			continue
		}
		prev_blank = false

		if md_is_rule(trimmed) {
			append(&out, MdLine{rule = true})
			i += 1
			continue
		}

		if htext, hok := md_header(trimmed); hok {
			spans := md_inline(htext, COLOR_PANE_PROMPT_FG, u64(tb2.Color.Bold))
			md_wrap_append(&out, spans, width)
			i += 1
			continue
		}

		spans := md_inline(line, COLOR_PANE_FG, 0)
		md_wrap_append(&out, spans, width)
		i += 1
	}

	for len(out) > 0 {
		last := out[len(out) - 1]
		if last.rule || len(last.spans) != 0 {
			break
		}
		pop(&out)
	}
	return out[:]
}

md_fence :: proc(trimmed: string) -> (fence: u8, info: string, ok: bool) {
	if len(trimmed) < 3 {
		return 0, "", false
	}
	c := trimmed[0]
	if c != '`' && c != '~' {
		return 0, "", false
	}
	n := 0
	for n < len(trimmed) && trimmed[n] == c {
		n += 1
	}
	if n < 3 {
		return 0, "", false
	}
	return c, strings.trim_space(trimmed[n:]), true
}

md_code_indent :: proc(line: string) -> (rest: string, ok: bool) {
	if strings.has_prefix(line, "\t") {
		return line[1:], true
	}
	if strings.has_prefix(line, "    ") {
		return line[4:], true
	}
	return line, false
}

md_fence_language :: proc(info: string, default_lang: Language) -> Language {
	if info == "" {
		return default_lang
	}
	word := info
	if sp := strings.index_byte(info, ' '); sp >= 0 {
		word = info[:sp]
	}
	if l := language_of_name(word); l != .Plain {
		return l
	}
	return default_lang
}

md_emit_code :: proc(out: ^[dynamic]MdLine, code: []string, info: string, default_lang: Language) {
	lang := md_fence_language(info, default_lang)
	colors: [dynamic][dynamic]tb2.Color
	highlight_lines(lang, code, &colors)
	defer highlight_lines_destroy(&colors)
	for line, idx in code {
		cols := colors[idx][:] if idx < len(colors) else nil
		append(out, MdLine{spans = md_colors_to_spans(line, cols)})
	}
}

md_colors_to_spans :: proc(line: string, colors: []tb2.Color) -> []MdSpan {
	spans := make([dynamic]MdSpan, context.temp_allocator)
	if len(line) == 0 {
		return spans[:]
	}
	col_at :: proc(colors: []tb2.Color, i: int) -> tb2.Color {
		return colors[i] if i < len(colors) else COLOR_FG
	}
	sb := strings.builder_make(context.temp_allocator)
	cur := col_at(colors, 0)
	col := 0
	i := 0
	for i < len(line) {
		c := col_at(colors, i)
		if c != cur {
			md_inline_flush(&spans, &sb, cur)
			cur = c
		}
		r, sz := utf8.decode_rune(line[i:])
		if r == '\t' {
			next := (col / TAB_WIDTH + 1) * TAB_WIDTH
			for col < next {
				strings.write_byte(&sb, ' ')
				col += 1
			}
		} else {
			strings.write_rune(&sb, r)
			col += md_rune_width(r)
		}
		i += sz
	}
	md_inline_flush(&spans, &sb, cur)
	return spans[:]
}

md_rune_width :: proc(r: rune) -> int {
	w := int(tb2.wcwidth(r))
	return w if w >= 0 else 1
}

md_is_rule :: proc(trimmed: string) -> bool {
	if len(trimmed) < 3 {
		return false
	}
	c := trimmed[0]
	if c != '-' && c != '*' && c != '_' {
		return false
	}
	count := 0
	for i in 0 ..< len(trimmed) {
		ch := trimmed[i]
		switch ch {
		case c:
			count += 1
		case ' ', '\t':
		case:
			return false
		}
	}
	return count >= 3
}

md_header :: proc(trimmed: string) -> (string, bool) {
	n := 0
	for n < len(trimmed) && trimmed[n] == '#' {
		n += 1
	}
	if n == 0 || n > 6 {
		return "", false
	}
	if n < len(trimmed) && trimmed[n] != ' ' {
		return "", false
	}
	rest := strings.trim_space(trimmed[n:])
	rest = strings.trim_right(rest, "#")
	rest = strings.trim_space(rest)
	return rest, true
}

md_inline :: proc(text: string, base_fg: tb2.Color, base_attr: u64) -> []MdSpan {
	spans := make([dynamic]MdSpan, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	bold, italic := false, false

	i := 0
	for i < len(text) {
		c := text[i]
		if c == '`' {
			if close := strings.index_byte(text[i + 1:], '`'); close >= 0 {
				md_inline_flush(&spans, &sb, md_run_fg(base_fg, base_attr, bold, italic))
				code := text[i + 1 : i + 1 + close]
				append(&spans, MdSpan{strings.clone(code, context.temp_allocator), tb2.Color(u64(COLOR_SYN_CODE) | base_attr)})
				i = i + 1 + close + 1
				continue
			}
		}
		if c == '*' || c == '_' {
			double := i + 1 < len(text) && text[i + 1] == c
			mlen := 2 if double else 1
			open := bold if double else italic
			if md_marker_ok(text, i, mlen, c, open) {
				md_inline_flush(&spans, &sb, md_run_fg(base_fg, base_attr, bold, italic))
				if double {
					bold = !bold
				} else {
					italic = !italic
				}
				i += mlen
				continue
			}
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	md_inline_flush(&spans, &sb, md_run_fg(base_fg, base_attr, bold, italic))
	return spans[:]
}

md_run_fg :: proc(base_fg: tb2.Color, base_attr: u64, bold, italic: bool) -> tb2.Color {
	a := base_attr
	if bold {
		a |= u64(tb2.Color.Bold)
	}
	if italic {
		a |= u64(tb2.Color.Italic)
	}
	return tb2.Color(u64(base_fg) | a)
}

md_inline_flush :: proc(spans: ^[dynamic]MdSpan, sb: ^strings.Builder, fg: tb2.Color) {
	if strings.builder_len(sb^) == 0 {
		return
	}
	append(spans, MdSpan{strings.clone(strings.to_string(sb^), context.temp_allocator), fg})
	strings.builder_reset(sb)
}

// Basic left/right-flanking: an opener needs a non-space after it, a closer a
// non-space before it. `_` additionally must sit on a word boundary so
// snake_case identifiers survive.
md_marker_ok :: proc(text: string, i, mlen: int, c: u8, open: bool) -> bool {
	after := i + mlen
	if !open {
		if after >= len(text) || md_is_space(text[after]) {
			return false
		}
		if c == '_' && i > 0 && md_is_alnum(text[i - 1]) {
			return false
		}
		return true
	}
	if i == 0 || md_is_space(text[i - 1]) {
		return false
	}
	if c == '_' && after < len(text) && md_is_alnum(text[after]) {
		return false
	}
	return true
}

md_is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

md_is_alnum :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

md_wrap_append :: proc(out: ^[dynamic]MdLine, spans: []MdSpan, width: int) {
	cells := make([dynamic]MdCell, context.temp_allocator)
	col := 0
	for sp in spans {
		i := 0
		for i < len(sp.text) {
			r, sz := utf8.decode_rune(sp.text[i:])
			if r == '\t' {
				next := (col / TAB_WIDTH + 1) * TAB_WIDTH
				for col < next {
					append(&cells, MdCell{" ", sp.fg, 1, true})
					col += 1
				}
				i += sz
				continue
			}
			cw := md_rune_width(r)
			append(&cells, MdCell{sp.text[i : i + sz], sp.fg, cw, r == ' '})
			col += cw
			i += sz
		}
	}
	if len(cells) == 0 {
		return
	}

	line := make([dynamic]MdCell, context.temp_allocator)
	line_w := 0
	last_space := -1
	has_word := false
	emitted := false
	for cell in cells {
		if line_w > 0 && line_w + cell.w > width {
			emitted = true
			if last_space >= 0 {
				md_line_emit(out, line[:last_space])
				tail := line[last_space + 1:]
				next := make([dynamic]MdCell, context.temp_allocator)
				append(&next, ..tail)
				line = next
				line_w = 0
				last_space = -1
				has_word = false
				for c, idx in line {
					line_w += c.w
					if c.space {
						if has_word {
							last_space = idx
						}
					} else {
						has_word = true
					}
				}
			} else {
				md_line_emit(out, line[:])
				line = make([dynamic]MdCell, context.temp_allocator)
				line_w = 0
				last_space = -1
				has_word = false
			}
		}
		if emitted && line_w == 0 && cell.space {
			continue
		}
		append(&line, cell)
		if cell.space {
			if has_word {
				last_space = len(line) - 1
			}
		} else {
			has_word = true
		}
		line_w += cell.w
	}
	if len(line) > 0 {
		md_line_emit(out, line[:])
	}
}

md_line_emit :: proc(out: ^[dynamic]MdLine, cells: []MdCell) {
	end := len(cells)
	for end > 0 && cells[end - 1].space {
		end -= 1
	}
	append(out, MdLine{spans = md_cells_to_spans(cells[:end])})
}

md_cells_to_spans :: proc(cells: []MdCell) -> []MdSpan {
	spans := make([dynamic]MdSpan, context.temp_allocator)
	if len(cells) == 0 {
		return spans[:]
	}
	sb := strings.builder_make(context.temp_allocator)
	cur := cells[0].fg
	for c in cells {
		if c.fg != cur {
			if strings.builder_len(sb) > 0 {
				append(&spans, MdSpan{strings.clone(strings.to_string(sb), context.temp_allocator), cur})
				strings.builder_reset(&sb)
			}
			cur = c.fg
		}
		strings.write_string(&sb, c.text)
	}
	if strings.builder_len(sb) > 0 {
		append(&spans, MdSpan{strings.clone(strings.to_string(sb), context.temp_allocator), cur})
	}
	return spans[:]
}

md_line_width :: proc(line: MdLine) -> int {
	w := 0
	for s in line.spans {
		i := 0
		for i < len(s.text) {
			r, sz := utf8.decode_rune(s.text[i:])
			w += md_rune_width(r)
			i += sz
		}
	}
	return w
}

md_line_text :: proc(line: MdLine, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for s in line.spans {
		strings.write_string(&sb, s.text)
	}
	return strings.to_string(sb)
}

md_draw_line :: proc(x, y, w: int, line: MdLine, bg: tb2.Color) {
	if line.rule {
		for c in 0 ..< w {
			tb2.set_cell(i32(x + c), i32(y), '─', COLOR_PANE_BORDER, bg)
		}
		return
	}
	col := 0
	for sp in line.spans {
		i := 0
		for i < len(sp.text) && col < w {
			r, sz := utf8.decode_rune(sp.text[i:])
			cw := md_rune_width(r)
			if col + cw > w {
				return
			}
			tb2.set_cell(i32(x + col), i32(y), r, sp.fg, bg)
			col += cw
			i += sz
		}
	}
}
