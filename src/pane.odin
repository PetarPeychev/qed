package main

import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

Rect :: struct {
	x, y, w, h: int,
}

pane_center :: proc(editor: ^Editor, content_w, content_h: int) -> Rect {
	sw := int(tb2.width())
	sh := int(tb2.height())
	if !editor.welcome {
		sh -= STATUS_ROWS
	}
	w := min(content_w + 2, sw)
	h := content_h + 2
	x := max(0, (sw - w) / 2)
	y := max(0, (sh - h) / 2)
	return {x, y, w, h}
}

pane_draw_box :: proc(r: Rect) -> Rect {
	for y in r.y ..< r.y + r.h {
		for x in r.x ..< r.x + r.w {
			tb2.set_cell(i32(x), i32(y), ' ', COLOR_PANE_BORDER, COLOR_PANE_BG)
		}
	}

	left := r.x
	right := r.x + r.w - 1
	top := r.y
	bottom := r.y + r.h - 1
	for x in left + 1 ..< right {
		tb2.set_cell(i32(x), i32(top), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
		tb2.set_cell(i32(x), i32(bottom), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	for y in top + 1 ..< bottom {
		tb2.set_cell(i32(left), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
		tb2.set_cell(i32(right), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(left), i32(top), '┌', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(right), i32(top), '┐', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(left), i32(bottom), '└', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(right), i32(bottom), '┘', COLOR_PANE_BORDER, COLOR_PANE_BG)

	return {r.x + 1, r.y + 1, r.w - 2, r.h - 2}
}

mouse_in_rect :: proc(ev: tb2.Event, r: Rect) -> bool {
	x, y := int(ev.x), int(ev.y)
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

pane_scrollbar_thumb :: proc(offset, visible, total: int) -> (start, length: int) {
	if visible <= 0 || total <= visible {
		return 0, 0
	}
	length = min(visible, max(1, visible * visible / total))
	span := visible - length
	start = clamp(offset * span / (total - visible), 0, span)
	return
}

pane_draw_scrollbar :: proc(x, y, visible, offset, total: int) {
	start, length := pane_scrollbar_thumb(offset, visible, total)
	for i in 0 ..< length {
		tb2.set_cell(i32(x), i32(y + start + i), '┃', COLOR_PANE_FG, COLOR_PANE_BG)
	}
}

pane_hline :: proc(box: Rect, y: int) {
	left := box.x
	right := box.x + box.w - 1
	for x in left + 1 ..< right {
		tb2.set_cell(i32(x), i32(y), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(left), i32(y), '├', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(right), i32(y), '┤', COLOR_PANE_BORDER, COLOR_PANE_BG)
}

pane_fill_row :: proc(x, y, w: int, fg, bg: tb2.Color) {
	for col in 0 ..< w {
		tb2.set_cell(i32(x + col), i32(y), ' ', fg, bg)
	}
}

pane_text :: proc(x, y, w: int, text: string, fg, bg: tb2.Color) {
	col := 0
	i := 0
	for i < len(text) && col < w {
		r, sz := utf8.decode_rune(text[i:])
		if r == '\t' {
			next := (col / TAB_WIDTH + 1) * TAB_WIDTH
			for col < next && col < w {
				tb2.set_cell(i32(x + col), i32(y), ' ', fg, bg)
				col += 1
			}
		} else {
			tb2.set_cell(i32(x + col), i32(y), r, fg, bg)
			col += 1
		}
		i += sz
	}
}

PaneKind :: enum {
	Exclusive,
	Child,
	Passive,
}

PaneSize :: enum {
	Dialog,
	Palette,
}

PaneAction :: enum {
	None,
	Activate,
	Close,
}

PaneField :: struct {
	prompt:      string,
	using field: TextField,
}

PaneList :: struct {
	items: []string,
	sel:   int,
}

PaneHandler :: proc(editor: ^Editor, p: ^Pane)

Pane :: struct {
	handle: u64,
	id:     string,
	owner:  string,
	kind:   PaneKind,
	safety: bool,
	parent: u64,
	over:   ^bool, // legacy Overlay this child sits on; goes away once every overlay is a Pane
	size:   PaneSize,
	fields: []PaneField,
	text:   []string,
	list:   PaneList,
	on:     struct {
		activate, close: PaneHandler,
	},
}

pane_open :: proc(editor: ^Editor, spec: Pane) -> ^Pane {
	if spec.kind == .Exclusive && !spec.safety {
		for i := len(editor.panes) - 1; i >= 0; i -= 1 {
			if i < len(editor.panes) && editor.panes[i].kind == .Exclusive && !editor.panes[i].safety {
				pane_end(editor, editor.panes[i].handle, false)
			}
		}
	}
	p := spec
	editor.pane_seq += 1
	p.handle = editor.pane_seq
	p.id = strings.clone(spec.id)
	p.text = make([]string, len(spec.text))
	for s, i in spec.text {
		p.text[i] = strings.clone(s)
	}
	p.list.items = make([]string, len(spec.list.items))
	for s, i in spec.list.items {
		p.list.items[i] = strings.clone(s)
	}
	p.fields = make([]PaneField, len(spec.fields))
	for f, i in spec.fields {
		p.fields[i].prompt = strings.clone(f.prompt)
		p.fields[i].anchor = -1
	}
	at := len(editor.panes)
	if !p.safety {
		for q, i in editor.panes {
			if q.safety {
				at = i
				break
			}
		}
	}
	inject_at(&editor.panes, at, p)
	return &editor.panes[at]
}

pane_free :: proc(p: ^Pane) {
	delete(p.id)
	for s in p.text {
		delete(s)
	}
	delete(p.text)
	for s in p.list.items {
		delete(s)
	}
	delete(p.list.items)
	for &f in p.fields {
		delete(f.prompt)
		textfield_destroy(&f.field)
	}
	delete(p.fields)
}

pane_index :: proc(editor: ^Editor, handle: u64) -> int {
	for p, i in editor.panes {
		if p.handle == handle {
			return i
		}
	}
	return -1
}

pane_end :: proc(editor: ^Editor, handle: u64, activate: bool) {
	i := pane_index(editor, handle)
	if i < 0 {
		return
	}
	gone := make([dynamic]Pane, context.temp_allocator)
	handles := make(map[u64]bool, context.temp_allocator)
	handles[handle] = true
	append(&gone, editor.panes[i])
	for j := i + 1; j < len(editor.panes); j += 1 {
		if editor.panes[j].parent in handles {
			handles[editor.panes[j].handle] = true
			append(&gone, editor.panes[j])
		}
	}
	for j := len(editor.panes) - 1; j >= i; j -= 1 {
		if editor.panes[j].handle in handles {
			ordered_remove(&editor.panes, j)
		}
	}
	// children first, so a parent's handler never sees its children open
	#reverse for &p in gone {
		h := p.on.activate if activate && p.handle == handle else p.on.close
		if h != nil {
			h(editor, &p)
		}
		pane_free(&p)
	}
}

pane_live :: proc(p: ^Pane) -> bool {
	return p.over == nil || p.over^
}

pane_focus :: proc(editor: ^Editor) -> ^Pane {
	#reverse for &p in editor.panes {
		if p.kind != .Passive && pane_live(&p) {
			return &p
		}
	}
	return nil
}

pane_find :: proc(editor: ^Editor, id: string) -> ^Pane {
	for &p in editor.panes {
		if p.id == id {
			return &p
		}
	}
	return nil
}

pane_safety_open :: proc(editor: ^Editor) -> bool {
	for p in editor.panes {
		if p.safety {
			return true
		}
	}
	return false
}

pane_stack_sync :: proc(editor: ^Editor) {
	for i := len(editor.panes) - 1; i >= 0; i -= 1 {
		if i < len(editor.panes) && !pane_live(&editor.panes[i]) {
			pane_end(editor, editor.panes[i].handle, false)
		}
	}
}

pane_unload :: proc(editor: ^Editor, owner: string) {
	for &p in editor.panes {
		if p.owner == owner {
			p.on = {}
		}
	}
	for i := len(editor.panes) - 1; i >= 0; i -= 1 {
		if i < len(editor.panes) && editor.panes[i].owner == owner {
			pane_end(editor, editor.panes[i].handle, false)
		}
	}
}

pane_stack_destroy :: proc(editor: ^Editor) {
	for &p in editor.panes {
		pane_free(&p)
	}
	delete(editor.panes)
}

pane_stack_dispatch :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	p := pane_focus(editor)
	if p == nil {
		return false
	}
	action := PaneAction.None
	#partial switch ev.type {
	case .Key:
		action = pane_key(p, ev)
	case .Mouse:
		action = pane_mouse(editor, p, ev)
	case .Resize:
		editor_overlay_resize(editor)
	}
	if action != .None {
		pane_end(editor, p.handle, action == .Activate)
	}
	return true
}

pane_stack_paste :: proc(editor: ^Editor, text: string) -> bool {
	p := pane_focus(editor)
	if p == nil {
		return false
	}
	pane_paste(p, text)
	return true
}

pane_stack_render :: proc(editor: ^Editor, passive: bool) -> (drew: bool) {
	for &p in editor.panes {
		if (p.kind == .Passive) == passive && pane_live(&p) {
			pane_render(editor, &p)
			drew = true
		}
	}
	return
}

pane_rows :: proc(p: ^Pane) -> (head, rows: int) {
	head = len(p.fields) + len(p.text)
	rows = head + len(p.list.items)
	if head > 0 && len(p.list.items) > 0 {
		rows += 1
	}
	return
}

pane_box :: proc(editor: ^Editor, p: ^Pane) -> Rect {
	_, rows := pane_rows(p)
	w := PALETTE_WIDTH
	if p.size == .Dialog {
		w = 0
		for s in p.text {
			w = max(w, len(s))
		}
		for s in p.list.items {
			w = max(w, len(s))
		}
		w = min(w + 2, int(tb2.width()) - 4)
	}
	return pane_center(editor, w, rows)
}

pane_list_top :: proc(p: ^Pane, inner: Rect) -> int {
	head, _ := pane_rows(p)
	return inner.y + head + (1 if head > 0 else 0)
}

pane_render :: proc(editor: ^Editor, p: ^Pane) {
	box := pane_box(editor, p)
	inner := pane_draw_box(box)
	y := inner.y
	for &f in p.fields {
		overlay_prompt_render(inner.x + 1, y, inner.w - 2, &f.field, f.prompt)
		y += 1
	}
	for s in p.text {
		pane_text(inner.x + 1, y, inner.w - 2, s, COLOR_PANE_FG, COLOR_PANE_BG)
		y += 1
	}
	if len(p.list.items) > 0 && y > inner.y {
		pane_hline(box, y)
	}
	top := pane_list_top(p, inner)
	for s, i in p.list.items {
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == p.list.sel {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, top + i, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, top + i, inner.w - 2, s, fg, bg)
	}
	if len(p.fields) == 0 {
		tb2.hide_cursor()
	}
}

pane_key :: proc(p: ^Pane, ev: tb2.Event) -> PaneAction {
	#partial switch ev.key {
	case .Esc:
		return .Close
	case .Enter:
		return .Activate
	case .Arrow_Up, .Arrow_Down:
		if n := len(p.list.items); n > 0 {
			p.list.sel = clamp(p.list.sel + (-1 if ev.key == .Arrow_Up else 1), 0, n - 1)
			return .None
		}
	}
	if len(p.fields) > 0 {
		textfield_key(&p.fields[0].field, ev)
	}
	return .None
}

pane_mouse :: proc(editor: ^Editor, p: ^Pane, ev: tb2.Event) -> PaneAction {
	if ev.key != .Mouse_Left {
		return .None
	}
	box := pane_box(editor, p)
	motion := ev_motion(ev)
	if !mouse_in_rect(ev, box) {
		return .None if motion else .Close
	}
	inner := Rect{box.x + 1, box.y + 1, box.w - 2, box.h - 2}
	if f := int(ev.y) - inner.y; f >= 0 && f < len(p.fields) {
		overlay_prompt_mouse(&p.fields[f].field, inner.x + 1, inner.y + f, inner.w - 2, ev, p.fields[f].prompt)
		return .None
	}
	off := overlay_row_off(ev, Rect{inner.x, pane_list_top(p, inner), inner.w, len(p.list.items)})
	if off < 0 {
		return .None
	}
	p.list.sel = off
	if !motion && overlay_double_click(editor, off) {
		return .Activate
	}
	return .None
}

pane_paste :: proc(p: ^Pane, text: string) {
	if len(p.fields) > 0 {
		textfield_insert_flat(&p.fields[0].field, text)
	}
}
