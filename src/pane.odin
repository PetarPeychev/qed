package main

import "core:fmt"
import "core:strings"
import "core:time"
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

PANE_QUERY_DEBOUNCE_MS :: 120

PaneKind :: enum {
	Exclusive,
	Child,
	Passive,
}

PanePlace :: enum {
	Center,
	Full,
	Split,
}

PaneSize :: enum {
	Dialog,
	Palette,
	Code,
}

PaneAction :: enum {
	None,
	Activate,
	Close,
}

PaneFieldMode :: enum {
	Input,
	Filter,
	Query,
	Path,
}

PaneField :: struct {
	prompt:      string,
	mode:        PaneFieldMode,
	count:       bool,
	using field: TextField,
}

PaneItem :: struct {
	label, detail, path, key: string,
	row, src:                 int,
}

PaneLine :: struct {
	text, color: string,
}

PaneHint :: struct {
	label, cmd: string,
}

PaneList :: struct {
	items:   [dynamic]PaneItem,
	matches: [dynamic]int,
	sel:     int,
	scroll:  int,
	anchor:  Maybe(int),
	multi:   bool,
	max:     int,
	more:    bool,
	empty:   string,
	hint:    string,
	restore: string,
	sort:    bool,
	moved:   bool,
	source:  ListSource,
}

PaneHandler :: proc(editor: ^Editor, p: ^Pane)

PaneCtx :: struct {
	buf: u64,
	lua: bool,
}

Pane :: struct {
	handle:       u64,
	id:           string,
	owner:        string,
	kind:         PaneKind,
	safety:       bool,
	modal:        bool,
	dead:         bool,
	parent:       u64,
	over:         ^bool, // legacy Overlay this child sits on; goes away once every overlay is a Pane
	place:        PanePlace,
	size:         PaneSize,
	ctx:          PaneCtx,
	title:        string,
	fields:       []PaneField,
	focus:        int,
	text:         []PaneLine,
	scroll:       int,
	list:         PaneList,
	has_list:     bool,
	auto_preview: bool,
	preview:      Preview,
	footer:       []PaneHint,
	toggle:       u64,
	chord:        string,
	query_due:    bool,
	query_at:     time.Tick,
	accept:       bool,
	landed:       bool,
	notified:     int,
	on:           struct {
		activate, close: PaneHandler,
	},
}

PaneSaved :: struct {
	id:    string,
	texts: []string,
	key:   string,
}

pane_labels :: proc(labels: []string) -> [dynamic]PaneItem {
	items := make([dynamic]PaneItem, len(labels), context.temp_allocator)
	for s, i in labels {
		items[i].label = s
	}
	return items
}

pane_open :: proc(editor: ^Editor, spec: Pane) -> ^Pane {
	if spec.kind == .Exclusive && !spec.safety {
		for &q in editor.panes {
			if q.modal && q.kind != .Passive && pane_live(editor, &q) {
				return nil
			}
		}
		for i := len(editor.panes) - 1; i >= 0; i -= 1 {
			if i < len(editor.panes) && editor.panes[i].kind == .Exclusive && !editor.panes[i].safety {
				pane_end(editor, editor.panes[i].handle, false)
			}
		}
	}
	at := len(editor.panes)
	if spec.parent != 0 {
		i := pane_index(editor, spec.parent)
		if i < 0 {
			return nil
		}
		at = i + 1
		for at < len(editor.panes) && pane_descends(editor, &editor.panes[at], spec.parent) {
			at += 1
		}
	} else if !spec.safety {
		for q, i in editor.panes {
			if q.safety {
				at = i
				break
			}
		}
	}
	p := spec
	editor.pane_seq += 1
	p.handle = editor.pane_seq
	p.id = strings.clone(spec.id)
	p.chord = strings.clone(spec.chord)
	p.title = strings.clone(spec.title)
	p.text = pane_lines_clone(spec.text)
	p.has_list = spec.has_list || len(spec.list.items) > 0
	p.list.items = {}
	p.list.matches = {}
	pane_items_add(&p, spec.list.items[:])
	p.list.empty = strings.clone(spec.list.empty)
	p.list.source = list_source_clone(spec.list.source)
	p.list.hint = ""
	p.list.restore = ""
	p.footer = make([]PaneHint, len(spec.footer))
	for h, i in spec.footer {
		p.footer[i] = {strings.clone(h.label), strings.clone(h.cmd)}
	}
	p.fields = make([]PaneField, len(spec.fields))
	for f, i in spec.fields {
		p.fields[i].prompt = strings.clone(f.prompt)
		p.fields[i].mode = f.mode
		p.fields[i].count = f.count
		p.fields[i].anchor = -1
	}
	p.preview = {}
	p.notified = -1
	inject_at(&editor.panes, at, p)
	return &editor.panes[at]
}

