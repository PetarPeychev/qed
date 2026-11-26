package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import cm "lib:cmark_gfm"
import "lib:tb2"

md_find :: proc(doc: ^MdDoc, text: string) -> (col, row: int, ok: bool) {
	for _, r in doc.rows {
		line := md_row_text(doc, r)
		if at := strings.index(line, text); at >= 0 {
			return md_text_width(line[:at]), r, true
		}
	}
	return 0, 0, false
}

md_cell_at :: proc(doc: ^MdDoc, text: string) -> MdCell {
	col, row, ok := md_find(doc, text)
	if !ok {
		return {}
	}
	return doc.rows[row][col]
}

md_attr :: proc(c: MdCell, attr: tb2.Color) -> bool {
	return u64(c.fg) & u64(attr) != 0
}

md_rows :: proc(doc: ^MdDoc) -> []string {
	out := make([]string, len(doc.rows), context.temp_allocator)
	for &line, i in out {
		line = md_row_text(doc, i)
	}
	return out
}

md_expect_rows :: proc(t: ^testing.T, doc: ^MdDoc, want: []string, loc := #caller_location) {
	got := md_rows(doc)
	if len(got) != len(want) {
		testing.expectf(t, false, "rows: got %v, want %v", got, want, loc = loc)
		return
	}
	for w, i in want {
		testing.expectf(t, got[i] == w, "row %d: got %q, want %q", i, got[i], w, loc = loc)
	}
}

@(test)
test_md_inline_styles :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("a **bold** and `code` and *slanted* ~~gone~~ end", 80, .Plain)
	md_expect_rows(t, doc, {"a bold and code and slanted gone end"})
	testing.expect(t, md_attr(md_cell_at(doc, "bold"), .Bold), "strong is bold")
	testing.expect(t, md_attr(md_cell_at(doc, "slanted"), .Italic), "emphasis is italic")
	testing.expect(t, md_attr(md_cell_at(doc, "gone"), .Strikeout), "strikethrough")
	st := md_style()
	code := md_cell_at(doc, "code")
	testing.expect_value(t, u64(code.fg) & COLOR_RGB_MASK, u64(st.code) & COLOR_RGB_MASK)
	testing.expect_value(t, code.bg, st.code_bg)
	testing.expect_value(t, md_cell_at(doc, "end").bg, tb2.Color(0))
}

@(test)
test_md_headings_and_ids :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("# Big Title\n\n## Sub `code` *x*\n\n### Small\n\n## Sub code x\n\ntext", 30, .Plain)
	rows := md_rows(doc)
	testing.expect_value(t, rows[0], "Big Title")
	testing.expect_value(t, rows[1], strings.repeat("━", 30, context.temp_allocator))
	testing.expect_value(t, rows[3], "Sub code x")
	testing.expect_value(t, rows[4], strings.repeat("─", 30, context.temp_allocator))
	testing.expect_value(t, rows[6], "Small")
	testing.expect_value(t, rows[7], "")
	testing.expect(t, md_attr(md_cell_at(doc, "Big"), .Bold), "headings are bold")
	testing.expect_value(t, doc.anchors["big-title"], 0)
	testing.expect_value(t, doc.anchors["sub-code-x"], 3)
	testing.expect_value(t, doc.anchors["small"], 6)
	testing.expect_value(t, doc.anchors["sub-code-x-1"], 8)
	testing.expect_value(t, doc.src[doc.anchors["small"]], 4)
}

@(test)
test_md_lists :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("- one\n- two\n  - nested\n    - deeper\n\n1. first\n2. second\n\n- [ ] todo\n- [x] done", 40, .Plain)
	md_expect_rows(t, doc, {"• one", "• two", "  ◦ nested", "    ▪ deeper", "", "1. first", "2. second", "", "  ☐ todo", "  ☑ done"})
	testing.expect_value(t, u64(md_cell_at(doc, "•").fg) & COLOR_RGB_MASK, u64(md_style().bullet) & COLOR_RGB_MASK)
	testing.expect_value(t, u64(md_cell_at(doc, "☑").fg) & COLOR_RGB_MASK, u64(md_style().checked) & COLOR_RGB_MASK)
	wrapped := md_render("- a long item that has to wrap", 14, .Plain)
	md_expect_rows(t, wrapped, {"• a long item", "  that has to", "  wrap"})
}

