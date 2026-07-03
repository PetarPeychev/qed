package main

import "core:strings"
import "lib:tb2"
import ts "lib:tree_sitter"

Highlight :: struct {
	computed: bool,
	valid:    bool,
	rev:      u64,
	colors:   [dynamic][dynamic]tb2.Color,
}

Syntax :: struct {
	tried:  bool,
	ready:  bool,
	parser: ^ts.Parser,
	query:  ^ts.Query,
	cursor: ^ts.QueryCursor,
	colors: [dynamic]tb2.Color,
	paint:  [dynamic]bool,
}

@(private = "file")
g_syntaxes: [Language]Syntax

syntax_ensure :: proc(language: Language) -> bool {
	s := &g_syntaxes[language]
	if s.tried {
		return s.ready
	}
	s.tried = true

	info := LANGUAGES[language]
	if info.grammar == nil || info.highlights == nil {
		return false
	}

	lang := info.grammar()
	s.parser = ts.parser_new()
	if !ts.parser_set_language(s.parser, lang) {
		return false
	}

	err_off: u32
	err_type: ts.QueryError
	s.query = ts.query_new(lang, raw_data(info.highlights), u32(len(info.highlights)), &err_off, &err_type)
	if s.query == nil {
		return false
	}
	s.cursor = ts.query_cursor_new()

	n := ts.query_capture_count(s.query)
	for id in 0 ..< n {
		length: u32
		name_ptr := ts.query_capture_name_for_id(s.query, id, &length)
		name := string(name_ptr[:length])
		color, ok := syntax_capture_color(name)
		append(&s.colors, color)
		append(&s.paint, ok)
	}

	s.ready = true
	return true
}

syntax_shutdown :: proc() {
	for &s in g_syntaxes {
		if s.cursor != nil {
			ts.query_cursor_delete(s.cursor)
		}
		if s.query != nil {
			ts.query_delete(s.query)
		}
		if s.parser != nil {
			ts.parser_delete(s.parser)
		}
		delete(s.colors)
		delete(s.paint)
	}
}

syntax_capture_color :: proc(name: string) -> (tb2.Color, bool) {
	switch {
	case strings.has_prefix(name, "keyword"),
	     strings.has_prefix(name, "conditional"),
	     strings.has_prefix(name, "repeat"),
	     strings.has_prefix(name, "include"),
	     name == "storageclass":
		return COLOR_SYN_KEYWORD, true
	case strings.has_prefix(name, "type"):
		return COLOR_SYN_TYPE, true
	case strings.has_prefix(name, "string"), name == "character":
		return COLOR_SYN_STRING, true
	case name == "comment", name == "spell":
		return COLOR_SYN_COMMENT, true
	case strings.has_prefix(name, "constant"),
	     name == "number",
	     name == "float",
	     name == "boolean":
		return COLOR_SYN_CONSTANT, true
	case name == "attribute", strings.has_prefix(name, "preproc"):
		return COLOR_SYN_ATTRIBUTE, true
	}
	return COLOR_FG, false
}

highlight_update :: proc(b: ^Buffer) {
	language := language_of(b.path)
	if !syntax_ensure(language) {
		b.hl.valid = false
		b.hl.computed = true
		b.hl.rev = b.rev
		return
	}
	s := &g_syntaxes[language]
	if b.hl.computed && b.hl.valid && b.hl.rev == b.rev {
		return
	}

	for len(b.hl.colors) < len(b.lines) {
		append(&b.hl.colors, make([dynamic]tb2.Color))
	}
	for len(b.hl.colors) > len(b.lines) {
		row := pop(&b.hl.colors)
		delete(row)
	}
	for r in 0 ..< len(b.lines) {
		n := len(b.lines[r].text)
		resize(&b.hl.colors[r], n)
		for i in 0 ..< n {
			b.hl.colors[r][i] = COLOR_FG
		}
	}

	snapshot := buffer_snapshot(b)
	defer delete(snapshot)
	tree := ts.parser_parse_string(s.parser, nil, raw_data(snapshot), u32(len(snapshot)))
	if tree == nil {
		b.hl.valid = false
		b.hl.computed = true
		b.hl.rev = b.rev
		return
	}
	defer ts.tree_delete(tree)

	ts.query_cursor_exec(s.cursor, s.query, ts.tree_root_node(tree))
	match: ts.QueryMatch
	for ts.query_cursor_next_match(s.cursor, &match) {
		for i in 0 ..< int(match.capture_count) {
			cap := match.captures[i]
			if int(cap.index) >= len(s.paint) || !s.paint[cap.index] {
				continue
			}
			sp := ts.node_start_point(cap.node)
			ep := ts.node_end_point(cap.node)
			highlight_paint(&b.hl, int(sp.row), int(sp.column), int(ep.row), int(ep.column), s.colors[cap.index])
		}
	}

	b.hl.valid = true
	b.hl.computed = true
	b.hl.rev = b.rev
}

highlight_paint :: proc(hl: ^Highlight, r0, c0, r1, c1: int, color: tb2.Color) {
	for r in r0 ..= r1 {
		if r < 0 || r >= len(hl.colors) {
			continue
		}
		row := &hl.colors[r]
		cs := c0 if r == r0 else 0
		ce := c1 if r == r1 else len(row)
		cs = clamp(cs, 0, len(row))
		ce = clamp(ce, 0, len(row))
		for c in cs ..< ce {
			row[c] = color
		}
	}
}

highlight_colors :: proc(b: ^Buffer, row: int) -> []tb2.Color {
	if !b.hl.valid || row >= len(b.hl.colors) {
		return nil
	}
	return b.hl.colors[row][:]
}

highlight_destroy :: proc(hl: ^Highlight) {
	for &row in hl.colors {
		delete(row)
	}
	delete(hl.colors)
}
