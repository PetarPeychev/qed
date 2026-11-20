package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "lib:tb2"

// all output lives in context.temp_allocator: consume it within the frame, or swap in an arena (pane_md_lines)

MdSpan :: struct {
	text:   string,
	fg, bg: tb2.Color,
	link:   string,
}

MdLine :: struct {
	spans:            []MdSpan,
	fill:             rune,
	fill_fg, fill_bg: tb2.Color,
	slug:             string,
	src:              int,
}

MdCell :: struct {
	text:       string,
	fg, bg:     tb2.Color,
	w:          int,
	space, brk: bool,
	link:       string,
}

MdKind :: enum {
	Paragraph,
	Heading,
	Code,
	Rule,
	Quote,
	List,
	Table,
	Html,
}

MdAlign :: enum {
	Left,
	Center,
	Right,
}

MdBlock :: struct {
	kind:     MdKind,
	level:    int,
	text:     string,
	lines:    []string,
	info:     string,
	children: []MdBlock,
	items:    []MdItem,
	ordered:  bool,
	start:    int,
	delim:    u8,
	loose:    bool,
	aligns:   []MdAlign,
	rows:     [][]string,
	src:      int,
}

MdItem :: struct {
	task:   int,
	blocks: []MdBlock,
	src:    int,
}

MdMarker :: struct {
	indent, width: int,
	ordered:       bool,
	ch:            u8,
	num:           int,
	content:       string,
}

MdPrefix :: struct {
	first, rest: string,
	fg:          tb2.Color,
	pending:     bool,
}

MdStyle :: struct {
	fg, heading, code, code_bg, link, bullet, checked, quote, border, dim: tb2.Color,
}

MdRender :: struct {
	out:         [dynamic]MdLine,
	width:       int,
	lang:        Language,
	style:       MdStyle,
	refs:        map[string]string,
	links:       [dynamic]string,
	link:        string,
	slugs:       map[string]int,
	prefix:      [dynamic]MdPrefix,
	gap, tight:  bool,
	nest:        int,
	inline:      int,
	depth:       int,
	em, strong:  int,
	src:         int,
}

MD_BULLETS := [?]string{"•", "◦", "▪"}
MD_MAX_NEST :: 64
MD_SCAN_MAX :: 4096

md_style :: proc() -> MdStyle {
	capture :: proc(name: string, fallback: tb2.Color) -> tb2.Color {
		c, ok := syntax_capture_color("markdown", name)
		return c if ok else fallback
	}
	st := MdStyle {
		fg = COLOR_PANE_FG,
		heading = capture("text.title", color_attr(COLOR_PANE_PROMPT_FG, .Bold)),
		code = capture("text.literal", COLOR_SYN_CODE),
		code_bg = color_over(COLOR_PANE_BG, COLOR_PANE_SEL_BG, MARKDOWN_CODE_TINT),
		link = capture("text.reference", COLOR_SYN_TYPE),
		bullet = capture("punctuation.special", COLOR_PANE_PROMPT_FG),
		checked = capture("string", COLOR_SYN_STRING),
		quote = COLOR_PANE_BORDER,
		border = COLOR_PANE_BORDER,
		dim = COLOR_PANE_SHORTCUT_FG,
	}
	// light themes pick a faint code color; on the band it must stay readable
	if md_contrast(st.code, st.code_bg) < 3 {
		st.code = tb2.Color(u64(COLOR_PANE_FG) | color_attrs(st.code))
	}
	return st
}

