package main

import "core:strings"
import "core:thread"
import "lib:tb2"
import ts "lib:tree_sitter"

HIGHLIGHT_ASYNC_BYTES :: 256 * 1024

Highlight :: struct {
	computed: bool,
	valid:    bool,
	rev:      u64,
	top:      int,
	bot:      int,
	tree:     ^ts.Tree,
	pending:  [dynamic]ts.InputEdit,
	colors:   [dynamic][dynamic]tb2.Color,
	job:      ^HighlightJob,
}

HighlightJob :: struct {
	language: Language,
	snapshot: string,
	edits:    [dynamic]ts.InputEdit,
	old_tree: ^ts.Tree,
	thread:   ^thread.Thread,
	tree:     ^ts.Tree,
}

highlight_record_edit :: proc(hl: ^Highlight, edit: ts.InputEdit) {
	append(&hl.pending, edit)
}

Syntax :: struct {
	tried:      bool,
	ready:      bool,
	parser:     ^ts.Parser,
	query:      ^ts.Query,
	cursor:     ^ts.QueryCursor,
	colors:     [dynamic]tb2.Color,
	paint:      [dynamic]bool,
	inj_query:  ^ts.Query,
	inj_cursor: ^ts.QueryCursor,
	inj_names:  [dynamic]string,
}

@(private = "file")
g_syntaxes: [Language]Syntax

// A language that ships a grammar failed to compile it; the editor drains this into the message line once.
g_syntax_error: string

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
		g_syntax_error = info.name
		return false
	}

	err_off: u32
	err_type: ts.QueryError
	s.query = ts.query_new(lang, raw_data(info.highlights), u32(len(info.highlights)), &err_off, &err_type)
	if s.query == nil {
		g_syntax_error = info.name
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

	// Optional injection query (currently markdown). Failure to compile just
	// disables injection; the host highlights still work.
	if info.injections != nil {
		off: u32
		et: ts.QueryError
		s.inj_query = ts.query_new(lang, raw_data(info.injections), u32(len(info.injections)), &off, &et)
		if s.inj_query != nil {
			s.inj_cursor = ts.query_cursor_new()
			m := ts.query_capture_count(s.inj_query)
			for id in 0 ..< m {
				length: u32
				name_ptr := ts.query_capture_name_for_id(s.inj_query, id, &length)
				append(&s.inj_names, string(name_ptr[:length]))
			}
		}
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
		if s.inj_cursor != nil {
			ts.query_cursor_delete(s.inj_cursor)
		}
		if s.inj_query != nil {
			ts.query_delete(s.inj_query)
		}
		if s.parser != nil {
			ts.parser_delete(s.parser)
		}
		delete(s.colors)
		delete(s.paint)
		delete(s.inj_names)
	}
}

color_attr :: proc(c: tb2.Color, attr: tb2.Color) -> tb2.Color {
	return tb2.Color(u64(c) | u64(attr))
}

COLOR_RGB_MASK :: u64(0x00FF_FFFF)

color_attrs :: proc(c: tb2.Color) -> u64 {
	return u64(c) &~ COLOR_RGB_MASK
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
	// Markdown (block + inline) uses nvim-flavored @text.* capture names.
	case name == "text.title":
		return color_attr(COLOR_SYN_KEYWORD, .Bold), true
	case name == "text.code":
		return COLOR_SYN_CODE, true
	case name == "text.uri", name == "text.reference":
		return COLOR_SYN_TYPE, true
	case name == "text.strong":
		return color_attr(COLOR_SYN_ATTRIBUTE, .Bold), true
	case name == "text.emphasis":
		return color_attr(COLOR_SYN_COMMENT, .Italic), true
	}
	return COLOR_FG, false
}

