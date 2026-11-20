package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "lib:tb2"

md_span_fg :: proc(lines: []MdLine, text: string) -> (tb2.Color, bool) {
	for line in lines {
		for s in line.spans {
			if s.text == text {
				return s.fg, true
			}
		}
	}
	return {}, false
}

md_has_bold :: proc(fg: tb2.Color) -> bool {
	return u64(fg) & u64(tb2.Color.Bold) != 0
}

md_has_italic :: proc(fg: tb2.Color) -> bool {
	return u64(fg) & u64(tb2.Color.Italic) != 0
}

md_all_text :: proc(lines: []MdLine) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, md_line_text(line))
	}
	return strings.to_string(sb)
}

@(test)
test_md_marker_stripping :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("a **bold** and `code` and *slanted* end", 200, .Plain)
	joined := md_all_text(lines)
	testing.expect(t, !strings.contains(joined, "*"), "asterisks stripped")
	testing.expect(t, !strings.contains(joined, "`"), "backticks stripped")
	testing.expect(t, strings.contains(joined, "bold"), "bold word kept")
	testing.expect(t, strings.contains(joined, "code"), "code word kept")

	bfg, bok := md_span_fg(lines, "bold")
	testing.expect(t, bok && md_has_bold(bfg), "bold span has bold attr")
	ifg, iok := md_span_fg(lines, "slanted")
	testing.expect(t, iok && md_has_italic(ifg), "italic span has italic attr")
	cfg, cok := md_span_fg(lines, "code")
	testing.expect(t, cok && u64(cfg) == u64(COLOR_SYN_CODE), "code span uses code color")
}

@(test)
test_md_snake_case_survives :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("call some_long_name here", 200, .Plain)
	testing.expect(t, strings.contains(md_all_text(lines), "some_long_name"), "underscores in identifier kept")
}

@(test)
test_md_header :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("## Big Title ##", 200, .Plain)
	testing.expect_value(t, len(lines), 2)
	fg, ok := md_span_fg(lines, "Big Title")
	testing.expect(t, ok, "header text stripped of #")
	testing.expect(t, md_has_bold(fg), "header is bold")
	want, _ := syntax_capture_color("markdown", "text.title")
	testing.expect_value(t, u64(fg) & COLOR_RGB_MASK, u64(want) & COLOR_RGB_MASK)
	testing.expect_value(t, lines[1].fill, '─')
}

@(test)
test_md_rule :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("above\n\n---\n\nbelow", 200, .Plain)
	found := false
	for line in lines {
		if line.fill == '─' {
			found = true
		}
	}
	testing.expect(t, found, "--- becomes a rule line")
	testing.expect(t, !strings.contains(md_all_text(lines), "---"), "dashes not in text")
}

@(test)
test_md_fence_language :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	testing.expect_value(t, md_fence_language("python", .Plain), Language.Python)
	testing.expect_value(t, md_fence_language("ts foo", .Plain), Language.TypeScript)
	testing.expect_value(t, md_fence_language("", .Go), Language.Go)
	testing.expect_value(t, md_fence_language("nonsense", .Rust), Language.Rust)
}

@(test)
test_md_fence_stripped :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("```python\nx = 1\ny = 2\n```", 200, .Plain)
	joined := md_all_text(lines)
	testing.expect(t, !strings.contains(joined, "`"), "fence backticks dropped")
	testing.expect(t, !strings.contains(joined, "python"), "info string dropped")
	testing.expect(t, strings.contains(joined, "x = 1"), "code content kept")
	testing.expect(t, strings.contains(joined, "y = 2"), "code content kept")
}

@(test)
test_md_wrap :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("the quick brown fox jumps over the lazy dog", 12, .Plain)
	testing.expect(t, len(lines) > 1, "long line wraps")
	for line in lines {
		testing.expect(t, md_line_width(line) <= 12, "each visual line fits width")
	}
	// words survive the wrap intact
	joined := strings.join(strings.fields(md_all_text(lines), context.temp_allocator), " ", context.temp_allocator)
	testing.expect_value(t, joined, "the quick brown fox jumps over the lazy dog")
}

