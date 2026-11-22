package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import lua "lib:lua"
import "lib:tb2"

UI_LAYERS :: [?]string{"background", "base", "popup", "pane", "notification", "alert"}
UI_FOCUS_HISTORY_MAX :: 16
UI_KEY_CHORD_ONLY :: tb2.Key(0xff00)
UI_UNBOUNDED :: 1 << 30

UiKind :: enum u8 {
	Column,
	Row,
	Box,
	Scroll,
	Text,
	Editor,
	Virtual_Column,
	Outlet,
}

ui_kind_names := [UiKind]string {
	.Column         = "column",
	.Row            = "row",
	.Box            = "box",
	.Scroll         = "scroll",
	.Text           = "text",
	.Editor         = "editor",
	.Virtual_Column = "virtual_column",
	.Outlet         = "outlet",
}

UiSizeForm :: enum u8 {
	Auto,
	Cells,
	Percent,
	Fit,
}

UiSize :: struct {
	form:  UiSizeForm,
	value: int,
	min:   int,
	max:   int,
}

UiFloat :: enum u8 {
	None,
	Parent,
	Screen,
}

UiAnchor :: enum u8 {
	Center,
	Top_Left,
	Top,
	Top_Right,
	Left,
	Right,
	Bottom_Left,
	Bottom,
	Bottom_Right,
	Cursor,
}

UiAlign :: enum u8 {
	Stretch,
	Start,
	Center,
	End,
}

UiStyleField :: enum u8 {
	Fg,
	Bg,
	Bold,
	Italic,
	Underline,
}

UiStyle :: struct {
	set:                     bit_set[UiStyleField],
	fg, bg:                  string,
	bold, italic, underline: bool,
}

UiSpan :: struct {
	text:  string,
	style: UiStyle,
}

UiEvent :: enum u8 {
	Key,
	Paste,
	Click,
	Double_Click,
	Wheel,
}

ui_event_names := [UiEvent]string {
	.Key          = "key",
	.Paste        = "paste",
	.Click        = "click",
	.Double_Click = "double_click",
	.Wheel        = "wheel",
}

UiItem :: struct {
	node: ^UiNode,
	rev:  u64,
}

UiNode :: struct {
	kind:            UiKind,
	id, key:         string,
	identity:        string,
	owner:           string,
	mount:           u64,
	parent:          ^UiNode,
	children:        [dynamic]^UiNode,
	child_slots:     [dynamic]int,
	header:          ^UiNode,
	expanded:        [dynamic]^UiNode,
	width, height:   UiSize,
	grow, drop:      int,
	grow_set:        bool,
	margin:          [4]int,
	float:           UiFloat,
	anchor:          UiAnchor,
	scope:           []string,
	handlers:        [UiEvent]i32,
	style:           UiStyle,
	gap:             int,
	separator:       bool,
	align:           UiAlign,
	highlight_style: UiStyle,
	border:          bool,
	title:           string,
	spans:           [dynamic]UiSpan,
	wrap:            bool,
	wrap_set:        bool,
	text_align:      UiAlign,
	buffer:          u64,
	placeholder:     string,
	line_numbers:    bool,
	highlight:       bool,
	readonly:        bool,
	current_line:    UiStyle,
	list:            u64,
	list_ref:        i32,
	item_ref:        i32,
	items:           map[string]UiItem,
	items_rev:       u64,
	window_lo:       int,
	window_hi:       int,
	rect:            Rect,
	clip:            Rect,
	hidden:          bool,
	is_item:         bool,
}

UiState :: struct {
	highlighted: string,
	offset:      int,
	scroll_row:  int,
	scroll_sub:  int,
	scroll_col:  int,
	reveal:      bool,
	cursor_seen: Cursor,
	rev_seen:    u64,
}

UiMount :: struct {
	handle: u64,
	owner:  string,
	outlet: string,
	root:   ^UiNode,
}

UiHit :: struct {
	node: ^UiNode,
	rect: Rect,
}

UiDrag :: struct {
	node:   string,
	active: bool,
}

Ui :: struct {
	mounts:        [dynamic]UiMount,
	states:        map[string]UiState,
	focus:         string,
	focus_history: [dynamic]string,
	index:         map[string]^UiNode,
	virtuals:      [dynamic]^UiNode,
	editors:       [dynamic]^UiNode,
	dirty:         bool,
	graveyard:     [dynamic]^UiNode,
	gen:           u64,
	seq:           u64,
	lists:         [dynamic]^UiList,
	hits:          [dynamic]UiHit,
	caret:         [2]int,
	caret_shown:   bool,
	target:        ^UiNode,
	drag:          UiDrag,
	internal:      [dynamic]^Buffer,
	internal_owner: map[u64]string,
	builds:        int,
}

ui_destroy :: proc(editor: ^Editor) {
	ui := &editor.ui
	for m in ui.mounts {
		ui_node_free(editor, m.root)
		delete(m.outlet)
	}
	delete(ui.mounts)
	ui_graveyard_flush(editor)
	delete(ui.graveyard)
	for k, v in ui.states {
		delete(k)
		delete(v.highlighted)
	}
	delete(ui.states)
	delete(ui.focus)
	for f in ui.focus_history {
		delete(f)
	}
	delete(ui.focus_history)
	delete(ui.index)
	delete(ui.virtuals)
	delete(ui.editors)
	for l in ui.lists {
		ui_list_free(editor, l)
	}
	delete(ui.lists)
	delete(ui.hits)
	delete(ui.drag.node)
	for b in ui.internal {
		buffer_destroy(b)
		free(b)
	}
	delete(ui.internal)
	delete(ui.internal_owner)
}

ui_node_free :: proc(editor: ^Editor, node: ^UiNode) {
	if node == nil {
		return
	}
	for c in node.children {
		ui_node_free(editor, c)
	}
	ui_node_free(editor, node.header)
	for _, item in node.items {
		ui_node_free(editor, item.node)
	}
	for k, _ in node.items {
		delete(k)
	}
	delete(node.items)
	delete(node.children)
	delete(node.child_slots)
	delete(node.expanded)
	L := editor.plugins.L
	if L != nil {
		for ref in node.handlers {
			if ref != 0 {
				lua_unref(L, ref)
			}
		}
		if node.item_ref != 0 {
			lua_unref(L, node.item_ref)
		}
		if node.list_ref != 0 {
			lua_unref(L, node.list_ref)
		}
	}
	for s in node.scope {
		delete(s)
	}
	delete(node.scope)
	for s in node.spans {
		delete(s.text)
		ui_style_free(s.style)
	}
	delete(node.spans)
	ui_style_free(node.style)
	ui_style_free(node.highlight_style)
	ui_style_free(node.current_line)
	delete(node.id)
	delete(node.key)
	delete(node.identity)
	delete(node.title)
	delete(node.placeholder)
	free(node)
}

ui_style_free :: proc(s: UiStyle) {
	delete(s.fg)
	delete(s.bg)
}

ui_graveyard_flush :: proc(editor: ^Editor) {
	for n in editor.ui.graveyard {
		ui_node_free(editor, n)
	}
	clear(&editor.ui.graveyard)
}

ui_mount_index :: proc(ui: ^Ui, handle: u64) -> int {
	for m, i in ui.mounts {
		if m.handle == handle {
			return i
		}
	}
	return -1
}

ui_mount_add :: proc(editor: ^Editor, owner, outlet: string, root: ^UiNode) -> u64 {
	ui := &editor.ui
	ui.seq += 1
	append(&ui.mounts, UiMount{handle = ui.seq, owner = owner, outlet = strings.clone(outlet), root = root})
	ui_tree_identify(root, ui.seq)
	ui.dirty = true
	ui.gen += 1
	return ui.seq
}