pane_lines_clone :: proc(lines: []PaneLine) -> []PaneLine {
	out := make([]PaneLine, len(lines))
	for l, i in lines {
		out[i] = {strings.clone(l.text), strings.clone(l.color)}
	}
	return out
}

pane_lines_free :: proc(lines: []PaneLine) {
	for l in lines {
		delete(l.text)
		delete(l.color)
	}
	delete(lines)
}

pane_item_free :: proc(it: PaneItem) {
	delete(it.label)
	delete(it.detail)
	delete(it.path)
	delete(it.key)
}

pane_item_clone :: proc(it: PaneItem) -> PaneItem {
	return {strings.clone(it.label), strings.clone(it.detail), strings.clone(it.path), strings.clone(it.key), it.row, it.src}
}

pane_items_add :: proc(p: ^Pane, items: []PaneItem) {
	for it in items {
		append(&p.list.items, pane_item_clone(it))
	}
}

pane_items_clear :: proc(p: ^Pane) {
	for it in p.list.items {
		pane_item_free(it)
	}
	clear(&p.list.items)
	clear(&p.list.matches)
}

pane_free :: proc(p: ^Pane) {
	delete(p.id)
	delete(p.chord)
	delete(p.title)
	pane_lines_free(p.text)
	pane_items_clear(p)
	delete(p.list.items)
	delete(p.list.matches)
	delete(p.list.empty)
	delete(p.list.hint)
	delete(p.list.restore)
	list_source_free(&p.list.source)
	for h in p.footer {
		delete(h.label)
		delete(h.cmd)
	}
	delete(p.footer)
	for &f in p.fields {
		delete(f.prompt)
		textfield_destroy(&f.field)
	}
	delete(p.fields)
	preview_destroy(&p.preview)
}

pane_index :: proc(editor: ^Editor, handle: u64) -> int {
	for p, i in editor.panes {
		if p.handle == handle {
			return i
		}
	}
	return -1
}

pane_descends :: proc(editor: ^Editor, p: ^Pane, ancestor: u64) -> bool {
	for parent := p.parent; parent != 0; {
		if parent == ancestor {
			return true
		}
		i := pane_index(editor, parent)
		if i < 0 {
			return false
		}
		parent = editor.panes[i].parent
	}
	return false
}

pane_buffer :: proc(editor: ^Editor, p: ^Pane) -> (^Buffer, int) {
	b, idx := api_buf_find(editor, p.ctx.buf)
	if b == nil {
		editor_log(editor, .Warn, "", "Buffer closed while the dialog was open")
	}
	return b, idx
}

// a pane's descendants always follow it contiguously (pane_open), so they are the run after it
pane_end :: proc(editor: ^Editor, handle: u64, activate: bool) {
	i := pane_index(editor, handle)
	if i < 0 {
		return
	}
	n := 1
	for i + n < len(editor.panes) && pane_descends(editor, &editor.panes[i + n], handle) {
		n += 1
	}
	gone := make([]Pane, n, context.temp_allocator)
	copy(gone, editor.panes[i:i + n])
	remove_range(&editor.panes, i, i + n)
	// children first, so a parent's handler never sees its children open
	#reverse for &p in gone {
		h := p.on.activate if activate && p.handle == handle else p.on.close
		if h != nil {
			h(editor, &p)
		}
		pane_free(&p)
	}
}

pane_live :: proc(editor: ^Editor, p: ^Pane) -> bool {
	if p.dead || (p.over != nil && !p.over^) {
		return false
	}
	if p.parent == 0 {
		return true
	}
	i := pane_index(editor, p.parent)
	return i >= 0 && pane_live(editor, &editor.panes[i])
}

