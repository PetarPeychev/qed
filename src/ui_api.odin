package main

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import lua "lib:lua"

UI_MARSHAL_DEPTH_MAX :: 64

lua_unref :: proc(L: ^lua.State, ref: i32) {
	lua.L_unref(L, lua.REGISTRYINDEX, c.int(ref))
}

lua_refs_equal :: proc(L: ^lua.State, first, second: i32) -> bool {
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(first))
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(second))
	same := lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 2)
	return same
}

UI_COMMON_PROPS :: [?]string{"id", "key", "width", "height", "grow", "drop", "margin", "float", "anchor", "scope", "on", "fg", "bg", "bold", "italic", "underline"}

ui_kind_props := [UiKind][]string {
	.Column         = {"gap", "align", "separator", "highlight_style"},
	.Row            = {"gap", "align", "separator", "highlight_style"},
	.Box            = {"border", "title"},
	.Scroll         = {"header", "follow"},
	.Text           = {"wrap", "align"},
	.Editor         = {"buffer", "placeholder", "line_numbers", "syntax", "wrap", "readonly"},
	.Virtual_Column = {"data", "item", "highlight_style"},
	.Outlet         = {},
	.Image          = {"path"},
	.Terminal       = {"session"},
	.Markdown       = {"text", "dir"},
	.Status         = {},
}

UiMarshal :: struct {
	L:      ^lua.State,
	editor: ^Editor,
	owner:  string,
	err:    string,
	ids:    [dynamic]string,
}

ui_marshal_fail :: proc(marshal: ^UiMarshal, msg: string) {
	if marshal.err == "" {
		marshal.err = msg
	}
}

ui_node_kind :: proc(L: ^lua.State, idx: c.int) -> (UiKind, bool) {
	if lua.type(L, idx) != .TABLE || lua.getmetatable(L, idx) == 0 {
		return {}, false
	}
	lua.pushstring(L, "__node")
	lua.rawget(L, -2)
	name, _ := lua.toodinstring(L, -1)
	lua.pop(L, 2)
	for node_name, kind in ui_kind_names {
		if node_name == name {
			return kind, true
		}
	}
	return {}, false
}

ui_positional_keys :: proc(L: ^lua.State, idx: c.int) -> []int {
	keys := make([dynamic]int, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		if lua.isinteger(L, -2) {
			slot := int(lua.tointeger(L, -2))
			if slot >= 1 && lua.type(L, -1) != .BOOLEAN {
				append(&keys, slot)
			}
		}
		lua.pop(L, 1)
	}
	slice.sort(keys[:])
	return keys[:]
}

ui_marshal_size :: proc(marshal: ^UiMarshal, idx: c.int, what: string) -> UiSize {
	L := marshal.L
	idx := lua.absindex(L, idx)
	#partial switch lua.type(L, idx) {
	case .NIL:
		return {}
	case .NUMBER:
		if !lua.isinteger(L, idx) {
			ui_marshal_fail(marshal, fmt.tprintf("%s: whole cells expected", what))
			return {}
		}
		return {form = .Cells, value = max(int(lua.tointeger(L, idx)), 0)}
	case .STRING:
		text, _ := lua.toodinstring(L, idx)
		if text == "fit" {
			return {form = .Fit}
		}
		if strings.has_suffix(text, "%") {
			if percent, ok := strconv.parse_int(text[:len(text) - 1]); ok && percent >= 0 {
				return {form = .Percent, value = percent}
			}
		}
		ui_marshal_fail(marshal, fmt.tprintf("%s: '%s' is not a size (n, \"N%%\", \"fit\")", what, text))
	case .TABLE:
		lua.rawgeti(L, idx, 1)
		size := ui_marshal_size(marshal, -1, what)
		lua.pop(L, 1)
		for bound, i in ([?]cstring{"min", "max"}) {
			lua.getfield(L, idx, bound)
			if lua.type(L, -1) == .NUMBER {
				bound := max(int(lua.tointeger(L, -1)), 0)
				if i == 0 {
					size.min = bound
				} else {
					size.max = bound
				}
			}
			lua.pop(L, 1)
		}
		if size.form == .Auto {
			size.form = .Fit
		}
		return size
	case:
		ui_marshal_fail(marshal, fmt.tprintf("%s: size expected", what))
	}
	return {}
}

ui_marshal_margin :: proc(marshal: ^UiMarshal, idx: c.int) -> (out: [4]int) {
	L := marshal.L
	idx := lua.absindex(L, idx)
	#partial switch lua.type(L, idx) {
	case .NUMBER:
		cells := int(lua.tointeger(L, idx))
		return {cells, cells, cells, cells}
	case .TABLE:
		sides := [?]string{"top", "right", "bottom", "left"}
		lua.pushnil(L)
		for lua.next(L, idx) != 0 {
			name := ""
			if lua.type(L, -2) == .STRING {
				name, _ = lua.toodinstring(L, -2)
			}
			cells := int(lua.tointeger(L, -1))
			switch name {
			case "x":
				out[1], out[3] = cells, cells
			case "y":
				out[0], out[2] = cells, cells
			case:
				known := false
				for side, i in sides {
					if side == name {
						out[i] = cells
						known = true
					}
				}
				if !known {
					ui_marshal_fail(marshal, "margin: a number, {x =, y =} or named sides {top =, right =, bottom =, left =}")
				}
			}
			lua.pop(L, 1)
		}
		return
	}
	ui_marshal_fail(marshal, "margin: a number, {x =, y =} or named sides {top =, right =, bottom =, left =}")
	return
}