ui_mount_replace :: proc(editor: ^Editor, handle: u64, root: ^UiNode) -> bool {
	ui := &editor.ui
	i := ui_mount_index(ui, handle)
	if i < 0 {
		return false
	}
	old := ui.mounts[i].root
	ui_tree_identify(root, handle)
	ui_tree_carry(editor.plugins.L, root, old)
	append(&ui.graveyard, old)
	ui.mounts[i].root = root
	ui.dirty = true
	ui.gen += 1
	return true
}

ui_mount_remove :: proc(editor: ^Editor, handle: u64) {
	ui := &editor.ui
	i := ui_mount_index(ui, handle)
	if i < 0 {
		return
	}
	append(&ui.graveyard, ui.mounts[i].root)
	delete(ui.mounts[i].outlet)
	ordered_remove(&ui.mounts, i)
	ui.dirty = true
	ui.gen += 1
}

ui_unload :: proc(editor: ^Editor, owner: string) {
	ui := &editor.ui
	for i := len(ui.mounts) - 1; i >= 0; i -= 1 {
		if ui.mounts[i].owner == owner {
			ui_mount_remove(editor, ui.mounts[i].handle)
		}
	}
	ui_graveyard_flush(editor)
	for i := len(ui.lists) - 1; i >= 0; i -= 1 {
		if ui.lists[i].owner == owner {
			ui_list_free(editor, ui.lists[i])
			ordered_remove(&ui.lists, i)
		}
	}
	for i := len(ui.internal) - 1; i >= 0; i -= 1 {
		b := ui.internal[i]
		if ui.internal_owner[b.id] == owner {
			ui_internal_close(editor, b.id)
		}
	}
}

ui_tree_identify :: proc(node: ^UiNode, handle: u64) {
	delete(node.identity)
	node.identity = strings.clone(fmt.tprintf("#%s/%s", node.owner, node.id) if node.id != "" else fmt.tprintf("@%d", handle))
	ui_children_identify(node, handle)
}

ui_children_identify :: proc(node: ^UiNode, handle: u64) {
	node.mount = handle
	for c, i in node.children {
		delete(c.identity)
		if c.id != "" {
			c.identity = strings.clone(fmt.tprintf("#%s/%s", c.owner, c.id))
		} else if c.key != "" {
			c.identity = strings.clone(fmt.tprintf("%s/k%s", node.identity, c.key))
		} else {
			c.identity = strings.clone(fmt.tprintf("%s/%s%d", node.identity, ui_kind_names[c.kind], node.child_slots[i]))
		}
		ui_children_identify(c, handle)
	}
	if node.header != nil {
		delete(node.header.identity)
		node.header.identity = strings.clone(fmt.tprintf("#%s/%s", node.header.owner, node.header.id) if node.header.id != "" else fmt.tprintf("%s/header", node.identity))
		ui_children_identify(node.header, handle)
	}
}

ui_tree_carry :: proc(L: ^lua.State, fresh, old: ^UiNode) {
	olds := make(map[string]^UiNode, 64, context.temp_allocator)
	ui_tree_collect(old, &olds)
	ui_tree_carry_walk(L, fresh, &olds)
}

ui_tree_collect :: proc(node: ^UiNode, into: ^map[string]^UiNode) {
	into[node.identity] = node
	for c in node.children {
		ui_tree_collect(c, into)
	}
	if node.header != nil {
		ui_tree_collect(node.header, into)
	}
}

ui_tree_carry_walk :: proc(L: ^lua.State, node: ^UiNode, olds: ^map[string]^UiNode) {
	if node.kind == .Virtual_Column {
		if old, ok := olds[node.identity]; ok && old.kind == .Virtual_Column && old.list == node.list && old.item_ref != 0 && node.item_ref != 0 && lua_refs_equal(L, old.item_ref, node.item_ref) {
			node.items, old.items = old.items, node.items
			node.items_rev = old.items_rev
		}
	}
	for c in node.children {
		ui_tree_carry_walk(L, c, olds)
	}
	if node.header != nil {
		ui_tree_carry_walk(L, node.header, olds)
	}
}

ui_state :: proc(ui: ^Ui, identity: string) -> ^UiState {
	if s, ok := &ui.states[identity]; ok {
		return s
	}
	ui.states[strings.clone(identity)] = {}
	return &ui.states[identity]
}

ui_state_prune :: proc(ui: ^Ui) {
	gone := make([dynamic]string, context.temp_allocator)
	for k, _ in ui.states {
		if k[0] != '#' && k not_in ui.index {
			append(&gone, k)
		}
	}
	for k in gone {
		key, state := delete_key(&ui.states, k)
		delete(key)
		delete(state.highlighted)
	}
}

ui_layer_used :: proc(ui: ^Ui, layer: string) -> bool {
	for m in ui.mounts {
		if m.outlet == layer {
			return true
		}
	}
	return false
}

ui_is_layer :: proc(name: string) -> bool {
	for l in UI_LAYERS {
		if l == name {
			return true
		}
	}
	return false
}

ui_resolve :: proc(editor: ^Editor) {
	ui := &editor.ui
	if !ui.dirty {
		return
	}
	ui.dirty = false
	clear(&ui.index)
	clear(&ui.virtuals)
	clear(&ui.editors)
	visiting := make(map[u64]bool, 16, context.temp_allocator)
	for layer in UI_LAYERS {
		for m in ui.mounts {
			if m.outlet == layer {
				m.root.parent = nil
				ui_resolve_node(editor, m.root, &visiting)
			}
		}
	}
	ui_state_prune(ui)
}

ui_resolve_node :: proc(editor: ^Editor, node: ^UiNode, visiting: ^map[u64]bool) {
	ui := &editor.ui
	ui.index[node.identity] = node
	if node.kind == .Virtual_Column {
		append(&ui.virtuals, node)
	} else if node.kind == .Editor {
		append(&ui.editors, node)
	}
	clear(&node.expanded)
	for c in node.children {
		if c.kind != .Outlet {
			c.parent = node
			append(&node.expanded, c)
			ui_resolve_node(editor, c, visiting)
			continue
		}
		ui.index[c.identity] = c
		c.parent = node
		if c.id == "" {
			continue
		}
		for m in ui.mounts {
			if m.outlet != c.id || visiting[m.handle] {
				continue
			}
			visiting[m.handle] = true
			m.root.parent = node
			append(&node.expanded, m.root)
			ui_resolve_node(editor, m.root, visiting)
			visiting[m.handle] = false
		}
	}
	if node.header != nil {
		node.header.parent = node
		ui_resolve_node(editor, node.header, visiting)
	}
	for _, item in node.items {
		item.node.parent = node
		ui_resolve_node(editor, item.node, visiting)
	}
}

ui_find :: proc(ui: ^Ui, identity: string) -> ^UiNode {
	return ui.index[identity] or_else nil
}

ui_focused :: proc(editor: ^Editor) -> ^UiNode {
	ui := &editor.ui
	ui_resolve(editor)
	for ui.focus != "" {
		if n := ui_find(ui, ui.focus); n != nil {
			return n
		}
		delete(ui.focus)
		ui.focus = ""
		for len(ui.focus_history) > 0 {
			prev := pop(&ui.focus_history)
			if ui_find(ui, prev) != nil {
				ui.focus = prev
				break
			}
			delete(prev)
		}
	}
	return nil
}

