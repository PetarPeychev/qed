package main

import "core:fmt"
import "core:strings"

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

@(thread_local)
test_list_built: int

ft_pane :: proc(ed: ^Editor) -> ^Pane {
	p := pane_find(ed, "filetree")
	if p == nil || !pane_live(ed, p) {
		return nil
	}
	return p
}

filetree_active :: proc(ed: ^Editor) -> bool {
	return ft_pane(ed) != nil
}

ft_run :: proc(ed: ^Editor, name: string) {
	cmd, ok := plugin_test_command(ed, name)
	assert(ok, name)
	plugin_command_run(ed, cmd)
	plugin_flush(ed)
}

filetree_open_all :: proc(ed: ^Editor) {
	ft_run(ed, "File Tree: All")
}

filetree_close :: proc(ed: ^Editor) {
	if p := ft_pane(ed); p != nil {
		pane_end(ed, p.handle, false)
		plugin_flush(ed)
	}
}

filetree_toggle_ignored :: proc(ed: ^Editor) {ft_run(ed, "File Tree: Toggle Ignored")}
filetree_toggle_dotfiles :: proc(ed: ^Editor) {ft_run(ed, "File Tree: Toggle Dotfiles")}
filetree_toggle_diff :: proc(ed: ^Editor) {ft_run(ed, "File Tree: Toggle Diff")}

ft_chip :: proc(ed: ^Editor, label: string) -> bool {
	if p := ft_pane(ed); p != nil {
		for c in p.chips {
			if c.label == label {
				return c.on
			}
		}
	}
	return false
}

ft_confirm_text :: proc(ed: ^Editor) -> string {
	if f := pane_focus(ed); f != nil && f.size == .Dialog && len(f.text) > 0 {
		return f.text[0].text
	}
	return ""
}

ft_scope :: proc(ed: ^Editor) -> string {
	p := ft_pane(ed)
	if p == nil || p.tab < 0 || p.tab >= len(p.tabs) {
		return ""
	}
	return p.tabs[p.tab].label
}

ft_tab_visible :: proc(ed: ^Editor, label: string) -> bool {
	cmd, ok := plugin_test_command(ed, fmt.tprintf("File Tree: %s", label))
	return ok && plugin_command_when(ed, cmd)
}

ft_entries :: proc(ed: ^Editor) -> []FileEntry {
	if p := ft_pane(ed); p != nil {
		return p.list.source.entries[:]
	}
	return nil
}

ft_selected :: proc(ed: ^Editor) -> (FileEntry, bool) {
	p := ft_pane(ed)
	if p == nil || len(p.list.source.entries) == 0 {
		return {}, false
	}
	return p.list.source.entries[clamp(p.list.sel, 0, len(p.list.source.entries) - 1)], true
}

ft_sel_range :: proc(ed: ^Editor) -> (lo, hi: int) {
	p := ft_pane(ed)
	lo, hi = p.list.sel, p.list.sel
	if a, ok := p.list.anchor.?; ok {
		lo, hi = min(a, p.list.sel), max(a, p.list.sel)
	}
	return
}

ft_mark :: proc(ed: ^Editor, path: string) -> PaneMark {
	if p := ft_pane(ed); p != nil {
		return p.marks[path] or_else PaneMark{}
	}
	return {}
}

ft_sel_deleted :: proc(ed: ^Editor) -> bool {
	sel, ok := ft_selected(ed)
	return ok && ft_mark(ed, sel.path).fg == "git_deleted"
}

FtMode :: enum {
	Nav,
	New,
	Rename,
	ConfirmDelete,
	ConfirmClose,
}

ft_mode :: proc(ed: ^Editor) -> FtMode {
	p := ft_pane(ed)
	if p == nil {
		return .Nav
	}
	if f := pane_focus(ed); f != nil && f.parent == p.handle && f.size == .Dialog && len(f.text) > 0 {
		switch {
		case strings.has_prefix(f.text[0].text, "Delete"):
			return .ConfirmDelete
		case strings.has_prefix(f.text[0].text, "Close"):
			return .ConfirmClose
		}
	}
	if p.footer_input {
		return .New if p.footer_field.prompt == "New: " else .Rename
	}
	return .Nav
}

FtLayout :: struct {
	box, inner:                               Rect,
	body_top, body_h, filter_y, filter_sep_y: int,
	footer_y, tab_y, title_sep_y:             int,
	div_x, left_w, right_x, right_w:          int,
	preview:                                  bool,
}

ft_layout :: proc(ed: ^Editor) -> FtLayout {
	p := ft_pane(ed)
	if p == nil {
		return {}
	}
	g := pane_geom(ed, p)
	return {
		box = g.box,
		inner = g.inner,
		body_top = g.list.y,
		body_h = g.list.h,
		filter_y = g.field_y,
		filter_sep_y = g.left_sep,
		footer_y = g.footer_y,
		tab_y = g.title_y,
		title_sep_y = g.title_y + 1,
		div_x = g.div_x,
		left_w = g.list.w,
		right_x = g.preview.x,
		right_w = g.preview.w,
		preview = g.has_preview,
	}
}

ft_expanded_count :: proc(ed: ^Editor) -> int {
	if p := ft_pane(ed); p != nil {
		return len(p.list.expanded)
	}
	if s := pane_saved_find(ed, "filetree"); s != nil {
		return len(s.expanded)
	}
	return 0
}