@(test)
test_md_reflow :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("  two-space\nindent  \nhard\\\nbreak", 200, .Plain)
	testing.expect_value(t, md_all_text(lines), "two-space indent\nhard\nbreak")
}

@(test)
test_md_indented_code_block :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "Example:\n\n\timport \"core:fmt\"\n\n\tmain :: proc() {\n\t\tx := 1\n\t}\n\nAfter"
	lines := md_render(src, 200, .Plain)
	joined := md_all_text(lines)
	testing.expect(t, strings.contains(joined, "\n import \"core:fmt\""), "code content kept, one indent level stripped")
	pad := strings.repeat(" ", TAB_WIDTH, context.temp_allocator)
	testing.expect(t, strings.contains(joined, fmt.tprintf("\n %sx := 1", pad)), "nested indentation preserved")
	testing.expect(t, strings.contains(joined, "\nAfter"), "prose resumes after the block")

	lit := md_render("para\n\n\t**not bold** `x`", 200, .Plain)
	testing.expect(t, strings.contains(md_all_text(lit), "**not bold** `x`"), "no inline processing inside indented code")
}

@(test)
test_md_tab_expansion :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("```\n\tx = 1\na\tb\n```", 200, .Plain)
	testing.expect_value(t, len(lines), 2)
	for line in lines {
		for s in line.spans {
			testing.expect(t, !strings.contains(s.text, "\t"), "no tab rune survives into any span")
		}
	}
	pad := strings.repeat(" ", TAB_WIDTH, context.temp_allocator)
	testing.expect_value(t, md_line_text(lines[0]), fmt.tprintf(" %sx = 1", pad))
	gap := strings.repeat(" ", TAB_WIDTH - 1, context.temp_allocator)
	testing.expect_value(t, md_line_text(lines[1]), fmt.tprintf(" a%sb", gap))
	testing.expect_value(t, md_line_width(lines[1]), TAB_WIDTH + 2)

	prose := md_render("p\tq", 200, .Plain)
	testing.expect_value(t, len(prose), 1)
	testing.expect_value(t, md_line_text(prose[0]), fmt.tprintf("p%sq", gap))
	testing.expect_value(t, md_line_width(prose[0]), TAB_WIDTH + 1)
}

@(test)
test_md_blank_collapse :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("a\n\n\n\nb", 200, .Plain)
	blanks := 0
	for line in lines {
		if line.fill == 0 && len(line.spans) == 0 {
			blanks += 1
		}
	}
	testing.expect_value(t, blanks, 1)
	testing.expect_value(t, len(lines), 3)
}

md_lines_fit :: proc(t: ^testing.T, lines: []MdLine, width: int, what: string) {
	for line in lines {
		testing.expectf(t, md_line_width(line) <= width, "%s: %q is wider than %d", what, md_line_text(line), width)
	}
}

md_texts :: proc(lines: []MdLine) -> []string {
	out := make([]string, len(lines), context.temp_allocator)
	for line, i in lines {
		out[i] = md_line_text(line)
	}
	return out
}

md_expect_texts :: proc(t: ^testing.T, texts, want: []string, loc := #caller_location) {
	testing.expect_value(t, len(texts), len(want), loc)
	for w, i in want {
		if i < len(texts) {
			testing.expect_value(t, texts[i], w, loc)
		}
	}
}

slice_has :: proc(xs: []string, s: string) -> bool {
	for x in xs {
		if x == s {
			return true
		}
	}
	return false
}

@(test)
test_md_heading_levels :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("# One\n\n### Three\n\nSetext\n======\n\ntext **bold**", 40, .Plain)
	texts := md_texts(lines)
	testing.expect_value(t, texts[0], "One")
	testing.expect_value(t, lines[1].fill, '━')
	testing.expect_value(t, texts[3], "Three")
	testing.expect_value(t, lines[4].fill, rune(0))
	testing.expect_value(t, texts[5], "Setext")
	testing.expect_value(t, lines[6].fill, '━')
	head, _ := md_span_fg(lines, "Three")
	bold, _ := md_span_fg(lines, "bold")
	testing.expect(t, md_has_bold(head) && md_has_bold(bold), "both bold")
	testing.expect(t, u64(head) & COLOR_RGB_MASK != u64(bold) & COLOR_RGB_MASK, "a heading and bold text differ in color")
}