ui_focus_set :: proc(editor: ^Editor, identity: string) {
	ui := &editor.ui
	if ui.focus == identity {
		return
	}
	if ui.focus != "" {
		for f, i in ui.focus_history {
			if f == ui.focus {
				delete(f)
				ordered_remove(&ui.focus_history, i)
				break
			}
		}
		if len(ui.focus_history) >= UI_FOCUS_HISTORY_MAX {
			delete(ui.focus_history[0])
			ordered_remove(&ui.focus_history, 0)
		}
		append(&ui.focus_history, ui.focus)
	}
	ui.focus = strings.clone(identity)
}

ui_buffer :: proc(editor: ^Editor, id: u64) -> ^Buffer {
	for b in editor.ui.internal {
		if b.id == id {
			return b
		}
	}
	if editor.welcome {
		return nil
	}
	for &b in editor.buffers {
		if b.id == id {
			return &b
		}
	}
	return nil
}

ui_internal_create :: proc(editor: ^Editor, owner: string) -> ^Buffer {
	b := new(Buffer)
	b^ = buffer_new()
	b.internal = true
	b.wrap = false
	append(&editor.ui.internal, b)
	editor.ui.internal_owner[b.id] = owner
	return b
}

ui_internal_close :: proc(editor: ^Editor, id: u64) -> bool {
	ui := &editor.ui
	for b, i in ui.internal {
		if b.id == id {
			buffer_destroy(b)
			free(b)
			ordered_remove(&ui.internal, i)
			delete_key(&ui.internal_owner, id)
			return true
		}
	}
	return false
}

ui_screen :: proc() -> Rect {
	return {0, 0, int(tb2.width()), int(tb2.height())}
}

ui_rect_shrink :: proc(r: Rect, margin: [4]int) -> Rect {
	out := Rect{r.x + margin[3], r.y + margin[0], r.w - margin[1] - margin[3], r.h - margin[0] - margin[2]}
	out.w = max(out.w, 0)
	out.h = max(out.h, 0)
	return out
}

ui_rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

ui_rect_has :: proc(r: Rect, x, y: int) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

ui_size_clamp :: proc(s: UiSize, v, avail: int) -> int {
	v := v
	if s.max > 0 {
		v = min(v, s.max)
	}
	v = max(v, s.min)
	return clamp(v, 0, max(avail, 0))
}

ui_size_resolve :: proc(s: UiSize, avail, natural: int) -> int {
	v := natural
	switch s.form {
	case .Cells:
		v = s.value
	case .Percent:
		v = max(avail, 0) * s.value / 100
	case .Fit, .Auto:
		v = natural
	}
	return ui_size_clamp(s, v, avail)
}

ui_grows :: proc(node: ^UiNode, axis: int) -> int {
	if node.grow_set {
		return node.grow
	}
	if node.kind == .Editor {
		size := node.height if axis == 1 else node.width
		return 1 if size.form == .Auto else 0
	}
	return 0
}

ui_axis_size :: proc(node: ^UiNode, axis: int) -> UiSize {
	return node.height if axis == 1 else node.width
}

ui_text_lines :: proc(node: ^UiNode, allocator := context.temp_allocator) -> [dynamic][dynamic]UiSpan {
	lines := make([dynamic][dynamic]UiSpan, allocator)
	append(&lines, make([dynamic]UiSpan, allocator))
	for s in node.spans {
		rest := s.text
		for {
			nl := strings.index_byte(rest, '\n')
			part := rest if nl < 0 else rest[:nl]
			if len(part) > 0 {
				append(&lines[len(lines) - 1], UiSpan{part, s.style})
			}
			if nl < 0 {
				break
			}
			append(&lines, make([dynamic]UiSpan, allocator))
			rest = rest[nl + 1:]
		}
	}
	return lines
}

ui_spans_width :: proc(spans: []UiSpan) -> int {
	w := 0
	for s in spans {
		w = visual_col_from(transmute([]u8)s.text, 0, w, len(s.text))
	}
	return w
}

ui_text_wrapped :: proc(node: ^UiNode, width: int) -> [dynamic][dynamic]UiSpan {
	lines := ui_text_lines(node)
	if !node.wrap || width <= 0 {
		return lines
	}
	out := make([dynamic][dynamic]UiSpan, context.temp_allocator)
	for line in lines {
		cur := make([dynamic]UiSpan, context.temp_allocator)
		col := 0
		for s in line {
			bytes := transmute([]u8)s.text
			start := 0
			i := 0
			for i < len(bytes) {
				e := cluster_end(bytes, i)
				cw := seg_width(bytes, i, e, col)
				if col + cw > width && col > 0 {
					if i > start {
						append(&cur, UiSpan{s.text[start:i], s.style})
					}
					append(&out, cur)
					cur = make([dynamic]UiSpan, context.temp_allocator)
					col = 0
					start = i
					continue
				}
				col += cw
				i = e
			}
			if i > start {
				append(&cur, UiSpan{s.text[start:i], s.style})
			}
		}
		append(&out, cur)
	}
	return out
}

ui_measure :: proc(editor: ^Editor, node: ^UiNode, avail_w, avail_h: int) -> (w, h: int) {
	switch node.kind {
	case .Text:
		lines := ui_text_wrapped(node, avail_w)
		for line in lines {
			w = max(w, ui_spans_width(line[:]))
		}
		h = len(lines)
	case .Column, .Row:
		axis := 1 if node.kind == .Column else 0
		main, cross := 0, 0
		count := 0
		for c in node.expanded {
			if c.float != .None {
				continue
			}
			cw, ch := ui_measure_slot(editor, c, avail_w, avail_h)
			sizes := [2]int{cw, ch}
			if ui_grows(c, axis) > 0 && ui_axis_size(c, axis).form == .Auto {
				sizes[axis] = ui_axis_size(c, axis).min + (c.margin[0] + c.margin[2] if axis == 1 else c.margin[1] + c.margin[3])
			}
			main += sizes[axis]
			cross = max(cross, sizes[1 - axis])
			count += 1
		}
		if count > 1 {
			main += (count - 1) * (node.gap + (1 if node.separator else 0))
		}
		if axis == 1 {
			w, h = cross, main
		} else {
			w, h = main, cross
		}
	case .Box:
		inset := 2 if node.border else 0
		for c in node.expanded {
			if c.float == .None {
				w, h = ui_measure_slot(editor, c, avail_w - inset, avail_h - inset)
				break
			}
		}
		w += inset
		h += inset
		if node.border && node.title != "" {
			w = max(w, visual_width(transmute([]u8)node.title) + 4)
		}
	case .Scroll:
		hw, hh := 0, 0
		if node.header != nil {
			hw, hh = ui_measure_slot(editor, node.header, avail_w - 1, avail_h)
		}
		for c in node.expanded {
			if c.float == .None {
				w, h = ui_measure_slot(editor, c, avail_w - 1, UI_UNBOUNDED)
				break
			}
		}
		w = max(w, hw) + 1
		h += hh
	case .Virtual_Column:
		list := ui_list_find(&editor.ui, node.list)
		if list != nil {
			h = ui_list_count(list)
		}
		for _, item in node.items {
			iw, _ := ui_measure_slot(editor, item.node, avail_w, 1)
			w = max(w, iw)
		}
	case .Editor:
		b := ui_buffer(editor, node.buffer)
		if b != nil {
			h = len(b.lines)
			for line in b.lines {
				w = max(w, visual_width(line.text[:]))
			}
			if node.line_numbers {
				w += digit_count(len(b.lines)) + 2
			}
		}
	case .Outlet:
	}
	return
}