highlight_update :: proc(b: ^Buffer, top, bot: int) {
	language := b.language
	if !syntax_ensure(language) {
		clear(&b.hl.pending)
		b.hl.valid = false
		b.hl.computed = true
		b.hl.rev = b.rev
		return
	}
	s := &g_syntaxes[language]

	// Adopt a finished background parse. A parse still in flight keeps the last
	// painted colors on screen (stale but colored) rather than blanking them.
	tree_fresh := false
	if b.hl.job != nil {
		if !thread.is_done(b.hl.job.thread) {
			return
		}
		if !highlight_job_adopt(b) {
			b.hl.valid = false
			b.hl.computed = true
			b.hl.rev = b.rev
			return
		}
		tree_fresh = true
	}

	vtop := clamp(top, 0, max(0, len(b.lines) - 1))
	vbot := clamp(bot, 0, max(0, len(b.lines) - 1))

	// Reparse when the retained tree no longer reflects the buffer (no tree yet,
	// or edits have accumulated). Large buffers parse on a background thread and
	// keep showing the previous colors until it lands; small buffers parse inline
	// (no thread overhead, no uncolored flash).
	if b.hl.tree == nil || len(b.hl.pending) > 0 {
		snapshot := buffer_snapshot(b)
		if len(snapshot) >= HIGHLIGHT_ASYNC_BYTES {
			highlight_job_start(b, language, snapshot)
			return
		}
		if !highlight_reparse(b, s, snapshot) {
			return
		}
		tree_fresh = true
	}

	// Requery + repaint only when the tree changed or the viewport moved; a pure
	// re-render at rest is a no-op.
	if !tree_fresh &&
	   b.hl.computed &&
	   b.hl.valid &&
	   b.hl.rev == b.rev &&
	   b.hl.top == vtop &&
	   b.hl.bot == vbot {
		return
	}
	highlight_query_paint(b, s, vtop, vbot)
}

highlight_query_paint :: proc(b: ^Buffer, s: ^Syntax, vtop, vbot: int) {
	for len(b.hl.colors) < len(b.lines) {
		append(&b.hl.colors, make([dynamic]tb2.Color))
	}
	for len(b.hl.colors) > len(b.lines) {
		row := pop(&b.hl.colors)
		delete(row)
	}
	for r in vtop ..= vbot {
		n := len(b.lines[r].text)
		resize(&b.hl.colors[r], n)
		for i in 0 ..< n {
			b.hl.colors[r][i] = COLOR_FG
		}
	}

	ts.query_cursor_set_point_range(s.cursor, {u32(vtop), 0}, {u32(vbot) + 1, 0})
	ts.query_cursor_exec(s.cursor, s.query, ts.tree_root_node(b.hl.tree))
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

	highlight_inject(b, s, vtop, vbot)

	b.hl.valid = true
	b.hl.computed = true
	b.hl.rev = b.rev
	b.hl.top = vtop
	b.hl.bot = vbot
}

// Re-parse embedded languages inside the host tree and paint their colors over
// the just-painted host colors. Concrete for markdown: (inline) nodes get the
// markdown_inline grammar, fenced code blocks get the language named by their
// info string. Injection regions are re-parsed fresh (synchronous, viewport
// -scoped) each paint — cheap because paint only reruns when the tree or viewport
// changed and the regions are small. A grammar without an injection query
// (everything but markdown) returns immediately.
highlight_inject :: proc(b: ^Buffer, s: ^Syntax, vtop, vbot: int) {
	if s.inj_query == nil || b.hl.tree == nil {
		return
	}
	ts.query_cursor_set_point_range(s.inj_cursor, {u32(vtop), 0}, {u32(vbot) + 1, 0})
	ts.query_cursor_exec(s.inj_cursor, s.inj_query, ts.tree_root_node(b.hl.tree))
	match: ts.QueryMatch
	for ts.query_cursor_next_match(s.inj_cursor, &match) {
		content_ok := false
		sr, sc, er, ec: int
		target := Language.Plain
		lang_name := ""
		for i in 0 ..< int(match.capture_count) {
			cap := match.captures[i]
			if int(cap.index) >= len(s.inj_names) {
				continue
			}
			sp := ts.node_start_point(cap.node)
			ep := ts.node_end_point(cap.node)
			switch s.inj_names[cap.index] {
			case "inline":
				sr, sc, er, ec = int(sp.row), int(sp.column), int(ep.row), int(ep.column)
				content_ok = true
				target = .MarkdownInline
			case "content":
				sr, sc, er, ec = int(sp.row), int(sp.column), int(ep.row), int(ep.column)
				content_ok = true
			case "language":
				lang_name = buffer_text_span(b, int(sp.row), int(sp.column), int(ep.row), int(ep.column))
			}
		}
		if !content_ok {
			continue
		}
		if target == .Plain {
			target = language_of_name(lang_name)
		}
		if target == .Plain {
			continue
		}
		highlight_inject_region(b, target, sr, sc, er, ec)
	}
}