pane_focus :: proc(editor: ^Editor) -> ^Pane {
	#reverse for &p in editor.panes {
		if p.kind != .Passive && pane_live(editor, &p) {
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

pane_lua_open :: proc(editor: ^Editor) -> bool {
	for &p in editor.panes {
		if p.ctx.lua && pane_live(editor, &p) {
			return true
		}
	}
	return false
}

pane_stack_sync :: proc(editor: ^Editor) {
	for {
		h: u64
		for &p in editor.panes {
			if !pane_live(editor, &p) {
				h = p.handle
				break
			}
		}
		if h == 0 {
			break
		}
		pane_end(editor, h, false)
	}
	pane_stack_fit(editor, false)
}

pane_stack_fit :: proc(editor: ^Editor, resize: bool) {
	for &p in editor.panes {
		if !pane_live(editor, &p) {
			continue
		}
		if resize && p.has_list {
			pane_scroll_fit(&p, pane_geom(editor, &p).list.h)
		}
		pane_preview_sync(editor, &p)
	}
}

// deferred to pane_stack_sync: no Lua may run while a plugin unloads
pane_unload :: proc(editor: ^Editor, owner: string) {
	for &p in editor.panes {
		if p.owner == owner {
			if p.ctx.lua {
				pane_save(editor, &p)
			}
			p.on = {}
			p.dead = true
		}
	}
}

pane_stack_destroy :: proc(editor: ^Editor) {
	for &p in editor.panes {
		pane_free(&p)
	}
	delete(editor.panes)
	for s in editor.pane_saved {
		pane_saved_free(s)
	}
	delete(editor.pane_saved)
}

pane_saved_free :: proc(s: PaneSaved) {
	delete(s.id)
	for t in s.texts {
		delete(t)
	}
	delete(s.texts)
	delete(s.key)
}

pane_saved_find :: proc(editor: ^Editor, id: string) -> ^PaneSaved {
	for &s in editor.pane_saved {
		if s.id == id {
			return &s
		}
	}
	return nil
}

pane_save :: proc(editor: ^Editor, p: ^Pane) {
	if p.id == "" {
		return
	}
	s := pane_saved_find(editor, p.id)
	if s == nil {
		append(&editor.pane_saved, PaneSaved{id = strings.clone(p.id)})
		s = &editor.pane_saved[len(editor.pane_saved) - 1]
	}
	for t in s.texts {
		delete(t)
	}
	delete(s.texts)
	delete(s.key)
	s.texts = make([]string, len(p.fields))
	for &f, i in p.fields {
		s.texts[i] = strings.clone(textfield_str(&f.field))
	}
	s.key = strings.clone(pane_selected_key(p))
}

pane_stack_dispatch :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	p := pane_focus(editor)
	if p == nil {
		return false
	}
	action := PaneAction.None
	#partial switch ev.type {
	case .Key:
		action = pane_key(editor, p, ev)
	case .Mouse:
		action = pane_mouse(editor, p, ev)
	case .Resize:
		editor_overlay_resize(editor)
	}
	if action == .Activate && p.ctx.lua {
		p.on.activate(editor, p)
	} else if action != .None {
		pane_end(editor, p.handle, action == .Activate)
	}
	pane_stack_fit(editor, false)
	return true
}

pane_stack_paste :: proc(editor: ^Editor, text: string) -> bool {
	p := pane_focus(editor)
	if p == nil {
		return false
	}
	pane_paste(editor, p, text)
	pane_stack_fit(editor, false)
	return true
}

pane_stack_render :: proc(editor: ^Editor, passive: bool) -> (drew: bool) {
	for &p in editor.panes {
		if (p.kind == .Passive) == passive && pane_live(editor, &p) {
			pane_render(editor, &p)
			drew = true
		}
	}
	return
}

pane_filter :: proc(p: ^Pane) -> ^PaneField {
	for &f in p.fields {
		if f.mode == .Filter {
			return &f
		}
	}
	return nil
}

pane_query :: proc(p: ^Pane) -> ^PaneField {
	for &f in p.fields {
		if f.mode == .Query {
			return &f
		}
	}
	return nil
}

pane_count :: proc(p: ^Pane) -> int {
	return len(p.list.matches) if pane_filter(p) != nil else len(p.list.items)
}

pane_item_index :: proc(p: ^Pane, i: int) -> int {
	return p.list.matches[i] if pane_filter(p) != nil else i
}