@(test)
test_md_inline_styles :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("~~gone~~ ***both*** 2 * 3 * 4 a_b_c \\*lit\\* &amp; &lt;x&gt;", 200, .Plain)
	testing.expect_value(t, md_all_text(lines), "gone both 2 * 3 * 4 a_b_c *lit* & <x>")
	g, _ := md_span_fg(lines, "gone")
	testing.expect(t, u64(g) & u64(tb2.Color.Strikeout) != 0, "strikethrough")
	b, _ := md_span_fg(lines, "both")
	testing.expect(t, md_has_bold(b) && md_has_italic(b), "bold italic")
	code := md_render("x `a|b` y", 200, .Plain)
	found := false
	for s in code[0].spans {
		if s.text == "a|b" {
			found = true
			testing.expect(t, u64(s.bg) != 0, "inline code has the code background")
		}
	}
	testing.expect(t, found, "inline code span")
}

@(test)
test_md_lists :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("- a\n- b\n  - c\n    - d\n\n1. x\n2. y\n\n- [ ] todo\n- [x] done", 40, .Plain)
	md_expect_texts(t, md_texts(lines), {"• a", "• b", "  ◦ c", "    ▪ d", "", "1. x", "2. y", "", "☐ todo", "☑ done"})
	ten := md_render("9. nine\n10. ten", 40, .Plain)
	md_expect_texts(t, md_texts(ten), {" 9. nine", "10. ten"})
}

@(test)
test_md_list_hanging_indent :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("- **Editing:** one two three\n  four five six seven\n- next", 16, .Plain)
	texts := md_texts(lines)
	testing.expect_value(t, texts[0], "• Editing: one")
	for s in texts[1:len(texts) - 1] {
		testing.expectf(t, strings.has_prefix(s, "  ") && s[2] != ' ', "continuation %q hangs under the text", s)
	}
	testing.expect_value(t, texts[len(texts) - 1], "• next")
	md_lines_fit(t, lines, 16, "hanging list")
	loose := md_render("- a\n\n- b", 40, .Plain)
	md_expect_texts(t, md_texts(loose), {"• a", "", "• b"})
}

@(test)
test_md_quote :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("> quoted words that wrap\n>\n> second\nlazy", 14, .Plain)
	texts := md_texts(lines)
	for s in texts {
		testing.expectf(t, strings.has_prefix(s, "│"), "%q carries the bar", s)
	}
	testing.expect_value(t, texts[0], "│ quoted words")
	testing.expect(t, slice_has(texts, "│"), "the blank line keeps the bar")
	testing.expect(t, slice_has(texts, "│ second lazy"), "lazy continuation joins the paragraph")
}

@(test)
test_md_table :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "| a | b |\n|---|--:|\n| 1 | 22 |\n| `x\\|y` | 3 |"
	md_expect_texts(t, md_texts(md_render(src, 40, .Plain)), {"┌─────┬────┐", "│ a   │  b │", "├─────┼────┤", "│ 1   │ 22 │", "│ x|y │  3 │", "└─────┴────┘"})
}

@(test)
test_md_table_narrow :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "| Key | Default | Meaning |\n|---|---|---|\n| `tab_width` | `4` | Indent width in spaces; also the display width of a literal tab. |\n| `line_wrap` | `true` | Soft-wrap long lines. |"
	for w in ([]int{60, 40, 30}) {
		lines := md_render(src, w, .Plain)
		md_lines_fit(t, lines, w, fmt.tprintf("table at %d", w))
		testing.expect(t, strings.has_prefix(md_line_text(lines[0]), "┌"), "drawn as a box")
		testing.expect(t, strings.contains(md_all_text(lines), "literal"), "wrapped cell text kept")
	}
	flat := md_render(src, 16, .Plain)
	md_lines_fit(t, flat, 16, "flat table")
	testing.expect_value(t, md_line_text(flat[0]), "Key: tab_width")
	testing.expect(t, !strings.contains(md_all_text(flat), "│"), "too narrow for columns: no box")
}

