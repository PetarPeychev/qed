package main


import "core:fmt"
import vmem "core:mem/virtual"
import "core:slice"
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
PANE_MIN_WIDTH :: 20

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
	Tree,
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
	prompt, hint: string,
	mode:         PaneFieldMode,
	count:        bool,
	esc_clears:   bool,
	using field:  TextField,
}

PaneItem :: struct {
	label, detail, path, key: string,
	row, col:                 int,
	id, buf:                  u64,
	color:                    string,
	cells:                    []string,
	depth:                    int,
	dir:                      bool,
}

PaneLine :: struct {
	text, color: string,
}

PaneHint :: struct {
	label, cmd: string,
}

PaneChip :: struct {
	label, cmd: string,
	on:         bool,
}

PaneTab :: struct {
	label, cmd: string,
}

PaneMark :: struct {
	bar, fg, suffix: string,
	added, removed:  int,
	sizes, dim:      bool,
}

PaneList :: struct {
	items:    [dynamic]PaneItem,
	matches:  [dynamic]int,
	filtered: bool,
	stamp:    u64,
	follow:   bool,
	stick:    bool,
	sel_bg:   bool,
	sel:      int,
	scroll:  int,
	anchor:  Maybe(int),
	multi:   bool,
	max:     int,
	more:    bool,
	empty:   string,
	hint:    string,
	restore: string,
	sort:     bool,
	moved:    bool,
	tree:     bool,
	expanded: map[string]bool,
	columns:  []PaneColumn,
	source:   ListSource,
}

PaneHandler :: proc(editor: ^Editor, p: ^Pane)

PaneBackdrop :: enum {
	None,
	Dim,
	Blank,
}

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
	md:           string,
	has_md:       bool,
	md_w:         int,
	md_lines:     []MdLine,
	md_arena:     vmem.Arena,
	md_job:       ^PaneMdJob,
	scroll:       int,
	max_width:    int,
	list:         PaneList,
	has_list:     bool,
	auto_preview: bool,
	body_preview: bool,
	preview:      Preview,
	preview_buf:  u64,
	footer:       []PaneHint,
	chips:        []PaneChip,
	tabs:         []PaneTab,
	tab:          int,
	marks:        map[string]PaneMark,
	marks_plain:  bool,
	marks_arena:  vmem.Arena,
	footer_field: PaneField,
	footer_input: bool,
	refill_due:   bool,
	refill_at:    time.Tick,
	preview_due:  bool,
	preview_at:   time.Tick,
	preview_key:  string,
	preview_off:  bool,
	scope:        string,
	keep:         bool,
	jump_closes:  bool,
	toggle:       u64,
	chord:        string,
	query_due:    bool,
	query_at:     time.Tick,
	accept:       bool,
	landed:       bool,
	notified:     int,
	notified_key: string,
	backdrop:     PaneBackdrop,
	on:           struct {
		activate, close, tab: PaneHandler,
		link:                 proc(editor: ^Editor, p: ^Pane, target: string) -> bool,
		footer:               proc(editor: ^Editor, p: ^Pane) -> string,
		submit:               proc(editor: ^Editor, p: ^Pane, text: string, ok: bool),
		expand:               proc(editor: ^Editor, p: ^Pane, path: string, on: bool),
	},
}