highlight_inject_region :: proc(b: ^Buffer, target: Language, sr, sc, er, ec: int) {
	if !syntax_ensure(target) {
		return
	}
	t := &g_syntaxes[target]
	slice := buffer_text_span(b, sr, sc, er, ec)
	if len(slice) == 0 {
		return
	}
	tree := ts.parser_parse_string(t.parser, nil, raw_data(slice), u32(len(slice)))
	if tree == nil {
		return
	}
	defer ts.tree_delete(tree)

	// The target cursor may carry a stale point range from a prior main-buffer
	// paint of this language; widen it so the whole slice is queried.
	ts.query_cursor_set_point_range(t.cursor, {0, 0}, {max(u32), 0})
	ts.query_cursor_exec(t.cursor, t.query, ts.tree_root_node(tree))
	match: ts.QueryMatch
	for ts.query_cursor_next_match(t.cursor, &match) {
		for i in 0 ..< int(match.capture_count) {
			cap := match.captures[i]
			if int(cap.index) >= len(t.paint) || !t.paint[cap.index] {
				continue
			}
			sp := ts.node_start_point(cap.node)
			ep := ts.node_end_point(cap.node)
			r0 := sr + int(sp.row)
			c0 := int(sp.column) + (sc if sp.row == 0 else 0)
			r1 := sr + int(ep.row)
			c1 := int(ep.column) + (sc if ep.row == 0 else 0)
			highlight_paint(&b.hl, r0, c0, r1, c1, t.colors[cap.index])
		}
	}
}