ui_marshal_style_field :: proc(marshal: ^UiMarshal, style: ^UiStyle, name: string, idx: c.int) -> bool {
	L := marshal.L
	switch name {
	case "fg", "bg":
		if lua.type(L, idx) != .STRING {
			ui_marshal_fail(marshal, fmt.tprintf("%s: theme color name expected", name))
			return true
		}
		text, _ := lua.toodinstring(L, idx)
		if name == "fg" {
			delete(style.fg)
			style.fg = strings.clone(text)
			style.set += {.Fg}
		} else {
			delete(style.bg)
			style.bg = strings.clone(text)
			style.set += {.Bg}
		}
		return true
	case "bold":
		style.bold = bool(lua.toboolean(L, idx))
		style.set += {.Bold}
		return true
	case "italic":
		style.italic = bool(lua.toboolean(L, idx))
		style.set += {.Italic}
		return true
	case "underline":
		style.underline = bool(lua.toboolean(L, idx))
		style.set += {.Underline}
		return true
	}
	return false
}

ui_marshal_style :: proc(marshal: ^UiMarshal, idx: c.int, what: string) -> (style: UiStyle) {
	L := marshal.L
	idx := lua.absindex(L, idx)
	if lua.type(L, idx) != .TABLE {
		ui_marshal_fail(marshal, fmt.tprintf("%s: style table expected", what))
		return
	}
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		if lua.type(L, -2) != .STRING {
			ui_marshal_fail(marshal, fmt.tprintf("%s: style fields are named", what))
		} else if name, _ := lua.toodinstring(L, -2); !ui_marshal_style_field(marshal, &style, name, -1) {
			ui_marshal_fail(marshal, fmt.tprintf("%s: unknown style field '%s'", what, name))
		}
		lua.pop(L, 1)
	}
	return
}

ui_marshal_spans :: proc(marshal: ^UiMarshal, node: ^UiNode, idx: c.int, inherited: UiStyle, depth: int) {
	L := marshal.L
	idx := lua.absindex(L, idx)
	if depth > UI_MARSHAL_DEPTH_MAX {
		ui_marshal_fail(marshal, "spans nested too deeply")
		return
	}
	style := inherited
	if depth > 0 {
		lua.pushnil(L)
		for lua.next(L, idx) != 0 {
			if lua.type(L, -2) == .STRING {
				name, _ := lua.toodinstring(L, -2)
				tmp: UiStyle
				if ui_marshal_style_field(marshal, &tmp, name, -1) {
					if .Fg in tmp.set {
						style.fg = strings.clone(tmp.fg, context.temp_allocator)
					}
					if .Bg in tmp.set {
						style.bg = strings.clone(tmp.bg, context.temp_allocator)
					}
					if .Bold in tmp.set {
						style.bold = tmp.bold
					}
					if .Italic in tmp.set {
						style.italic = tmp.italic
					}
					if .Underline in tmp.set {
						style.underline = tmp.underline
					}
					style.set += tmp.set
					ui_style_free(tmp)
				} else {
					ui_marshal_fail(marshal, fmt.tprintf("span: unknown field '%s'", name))
				}
			}
			lua.pop(L, 1)
		}
	}
	for slot in ui_positional_keys(L, idx) {
		lua.rawgeti(L, idx, lua.Integer(slot))
		#partial switch lua.type(L, -1) {
		case .STRING, .NUMBER:
			text, _ := lua.toodinstring(L, -1)
			span := UiSpan{text = strings.clone(text), style = style}
			span.style.fg = strings.clone(style.fg)
			span.style.bg = strings.clone(style.bg)
			append(&node.spans, span)
		case .TABLE:
			if _, is_node := ui_node_kind(L, -1); is_node {
				ui_marshal_fail(marshal, "text children are strings and spans, not nodes")
			} else {
				ui_marshal_spans(marshal, node, -1, style, depth + 1)
			}
		case:
			ui_marshal_fail(marshal, "text children are strings and spans")
		}
		lua.pop(L, 1)
	}
}

ui_prop_allowed :: proc(kind: UiKind, name: string) -> bool {
	if kind == .Outlet {
		return name == "id"
	}
	for prop in UI_COMMON_PROPS {
		if prop == name {
			return true
		}
	}
	for prop in ui_kind_props[kind] {
		if prop == name {
			return true
		}
	}
	return false
}