@(test)
test_md_quotes_and_alerts :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("> quoted\n> > nested\n\n> [!NOTE]\n> Useful.\n\n> [!warning] \n> Careful\n> more\n\n> [!NOPE]\n> plain", 40, .Plain)
	md_expect_rows(t, doc, {"│ quoted", "│", "│ │ nested", "", "│ ⓘ Note", "│ Useful.", "", "│ ⚠ Warning", "│ Careful more", "", "│ [!NOPE] plain"})
	note := md_cell_at(doc, "ⓘ")
	testing.expect_value(t, u64(note.fg) & COLOR_RGB_MASK, u64(COLOR_DIAG_INFO_FG) & COLOR_RGB_MASK)
	_, row, _ := md_find(doc, "ⓘ")
	testing.expect_value(t, u64(doc.rows[row][0].fg) & COLOR_RGB_MASK, u64(COLOR_DIAG_INFO_FG) & COLOR_RGB_MASK)
	testing.expect(t, md_attr(note, .Bold), "an alert title is bold")
	_, warn, _ := md_find(doc, "Careful")
	testing.expect_value(t, u64(doc.rows[warn][0].fg) & COLOR_RGB_MASK, u64(COLOR_DIAG_WARN_FG) & COLOR_RGB_MASK)
}

@(test)
test_md_table :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("| Key | Action |\n|-----|:------:|\n| a | b |\n| long | 😀 |", 40, .Plain)
	md_expect_rows(t, doc, {
		"┌──────┬────────┐",
		"│ Key  │ Action │",
		"├──────┼────────┤",
		"│ a    │    b   │",
		"├──────┼────────┤",
		"│ long │   😀   │",
		"└──────┴────────┘",
	})
	testing.expect(t, md_attr(md_cell_at(doc, "Key"), .Bold), "header cells are bold")
	testing.expect(t, !md_attr(md_cell_at(doc, "long"), .Bold), "body cells are not")
	_, row, _ := md_find(doc, "long")
	testing.expect_value(t, doc.src[row], 3)
	col, emoji, _ := md_find(doc, "😀")
	testing.expect(t, doc.rows[emoji][col + 1].tail, "a wide glyph covers two cells")
}

@(test)
test_md_code_block :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("para\n\n```python\nx = 1\n\ndef f():\n\treturn 'long string that wraps around'\n```\n\nafter", 30, .Plain)
	rows := md_rows(doc)
	testing.expect_value(t, rows[2], " x = 1")
	testing.expect_value(t, rows[3], "")
	testing.expect_value(t, rows[4], " def f():")
	testing.expect(t, strings.has_prefix(rows[5], "     return"), "a tab expands to the next stop")
	testing.expect_value(t, doc.src[2], 3)
	testing.expect_value(t, doc.src[3], 4)
	testing.expect_value(t, doc.src[4], 5)
	testing.expect_value(t, doc.src[5], 6)
	testing.expect_value(t, doc.src[6], 6)
	st := md_style()
	for r in 2 ..= 6 {
		testing.expectf(t, len(doc.rows[r]) == 30 && doc.rows[r][29].bg == st.code_bg, "row %d: the band reaches the edge", r)
	}
	def := md_cell_at(doc, "def")
	ret := md_cell_at(doc, "'long")
	testing.expect(t, def.fg != ret.fg, "keywords and strings get their own colors")
	testing.expect_value(t, rows[len(rows) - 1], "after")
}

@(test)
test_md_details :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "<details>\n<summary>More</summary>\n\nHidden body\n\n</details>\n\n<details open><summary>Open</summary>\n\nShown\n\n</details>"
	doc := md_render(src, 40, .Plain)
	md_expect_rows(t, doc, {"▶ More", "", "▼ Open", "", "Shown"})
	testing.expect_value(t, len(doc.summaries), 2)
	index, ok := md_summary_at(doc, 3, 0)
	testing.expect(t, ok && index == 0, "the first summary row toggles the first details")
	_, ok = md_summary_at(doc, 3, 1)
	testing.expect(t, !ok, "the gap below is not a summary")

	toggled := md_render(src, 40, .Plain, "", {0, 1})
	md_expect_rows(t, toggled, {"▼ More", "", "Hidden body", "", "▶ Open"})
}