ui_measure_slot :: proc(editor: ^Editor, node: ^UiNode, avail_w, avail_h: int) -> (w, h: int) {
	mx := node.margin[1] + node.margin[3]
	my := node.margin[0] + node.margin[2]
	inner_w := max(avail_w - mx, 0)
	inner_h := max(avail_h - my, 0)
	nw, nh := 0, 0
	if node.width.form == .Auto || node.width.form == .Fit || node.height.form == .Auto || node.height.form == .Fit {
		nw, nh = ui_measure(editor, node, inner_w if node.width.form != .Cells else node.width.value, inner_h)
	}
	w = ui_size_resolve(node.width, inner_w, nw) + mx
	h = ui_size_resolve(node.height, inner_h, nh) + my
	return
}

ui_layout_children :: proc(editor: ^Editor, node: ^UiNode) {
	content := node.rect
	switch node.kind {
	case .Box:
		if node.border {
			content = ui_rect_shrink(node.rect, {1, 1, 1, 1})
		}
		for c in node.expanded {
			if c.float == .None {
				ui_layout_single(editor, c, content, node.clip)
				break
			}
		}
	case .Scroll:
		content.w = max(content.w - 1, 0)
		if node.header != nil {
			_, hh := ui_measure_slot(editor, node.header, content.w, content.h)
			hh = min(hh, content.h)
			ui_layout_node(editor, node.header, ui_rect_shrink({content.x, content.y, content.w, hh}, node.header.margin), node.clip)
			content.y += hh
			content.h -= hh
		}
		state := ui_state(&editor.ui, node.identity)
		for c in node.expanded {
			if c.float != .None {
				continue
			}
			_, ch := ui_measure_slot(editor, c, content.w, UI_UNBOUNDED)
			total := max(ch, content.h)
			state.offset = clamp(state.offset, 0, max(0, ch - content.h))
			slot := Rect{content.x, content.y - state.offset, content.w, total}
			ui_layout_node(editor, c, ui_rect_shrink(slot, c.margin), ui_rect_intersect(content, node.clip))
			break
		}
	case .Column, .Row:
		ui_layout_flow(editor, node, content)
	case .Text, .Editor, .Virtual_Column, .Outlet:
	}
	for c in node.expanded {
		if c.float != .None {
			ui_layout_float(editor, c, node)
		}
	}
}

ui_layout_single :: proc(editor: ^Editor, child: ^UiNode, area, clip: Rect) {
	inner := ui_rect_shrink(area, child.margin)
	r := inner
	if child.width.form != .Auto {
		nw, _ := ui_measure(editor, child, inner.w, inner.h)
		r.w = ui_size_resolve(child.width, inner.w, nw)
	}
	if child.height.form != .Auto {
		_, nh := ui_measure(editor, child, r.w, inner.h)
		r.h = ui_size_resolve(child.height, inner.h, nh)
	}
	ui_layout_node(editor, child, r, clip)
}

ui_layout_node :: proc(editor: ^Editor, node: ^UiNode, r, clip: Rect) {
	node.rect = r
	node.clip = clip
	node.hidden = false
	ui_layout_children(editor, node)
}

ui_layout_flow :: proc(editor: ^Editor, node: ^UiNode, content: Rect) {
	axis := 1 if node.kind == .Column else 0
	avail := [2]int{content.w, content.h}
	kids := make([dynamic]^UiNode, context.temp_allocator)
	for c in node.expanded {
		if c.float == .None {
			append(&kids, c)
			c.hidden = false
		}
	}
	sizes := make([]int, len(kids), context.temp_allocator)
	margins := make([]int, len(kids), context.temp_allocator)
	for c, i in kids {
		margins[i] = c.margin[0] + c.margin[2] if axis == 1 else c.margin[1] + c.margin[3]
		form := ui_axis_size(c, axis)
		if ui_grows(c, axis) > 0 && form.form == .Auto {
			sizes[i] = form.min
			continue
		}
		cw, ch := ui_measure_slot(editor, c, content.w, content.h)
		sizes[i] = (ch if axis == 1 else cw) - margins[i]
	}
	sep := node.gap + (1 if node.separator else 0)
	total :: proc(kids: []^UiNode, sizes, margins: []int, sep: int) -> int {
		t, n := 0, 0
		for c, i in kids {
			if c.hidden {
				continue
			}
			t += sizes[i] + margins[i]
			n += 1
		}
		return t + max(n - 1, 0) * sep
	}
	for total(kids[:], sizes, margins, sep) > avail[axis] {
		worst := -1
		for c, i in kids {
			if !c.hidden && c.drop > 0 && (worst < 0 || c.drop >= kids[worst].drop) {
				worst = i
			}
		}
		if worst < 0 {
			break
		}
		kids[worst].hidden = true
	}
	leftover := avail[axis] - total(kids[:], sizes, margins, sep)
	weight := 0
	for c in kids {
		if !c.hidden {
			weight += ui_grows(c, axis)
		}
	}
	if leftover > 0 && weight > 0 {
		given := 0
		last := -1
		for c, i in kids {
			g := ui_grows(c, axis)
			if c.hidden || g == 0 {
				continue
			}
			share := leftover * g / weight
			form := ui_axis_size(c, axis)
			if form.max > 0 {
				share = min(share, max(form.max - sizes[i], 0))
			}
			sizes[i] += share
			given += share
			last = i
		}
		if last >= 0 && ui_axis_size(kids[last], axis).max == 0 {
			sizes[last] += leftover - given
		}
	}
	pos := content.y if axis == 1 else content.x
	end := pos + avail[axis]
	for c, i in kids {
		if c.hidden {
			c.rect = {}
			continue
		}
		lead := c.margin[0] if axis == 1 else c.margin[3]
		main := clamp(sizes[i], 0, max(end - pos - lead, 0))
		cross_avail := (content.w - c.margin[1] - c.margin[3]) if axis == 1 else (content.h - c.margin[0] - c.margin[2])
		cross_avail = max(cross_avail, 0)
		cross_form := ui_axis_size(c, 1 - axis)
		cross := cross_avail
		align := node.align
		if cross_form.form != .Auto {
			nw, nh := ui_measure(editor, c, main if axis == 0 else cross_avail, main if axis == 1 else cross_avail)
			cross = ui_size_resolve(cross_form, cross_avail, nh if axis == 0 else nw)
			if align == .Stretch {
				align = .Start
			}
		}
		cross_lead := c.margin[3] if axis == 1 else c.margin[0]
		cross_pos := (content.x if axis == 1 else content.y) + cross_lead
		switch align {
		case .Stretch, .Start:
		case .Center:
			if (cross_avail - cross) % 2 != 0 {
				cross -= 1
			}
			cross_pos += (cross_avail - cross) / 2
		case .End:
			cross_pos += cross_avail - cross
		}
		r: Rect
		if axis == 1 {
			r = {cross_pos, pos + lead, cross, main}
		} else {
			r = {pos + lead, cross_pos, main, cross}
		}
		ui_layout_node(editor, c, r, node.clip)
		pos += main + margins[i] + sep
	}
}