@(test)
test_md_links :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "See [qed](https://q.ed/x \"t\") and [top](#top), [ref][r], <https://auto.link>, https://bare.url/p.\n\n![logo](a.png) [again](https://q.ed/x)\n\n[r]: https://r.ef"
	lines := md_render(src, 80, .Plain)
	texts := md_texts(lines)
	testing.expect_value(t, texts[0], "See qed[1] and top, ref[2], https://auto.link, https://bare.url/p.")
	testing.expect_value(t, texts[2], "[image: logo] again[1]")
	testing.expect_value(t, texts[len(texts) - 2], "[1] https://q.ed/x")
	testing.expect_value(t, texts[len(texts) - 1], "[2] https://r.ef")
	fg, _ := md_span_fg(lines, "qed")
	testing.expect(t, u64(fg) & u64(tb2.Color.Underline) != 0, "link text underlined")
}

@(test)
test_md_html :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "<p align=\"center\">\n  <img src=\"x.png\" alt=\"a shot\" width=\"9\">\n</p>\n\n<!-- hidden -->\n\n<table><tr><td><img alt=\"w\"><br><em>caption</em></td></tr></table>\n\nafter"
	md_expect_texts(t, md_texts(md_render(src, 40, .Plain)), {"[image: a shot]", "", "[image: w]", "caption", "", "after"})
}

@(test)
test_md_code_band :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("- item\n\n  ```\n  0123456789abcdef\n  ```", 12, .Plain)
	md_lines_fit(t, lines, 12, "code in a list")
	band := 0
	for line in lines {
		if line.fill == ' ' {
			band += 1
			testing.expect(t, u64(line.fill_bg) != 0, "band background")
			testing.expect(t, strings.has_prefix(md_line_text(line), "   "), "band starts after the list indent")
		}
	}
	testing.expect_value(t, band, 2)
}

@(test)
test_md_hover_style :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	src := "```go\nfunc Fprintf(w io.Writer, format string, a ...any) (n int, err error)\n```\n\nFprintf formats according to a format specifier and writes to w.\n\n---\n\n| A | B |\n|---|---|\n| one | two |\n\n[`fmt.Fprintf` on pkg.go.dev](https://pkg.go.dev/fmt#Fprintf)"
	for w in ([]int{76, 30, 10}) {
		lines := md_render(src, w, .Go)
		md_lines_fit(t, lines, w, fmt.tprintf("hover at %d", w))
		text := md_all_text(lines)
		testing.expect(t, !strings.contains(text, "```"), "no fence markers")
		testing.expect(t, strings.contains(text, "formats"), "prose kept")
	}
	wide := md_all_text(md_render(src, 76, .Go))
	testing.expect(t, strings.contains(wide, "[1] https://pkg.go.dev/fmt#Fprintf"), "footnote url")
}

@(test)
test_md_link_targets :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("a [b **c**](https://x.y) d <https://q.r> [e](#f)", 80, .Plain)
	testing.expect_value(t, md_line_link(lines[0], 0), "")
	testing.expect_value(t, md_line_link(lines[0], 2), "https://x.y")
	testing.expect_value(t, md_line_link(lines[0], 4), "https://x.y")
	testing.expect_value(t, md_line_link(lines[0], 6), "https://x.y")
	text := md_line_text(lines[0])
	testing.expect_value(t, md_line_link(lines[0], strings.index(text, "q.r")), "https://q.r")
	testing.expect_value(t, md_line_link(lines[0], strings.index(text, " e") + 1), "#f")
	foot := lines[len(lines) - 1]
	testing.expect_value(t, md_line_link(foot, 5), "https://x.y")
	wrapped := md_render("[one two three four](https://w.x)", 8, .Plain)
	for line in wrapped[:2] {
		testing.expect_value(t, md_line_link(line, 0), "https://w.x")
	}
}

@(test)
test_md_slugs :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	lines := md_render("# The `qed` Table!\n\n## Deep Dive\n\n## Deep Dive\n\ntext", 80, .Plain)
	slugs := make([dynamic]string, context.temp_allocator)
	for line in lines {
		if line.slug != "" {
			append(&slugs, line.slug)
		}
	}
	md_expect_texts(t, slugs[:], {"the-qed-table", "deep-dive", "deep-dive-1"})
}