@(test)
test_md_links_and_footnotes :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("See [the docs](docs/x.md) and <https://example.com>, ref[^1].\n\n[^1]: The note.", 24, .Plain)
	col, row, _ := md_find(doc, "the docs")
	testing.expect_value(t, md_link_at(doc, col, row), "docs/x.md")
	testing.expect_value(t, md_link_at(doc, col + 7, row), "docs/x.md")
	testing.expect_value(t, md_link_at(doc, col - 1, row), "")
	testing.expect(t, md_attr(doc.rows[row][col], .Underline), "links are underlined")
	ucol, urow, _ := md_find(doc, "example")
	testing.expect_value(t, md_link_at(doc, ucol, urow), "https://example.com")
	fcol, frow, _ := md_find(doc, "[1]")
	testing.expect_value(t, md_link_at(doc, fcol + 1, frow), "#fn-1")
	note := doc.anchors["fn-1"]
	testing.expect(t, strings.contains(md_row_text(doc, note), "The note."), "the footnote anchor is its item")
}

@(test)
test_md_source_rows :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("# Title\n\nfirst para that wraps over more than one row\nsecond source line\n\n- item\n- item two\n\n> quote", 20, .Plain)
	rows := md_rows(doc)
	for r in 0 ..< len(rows) {
		if r > 0 {
			testing.expectf(t, doc.src[r] >= doc.src[r - 1], "source rows never go back: %v", doc.src)
		}
	}
	_, para, _ := md_find(doc, "first")
	_, more, _ := md_find(doc, "second")
	testing.expect_value(t, doc.src[para], 2)
	testing.expect_value(t, doc.src[more], 2)
	_, item2, _ := md_find(doc, "item two")
	testing.expect_value(t, doc.src[item2], 6)
	_, quote, _ := md_find(doc, "quote")
	testing.expect_value(t, doc.src[quote], 8)
}

@(test)
test_md_front_matter_and_html :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	fm := md_render("---\ntitle: x\n---\n# Doc", 20, .Plain)
	testing.expect_value(t, md_rows(fm)[0], " title: x")
	testing.expect_value(t, fm.anchors["doc"], 2)
	html := md_render("<p align=\"center\">centered</p>\n\n<!-- hidden -->\n\nVec<T> & <kbd>Ctrl</kbd>", 20, .Plain)
	md_expect_rows(t, html, {"      centered", "", "Vec & Ctrl"})
}

@(test)
test_md_escape_plain :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "def f(x: *int) -> List[int]\n  indented # not a heading\n- not a list\n\nnext para &amp; <b>"
	md_expect_rows(t, md_render(md_escape_plain(src), 80, .Plain), {"def f(x: *int) -> List[int]", "  indented # not a heading", "- not a list", "", "next para &amp; <b>"})
}

@(test)
test_md_hover_width :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("```c\nint add(int a)\n```\n\n---\n\nshort", 60, .C)
	testing.expect_value(t, doc.width, len(" int add(int a)"))
	table := md_render("| a | b |\n|---|---|\n| 1 | 2 |", 60, .Plain)
	testing.expect_value(t, table.width, md_text_width("┌───┬───┐"))
}

@(test)
test_md_narrow_and_hostile :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 200 {
		fmt.sbprintf(&sb, "%s- [x](#a) `c` **b** | t |\n", strings.repeat("> ", i % 7, context.temp_allocator))
	}
	strings.write_string(&sb, strings.repeat("[", 5000, context.temp_allocator))
	strings.write_string(&sb, "\n| a | b |\n|---|---|\n| verylongwordwithoutspaces | x |\n")
	for w in ([]int{1, 5, 12}) {
		doc := md_render(strings.to_string(sb), w, .Plain)
		for row in doc.rows {
			testing.expectf(t, len(row) <= w, "width %d: a row of %d cells", w, len(row))
		}
	}
	empty := md_render("", 20, .Plain)
	testing.expect_value(t, len(empty.rows), 0)
}

