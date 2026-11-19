package main

test_buffer :: proc(lines: ..string) -> Buffer {
	b: Buffer
	b.id = buffer_id_next()
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

test_view :: proc(ed: ^Editor) -> ^Pane {
	p := pane_focus(ed)
	if p == nil || !p.ctx.lua {
		return nil
	}
	return p
}

test_view_selected :: proc(ed: ^Editor) -> string {
	p := test_view(ed)
	if p == nil || pane_count(p) == 0 {
		return ""
	}
	return p.list.items[pane_item_index(p, p.list.sel)].label
}