md_contrast :: proc(a, b: tb2.Color) -> f32 {
	lum :: proc(c: tb2.Color) -> f32 {
		ch :: proc(v: u64) -> f32 {
			f := f32(v & 0xff) / 255
			return f / 12.92 if f <= 0.03928 else math.pow((f + 0.055) / 1.055, 2.4)
		}
		v := u64(c)
		return 0.2126 * ch(v >> 16) + 0.7152 * ch(v >> 8) + 0.0722 * ch(v)
	}
	la, lb := lum(a), lum(b)
	return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

md_render :: proc(src: string, width: int, default_lang: Language) -> []MdLine {
	r := MdRender {
		width = width,
		lang  = default_lang,
		style = md_style(),
	}
	r.out = make([dynamic]MdLine, context.temp_allocator)
	if width <= 0 {
		return r.out[:]
	}
	r.refs = make(map[string]string, context.temp_allocator)
	r.links = make([dynamic]string, context.temp_allocator)
	r.slugs = make(map[string]int, context.temp_allocator)
	r.prefix = make([dynamic]MdPrefix, context.temp_allocator)
	raw := strings.split(src, "\n", context.temp_allocator)
	for &l in raw {
		l = md_expand_indent(md_sanitize(strings.trim_right(l, "\r")))
		// indent past the nesting cap means nothing, and every level rescans it
		if n := md_indent(l); n > 4 * MD_MAX_NEST {
			l = l[n - 4 * MD_MAX_NEST:]
		}
	}
	rows := make([]int, len(raw), context.temp_allocator)
	for &row, k in rows {
		row = k
	}
	blocks := make([dynamic]MdBlock, context.temp_allocator)
	if len(raw) > 1 && raw[0] == "---" {
		for k in 1 ..< len(raw) {
			if raw[k] == "---" || raw[k] == "..." {
				append(&blocks, MdBlock{kind = .Code, lines = raw[1:k], info = "yaml"})
				raw, rows = raw[k + 1:], rows[k + 1:]
				break
			}
		}
	}
	append(&blocks, ..md_parse(&r, raw, rows))
	md_blocks(&r, blocks[:])
	if len(r.links) > 0 {
		md_gap(&r, r.src)
		for url, i in r.links {
			mark := fmt.tprintf("[%d] ", i + 1)
			append(&r.prefix, MdPrefix{mark, strings.repeat(" ", len(mark), context.temp_allocator), r.style.dim, true})
			for row in md_wrap_hard({{text = url, fg = r.style.dim, link = url}}, md_avail(&r)) {
				md_emit(&r, row)
			}
			pop(&r.prefix)
		}
	}
	for len(r.out) > 0 {
		last := r.out[len(r.out) - 1]
		if last.fill != 0 || len(last.spans) != 0 {
			break
		}
		pop(&r.out)
	}
	return r.out[:]
}

md_sanitize :: proc(line: string) -> string {
	bad := false
	for c in transmute([]u8)line {
		bad ||= (c < 0x20 && c != '\t') || c == 0x7f
	}
	if !bad {
		return line
	}
	out := transmute([]u8)strings.clone(line, context.temp_allocator)
	for &c in out {
		if (c < 0x20 && c != '\t') || c == 0x7f {
			c = ' '
		}
	}
	return string(out)
}

md_expand_indent :: proc(line: string) -> string {
	n := 0
	for n < len(line) && (line[n] == ' ' || line[n] == '\t') {
		n += 1
	}
	if strings.index_byte(line[:n], '\t') < 0 {
		return line
	}
	sb := strings.builder_make(context.temp_allocator)
	col := 0
	for c in transmute([]u8)line[:n] {
		next := col + 1 if c == ' ' else (col / 4 + 1) * 4
		for col < next {
			strings.write_byte(&sb, ' ')
			col += 1
		}
	}
	strings.write_string(&sb, line[n:])
	return strings.to_string(sb)
}

md_indent :: proc(line: string) -> int {
	n := 0
	for n < len(line) && line[n] == ' ' {
		n += 1
	}
	return n
}

// plaintext as markdown that renders verbatim: punctuation escaped, indent kept as no-break spaces, every line break hard
md_escape_plain :: proc(text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	lines := strings.split(text, "\n", context.temp_allocator)
	for line, k in lines {
		l := strings.trim_right(line, "\r")
		n := md_indent(l)
		for _ in 0 ..< n {
			strings.write_string(&sb, "\u00a0")
		}
		for c in transmute([]u8)l[n:] {
			if md_is_punct(c) {
				strings.write_byte(&sb, '\\')
			}
			strings.write_byte(&sb, c)
		}
		if k < len(lines) - 1 {
			blank := md_blank(l) || (k + 1 < len(lines) && md_blank(lines[k + 1]))
			strings.write_string(&sb, "\n" if blank else "\\\n")
		}
	}
	return strings.to_string(sb)
}

md_trim :: proc(s: string) -> string {
	return strings.trim(s, " \t")
}

md_blank :: proc(line: string) -> bool {
	return md_trim(line) == ""
}

md_parse :: proc(r: ^MdRender, lines_in: []string, rows: []int) -> []MdBlock {
	blocks := make([dynamic]MdBlock, context.temp_allocator)
	// container bodies can start with a tab once their prefix is stripped
	lines := make([]string, len(lines_in), context.temp_allocator)
	for l, k in lines_in {
		lines[k] = md_expand_indent(l)
	}
	r.nest += 1
	defer r.nest -= 1
	nest_ok := r.nest < MD_MAX_NEST
	i := 0
	for i < len(lines) {
		line := lines[i]
		ind := md_indent(line)
		t := md_trim(line)
		if t == "" {
			i += 1
			continue
		}
		src := rows[i]
		if ind >= 4 {
			code := make([dynamic]string, context.temp_allocator)
			for i < len(lines) && (md_blank(lines[i]) || md_indent(lines[i]) >= 4) {
				append(&code, lines[i][4:] if len(lines[i]) >= 4 else "")
				i += 1
			}
			for len(code) > 0 && md_trim(code[len(code) - 1]) == "" {
				pop(&code)
			}
			append(&blocks, MdBlock{kind = .Code, lines = code[:], src = src})
			continue
		}
		if fence, n, info, ok := md_fence(t); ok {
			code := make([dynamic]string, context.temp_allocator)
			i += 1
			for i < len(lines) {
				ct := md_trim(lines[i])
				if cf, cn, cinfo, cok := md_fence(ct); cok && cf == fence && cn >= n && cinfo == "" && md_indent(lines[i]) < 4 {
					i += 1
					break
				}
				append(&code, lines[i][min(ind, md_indent(lines[i])):])
				i += 1
			}
			append(&blocks, MdBlock{kind = .Code, lines = code[:], info = info, src = src})
			continue
		}
		if level, text, ok := md_heading(t); ok {
			append(&blocks, MdBlock{kind = .Heading, level = level, text = text, src = src})
			i += 1
			continue
		}
		if md_is_rule(t) {
			append(&blocks, MdBlock{kind = .Rule, src = src})
			i += 1
			continue
		}
		if t[0] == '>' && nest_ok {
			sub := make([dynamic]string, context.temp_allocator)
			sub_rows := make([dynamic]int, context.temp_allocator)
			append(&sub, strings.trim_prefix(t[1:], " "))
			append(&sub_rows, src)
			i += 1
			for i < len(lines) {
				l := lines[i]
				lt := strings.trim_left(l, " ")
				if md_indent(l) < 4 && strings.has_prefix(lt, ">") {
					rest := lt[1:]
					if strings.has_prefix(rest, " ") {
						rest = rest[1:]
					}
					append(&sub, rest)
					append(&sub_rows, rows[i])
					i += 1
					continue
				}
				if md_blank(l) || len(sub) == 0 || md_blank(sub[len(sub) - 1]) || md_interrupts(l) {
					break
				}
				append(&sub, l)
				append(&sub_rows, rows[i])
				i += 1
			}
			append(&blocks, MdBlock{kind = .Quote, children = md_parse(r, sub[:], sub_rows[:]), src = src})
			continue
		}
		if _, ok := md_list_marker(line); ok && nest_ok {
			b: MdBlock
			b, i = md_parse_list(r, lines, rows, i)
			append(&blocks, b)
			continue
		}
		if b, end, ok := md_parse_table(lines, i); ok {
			b.src = src
			append(&blocks, b)
			i = end
			continue
		}
		if md_html_start(t) {
			sub := make([dynamic]string, context.temp_allocator)
			comment := strings.has_prefix(t, "<!--")
			for i < len(lines) && (comment || !md_blank(lines[i])) {
				append(&sub, md_trim(lines[i]))
				i += 1
				if comment && strings.contains(sub[len(sub) - 1], "-->") {
					comment = false
				}
			}
			append(&blocks, MdBlock{kind = .Html, text = strings.join(sub[:], " ", context.temp_allocator), src = src})
			continue
		}
		if label, url, ok := md_ref_def(t); ok {
			if label not_in r.refs {
				r.refs[label] = url
			}
			i += 1
			continue
		}
		para := make([dynamic]string, context.temp_allocator)
		append(&para, line)
		i += 1
		level := 0
		for i < len(lines) {
			l := lines[i]
			if md_blank(l) {
				break
			}
			if level = md_setext(l); level > 0 {
				i += 1
				break
			}
			if md_interrupts(l) {
				break
			}
			if _, _, ok := md_parse_table(lines, i); ok {
				break
			}
			append(&para, l)
			i += 1
		}
		text := md_join_para(para[:])
		if level > 0 {
			append(&blocks, MdBlock{kind = .Heading, level = level, text = text, src = src})
		} else {
			append(&blocks, MdBlock{kind = .Paragraph, text = text, src = src})
		}
	}
	return blocks[:]
}

md_join_para :: proc(lines: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for l, k in lines {
		s := strings.trim_left(l, " ")
		last := k == len(lines) - 1
		hard := false
		if !last && strings.has_suffix(s, "  ") {
			hard = true
		} else if !last && strings.has_suffix(s, "\\") {
			s = s[:len(s) - 1]
			hard = true
		}
		strings.write_string(&sb, strings.trim_right(s, " "))
		if !last {
			strings.write_byte(&sb, '\n' if hard else ' ')
		}
	}
	return strings.to_string(sb)
}

md_setext :: proc(line: string) -> int {
	if md_indent(line) >= 4 {
		return 0
	}
	t := md_trim(line)
	if t == "" || (t[0] != '=' && t[0] != '-') {
		return 0
	}
	for c in transmute([]u8)t {
		if c != t[0] {
			return 0
		}
	}
	return 1 if t[0] == '=' else 2
}

md_interrupts :: proc(line: string) -> bool {
	if md_indent(line) >= 4 {
		return false
	}
	t := md_trim(line)
	if t == "" {
		return false
	}
	if _, _, _, ok := md_fence(t); ok {
		return true
	}
	if _, _, ok := md_heading(t); ok {
		return true
	}
	if md_is_rule(t) || t[0] == '>' || md_html_start(t) {
		return true
	}
	if m, ok := md_list_marker(line); ok && m.content != "" && (!m.ordered || m.num == 1) {
		return true
	}
	return false
}

md_list_marker :: proc(line: string) -> (m: MdMarker, ok: bool) {
	ind := md_indent(line)
	if ind >= 4 {
		return
	}
	s := line[ind:]
	n := 0
	if len(s) > 0 && (s[0] == '-' || s[0] == '+' || s[0] == '*') {
		m.ch = s[0]
		n = 1
	} else {
		for n < len(s) && n < 9 && s[n] >= '0' && s[n] <= '9' {
			n += 1
		}
		if n == 0 || n >= len(s) || (s[n] != '.' && s[n] != ')') {
			return
		}
		m.ordered = true
		m.num, _ = strconv.parse_int(s[:n])
		m.ch = s[n]
		n += 1
	}
	rest := s[n:]
	if len(rest) > 0 && rest[0] != ' ' {
		return
	}
	sp := md_indent(rest)
	switch {
	case sp == len(rest):
		sp = 1
	case sp > 4:
		sp = 1
		m.content = rest[1:]
	case:
		m.content = rest[sp:]
	}
	m.indent = ind
	m.width = ind + n + sp
	return m, true
}

md_parse_list :: proc(r: ^MdRender, lines: []string, rows: []int, start: int) -> (MdBlock, int) {
	first, _ := md_list_marker(lines[start])
	b := MdBlock {
		kind    = .List,
		ordered = first.ordered,
		start   = first.num,
		delim   = first.ch,
		src     = rows[start],
	}
	items := make([dynamic]MdItem, context.temp_allocator)
	j := start
	for j < len(lines) {
		m, ok := md_list_marker(lines[j])
		if !ok || m.ordered != first.ordered || m.ch != first.ch {
			break
		}
		sub := make([dynamic]string, context.temp_allocator)
		sub_rows := make([dynamic]int, context.temp_allocator)
		item_src := rows[j]
		append(&sub, m.content)
		append(&sub_rows, item_src)
		j += 1
		blanks := 0
		for j < len(lines) {
			l := lines[j]
			if md_blank(l) {
				blanks += 1
				j += 1
				continue
			}
			if md_indent(l) >= m.width {
				if blanks > 0 {
					b.loose = true
				}
				for k in 0 ..< blanks {
					append(&sub, "")
					append(&sub_rows, rows[j - blanks + k])
				}
				blanks = 0
				append(&sub, l[m.width:])
				append(&sub_rows, rows[j])
				j += 1
				continue
			}
			_, item := md_list_marker(l)
			if blanks > 0 || item || md_interrupts(l) {
				break
			}
			append(&sub, strings.trim_left(l, " "))
			append(&sub_rows, rows[j])
			j += 1
		}
		task := -1
		c := sub[0]
		switch {
		case c == "[ ]" || strings.has_prefix(c, "[ ] "):
			task = 0
		case c == "[x]" || c == "[X]" || strings.has_prefix(c, "[x] ") || strings.has_prefix(c, "[X] "):
			task = 1
		}
		if task >= 0 {
			sub[0] = c[min(4, len(c)):]
		}
		append(&items, MdItem{task, md_parse(r, sub[:], sub_rows[:]), item_src})
		if blanks > 0 && j < len(lines) {
			if next, nok := md_list_marker(lines[j]); nok && next.ordered == first.ordered && next.ch == first.ch {
				b.loose = true
			}
		}
	}
	b.items = items[:]
	return b, j
}

md_table_cells :: proc(line: string) -> []string {
	t := md_trim(line)
	if strings.has_prefix(t, "|") {
		t = t[1:]
	}
	if strings.has_suffix(t, "|") && !strings.has_suffix(t, "\\|") {
		t = t[:len(t) - 1]
	}
	cells := make([dynamic]string, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	tick := 0
	i := 0
	for i < len(t) {
		c := t[i]
		switch {
		case c == '\\' && i + 1 < len(t) && t[i + 1] == '|':
			strings.write_byte(&sb, '|')
			i += 2
			continue
		case c == '`':
			n := md_run(t, i, '`')
			if tick == 0 {
				tick = n
			} else if tick == n {
				tick = 0
			}
			strings.write_string(&sb, t[i:i + n])
			i += n
			continue
		case c == '|' && tick == 0:
			append(&cells, md_trim(strings.clone(strings.to_string(sb), context.temp_allocator)))
			strings.builder_reset(&sb)
			i += 1
			continue
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	append(&cells, md_trim(strings.to_string(sb)))
	return cells[:]
}

md_table_delim :: proc(line: string) -> ([]MdAlign, bool) {
	if md_indent(line) >= 4 || strings.index_byte(line, '|') < 0 || strings.index_byte(line, '-') < 0 {
		return nil, false
	}
	cells := md_table_cells(line)
	aligns := make([]MdAlign, len(cells), context.temp_allocator)
	for c, i in cells {
		s := c
		left := strings.has_prefix(s, ":")
		right := strings.has_suffix(s, ":")
		s = strings.trim(s, ":")
		if s == "" || strings.trim_left(s, "-") != "" {
			return nil, false
		}
		aligns[i] = .Center if left && right else .Right if right else .Left
	}
	return aligns, true
}

md_parse_table :: proc(lines: []string, i: int) -> (b: MdBlock, end: int, ok: bool) {
	if i + 1 >= len(lines) || strings.index_byte(lines[i], '|') < 0 || md_indent(lines[i]) >= 4 {
		return
	}
	aligns, dok := md_table_delim(lines[i + 1])
	header := md_table_cells(lines[i])
	if !dok || len(header) != len(aligns) {
		return
	}
	rows := make([dynamic][]string, context.temp_allocator)
	append(&rows, header)
	end = i + 2
	for end < len(lines) && !md_blank(lines[end]) && strings.index_byte(lines[end], '|') >= 0 && !md_interrupts(lines[end]) {
		cells := md_table_cells(lines[end])
		row := make([]string, len(aligns), context.temp_allocator)
		copy(row, cells)
		append(&rows, row)
		end += 1
	}
	return MdBlock{kind = .Table, aligns = aligns, rows = rows[:]}, end, true
}

md_html_start :: proc(t: string) -> bool {
	if len(t) < 2 || t[0] != '<' {
		return false
	}
	if strings.has_prefix(t, "<!--") {
		return true
	}
	j := 2 if t[1] == '/' else 1
	start := j
	for j < len(t) && (md_is_alnum(t[j]) || t[j] == '-') {
		j += 1
	}
	if !md_html_known(t[start:j]) {
		return false
	}
	return j == len(t) || t[j] == ' ' || t[j] == '>' || t[j] == '/'
}

// only real tag names, so hover types like Vec<T> or Promise<Response> stay text
md_html_known :: proc(name: string) -> bool {
	switch strings.to_lower(name, context.temp_allocator) {
	case "br", "p", "div", "img", "b", "strong", "i", "em", "code", "a", "span", "sup", "sub", "kbd", "details", "summary", "table", "thead", "tbody", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "hr", "pre", "picture", "source", "center":
		return true
	}
	return false
}

md_ref_def :: proc(t: string) -> (label, url: string, ok: bool) {
	if !strings.has_prefix(t, "[") || strings.has_prefix(t, "[^") {
		return
	}
	close := strings.index(t, "]:")
	if close <= 1 {
		return
	}
	rest := md_trim(t[close + 2:])
	if rest == "" {
		return
	}
	tail := ""
	if strings.has_prefix(rest, "<") {
		e := strings.index_byte(rest, '>')
		if e <= 0 {
			return
		}
		rest, tail = rest[1:e], rest[e + 1:]
	} else if sp := strings.index_any(rest, " \t"); sp >= 0 {
		rest, tail = rest[:sp], rest[sp:]
	}
	tail = md_trim(tail)
	if tail != "" {
		close_ch := u8(')') if tail[0] == '(' else tail[0]
		if (tail[0] != '"' && tail[0] != '\'' && tail[0] != '(') || len(tail) < 2 || tail[len(tail) - 1] != close_ch {
			return
		}
	}
	return md_ref_key(t[1:close]), rest, true
}

md_ref_key :: proc(label: string) -> string {
	return strings.to_lower(strings.join(strings.fields(label, context.temp_allocator), " ", context.temp_allocator), context.temp_allocator)
}

md_fence :: proc(trimmed: string) -> (fence: u8, n: int, info: string, ok: bool) {
	if len(trimmed) < 3 {
		return
	}
	c := trimmed[0]
	if c != '`' && c != '~' {
		return
	}
	n = md_run(trimmed, 0, c)
	if n < 3 {
		return
	}
	info = md_trim(trimmed[n:])
	if c == '`' && strings.index_byte(info, '`') >= 0 {
		return
	}
	return c, n, info, true
}

md_fence_language :: proc(info: string, default_lang: Language) -> Language {
	if info == "" {
		return default_lang
	}
	word := info
	if sp := strings.index_any(info, " {,"); sp >= 0 {
		word = info[:sp]
	}
	if l := language_of_name(word); l != .Plain {
		return l
	}
	return default_lang
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
	for ch in transmute([]u8)trimmed {
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

md_heading :: proc(trimmed: string) -> (level: int, text: string, ok: bool) {
	n := md_run(trimmed, 0, '#')
	if n == 0 || n > 6 || (n < len(trimmed) && trimmed[n] != ' ') {
		return
	}
	rest := md_trim(trimmed[n:])
	closing := strings.trim_right(rest, "#")
	if closing == "" || strings.has_suffix(closing, " ") {
		rest = md_trim(closing)
	}
	return n, rest, true
}

md_run :: proc(s: string, i: int, c: u8) -> int {
	n := 0
	for i + n < len(s) && s[i + n] == c {
		n += 1
	}
	return n
}

md_gap :: proc(r: ^MdRender, src: int) {
	if r.gap && !r.tight {
		md_emit_blank(r)
	}
	r.gap = true
	r.src = src
}

md_blocks :: proc(r: ^MdRender, blocks: []MdBlock) {
	for &b in blocks {
		md_block(r, &b)
	}
}

md_block :: proc(r: ^MdRender, b: ^MdBlock) {
	switch b.kind {
	case .Paragraph:
		md_gap(r, b.src)
		md_emit_wrapped(r, md_inline(r, b.text, r.style.fg))
	case .Heading:
		md_gap(r, b.src)
		spans := md_inline(r, b.text, r.style.heading)
		at := len(r.out)
		md_emit_wrapped(r, spans)
		if at < len(r.out) {
			r.out[at].slug = md_slug(r, md_line_text({spans = spans}))
		}
		if b.level == 1 {
			md_emit(r, nil, '━', tb2.Color(u64(r.style.heading) & COLOR_RGB_MASK))
		} else if b.level == 2 {
			md_emit(r, nil, '─', r.style.border)
		}
	case .Code:
		md_gap(r, b.src)
		md_emit_code(r, b.lines, b.info)
	case .Rule:
		md_gap(r, b.src)
		md_emit(r, nil, '─', r.style.border)
	case .Quote:
		md_gap(r, b.src)
		append(&r.prefix, MdPrefix{"│ ", "│ ", r.style.quote, true})
		tight := r.tight
		r.gap, r.tight = false, false
		md_blocks(r, b.children)
		r.gap, r.tight = true, tight
		pop(&r.prefix)
	case .List:
		md_gap(r, b.src)
		md_emit_list(r, b)
	case .Table:
		md_gap(r, b.src)
		md_emit_table(r, b)
	case .Html:
		rows := md_wrap(md_inline(r, b.text, r.style.fg), md_avail(r))
		if len(rows) == 0 {
			return
		}
		md_gap(r, b.src)
		for row in rows {
			if len(row) > 0 {
				md_emit(r, row)
			}
		}
	}
}

md_emit_list :: proc(r: ^MdRender, b: ^MdBlock) {
	marks := make([]string, len(b.items), context.temp_allocator)
	w := 0
	for _, k in b.items {
		marks[k] = fmt.tprintf("%d%c", b.start + k, b.delim) if b.ordered else MD_BULLETS[r.depth % len(MD_BULLETS)]
		w = max(w, md_text_width(marks[k]))
	}
	tight := r.tight
	r.tight = !b.loose
	r.depth += 1
	for &it, k in b.items {
		if k > 0 && b.loose {
			md_emit_blank(r)
		}
		first := fmt.tprintf("%s%s ", strings.repeat(" ", w - md_text_width(marks[k]), context.temp_allocator), marks[k])
		fg := r.style.bullet
		if it.task >= 0 {
			box := "☑ " if it.task == 1 else "☐ "
			first = strings.concatenate({first, box}, context.temp_allocator) if b.ordered else box
			if it.task == 1 {
				fg = r.style.checked
			}
		}
		append(&r.prefix, MdPrefix{first, strings.repeat(" ", md_text_width(first), context.temp_allocator), fg, true})
		r.gap = false
		r.src = it.src
		if len(it.blocks) == 0 {
			md_emit(r, nil)
		}
		md_blocks(r, it.blocks)
		pop(&r.prefix)
	}
	r.depth -= 1
	r.tight = tight
	r.gap = true
}

md_emit_code :: proc(r: ^MdRender, code: []string, info: string) {
	lang := md_fence_language(info, r.lang)
	colors: [dynamic][dynamic]tb2.Color
	highlight_lines(lang, code, &colors)
	defer highlight_lines_destroy(&colors)
	bg := r.style.code_bg
	w := max(1, md_avail(r) - 1)
	for line, idx in code {
		spans := md_colors_to_spans(line, colors[idx][:] if idx < len(colors) else nil)
		for &s in spans {
			s.bg = bg
		}
		for row in md_wrap_hard(spans, w) {
			content := make([dynamic]MdSpan, 0, len(row) + 1, context.temp_allocator)
			append(&content, MdSpan{text = " ", fg = COLOR_PANE_FG, bg = bg})
			append(&content, ..row)
			md_emit(r, content[:], ' ', COLOR_PANE_FG, bg)
		}
	}
}

md_emit_table :: proc(r: ^MdRender, b: ^MdBlock) {
	n := len(b.aligns)
	cells := make([][][]MdSpan, len(b.rows), context.temp_allocator)
	nat := make([]int, n, context.temp_allocator)
	word := make([]int, n, context.temp_allocator)
	for row, ri in b.rows {
		cells[ri] = make([][]MdSpan, n, context.temp_allocator)
		fg := color_attr(r.style.fg, .Bold) if ri == 0 else r.style.fg
		for c in 0 ..< n {
			cells[ri][c] = md_inline(r, row[c], fg)
			for line in md_wrap(cells[ri][c], max(int)) {
				nat[c] = max(nat[c], md_spans_width(line))
				for w in strings.fields(md_line_text({spans = line}), context.temp_allocator) {
					word[c] = max(word[c], md_text_width(w))
				}
			}
		}
	}
	budget := md_avail(r) - (3 * n + 1)
	widths := make([]int, n, context.temp_allocator)
	total := 0
	for c in 0 ..< n {
		widths[c] = max(1, nat[c])
		total += widths[c]
	}
	if total > budget {
		if budget < 3 * n {
			md_emit_table_flat(r, cells)
			return
		}
		base := make([]int, n, context.temp_allocator)
		left := budget
		for c in 0 ..< n {
			base[c] = max(1, min(word[c], widths[c]))
			left -= base[c]
		}
		if left < 0 {
			left = budget
			for &b in base {
				b = 0
			}
		}
		order := make([]int, n, context.temp_allocator)
		for c in 0 ..< n {
			order[c] = c
			for k := c; k > 0 && widths[order[k]] - base[order[k]] < widths[order[k - 1]] - base[order[k - 1]]; k -= 1 {
				order[k], order[k - 1] = order[k - 1], order[k]
			}
		}
		for c, k in order {
			add := min(widths[c] - base[c], left / (n - k))
			widths[c] = max(1, base[c] + add)
			left -= add
		}
	}
	wrapped := make([][][][]MdSpan, len(cells), context.temp_allocator)
	heights := make([]int, len(cells), context.temp_allocator)
	tall := false
	for row, ri in cells {
		wrapped[ri] = make([][][]MdSpan, n, context.temp_allocator)
		for c in 0 ..< n {
			wrapped[ri][c] = md_wrap(row[c], widths[c])
			heights[ri] = max(heights[ri], len(wrapped[ri][c]), 1)
		}
		tall = tall || (ri > 0 && heights[ri] > 1)
	}
	md_emit(r, md_table_rule(r, widths, "┌", "┬", "┐"))
	for row, ri in wrapped {
		if ri == 1 || (ri > 1 && tall) {
			md_emit(r, md_table_rule(r, widths, "├", "┼", "┤"))
		}
		for l in 0 ..< heights[ri] {
			spans := make([dynamic]MdSpan, context.temp_allocator)
			append(&spans, MdSpan{text = "│", fg = r.style.border})
			for c in 0 ..< n {
				line := row[c][l] if l < len(row[c]) else nil
				pad := widths[c] - md_spans_width(line)
				lpad := 0
				switch b.aligns[c] {
				case .Left:
				case .Right:
					lpad = pad
				case .Center:
					lpad = pad / 2
				}
				append(&spans, MdSpan{text = strings.repeat(" ", 1 + lpad, context.temp_allocator), fg = r.style.fg})
				append(&spans, ..line)
				append(&spans, MdSpan{text = strings.repeat(" ", 1 + pad - lpad, context.temp_allocator), fg = r.style.fg})
				append(&spans, MdSpan{text = "│", fg = r.style.border})
			}
			md_emit(r, spans[:])
		}
	}
	md_emit(r, md_table_rule(r, widths, "└", "┴", "┘"))
}

md_table_rule :: proc(r: ^MdRender, widths: []int, left, mid, right: string) -> []MdSpan {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, left)
	for w, c in widths {
		if c > 0 {
			strings.write_string(&sb, mid)
		}
		for _ in 0 ..< w + 2 {
			strings.write_string(&sb, "─")
		}
	}
	strings.write_string(&sb, right)
	spans := make([]MdSpan, 1, context.temp_allocator)
	spans[0] = {text = strings.to_string(sb), fg = r.style.border}
	return spans
}

md_emit_table_flat :: proc(r: ^MdRender, cells: [][][]MdSpan) {
	head := cells[0]
	if len(cells) == 1 {
		for h in head {
			md_emit_wrapped(r, h)
		}
		return
	}
	for row, ri in cells[1:] {
		if ri > 0 {
			md_emit(r, nil, '─', r.style.border)
		}
		for c in 0 ..< len(row) {
			spans := make([dynamic]MdSpan, context.temp_allocator)
			append(&spans, ..head[c])
			append(&spans, MdSpan{text = ": ", fg = r.style.dim})
			append(&spans, ..row[c])
			md_emit_wrapped(r, spans[:])
		}
	}
}

md_prefix_spans :: proc(r: ^MdRender, consume: bool) -> [dynamic]MdSpan {
	spans := make([dynamic]MdSpan, 0, len(r.prefix) + 4, context.temp_allocator)
	shown := md_prefix_shown(r)
	for &p, k in r.prefix {
		s := p.rest
		if p.pending && consume {
			s = p.first
			p.pending = false
		}
		if k < shown {
			append(&spans, MdSpan{text = s, fg = p.fg})
		}
	}
	return spans
}

// deep nesting keeps only the outer prefixes that fit in half the width, so text never starves
md_prefix_shown :: proc(r: ^MdRender) -> int {
	w := 0
	for p, k in r.prefix {
		w += md_text_width(p.rest)
		if w > r.width / 2 {
			return k
		}
	}
	return len(r.prefix)
}

md_avail :: proc(r: ^MdRender) -> int {
	w := 0
	for p in r.prefix[:md_prefix_shown(r)] {
		w += md_text_width(p.rest)
	}
	return max(1, r.width - w)
}

md_emit :: proc(r: ^MdRender, content: []MdSpan, fill: rune = 0, fill_fg: tb2.Color = {}, fill_bg: tb2.Color = {}) {
	spans := md_prefix_spans(r, true)
	append(&spans, ..content)
	out := spans[:]
	if md_spans_width(out) > r.width {
		cells := md_cells(out)
		w, n := 0, 0
		for n < len(cells) && w + cells[n].w <= r.width {
			w += cells[n].w
			n += 1
		}
		out = md_cells_to_spans(cells[:n])
	}
	append(&r.out, MdLine{spans = out, fill = fill, fill_fg = fill_fg, fill_bg = fill_bg, src = r.src})
}

// rendered lines run in source order, so the block holding src starts at the first line of the last src <= it
md_line_of_src :: proc(lines: []MdLine, src: int) -> int {
	at, best := 0, -1
	for line, i in lines {
		if line.src > src {
			break
		}
		if line.src > best {
			at, best = i, line.src
		}
	}
	return at
}

md_emit_blank :: proc(r: ^MdRender) {
	spans := md_prefix_spans(r, false)
	for len(spans) > 0 {
		last := &spans[len(spans) - 1]
		last.text = strings.trim_right(last.text, " ")
		if last.text != "" {
			break
		}
		pop(&spans)
	}
	append(&r.out, MdLine{spans = spans[:], src = r.src})
}

md_emit_wrapped :: proc(r: ^MdRender, spans: []MdSpan) {
	for row in md_wrap(spans, md_avail(r)) {
		md_emit(r, row)
	}
}

md_inline :: proc(r: ^MdRender, text: string, fg: tb2.Color) -> []MdSpan {
	spans := make([dynamic]MdSpan, context.temp_allocator)
	md_inline_into(r, &spans, text, fg)
	r.em, r.strong = 0, 0
	return spans[:]
}

md_fg :: proc(base: tb2.Color, outer: tb2.Color, extra: u64 = 0) -> tb2.Color {
	return tb2.Color(u64(base) | color_attrs(outer) | extra)
}

md_inline_flush :: proc(r: ^MdRender, spans: ^[dynamic]MdSpan, sb: ^strings.Builder, fg: tb2.Color) {
	if strings.builder_len(sb^) == 0 {
		return
	}
	extra: u64
	if r.em > 0 {
		extra |= u64(tb2.Color.Italic)
	}
	if r.strong > 0 {
		extra |= u64(tb2.Color.Bold)
	}
	append(spans, MdSpan{text = strings.clone(strings.to_string(sb^), context.temp_allocator), fg = tb2.Color(u64(fg) | extra), link = r.link})
	strings.builder_reset(sb)
}

md_inline_into :: proc(r: ^MdRender, spans: ^[dynamic]MdSpan, text: string, fg: tb2.Color) {
	r.inline += 1
	defer r.inline -= 1
	if r.inline > MD_MAX_NEST {
		append(spans, MdSpan{text = text, fg = fg, link = r.link})
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		switch c {
		case '\\':
			if i + 1 < len(text) && md_is_punct(text[i + 1]) {
				strings.write_byte(&sb, text[i + 1])
				i += 2
				continue
			}
		case '`':
			n := md_run(text, i, '`')
			if close := md_find_run(text, i + n, '`', n); close >= 0 {
				md_inline_flush(r, spans, &sb, fg)
				code, _ := strings.replace_all(text[i + n:close], "\n", " ", context.temp_allocator)
				if len(code) >= 2 && code[0] == ' ' && code[len(code) - 1] == ' ' && md_trim(code) != "" {
					code = code[1:len(code) - 1]
				}
				append(spans, MdSpan{text = code, fg = md_fg(r.style.code, fg), bg = r.style.code_bg, link = r.link})
				i = close + n
				continue
			}
			strings.write_string(&sb, text[i:i + n])
			i += n
			continue
		case '!':
			if i + 1 < len(text) && text[i + 1] == '[' {
				if label_end, _, end, ok := md_link_at(r, text, i + 1); ok {
					md_inline_flush(r, spans, &sb, fg)
					alt := md_plain(text[i + 2:label_end])
					append(spans, MdSpan{text = fmt.tprintf("[image: %s]", alt) if alt != "" else "[image]", fg = r.style.dim, link = r.link})
					i = end
					continue
				}
			}
		case '[':
			if label_end, dest, end, ok := md_link_at(r, text, i); ok {
				md_inline_flush(r, spans, &sb, fg)
				inner := text[i + 1:label_end]
				outer := r.link
				r.link = dest
				md_inline_into(r, spans, inner, md_fg(r.style.link, fg, u64(tb2.Color.Underline)))
				md_footnote(r, spans, dest, inner)
				r.link = outer
				i = end
				continue
			}
		case '<':
			if end, url, ok := md_autolink(text, i); ok {
				md_inline_flush(r, spans, &sb, fg)
				append(spans, MdSpan{text = url, fg = md_fg(r.style.link, fg, u64(tb2.Color.Underline)), link = url})
				i = end
				continue
			}
			if end, ok := md_html_tag(r, spans, &sb, text, i, fg); ok {
				i = end
				continue
			}
		case '*', '_', '~':
			n := md_run(text, i, c)
			if (c == '~' && n == 2) || (c != '~' && n <= 3) {
				if md_can_open(text, i, n, c) {
					if close := md_find_closer(text, i + n, c, n); close >= 0 {
						md_inline_flush(r, spans, &sb, fg)
						attr: u64
						switch {
						case c == '~':
							attr = u64(tb2.Color.Strikeout)
						case n == 1:
							attr = u64(tb2.Color.Italic)
						case n == 2:
							attr = u64(tb2.Color.Bold)
						case:
							attr = u64(tb2.Color.Bold) | u64(tb2.Color.Italic)
						}
						md_inline_into(r, spans, text[i + n:close], tb2.Color(u64(fg) | attr))
						i = close + n
						continue
					}
				}
			}
			strings.write_string(&sb, text[i:i + n])
			i += n
			continue
		case '&':
			if s, end, ok := md_entity(text, i); ok {
				strings.write_string(&sb, s)
				i = end
				continue
			}
		case 'h':
			if (strings.has_prefix(text[i:], "https://") || strings.has_prefix(text[i:], "http://")) && (i == 0 || !md_is_alnum(text[i - 1])) {
				end := i
				for end < len(text) && text[end] != ' ' && text[end] != '\n' && text[end] != '<' {
					end += 1
				}
				for end > i && strings.index_byte(".,;:!?*_'\")", text[end - 1]) >= 0 {
					if text[end - 1] == ')' && strings.count(text[i:end], "(") >= strings.count(text[i:end], ")") {
						break
					}
					end -= 1
				}
				md_inline_flush(r, spans, &sb, fg)
				append(spans, MdSpan{text = text[i:end], fg = md_fg(r.style.link, fg, u64(tb2.Color.Underline)), link = text[i:end]})
				i = end
				continue
			}
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	md_inline_flush(r, spans, &sb, fg)
}

md_footnote :: proc(r: ^MdRender, spans: ^[dynamic]MdSpan, dest, label: string) {
	if dest == "" || dest[0] == '#' || md_plain(label) == dest {
		return
	}
	n := -1
	for u, k in r.links {
		if u == dest {
			n = k
			break
		}
	}
	if n < 0 {
		append(&r.links, dest)
		n = len(r.links) - 1
	}
	append(spans, MdSpan{text = fmt.tprintf("[%d]", n + 1), fg = r.style.dim, link = dest})
}

md_plain :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '*', '_', '`', '~':
			continue
		case '\\':
			if i + 1 < len(s) {
				i += 1
				c = s[i]
			}
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}

md_find_run :: proc(text: string, from: int, c: u8, n: int) -> int {
	text := text[:min(len(text), from + MD_SCAN_MAX)]
	j := from
	for j < len(text) {
		if text[j] != c {
			j += 1
			continue
		}
		m := md_run(text, j, c)
		if m == n {
			return j
		}
		j += m
	}
	return -1
}

md_can_open :: proc(text: string, i, n: int, c: u8) -> bool {
	after := i + n
	if after >= len(text) || md_is_space(text[after]) {
		return false
	}
	return c != '_' || i == 0 || !md_is_alnum(text[i - 1])
}

md_find_closer :: proc(text: string, from: int, c: u8, n: int) -> int {
	text := text[:min(len(text), from + MD_SCAN_MAX)]
	j := from
	for j < len(text) {
		ch := text[j]
		switch ch {
		case '\\':
			j += 2
			continue
		case '`':
			m := md_run(text, j, '`')
			if close := md_find_run(text, j + m, '`', m); close >= 0 {
				j = close + m
			} else {
				j += m
			}
			continue
		case c:
			m := md_run(text, j, c)
			ok := m == n && j > from && !md_is_space(text[j - 1])
			if ok && c == '_' && j + m < len(text) && md_is_alnum(text[j + m]) {
				ok = false
			}
			if ok {
				return j
			}
			j += m
			continue
		}
		j += 1
	}
	return -1
}

md_link_at :: proc(r: ^MdRender, text: string, i: int) -> (label_end: int, dest: string, end: int, ok: bool) {
	text := text[:min(len(text), i + MD_SCAN_MAX)]
	depth := 0
	j := i
	label_end = -1
	scan: for j < len(text) {
		switch text[j] {
		case '\\':
			j += 2
			continue
		case '`':
			m := md_run(text, j, '`')
			if close := md_find_run(text, j + m, '`', m); close >= 0 {
				j = close + m
				continue
			}
			j += m
			continue
		case '[':
			depth += 1
		case ']':
			depth -= 1
			if depth == 0 {
				label_end = j
				break scan
			}
		}
		j += 1
	}
	if label_end < 0 {
		return
	}
	k := label_end + 1
	if k < len(text) && text[k] == '(' {
		k += 1
		for k < len(text) && text[k] == ' ' {
			k += 1
		}
		start := k
		if k < len(text) && text[k] == '<' {
			e := strings.index_byte(text[k:], '>')
			if e < 0 {
				return
			}
			dest = text[k + 1:k + e]
			k += e + 1
		} else {
			parens := 0
			for k < len(text) && text[k] != ' ' && text[k] != '\n' {
				if text[k] == '(' {
					parens += 1
				} else if text[k] == ')' {
					if parens == 0 {
						break
					}
					parens -= 1
				}
				k += 1
			}
			dest = text[start:k]
		}
		for k < len(text) && md_is_space(text[k]) {
			k += 1
		}
		if k < len(text) && (text[k] == '"' || text[k] == '\'' || text[k] == '(') {
			close := u8(')') if text[k] == '(' else text[k]
			e := strings.index_byte(text[k + 1:], close)
			if e < 0 {
				return
			}
			k += e + 2
			for k < len(text) && md_is_space(text[k]) {
				k += 1
			}
		}
		if k >= len(text) || text[k] != ')' {
			return
		}
		return label_end, dest, k + 1, true
	}
	if k < len(text) && text[k] == '[' {
		if e := strings.index_byte(text[k:], ']'); e >= 0 {
			key := text[k + 1:k + e]
			if key == "" {
				key = text[i + 1:label_end]
			}
			if u, found := r.refs[md_ref_key(key)]; found {
				return label_end, u, k + e + 1, true
			}
		}
		return
	}
	if u, found := r.refs[md_ref_key(text[i + 1:label_end])]; found {
		return label_end, u, label_end + 1, true
	}
	return
}

md_autolink :: proc(text: string, i: int) -> (end: int, url: string, ok: bool) {
	e := strings.index_byte(text[i:], '>')
	if e < 3 {
		return
	}
	inner := text[i + 1:i + e]
	if strings.index_any(inner, " <\n") >= 0 {
		return
	}
	colon := strings.index_byte(inner, ':')
	scheme := colon >= 2 && md_is_alpha(inner[0])
	for k in 0 ..< max(colon, 0) {
		scheme = scheme && (md_is_alnum(inner[k]) || inner[k] == '+' || inner[k] == '.' || inner[k] == '-')
	}
	at := strings.index_byte(inner, '@')
	if !scheme && (at <= 0 || strings.index_byte(inner[at:], '.') < 0) {
		return
	}
	return i + e + 1, inner, true
}

md_html_tag :: proc(r: ^MdRender, spans: ^[dynamic]MdSpan, sb: ^strings.Builder, text: string, i: int, fg: tb2.Color) -> (end: int, ok: bool) {
	if strings.has_prefix(text[i:], "<!--") {
		e := strings.index(text[i + 4:], "-->")
		return (i + 4 + e + 3 if e >= 0 else len(text)), true
	}
	j := i + 1
	closing := j < len(text) && text[j] == '/'
	if closing {
		j += 1
	}
	if j >= len(text) || !md_is_alpha(text[j]) {
		return
	}
	name_start := j
	for j < len(text) && (md_is_alnum(text[j]) || text[j] == '-') {
		j += 1
	}
	name := strings.to_lower(text[name_start:j], context.temp_allocator)
	if !md_html_known(name) {
		return
	}
	e := strings.index_byte(text[j:min(len(text), j + MD_SCAN_MAX)], '>')
	if e < 0 || strings.index_byte(text[j:j + e], '\n') >= 0 || strings.index_byte(text[j:j + e], '<') >= 0 {
		return
	}
	attrs := text[j:j + e]
	end = j + e + 1
	switch name {
	case "br":
		strings.write_byte(sb, '\n')
	case "p", "div", "tr", "li", "td", "th", "table", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote":
		if closing {
			strings.write_byte(sb, '\n')
		}
	case "img":
		md_inline_flush(r, spans, sb, fg)
		alt := md_html_attr(attrs, "alt")
		append(spans, MdSpan{text = fmt.tprintf("[image: %s]", alt) if alt != "" else "[image]", fg = r.style.dim})
	case "em", "i":
		md_inline_flush(r, spans, sb, fg)
		r.em = max(0, r.em + (-1 if closing else 1))
	case "strong", "b":
		md_inline_flush(r, spans, sb, fg)
		r.strong = max(0, r.strong + (-1 if closing else 1))
	}
	return end, true
}

md_html_attr :: proc(attrs, name: string) -> string {
	k := strings.index(attrs, fmt.tprintf("%s=", name))
	if k < 0 {
		return ""
	}
	v := attrs[k + len(name) + 1:]
	if len(v) > 0 && (v[0] == '"' || v[0] == '\'') {
		if e := strings.index_byte(v[1:], v[0]); e >= 0 {
			return v[1:1 + e]
		}
		return ""
	}
	if sp := strings.index_any(v, " />"); sp >= 0 {
		return v[:sp]
	}
	return v
}

md_entity :: proc(text: string, i: int) -> (s: string, end: int, ok: bool) {
	e := strings.index_byte(text[i:], ';')
	if e < 2 || e > 10 {
		return
	}
	name := text[i + 1:i + e]
	end = i + e + 1
	if name[0] == '#' {
		cp: int
		pok: bool
		if len(name) > 1 && (name[1] == 'x' || name[1] == 'X') {
			cp, pok = strconv.parse_int(name[2:], 16)
		} else {
			cp, pok = strconv.parse_int(name[1:], 10)
		}
		if !pok || cp <= 0 || cp > 0x10FFFF {
			return
		}
		buf, n := utf8.encode_rune(rune(cp))
		return strings.clone(string(buf[:n]), context.temp_allocator), end, true
	}
	switch name {
	case "amp":
		return "&", end, true
	case "lt":
		return "<", end, true
	case "gt":
		return ">", end, true
	case "quot":
		return "\"", end, true
	case "apos":
		return "'", end, true
	case "nbsp":
		return " ", end, true
	case "copy":
		return "©", end, true
	case "mdash":
		return "—", end, true
	case "ndash":
		return "–", end, true
	case "hellip":
		return "…", end, true
	case "rarr":
		return "→", end, true
	case "larr":
		return "←", end, true
	}
	return
}

md_is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n'
}

md_is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

md_is_alnum :: proc(c: u8) -> bool {
	return md_is_alpha(c) || (c >= '0' && c <= '9')
}

md_is_punct :: proc(c: u8) -> bool {
	return strings.index_byte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) >= 0
}

md_colors_to_spans :: proc(line: string, colors: []tb2.Color) -> []MdSpan {
	spans := make([dynamic]MdSpan, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	col_at :: proc(colors: []tb2.Color, i: int) -> tb2.Color {
		return colors[i] if i < len(colors) else COLOR_FG
	}
	cur := col_at(colors, 0)
	col := 0
	i := 0
	for i < len(line) {
		if c := col_at(colors, i); c != cur {
			if strings.builder_len(sb) > 0 {
				append(&spans, MdSpan{text = strings.clone(strings.to_string(sb), context.temp_allocator), fg = cur})
				strings.builder_reset(&sb)
			}
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
	if strings.builder_len(sb) > 0 {
		append(&spans, MdSpan{text = strings.clone(strings.to_string(sb), context.temp_allocator), fg = cur})
	}
	return spans[:]
}

md_rune_width :: proc(r: rune) -> int {
	w := int(tb2.wcwidth(r))
	return w if w >= 0 else 1
}

// grapheme_next rescans from the start, so long lines walk the iterator once here
md_clusters :: proc(s: string) -> []string {
	ascii := true
	for c in transmute([]u8)s {
		ascii &&= c < 0x80
	}
	out := make([dynamic]string, 0, len(s), context.temp_allocator)
	if ascii {
		for i in 0 ..< len(s) {
			append(&out, s[i:i + 1])
		}
		return out[:]
	}
	it := utf8.decode_grapheme_iterator_make(s)
	prev := 0
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if g.byte_index > prev {
			append(&out, s[prev:g.byte_index])
			prev = g.byte_index
		}
	}
	if prev < len(s) {
		append(&out, s[prev:])
	}
	return out[:]
}

md_text_width :: proc(s: string) -> int {
	ascii := true
	for c in transmute([]u8)s {
		ascii &&= c >= 0x20 && c < 0x7f
	}
	if ascii {
		return len(s)
	}
	w := 0
	for c in md_clusters(s) {
		w += cluster_width(transmute([]u8)c)
	}
	return w
}

md_spans_width :: proc(spans: []MdSpan) -> int {
	w := 0
	for s in spans {
		w += md_text_width(s.text)
	}
	return w
}

md_cells :: proc(spans: []MdSpan) -> [dynamic]MdCell {
	cells := make([dynamic]MdCell, context.temp_allocator)
	col := 0
	for sp in spans {
		for cluster in md_clusters(sp.text) {
			switch cluster {
			case "\n":
				append(&cells, MdCell{brk = true})
				col = 0
			case "\t":
				for stop := (col / TAB_WIDTH + 1) * TAB_WIDTH; col < stop; col += 1 {
					append(&cells, MdCell{" ", sp.fg, sp.bg, 1, true, false, sp.link})
				}
			case:
				cw := cluster_width(transmute([]u8)cluster)
				append(&cells, MdCell{cluster, sp.fg, sp.bg, cw, cluster == " ", false, sp.link})
				col += cw
			}
		}
	}
	return cells
}

md_cells_to_spans :: proc(cells: []MdCell) -> []MdSpan {
	spans := make([dynamic]MdSpan, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	fg, bg: tb2.Color
	link: string
	for c, k in cells {
		if k > 0 && (c.fg != fg || c.bg != bg || c.link != link) {
			append(&spans, MdSpan{strings.clone(strings.to_string(sb), context.temp_allocator), fg, bg, link})
			strings.builder_reset(&sb)
		}
		fg, bg, link = c.fg, c.bg, c.link
		strings.write_string(&sb, c.text)
	}
	if len(cells) > 0 {
		append(&spans, MdSpan{strings.clone(strings.to_string(sb), context.temp_allocator), fg, bg, link})
	}
	return spans[:]
}

md_wrap_flush :: proc(out: ^[dynamic][]MdSpan, line: []MdCell) {
	start, end := 0, len(line)
	for end > 0 && line[end - 1].space {
		end -= 1
	}
	for start < end && line[start].space {
		start += 1
	}
	append(out, md_cells_to_spans(line[start:end]))
}

md_wrap :: proc(spans: []MdSpan, width: int) -> [][]MdSpan {
	out := make([dynamic][]MdSpan, context.temp_allocator)
	line := make([dynamic]MdCell, context.temp_allocator)
	lw, last := 0, -1
	for c in md_cells(spans) {
		if c.brk {
			md_wrap_flush(&out, line[:])
			line = make([dynamic]MdCell, context.temp_allocator)
			lw, last = 0, -1
			continue
		}
		if c.space && lw == 0 && len(out) > 0 {
			continue
		}
		if lw > 0 && lw + c.w > width {
			if c.space {
				md_wrap_flush(&out, line[:])
				line = make([dynamic]MdCell, context.temp_allocator)
				lw, last = 0, -1
				continue
			}
			tail := make([dynamic]MdCell, context.temp_allocator)
			if last > 0 {
				append(&tail, ..line[last + 1:])
				md_wrap_flush(&out, line[:last])
			} else {
				md_wrap_flush(&out, line[:])
			}
			line = tail
			lw, last = 0, -1
			for t in line {
				lw += t.w
			}
			if lw > 0 && lw + c.w > width {
				md_wrap_flush(&out, line[:])
				line = make([dynamic]MdCell, context.temp_allocator)
				lw = 0
			}
		}
		append(&line, c)
		lw += c.w
		if c.space && len(line) > 1 {
			last = len(line) - 1
		}
	}
	if len(line) > 0 {
		md_wrap_flush(&out, line[:])
	}
	return out[:]
}

// always at least one row, so an empty code line still gets its band
md_wrap_hard :: proc(spans: []MdSpan, width: int) -> [][]MdSpan {
	out := make([dynamic][]MdSpan, context.temp_allocator)
	line := make([dynamic]MdCell, context.temp_allocator)
	lw := 0
	for c in md_cells(spans) {
		if c.brk || (lw > 0 && lw + c.w > width) {
			append(&out, md_cells_to_spans(line[:]))
			line = make([dynamic]MdCell, context.temp_allocator)
			lw = 0
			if c.brk {
				continue
			}
		}
		append(&line, c)
		lw += c.w
	}
	append(&out, md_cells_to_spans(line[:]))
	return out[:]
}

// GitHub heading anchors: lowercase, spaces to '-', punctuation dropped, repeats get -1, -2
md_slug :: proc(r: ^MdRender, text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in strings.to_lower(text, context.temp_allocator) {
		switch {
		case c == ' ':
			strings.write_byte(&sb, '-')
		case c == '-' || c == '_' || unicode.is_letter(c) || unicode.is_digit(c):
			strings.write_rune(&sb, c)
		}
	}
	slug := strings.to_string(sb)
	n := r.slugs[slug]
	r.slugs[slug] = n + 1
	return slug if n == 0 else fmt.tprintf("%s-%d", slug, n)
}

md_line_link :: proc(line: MdLine, col: int) -> string {
	x := 0
	for sp in line.spans {
		w := md_text_width(sp.text)
		if col >= x && col < x + w {
			return sp.link
		}
		x += w
	}
	return ""
}

md_line_width :: proc(line: MdLine) -> int {
	return md_spans_width(line.spans)
}

md_line_text :: proc(line: MdLine, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for s in line.spans {
		strings.write_string(&sb, s.text)
	}
	return strings.to_string(sb)
}

md_draw_line :: proc(x, y, w: int, line: MdLine, bg: tb2.Color) {
	col := 0
	for sp in line.spans {
		sbg := sp.bg if u64(sp.bg) != 0 else bg
		for c in md_clusters(sp.text) {
			cluster := transmute([]u8)c
			cw := cluster_width(cluster)
			if col + cw > w {
				return
			}
			r, n := utf8.decode_rune(cluster)
			tb2.set_cell(i32(x + col), i32(y), r, sp.fg, sbg)
			for rest := cluster[n:]; len(rest) > 0; {
				rr, m := utf8.decode_rune(rest)
				tb2.extend_cell(i32(x + col), i32(y), rr)
				rest = rest[m:]
			}
			col += cw
		}
	}
	if line.fill != 0 {
		fbg := line.fill_bg if u64(line.fill_bg) != 0 else bg
		for ; col < w; col += 1 {
			tb2.set_cell(i32(x + col), i32(y), line.fill, line.fill_fg, fbg)
		}
	}
}