@(test)
test_md_pieces_reuse :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 400 {
		fmt.sbprintf(&sb, "## Part %d\n\nparagraph %d with a [link](#part-%d)\n\n", i, i, (i + 1) % 400)
	}
	src := strings.to_string(sb)
	doc := md_render(src, 60, .Plain)
	testing.expect_value(t, len(doc.rows), 400 * 5 - 1)
	_, row, _ := md_find(doc, "paragraph 399 with")
	testing.expect_value(t, md_link_at(doc, 21, row), "#part-0")
	testing.expect_value(t, doc.anchors["part-399"], 399 * 5)
	testing.expect_value(t, doc.src[doc.anchors["part-399"]], 399 * 4)
	for r in 1 ..< len(doc.src) {
		testing.expect(t, doc.src[r] >= doc.src[r - 1], "source rows never go back across pieces")
	}

	context.allocator = context.temp_allocator
	layout_job :: proc(src: string, prev: []^MdChunk) -> MdJob {
		job := MdJob{input = md_input_make(src, "", .Plain, 60, nil), prev = prev, code_allocator = context.temp_allocator}
		md_layout(&job)
		md_input_free(&job.input)
		return job
	}
	fresh_pieces :: proc(job: MdJob, prev: []^MdChunk) -> int {
		fresh := 0
		for chunk in job.chunks {
			if !slice.contains(prev, chunk) {
				fresh += 1
			}
		}
		return fresh
	}
	first := layout_job(src, nil)
	testing.expect(t, len(first.chunks) > 4, "a long document is laid out in pieces")
	edited, _ := strings.replace(src, "paragraph 200 with", "paragraph 200 now with", 1, context.temp_allocator)
	second := layout_job(edited, first.chunks)
	testing.expect_value(t, len(second.chunks), len(first.chunks))
	testing.expect_value(t, fresh_pieces(second, first.chunks), 1)
	inserted, _ := strings.replace(src, "paragraph 3 with", "a new line\n\nparagraph 3 with", 1, context.temp_allocator)
	third := layout_job(inserted, first.chunks)
	testing.expectf(t, fresh_pieces(third, first.chunks) <= 2, "lines added above move no later piece: %d laid out again", fresh_pieces(third, first.chunks))
	doc_inserted := md_doc_assemble(third.pieces, third.chunks)
	testing.expect_value(t, doc_inserted.src[doc_inserted.anchors["part-399"]], 399 * 4 + 2)
	for job in ([]MdJob{second, third}) {
		for chunk in job.chunks {
			if !slice.contains(first.chunks, chunk) {
				md_chunk_free(chunk)
			}
		}
	}
	for chunk in first.chunks {
		md_chunk_free(chunk)
	}
}

md_doc_text :: proc(doc: ^MdDoc) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for _, row in doc.rows {
		strings.write_string(&sb, md_row_text(doc, row))
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

@(test)
test_md_parse_on_two_threads :: proc(t: ^testing.T) {
	cm.init()
	Parse :: struct {
		text, want: string,
		misses:     int,
	}
	run :: proc(parse: ^Parse) {
		for _ in 0 ..< 300 {
			html := cm.to_html(raw_data(parse.text), len(parse.text), 1, 0, nil, nil)
			if !strings.contains(string(html), parse.want) {
				parse.misses += 1
			}
			cm.free(html)
		}
	}
	strike := Parse{text = "some ~~struck~~ words and ~~more~~", want = "<del>struck</del>"}
	link := Parse{text = "see www.example.com and https://example.org now", want = `<a href="http://www.example.com">`}
	threads := [2]^thread.Thread{thread.create_and_start_with_poly_data(&strike, run), thread.create_and_start_with_poly_data(&link, run)}
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	testing.expect_value(t, strike.misses, 0)
	testing.expect_value(t, link.misses, 0)
}

@(test)
test_md_hostile_height :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("before\n\n<div style=\"height: 100000000px\">tall</div>\n\nafter", 40, .Plain)
	testing.expectf(t, len(doc.rows) <= MD_PIECE_ROWS_MAX + 1, "a hostile height is clamped: %d rows", len(doc.rows))
	testing.expect_value(t, md_row_text(doc, 0), "before")
}