ui_marshal :: proc(marshal: ^UiMarshal, idx: c.int, depth: int) -> ^UiNode {
	L := marshal.L
	idx := lua.absindex(L, idx)
	kind, ok := ui_node_kind(L, idx)
	if !ok {
		ui_marshal_fail(marshal, "node expected (build nodes with qed.ui.column, qed.ui.text, ...)")
		return nil
	}
	if depth > UI_MARSHAL_DEPTH_MAX {
		ui_marshal_fail(marshal, "tree nested too deeply")
		return nil
	}
	lua.L_checkstack(L, 8, "ui tree")
	node := new(UiNode)
	node.kind = kind
	node.owner = marshal.owner
	if kind == .Editor {
		node.wrap = false
	}
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		if lua.type(L, -2) != .STRING {
			lua.pop(L, 1)
			continue
		}
		name, _ := lua.toodinstring(L, -2)
		name = strings.clone(name, context.temp_allocator)
		if !ui_prop_allowed(kind, name) {
			ui_marshal_fail(marshal, fmt.tprintf("%s: unknown prop '%s'", ui_kind_names[kind], name))
			lua.pop(L, 1)
			continue
		}
		value_index := lua.gettop(L)
		if ui_marshal_style_field(marshal, &node.style, name, value_index) {
			lua.pop(L, 1)
			continue
		}
		switch name {
		case "session":
			if lua.type(L, value_index) != .STRING {
				ui_marshal_fail(marshal, "session: a qed.term session name expected")
				break
			}
			text, _ := lua.toodinstring(L, value_index)
			node.session = strings.clone(text)
		case "text":
			if lua.type(L, value_index) != .STRING {
				ui_marshal_fail(marshal, "text: string expected")
				break
			}
			text, _ := lua.toodinstring(L, value_index)
			node.source = strings.clone(text)
		case "dir":
			if lua.type(L, value_index) != .STRING {
				ui_marshal_fail(marshal, "dir: string expected")
				break
			}
			text, _ := lua.toodinstring(L, value_index)
			node.path = strings.clone(api_path(marshal.editor, text))
		case "path":
			if lua.type(L, value_index) != .STRING {
				ui_marshal_fail(marshal, "path: string expected")
				break
			}
			text, _ := lua.toodinstring(L, value_index)
			node.path = strings.clone(api_path(marshal.editor, text))
		case "id", "key", "title", "placeholder":
			value_type := lua.type(L, value_index)
			if value_type != .STRING && !(value_type == .NUMBER && name == "key") {
				ui_marshal_fail(marshal, fmt.tprintf("%s: string expected", name))
				break
			}
			text, _ := lua.toodinstring(L, value_index)
			switch name {
			case "id":
				node.id = strings.clone(text)
				append(&marshal.ids, node.id)
			case "key":
				node.key = strings.clone(text)
			case "title":
				node.title = strings.clone(text)
			case "placeholder":
				node.placeholder = strings.clone(text)
			}
		case "width":
			node.width = ui_marshal_size(marshal, value_index, "width")
		case "height":
			node.height = ui_marshal_size(marshal, value_index, "height")
		case "grow":
			node.grow = int(lua.tointeger(L, value_index))
			node.grow_set = true
		case "drop":
			node.drop = int(lua.tointeger(L, value_index))
		case "gap":
			node.gap = max(int(lua.tointeger(L, value_index)), 0)
		case "margin":
			node.margin = ui_marshal_margin(marshal, value_index)
		case "float":
			text, _ := lua.toodinstring(L, value_index)
			switch text {
			case "parent":
				node.float = .Parent
			case "screen":
				node.float = .Screen
			case:
				ui_marshal_fail(marshal, "float: \"parent\" or \"screen\"")
			}
		case "anchor":
			text, _ := lua.toodinstring(L, value_index)
			found := false
			names := [UiAnchor]string {
				.Center       = "center",
				.Top_Left     = "top_left",
				.Top          = "top",
				.Top_Right    = "top_right",
				.Left         = "left",
				.Right        = "right",
				.Bottom_Left  = "bottom_left",
				.Bottom       = "bottom",
				.Bottom_Right = "bottom_right",
				.Cursor       = "cursor",
			}
			for anchor_name, anchor in names {
				if anchor_name == text {
					node.anchor = anchor
					found = true
				}
			}
			if !found {
				ui_marshal_fail(marshal, fmt.tprintf("anchor: unknown '%s'", text))
			}
		case "align":
			value, _ := lua.toodinstring(L, value_index)
			start, finish := "left", "right"
			if kind == .Row {
				start, finish = "top", "bottom"
			}
			switch value {
			case start:
				node.align = .Start
			case "center":
				node.align = .Center
			case finish:
				node.align = .End
			case:
				ui_marshal_fail(marshal, fmt.tprintf("align: %s takes %s, center or %s, not '%s'", ui_kind_names[kind], start, finish, value))
			}
			if kind == .Text {
				node.text_align = node.align
				node.align = .Stretch
			}
		case "scope":
			scopes := make([dynamic]string)
			if lua.type(L, value_index) == .STRING {
				text, _ := lua.toodinstring(L, value_index)
				append(&scopes, strings.clone(text))
			} else if lua.type(L, value_index) == .TABLE {
				for slot in ui_positional_keys(L, value_index) {
					lua.rawgeti(L, value_index, lua.Integer(slot))
					text, _ := lua.toodinstring(L, -1)
					append(&scopes, strings.clone(text))
					lua.pop(L, 1)
				}
			} else {
				ui_marshal_fail(marshal, "scope: a scope name or a list of names")
			}
			node.scope = scopes[:]
			for scope in scopes {
				if scope == "editor" && kind != .Editor {
					ui_marshal_fail(marshal, "scope 'editor' only goes on an editor node")
				}
				ui_scope_check(marshal.editor, scope)
			}
		case "on":
			if lua.type(L, value_index) != .TABLE {
				ui_marshal_fail(marshal, "on: table of handlers expected")
				break
			}
			lua.pushnil(L)
			for lua.next(L, value_index) != 0 {
				if lua.type(L, -2) != .STRING {
					ui_marshal_fail(marshal, "on: handlers are named by event")
					lua.pop(L, 1)
					continue
				}
				ev_name, _ := lua.toodinstring(L, -2)
				found := false
				for event_name, event in ui_event_names {
					if event_name == ev_name {
						found = true
						if lua.type(L, -1) != .FUNCTION {
							ui_marshal_fail(marshal, fmt.tprintf("on.%s: function expected", event_name))
						} else {
							lua.pushvalue(L, -1)
							node.handlers[event] = i32(lua.L_ref(L, lua.REGISTRYINDEX))
						}
					}
				}
				if !found {
					ui_marshal_fail(marshal, fmt.tprintf("on: unknown event '%s'", ev_name))
				}
				lua.pop(L, 1)
			}
		case "separator":
			node.separator = bool(lua.toboolean(L, value_index))
		case "follow":
			node.follow = bool(lua.toboolean(L, value_index))
		case "border":
			node.border = bool(lua.toboolean(L, value_index))
		case "wrap":
			node.wrap = bool(lua.toboolean(L, value_index))
			node.wrap_set = true
		case "line_numbers":
			node.line_numbers = bool(lua.toboolean(L, value_index))
		case "syntax":
			node.syntax = bool(lua.toboolean(L, value_index))
		case "readonly":
			node.readonly = bool(lua.toboolean(L, value_index))
		case "highlight_style":
			node.highlight_style = ui_marshal_style(marshal, value_index, name)
		case "buffer":
			id := 0
			if lua.type(L, value_index) == .TABLE {
				id, _ = api_field_int(L, value_index, "id")
			}
			if ui_buffer(marshal.editor, u64(id)) == nil {
				ui_marshal_fail(marshal, "buffer: an open buffer object expected")
			}
			node.buffer = u64(id)
		case "header":
			if _, is_node := ui_node_kind(L, value_index); !is_node {
				ui_marshal_fail(marshal, "header: node expected")
				break
			}
			node.header = ui_marshal(marshal, value_index, depth + 1)
			if node.header != nil && node.header.float != .None {
				ui_marshal_fail(marshal, "header: a floating node cannot be a header")
			}
		case "data":
			list, gone := api_ui_list_lookup(L, marshal.editor, value_index)
			if list == nil {
				ui_marshal_fail(marshal, "data: the list is gone" if gone else "data: qed.list expected")
				break
			}
			node.list = list.id
			lua.pushvalue(L, value_index)
			node.list_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
		case "item":
			if lua.type(L, value_index) != .FUNCTION {
				ui_marshal_fail(marshal, "item: function(record) -> node expected")
				break
			}
			lua.pushvalue(L, value_index)
			node.item_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
		}
		lua.pop(L, 1)
	}
	if kind == .Text {
		ui_marshal_spans(marshal, node, idx, {}, 0)
		return node
	}
	laid := 0
	seen_keys := make(map[string]bool, 8, context.temp_allocator)
	for slot in ui_positional_keys(L, idx) {
		lua.rawgeti(L, idx, lua.Integer(slot))
		child := ui_marshal(marshal, -1, depth + 1)
		lua.pop(L, 1)
		if child == nil {
			continue
		}
		if child.key != "" {
			if seen_keys[child.key] {
				ui_marshal_fail(marshal, fmt.tprintf("duplicate key '%s' among siblings", child.key))
			}
			seen_keys[child.key] = true
		}
		append(&node.children, child)
		append(&node.child_slots, slot)
		if child.float == .None {
			laid += 1
		}
	}
	limit := -1
	#partial switch kind {
	case .Box, .Scroll:
		if laid != 1 {
			ui_marshal_fail(marshal, fmt.tprintf("%s: exactly one laid-out child expected, got %d", ui_kind_names[kind], laid))
		}
	case .Editor, .Virtual_Column, .Image, .Terminal, .Markdown, .Status:
		limit = 0
	case .Outlet:
		if len(node.children) > 0 {
			ui_marshal_fail(marshal, "outlet: no children (mount into it)")
		}
		if node.id == "" {
			ui_marshal_fail(marshal, "outlet: id expected")
		}
	}
	if limit == 0 && laid > 0 {
		ui_marshal_fail(marshal, fmt.tprintf("%s: only floating children allowed", ui_kind_names[kind]))
	}
	if kind == .Virtual_Column && (node.list == 0 || node.item_ref == 0) {
		ui_marshal_fail(marshal, "virtual_column: data and item expected")
	}
	if kind == .Image && node.path == "" {
		ui_marshal_fail(marshal, "image: path expected")
	}
	if kind == .Editor && node.buffer == 0 {
		ui_marshal_fail(marshal, "editor: buffer expected")
	}
	return node
}

