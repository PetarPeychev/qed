package main

import "core:fmt"
import "core:os"
import "core:io"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:sys/posix"
import "core:unicode/utf8"
import lua "lib:lua"
import "lib:tb2"

UI_LAYERS :: [?]string{"background", "base", "popup", "pane", "notification", "alert"}
UI_FOCUS_HISTORY_MAX :: 16
UI_KEY_CHORD_ONLY :: tb2.Key(0xff00)
UI_UNBOUNDED :: 1 << 30
UI_ITEM_KEEP :: 64

UiKind :: enum u8 {
	Column,
	Row,
	Box,
	Scroll,
	Text,
	Editor,
	Virtual_Column,
	Outlet,
	Image,
	Terminal,
	Markdown,
	Status,
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
	.Image          = "image",
	.Terminal       = "terminal",
	.Markdown       = "markdown",
	.Status         = "status",
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
	Link,
	State,
}

ui_event_names := [UiEvent]string {
	.Key          = "key",
	.Paste        = "paste",
	.Click        = "click",
	.Double_Click = "double_click",
	.Wheel        = "wheel",
	.Link         = "link",
	.State        = "state",
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
	follow:          bool,
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
	path:            string,
	source:          string,
	session:         string,
	line_numbers:    bool,
	syntax:          bool,
	readonly:        bool,
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
	extend_from: string,
	offset:      int,
	scroll_row:  int,
	scroll_sub:  int,
	scroll_col:  int,
	reveal:      bool,
	cursor_seen: Cursor,
	kept:        bool,
	at_end:      bool,
	buffer:      u64,
	md_source:   int,
	md_at:       int,
	md_heading:  string,
	md_found:    int,
	kind:        UiKind,
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
	results:       map[u64]i32,
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
	scopes_warned: map[string]bool,
	lists_dead:    [dynamic]u64,
	chords:        map[string]string,
	markdowns:     map[string]^UiMarkdown,
	editor_clicks: UiClicks,
}

UiClicks :: struct {
	count: int,
	tick:  time.Tick,
	pos:   Cursor,
	node:  u64,
}

ui_destroy :: proc(editor: ^Editor) {
	ui := &editor.ui
	for mount in ui.mounts {
		ui_node_free(editor, mount.root)
		delete(mount.outlet)
	}
	delete(ui.mounts)
	ui_graveyard_flush(editor)
	delete(ui.graveyard)
	ui_markdowns_free(editor)
	for key, state in ui.states {
		delete(key)
		delete(state.highlighted)
		delete(state.extend_from)
		delete(state.md_heading)
	}
	delete(ui.states)
	delete(ui.focus)
	for entry in ui.focus_history {
		delete(entry)
	}
	delete(ui.focus_history)
	delete(ui.index)
	delete(ui.virtuals)
	delete(ui.editors)
	delete(ui.results)
	// popped first: a list's free looks up the others, never one already freed
	for len(ui.lists) > 0 {
		ui_list_free(editor, pop(&ui.lists))
	}
	delete(ui.lists)
	delete(ui.hits)
	delete(ui.drag.node)
	for buffer in ui.internal {
		buffer_destroy(buffer)
		free(buffer)
	}
	delete(ui.internal)
	delete(ui.internal_owner)
	for scope, _ in ui.scopes_warned {
		delete(scope)
	}
	delete(ui.scopes_warned)
	delete(ui.lists_dead)
	for shortcut, chord in ui.chords {
		delete(shortcut)
		delete(chord)
	}
	delete(ui.chords)
}

