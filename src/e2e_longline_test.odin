package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(private = "file")
longline_text :: proc(n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< n {
		fmt.sbprintf(&sb, "w%05d ", i)
	}
	return strings.to_string(sb)
}

@(test)
e2e_long_line_wrapped_segments_render :: proc(t: ^testing.T) {
	line := longline_text(20000)
	e := e2e_start(fmt.tprintf("%s\n\tté́xt\t😀 tail\n", line))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.wrap = true
	b.cursor = {0, len(line) / 2}
	editor_scroll(&e.ed)
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	w := int(80) - gutter
	segs := line_wrap(b.lines[0].text[:], w)
	sub := main_view(&e).scroll_sub
	testing.expect(t, sub > 100, "viewport is deep inside the long line")
	for y in 0 ..< 5 {
		s := sub + y
		want := strings.trim_right_space(line[segs[s]:segs[s + 1]])
		got := strings.trim_space(e2e_row_text(&e, y)[gutter:])
		testing.expectf(t, got == want, "row %d: %q, want %q", y, got, want)
	}

	b.cursor = {1, 0}
	editor_scroll(&e.ed)
	e2e_render(&e)
	found := false
	for y in 0 ..< 22 {
		if strings.contains(e2e_row_text(&e, y), "tail") {
			found = true
			testing.expect(t, strings.contains(e2e_row_text(&e, y), "😀"), "emoji renders")
		}
	}
	testing.expect(t, found, "second line visible")
}

@(private = "file")
clip_screen_fg :: proc() -> []tb2.Color {
	w, h := int(tb2.width()), int(tb2.height()) - STATUS_ROWS
	out := make([]tb2.Color, w * h, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			cell: ^tb2.Cell_Raw
			if tb2.get_cell(i32(x), i32(y), 1, &cell) == .Ok {
				out[y * w + x] = cell.fg
			}
		}
	}
	return out
}

@(private = "file")
clip_check :: proc(t: ^testing.T, e: ^E2E, label: string) {
	b := editor_buffer(&e.ed)
	for &row in b.hl.colors {
		clear(&row)
	}
	b.hl.top = -1
	e2e_render(e)
	testing.expectf(t, len(b.hl.clips) > 0, "%s: a long row is clipped", label)
	clipped := clip_screen_fg()
	colored := 0
	for c in clipped {
		if e2e_rgb(c) != e2e_rgb(COLOR_FG) && e2e_rgb(c) != e2e_rgb(COLOR_BG) {
			colored += 1
		}
	}
	testing.expectf(t, colored > 100, "%s: screen is highlighted (%d colored cells)", label, colored)

	highlight_query_paint(b, syntax_for(b.language), b.hl.top, b.hl.bot)
	view := main_view(e)
	e.ed.scroll_row, e.ed.scroll_sub, e.ed.scroll_col = view.scroll_row, view.scroll_sub, view.scroll_col
	tb2.clear()
	editor_render_buffer(&e.ed)
	full := clip_screen_fg()
	w := int(tb2.width())
	for c, i in clipped {
		if c != full[i] {
			testing.expectf(t, false, "%s: cell (%d,%d) clipped %v, full %v", label, i % w, i / w, c, full[i])
			return
		}
	}
}

@(private = "file")
clip_long_row :: proc(sb: ^strings.Builder, n: int) {
	for i in 0 ..< n {
		switch i % 4 {
		case 0:
			fmt.sbprintf(sb, "int v%d = 0x%x; ", i, i)
		case 1:
			fmt.sbprintf(sb, "char *s%d = \"a string \\n %d that runs well past one screen width of text, with \\t escapes\"; ", i, i)
		case 2:
			fmt.sbprintf(sb, "/* inline comment %d long enough to straddle a screen edge somewhere along the row */ ", i)
		case:
			fmt.sbprintf(sb, "return f%d(%d); ", i, i)
		}
	}
	strings.write_byte(sb, '\n')
}

@(test)
e2e_highlight_clip_matches_full :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "/* a block comment\n   that starts above\n   the viewport\n   and ends */ int z = 1;\n")
	clip_long_row(&sb, 600)
	strings.write_string(&sb, "int short_a;\n/* split\n comment */\n")
	clip_long_row(&sb, 500)
	for i in 0 ..< 40 {
		fmt.sbprintf(&sb, "int tail%d = %d;\n", i, i)
	}
	e := e2e_start(strings.to_string(sb))
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.language = .C

	b.wrap = false
	main_view(&e).scroll_row, main_view(&e).scroll_sub = 2, 0
	b.cursor = {4, 0}
	clip_check(t, &e, "wrap off, column 0")
	for col in ([]int{9000, 9001, 9017, 9033, 20000}) {
		b.cursor = {4, col}
		clip_check(t, &e, fmt.tprintf("wrap off, cursor at %d", col))
		b.cursor = {8, col}
		clip_check(t, &e, fmt.tprintf("wrap off, second long row at %d", col))
	}

	b.wrap = true
	main_view(&e).scroll_row, main_view(&e).scroll_sub = 2, 0
	b.cursor = {2, 0}
	clip_check(t, &e, "wrap on, comment above")
	for col in ([]int{9000, 9033, 20000, len(b.lines[4].text) - 1}) {
		b.cursor = {4, col}
		clip_check(t, &e, fmt.tprintf("wrap on, cursor at %d", col))
	}
	b.cursor = {8, 100}
	clip_check(t, &e, "wrap on, second long row")
}