ui_scope_check :: proc(editor: ^Editor, scope: string) {
	if scope in editor.ui.scopes_warned {
		return
	}
	for command in scoped_commands {
		if command.scope == scope {
			return
		}
	}
	for command in editor.plugins.commands {
		if command.scope == scope {
			return
		}
	}
	editor.ui.scopes_warned[strings.clone(scope)] = true
	editor_log(editor, .Warn, "UI", fmt.tprintf("scope '%s' has no commands", scope))
}

ui_marshal_tree :: proc(L: ^lua.State, editor: ^Editor, owner: string, idx: c.int, replacing: u64) -> (^UiNode, string) {
	marshal := UiMarshal{L = L, editor = editor, owner = owner}
	marshal.ids = make([dynamic]string, context.temp_allocator)
	root := ui_marshal(&marshal, idx, 0)
	if marshal.err == "" {
		ui_resolve(editor)
		seen := make(map[string]bool, 16, context.temp_allocator)
		for id in marshal.ids {
			if seen[id] {
				marshal.err = fmt.tprintf("duplicate id '%s'", id)
				break
			}
			seen[id] = true
			if ui_is_layer(id) {
				marshal.err = fmt.tprintf("id '%s' is a layer name", id)
				break
			}
			if other := ui_find(&editor.ui, fmt.tprintf("#%s/%s", owner, id)); other != nil && other.mount != replacing {
				marshal.err = fmt.tprintf("duplicate id '%s' (already in the tree)", id)
				break
			}
		}
	}
	if marshal.err != "" {
		ui_node_free(editor, root)
		return nil, marshal.err
	}
	return root, ""
}

