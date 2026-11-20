package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
longline_text :: proc(n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< n {
		fmt.sbprintf(&sb, "w%05d ", i)
	}
	return strings.to_string(sb)
}

@(test)
e2e_long_line_find_highlights :: proc(t: ^testing.T) {
	line := longline_text(20000)
	e := e2e_start(line)
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	b.wrap = false
	b.cursor = {0, 0}
	e2e_key(&e, .Ctrl_F)
	e2e_type(&e, "w0")
	testing.expect_value(t, len(e.ed.find.matches), FIND_MAX_MATCHES)
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	row := -1
	for y in 0 ..< 22 {
		if strings.contains(e2e_row_text(&e, y), "w00000") {
			row = y
		}
	}
	testing.expect(t, row >= 0, "line on screen")
	if row < 0 {
		return
	}
	for x in 0 ..< 70 {
		col := x
		if col < 7 {
			continue
		}
		in_match := col % 7 < 2
		hl := e2e_cell_bg(&e, gutter + x, row) == COLOR_FIND_MATCH_BG
		testing.expectf(t, hl == in_match, "col %d highlighted=%v, want %v", col, hl, in_match)
	}
}