pane_item_key :: proc(it: PaneItem) -> string {
	return it.key if it.key != "" else it.label
}

pane_selected_key :: proc(p: ^Pane) -> string {
	if pane_count(p) == 0 {
		return ""
	}
	return pane_item_key(p.list.items[pane_item_index(p, p.list.sel)])
}

pane_hint :: proc(p: ^Pane) -> string {
	return p.list.hint if p.list.hint != "" else p.list.empty
}

pane_prompt :: proc(f: ^PaneField) -> string {
	return f.prompt if f.prompt != "" else "> "
}

pane_refilter :: proc(p: ^Pane) {
	f := pane_filter(p)
	if f == nil {
		return
	}
	labels := make([]string, len(p.list.items), context.temp_allocator)
	for it, i in p.list.items {
		labels[i] = it.label
	}
	fz := fuzzy_begin(labels)
	clear(&p.list.matches)
	for idx in fuzzy_rank(&fz, textfield_str(&f.field)) {
		append(&p.list.matches, idx)
	}
	p.list.sel, p.list.scroll, p.list.anchor, p.list.moved = 0, 0, nil, false
}

pane_marks :: proc(p: ^Pane) -> (sel, anchor: int) {
	sel, anchor = -1, -1
	if pane_count(p) > 0 {
		sel = pane_item_index(p, p.list.sel)
	}
	if a, ok := p.list.anchor.?; ok {
		anchor = pane_item_index(p, a)
	}
	return
}

// a full re-rank per call is O(n log n); fine for the small lists that change under a filter
pane_refilter_keep :: proc(p: ^Pane, rows, sel, anchor: int) {
	moved, scroll := p.list.moved, p.list.scroll
	pane_refilter(p)
	for m, i in p.list.matches {
		if m == sel {
			p.list.sel = i
		}
		if m == anchor {
			p.list.anchor = i
		}
	}
	p.list.moved, p.list.scroll = moved, scroll
	pane_scroll_fit(p, rows)
}

pane_scroll_fit :: proc(p: ^Pane, rows: int) {
	if p.list.sel < p.list.scroll {
		p.list.scroll = p.list.sel
	}
	if rows > 0 && p.list.sel >= p.list.scroll + rows {
		p.list.scroll = p.list.sel - rows + 1
	}
}

pane_select :: proc(p: ^Pane, i, rows: int) {
	n := pane_count(p)
	if n == 0 {
		return
	}
	p.list.sel = clamp(i, 0, n - 1)
	pane_scroll_fit(p, rows)
}

pane_restore :: proc(p: ^Pane, rows: int) {
	if p.list.restore == "" {
		return
	}
	for i in 0 ..< pane_count(p) {
		if pane_item_key(p.list.items[pane_item_index(p, i)]) == p.list.restore {
			p.list.sel = i
			p.list.scroll = max(0, i - rows / 2)
			p.list.moved = true
			pane_scroll_fit(p, rows)
			delete(p.list.restore)
			p.list.restore = ""
			return
		}
	}
}

pane_field_changed :: proc(editor: ^Editor, p: ^Pane, f: ^PaneField) {
	p.accept = false
	delete(p.list.restore)
	p.list.restore = ""
	switch f.mode {
	case .Filter:
		pane_refilter(p)
	case .Query:
		p.query_due = true
		p.query_at = time.tick_add(time.tick_now(), PANE_QUERY_DEBOUNCE_MS * time.Millisecond)
	case .Path:
		pane_list_load(editor, p)
	case .Input:
	}
}

pane_preview_sync :: proc(editor: ^Editor, p: ^Pane) {
	if !p.auto_preview {
		return
	}
	g := pane_geom(editor, p)
	path, row := "", 0
	if g.has_preview && pane_count(p) > 0 {
		it := p.list.items[pane_item_index(p, p.list.sel)]
		path, row = it.path, it.row
	}
	if path == "" {
		if preview_loaded(&p.preview) {
			preview_reset(&p.preview)
		}
		return
	}
	if preview_loaded(&p.preview) && p.preview.path == path && p.preview.focus == row {
		return
	}
	preview_set_file(&p.preview, path, row, g.preview.h)
}

PaneGeom :: struct {
	box, inner:                Rect,
	title_y, footer_y:         int,
	field_x, field_y, field_w: int,
	text, list, preview:       Rect,
	has_preview:               bool,
	seps:                      [3]int,
	nsep:                      int,
	left_sep:                  int,
	div_x:                     int,
}