qed_ui_mount :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	outlet := api_string(L, 1)
	plugin := api_loaded(L, editor)
	if outlet == "alert" && safety_open(editor) {
		return api_fail(L, "busy")
	}
	root, err := ui_marshal_tree(L, editor, plugin_name_intern(&editor.plugins, plugin.name), 2, 0)
	if root == nil {
		return plugin_raise(L, err)
	}
	handle := ui_mount_add(editor, root.owner, outlet, root)
	api_handle_push(L, handle, {{"update", qed_ui_handle_update}, {"unmount", qed_ui_handle_unmount}, {"wait", qed_ui_handle_wait}})
	return 1
}

qed_ui_handle_update :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	handle := api_handle_id(L)
	i := ui_mount_index(&editor.ui, handle)
	if i < 0 {
		return api_fail(L, "unmounted")
	}
	tree: c.int = 2 if lua.type(L, 1) == .TABLE && lua.gettop(L) >= 2 else 1
	root, err := ui_marshal_tree(L, editor, editor.ui.mounts[i].owner, tree, handle)
	if root == nil {
		return plugin_raise(L, err)
	}
	ui_mount_replace(editor, handle, root)
	lua.pushboolean(L, true)
	return 1
}

qed_ui_handle_unmount :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	ui := &entry.editor.ui
	handle := api_handle_id(L)
	if ui_mount_index(ui, handle) >= 0 && lua.gettop(L) >= 2 && lua.type(L, 2) != .NIL {
		lua.pushvalue(L, 2)
		ui.results[handle] = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	}
	ui_mount_remove(entry.editor, handle)
	return 0
}

qed_ui_handle_wait :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	handle := api_handle_id(L)
	if ui_mount_index(&entry.editor.ui, handle) < 0 {
		return ui_mount_result_push(L, entry.editor, handle)
	}
	t := api_await(L, p, "handle:wait")
	t.wait = {kind = .Mount, id = handle}
	return lua.yieldk(L, 0, lua.KContext(handle), qed_ui_handle_wait_k)
}

qed_ui_handle_wait_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	return ui_mount_result_push(L, entry.editor, u64(ctx))
}

ui_mount_result_push :: proc(L: ^lua.State, editor: ^Editor, handle: u64) -> c.int {
	if ref, ok := editor.ui.results[handle]; ok {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
		lua.L_unref(L, lua.REGISTRYINDEX, c.int(ref))
		delete_key(&editor.ui.results, handle)
	} else {
		lua.pushnil(L)
	}
	return 1
}

ui_mount_waiters_resume :: proc(editor: ^Editor) {
	p := &editor.plugins
	ui := &editor.ui
	ready := make([dynamic]u64, context.temp_allocator)
	for t in p.tasks {
		if t.wait.kind == .Mount && ui_mount_index(ui, t.wait.id) < 0 {
			append(&ready, t.id)
		}
	}
	for id in ready {
		plugin_task_resume(editor, id, 0)
	}
	waited := make(map[u64]bool, 8, context.temp_allocator)
	for t in p.tasks {
		if t.wait.kind == .Mount {
			waited[t.wait.id] = true
		}
	}
	gone := make([dynamic]u64, context.temp_allocator)
	for handle, ref in ui.results {
		if !waited[handle] && ui_mount_index(ui, handle) < 0 {
			lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ref))
			append(&gone, handle)
		}
	}
	for handle in gone {
		delete_key(&ui.results, handle)
	}
}