ui_layout_float :: proc(editor: ^Editor, node: ^UiNode, parent: ^UiNode) {
	ref := ui_screen()
	if node.float == .Parent && parent != nil {
		ref = parent.rect
	}
	area := ui_rect_shrink(ref, node.margin)
	nw, nh := 0, 0
	if node.width.form == .Auto || node.width.form == .Fit || node.height.form == .Auto || node.height.form == .Fit {
		nw, nh = ui_measure(editor, node, area.w if node.width.form != .Cells else node.width.value, area.h)
	}
	w := ui_size_resolve(node.width, area.w, nw)
	if node.height.form == .Fit || node.height.form == .Auto {
		_, nh = ui_measure(editor, node, w, area.h)
	}
	h := ui_size_resolve(node.height, area.h, nh)
	x, y := area.x, area.y
	center_x :: proc(area: Rect, w: ^int) -> int {
		if (area.w - w^) % 2 != 0 {
			w^ -= 1
		}
		return area.x + (area.w - w^) / 2
	}
	center_y :: proc(area: Rect, h: ^int) -> int {
		if (area.h - h^) % 2 != 0 {
			h^ -= 1
		}
		return area.y + (area.h - h^) / 2
	}
	switch node.anchor {
	case .Center:
		x = center_x(area, &w)
		y = center_y(area, &h)
	case .Top_Left:
	case .Top:
		x = center_x(area, &w)
	case .Top_Right:
		x = area.x + area.w - w
	case .Left:
		y = center_y(area, &h)
	case .Right:
		x = area.x + area.w - w
		y = center_y(area, &h)
	case .Bottom_Left:
		y = area.y + area.h - h
	case .Bottom:
		x = center_x(area, &w)
		y = area.y + area.h - h
	case .Bottom_Right:
		x = area.x + area.w - w
		y = area.y + area.h - h
	case .Cursor:
		cx, cy, ok := ui_editor_caret_pos(editor, parent)
		if !ok {
			node.hidden = true
			node.rect = {}
			return
		}
		x = clamp(cx, area.x, max(area.x + area.w - w, area.x))
		y = cy + 1
		if y + h > area.y + area.h && cy - h >= area.y {
			y = cy - h
		}
	}
	ui_layout_node(editor, node, {x, y, w, h}, ui_screen())
}

ui_editor_text_width :: proc(node: ^UiNode, b: ^Buffer) -> int {
	gutter := digit_count(len(b.lines)) + 2 if node.line_numbers else 0
	return max(node.rect.w - gutter, 0)
}

ui_editor_caret_pos :: proc(editor: ^Editor, node: ^UiNode) -> (x, y: int, ok: bool) {
	if node == nil || node.kind != .Editor {
		return
	}
	b := ui_buffer(editor, node.buffer)
	if b == nil {
		return
	}
	state := ui_state(&editor.ui, node.identity)
	gutter := digit_count(len(b.lines)) + 2 if node.line_numbers else 0
	w := ui_editor_text_width(node, b)
	text := b.lines[b.cursor.row].text[:]
	if b.cursor.row < state.scroll_row {
		return
	}
	cx, cy: int
	if b.wrap && w > 0 {
		segs := buffer_line_wrap(b, b.cursor.row, w)
		sub := wrap_subrow(segs, b.cursor.col)
		if b.cursor.row == state.scroll_row && sub < state.scroll_sub {
			return
		}
		cx = visual_col(text, b.cursor.col) - visual_col(text, segs[sub])
		cy = vpos_dist(b, w, state.scroll_row, state.scroll_sub, b.cursor.row, sub, node.rect.h + 1)
	} else {
		cx = visual_col(text, b.cursor.col) - state.scroll_col
		cy = b.cursor.row - state.scroll_row
	}
	if cy < 0 || cy >= node.rect.h || cx < 0 || cx >= w {
		return
	}
	return node.rect.x + gutter + cx, node.rect.y + cy, true
}

ui_editor_reveal :: proc(editor: ^Editor, node: ^UiNode) {
	b := ui_buffer(editor, node.buffer)
	state := ui_state(&editor.ui, node.identity)
	if b == nil {
		return
	}
	if b.cursor != state.cursor_seen || b.rev != state.rev_seen {
		state.cursor_seen = b.cursor
		state.rev_seen = b.rev
		state.reveal = true
	}
	state.scroll_row = clamp(state.scroll_row, 0, len(b.lines) - 1)
	if !state.reveal {
		return
	}
	state.reveal = false
	w := ui_editor_text_width(node, b)
	h := node.rect.h
	if h <= 0 || w <= 0 {
		return
	}
	if b.cursor.row < state.scroll_row {
		state.scroll_row = b.cursor.row
		state.scroll_sub = 0
	}
	if b.wrap {
		state.scroll_col = 0
		segs := buffer_line_wrap(b, b.cursor.row, w)
		sub := wrap_subrow(segs, b.cursor.col)
		if b.cursor.row == state.scroll_row && sub < state.scroll_sub {
			state.scroll_sub = sub
		}
		for vpos_dist(b, w, state.scroll_row, state.scroll_sub, b.cursor.row, sub, h + 1) >= h {
			if state.scroll_sub + 1 < line_rows(b, w, state.scroll_row) {
				state.scroll_sub += 1
			} else {
				state.scroll_row += 1
				state.scroll_sub = 0
			}
		}
		return
	}
	state.scroll_sub = 0
	if b.cursor.row >= state.scroll_row + h {
		state.scroll_row = b.cursor.row - h + 1
	}
	vx := visual_col(b.lines[b.cursor.row].text[:], b.cursor.col)
	if vx < state.scroll_col {
		state.scroll_col = vx
	} else if vx >= state.scroll_col + w {
		state.scroll_col = vx - w + 1
	}
}

ui_layout :: proc(editor: ^Editor) {
	screen := ui_screen()
	for layer in UI_LAYERS {
		for m in editor.ui.mounts {
			if m.outlet != layer {
				continue
			}
			root := m.root
			if root.float != .None {
				ui_layout_float(editor, root, nil)
			} else {
				ui_layout_node(editor, root, ui_rect_shrink(screen, root.margin), screen)
			}
		}
	}
}

ui_enclosing_scroll :: proc(node: ^UiNode) -> ^UiNode {
	for p := node.parent; p != nil; p = p.parent {
		if p.kind == .Scroll {
			return p
		}
		if p.float != .None {
			return nil
		}
	}
	return nil
}

ui_scroll_content :: proc(editor: ^Editor, scroll: ^UiNode) -> Rect {
	content := scroll.rect
	content.w = max(content.w - 1, 0)
	if scroll.header != nil {
		content.y += scroll.header.rect.h
		content.h -= scroll.header.rect.h
	}
	return content
}

ui_reveal_row :: proc(editor: ^Editor, node: ^UiNode, row_y, row_h: int) -> bool {
	scroll := ui_enclosing_scroll(node)
	if scroll == nil {
		return false
	}
	state := ui_state(&editor.ui, scroll.identity)
	content := ui_scroll_content(editor, scroll)
	top := row_y - (content.y - state.offset)
	before := state.offset
	if top < state.offset {
		state.offset = top
	} else if top + row_h > state.offset + content.h {
		state.offset = top + row_h - content.h
	}
	return state.offset != before
}

ui_prepare :: proc(editor: ^Editor) {
	ui := &editor.ui
	ui_graveyard_flush(editor)
	ui_resolve(editor)
	ui_focused(editor)
	if len(ui.mounts) == 0 {
		return
	}
	for n in ui.virtuals {
		if list := ui_list_find(ui, n.list); list != nil {
			ui_list_settle_all(editor, list)
		}
	}
	for n in ui.editors {
		if b := ui_buffer(editor, n.buffer); b != nil && n.wrap_set {
			b.wrap = n.wrap
		}
	}
	for pass in 0 ..< 3 {
		ui_layout(editor)
		moved := false
		for n in ui.virtuals {
			ui_virtual_build(editor, n)
			if ui_virtual_reveal(editor, n) {
				moved = true
			}
		}
		for _, n in ui.index {
			if n.kind == .Column || n.kind == .Row {
				if ui_container_reveal(editor, n) {
					moved = true
				}
			}
		}
		for n in ui.editors {
			ui_editor_reveal(editor, n)
		}
		if !moved && pass > 0 {
			break
		}
	}
	for n in ui.editors {
		b := ui_buffer(editor, n.buffer)
		if b != nil && n.highlight && !b.big && n.rect.h > 0 {
			state := ui_state(ui, n.identity)
			highlight_update(b, state.scroll_row, state.scroll_row + n.rect.h - 1)
			diffbase_update(b)
		}
	}
}