ui_node_free :: proc(editor: ^Editor, node: ^UiNode) {
	if node == nil {
		return
	}
	for child in node.children {
		ui_node_free(editor, child)
	}
	ui_node_free(editor, node.header)
	for _, item in node.items {
		ui_node_free(editor, item.node)
	}
	for key, _ in node.items {
		delete(key)
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
	for scope in node.scope {
		delete(scope)
	}
	delete(node.scope)
	for span in node.spans {
		delete(span.text)
		ui_style_free(span.style)
	}
	delete(node.spans)
	ui_style_free(node.style)
	ui_style_free(node.highlight_style)
	delete(node.id)
	delete(node.key)
	delete(node.identity)
	delete(node.title)
	delete(node.placeholder)
	delete(node.path)
	delete(node.source)
	delete(node.session)
	free(node)
}

ui_style_free :: proc(style: UiStyle) {
	delete(style.fg)
	delete(style.bg)
}

ui_graveyard_flush :: proc(editor: ^Editor) {
	for node in editor.ui.graveyard {
		ui_node_free(editor, node)
	}
	clear(&editor.ui.graveyard)
}

ui_mount_index :: proc(ui: ^Ui, handle: u64) -> int {
	for mount, i in ui.mounts {
		if mount.handle == handle {
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
	prefix := fmt.tprintf("#%s/", owner)
	gone := make([dynamic]string, context.temp_allocator)
	for key, _ in ui.states {
		if strings.has_prefix(key, prefix) {
			append(&gone, key)
		}
	}
	ui_states_drop(ui, gone[:])
	for i := len(ui.lists) - 1; i >= 0; i -= 1 {
		if ui.lists[i].owner == owner {
			ui_list_free(editor, ui.lists[i])
			ordered_remove(&ui.lists, i)
		}
	}
	for i := len(ui.internal) - 1; i >= 0; i -= 1 {
		buffer := ui.internal[i]
		if ui.internal_owner[buffer.id] == owner {
			ui_internal_close(editor, buffer.id)
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
	for child, i in node.children {
		delete(child.identity)
		if child.id != "" {
			child.identity = strings.clone(fmt.tprintf("#%s/%s", child.owner, child.id))
		} else if child.key != "" {
			child.identity = strings.clone(fmt.tprintf("%s/k%s", node.identity, child.key))
		} else {
			child.identity = strings.clone(fmt.tprintf("%s/%s%d", node.identity, ui_kind_names[child.kind], node.child_slots[i]))
		}
		ui_children_identify(child, handle)
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
	for child in node.children {
		ui_tree_collect(child, into)
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
	for child in node.children {
		ui_tree_carry_walk(L, child, olds)
	}
	if node.header != nil {
		ui_tree_carry_walk(L, node.header, olds)
	}
}

ui_state_key :: proc(ui: ^Ui, key: string, kept: bool, buffer: u64 = 0) -> ^UiState {
	if state, ok := &ui.states[key]; ok {
		return state
	}
	ui.states[strings.clone(key)] = {kept = kept, buffer = buffer}
	return &ui.states[key]
}

ui_node_state :: proc(ui: ^Ui, node: ^UiNode) -> ^UiState {
	state: ^UiState
	if node.kind == .Editor {
		state = ui_state_key(ui, fmt.tprintf("%s|%d", node.identity, node.buffer), node.id != "", node.buffer)
	} else {
		state = ui_state_key(ui, node.identity, node.id != "")
	}
	state.kind = node.kind
	return state
}

ui_highlight_present :: proc(editor: ^Editor, node: ^UiNode, key: string) -> bool {
	if node.kind == .Virtual_Column {
		list := ui_list_find(&editor.ui, node.list)
		if list == nil {
			return false
		}
		ui_list_settle_all(editor, list)
		_, present := ui_list_position(list, key)
		return present
	}
	for child in node.expanded {
		if child.key == key {
			return true
		}
	}
	return false
}

ui_node_state_peek :: proc(ui: ^Ui, node: ^UiNode) -> UiState {
	if node.kind == .Editor {
		return ui.states[fmt.tprintf("%s|%d", node.identity, node.buffer)] or_else UiState{}
	}
	return ui.states[node.identity] or_else UiState{}
}

ui_states_drop :: proc(ui: ^Ui, gone: []string) {
	for key in gone {
		owned, state := delete_key(&ui.states, key)
		delete(owned)
		delete(state.highlighted)
		delete(state.extend_from)
		delete(state.md_heading)
	}
}

ui_state_prune :: proc(editor: ^Editor) {
	ui := &editor.ui
	gone := make([dynamic]string, context.temp_allocator)
	for key, state in ui.states {
		identity := key
		if bar := strings.index_byte(key, '|'); bar >= 0 {
			identity = key[:bar]
		}
		buffer_gone := state.buffer != 0 && ui_buffer(editor, state.buffer) == nil
		if buffer_gone || (!state.kept && identity not_in ui.index) {
			append(&gone, key)
		}
	}
	ui_states_drop(ui, gone[:])
}

ui_layer_used :: proc(ui: ^Ui, layer: string) -> bool {
	for mount in ui.mounts {
		if mount.outlet == layer {
			return true
		}
	}
	return false
}

ui_is_layer :: proc(name: string) -> bool {
	for layer in UI_LAYERS {
		if layer == name {
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
	for mount in ui.mounts {
		mount.root.parent = nil
	}
	for layer in UI_LAYERS {
		for mount in ui.mounts {
			if mount.outlet == layer {
				mount.root.parent = nil
				ui_resolve_node(editor, mount.root, &visiting)
			}
		}
	}
	ui_state_prune(editor)
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
	for child in node.children {
		if child.kind != .Outlet {
			child.parent = node
			append(&node.expanded, child)
			ui_resolve_node(editor, child, visiting)
			continue
		}
		ui.index[child.identity] = child
		child.parent = node
		if child.id == "" {
			continue
		}
		for mount in ui.mounts {
			if mount.outlet != child.id || visiting[mount.handle] {
				continue
			}
			visiting[mount.handle] = true
			mount.root.parent = node
			append(&node.expanded, mount.root)
			ui_resolve_node(editor, mount.root, visiting)
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
		if node := ui_find(ui, ui.focus); node != nil {
			return node
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
		for entry, i in ui.focus_history {
			if entry == ui.focus {
				delete(entry)
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
	for buffer in editor.ui.internal {
		if buffer.id == id {
			return buffer
		}
	}
	if editor.welcome {
		return nil
	}
	for &buffer in editor.buffers {
		if buffer.id == id {
			return &buffer
		}
	}
	return nil
}

ui_internal_create :: proc(editor: ^Editor, owner: string) -> ^Buffer {
	buffer := new(Buffer)
	buffer^ = buffer_new()
	buffer.internal = true
	buffer.wrap = false
	buffer.plugin_seen = true
	buffer.plugin_rev = buffer.rev
	append(&editor.ui.internal, buffer)
	editor.ui.internal_owner[buffer.id] = owner
	return buffer
}

// a copy for showing a file: an open buffer's live text, else the head of the file on disk
ui_internal_load :: proc(editor: ^Editor, buffer: ^Buffer, path: string) {
	text := ""
	if index := editor_find_buffer(editor, path); index >= 0 {
		text = buffer_snapshot(&editor.buffers[index], context.temp_allocator)
	} else if info, ok := fs_stat(path); !ok || !posix.S_ISREG(info.st_mode) {
		// a fifo or device would block the read
		text = ""
	} else if data, read_ok := ui_preview_read(path); read_ok {
		text, _ = strings.replace_all(string(data), "\r\n", "\n", context.temp_allocator)
	}
	if data := transmute([]u8)text; preview_is_binary(data[:min(len(data), PREVIEW_HEX_BYTES * PREVIEW_MAX_LINES)]) {
		sb := strings.builder_make(context.temp_allocator)
		for offset := 0; offset < len(data) && offset < PREVIEW_HEX_BYTES * PREVIEW_MAX_LINES; offset += PREVIEW_HEX_BYTES {
			line := hex_dump_line(data[offset:min(offset + PREVIEW_HEX_BYTES, len(data))], offset)
			strings.write_string(&sb, line)
			strings.write_byte(&sb, '\n')
			delete(line)
		}
		buffer_set_text(buffer, strings.to_string(sb))
		buffer.cursor = {}
		buffer.plugin_rev = buffer.rev
		return
	}
	buffer_set_text(buffer, text)
	editor_set_language(editor, buffer, language_of(path))
	buffer.cursor = {}
	buffer.plugin_rev = buffer.rev
}

// the file (at most PREVIEW_MAX_BYTES), cut back to the last whole line when it is longer: every row a pick or
// search lists in it is in one copy
ui_preview_read :: proc(path: string) -> (data: []u8, ok: bool) {
	fd, err := os.open(path)
	if err != nil {
		return nil, false
	}
	defer os.close(fd)
	out := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	chunk: [64 * 1024]u8
	for {
		n, read_err := os.read(fd, chunk[:])
		if n <= 0 {
			if read_err != nil && read_err != io.Error.EOF {
				return nil, false
			}
			return out[:], true
		}
		append(&out, ..chunk[:n])
		if len(out) >= PREVIEW_MAX_BYTES {
			break
		}
	}
	end := min(len(out), PREVIEW_MAX_BYTES)
	if last := strings.last_index_byte(string(out[:end]), '\n'); last >= 0 {
		end = last + 1
	}
	return out[:end], true
}

ui_internal_close :: proc(editor: ^Editor, id: u64) -> bool {
	plugin_buffer_hooks_drop(&editor.plugins, id)
	searches_buffer_closed(editor, id)
	ui := &editor.ui
	for buffer, i in ui.internal {
		if buffer.id == id {
			buffer_destroy(buffer)
			free(buffer)
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

ui_rect_shrink :: proc(rect: Rect, margin: [4]int) -> Rect {
	out := Rect{rect.x + margin[3], rect.y + margin[0], rect.w - margin[1] - margin[3], rect.h - margin[0] - margin[2]}
	out.w = max(out.w, 0)
	out.h = max(out.h, 0)
	return out
}

ui_rect_intersect :: proc(first, second: Rect) -> Rect {
	x0 := max(first.x, second.x)
	y0 := max(first.y, second.y)
	x1 := min(first.x + first.w, second.x + second.w)
	y1 := min(first.y + first.h, second.y + second.h)
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

ui_rect_has :: proc(rect: Rect, cell_x, cell_y: int) -> bool {
	return cell_x >= rect.x && cell_y >= rect.y && cell_x < rect.x + rect.w && cell_y < rect.y + rect.h
}

ui_size_clamp :: proc(size: UiSize, value, avail: int) -> int {
	value := value
	if size.max > 0 {
		value = min(value, size.max)
	}
	value = max(value, size.min)
	return clamp(value, 0, max(avail, 0))
}

ui_size_resolve :: proc(size: UiSize, avail, natural: int) -> int {
	value := natural
	switch size.form {
	case .Cells:
		value = size.value
	case .Percent:
		value = max(avail, 0) * size.value / 100
	case .Fit, .Auto:
		value = natural
	}
	return ui_size_clamp(size, value, avail)
}

ui_snap :: proc(size: UiSize, value, avail: int) -> int {
	if size.form != .Percent || (avail - value) % 2 == 0 || value - 1 < size.min || value <= 0 {
		return value
	}
	return value - 1
}

ui_grows :: proc(node: ^UiNode, axis: int) -> int {
	if node.grow_set {
		return node.grow
	}
	if node.kind == .Editor || node.kind == .Terminal {
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
	for span in node.spans {
		rest := span.text
		for {
			nl := strings.index_byte(rest, '\n')
			part := rest if nl < 0 else rest[:nl]
			if len(part) > 0 {
				append(&lines[len(lines) - 1], UiSpan{part, span.style})
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
	width := 0
	for span in spans {
		width = visual_col_from(transmute([]u8)span.text, 0, width, len(span.text))
	}
	return width
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
		for span in line {
			bytes := transmute([]u8)span.text
			start := 0
			i := 0
			for i < len(bytes) {
				next_index := cluster_end(bytes, i)
				cw := seg_width(bytes, i, next_index, col)
				if col + cw > width && col > 0 {
					if i > start {
						append(&cur, UiSpan{span.text[start:i], span.style})
					}
					append(&out, cur)
					cur = make([dynamic]UiSpan, context.temp_allocator)
					col = 0
					start = i
					continue
				}
				col += cw
				i = next_index
			}
			if i > start {
				append(&cur, UiSpan{span.text[start:i], span.style})
			}
		}
		append(&out, cur)
	}
	return out
}

ui_measure :: proc(editor: ^Editor, node: ^UiNode, avail_w, avail_h: int) -> (width, height: int) {
	switch node.kind {
	case .Text:
		lines := ui_text_wrapped(node, avail_w)
		for line in lines {
			width = max(width, ui_spans_width(line[:]))
		}
		height = len(lines)
	case .Column, .Row:
		axis := 1 if node.kind == .Column else 0
		main, cross := 0, 0
		count := 0
		for child in node.expanded {
			if child.float != .None {
				continue
			}
			cw, ch := ui_measure_slot(editor, child, avail_w, avail_h)
			sizes := [2]int{cw, ch}
			if ui_grows(child, axis) > 0 && ui_axis_size(child, axis).form == .Auto {
				sizes[axis] = ui_axis_size(child, axis).min + (child.margin[0] + child.margin[2] if axis == 1 else child.margin[1] + child.margin[3])
			}
			main += sizes[axis]
			cross = max(cross, sizes[1 - axis])
			count += 1
		}
		if count > 1 {
			main += (count - 1) * (node.gap + (1 if node.separator else 0))
		}
		if axis == 1 {
			width, height = cross, main
		} else {
			width, height = main, cross
		}
	case .Box:
		inset := 2 if node.border else 0
		for child in node.expanded {
			if child.float == .None {
				width, height = ui_measure_slot(editor, child, avail_w - inset, avail_h - inset)
				break
			}
		}
		width += inset
		height += inset
		if node.border && node.title != "" {
			width = max(width, visual_width(transmute([]u8)node.title) + 4)
		}
	case .Scroll:
		hw, hh := 0, 0
		if node.header != nil {
			hw, hh = ui_measure_slot(editor, node.header, avail_w - 1, avail_h)
		}
		for child in node.expanded {
			if child.float == .None {
				width, height = ui_measure_slot(editor, child, avail_w - 1, UI_UNBOUNDED)
				break
			}
		}
		width = max(width, hw) + 1
		height += hh
	case .Virtual_Column:
		list := ui_list_find(&editor.ui, node.list)
		if list != nil {
			height = ui_list_count(list)
		}
		if list != nil {
			for i in node.window_lo ..< min(node.window_hi, ui_list_count(list)) {
				if item, ok := node.items[ui_list_key(list, i)]; ok {
					item_width, _ := ui_measure_slot(editor, item.node, avail_w, 1)
					width = max(width, item_width)
				}
			}
		}
	case .Editor:
		if buffer := ui_buffer(editor, node.buffer); buffer != nil {
			height = len(buffer.lines)
		}
	case .Terminal:
	case .Status:
		height = 1
	case .Markdown:
		height = len(ui_markdown_lines(ui_markdown_of(editor, node), avail_w))
	case .Image:
		if image := image_get(node.path); image != nil && image_enabled() {
			width, height = image_cells(image.w, image.h, avail_w, avail_h, g_image_cell.x, g_image_cell.y)
		} else {
			width, height = visual_width(transmute([]u8)ui_image_alt(node)), 1
		}
	case .Outlet:
	}
	return
}

ui_image_alt :: proc(node: ^UiNode) -> string {
	return fmt.tprintf("[image: %s]", filepath.base(node.path))
}

ui_measure_slot :: proc(editor: ^Editor, node: ^UiNode, avail_w, avail_h: int) -> (width, height: int) {
	mx := node.margin[1] + node.margin[3]
	my := node.margin[0] + node.margin[2]
	inner_w := max(avail_w - mx, 0)
	inner_h := max(avail_h - my, 0)
	nw, nh := 0, 0
	if node.width.form == .Auto || node.width.form == .Fit || node.height.form == .Auto || node.height.form == .Fit {
		nw, nh = ui_measure(editor, node, inner_w if node.width.form != .Cells else node.width.value, inner_h)
	}
	width = ui_size_resolve(node.width, inner_w, nw) + mx
	height = ui_size_resolve(node.height, inner_h, nh) + my
	return
}

ui_layout_children :: proc(editor: ^Editor, node: ^UiNode) {
	content := node.rect
	switch node.kind {
	case .Box:
		if node.border {
			content = ui_rect_shrink(node.rect, {1, 1, 1, 1})
		}
		for child in node.expanded {
			if child.float == .None {
				ui_layout_single(editor, child, content, node.clip)
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
		state := ui_node_state(&editor.ui, node)
		for child in node.expanded {
			if child.float != .None {
				continue
			}
			_, content_height := ui_measure_slot(editor, child, content.w, UI_UNBOUNDED)
			if child.kind == .Markdown {
				ui_markdown_resolve(ui_markdown_of(editor, child), ui_node_state(&editor.ui, child), state, content)
			}
			total := max(content_height, content.h)
			max_offset := max(0, content_height - content.h)
			if node.follow && state.at_end {
				state.offset = max_offset
			}
			state.offset = clamp(state.offset, 0, max_offset)
			state.at_end = state.offset >= max_offset
			slot := Rect{content.x, content.y - state.offset, content.w, total}
			ui_layout_node(editor, child, ui_rect_shrink(slot, child.margin), ui_rect_intersect(content, node.clip))
			break
		}
	case .Column, .Row:
		ui_layout_flow(editor, node, content)
	case .Text, .Editor, .Virtual_Column, .Outlet, .Image, .Terminal, .Markdown, .Status:
	}
	for child in node.expanded {
		if child.float != .None {
			ui_layout_float(editor, child, node)
		}
	}
}

ui_layout_single :: proc(editor: ^Editor, child: ^UiNode, area, clip: Rect) {
	inner := ui_rect_shrink(area, child.margin)
	rect := inner
	if child.width.form != .Auto {
		nw, _ := ui_measure(editor, child, inner.w, inner.h)
		rect.w = ui_size_resolve(child.width, inner.w, nw)
	}
	if child.height.form != .Auto {
		_, nh := ui_measure(editor, child, rect.w, inner.h)
		rect.h = ui_size_resolve(child.height, inner.h, nh)
	}
	ui_layout_node(editor, child, rect, clip)
}

ui_layout_node :: proc(editor: ^Editor, node: ^UiNode, rect, clip: Rect) {
	node.rect = rect
	node.clip = clip
	node.hidden = false
	ui_layout_children(editor, node)
}

ui_node_hide :: proc(node: ^UiNode) {
	node.hidden = true
	node.rect = {}
	for child in node.expanded {
		ui_node_hide(child)
	}
	if node.header != nil {
		ui_node_hide(node.header)
	}
	for _, item in node.items {
		ui_node_hide(item.node)
	}
}

ui_layout_flow :: proc(editor: ^Editor, node: ^UiNode, content: Rect) {
	axis := 1 if node.kind == .Column else 0
	avail := [2]int{content.w, content.h}
	laid_out := make([dynamic]^UiNode, context.temp_allocator)
	for child in node.expanded {
		if child.float == .None {
			append(&laid_out, child)
			child.hidden = false
		}
	}
	sizes := make([]int, len(laid_out), context.temp_allocator)
	margins := make([]int, len(laid_out), context.temp_allocator)
	for child, i in laid_out {
		margins[i] = child.margin[0] + child.margin[2] if axis == 1 else child.margin[1] + child.margin[3]
		form := ui_axis_size(child, axis)
		if ui_grows(child, axis) > 0 && form.form == .Auto {
			sizes[i] = form.min
			continue
		}
		cw, ch := ui_measure_slot(editor, child, content.w, content.h)
		sizes[i] = (ch if axis == 1 else cw) - margins[i]
	}
	sep := node.gap + (1 if node.separator else 0)
	total :: proc(laid_out: []^UiNode, sizes, margins: []int, sep: int) -> int {
		sum, count := 0, 0
		for child, i in laid_out {
			if child.hidden {
				continue
			}
			sum += sizes[i] + margins[i]
			count += 1
		}
		return sum + max(count - 1, 0) * sep
	}
	for total(laid_out[:], sizes, margins, sep) > avail[axis] {
		worst := -1
		for child, i in laid_out {
			if !child.hidden && child.drop > 0 && (worst < 0 || child.drop >= laid_out[worst].drop) {
				worst = i
			}
		}
		if worst < 0 {
			break
		}
		laid_out[worst].hidden = true
	}
	leftover := avail[axis] - total(laid_out[:], sizes, margins, sep)
	weight := 0
	for child in laid_out {
		if !child.hidden {
			weight += ui_grows(child, axis)
		}
	}
	if leftover > 0 && weight > 0 {
		given := 0
		last := -1
		for child, i in laid_out {
			growth := ui_grows(child, axis)
			if child.hidden || growth == 0 {
				continue
			}
			share := leftover * growth / weight
			form := ui_axis_size(child, axis)
			if form.max > 0 {
				share = min(share, max(form.max - sizes[i], 0))
			}
			sizes[i] += share
			given += share
			last = i
		}
		if last >= 0 && ui_axis_size(laid_out[last], axis).max == 0 {
			sizes[last] += leftover - given
		}
	}
	pos := content.y if axis == 1 else content.x
	end := pos + avail[axis]
	for child, i in laid_out {
		if child.hidden {
			ui_node_hide(child)
			continue
		}
		lead := child.margin[0] if axis == 1 else child.margin[3]
		main := clamp(sizes[i], 0, max(end - pos - lead, 0))
		cross_avail := (content.w - child.margin[1] - child.margin[3]) if axis == 1 else (content.h - child.margin[0] - child.margin[2])
		cross_avail = max(cross_avail, 0)
		cross_form := ui_axis_size(child, 1 - axis)
		cross := cross_avail
		align := node.align
		if cross_form.form != .Auto {
			nw, nh := ui_measure(editor, child, main if axis == 0 else cross_avail, main if axis == 1 else cross_avail)
			cross = ui_size_resolve(cross_form, cross_avail, nh if axis == 0 else nw)
			if align == .Stretch {
				align = .Start
			}
		}
		cross_lead := child.margin[3] if axis == 1 else child.margin[0]
		cross_pos := (content.x if axis == 1 else content.y) + cross_lead
		switch align {
		case .Stretch, .Start:
		case .Center:
			cross = ui_snap(cross_form, cross, cross_avail)
			cross_pos += (cross_avail - cross) / 2
		case .End:
			cross_pos += cross_avail - cross
		}
		rect: Rect
		if axis == 1 {
			rect = {cross_pos, pos + lead, cross, main}
		} else {
			rect = {pos + lead, cross_pos, main, cross}
		}
		ui_layout_node(editor, child, rect, node.clip)
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
	width := ui_size_resolve(node.width, area.w, nw)
	if node.height.form == .Fit || node.height.form == .Auto {
		_, nh = ui_measure(editor, node, width, area.h)
	}
	height := ui_size_resolve(node.height, area.h, nh)
	cell_x, cell_y := area.x, area.y
	center_x :: proc(node: ^UiNode, area: Rect, width: ^int) -> int {
		width^ = ui_snap(node.width, width^, area.w)
		return area.x + (area.w - width^) / 2
	}
	center_y :: proc(node: ^UiNode, area: Rect, height: ^int) -> int {
		height^ = ui_snap(node.height, height^, area.h)
		return area.y + (area.h - height^) / 2
	}
	switch node.anchor {
	case .Center:
		cell_x = center_x(node, area, &width)
		cell_y = center_y(node, area, &height)
	case .Top_Left:
	case .Top:
		cell_x = center_x(node, area, &width)
	case .Top_Right:
		cell_x = area.x + area.w - width
	case .Left:
		cell_y = center_y(node, area, &height)
	case .Right:
		cell_x = area.x + area.w - width
		cell_y = center_y(node, area, &height)
	case .Bottom_Left:
		cell_y = area.y + area.h - height
	case .Bottom:
		cell_x = center_x(node, area, &width)
		cell_y = area.y + area.h - height
	case .Bottom_Right:
		cell_x = area.x + area.w - width
		cell_y = area.y + area.h - height
	case .Cursor:
		cx, cy, ok := ui_editor_caret_pos(editor, parent)
		if !ok {
			node.hidden = true
			node.rect = {}
			return
		}
		cell_x = clamp(cx, area.x, max(area.x + area.w - width, area.x))
		cell_y = cy + 1
		if cell_y + height > area.y + area.h && cy - height >= area.y {
			cell_y = cy - height
		}
	}
	ui_layout_node(editor, node, {cell_x, cell_y, width, height}, ui_screen())
}

ui_editor_text_width :: proc(node: ^UiNode, buffer: ^Buffer) -> int {
	gutter := digit_count(len(buffer.lines)) + 2 if node.line_numbers else 0
	return max(node.rect.w - gutter, 0)
}

ui_editor_caret_pos :: proc(editor: ^Editor, node: ^UiNode) -> (cell_x, cell_y: int, ok: bool) {
	if node == nil || node.kind != .Editor {
		return
	}
	buffer := ui_buffer(editor, node.buffer)
	if buffer == nil {
		return
	}
	state := ui_node_state(&editor.ui, node)
	gutter := digit_count(len(buffer.lines)) + 2 if node.line_numbers else 0
	width := ui_editor_text_width(node, buffer)
	text := buffer.lines[buffer.cursor.row].text[:]
	if buffer.cursor.row < state.scroll_row {
		return
	}
	cx, cy: int
	if buffer.wrap && width > 0 {
		segs := buffer_line_wrap(buffer, buffer.cursor.row, width)
		sub := wrap_subrow(segs, buffer.cursor.col)
		if buffer.cursor.row == state.scroll_row && sub < state.scroll_sub {
			return
		}
		cx = visual_col(text, buffer.cursor.col) - visual_col(text, segs[sub])
		cy = vpos_dist(buffer, width, state.scroll_row, state.scroll_sub, buffer.cursor.row, sub, node.rect.h + 1)
	} else {
		cx = visual_col(text, buffer.cursor.col) - state.scroll_col
		cy = buffer.cursor.row - state.scroll_row
	}
	if cy < 0 || cy >= node.rect.h || cx < 0 || cx >= width {
		return
	}
	return node.rect.x + gutter + cx, node.rect.y + cy, true
}

ui_editor_reveal :: proc(editor: ^Editor, node: ^UiNode) {
	buffer := ui_buffer(editor, node.buffer)
	if buffer == nil {
		return
	}
	state := ui_node_state(&editor.ui, node)
	if buffer.cursor != state.cursor_seen {
		state.cursor_seen = buffer.cursor
		state.reveal = true
	}
	state.scroll_row = clamp(state.scroll_row, 0, len(buffer.lines) - 1)
	width := ui_editor_text_width(node, buffer)
	height := node.rect.h
	if !state.reveal || height <= 0 || width <= 0 {
		return
	}
	state.reveal = false
	sub := 0
	if buffer.wrap {
		state.scroll_col = 0
		sub = wrap_subrow(buffer_line_wrap(buffer, buffer.cursor.row, width), buffer.cursor.col)
	} else {
		state.scroll_sub = 0
	}
	// every move is a jump measured from the cursor (O(height)); a jump target is centred, else the
	// cursor keeps scroll_margin rows to the nearer edge
	margin := clamp(SCROLL_MARGIN, 0, (height - 1) / 2)
	row, sub_row := buffer.cursor.row, sub
	top_limit_row, top_limit_sub := vpos_down(buffer, width, state.scroll_row, state.scroll_sub, margin)
	if buffer.reveal_center {
		buffer.reveal_center = false
		state.scroll_row, state.scroll_sub = vpos_up(buffer, width, row, sub_row, height / 2)
	} else if vpos_cmp(row, sub_row, top_limit_row, top_limit_sub) < 0 {
		state.scroll_row, state.scroll_sub = vpos_up(buffer, width, row, sub_row, margin)
	} else if vpos_dist(buffer, width, state.scroll_row, state.scroll_sub, row, sub_row, height) >= height - margin {
		state.scroll_row, state.scroll_sub = vpos_up(buffer, width, row, sub_row, height - 1 - margin)
	}
	last := len(buffer.lines) - 1
	max_row, max_sub := vpos_up(buffer, width, last, line_rows(buffer, width, last) - 1, height - 1)
	if vpos_cmp(state.scroll_row, state.scroll_sub, max_row, max_sub) > 0 && vpos_cmp(row, sub_row, max_row, max_sub) >= 0 {
		state.scroll_row, state.scroll_sub = max_row, max_sub
	}
	if !buffer.wrap {
		state.scroll_sub = 0
	} else {
		return
	}
	visual_x := visual_col(buffer.lines[buffer.cursor.row].text[:], buffer.cursor.col)
	side := min(SCROLL_MARGIN, width / 4)
	if visual_x < state.scroll_col + side {
		state.scroll_col = max(visual_x - side, 0)
	} else if visual_x >= state.scroll_col + width - side {
		state.scroll_col = visual_x - width + side + 1
	}
}

ui_layout :: proc(editor: ^Editor) {
	screen := ui_screen()
	for layer in UI_LAYERS {
		for mount in editor.ui.mounts {
			if mount.outlet != layer {
				continue
			}
			root := mount.root
			if root.float != .None {
				ui_layout_float(editor, root, nil)
			} else {
				ui_layout_node(editor, root, ui_rect_shrink(screen, root.margin), screen)
			}
		}
	}
}

ui_enclosing_scroll :: proc(node: ^UiNode) -> ^UiNode {
	for ancestor := node.parent; ancestor != nil; ancestor = ancestor.parent {
		if ancestor.kind == .Scroll {
			return ancestor
		}
		if ancestor.float != .None {
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
	state := ui_node_state(&editor.ui, scroll)
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
	clear(&ui.hits)
	ui.caret_shown = false
	ui_graveyard_flush(editor)
	for id in ui.lists_dead {
		ui_list_remove_by_id(editor, id)
	}
	clear(&ui.lists_dead)
	ui_resolve(editor)
	ui_focused(editor)
	editor.terminal.active = false
	if len(ui.mounts) == 0 {
		return
	}
	walk_trees_settle(editor)
	ui_markdowns_sweep(editor)
	for _, md in ui.markdowns {
		ui_markdown_step(md, md_slice_ms)
	}
	for node in ui.virtuals {
		if list := ui_list_find(ui, node.list); list != nil {
			ui_list_settle_all(editor, list)
		}
	}
	for node in ui.editors {
		if buffer := ui_buffer(editor, node.buffer); buffer != nil && node.wrap_set {
			buffer.wrap = node.wrap
		}
	}
	for pass in 0 ..< 3 {
		ui_resolve(editor)
		ui_layout(editor)
		moved := false
		virtuals := slice.clone(ui.virtuals[:], context.temp_allocator)
		for node in virtuals {
			ui_virtual_build(editor, node)
			if ui_virtual_reveal(editor, node) {
				moved = true
			}
		}
		for _, node in ui.index {
			if node.kind == .Column || node.kind == .Row {
				if ui_container_reveal(editor, node) {
					moved = true
				}
			}
		}
		for node in ui.editors {
			ui_editor_reveal(editor, node)
		}
		if !moved && pass > 0 {
			break
		}
	}
	for _, node in ui.index {
		if node.kind != .Terminal || node.hidden || node.rect.w <= 0 || node.rect.h <= 0 {
			continue
		}
		if session := term_find(editor, node.session); session != nil {
			editor.terminal.active = true
			editor.terminal.shown = session
			editor.terminal.area = node.rect
			term_resize(editor)
		}
	}
	for node in ui.editors {
		buffer := ui_buffer(editor, node.buffer)
		if buffer != nil && node.syntax && !buffer.big && node.rect.h > 0 {
			state := ui_node_state(ui, node)
			width := ui_editor_text_width(node, buffer)
			top, bottom := state.scroll_row, state.scroll_row + node.rect.h - 1
			ghost := inline_active(editor) && ui_editor_shows_current(editor, buffer)
			highlight_update(buffer, top, bottom, highlight_clips_view(buffer, width, node.rect.h, state.scroll_row, state.scroll_sub, state.scroll_col, ghost, top, bottom))
			diffbase_update(buffer)
		}
	}
}

ui_container_reveal :: proc(editor: ^Editor, node: ^UiNode) -> bool {
	state, ok := &editor.ui.states[node.identity]
	if !ok || !state.reveal || state.highlighted == "" {
		return false
	}
	state.reveal = false
	for child in node.expanded {
		if child.key == state.highlighted && !child.hidden {
			return ui_reveal_row(editor, node, child.rect.y, child.rect.h)
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
		for stale_key, item in node.items {
			pos, present := ui_list_position(list, stale_key)
			if !present || ui_list_record_rev(list, pos) != item.rev {
				append(&stale, stale_key)
			}
		}
		for stale_key in stale {
			key, item := delete_key(&node.items, stale_key)
			append(&editor.ui.graveyard, item.node)
			editor.ui.dirty = true
			delete(key)
		}
	}
	lo, hi := ui_virtual_window(node, ui_list_count(list))
	node.window_lo, node.window_hi = lo, hi
	rev := list.rev
	for i in lo ..< hi {
		if list.rev != rev || i >= ui_list_count(list) {
			break
		}
		key := strings.clone(ui_list_key(list, i), context.temp_allocator)
		item, cached := node.items[key]
		if !cached {
			built := ui_item_build(editor, node, list, i, key)
			if built == nil {
				continue
			}
			if list.rev != rev {
				ui_node_free(editor, built)
				break
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
	if len(node.items) > hi - lo + 2 * UI_ITEM_KEEP {
		evicted := make([dynamic]string, context.temp_allocator)
		for key, _ in node.items {
			position, present := ui_list_position(list, key)
			if !present || position < lo - UI_ITEM_KEEP || position >= hi + UI_ITEM_KEEP {
				append(&evicted, key)
			}
		}
		for key in evicted {
			owned, item := delete_key(&node.items, key)
			append(&editor.ui.graveyard, item.node)
			editor.ui.dirty = true
			delete(owned)
		}
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

ui_style_colors :: proc(style: UiStyle, fg, bg: tb2.Color) -> (tb2.Color, tb2.Color) {
	foreground := ui_color(style.fg, fg) if .Fg in style.set else fg
	background := ui_color(style.bg, bg) if .Bg in style.set else bg
	attrs := u64(0)
	if style.bold {
		attrs |= u64(tb2.Color.Bold)
	}
	if style.italic {
		attrs |= u64(tb2.Color.Italic)
	}
	if style.underline {
		attrs |= u64(tb2.Color.Underline)
	}
	return tb2.Color(u64(foreground) | attrs), background
}

UiPaint :: struct {
	clip:     Rect,
	inherit:  UiStyle,
	override: UiStyle,
	bg:       tb2.Color,
}

ui_cell :: proc(paint: ^UiPaint, cell_x, cell_y: int, character: rune, fg, bg: tb2.Color) {
	if ui_rect_has(paint.clip, cell_x, cell_y) {
		tb2.set_cell(i32(cell_x), i32(cell_y), character, fg, bg)
	}
}

ui_fill :: proc(paint: ^UiPaint, rect: Rect, bg: tb2.Color) {
	area := ui_rect_intersect(rect, paint.clip)
	for cell_y in area.y ..< area.y + area.h {
		for cell_x in area.x ..< area.x + area.w {
			tb2.set_cell(i32(cell_x), i32(cell_y), ' ', COLOR_FG, bg)
		}
	}
}

// the alert layer draws after the old panes (ui_render_alert), so a dialog sits above them
ui_render :: proc(editor: ^Editor) {
	ui := &editor.ui
	clear(&ui.hits)
	ui.caret_shown = false
	for layer in UI_LAYERS {
		if layer == "alert" {
			continue
		}
		ui_render_layer(editor, layer)
		if layer == "base" {
			ui_render_caret(editor, true)
		}
	}
	ui_render_caret(editor, false)
}

ui_render_alert :: proc(editor: ^Editor) -> bool {
	if !ui_layer_used(&editor.ui, "alert") {
		return false
	}
	ui_render_layer(editor, "alert")
	ui_render_caret(editor, false)
	return true
}

ui_render_layer :: proc(editor: ^Editor, layer: string) {
	ui := &editor.ui
	floats := make([dynamic]^UiNode, context.temp_allocator)
	for mount in ui.mounts {
		if mount.outlet != layer {
			continue
		}
		if mount.root.float != .None {
			append(&floats, mount.root)
			continue
		}
		paint := UiPaint{clip = ui_screen(), bg = COLOR_BG}
		ui_render_node(editor, mount.root, &paint, &floats)
	}
	for i := 0; i < len(floats); i += 1 {
		floating := floats[i]
		paint := UiPaint{clip = ui_screen(), bg = COLOR_BG}
		if floating.parent != nil {
			paint.inherit = ui_inherited(floating.parent)
			paint.bg = ui_inherited_bg(floating.parent)
		}
		ui_render_node(editor, floating, &paint, &floats)
	}
}

ui_focus_in_layer :: proc(editor: ^Editor, layer: string) -> bool {
	focus := ui_focused(editor)
	if focus == nil {
		return false
	}
	root := focus
	for root.parent != nil {
		root = root.parent
	}
	for mount in editor.ui.mounts {
		if mount.root == root {
			return mount.outlet == layer
		}
	}
	return false
}

ui_render_caret :: proc(editor: ^Editor, popups: bool) {
	ui := &editor.ui
	if focused := ui_focused(editor); focused != nil && focused.kind == .Editor && !focused.hidden {
		if cell_x, cell_y, ok := ui_editor_caret_pos(editor, focused); ok && ui_rect_has(focused.clip, cell_x, cell_y) {
			ui.caret = {cell_x, cell_y}
			ui.caret_shown = true
			buffer := ui_buffer(editor, focused.buffer)
			if popups && ui_editor_shows_current(editor, buffer) {
				ghost := inline_active(editor)
				if ghost && !buffer.wrap {
					inline_render(editor, cell_x, cell_y)
				}
				if editor.completion.active {
					completion_render(editor, cell_x, cell_y)
				} else if !ghost && editor.hover_active {
					editor_render_hover_pane(editor, cell_x, cell_y)
				} else if !ghost {
					editor_render_diag_pane(editor, cell_x, cell_y)
				}
			}
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
	style := ui_inherited(node)
	return ui_color(style.bg, COLOR_BG) if .Bg in style.set else COLOR_BG
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
	state := ui_node_state_peek(&editor.ui, node)
	switch node.kind {
	case .Text:
		ui_render_text(&paint, node)
	case .Box:
		if node.border {
			ui_render_border(&paint, node)
		}
	case .Scroll:
		content := ui_scroll_content(editor, node)
		for expanded_child in node.expanded {
			if expanded_child.float == .None {
				total := expanded_child.rect.h + expanded_child.margin[0] + expanded_child.margin[2]
				if total > content.h {
					start, length := scrollbar_thumb(state.offset, content.h, total)
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
			low, high := -1, -1
			if state.extend_from != "" {
				anchor_at, anchor_ok := ui_list_position(list, state.extend_from)
				cursor_at, cursor_ok := ui_list_position(list, state.highlighted)
				if anchor_ok && cursor_ok {
					low, high = min(anchor_at, cursor_at), max(anchor_at, cursor_at)
				}
			}
			for i in node.window_lo ..< min(node.window_hi, ui_list_count(list)) {
				key := ui_list_key(list, i)
				item, ok := node.items[key]
				if !ok {
					continue
				}
				child := paint
				if (state.highlighted != "" && key == state.highlighted) || (i >= low && i <= high) {
					child.override = ui_style_over(paint.override, node.highlight_style)
				}
				ui_render_node(editor, item.node, &child, floats)
			}
		}
	case .Image:
		ui_render_image(&paint, node)
	case .Markdown:
		ui_render_markdown(editor, &paint, node)
	case .Status:
		status_render(editor, ui_rect_intersect(node.rect, paint.clip), paint.bg)
	case .Terminal:
		if session := term_find(editor, node.session); session != nil {
			focused := editor.ui.focus == node.identity
			if cell_x, cell_y, ok := term_render_area(editor, session, node.rect, focused); ok && focused {
				editor.ui.caret = {cell_x, cell_y}
				editor.ui.caret_shown = true
			}
		}
	case .Column, .Row, .Outlet:
	}
	if node.header != nil {
		ui_render_node(editor, node.header, &paint, floats)
	}
	for expanded_child in node.expanded {
		if expanded_child.float != .None {
			append(floats, expanded_child)
			continue
		}
		child := paint
		if state.highlighted != "" && expanded_child.key == state.highlighted {
			child.override = ui_style_over(paint.override, node.highlight_style)
		}
		ui_render_node(editor, expanded_child, &child, floats)
	}
	if node.separator && (node.kind == .Column || node.kind == .Row) {
		ui_render_separators(&paint, node)
	}
}

ui_render_image :: proc(paint: ^UiPaint, node: ^UiNode) {
	rect := node.rect
	image := image_get(node.path)
	state := ImageState.Failed
	if image != nil {
		state, _ = image_state(image.id)
	}
	if image == nil || state == .Failed || !image_enabled() {
		ui_draw_text(paint, rect.x, rect.y, rect.w, ui_image_alt(node), COLOR_PANE_DIM_FG, paint.bg)
		return
	}
	cols, rows := image_cells(image.w, image.h, rect.w, rect.h, g_image_cell.x, g_image_cell.y)
	image_show({image.id, i32(cols), i32(rows)})
	for row in 0 ..< rows {
		ui_draw_text(paint, rect.x, rect.y + row, cols, image_placeholder_row(row, cols), image_color(image.id), paint.bg)
	}
}

ui_render_border :: proc(paint: ^UiPaint, node: ^UiNode) {
	rect := node.rect
	fg, _ := ui_style_colors(ui_style_over(paint.inherit, paint.override), COLOR_PANE_BORDER, paint.bg)
	if .Fg not_in node.style.set {
		fg = COLOR_PANE_BORDER
	}
	x1, y1 := rect.x + rect.w - 1, rect.y + rect.h - 1
	for cell_x in rect.x + 1 ..< x1 {
		ui_cell(paint, cell_x, rect.y, '─', fg, paint.bg)
		ui_cell(paint, cell_x, y1, '─', fg, paint.bg)
	}
	for cell_y in rect.y + 1 ..< y1 {
		ui_cell(paint, rect.x, cell_y, '│', fg, paint.bg)
		ui_cell(paint, x1, cell_y, '│', fg, paint.bg)
	}
	ui_cell(paint, rect.x, rect.y, '┌', fg, paint.bg)
	ui_cell(paint, x1, rect.y, '┐', fg, paint.bg)
	ui_cell(paint, rect.x, y1, '└', fg, paint.bg)
	ui_cell(paint, x1, y1, '┘', fg, paint.bg)
	if node.title != "" && rect.w > 4 {
		title_fg, _ := ui_style_colors(ui_style_over(paint.inherit, paint.override), COLOR_PANE_FG, paint.bg)
		ui_draw_text(paint, rect.x + 2, rect.y, rect.w - 4, fmt.tprintf(" %s ", node.title), title_fg, paint.bg)
	}
}

ui_render_separators :: proc(paint: ^UiPaint, node: ^UiNode) {
	prev: ^UiNode
	for child in node.expanded {
		if child.float != .None || child.hidden {
			continue
		}
		if prev != nil {
			if node.kind == .Column {
				cell_y := child.rect.y - child.margin[0] - 1
				for cell_x in node.rect.x ..< node.rect.x + node.rect.w {
					ui_cell(paint, cell_x, cell_y, '─', COLOR_PANE_BORDER, paint.bg)
				}
			} else {
				cell_x := child.rect.x - child.margin[3] - 1
				for cell_y in node.rect.y ..< node.rect.y + node.rect.h {
					ui_cell(paint, cell_x, cell_y, '│', COLOR_PANE_BORDER, paint.bg)
				}
			}
		}
		prev = child
	}
}

ui_draw_text :: proc(paint: ^UiPaint, cell_x, cell_y, width: int, text: string, fg, bg: tb2.Color) -> int {
	bytes := transmute([]u8)text
	col := 0
	i := 0
	for i < len(bytes) && col < width {
		next_index := cluster_end(bytes, i)
		cw := seg_width(bytes, i, next_index, col)
		if col + cw > width {
			break
		}
		if bytes[i] == '\t' {
			for offset in 0 ..< cw {
				ui_cell(paint, cell_x + col + offset, cell_y, ' ', fg, bg)
			}
		} else if ui_rect_has(paint.clip, cell_x + col, cell_y) && ui_rect_has(paint.clip, cell_x + col + cw - 1, cell_y) {
			cell_put_cluster(cell_x + col, cell_y, bytes[i:next_index], fg, bg)
		}
		col += cw
		i = next_index
	}
	return col
}

ui_render_text :: proc(paint: ^UiPaint, node: ^UiNode) {
	rect := node.rect
	lines := ui_text_wrapped(node, rect.w)
	for line, row in lines {
		if row >= rect.h {
			break
		}
		cell_y := rect.y + row
		width := ui_spans_width(line[:])
		cell_x := rect.x
		switch node.text_align {
		case .Center:
			cell_x += max(rect.w - width, 0) / 2
		case .End:
			cell_x += max(rect.w - width, 0)
		case .Stretch, .Start:
		}
		col := cell_x - rect.x
		overflow := width > rect.w
		limit := rect.w - 1 if overflow else rect.w
		last_fg, last_bg := COLOR_FG, paint.bg
		for span in line {
			style := ui_style_over(ui_style_over(paint.inherit, span.style), paint.override)
			fg, bg := ui_style_colors(style, COLOR_FG, paint.bg)
			last_fg, last_bg = fg, bg
			if col >= limit {
				break
			}
			drawn := ui_draw_text(paint, rect.x + col, cell_y, limit - col, span.text, fg, bg)
			col += drawn
			if drawn < visual_width(transmute([]u8)span.text) {
				break
			}
		}
		if overflow && rect.w > 0 {
			ui_cell(paint, rect.x + rect.w - 1, cell_y, '…', last_fg, last_bg)
		}
	}
}

ui_editor_advance :: proc(buffer: ^Buffer, width, row, sub_row, rows: int) -> (int, int) {
	row, sub_row := row, sub_row
	for _ in 0 ..< max(rows, 0) {
		if buffer.wrap && width > 0 && sub_row + 1 < line_rows(buffer, width, row) {
			sub_row += 1
		} else if row + 1 < len(buffer.lines) {
			row += 1
			sub_row = 0
		}
	}
	return row, sub_row
}

ui_editor_shows_current :: proc(editor: ^Editor, buffer: ^Buffer) -> bool {
	return buffer != nil && !editor.welcome && len(editor.buffers) > 0 && editor_buffer(editor) == buffer
}

ui_render_editor :: proc(editor: ^Editor, paint: ^UiPaint, node: ^UiNode) {
	buffer := ui_buffer(editor, node.buffer)
	if buffer == nil {
		return
	}
	visible := ui_rect_intersect(node.rect, paint.clip)
	if visible.w <= 0 || visible.h <= 0 {
		return
	}
	state := ui_node_state(&editor.ui, node)
	gutter := digit_count(len(buffer.lines)) + 2 if node.line_numbers else 0
	width := ui_editor_text_width(node, buffer)
	row, sub_row := ui_editor_advance(buffer, width, state.scroll_row, state.scroll_sub, visible.y - node.rect.y)
	base := ui_style_over(paint.inherit, paint.override)
	foreground, background := ui_style_colors(base, COLOR_FG, paint.bg)
	shows_current := ui_editor_shows_current(editor, buffer)
	focused := editor.ui.focus == node.identity
	view := EditorView {
		buffer       = buffer,
		x            = node.rect.x,
		y            = visible.y,
		w            = width,
		h            = visible.h,
		gutter       = gutter,
		scroll_row   = row,
		scroll_sub   = sub_row,
		scroll_col   = state.scroll_col,
		bg           = background,
		fg           = foreground,
		fg_set       = .Fg in base.set,
		syntax       = node.syntax && !buffer.big,
		current_line = node.line_numbers && focused,
		find         = find_shows(editor, buffer),
		inline       = shows_current && focused,
	}
	if shows_current && focused {
		editor.caret_view = view
		editor.caret_view.y, editor.caret_view.h = node.rect.y, node.rect.h
		editor.caret_view.scroll_row, editor.caret_view.scroll_sub = state.scroll_row, state.scroll_sub
	}
	editor_render_view(editor, &view)
	if len(buffer.lines) == 1 && len(buffer.lines[0].text) == 0 && node.placeholder != "" {
		ui_draw_text(paint, node.rect.x + gutter, node.rect.y, view.w, node.placeholder, COLOR_PANE_DIM_FG, background)
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
		name, ctrl = "Space", true
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
		case .F12 ..= .F1:
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

ui_chord_parse :: proc(chord: string) -> (ctrl, alt, shift: bool, name: string, ok: bool) {
	rest := chord
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
	for key_name in UI_NAMED_KEYS {
		if rest == key_name {
			return ctrl, alt, shift, rest, true
		}
	}
	if strings.equal_fold(rest, "escape") {
		return ctrl, alt, shift, "Esc", true
	}
	character, size := utf8.decode_rune_in_string(rest)
	if size == 0 || size != len(rest) || character == utf8.RUNE_ERROR {
		return
	}
	if ctrl && character >= 'A' && character <= 'Z' {
		rest = fmt.tprintf("%c", character + 32)
	}
	return ctrl, alt, shift, rest, true
}

ui_chord_normalize :: proc(chord: string, allocator := context.temp_allocator) -> string {
	ctrl, alt, shift, name, ok := ui_chord_parse(chord)
	if !ok {
		return ""
	}
	return ui_chord_build(ctrl, alt, shift, name, allocator)
}

UI_CHORDS_UNSEEN :: [?]string{"Ctrl+Enter", "Shift+Enter", "Ctrl+Tab", "Ctrl+Backspace", "Ctrl+Esc", "Shift+Esc", "Shift+Backspace"}

ui_chord_cached :: proc(ui: ^Ui, shortcut: string) -> string {
	if chord, ok := ui.chords[shortcut]; ok {
		return chord
	}
	chord := ui_chord_normalize(shortcut, context.allocator)
	ui.chords[strings.clone(shortcut)] = chord
	return chord
}

ui_chord_named_key :: proc(chord: string) -> (key: tb2.Key, ok: bool) {
	for unseen in UI_CHORDS_UNSEEN {
		if ui_chord_normalize(chord) == unseen {
			return
		}
	}
	ctrl, alt, shift, name, parsed := ui_chord_parse(chord)
	if !parsed {
		return
	}
	named := false
	for key_name in UI_NAMED_KEYS {
		named = named || key_name == name
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