pane_geom_sep :: proc(g: ^PaneGeom, y: int) {
	g.seps[g.nsep] = y
	g.nsep += 1
}

pane_geom :: proc(editor: ^Editor, p: ^Pane) -> (g: PaneGeom) {
	g.title_y, g.footer_y, g.left_sep = -1, -1, -1
	nf := len(p.fields)
	if p.place == .Center {
		n := pane_count(p)
		rows := min(n, PALETTE_MAX_ROWS) if p.size == .Palette else n
		if n == 0 && pane_hint(p) != "" {
			rows = 1
		}
		head := (1 if p.title != "" else 0) + nf + len(p.text)
		sep := head > 0 && p.has_list
		w := PALETTE_WIDTH
		if p.size == .Dialog {
			w = visual_width(transmute([]u8)p.title)
			for l in p.text {
				w = max(w, visual_width(transmute([]u8)l.text))
			}
			for it in p.list.items {
				w = max(w, visual_width(transmute([]u8)it.label))
			}
			w = min(w + 2, int(tb2.width()) - 4)
		}
		g.box = pane_center(editor, w, head + rows + (1 if sep else 0) + (2 if len(p.footer) > 0 else 0))
		g.inner = {g.box.x + 1, g.box.y + 1, g.box.w - 2, g.box.h - 2}
		y := g.inner.y
		if p.title != "" {
			g.title_y = y
			y += 1
		}
		g.field_x, g.field_y, g.field_w = g.inner.x + 1, y, g.inner.w - 2
		y += nf
		g.text = {g.inner.x + 1, y, g.inner.w - 2, len(p.text)}
		y += len(p.text)
		if sep {
			pane_geom_sep(&g, y)
			y += 1
		}
		g.list = {g.inner.x, y, g.inner.w, rows}
		if len(p.footer) > 0 {
			pane_geom_sep(&g, y + rows)
			g.footer_y = y + rows + 1
		}
		g.div_x = g.inner.x + g.inner.w
		return
	}
	split := p.place == .Split && p.auto_preview
	lay := overlay_layout(editor, .Code if split else .None)
	g.box, g.inner = lay.box, lay.inner
	y := g.inner.y
	bottom := g.inner.y + g.inner.h
	if p.title != "" {
		g.title_y = y
		pane_geom_sep(&g, y + 1)
		y += 2
	}
	if len(p.footer) > 0 {
		g.footer_y = bottom - 1
		pane_geom_sep(&g, bottom - 2)
		bottom -= 2
	}
	g.div_x = g.inner.x + lay.left_w
	if split {
		g.has_preview = lay.preview
		g.preview = {lay.right_x, y, lay.right_w, max(0, bottom - y)}
	}
	g.field_x, g.field_y = g.inner.x + 1, y
	g.field_w = lay.left_w - 1 if p.place == .Split else g.inner.w - 2
	y += nf
	if nf > 0 {
		if p.place == .Split {
			g.left_sep = y
		} else {
			pane_geom_sep(&g, y)
		}
		y += 1
	}
	if p.has_list {
		g.list = {g.inner.x, y, lay.left_w, max(0, bottom - y)}
	} else {
		g.text = {g.inner.x + 1, y, g.inner.w - 2, max(0, bottom - y)}
	}
	return
}

pane_count_text :: proc(p: ^Pane) -> string {
	n := pane_count(p)
	if n == 0 {
		return ""
	}
	return fmt.tprintf("%d+" if p.list.more else "%d", n)
}

pane_shortcut :: proc(editor: ^Editor, name: string) -> string {
	if s := command_shortcut(name); s != "" {
		return s
	}
	for cmd in editor.plugins.commands {
		if cmd.name == name {
			return cmd.shortcut
		}
	}
	return ""
}

pane_footer_text :: proc(editor: ^Editor, p: ^Pane) -> string {
	parts := make([]string, len(p.footer), context.temp_allocator)
	for h, i in p.footer {
		parts[i] = h.label
		if key := pane_shortcut(editor, h.cmd); h.cmd != "" && key != "" {
			parts[i] = fmt.tprintf("%s %s", key, h.label)
		}
	}
	return strings.join(parts, "  ", context.temp_allocator)
}

