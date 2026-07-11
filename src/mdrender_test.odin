package main

import "core:fmt"
import "core:strings"
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
	lines := md_render("call some_long_name here", 200, .Plain)
	testing.expect(t, strings.contains(md_all_text(lines), "some_long_name"), "underscores in identifier kept")
}

@(test)
test_md_header :: proc(t: ^testing.T) {
	lines := md_render("## Big Title ##", 200, .Plain)
	testing.expect_value(t, len(lines), 1)
	fg, ok := md_span_fg(lines, "Big Title")
	testing.expect(t, ok, "header text stripped of #")
	testing.expect(t, md_has_bold(fg), "header is bold")
	testing.expect(t, u64(fg) & u64(COLOR_PANE_PROMPT_FG) == u64(COLOR_PANE_PROMPT_FG), "header uses prompt color")
}

@(test)
test_md_rule :: proc(t: ^testing.T) {
	lines := md_render("above\n\n---\n\nbelow", 200, .Plain)
	found := false
	for line in lines {
		if line.rule {
			found = true
		}
	}
	testing.expect(t, found, "--- becomes a rule line")
	testing.expect(t, !strings.contains(md_all_text(lines), "---"), "dashes not in text")
}

@(test)
test_md_fence_language :: proc(t: ^testing.T) {
	testing.expect_value(t, md_fence_language("python", .Plain), Language.Python)
	testing.expect_value(t, md_fence_language("ts foo", .Plain), Language.TypeScript)
	testing.expect_value(t, md_fence_language("", .Go), Language.Go)
	testing.expect_value(t, md_fence_language("nonsense", .Rust), Language.Rust)
}

@(test)
test_md_fence_stripped :: proc(t: ^testing.T) {
	lines := md_render("```python\nx = 1\ny = 2\n```", 200, .Plain)
	joined := md_all_text(lines)
	testing.expect(t, !strings.contains(joined, "`"), "fence backticks dropped")
	testing.expect(t, !strings.contains(joined, "python"), "info string dropped")
	testing.expect(t, strings.contains(joined, "x = 1"), "code content kept")
	testing.expect(t, strings.contains(joined, "y = 2"), "code content kept")
}

@(test)
test_md_wrap :: proc(t: ^testing.T) {
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
test_md_leading_spaces :: proc(t: ^testing.T) {
	lines := md_render("  two-space indent", 200, .Plain)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, md_line_text(lines[0]), "  two-space indent")

	wrapped := md_render("  aaa bbb", 5, .Plain)
	testing.expect_value(t, len(wrapped), 2)
	testing.expect_value(t, md_line_text(wrapped[0]), "  aaa")
	testing.expect_value(t, md_line_text(wrapped[1]), "bbb")
}

@(test)
test_md_indented_code_block :: proc(t: ^testing.T) {
	src := "Example:\n\n\timport \"core:fmt\"\n\n\tmain :: proc() {\n\t\tx := 1\n\t}\n\nAfter"
	lines := md_render(src, 200, .Plain)
	joined := md_all_text(lines)
	testing.expect(t, strings.contains(joined, "\nimport \"core:fmt\""), "code content kept, one indent level stripped")
	pad := strings.repeat(" ", TAB_WIDTH, context.temp_allocator)
	testing.expect(t, strings.contains(joined, fmt.tprintf("\n%sx := 1", pad)), "nested indentation preserved")
	testing.expect(t, strings.contains(joined, "\nAfter"), "prose resumes after the block")

	lit := md_render("para\n\n\t**not bold** `x`", 200, .Plain)
	testing.expect(t, strings.contains(md_all_text(lit), "**not bold** `x`"), "no inline processing inside indented code")
}

@(test)
test_md_tab_expansion :: proc(t: ^testing.T) {
	lines := md_render("```\n\tx = 1\na\tb\n```", 200, .Plain)
	testing.expect_value(t, len(lines), 2)
	for line in lines {
		for s in line.spans {
			testing.expect(t, !strings.contains(s.text, "\t"), "no tab rune survives into any span")
		}
	}
	pad := strings.repeat(" ", TAB_WIDTH, context.temp_allocator)
	testing.expect_value(t, md_line_text(lines[0]), fmt.tprintf("%sx = 1", pad))
	gap := strings.repeat(" ", TAB_WIDTH - 1, context.temp_allocator)
	testing.expect_value(t, md_line_text(lines[1]), fmt.tprintf("a%sb", gap))
	testing.expect_value(t, md_line_width(lines[1]), TAB_WIDTH + 1)

	prose := md_render("p\tq", 200, .Plain)
	testing.expect_value(t, len(prose), 1)
	testing.expect_value(t, md_line_text(prose[0]), fmt.tprintf("p%sq", gap))
	testing.expect_value(t, md_line_width(prose[0]), TAB_WIDTH + 1)
}

@(test)
test_md_blank_collapse :: proc(t: ^testing.T) {
	lines := md_render("a\n\n\n\nb", 200, .Plain)
	blanks := 0
	for line in lines {
		if !line.rule && len(line.spans) == 0 {
			blanks += 1
		}
	}
	testing.expect_value(t, blanks, 1)
	testing.expect_value(t, len(lines), 3)
}