ui_container_reveal :: proc(editor: ^Editor, node: ^UiNode) -> bool {
	state, ok := &editor.ui.states[node.identity]
	if !ok || !state.reveal || state.highlighted == "" {
		return false
	}
	state.reveal = false
	for c in node.expanded {
		if c.key == state.highlighted && !c.hidden {
			return ui_reveal_row(editor, node, c.rect.y, c.rect.h)
		}
	}
	return false
}

ui_virtual_window :: proc(node: ^UiNode, count: int) -> (lo, hi: int) {
	view := ui_rect_intersect(node.rect, node.clip)
	if view.h <= 0 {
		return 0, 0
	}
	lo = clamp(view.y - node.rect.y, 0, count)
	hi = clamp(view.y + view.h - node.rect.y, lo, count)
	return
}

ui_virtual_build :: proc(editor: ^Editor, node: ^UiNode) {
	list := ui_list_find(&editor.ui, node.list)
	if list == nil {
		return
	}
	ui_list_settle_all(editor, list)
	if node.items_rev != list.rev {
		node.items_rev = list.rev
		stale := make([dynamic]string, context.temp_allocator)
		for k, item in node.items {
			pos, present := ui_list_position(list, k)
			if !present || ui_list_record_rev(list, pos) != item.rev {
				append(&stale, k)
			}
		}
		for k in stale {
			key, item := delete_key(&node.items, k)
			ui_node_free(editor, item.node)
			delete(key)
		}
	}
	lo, hi := ui_virtual_window(node, ui_list_count(list))
	node.window_lo, node.window_hi = lo, hi
	for i in lo ..< hi {
		key := ui_list_key(list, i)
		item, cached := node.items[key]
		if !cached {
			built := ui_item_build(editor, node, list, i)
			if built == nil {
				continue
			}
			item = UiItem{built, ui_list_record_rev(list, i)}
			node.items[strings.clone(key)] = item
			built.parent = node
			visiting := make(map[u64]bool, 1, context.temp_allocator)
			ui_resolve_node(editor, built, &visiting)
		}
		item.node.parent = node
		ui_layout_node(editor, item.node, ui_rect_shrink({node.rect.x, node.rect.y + i, node.rect.w, 1}, item.node.margin), node.clip)
	}
}

ui_virtual_reveal :: proc(editor: ^Editor, node: ^UiNode) -> bool {
	state, ok := &editor.ui.states[node.identity]
	if !ok || !state.reveal || state.highlighted == "" {
		return false
	}
	state.reveal = false
	list := ui_list_find(&editor.ui, node.list)
	if list == nil {
		return false
	}
	pos, present := ui_list_position(list, state.highlighted)
	if !present {
		return false
	}
	return ui_reveal_row(editor, node, node.rect.y + pos, 1)
}

ui_color :: proc(key: string, fallback: tb2.Color) -> tb2.Color {
	if key == "" {
		return fallback
	}
	return g_theme_colors[key] or_else fallback
}

ui_style_over :: proc(base, top: UiStyle) -> UiStyle {
	out := base
	if .Fg in top.set {
		out.fg = top.fg
	}
	if .Bg in top.set {
		out.bg = top.bg
	}
	if .Bold in top.set {
		out.bold = top.bold
	}
	if .Italic in top.set {
		out.italic = top.italic
	}
	if .Underline in top.set {
		out.underline = top.underline
	}
	out.set = base.set + top.set
	return out
}

ui_style_colors :: proc(s: UiStyle, fg, bg: tb2.Color) -> (tb2.Color, tb2.Color) {
	f := ui_color(s.fg, fg) if .Fg in s.set else fg
	g := ui_color(s.bg, bg) if .Bg in s.set else bg
	attrs := u64(0)
	if s.bold {
		attrs |= u64(tb2.Color.Bold)
	}
	if s.italic {
		attrs |= u64(tb2.Color.Italic)
	}
	if s.underline {
		attrs |= u64(tb2.Color.Underline)
	}
	return tb2.Color(u64(f) | attrs), g
}

UiPaint :: struct {
	clip:     Rect,
	inherit:  UiStyle,
	override: UiStyle,
	bg:       tb2.Color,
}

ui_cell :: proc(p: ^UiPaint, x, y: int, r: rune, fg, bg: tb2.Color) {
	if ui_rect_has(p.clip, x, y) {
		tb2.set_cell(i32(x), i32(y), r, fg, bg)
	}
}

ui_fill :: proc(p: ^UiPaint, r: Rect, bg: tb2.Color) {
	area := ui_rect_intersect(r, p.clip)
	for y in area.y ..< area.y + area.h {
		for x in area.x ..< area.x + area.w {
			tb2.set_cell(i32(x), i32(y), ' ', COLOR_FG, bg)
		}
	}
}

ui_render :: proc(editor: ^Editor) {
	ui := &editor.ui
	clear(&ui.hits)
	ui.caret_shown = false
	floats := make([dynamic]^UiNode, context.temp_allocator)
	for layer in UI_LAYERS {
		clear(&floats)
		for m in ui.mounts {
			if m.outlet != layer {
				continue
			}
			if m.root.float != .None {
				append(&floats, m.root)
				continue
			}
			paint := UiPaint{clip = ui_screen(), bg = COLOR_BG}
			ui_render_node(editor, m.root, &paint, &floats)
		}
		for i := 0; i < len(floats); i += 1 {
			n := floats[i]
			paint := UiPaint{clip = ui_screen(), bg = COLOR_BG}
			if n.parent != nil {
				paint.inherit = ui_inherited(n.parent)
				paint.bg = ui_inherited_bg(n.parent)
			}
			ui_render_node(editor, n, &paint, &floats)
		}
	}
	if f := ui_focused(editor); f != nil && f.kind == .Editor && !f.hidden {
		if x, y, ok := ui_editor_caret_pos(editor, f); ok && ui_rect_has(f.clip, x, y) {
			ui.caret = {x, y}
			ui.caret_shown = true
		}
	}
}

ui_inherited :: proc(node: ^UiNode) -> UiStyle {
	if node == nil {
		return {}
	}
	return ui_style_over(ui_inherited(node.parent), node.style)
}

ui_inherited_bg :: proc(node: ^UiNode) -> tb2.Color {
	s := ui_inherited(node)
	return ui_color(s.bg, COLOR_BG) if .Bg in s.set else COLOR_BG
}

