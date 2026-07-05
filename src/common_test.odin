package main

test_buffer :: proc(lines: ..string) -> Buffer {
	b: Buffer
	b.indent_width = TAB_WIDTH
	b.lines = make([dynamic]Line, 0, len(lines))
	for l in lines {
		line: Line
		append(&line.text, ..transmute([]u8)l)
		append(&b.lines, line)
	}
	if len(b.lines) == 0 {
		append(&b.lines, Line{})
	}
	return b
}