@(test)
e2e_md_repeated_blocks_share_no_piece :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 300 {
		strings.write_string(&sb, "the same paragraph again, long enough to count for something\n\n")
	}
	ft_lua(&e.ed, fmt.tprintf(`
		_G.md_repeat = %q
		_G.md_handle = qed.ui.mount("pane", qed.ui.box{{float = "screen", width = 60, height = 20,
			qed.ui.scroll{{id = "repeat_scroll", qed.markdown.parse(md_repeat, {{id = "repeat_md"}})}}}})
		return 0`, strings.to_string(sb)))
	e2e_render(&e)
	md := e.ed.ui.markdowns["#fthelper/repeat_md"]
	testing.expect(t, md != nil && len(md.chunks) > 1, "repeated blocks still make pieces")
	if md != nil {
		testing.expect(t, len(md.chunks) < 100, "but not one per block")
		for chunk, k in md.chunks {
			testing.expect(t, !slice.contains(md.chunks[k + 1:], chunk), "every piece is its own")
		}
	}
	ft_lua(&e.ed, `_G.md_handle:update(qed.ui.box{float = "screen", width = 60, height = 20,
		qed.ui.scroll{id = "repeat_scroll", qed.markdown.parse(md_repeat .. "edited\n", {id = "repeat_md"})}}) return 0`)
	e2e_render(&e)
	e2e_resize(&e, 70, 24)
	e2e_render(&e)
	ft_lua(&e.ed, `_G.md_handle:unmount() return 0`)
	e2e_render(&e)
	testing.expect(t, e.ed.ui.markdowns["#fthelper/repeat_md"] == nil, "closed")
}

@(test)
e2e_md_code_colors_follow_the_theme :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	saved := strings.clone(THEME, context.temp_allocator)
	defer editor_theme_set(&e.ed, saved, false)
	md_job := proc(source: string, prev_code: map[string][]string) -> MdJob {
		context.allocator = context.temp_allocator
		job := MdJob{input = md_input_make(source, "", .Plain, 40, nil), code_allocator = context.temp_allocator, allocator = context.temp_allocator, prev_code = prev_code}
		md_layout(&job)
		md_input_free(&job.input)
		return job
	}
	source := "```python\ndef f():\n    return 1\n```"
	color_of :: proc(job: ^MdJob) -> string {
		html := job.pieces[0].html
		at := strings.index(html, "def")
		start := strings.last_index(html[:at], "color: ")
		return html[start:start + len("color: #000000")]
	}
	first := md_job(source, nil)
	editor_theme_set(&e.ed, "solarized-light", false)
	second := md_job(source, first.code)
	testing.expect(t, color_of(&first) != color_of(&second), "a retheme recolors cached code")
}

@(test)
test_md_forced_cut_keeps_details_whole :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<details open>\n<summary>Big</summary>\n<div>\n\n")
	for i in 0 ..< 3000 {
		fmt.sbprintf(&sb, "```python\nx_%d = 'value %d' + str(%d)\n```\n\n", i, i, i)
	}
	strings.write_string(&sb, "</div>\n</details>\n\nafter")
	context.allocator = context.temp_allocator
	job := MdJob{input = md_input_make(strings.to_string(sb), "", .Plain, 60, nil), code_allocator = context.temp_allocator, allocator = context.temp_allocator}
	md_layout(&job)
	md_input_free(&job.input)
	testing.expect(t, len(job.pieces) > 1, "an element left open still lets the document be cut")
	for piece, k in job.pieces[:len(job.pieces) - 1] {
		testing.expectf(t, strings.has_suffix(strings.trim_space(piece.html), "</div></details>"), "piece %d closes what is open", k)
		testing.expectf(t, strings.has_prefix(job.pieces[k + 1].html, "<details open "), "piece %d reopens it", k + 1)
	}
	doc := md_doc_assemble(job.pieces, job.chunks)
	_, row, found := md_find(doc, "x_2999 = ")
	testing.expect(t, found, "the last block shows inside the open details")
	_, after, _ := md_find(doc, "after")
	testing.expect(t, after > row, "and the text after it follows")
}

@(test)
test_md_forged_piece_marker :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	doc := md_render("first\n\n<!--qed-piece 0-->\n\n<!--qed-piece 0 0-->\n\nsecond\n\n<!--qed-piece ffffffff 999999-->\n\nthird", 30, .Plain)
	testing.expect(t, strings.contains(md_doc_text(doc), "third"), "a marker written in the source is only a comment")
}