PaneSaved :: struct {
	id:       string,
	texts:    []string,
	key:      string,
	scroll:   int,
	expanded: map[string]bool,
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
	p.md = strings.clone(spec.md)
	p.md_w, p.md_lines, p.md_arena, p.md_job = -1, nil, {}, nil
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
	p.chips = nil
	pane_chips_set(&p, spec.chips)
	p.tabs = nil
	pane_tabs_set(&p, spec.tabs)
	p.marks = {}
	p.list.expanded = {}
	p.list.columns = slice.clone(spec.list.columns)
	p.footer_field = {anchor = -1}
	p.preview_key = ""
	p.notified_key = ""
	p.scope = strings.clone(spec.scope)
	p.fields = make([]PaneField, len(spec.fields))
	for f, i in spec.fields {
		p.fields[i].prompt = strings.clone(f.prompt)
		p.fields[i].hint = strings.clone(f.hint)
		p.fields[i].mode = f.mode
		p.fields[i].count = f.count
		p.fields[i].esc_clears = f.esc_clears
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
	delete(it.color)
	for c in it.cells {
		delete(c)
	}
	delete(it.cells)
}

pane_item_clone :: proc(it: PaneItem) -> PaneItem {
	out := it
	out.label, out.detail, out.path = strings.clone(it.label), strings.clone(it.detail), strings.clone(it.path)
	out.key, out.color = strings.clone(it.key), strings.clone(it.color)
	out.cells = nil
	if len(it.cells) > 0 {
		out.cells = make([]string, len(it.cells))
		for c, i in it.cells {
			out.cells[i] = strings.clone(c)
		}
	}
	return out
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
	pane_md_reset(p)
	delete(p.md)
	vmem.arena_destroy(&p.md_arena)
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
	pane_chips_set(p, nil)
	pane_tabs_set(p, nil)
	delete(p.marks)
	vmem.arena_destroy(&p.marks_arena)
	walk_set_clear(&p.list.expanded)
	delete(p.list.expanded)
	delete(p.list.columns)
	textfield_destroy(&p.footer_field.field)
	delete(p.footer_field.prompt)
	delete(p.preview_key)
	delete(p.notified_key)
	delete(p.scope)
	for &f in p.fields {
		delete(f.prompt)
		delete(f.hint)
		textfield_destroy(&f.field)
	}
	delete(p.fields)
	preview_destroy(&p.preview)
}

pane_chips_set :: proc(p: ^Pane, chips: []PaneChip) {
	for c in p.chips {
		delete(c.label)
		delete(c.cmd)
	}
	delete(p.chips)
	p.chips = make([]PaneChip, len(chips))
	for c, i in chips {
		p.chips[i] = {strings.clone(c.label), strings.clone(c.cmd), c.on}
	}
}

pane_tabs_set :: proc(p: ^Pane, tabs: []PaneTab) {
	for t in p.tabs {
		delete(t.label)
		delete(t.cmd)
	}
	delete(p.tabs)
	p.tabs = make([]PaneTab, len(tabs))
	for t, i in tabs {
		p.tabs[i] = {strings.clone(t.label), strings.clone(t.cmd)}
	}
	p.tab = clamp(p.tab, 0, max(0, len(tabs) - 1))
}

// keys and suffixes live in the pane's arena: a 50k-mark push is a few block allocations, not 50k;
// bar and fg are interned theme keys (Plugins.colors) that outlive every pane
pane_marks_clear :: proc(p: ^Pane) {
	clear(&p.marks)
	vmem.arena_free_all(&p.marks_arena)
}

pane_mark_set :: proc(p: ^Pane, key: string, m: PaneMark) {
	a := vmem.arena_allocator(&p.marks_arena)
	c := PaneMark{m.bar, m.fg, strings.clone(m.suffix, a), m.added, m.removed, m.sizes, m.dim}
	if _, ok := p.marks[key]; ok {
		p.marks[key] = c
	} else {
		p.marks[strings.clone(key, a)] = c
	}
}

pane_mark_drop :: proc(p: ^Pane, key: string) {
	delete_key(&p.marks, key)
}

pane_footer_input :: proc(p: ^Pane, prompt, text: string) {
	delete(p.footer_field.prompt)
	p.footer_field.prompt = strings.clone(prompt)
	p.footer_field.mode = .Input
	textfield_set(&p.footer_field.field, text)
	p.footer_input = true
}

pane_footer_end :: proc(editor: ^Editor, p: ^Pane, ok: bool) {
	p.footer_input = false
	if p.on.submit != nil {
		p.on.submit(editor, p, textfield_str(&p.footer_field.field), ok)
	}
}

pane_tab_set :: proc(editor: ^Editor, p: ^Pane, i: int) {
	if i == p.tab || i < 0 || i >= len(p.tabs) {
		return
	}
	p.tab = i
	if p.on.tab != nil {
		p.on.tab(editor, p)
	}
}

pane_tab_at :: proc(p: ^Pane, g: PaneGeom, cx: int) -> int {
	x := g.inner.x + 1
	for t, i in p.tabs {
		if i > 0 {
			x += 3
		}
		w := visual_width(transmute([]u8)t.label)
		if cx >= x && cx < x + w {
			return i
		}
		x += w
	}
	return -1
}

pane_cmd_matches :: proc(editor: ^Editor, ev: tb2.Event, name: string) -> bool {
	if command_matches(ev, name) {
		return true
	}
	for cmd in editor.plugins.commands {
		if cmd.name == name && plugin_command_matches(cmd, ev) {
			return true
		}
	}
	return false
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
	s := s
	delete(s.id)
	for t in s.texts {
		delete(t)
	}
	delete(s.texts)
	delete(s.key)
	walk_set_clear(&s.expanded)
	delete(s.expanded)
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
	s.key = strings.clone(pane_selected_key(editor, p))
	s.scroll = p.scroll
	if p.list.tree {
		walk_set_clear(&s.expanded)
		for key, on in p.list.expanded {
			s.expanded[strings.clone(key)] = on
		}
	}
}

pane_stack_dispatch :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	p := pane_focus(editor)
	if p == nil {
		return false
	}
	if ev.type == .Key {
		for parent := p.parent; parent != 0; {
			i := pane_index(editor, parent)
			if i < 0 {
				break
			}
			if q := &editor.panes[i]; q.chord != "" && command_matches(ev, q.chord) {
				pane_end(editor, q.handle, false)
				pane_stack_fit(editor, false)
				return true
			}
			parent = editor.panes[i].parent
		}
	}
	if p.has_list {
		pane_list_fit(editor, p, pane_geom(editor, p).list.h)
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
	if action == .Activate && p.list.tree && pane_tree_enter(editor, p) {
		action = .None
	}
	if action == .Activate && !p.ctx.lua && p.on.activate == nil {
		action = .None
	}
	if action == .Activate && (p.ctx.lua || p.keep) {
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

pane_count :: proc(editor: ^Editor, p: ^Pane) -> int {
	return len(p.list.matches) if p.list.filtered else list_count(editor, p)
}

pane_item_index :: proc(p: ^Pane, i: int) -> int {
	return p.list.matches[i] if p.list.filtered else i
}

pane_item_key :: proc(it: PaneItem) -> string {
	return it.key if it.key != "" else it.label
}

pane_selected_key :: proc(editor: ^Editor, p: ^Pane) -> string {
	if pane_count(editor, p) == 0 {
		return ""
	}
	return pane_item_key(list_item(editor, p, pane_item_index(p, p.list.sel)))
}

pane_hint :: proc(p: ^Pane) -> string {
	return p.list.hint if p.list.hint != "" else p.list.empty
}

pane_prompt :: proc(f: ^PaneField) -> string {
	return f.prompt if f.prompt != "" else "> "
}

pane_refilter :: proc(editor: ^Editor, p: ^Pane) {
	if p.list.source.kind == .Walk {
		list_walk_fill(editor, p)
		return
	}
	clear(&p.list.matches)
	p.list.filtered = false
	p.list.sel, p.list.scroll, p.list.anchor, p.list.moved = 0, 0, nil, false
	p.list.stamp = list_stamp(editor, p)
	f := pane_filter(p)
	if f == nil {
		return
	}
	if row, ok := list_exact(editor, p); ok {
		append(&p.list.matches, row)
		p.list.filtered = true
		return
	}
	query := textfield_str(&f.field)
	if query == "" {
		return
	}
	entries := make([dynamic]ScoreIdx, 0, 64, context.temp_allocator)
	for i in 0 ..< list_count(editor, p) {
		if score, ok := fuzzy_match(query, list_text(editor, p, i)); ok {
			append(&entries, ScoreIdx{score, i})
		}
	}
	if list_ranked(p.list.source.kind) {
		fuzzy_sort(entries[:])
	}
	for e in entries {
		append(&p.list.matches, e.idx)
	}
	p.list.filtered = true
}

pane_marks :: proc(editor: ^Editor, p: ^Pane) -> (sel, anchor: int) {
	sel, anchor = -1, -1
	if pane_count(editor, p) > 0 {
		sel = pane_item_index(p, p.list.sel)
	}
	if a, ok := p.list.anchor.?; ok {
		anchor = pane_item_index(p, a)
	}
	return
}

// a full re-rank per call is O(n log n); fine for the small lists that change under a filter
pane_refilter_keep :: proc(editor: ^Editor, p: ^Pane, rows, sel, anchor: int) {
	moved, scroll := p.list.moved, p.list.scroll
	pane_refilter(editor, p)
	if !p.list.filtered {
		p.list.sel = max(0, sel)
		if anchor >= 0 {
			p.list.anchor = anchor
		}
	}
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

// live sources change between frames: edits, disk reloads, a closed buffer, ring eviction
pane_list_fit :: proc(editor: ^Editor, p: ^Pane, rows: int) {
	if stamp := list_stamp(editor, p); stamp != p.list.stamp {
		src := &p.list.source
		sel, anchor := pane_marks(editor, p)
		if src.kind == .Walk {
			list_walk_fill(editor, p)
		} else if p.list.filtered || stamp == 0 {
			pane_refilter_keep(editor, p, rows, sel, anchor)
		}
		p.list.stamp = stamp
		if src.kind == .Log {
			list_log_rows(editor, src)
			d := src.evicted
			src.evicted = 0
			p.list.sel, p.list.scroll = max(0, p.list.sel - d), max(0, p.list.scroll - d)
			if a, ok := p.list.anchor.?; ok {
				p.list.anchor = max(0, a - d)
			}
		}
	}
	n := pane_count(editor, p)
	if a, ok := p.list.anchor.?; ok {
		p.list.anchor = clamp(a, 0, n - 1) if n > 0 else nil
	}
	if p.list.follow && p.list.stick {
		p.list.sel = max(0, n - 1)
		p.list.scroll = max(0, n - rows)
		return
	}
	p.list.sel = clamp(p.list.sel, 0, max(0, n - 1))
	p.list.scroll = clamp(p.list.scroll, 0, max(0, n - rows))
}

pane_select :: proc(editor: ^Editor, p: ^Pane, i, rows: int) {
	n := pane_count(editor, p)
	if n == 0 {
		return
	}
	p.list.sel = clamp(i, 0, n - 1)
	p.list.stick = p.list.sel == n - 1 && p.list.anchor == nil
	pane_scroll_fit(p, rows)
}

pane_restore :: proc(editor: ^Editor, p: ^Pane, rows: int) {
	if p.list.restore == "" {
		return
	}
	for i in 0 ..< pane_count(editor, p) {
		if pane_item_key(list_item(editor, p, pane_item_index(p, i))) == p.list.restore {
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
		if p.list.source.kind == .Walk {
			p.refill_due = true
			p.refill_at = time.tick_add(time.tick_now(), WALK_FILTER_DEBOUNCE_MS * time.Millisecond)
		} else {
			pane_refilter(editor, p)
		}
	case .Query:
		p.query_due = true
		p.query_at = time.tick_add(time.tick_now(), PANE_QUERY_DEBOUNCE_MS * time.Millisecond)
	case .Path:
		pane_list_load(editor, p)
	case .Input:
	}
}

pane_preview_item :: proc(editor: ^Editor, p: ^Pane) -> (it: PaneItem, g: PaneGeom) {
	g = pane_geom(editor, p)
	if g.has_preview && !p.preview_off && pane_count(editor, p) > 0 {
		it = list_item(editor, p, pane_item_index(p, p.list.sel))
	}
	return
}

// a walk list debounces its preview: a held arrow must not load every file it passes
pane_preview_sync :: proc(editor: ^Editor, p: ^Pane) {
	if !p.auto_preview {
		return
	}
	it, _ := pane_preview_item(editor, p)
	key := fmt.tprintf("%s\x00%d\x00%d", it.path, it.buf, it.row)
	if key == p.preview_key {
		return
	}
	delete(p.preview_key)
	p.preview_key = strings.clone(key)
	if p.list.source.kind == .Walk && it.path != "" {
		p.preview_due = true
		p.preview_at = time.tick_add(time.tick_now(), WALK_PREVIEW_DEBOUNCE_MS * time.Millisecond)
		return
	}
	pane_preview_load(editor, p)
}

pane_preview_load :: proc(editor: ^Editor, p: ^Pane) {
	p.preview_due = false
	if p.preview_off {
		return
	}
	it, g := pane_preview_item(editor, p)
	b, _ := api_buf_find(editor, it.buf)
	if it.dir || (it.path == "" && b == nil) {
		if preview_loaded(&p.preview) {
			preview_reset(&p.preview)
		}
		p.preview_buf = 0
		return
	}
	p.preview_buf = it.buf
	if b != nil {
		preview_set_buffer(&p.preview, b, it.row, g.preview.h)
	} else {
		preview_set_file(&p.preview, it.path, it.row, g.preview.h)
	}
}

pane_stack_pending :: proc(editor: ^Editor) -> bool {
	for &p in editor.panes {
		if (p.refill_due || p.preview_due || p.md_job != nil) && pane_live(editor, &p) {
			return true
		}
	}
	return false
}

pane_stack_pump :: proc(editor: ^Editor, force := false) -> (redraw: bool) {
	now := time.tick_now()
	for i := 0; i < len(editor.panes); i += 1 {
		p := &editor.panes[i]
		if !pane_live(editor, p) {
			continue
		}
		if p.refill_due && (force || plugin_tick_due(p.refill_at, now)) {
			list_walk_fill(editor, p)
			pane_preview_sync(editor, p)
			redraw = true
		}
		if p.preview_due && (force || plugin_tick_due(p.preview_at, now)) {
			pane_preview_load(editor, p)
			redraw = true
		}
		if p.md_job != nil && pane_md_step(p, md_slice_ms) {
			redraw = true
		}
	}
	return
}

pane_md_busy :: proc(editor: ^Editor) -> bool {
	for &p in editor.panes {
		if p.md_job != nil && pane_live(editor, &p) {
			return true
		}
	}
	return false
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
		n := pane_count(editor, p)
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
		if p.max_width > 0 {
			w = min(w, p.max_width - 2)
		}
		g.box = pane_center(editor, w, head + rows + (1 if sep else 0) + (2 if pane_has_footer(p) else 0))
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
		if pane_has_footer(p) {
			pane_geom_sep(&g, y + rows)
			g.footer_y = y + rows + 1
		}
		g.div_x = g.inner.x + g.inner.w
		return
	}
	split := p.place == .Split && p.auto_preview
	lay := overlay_layout(editor, .FileTree if split && p.size == .Tree else .Code if split else .None)
	if p.place == .Full && p.max_width > 0 && lay.box.w > p.max_width {
		lay.box.x += (lay.box.w - p.max_width) / 2
		lay.box.w = p.max_width
		lay.inner = {lay.box.x + 1, lay.box.y + 1, lay.box.w - 2, lay.box.h - 2}
		lay.left_w = lay.inner.w
	}
	g.box, g.inner = lay.box, lay.inner
	y := g.inner.y
	bottom := g.inner.y + g.inner.h
	if p.title != "" || len(p.tabs) > 0 {
		g.title_y = y
		pane_geom_sep(&g, y + 1)
		y += 2
	}
	if pane_has_footer(p) {
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

pane_has_footer :: proc(p: ^Pane) -> bool {
	return len(p.footer) > 0 || len(p.chips) > 0 || p.on.footer != nil
}

pane_count_text :: proc(editor: ^Editor, p: ^Pane) -> string {
	n := pane_count(editor, p)
	if n == 0 || (p.list.source.kind == .Walk && !p.list.source.filtering) {
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

pane_hint_text :: proc(editor: ^Editor, label, cmd: string) -> string {
	if key := pane_shortcut(editor, cmd); cmd != "" && key != "" {
		return fmt.tprintf("%s %s", key, label)
	}
	return label
}

pane_footer_text :: proc(editor: ^Editor, p: ^Pane) -> string {
	parts := make([]string, len(p.footer), context.temp_allocator)
	for h, i in p.footer {
		parts[i] = pane_hint_text(editor, h.label, h.cmd)
	}
	return strings.join(parts, "  ", context.temp_allocator)
}

pane_chips_layout :: proc(editor: ^Editor, p: ^Pane, g: PaneGeom) -> (xs: []int, hints_w: int) {
	xs = make([]int, len(p.chips), context.temp_allocator)
	if len(p.chips) == 0 {
		return xs, g.inner.w - 2
	}
	total := 0
	for c, i in p.chips {
		total += visual_width(transmute([]u8)pane_hint_text(editor, c.label, c.cmd)) + (2 if i > 0 else 0)
	}
	x := g.inner.x + g.inner.w - 1 - total
	hints_w = max(0, x - (g.inner.x + 1) - 1)
	for c, i in p.chips {
		xs[i] = x
		x += visual_width(transmute([]u8)pane_hint_text(editor, c.label, c.cmd)) + 2
	}
	return
}

pane_footer_rect :: proc(p: ^Pane, g: PaneGeom) -> (x, w: int) {
	x = g.inner.x + 1 + visual_width(transmute([]u8)p.footer_field.prompt)
	return x, g.inner.x + g.inner.w - 1 - x
}

pane_render_footer :: proc(editor: ^Editor, p: ^Pane, g: PaneGeom) {
	if p.footer_input {
		label := p.footer_field.prompt
		pane_text(g.inner.x + 1, g.footer_y, visual_width(transmute([]u8)label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
		return
	}
	if p.on.footer != nil {
		if s := p.on.footer(editor, p); s != "" {
			pane_text(g.inner.x + 1, g.footer_y, g.inner.w - 2, s, COLOR_ERROR_FG, COLOR_PANE_BG)
			return
		}
	}
	xs, hints_w := pane_chips_layout(editor, p, g)
	pane_text(g.inner.x + 1, g.footer_y, hints_w, pane_footer_text(editor, p), COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	for c, i in p.chips {
		s := pane_hint_text(editor, c.label, c.cmd)
		pane_text(xs[i], g.footer_y, visual_width(transmute([]u8)s), s, COLOR_PANE_PROMPT_FG if c.on else COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
}

pane_run_command :: proc(editor: ^Editor, p: ^Pane, name: string) {
	for cmd in pane_commands {
		if cmd.scope == p.scope && command_config_name(cmd) == name {
			command_run(editor, cmd)
			return
		}
	}
	for cmd in commands {
		if cmd.name == name {
			command_run(editor, cmd)
			return
		}
	}
	for cmd in editor.plugins.commands {
		if cmd.name == name {
			plugin_command_chord(editor, cmd)
			return
		}
	}
}

pane_render_row :: proc(it: PaneItem, cols: []PaneColumn, x, y, w: int, fg, bg: tb2.Color) {
	if len(cols) == 0 {
		pane_text(x, y, w, it.label, fg, bg)
		return
	}
	cx := x
	for c, i in cols {
		if i >= len(it.cells) || cx >= x + w {
			break
		}
		cw := x + w - cx if c.w == 0 else min(c.w, x + w - cx)
		sw := visual_width(transmute([]u8)it.cells[i])
		off := max(0, cw - sw) if c.right else 0
		pane_text(cx + off, y, cw - off, it.cells[i], fg, bg)
		cx += cw + 2
	}
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
	if f.hint != "" && len(f.text) == 0 {
		pw := visual_width(transmute([]u8)pane_prompt(f))
		pane_text(g.field_x + pw, y, w - pw, f.hint, COLOR_PANE_DIM_FG, COLOR_PANE_BG)
	}
}

pane_render_tabs :: proc(p: ^Pane, g: PaneGeom) {
	x := g.inner.x + 1
	for t, i in p.tabs {
		if i > 0 {
			pane_text(x, g.title_y, 3, " │ ", COLOR_PANE_BORDER, COLOR_PANE_BG)
			x += 3
		}
		w := visual_width(transmute([]u8)t.label)
		pane_text(x, g.title_y, w, t.label, COLOR_PANE_PROMPT_FG if i == p.tab else COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
		x += w
	}
}

pane_mark_dim :: proc(p: ^Pane, path: string) -> bool {
	for q := path; true; {
		if m, ok := p.marks[q]; ok && m.dim {
			return true
		}
		np := path_parent(q)
		if np == q {
			return false
		}
		q = np
	}
	return false
}

pane_tree_label :: proc(p: ^Pane, it: PaneItem) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< it.depth {
		strings.write_string(&sb, "  ")
	}
	if it.dir {
		open := !p.list.source.filtering && pane_tree_expanded(p, it.path)
		strings.write_string(&sb, ICON_TREE_EXPANDED if open else ICON_TREE_COLLAPSED)
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, it.label)
		strings.write_byte(&sb, '/')
	} else {
		strings.write_string(&sb, "  ")
		strings.write_string(&sb, it.label)
	}
	return strings.to_string(sb)
}

pane_tree_unsaved :: proc(editor: ^Editor, it: PaneItem) -> bool {
	if !it.dir {
		idx := editor_find_buffer(editor, it.path)
		return idx >= 0 && editor.buffers[idx].modified
	}
	prefix := strings.concatenate({it.path, "/"}, context.temp_allocator)
	for &b in editor.buffers {
		if b.modified && strings.has_prefix(b.path, prefix) {
			return true
		}
	}
	return false
}

pane_theme_color :: proc(key: string, fallback: tb2.Color) -> tb2.Color {
	if key == "" {
		return fallback
	}
	return g_theme_colors[key] or_else fallback
}

pane_size_paint :: proc(x, y, max_x: int, label: string, bg: tb2.Color) {
	fg := COLOR_GIT_ADD
	for i in 0 ..< len(label) {
		if x + i >= max_x {
			return
		}
		if label[i] == '-' {
			fg = COLOR_GIT_DEL
		}
		tb2.set_cell(i32(x + i), i32(y), rune(label[i]), fg, bg)
	}
}

PANE_SIZES_MIN_LABEL :: 8

pane_render :: proc(editor: ^Editor, p: ^Pane) {
	g := pane_geom(editor, p)
	pane_backdrop(p.backdrop)
	pane_draw_box(g.box)
	for y in g.seps[:g.nsep] {
		pane_hline(g.box, y)
	}
	if g.title_y >= 0 && len(p.tabs) > 0 {
		pane_render_tabs(p, g)
	} else if g.title_y >= 0 {
		pane_text(g.inner.x + 1, g.title_y, g.inner.w - 2, p.title, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	}
	if g.footer_y >= 0 {
		pane_render_footer(editor, p, g)
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

	if p.body_preview {
		preview_ensure(&p.preview, g.text.h)
		preview_render(&p.preview, g.text.x - 1, g.text.y, g.text.w + 1, g.text.h)
		pane_draw_scrollbar(g.box.x + g.box.w - 1, g.text.y, g.text.h, p.preview.scroll, preview_total(&p.preview))
	}
	rows := pane_body_rows(p, g)
	p.scroll = clamp(p.scroll, 0, max(0, rows - g.text.h))
	for i in 0 ..< min(g.text.h, rows - p.scroll) {
		if p.has_md {
			md_draw_line(g.text.x, g.text.y + i, g.text.w, p.md_lines[p.scroll + i], COLOR_PANE_BG)
			continue
		}
		l := p.text[p.scroll + i]
		fg := COLOR_PANE_FG
		if c, ok := g_theme_colors[l.color]; ok && l.color != "" {
			fg = c
		}
		pane_text(g.text.x, g.text.y + i, g.text.w, l.text, fg, COLOR_PANE_BG)
	}
	if p.place != .Center && !p.body_preview {
		pane_draw_scrollbar(g.box.x + g.box.w - 1, g.text.y, g.text.h, p.scroll, rows)
	}

	if p.has_list {
		pane_list_fit(editor, p, g.list.h)
	}
	n := pane_count(editor, p)
	lw := g.list.w - (1 if p.place == .Split else 2)
	if hint := pane_hint(p); n == 0 && hint != "" && g.list.h > 0 {
		pane_text(g.list.x + 1, g.list.y, lw, hint, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	cols := list_columns(editor, p) if n > 0 else nil
	addw, delw := 0, 0
	for r in 0 ..< g.list.h {
		if i := p.list.scroll + r; i < n && len(p.marks) > 0 {
			it := list_item(editor, p, pane_item_index(p, i))
			if m, ok := p.marks[pane_item_key(it)]; ok && m.sizes && !it.dir && !p.marks_plain {
				addw, delw = max(addw, digit_count(m.added)), max(delw, digit_count(m.removed))
			}
		}
	}
	tree := p.list.tree
	current := editor_buffer(editor).path if !editor.welcome && len(editor.buffers) > 0 else ""
	for r in 0 ..< g.list.h {
		i := p.list.scroll + r
		if i >= n {
			break
		}
		it := list_item(editor, p, pane_item_index(p, i))
		y := g.list.y + r
		fg, bg, dfg := COLOR_PANE_FG, COLOR_PANE_BG, COLOR_PANE_SHORTCUT_FG
		if c, ok := g_theme_colors[it.color]; ok && it.color != "" {
			fg = c
		}
		selected := overlay_row_selected(i, p.list.sel, p.list.anchor if p.list.multi else nil)
		if selected {
			bg = COLOR_PANE_SEL_BG
			if !p.list.sel_bg {
				fg, dfg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_FG
			}
			pane_fill_row(g.list.x + (1 if tree else 0), y, g.list.w - (1 if tree else 0), fg, bg)
		}
		m: PaneMark
		marked := false
		if len(p.marks) > 0 {
			m, marked = p.marks[pane_item_key(it)]
		}
		if marked && m.bar != "" {
			tb2.set_cell(i32(g.list.x), i32(y), '▌', pane_theme_color(m.bar, COLOR_GIT_MOD), COLOR_PANE_BG)
		}
		switch {
		case marked && m.fg != "":
			fg = pane_theme_color(m.fg, fg)
		case tree && !it.dir && it.path != "" && it.path == current:
			fg = COLOR_PANE_PROMPT_FG
		case !selected && len(p.marks) > 0 && (m.dim || (tree && pane_mark_dim(p, it.path))):
			fg = COLOR_PANE_DIM_FG
		}
		label := pane_tree_label(p, it) if tree else it.label
		if marked && m.suffix != "" && !it.dir && !p.marks_plain {
			label = fmt.tprintf("%s  %s", label, m.suffix)
		}
		if tree && pane_tree_unsaved(editor, it) {
			label = strings.concatenate({label, " ", ICON_MODIFIED}, context.temp_allocator)
		}
		label_w, sizes := lw, ""
		if marked && m.sizes && !it.dir && !p.marks_plain {
			sizes = fmt.tprintf("%*s  %*s", addw + 1, fmt.tprintf("+%d", m.added), delw + 1, fmt.tprintf("-%d", m.removed))
			room := label_w - len(sizes) - 1
			if room >= min(visual_width(transmute([]u8)label), PANE_SIZES_MIN_LABEL) {
				label_w = room
				label = status_clip(label, room)
			} else {
				sizes = ""
			}
		}
		it.label = label
		pane_render_row(it, cols, g.list.x + 1, y, label_w, fg, bg)
		if sizes != "" {
			pane_size_paint(g.list.x + g.list.w - len(sizes), y, g.list.x + g.list.w, sizes, bg)
		}
		if it.detail != "" {
			dw := visual_width(transmute([]u8)it.detail)
			pane_text(g.list.x + g.list.w - 1 - dw, y, dw, it.detail, dfg, bg)
		}
	}
	if p.has_list {
		pane_draw_scrollbar(g.div_x, g.list.y, g.list.h, p.list.scroll, n)
	}

	if len(p.fields) == 0 && !p.footer_input {
		tb2.hide_cursor()
		return
	}
	count := pane_count_text(editor, p)
	for i in 0 ..< len(p.fields) {
		if i != p.focus {
			pane_render_field(p, g, i, count)
		}
	}
	pane_render_field(p, g, p.focus, count)
	if p.footer_input && g.footer_y >= 0 {
		x, w := pane_footer_rect(p, g)
		textfield_render(x, g.footer_y, w, &p.footer_field.field)
	}
}

pane_key :: proc(editor: ^Editor, p: ^Pane, ev: tb2.Event) -> PaneAction {
	if p.footer_input {
		#partial switch ev.key {
		case .Esc:
			pane_footer_end(editor, p, false)
		case .Enter:
			pane_footer_end(editor, p, true)
		case:
			textfield_key(&p.footer_field.field, ev)
		}
		return .None
	}
	if (p.toggle != 0 && plugin_command_id_matches(editor, p.toggle, ev)) || (p.chord != "" && command_matches(ev, p.chord)) {
		return .Close
	}
	for t, i in p.tabs {
		if t.cmd != "" && pane_cmd_matches(editor, ev, t.cmd) {
			if i == p.tab {
				return .Close
			}
			pane_tab_set(editor, p, i)
			return .None
		}
	}
	if p.scope != "" {
		if command_matches(ev, "Command Palette") {
			palette_open(editor)
			return .None
		}
		bare := len(p.fields) == 0
		if cmd, ok := pane_command_for_event(p.scope, ev, bare); ok {
			command_run(editor, cmd)
			return .None
		}
		if cmd, ok := plugin_command_for_event(editor, ev, p.scope, bare); ok {
			plugin_command_chord(editor, cmd)
			return .None
		}
	}
	if len(p.fields) > 0 && p.fields[p.focus].mode == .Path && pane_path_key(editor, p, &p.fields[p.focus], ev) {
		return .None
	}
	#partial switch ev.key {
	case .Esc:
		for &f in p.fields {
			if f.esc_clears && len(f.text) > 0 {
				textfield_reset(&f.field)
				pane_field_changed(editor, p, &f)
				if p.refill_due {
					list_walk_fill(editor, p)
				}
				return .None
			}
		}
		return .Close
	case .Arrow_Left, .Arrow_Right:
		if len(p.tabs) > 0 {
			pane_tab_set(editor, p, p.tab + (1 if ev.key == .Arrow_Right else -1))
			return .None
		}
	case .Enter:
		if !p.ctx.lua && p.has_list && pane_count(editor, p) == 0 {
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
		if p.body_preview {
			preview_scroll_by(&p.preview, d, g.text.h)
			return .None
		}
		if p.has_list {
			if pane_count(editor, p) > 0 {
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
				pane_select(editor, p, p.list.sel + d, g.list.h)
			}
			return .None
		}
		if len(p.fields) == 0 {
			overlay_scroll_by(&p.scroll, d, pane_body_rows(p, g), g.text.h)
			return .None
		}
	case .Home, .End:
		if p.body_preview {
			g := pane_geom(editor, p)
			total := preview_total(&p.preview)
			preview_scroll_by(&p.preview, -total if ev.key == .Home else total, g.text.h)
			return .None
		}
		if !p.has_list && len(p.fields) == 0 {
			g := pane_geom(editor, p)
			p.scroll = 0 if ev.key == .Home else max(0, pane_body_rows(p, g) - g.text.h)
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
	n := pane_count(editor, p)
	#partial switch ev.key {
	case .Mouse_Wheel_Up, .Mouse_Wheel_Down:
		d := -WHEEL_SCROLL_LINES if ev.key == .Mouse_Wheel_Up else WHEEL_SCROLL_LINES
		if g.has_preview && mouse_in_rect(ev, g.preview) {
			preview_scroll_by(&p.preview, d, g.preview.h)
		} else if p.body_preview {
			preview_scroll_by(&p.preview, d, g.text.h)
		} else if p.has_list {
			overlay_scroll_by(&p.list.scroll, d, n, g.list.h)
			p.list.stick = d > 0 && p.list.scroll >= max(0, n - g.list.h)
		} else {
			overlay_scroll_by(&p.scroll, d, pane_body_rows(p, g), g.text.h)
		}
		return .None
	case .Mouse_Left:
	case:
		return .None
	}
	motion := ev_motion(ev)
	if p.footer_input {
		if !mouse_in_rect(ev, g.box) {
			return .None if motion else .Close
		}
		if int(ev.y) == g.footer_y {
			x, w := pane_footer_rect(p, g)
			textfield_mouse(&p.footer_field.field, x, g.footer_y, w, ev)
		}
		return .None
	}
	if !motion && int(ev.y) == g.title_y && len(p.tabs) > 0 {
		pane_tab_set(editor, p, pane_tab_at(p, g, int(ev.x)))
		return .None
	}
	for &f, i in p.fields {
		y := g.field_y + i
		if !motion && int(ev.y) == y && int(ev.x) >= g.field_x && int(ev.x) < g.field_x + g.field_w {
			p.focus = i
			overlay_prompt_mouse(&f.field, g.field_x, y, g.field_w, ev, pane_prompt(&f))
			return .None
		}
	}
	if !motion && int(ev.y) == g.footer_y && len(p.chips) > 0 {
		xs, _ := pane_chips_layout(editor, p, g)
		for c, i in p.chips {
			w := visual_width(transmute([]u8)pane_hint_text(editor, c.label, c.cmd))
			if int(ev.x) >= xs[i] && int(ev.x) < xs[i] + w {
				pane_run_command(editor, p, c.cmd)
				return .None
			}
		}
	}
	if off := overlay_row_off(ev, g.list); off >= 0 {
		if i := p.list.scroll + off; i < n {
			p.list.sel, p.list.anchor, p.list.moved = i, nil, true
			p.list.stick = i == n - 1
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
	if p.has_md && !motion && mouse_in_rect(ev, g.text) {
		if row := p.scroll + int(ev.y) - g.text.y; row < len(p.md_lines) {
			pane_md_follow(editor, p, md_line_link(p.md_lines[row], int(ev.x) - g.text.x))
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

pane_md_follow :: proc(editor: ^Editor, p: ^Pane, target: string) {
	if target == "" || (p.on.link != nil && p.on.link(editor, p, target)) {
		return
	}
	if target[0] == '#' {
		for line, i in p.md_lines {
			if line.slug != "" && line.slug == target[1:] {
				p.scroll = i
				break
			}
		}
	}
}

// everything drawn so far except the status rows, so panes underneath fade too
pane_backdrop :: proc(mode: PaneBackdrop) {
	if mode == .None {
		return
	}
	for y in 0 ..< int(tb2.height()) - STATUS_ROWS {
		for x in 0 ..< int(tb2.width()) {
			if mode == .Blank {
				tb2.set_cell(i32(x), i32(y), ' ', COLOR_FG, COLOR_BG)
				continue
			}
			cell: ^tb2.Cell_Raw
			if tb2.get_cell(i32(x), i32(y), 1, &cell) == .Ok && cell != nil {
				cell.fg = tb2.Color(u64(color_over(cell.fg, cell.bg, PANE_BACKDROP_TINT)) | color_attrs(cell.fg))
			}
		}
	}
}

pane_body_rows :: proc(p: ^Pane, g: PaneGeom) -> int {
	return len(pane_md_lines(p, g.text.w)) if p.has_md else len(p.text)
}

pane_md_visible :: proc(editor: ^Editor, p: ^Pane) -> (scroll: int, src: []int) {
	g := pane_geom(editor, p)
	lines := pane_md_lines(p, g.text.w)
	scroll = clamp(p.scroll, 0, max(0, len(lines) - g.text.h))
	src = make([]int, clamp(len(lines) - scroll, 0, g.text.h), context.temp_allocator)
	for &s, i in src {
		s = lines[scroll + i].src
	}
	return
}

PaneMdJob :: struct {
	arena: vmem.Arena,
	job:   MdJob,
	w:     int,
}

md_slice_ms := 10

// the last finished render, kept on screen while a newer one runs in md_slice_ms steps from pane_stack_pump
pane_md_lines :: proc(p: ^Pane, w: int) -> []MdLine {
	if p.md_w == w {
		return p.md_lines
	}
	if p.md_job != nil && p.md_job.w != w {
		pane_md_reset(p)
	}
	if p.md_job == nil {
		j := new(PaneMdJob)
		j.w = w
		context.temp_allocator = vmem.arena_allocator(&j.arena)
		md_job_start(&j.job, strings.clone(p.md, context.temp_allocator), w, .Plain)
		p.md_job = j
		pane_md_step(p, md_slice_ms)
	}
	return p.md_lines
}

pane_md_step :: proc(p: ^Pane, ms: int) -> (done: bool) {
	j := p.md_job
	if j == nil {
		return false
	}
	deadline := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond) if ms >= 0 else time.Tick{}
	context.temp_allocator = vmem.arena_allocator(&j.arena)
	lines := md_job_step(&j.job, deadline)
	if !j.job.done {
		return false
	}
	vmem.arena_destroy(&p.md_arena)
	p.md_arena = j.arena
	p.md_lines, p.md_w = lines, j.w
	free(j)
	p.md_job = nil
	return true
}

pane_md_reset :: proc(p: ^Pane) {
	p.md_w = -1
	if p.md_job != nil {
		vmem.arena_destroy(&p.md_job.arena)
		free(p.md_job)
		p.md_job = nil
	}
}

pane_paste :: proc(editor: ^Editor, p: ^Pane, text: string) {
	if p.footer_input {
		textfield_insert_flat(&p.footer_field.field, text)
		return
	}
	if len(p.fields) == 0 {
		return
	}
	f := &p.fields[p.focus]
	if textfield_insert_flat(&f.field, text) {
		pane_field_changed(editor, p, f)
	}
}