// Concatenate the buffer bytes spanning [sr:sc .. er:ec], newline-joined — the
// source text of an injection region, for a one-shot sub-parse. Temp-allocated.
buffer_text_span :: proc(b: ^Buffer, sr, sc, er, ec: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in sr ..= er {
		if r < 0 || r >= len(b.lines) {
			continue
		}
		line := b.lines[r].text[:]
		lo := sc if r == sr else 0
		hi := ec if r == er else len(line)
		lo = clamp(lo, 0, len(line))
		hi = clamp(hi, 0, len(line))
		if hi > lo {
			strings.write_bytes(&sb, line[lo:hi])
		}
		if r < er {
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}

// Reparse the buffer on the main thread, reusing the retained tree when present
// (incremental). Takes ownership of `snapshot`. Returns false if the parse
// failed, having marked the buffer's highlight invalid so the caller aborts.
highlight_reparse :: proc(b: ^Buffer, s: ^Syntax, snapshot: string) -> bool {
	defer delete(snapshot)
	if b.hl.tree != nil {
		for &edit in b.hl.pending {
			ts.tree_edit(b.hl.tree, &edit)
		}
	}
	clear(&b.hl.pending)

	tree := ts.parser_parse_string(s.parser, b.hl.tree, raw_data(snapshot), u32(len(snapshot)))
	if tree == nil {
		if b.hl.tree != nil {
			ts.tree_delete(b.hl.tree)
			b.hl.tree = nil
		}
		b.hl.valid = false
		b.hl.computed = true
		b.hl.rev = b.rev
		return false
	}
	if b.hl.tree != nil && b.hl.tree != tree {
		ts.tree_delete(b.hl.tree)
	}
	b.hl.tree = tree
	return true
}

// Parses of large buffers run on a background thread so input stays responsive.
// A cold parse (no retained tree) shows plain text until adopted; an incremental
// reparse keeps the previous colors. The job owns `snapshot` and a private
// `old_tree` copy (freed on adopt/teardown) and parses with its own parser, so it
// shares no mutable tree-sitter state with the main thread — the copy makes
// `tree_edit`/`parse` on the worker copy-on-write against the retained tree.
highlight_job_start :: proc(b: ^Buffer, language: Language, snapshot: string) {
	job := new(HighlightJob)
	job.language = language
	job.snapshot = snapshot
	if b.hl.tree != nil {
		job.old_tree = ts.tree_copy(b.hl.tree)
		for edit in b.hl.pending {
			append(&job.edits, edit)
		}
	}
	clear(&b.hl.pending)
	job.thread = thread.create(highlight_job_run)
	job.thread.data = job
	b.hl.job = job
	thread.start(job.thread)
}

highlight_job_run :: proc(t: ^thread.Thread) {
	job := cast(^HighlightJob)t.data
	info := LANGUAGES[job.language]
	if info.grammar == nil {
		return
	}
	parser := ts.parser_new()
	defer ts.parser_delete(parser)
	if !ts.parser_set_language(parser, info.grammar()) {
		return
	}
	if job.old_tree != nil {
		for &edit in job.edits {
			ts.tree_edit(job.old_tree, &edit)
		}
	}
	job.tree = ts.parser_parse_string(parser, job.old_tree, raw_data(job.snapshot), u32(len(job.snapshot)))
	if job.old_tree != nil {
		ts.tree_delete(job.old_tree)
		job.old_tree = nil
	}
}

// Take a finished job's tree (called only when the thread is done). Returns
// false if the background parse failed to produce a tree.
highlight_job_adopt :: proc(b: ^Buffer) -> bool {
	job := b.hl.job
	thread.destroy(job.thread)
	tree := job.tree
	delete(job.snapshot)
	delete(job.edits)
	if job.old_tree != nil {
		ts.tree_delete(job.old_tree)
	}
	free(job)
	b.hl.job = nil
	if tree == nil {
		return false
	}
	if b.hl.tree != nil {
		ts.tree_delete(b.hl.tree)
	}
	b.hl.tree = tree
	return true
}

highlight_busy :: proc(b: ^Buffer) -> bool {
	return b.hl.job != nil
}

highlight_ready :: proc(b: ^Buffer) -> bool {
	return b.hl.job != nil && thread.is_done(b.hl.job.thread)
}

highlight_paint :: proc(hl: ^Highlight, r0, c0, r1, c1: int, color: tb2.Color) {
	highlight_paint_rows(hl.colors[:], r0, c0, r1, c1, color)
}

highlight_paint_rows :: proc(rows: [][dynamic]tb2.Color, r0, c0, r1, c1: int, color: tb2.Color) {
	for r in r0 ..= r1 {
		if r < 0 || r >= len(rows) {
			continue
		}
		row := &rows[r]
		cs := c0 if r == r0 else 0
		ce := c1 if r == r1 else len(row)
		cs = clamp(cs, 0, len(row))
		ce = clamp(ce, 0, len(row))
		for c in cs ..< ce {
			row[c] = color
		}
	}
}

// One-shot synchronous highlight of a small standalone snippet (preview panes).
// Fills `out` with one color row per input line, sized to the line's byte length,
// defaulting to COLOR_FG. Parses the whole snippet fresh — no retained tree, no
// injection — so it is only appropriate for a handful of lines.
highlight_lines :: proc(language: Language, lines: []string, out: ^[dynamic][dynamic]tb2.Color) {
	for &row in out {
		delete(row)
	}
	clear(out)
	for line in lines {
		row := make([dynamic]tb2.Color)
		resize(&row, len(line))
		for i in 0 ..< len(line) {
			row[i] = COLOR_FG
		}
		append(out, row)
	}
	if !syntax_ensure(language) {
		return
	}
	s := &g_syntaxes[language]

	sb := strings.builder_make(context.temp_allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, line)
	}
	src := strings.to_string(sb)
	tree := ts.parser_parse_string(s.parser, nil, raw_data(src), u32(len(src)))
	if tree == nil {
		return
	}
	defer ts.tree_delete(tree)

	ts.query_cursor_set_point_range(s.cursor, {0, 0}, {max(u32), 0})
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
			highlight_paint_rows(out[:], int(sp.row), int(sp.column), int(ep.row), int(ep.column), s.colors[cap.index])
		}
	}
}

highlight_lines_destroy :: proc(out: ^[dynamic][dynamic]tb2.Color) {
	for &row in out {
		delete(row)
	}
	delete(out^)
}

highlight_colors :: proc(b: ^Buffer, row: int) -> []tb2.Color {
	if !b.hl.valid || row >= len(b.hl.colors) {
		return nil
	}
	return b.hl.colors[row][:]
}

highlight_destroy :: proc(hl: ^Highlight) {
	if hl.job != nil {
		thread.destroy(hl.job.thread)
		if hl.job.tree != nil {
			ts.tree_delete(hl.job.tree)
		}
		if hl.job.old_tree != nil {
			ts.tree_delete(hl.job.old_tree)
		}
		delete(hl.job.snapshot)
		delete(hl.job.edits)
		free(hl.job)
		hl.job = nil
	}
	if hl.tree != nil {
		ts.tree_delete(hl.tree)
		hl.tree = nil
	}
	delete(hl.pending)
	for &row in hl.colors {
		delete(row)
	}
	delete(hl.colors)
}