ui_node_ref_methods := [?]lua.L_Reg {
	{"focus", qed_ui_ref_focus},
	{"state", qed_ui_ref_state},
	{"set_state", qed_ui_ref_set_state},
	{"rect", qed_ui_ref_rect},
}

qed_ui_node :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	id := api_string(L, 1)
	if id == "" {
		lua.L_argerror(L, 1, "node id expected")
	}
	lua.createtable(L, 0, len(ui_node_ref_methods) + 1)
	lua.pushvalue(L, 1)
	lua.setfield(L, -2, "id")
	for method in ui_node_ref_methods {
		lua.pushvalue(L, lua.upvalueindex(1))
		lua.pushvalue(L, 1)
		lua.pushcclosure(L, method.func, 2)
		lua.setfield(L, -2, method.name)
	}
	return 1
}

qed_ui_focus_scopes :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.createtable(L, 0, 0)
	count: lua.Integer = 0
	for node := ui_focused(entry.editor); node != nil; node = node.parent {
		for scope in node.scope {
			count += 1
			lua.pushodinstring(L, scope)
			lua.rawseti(L, -2, count)
		}
	}
	return 1
}

ui_ref_identity :: proc(L: ^lua.State) -> string {
	id, _ := lua.toodinstring(L, lua.upvalueindex(2))
	plugin := api_loaded(L, plugin_entry(L).editor)
	return fmt.tprintf("#%s/%s", plugin.name, id)
}

qed_ui_ref_focus :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	identity := ui_ref_identity(L)
	ui_resolve(editor)
	if ui_find(&editor.ui, identity) == nil {
		return api_fail(L, "no such node")
	}
	ui_focus_set(editor, identity)
	lua.pushboolean(L, true)
	return 1
}

// a list's keys are all strings or all integers: a state key must match the list's kind
ui_state_key_arg :: proc(L: ^lua.State, editor: ^Editor, identity: string, state: ^UiState, what: string) -> string {
	key, kind := ui_list_key_read(L, -1, what)
	if node := ui_find(&editor.ui, identity); node != nil && node.kind == .Virtual_Column {
		if list := ui_list_find(&editor.ui, node.list); list != nil {
			owner := ui_list_keys_owner(editor, list)
			if owner.key_kind != .Unset && owner.key_kind != kind {
				plugin_raise(L, fmt.tprintf("%s: this list's keys are %s", what, "integers" if owner.key_kind == .Integer else "strings"))
			}
		}
	}
	state.key_kind = kind
	return key
}

qed_ui_ref_state :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	identity := ui_ref_identity(L)
	ui_resolve(editor)
	node := ui_find(&editor.ui, identity)
	state: UiState
	if node != nil {
		state = ui_node_state_peek(&editor.ui, node)
		state.kind = node.kind
	} else if kept, has := editor.ui.states[identity]; has {
		state = kept
	} else {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 3)
	#partial switch state.kind {
	case .Column, .Row, .Virtual_Column:
		list := ui_list_find(&editor.ui, node.list) if node != nil && node.kind == .Virtual_Column else nil
		for field in ([2]struct {
				name, key: string,
			}{{"highlighted", state.highlighted}, {"extend_from", state.extend_from}}) {
			if field.key == "" || (node != nil && !ui_highlight_present(editor, node, field.key)) {
				continue
			}
			// an unmounted node has no list to ask: the kind its key was set with answers
			if list == nil && state.key_kind == .Integer {
				lua.pushinteger(L, lua.Integer(strconv.parse_i64(field.key) or_else 0))
			} else {
				ui_list_push_key(L, editor, list, field.key)
			}
			lua.setfield(L, -2, strings.clone_to_cstring(field.name, context.temp_allocator))
		}
	case .Scroll:
		lua.pushinteger(L, lua.Integer(state.offset))
		lua.setfield(L, -2, "offset")
	case .Editor:
		lua.pushinteger(L, lua.Integer(state.scroll_row))
		lua.setfield(L, -2, "offset")
	case .Markdown:
		if node != nil {
			sources, rows := ui_markdown_sources(editor, node)
			lua.pushinteger(L, lua.Integer(rows))
			lua.setfield(L, -2, "rows")
			lua.createtable(L, c.int(len(sources)), 0)
			for source, i in sources {
				lua.pushinteger(L, lua.Integer(source + 1))
				lua.rawseti(L, -2, lua.Integer(i + 1))
			}
			lua.setfield(L, -2, "sources")
		}
		if state.md_found > 0 {
			lua.pushinteger(L, lua.Integer(state.md_found))
			lua.setfield(L, -2, "heading")
		}
	}
	return 1
}