ui_render_node :: proc(editor: ^Editor, node: ^UiNode, parent: ^UiPaint, floats: ^[dynamic]^UiNode) {
	if node.hidden || node.rect.w <= 0 || node.rect.h <= 0 {
		return
	}
	paint := parent^
	paint.clip = node.clip
	paint.inherit = ui_style_over(parent.inherit, node.style)
	visible := ui_rect_intersect(node.rect, paint.clip)
	append(&editor.ui.hits, UiHit{node, visible})
	if .Bg in node.style.set || .Bg in paint.override.set {
		_, bg := ui_style_colors(ui_style_over(paint.inherit, paint.override), COLOR_FG, paint.bg)
		paint.bg = bg
		ui_fill(&paint, node.rect, bg)
	}
	state := editor.ui.states[node.identity] or_else UiState{}
	switch node.kind {
	case .Text:
		ui_render_text(&paint, node)
	case .Box:
		if node.border {
			ui_render_border(&paint, node)
		}
	case .Scroll:
		content := ui_scroll_content(editor, node)
		for c in node.expanded {
			if c.float == .None {
				total := c.rect.h + c.margin[0] + c.margin[2]
				if total > content.h {
					start, length := pane_scrollbar_thumb(state.offset, content.h, total)
					fg, _ := ui_style_colors(paint.inherit, COLOR_PANE_BORDER, paint.bg)
					for i in 0 ..< length {
						ui_cell(&paint, content.x + content.w, content.y + start + i, '┃', fg, paint.bg)
					}
				}
				break
			}
		}
	case .Editor:
		ui_render_editor(editor, &paint, node)
	case .Virtual_Column:
		list := ui_list_find(&editor.ui, node.list)
		if list != nil {
			for i in node.window_lo ..< min(node.window_hi, ui_list_count(list)) {
				key := ui_list_key(list, i)
				item, ok := node.items[key]
				if !ok {
					continue
				}
				child := paint
				if state.highlighted != "" && key == state.highlighted {
					child.override = ui_style_over(paint.override, node.highlight_style)
				}
				ui_render_node(editor, item.node, &child, floats)
			}
		}
	case .Column, .Row, .Outlet:
	}
	if node.header != nil {
		ui_render_node(editor, node.header, &paint, floats)
	}
	for c in node.expanded {
		if c.float != .None {
			append(floats, c)
			continue
		}
		child := paint
		if state.highlighted != "" && c.key == state.highlighted {
			child.override = ui_style_over(paint.override, node.highlight_style)
		}
		ui_render_node(editor, c, &child, floats)
	}
	if node.separator && (node.kind == .Column || node.kind == .Row) {
		ui_render_separators(&paint, node)
	}
}

ui_render_border :: proc(p: ^UiPaint, node: ^UiNode) {
	r := node.rect
	fg, _ := ui_style_colors(ui_style_over(p.inherit, p.override), COLOR_PANE_BORDER, p.bg)
	if .Fg not_in node.style.set {
		fg = COLOR_PANE_BORDER
	}
	x1, y1 := r.x + r.w - 1, r.y + r.h - 1
	for x in r.x + 1 ..< x1 {
		ui_cell(p, x, r.y, '─', fg, p.bg)
		ui_cell(p, x, y1, '─', fg, p.bg)
	}
	for y in r.y + 1 ..< y1 {
		ui_cell(p, r.x, y, '│', fg, p.bg)
		ui_cell(p, x1, y, '│', fg, p.bg)
	}
	ui_cell(p, r.x, r.y, '┌', fg, p.bg)
	ui_cell(p, x1, r.y, '┐', fg, p.bg)
	ui_cell(p, r.x, y1, '└', fg, p.bg)
	ui_cell(p, x1, y1, '┘', fg, p.bg)
	if node.title != "" && r.w > 4 {
		title_fg, _ := ui_style_colors(ui_style_over(p.inherit, p.override), COLOR_PANE_FG, p.bg)
		ui_draw_text(p, r.x + 2, r.y, r.w - 4, fmt.tprintf(" %s ", node.title), title_fg, p.bg)
	}
}

ui_render_separators :: proc(p: ^UiPaint, node: ^UiNode) {
	prev: ^UiNode
	for c in node.expanded {
		if c.float != .None || c.hidden {
			continue
		}
		if prev != nil {
			if node.kind == .Column {
				y := c.rect.y - c.margin[0] - 1
				for x in node.rect.x ..< node.rect.x + node.rect.w {
					ui_cell(p, x, y, '─', COLOR_PANE_BORDER, p.bg)
				}
			} else {
				x := c.rect.x - c.margin[3] - 1
				for y in node.rect.y ..< node.rect.y + node.rect.h {
					ui_cell(p, x, y, '│', COLOR_PANE_BORDER, p.bg)
				}
			}
		}
		prev = c
	}
}

ui_draw_text :: proc(p: ^UiPaint, x, y, w: int, text: string, fg, bg: tb2.Color) -> int {
	bytes := transmute([]u8)text
	col := 0
	i := 0
	for i < len(bytes) && col < w {
		e := cluster_end(bytes, i)
		cw := seg_width(bytes, i, e, col)
		if col + cw > w {
			break
		}
		if bytes[i] == '\t' {
			for k in 0 ..< cw {
				ui_cell(p, x + col + k, y, ' ', fg, bg)
			}
		} else if ui_rect_has(p.clip, x + col, y) && ui_rect_has(p.clip, x + col + cw - 1, y) {
			cell_put_cluster(x + col, y, bytes[i:e], fg, bg)
		}
		col += cw
		i = e
	}
	return col
}

ui_render_text :: proc(p: ^UiPaint, node: ^UiNode) {
	r := node.rect
	lines := ui_text_wrapped(node, r.w)
	for line, row in lines {
		if row >= r.h {
			break
		}
		y := r.y + row
		width := ui_spans_width(line[:])
		x := r.x
		switch node.text_align {
		case .Center:
			x += max(r.w - width, 0) / 2
		case .End:
			x += max(r.w - width, 0)
		case .Stretch, .Start:
		}
		col := x - r.x
		overflow := width > r.w
		limit := r.w - 1 if overflow else r.w
		last_fg, last_bg := COLOR_FG, p.bg
		for s in line {
			style := ui_style_over(ui_style_over(p.inherit, s.style), p.override)
			fg, bg := ui_style_colors(style, COLOR_FG, p.bg)
			last_fg, last_bg = fg, bg
			if col >= limit {
				break
			}
			drawn := ui_draw_text(p, r.x + col, y, limit - col, s.text, fg, bg)
			col += drawn
			if drawn < visual_width(transmute([]u8)s.text) {
				break
			}
		}
		if overflow && r.w > 0 {
			ui_cell(p, r.x + r.w - 1, y, '…', last_fg, last_bg)
		}
	}
}