pane_render_field :: proc(p: ^Pane, g: PaneGeom, i: int, count: string) {
	f := &p.fields[i]
	y := g.field_y + i
	w := g.field_w
	if f.count && count != "" {
		pane_text(g.div_x - len(count), y, len(count), count, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
		w = max(1, w - len(count) - 1)
	}
	overlay_prompt_render(g.field_x, y, w, &f.field, pane_prompt(f))
}

pane_render :: proc(editor: ^Editor, p: ^Pane) {
	g := pane_geom(editor, p)
	pane_draw_box(g.box)
	for y in g.seps[:g.nsep] {
		pane_hline(g.box, y)
	}
	if g.title_y >= 0 {
		pane_text(g.inner.x + 1, g.title_y, g.inner.w - 2, p.title, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	}
	if g.footer_y >= 0 {
		pane_text(g.inner.x + 1, g.footer_y, g.inner.w - 2, pane_footer_text(editor, p), COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	if g.has_preview {
		preview_render(&p.preview, g.preview.x + 1, g.preview.y, g.preview.w - 1, g.preview.h)
		top, bottom := g.preview.y - 1, g.preview.y + g.preview.h
		for y in top + 1 ..< bottom {
			tb2.set_cell(i32(g.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
		}
		tb2.set_cell(i32(g.div_x), i32(top), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
		tb2.set_cell(i32(g.div_x), i32(bottom), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	if g.left_sep >= 0 {
		tb2.set_cell(i32(g.box.x), i32(g.left_sep), '├', COLOR_PANE_BORDER, COLOR_PANE_BG)
		for x in g.inner.x ..< g.div_x {
			tb2.set_cell(i32(x), i32(g.left_sep), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
		}
		tb2.set_cell(i32(g.div_x), i32(g.left_sep), '┤', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}

	p.scroll = clamp(p.scroll, 0, max(0, len(p.text) - g.text.h))
	for i in 0 ..< g.text.h {
		if p.scroll + i >= len(p.text) {
			break
		}
		l := p.text[p.scroll + i]
		fg := COLOR_PANE_FG
		if c, ok := g_theme_colors[l.color]; ok && l.color != "" {
			fg = c
		}
		pane_text(g.text.x, g.text.y + i, g.text.w, l.text, fg, COLOR_PANE_BG)
	}
	if p.place != .Center {
		pane_draw_scrollbar(g.box.x + g.box.w - 1, g.text.y, g.text.h, p.scroll, len(p.text))
	}

	n := pane_count(p)
	lw := g.list.w - (1 if p.place == .Split else 2)
	if hint := pane_hint(p); n == 0 && hint != "" && g.list.h > 0 {
		pane_text(g.list.x + 1, g.list.y, lw, hint, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	for r in 0 ..< g.list.h {
		i := p.list.scroll + r
		if i >= n {
			break
		}
		it := p.list.items[pane_item_index(p, i)]
		y := g.list.y + r
		fg, bg, dfg := COLOR_PANE_FG, COLOR_PANE_BG, COLOR_PANE_SHORTCUT_FG
		if overlay_row_selected(i, p.list.sel, p.list.anchor if p.list.multi else nil) {
			fg, bg, dfg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG, COLOR_PANE_SEL_FG
			pane_fill_row(g.list.x, y, g.list.w, fg, bg)
		}
		pane_text(g.list.x + 1, y, lw, it.label, fg, bg)
		if detail := list_item_detail(editor, p, it); detail != "" {
			dw := visual_width(transmute([]u8)detail)
			pane_text(g.list.x + g.list.w - 1 - dw, y, dw, detail, dfg, bg)
		}
	}
	if p.has_list {
		pane_draw_scrollbar(g.div_x, g.list.y, g.list.h, p.list.scroll, n)
	}

	if len(p.fields) == 0 {
		tb2.hide_cursor()
		return
	}
	count := pane_count_text(p)
	for i in 0 ..< len(p.fields) {
		if i != p.focus {
			pane_render_field(p, g, i, count)
		}
	}
	pane_render_field(p, g, p.focus, count)
}

pane_key :: proc(editor: ^Editor, p: ^Pane, ev: tb2.Event) -> PaneAction {
	if (p.toggle != 0 && plugin_command_id_matches(editor, p.toggle, ev)) || (p.chord != "" && command_matches(ev, p.chord)) {
		return .Close
	}
	if len(p.fields) > 0 && p.fields[p.focus].mode == .Path && pane_path_key(editor, p, &p.fields[p.focus], ev) {
		return .None
	}
	#partial switch ev.key {
	case .Esc:
		return .Close
	case .Enter:
		if !p.ctx.lua && p.has_list && pane_count(p) == 0 {
			return .None
		}
		return .Activate
	case .Arrow_Up, .Arrow_Down, .Pgup, .Pgdn:
		g := pane_geom(editor, p)
		page := g.list.h if p.has_list else g.text.h
		d := 1
		#partial switch ev.key {
		case .Arrow_Up:
			d = -1
		case .Pgup:
			d = -max(1, page)
		case .Pgdn:
			d = max(1, page)
		}
		if p.has_list {
			if pane_count(p) > 0 {
				if p.list.multi && ev_shift(ev) && (ev.key == .Arrow_Up || ev.key == .Arrow_Down) {
					if p.list.anchor == nil {
						p.list.anchor = p.list.sel
					}
				} else {
					p.list.anchor = nil
				}
				delete(p.list.restore)
				p.list.restore = ""
				p.list.moved = true
				pane_select(p, p.list.sel + d, g.list.h)
			}
			return .None
		}
		if len(p.fields) == 0 {
			overlay_scroll_by(&p.scroll, d, len(p.text), g.text.h)
			return .None
		}
	case .Tab:
		if len(p.fields) > 1 {
			p.focus = (p.focus + 1) % len(p.fields)
			return .None
		}
	}
	if len(p.fields) > 0 {
		f := &p.fields[p.focus]
		if textfield_key(&f.field, ev) {
			pane_field_changed(editor, p, f)
		}
	}
	return .None
}

pane_mouse :: proc(editor: ^Editor, p: ^Pane, ev: tb2.Event) -> PaneAction {
	g := pane_geom(editor, p)
	n := pane_count(p)
	#partial switch ev.key {
	case .Mouse_Wheel_Up, .Mouse_Wheel_Down:
		d := -WHEEL_SCROLL_LINES if ev.key == .Mouse_Wheel_Up else WHEEL_SCROLL_LINES
		if g.has_preview && mouse_in_rect(ev, g.preview) {
			preview_scroll_by(&p.preview, d, g.preview.h)
		} else if p.has_list {
			overlay_scroll_by(&p.list.scroll, d, n, g.list.h)
		} else {
			overlay_scroll_by(&p.scroll, d, len(p.text), g.text.h)
		}
		return .None
	case .Mouse_Left:
	case:
		return .None
	}
	motion := ev_motion(ev)
	for &f, i in p.fields {
		y := g.field_y + i
		if !motion && int(ev.y) == y && int(ev.x) >= g.field_x && int(ev.x) < g.field_x + g.field_w {
			p.focus = i
			overlay_prompt_mouse(&f.field, g.field_x, y, g.field_w, ev, pane_prompt(&f))
			return .None
		}
	}
	if off := overlay_row_off(ev, g.list); off >= 0 {
		if i := p.list.scroll + off; i < n {
			p.list.sel, p.list.anchor, p.list.moved = i, nil, true
			delete(p.list.restore)
			p.list.restore = ""
			if !motion && overlay_double_click(editor, i) {
				if f := pane_path(p); f != nil {
					pane_path_complete(editor, p, f)
					return .None
				}
				return .Activate
			}
		}
		return .None
	}
	if len(p.fields) > 0 && (motion || (p.place == .Center && mouse_in_rect(ev, g.box))) {
		f := &p.fields[p.focus]
		fe := ev
		fe.y = i32(g.field_y + p.focus)
		overlay_prompt_mouse(&f.field, g.field_x, g.field_y + p.focus, g.field_w, fe, pane_prompt(f))
		return .None
	}
	if !mouse_in_rect(ev, g.box) && !motion {
		return .Close
	}
	return .None
}

pane_paste :: proc(editor: ^Editor, p: ^Pane, text: string) {
	if len(p.fields) == 0 {
		return
	}
	f := &p.fields[p.focus]
	if textfield_insert_flat(&f.field, text) {
		pane_field_changed(editor, p, f)
	}
}