qed_ui_ref_set_state :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "state patch table expected (call with ':')")
	}
	patch: c.int = 2 if lua.gettop(L) >= 2 else 1
	if lua.type(L, patch) != .TABLE {
		lua.L_argerror(L, patch, "state patch table expected")
	}
	identity := ui_ref_identity(L)
	ui_resolve(editor)
	state: ^UiState
	if node := ui_find(&editor.ui, identity); node != nil {
		state = ui_node_state(&editor.ui, node)
	} else {
		state = ui_state_key(&editor.ui, identity, true)
	}
	lua.pushnil(L)
	for lua.next(L, patch) != 0 {
		if lua.type(L, -2) != .STRING {
			return plugin_raise(L, "set_state: field names are strings")
		}
		name, _ := lua.toodinstring(L, -2)
		switch name {
		case "highlighted":
			// a rejected key raises before the old highlight is touched
			key := ""
			if lua.type(L, -1) != .NIL && lua.type(L, -1) != .BOOLEAN {
				key = ui_state_key_arg(L, editor, identity, state, "highlighted")
			}
			delete(state.highlighted)
			state.highlighted = strings.clone(key)
			if key != "" {
				state.reveal = true
				if node := ui_find(&editor.ui, identity); node != nil && node.kind == .Virtual_Column {
					ui_follow_park(editor, node, state.highlighted)
				}
			}
		case "extend_from":
			key := ""
			if lua.type(L, -1) != .NIL && lua.type(L, -1) != .BOOLEAN {
				key = ui_state_key_arg(L, editor, identity, state, "extend_from")
			}
			delete(state.extend_from)
			state.extend_from = strings.clone(key)
		case "offset":
			// a scroll keeps its rows in `offset`, an editor its top row in `scroll_row`: one name for both
			state.offset = max(int(lua.tointeger(L, -1)), 0)
			state.scroll_row, state.scroll_sub = state.offset, 0
			// as the wheel: an explicit position is the newer intent; layout reads at_end from it, parked or not
			state.at_end, state.parked = false, false
		case "source":
			state.md_source = max(int(lua.tointeger(L, -1)), 1)
		case "at":
			state.md_at = max(int(lua.tointeger(L, -1)), 0)
		case "heading":
			state.md_found = 0
			delete(state.md_heading)
			text, _ := lua.toodinstring(L, -1)
			state.md_heading = strings.clone(text)
		case:
			return plugin_raise(L, fmt.tprintf("set_state: unknown state field '%s'", name))
		}
		lua.pop(L, 1)
	}
	// a shown markdown resolves a heading or source row now, so a following state() sees it
	if node := ui_find(&editor.ui, identity); node != nil && node.kind == .Markdown && node.clip.h > 0 {
		if md, found := editor.ui.markdowns[identity]; found {
			ui_markdown_resolve(md, state, ui_markdown_scroller(editor, node), node.clip)
		}
	}
	return 0
}

qed_ui_ref_rect :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	ui_resolve(editor)
	node := ui_find(&editor.ui, ui_ref_identity(L))
	if node == nil || node.hidden {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 4)
	fields := [4]int{node.rect.x + 1, node.rect.y + 1, node.rect.w, node.rect.h}
	for name, i in ([?]cstring{"x", "y", "width", "height"}) {
		lua.pushinteger(L, lua.Integer(fields[i]))
		lua.setfield(L, -2, name)
	}
	return 1
}

UiHandlerArgs :: struct {
	chord, text: string,
	target:      string,
	state:       bool,
	highlighted: string,
	extend_from: string,
	list:        ^UiList,
	x, y:        int,
	button:      string,
	mouse:       bool,
}

ui_handler_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	args := (^UiHandlerArgs)(lua.touserdata(L, 2))
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.tointeger(L, 1))
	lua.createtable(L, 0, 4)
	if args.mouse {
		lua.pushinteger(L, lua.Integer(args.x))
		lua.setfield(L, -2, "x")
		lua.pushinteger(L, lua.Integer(args.y))
		lua.setfield(L, -2, "y")
		lua.pushodinstring(L, args.button)
		lua.setfield(L, -2, "button")
	} else {
		if args.chord != "" {
			lua.pushodinstring(L, args.chord)
			lua.setfield(L, -2, "chord")
		}
		if args.text != "" {
			lua.pushodinstring(L, args.text)
			lua.setfield(L, -2, "text")
		}
		if args.target != "" {
			lua.pushodinstring(L, args.target)
			lua.setfield(L, -2, "target")
		}
		if args.state {
			if args.highlighted != "" {
				ui_list_push_key(L, entry.editor, args.list, args.highlighted)
				lua.setfield(L, -2, "highlighted")
			}
			if args.extend_from != "" {
				ui_list_push_key(L, entry.editor, args.list, args.extend_from)
				lua.setfield(L, -2, "extend_from")
			}
		}
	}
	lua.call(L, 1, 1)
	return 1
}

