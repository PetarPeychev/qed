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
	if p == nil || pane_count(ed, p) == 0 {
		return ""
	}
	return test_pane_label(ed, p, p.list.sel)
}

test_pane_label :: proc(ed: ^Editor, p: ^Pane, i: int) -> string {
	return list_item(ed, p, pane_item_index(p, i)).label
}

test_pane_items :: proc(ed: ^Editor, p: ^Pane) -> []PaneItem {
	out := make([]PaneItem, list_count(ed, p), context.temp_allocator)
	for &it, i in out {
		it = list_item(ed, p, i)
	}
	return out
}

test_pane_open :: proc(ed: ^Editor, id: string) -> bool {
	p := pane_find(ed, id)
	return p != nil && pane_live(ed, p)
}