ui_render_editor :: proc(editor: ^Editor, p: ^UiPaint, node: ^UiNode) {
	b := ui_buffer(editor, node.buffer)
	if b == nil {
		return
	}
	state := ui_state(&editor.ui, node.identity)
	r := ui_rect_intersect(node.rect, p.clip)
	if r.w <= 0 || r.h <= 0 {
		return
	}
	gutter := digit_count(len(b.lines)) + 2 if node.line_numbers else 0
	w := ui_editor_text_width(node, b)
	b.wrap_width = w
	base := ui_style_over(p.inherit, p.override)
	fg_base, bg := ui_style_colors(base, COLOR_FG, p.bg)
	sel_from, sel_to, sel_ok := selection_range(b)
	focused := editor.ui.focus == node.identity
	y := node.rect.y
	bottom := node.rect.y + node.rect.h
	for row := state.scroll_row; row < len(b.lines) && y < bottom; row += 1 {
		text := b.lines[row].text[:]
		current := row == b.cursor.row && focused
		line_bg := bg
		if current && .Bg in node.current_line.set {
			_, line_bg = ui_style_colors(node.current_line, fg_base, bg)
		}
		colors: []tb2.Color
		if node.highlight && !b.big {
			colors = highlight_colors(b, row)
		}
		if len(colors) == 0 && .Fg in base.set {
			colors = make([]tb2.Color, len(text), context.temp_allocator)
			slice.fill(colors, fg_base)
		}
		rs, re := -1, -1
		if sel_ok && row >= sel_from.row && row <= sel_to.row {
			rs = sel_from.col if row == sel_from.row else 0
			re = sel_to.col if row == sel_to.row else len(text) + 1
		}
		segs: []int
		if b.wrap && w > 0 {
			segs = buffer_line_wrap(b, row, w)
		} else {
			segs = {0}
		}
		start_sub := state.scroll_sub if row == state.scroll_row && b.wrap else 0
		x_origin := state.scroll_col if !b.wrap else (visual_col(text, segs[start_sub]) if start_sub < len(segs) else 0)
		for s in start_sub ..< len(segs) {
			if y >= bottom {
				break
			}
			seg_start := segs[s]
			seg_end := segs[s + 1] if s + 1 < len(segs) else len(text)
			if !b.wrap {
				seg_start, seg_end = 0, len(text)
			}
			if node.line_numbers {
				ui_render_gutter(p, node.rect.x, y, gutter, row + 1 if s == start_sub || s == 0 else 0, current)
			}
			if y >= r.y && y < r.y + r.h {
				editor_render_text_row(node.rect.x + gutter, y, w, text, colors, x_origin, line_bg, rs, re, nil, seg_start, seg_end)
			}
			if b.wrap {
				x_origin = visual_col_from(text, seg_start, x_origin, seg_end)
			}
			y += 1
		}
	}
	for ; y < bottom; y += 1 {
		if node.line_numbers {
			ui_render_gutter(p, node.rect.x, y, gutter, 0, false)
		}
		ui_fill(p, {node.rect.x + gutter, y, w, 1}, bg)
	}
	if len(b.lines) == 1 && len(b.lines[0].text) == 0 && node.placeholder != "" {
		ui_draw_text(p, node.rect.x + gutter, node.rect.y, w, node.placeholder, COLOR_PANE_DIM_FG, bg)
	}
}

ui_render_gutter :: proc(p: ^UiPaint, x, y, width, number: int, current: bool) {
	fg := COLOR_CURRENT_LINE_FG if current else COLOR_GUTTER_FG
	for i in 0 ..< width {
		ui_cell(p, x + i, y, ' ', fg, COLOR_GUTTER_BG)
	}
	if number > 0 {
		label := fmt.tprintf("%d", number)
		ui_draw_text(p, x + width - 1 - len(label), y, len(label), label, fg, COLOR_GUTTER_BG)
	}
}

ui_chord_of_event :: proc(ev: tb2.Event, allocator := context.temp_allocator) -> string {
	if ev.type != .Key {
		return ""
	}
	alt := ev_alt(ev)
	shift := ev_shift(ev)
	ctrl := ev_ctrl(ev)
	if ev.ch != 0 {
		name := "Space" if ev.ch == ' ' else fmt.tprintf("%c", ev.ch)
		return ui_chord_build(false, alt, false, name, allocator)
	}
	name := ""
	control_byte := false
	switch u16(ev.key) {
	case 0x00:
		name, ctrl = "~", true
	case 0x08:
		name, ctrl = "h", true
	case 0x09:
		name, control_byte = "Tab", true
	case 0x0d:
		name, control_byte = "Enter", true
	case 0x1b:
		name, control_byte = "Esc", true
	case 0x1c:
		name, ctrl = "\\", true
	case 0x1f:
		name, ctrl = "/", true
	case 0x20:
		name = "Space"
	case 0x7f:
		name, control_byte = "Backspace", true
	case 0x01 ..= 0x1a:
		name, ctrl = fmt.tprintf("%c", 'a' + rune(ev.key) - 1), true
	case:
		#partial switch ev.key {
		case .Arrow_Up:
			name = "Up"
		case .Arrow_Down:
			name = "Down"
		case .Arrow_Left:
			name = "Left"
		case .Arrow_Right:
			name = "Right"
		case .Back_Tab:
			name, shift = "Tab", true
		case .Delete:
			name = "Delete"
		case .Insert:
			name = "Insert"
		case .Home:
			name = "Home"
		case .End:
			name = "End"
		case .Pgup:
			name = "PgUp"
		case .Pgdn:
			name = "PgDn"
		case .F1 ..= .F12:
			name = fmt.tprintf("F%d", 0xffff - int(ev.key) + 1)
		}
	}
	if name == "" {
		return ""
	}
	if control_byte {
		ctrl = false
	}
	return ui_chord_build(ctrl, alt, shift, name, allocator)
}

ui_chord_build :: proc(ctrl, alt, shift: bool, name: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s%s%s%s", "Ctrl+" if ctrl else "", "Alt+" if alt else "", "Shift+" if shift else "", name, allocator = allocator)
}

UI_NAMED_KEYS :: [?]string{"Up", "Down", "Left", "Right", "Enter", "Esc", "Tab", "Backspace", "Delete", "Insert", "Home", "End", "PgUp", "PgDn", "Space", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"}

ui_chord_parse :: proc(s: string) -> (ctrl, alt, shift: bool, name: string, ok: bool) {
	rest := s
	for {
		switch {
		case strings.has_prefix(rest, "Ctrl+") && len(rest) > 5:
			ctrl, rest = true, rest[5:]
			continue
		case strings.has_prefix(rest, "Alt+") && len(rest) > 4:
			alt, rest = true, rest[4:]
			continue
		case strings.has_prefix(rest, "Shift+") && len(rest) > 6:
			shift, rest = true, rest[6:]
			continue
		}
		break
	}
	for k in UI_NAMED_KEYS {
		if rest == k {
			return ctrl, alt, shift, rest, true
		}
	}
	if strings.equal_fold(rest, "escape") {
		return ctrl, alt, shift, "Esc", true
	}
	r, size := utf8.decode_rune_in_string(rest)
	if size == 0 || size != len(rest) || r == utf8.RUNE_ERROR {
		return
	}
	if ctrl && r >= 'A' && r <= 'Z' {
		rest = fmt.tprintf("%c", r + 32)
	}
	return ctrl, alt, shift, rest, true
}

ui_chord_normalize :: proc(s: string, allocator := context.temp_allocator) -> string {
	ctrl, alt, shift, name, ok := ui_chord_parse(s)
	if !ok {
		return ""
	}
	return ui_chord_build(ctrl, alt, shift, name, allocator)
}

ui_chord_named_key :: proc(s: string) -> (key: tb2.Key, ok: bool) {
	ctrl, alt, shift, name, parsed := ui_chord_parse(s)
	if !parsed {
		return
	}
	named := false
	for k in UI_NAMED_KEYS {
		named = named || k == name
	}
	if !named {
		return
	}
	if ctrl || alt || shift {
		return UI_KEY_CHORD_ONLY, true
	}
	switch name {
	case "Up":
		return .Arrow_Up, true
	case "Down":
		return .Arrow_Down, true
	case "Left":
		return .Arrow_Left, true
	case "Right":
		return .Arrow_Right, true
	case "Enter":
		return .Enter, true
	case "Esc":
		return .Esc, true
	case "Tab":
		return .Tab, true
	case "Backspace":
		return .Backspace2, true
	case "Delete":
		return .Delete, true
	case "Insert":
		return .Insert, true
	case "Home":
		return .Home, true
	case "End":
		return .End, true
	case "PgUp":
		return .Pgup, true
	case "PgDn":
		return .Pgdn, true
	case "Space":
		return .Space, true
	}
	return UI_KEY_CHORD_ONLY, true
}