ui_handler_call :: proc(editor: ^Editor, owner: string, ref: i32, args: UiHandlerArgs) -> bool {
	plugins := &editor.plugins
	if plugins.L == nil || ref == 0 {
		return false
	}
	args := args
	previous_owner := plugins.entry_owner
	plugins.entry_owner = owner
	defer plugins.entry_owner = previous_owner
	lua.pushcfunction(plugins.L, ui_handler_c)
	lua.pushinteger(plugins.L, lua.Integer(ref))
	lua.pushlightuserdata(plugins.L, &args)
	plugins.resumes += 1
	prev_slice := plugin_slice_begin(plugins, .When)
	ok, msg, tb := plugin_call(editor, 2, 1)
	if plugin_slice_end(editor, prev_slice, owner, .When, "ui handler") && ok {
		lua.pop(plugins.L, 1)
		ok, msg, tb = false, fmt.tprintf("ui handler exceeded its %.0f ms budget", plugin_budget(.When).hard_ms), ""
	}
	if !ok {
		if plugin := plugin_find(plugins, owner); plugin != nil {
			plugin_error(editor, plugin, msg, tb, false)
		}
		return false
	}
	handled := bool(lua.toboolean(plugins.L, -1))
	lua.pop(plugins.L, 1)
	return handled
}

UiItemBuild :: struct {
	editor: ^Editor,
	vc:     ^UiNode,
	list:   ^UiList,
	pos:    int,
	node:   ^UiNode,
	err:    string,
}

ui_item_build_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	build := (^UiItemBuild)(lua.touserdata(L, 1))
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(build.vc.item_ref))
	ui_list_record_push(L, build.editor, build.list, build.pos)
	lua.call(L, 1, 1)
	marshal := UiMarshal{L = L, editor = build.editor, owner = build.vc.owner}
	marshal.ids = make([dynamic]string, context.temp_allocator)
	node := ui_marshal(&marshal, -1, 0)
	if marshal.err == "" && len(marshal.ids) > 0 {
		marshal.err = "item nodes cannot carry an id (use key)"
	}
	if marshal.err != "" {
		ui_node_free(build.editor, node)
		build.err = strings.clone(marshal.err, context.temp_allocator)
		return 0
	}
	build.node = node
	return 0
}

ui_item_build :: proc(editor: ^Editor, vc: ^UiNode, list: ^UiList, pos: int, key: string) -> ^UiNode {
	plugins := &editor.plugins
	if plugins.L == nil {
		return nil
	}
	build := UiItemBuild{editor = editor, vc = vc, list = list, pos = pos}
	previous_owner := plugins.entry_owner
	plugins.entry_owner = vc.owner
	defer plugins.entry_owner = previous_owner
	lua.pushcfunction(plugins.L, ui_item_build_c)
	lua.pushlightuserdata(plugins.L, &build)
	plugins.resumes += 1
	prev_slice := plugin_slice_begin(plugins, .When)
	ok, msg, tb := plugin_call(editor, 1, 0)
	plugin_slice_end(editor, prev_slice, vc.owner, .When, "ui item")
	editor.ui.builds += 1
	if !ok || build.err != "" {
		if !ok {
			build.err = msg
		}
		if plugin := plugin_find(plugins, vc.owner); plugin != nil {
			plugin_error(editor, plugin, fmt.tprintf("item: %s", build.err), tb, false)
		}
		node := new(UiNode)
		node.kind = .Text
		node.owner = vc.owner
		append(&node.spans, UiSpan{text = strings.clone(fmt.tprintf("item error: %s", build.err)), style = {set = {.Fg}, fg = strings.clone("error_foreground")}})
		build.node = node
	}
	node := build.node
	delete(node.key)
	node.key = strings.clone(key)
	node.is_item = true
	delete(node.identity)
	node.identity = strings.clone(fmt.tprintf("%s/k%s", vc.identity, key))
	ui_children_identify(node, vc.mount)
	return node
}

qed_buf_create :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	internal := false
	path := ""
	if lua.type(L, 1) == .TABLE {
		lua.getfield(L, 1, "internal")
		internal = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		if text, ok := api_field_string(L, 1, "from"); ok && text != "" {
			path = api_path(editor, text)
		}
	}
	if !internal {
		return plugin_raise(L, "qed.buf.create: only internal buffers exist so far ({internal = true})")
	}
	plugin := api_loaded(L, editor)
	buffer := ui_internal_create(editor, plugin_name_intern(&editor.plugins, plugin.name))
	if path != "" {
		ui_internal_load(editor, buffer, path)
	}
	lua.pushinteger(L, lua.Integer(buffer.id))
	return 1
}

plugin_buffer_hooks_drop :: proc(plugins: ^Plugins, buffer: u64) {
	for i := len(plugins.hooks) - 1; i >= 0; i -= 1 {
		if plugins.hooks[i].buf == buffer {
			plugin_hook_remove(plugins, i)
		}
	}
}

qed_buf_on :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	plugins := &editor.plugins
	buffer, _ := api_buf(L, editor, 1)
	name := api_string(L, 2)
	if name != "change" {
		lua.L_argerror(L, 2, "buffer event expected: \"change\"")
	}
	if lua.type(L, 3) != .FUNCTION {
		lua.L_argerror(L, 3, "function expected")
	}
	plugin := api_loaded(L, editor)
	id := plugin_next_id(plugins)
	buf := buffer.id
	lua.settop(L, 3)
	api_handle_push(L, id, {{"remove", qed_hook_off}})
	lua.pushvalue(L, 3)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	append(&plugins.hooks, PluginHook{id = id, buf = buf, event = .Buf_Changed, owner = plugin.name, ref = ref})
	plugins.subs[.Buf_Changed] += 1
	return 1
}
