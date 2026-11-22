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

lua_refs_equal :: proc(L: ^lua.State, a, b: i32) -> bool {
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(a))
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(b))
	same := lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 2)
	return same
}

UI_COMMON_PROPS :: [?]string{"id", "key", "width", "height", "grow", "drop", "margin", "float", "anchor", "scope", "on", "fg", "bg", "bold", "italic", "underline"}

ui_kind_props := [UiKind][]string {
	.Column         = {"gap", "align", "separator", "highlight_style"},
	.Row            = {"gap", "align", "separator", "highlight_style"},
	.Box            = {"border", "title"},
	.Scroll         = {"header"},
	.Text           = {"wrap", "align"},
	.Editor         = {"buffer", "placeholder", "line_numbers", "syntax", "wrap", "readonly", "current_line_style"},
	.Virtual_Column = {"data", "item", "highlight_style"},
	.Outlet         = {},
}

UiMarshal :: struct {
	L:      ^lua.State,
	editor: ^Editor,
	owner:  string,
	err:    string,
	ids:    [dynamic]string,
}

ui_marshal_fail :: proc(m: ^UiMarshal, msg: string) {
	if m.err == "" {
		m.err = msg
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
	for n, k in ui_kind_names {
		if n == name {
			return k, true
		}
	}
	return {}, false
}

ui_positional_keys :: proc(L: ^lua.State, idx: c.int) -> []int {
	keys := make([dynamic]int, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		if lua.isinteger(L, -2) {
			k := int(lua.tointeger(L, -2))
			if k >= 1 && lua.type(L, -1) != .BOOLEAN {
				append(&keys, k)
			}
		}
		lua.pop(L, 1)
	}
	slice.sort(keys[:])
	return keys[:]
}

ui_marshal_size :: proc(m: ^UiMarshal, idx: c.int, what: string) -> UiSize {
	L := m.L
	idx := lua.absindex(L, idx)
	#partial switch lua.type(L, idx) {
	case .NIL:
		return {}
	case .NUMBER:
		if !lua.isinteger(L, idx) {
			ui_marshal_fail(m, fmt.tprintf("%s: whole cells expected", what))
			return {}
		}
		return {form = .Cells, value = max(int(lua.tointeger(L, idx)), 0)}
	case .STRING:
		s, _ := lua.toodinstring(L, idx)
		if s == "fit" {
			return {form = .Fit}
		}
		if strings.has_suffix(s, "%") {
			if n, ok := strconv.parse_int(s[:len(s) - 1]); ok && n >= 0 {
				return {form = .Percent, value = n}
			}
		}
		ui_marshal_fail(m, fmt.tprintf("%s: '%s' is not a size (n, \"N%%\", \"fit\")", what, s))
	case .TABLE:
		lua.rawgeti(L, idx, 1)
		size := ui_marshal_size(m, -1, what)
		lua.pop(L, 1)
		for bound, i in ([?]cstring{"min", "max"}) {
			lua.getfield(L, idx, bound)
			if lua.type(L, -1) == .NUMBER {
				v := max(int(lua.tointeger(L, -1)), 0)
				if i == 0 {
					size.min = v
				} else {
					size.max = v
				}
			}
			lua.pop(L, 1)
		}
		if size.form == .Auto {
			size.form = .Fit
		}
		return size
	case:
		ui_marshal_fail(m, fmt.tprintf("%s: size expected", what))
	}
	return {}
}

ui_marshal_margin :: proc(m: ^UiMarshal, idx: c.int) -> (out: [4]int) {
	L := m.L
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
					ui_marshal_fail(m, "margin: a number, {x =, y =} or named sides {top =, right =, bottom =, left =}")
				}
			}
			lua.pop(L, 1)
		}
		return
	}
	ui_marshal_fail(m, "margin: a number, {x =, y =} or named sides {top =, right =, bottom =, left =}")
	return
}

ui_marshal_style_field :: proc(m: ^UiMarshal, style: ^UiStyle, name: string, idx: c.int) -> bool {
	L := m.L
	switch name {
	case "fg", "bg":
		if lua.type(L, idx) != .STRING {
			ui_marshal_fail(m, fmt.tprintf("%s: theme color name expected", name))
			return true
		}
		s, _ := lua.toodinstring(L, idx)
		if name == "fg" {
			delete(style.fg)
			style.fg = strings.clone(s)
			style.set += {.Fg}
		} else {
			delete(style.bg)
			style.bg = strings.clone(s)
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

ui_marshal_style :: proc(m: ^UiMarshal, idx: c.int, what: string) -> (style: UiStyle) {
	L := m.L
	idx := lua.absindex(L, idx)
	if lua.type(L, idx) != .TABLE {
		ui_marshal_fail(m, fmt.tprintf("%s: style table expected", what))
		return
	}
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		if lua.type(L, -2) != .STRING {
			ui_marshal_fail(m, fmt.tprintf("%s: style fields are named", what))
		} else if name, _ := lua.toodinstring(L, -2); !ui_marshal_style_field(m, &style, name, -1) {
			ui_marshal_fail(m, fmt.tprintf("%s: unknown style field '%s'", what, name))
		}
		lua.pop(L, 1)
	}
	return
}

ui_marshal_spans :: proc(m: ^UiMarshal, node: ^UiNode, idx: c.int, inherited: UiStyle, depth: int) {
	L := m.L
	idx := lua.absindex(L, idx)
	if depth > UI_MARSHAL_DEPTH_MAX {
		ui_marshal_fail(m, "spans nested too deeply")
		return
	}
	style := inherited
	if depth > 0 {
		lua.pushnil(L)
		for lua.next(L, idx) != 0 {
			if lua.type(L, -2) == .STRING {
				name, _ := lua.toodinstring(L, -2)
				tmp: UiStyle
				if ui_marshal_style_field(m, &tmp, name, -1) {
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
					ui_marshal_fail(m, fmt.tprintf("span: unknown field '%s'", name))
				}
			}
			lua.pop(L, 1)
		}
	}
	for k in ui_positional_keys(L, idx) {
		lua.rawgeti(L, idx, lua.Integer(k))
		#partial switch lua.type(L, -1) {
		case .STRING, .NUMBER:
			s, _ := lua.toodinstring(L, -1)
			span := UiSpan{text = strings.clone(s), style = style}
			span.style.fg = strings.clone(style.fg)
			span.style.bg = strings.clone(style.bg)
			append(&node.spans, span)
		case .TABLE:
			if _, is_node := ui_node_kind(L, -1); is_node {
				ui_marshal_fail(m, "text children are strings and spans, not nodes")
			} else {
				ui_marshal_spans(m, node, -1, style, depth + 1)
			}
		case:
			ui_marshal_fail(m, "text children are strings and spans")
		}
		lua.pop(L, 1)
	}
}

ui_prop_allowed :: proc(kind: UiKind, name: string) -> bool {
	if kind == .Outlet {
		return name == "id"
	}
	for p in UI_COMMON_PROPS {
		if p == name {
			return true
		}
	}
	for p in ui_kind_props[kind] {
		if p == name {
			return true
		}
	}
	return false
}

ui_marshal :: proc(m: ^UiMarshal, idx: c.int, depth: int) -> ^UiNode {
	L := m.L
	idx := lua.absindex(L, idx)
	kind, ok := ui_node_kind(L, idx)
	if !ok {
		ui_marshal_fail(m, "node expected (build nodes with qed.ui.column, qed.ui.text, ...)")
		return nil
	}
	if depth > UI_MARSHAL_DEPTH_MAX {
		ui_marshal_fail(m, "tree nested too deeply")
		return nil
	}
	lua.L_checkstack(L, 8, "ui tree")
	node := new(UiNode)
	node.kind = kind
	node.owner = m.owner
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
			ui_marshal_fail(m, fmt.tprintf("%s: unknown prop '%s'", ui_kind_names[kind], name))
			lua.pop(L, 1)
			continue
		}
		v := lua.gettop(L)
		if ui_marshal_style_field(m, &node.style, name, v) {
			lua.pop(L, 1)
			continue
		}
		switch name {
		case "id", "key", "title", "placeholder":
			t := lua.type(L, v)
			if t != .STRING && !(t == .NUMBER && name == "key") {
				ui_marshal_fail(m, fmt.tprintf("%s: string expected", name))
				break
			}
			s, _ := lua.toodinstring(L, v)
			switch name {
			case "id":
				node.id = strings.clone(s)
				append(&m.ids, node.id)
			case "key":
				node.key = strings.clone(s)
			case "title":
				node.title = strings.clone(s)
			case "placeholder":
				node.placeholder = strings.clone(s)
			}
		case "width":
			node.width = ui_marshal_size(m, v, "width")
		case "height":
			node.height = ui_marshal_size(m, v, "height")
		case "grow":
			node.grow = int(lua.tointeger(L, v))
			node.grow_set = true
		case "drop":
			node.drop = int(lua.tointeger(L, v))
		case "gap":
			node.gap = max(int(lua.tointeger(L, v)), 0)
		case "margin":
			node.margin = ui_marshal_margin(m, v)
		case "float":
			s, _ := lua.toodinstring(L, v)
			switch s {
			case "parent":
				node.float = .Parent
			case "screen":
				node.float = .Screen
			case:
				ui_marshal_fail(m, "float: \"parent\" or \"screen\"")
			}
		case "anchor":
			s, _ := lua.toodinstring(L, v)
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
			for n, a in names {
				if n == s {
					node.anchor = a
					found = true
				}
			}
			if !found {
				ui_marshal_fail(m, fmt.tprintf("anchor: unknown '%s'", s))
			}
		case "align":
			value, _ := lua.toodinstring(L, v)
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
				ui_marshal_fail(m, fmt.tprintf("align: %s takes %s, center or %s, not '%s'", ui_kind_names[kind], start, finish, value))
			}
			if kind == .Text {
				node.text_align = node.align
				node.align = .Stretch
			}
		case "scope":
			scopes := make([dynamic]string)
			if lua.type(L, v) == .STRING {
				s, _ := lua.toodinstring(L, v)
				append(&scopes, strings.clone(s))
			} else if lua.type(L, v) == .TABLE {
				for k in ui_positional_keys(L, v) {
					lua.rawgeti(L, v, lua.Integer(k))
					s, _ := lua.toodinstring(L, -1)
					append(&scopes, strings.clone(s))
					lua.pop(L, 1)
				}
			} else {
				ui_marshal_fail(m, "scope: a scope name or a list of names")
			}
			node.scope = scopes[:]
			for scope in scopes {
				if scope == "editor" && kind != .Editor {
					ui_marshal_fail(m, "scope 'editor' only goes on an editor node")
				}
				ui_scope_check(m.editor, scope)
			}
		case "on":
			if lua.type(L, v) != .TABLE {
				ui_marshal_fail(m, "on: table of handlers expected")
				break
			}
			lua.pushnil(L)
			for lua.next(L, v) != 0 {
				if lua.type(L, -2) != .STRING {
					ui_marshal_fail(m, "on: handlers are named by event")
					lua.pop(L, 1)
					continue
				}
				ev_name, _ := lua.toodinstring(L, -2)
				found := false
				for n, e in ui_event_names {
					if n == ev_name {
						found = true
						if lua.type(L, -1) != .FUNCTION {
							ui_marshal_fail(m, fmt.tprintf("on.%s: function expected", n))
						} else {
							lua.pushvalue(L, -1)
							node.handlers[e] = i32(lua.L_ref(L, lua.REGISTRYINDEX))
						}
					}
				}
				if !found {
					ui_marshal_fail(m, fmt.tprintf("on: unknown event '%s'", ev_name))
				}
				lua.pop(L, 1)
			}
		case "separator":
			node.separator = bool(lua.toboolean(L, v))
		case "border":
			node.border = bool(lua.toboolean(L, v))
		case "wrap":
			node.wrap = bool(lua.toboolean(L, v))
			node.wrap_set = true
		case "line_numbers":
			node.line_numbers = bool(lua.toboolean(L, v))
		case "syntax":
			node.syntax = bool(lua.toboolean(L, v))
		case "readonly":
			node.readonly = bool(lua.toboolean(L, v))
		case "highlight_style":
			node.highlight_style = ui_marshal_style(m, v, name)
		case "current_line_style":
			node.current_line = ui_marshal_style(m, v, name)
		case "buffer":
			id := 0
			if lua.type(L, v) == .TABLE {
				id, _ = api_field_int(L, v, "id")
			} else if lua.isinteger(L, v) {
				id = int(lua.tointeger(L, v))
			}
			if ui_buffer(m.editor, u64(id)) == nil {
				ui_marshal_fail(m, "buffer: an open buffer (qed.buf.create or qed.buf.get) expected")
			}
			node.buffer = u64(id)
		case "header":
			if _, is_node := ui_node_kind(L, v); !is_node {
				ui_marshal_fail(m, "header: node expected")
				break
			}
			node.header = ui_marshal(m, v, depth + 1)
			if node.header != nil && node.header.float != .None {
				ui_marshal_fail(m, "header: a floating node cannot be a header")
			}
		case "data":
			list, gone := api_ui_list_lookup(L, m.editor, v)
			if list == nil {
				ui_marshal_fail(m, "data: the list is gone" if gone else "data: qed.list expected")
				break
			}
			node.list = list.id
			lua.pushvalue(L, v)
			node.list_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
		case "item":
			if lua.type(L, v) != .FUNCTION {
				ui_marshal_fail(m, "item: function(record) -> node expected")
				break
			}
			lua.pushvalue(L, v)
			node.item_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
		}
		lua.pop(L, 1)
	}
	if kind == .Text {
		ui_marshal_spans(m, node, idx, {}, 0)
		return node
	}
	laid := 0
	seen_keys := make(map[string]bool, 8, context.temp_allocator)
	for k in ui_positional_keys(L, idx) {
		lua.rawgeti(L, idx, lua.Integer(k))
		child := ui_marshal(m, -1, depth + 1)
		lua.pop(L, 1)
		if child == nil {
			continue
		}
		if child.key != "" {
			if seen_keys[child.key] {
				ui_marshal_fail(m, fmt.tprintf("duplicate key '%s' among siblings", child.key))
			}
			seen_keys[child.key] = true
		}
		append(&node.children, child)
		append(&node.child_slots, k)
		if child.float == .None {
			laid += 1
		}
	}
	limit := -1
	#partial switch kind {
	case .Box, .Scroll:
		if laid != 1 {
			ui_marshal_fail(m, fmt.tprintf("%s: exactly one laid-out child expected, got %d", ui_kind_names[kind], laid))
		}
	case .Editor, .Virtual_Column:
		limit = 0
	case .Outlet:
		if len(node.children) > 0 {
			ui_marshal_fail(m, "outlet: no children (mount into it)")
		}
		if node.id == "" {
			ui_marshal_fail(m, "outlet: id expected")
		}
	}
	if limit == 0 && laid > 0 {
		ui_marshal_fail(m, fmt.tprintf("%s: only floating children allowed", ui_kind_names[kind]))
	}
	if kind == .Virtual_Column && (node.list == 0 || node.item_ref == 0) {
		ui_marshal_fail(m, "virtual_column: data and item expected")
	}
	if kind == .Editor && node.buffer == 0 {
		ui_marshal_fail(m, "editor: buffer expected")
	}
	return node
}

ui_scope_check :: proc(editor: ^Editor, scope: string) {
	if scope in editor.ui.scopes_warned {
		return
	}
	for command in pane_commands {
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
	m := UiMarshal{L = L, editor = editor, owner = owner}
	m.ids = make([dynamic]string, context.temp_allocator)
	root := ui_marshal(&m, idx, 0)
	if m.err == "" {
		ui_resolve(editor)
		seen := make(map[string]bool, 16, context.temp_allocator)
		for id in m.ids {
			if seen[id] {
				m.err = fmt.tprintf("duplicate id '%s'", id)
				break
			}
			seen[id] = true
			if ui_is_layer(id) {
				m.err = fmt.tprintf("id '%s' is a layer name", id)
				break
			}
			if other := ui_find(&editor.ui, fmt.tprintf("#%s/%s", owner, id)); other != nil && other.mount != replacing {
				m.err = fmt.tprintf("duplicate id '%s' (already in the tree)", id)
				break
			}
		}
	}
	if m.err != "" {
		ui_node_free(editor, root)
		return nil, m.err
	}
	return root, ""
}

qed_ui_mount :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	outlet := api_string(L, 1)
	pl := api_loaded(L, editor)
	root, err := ui_marshal_tree(L, editor, plugin_name_intern(&editor.plugins, pl.name), 2, 0)
	if root == nil {
		return plugin_raise(L, err)
	}
	handle := ui_mount_add(editor, root.owner, outlet, root)
	api_handle_push(L, handle, {{"update", qed_ui_handle_update}, {"unmount", qed_ui_handle_unmount}})
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
	ui_mount_remove(entry.editor, api_handle_id(L))
	return 0
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
	for m in ui_node_ref_methods {
		lua.pushvalue(L, lua.upvalueindex(1))
		lua.pushvalue(L, 1)
		lua.pushcclosure(L, m.func, 2)
		lua.setfield(L, -2, m.name)
	}
	return 1
}

ui_ref_identity :: proc(L: ^lua.State) -> string {
	id, _ := lua.toodinstring(L, lua.upvalueindex(2))
	pl := api_loaded(L, plugin_entry(L).editor)
	return fmt.tprintf("#%s/%s", pl.name, id)
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
		if state.highlighted != "" && (node == nil || ui_highlight_present(editor, node, state.highlighted)) {
			lua.pushodinstring(L, state.highlighted)
			lua.setfield(L, -2, "highlighted")
		}
	case .Scroll:
		lua.pushinteger(L, lua.Integer(state.offset))
		lua.setfield(L, -2, "offset")
	case .Editor:
		lua.pushinteger(L, lua.Integer(state.scroll_row + 1))
		lua.setfield(L, -2, "scroll")
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
			delete(state.highlighted)
			state.highlighted = ""
			if lua.type(L, -1) == .STRING || lua.type(L, -1) == .NUMBER {
				s, _ := lua.toodinstring(L, -1)
				state.highlighted = strings.clone(s)
				state.reveal = true
			}
		case "offset":
			state.offset = max(int(lua.tointeger(L, -1)), 0)
		case "scroll":
			state.scroll_row = max(int(lua.tointeger(L, -1)) - 1, 0)
			state.scroll_sub = 0
		case:
			return plugin_raise(L, fmt.tprintf("set_state: unknown state field '%s'", name))
		}
		lua.pop(L, 1)
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
	}
	lua.call(L, 1, 1)
	return 1
}

ui_handler_call :: proc(editor: ^Editor, owner: string, ref: i32, args: UiHandlerArgs) -> bool {
	p := &editor.plugins
	if p.L == nil || ref == 0 {
		return false
	}
	args := args
	lua.pushcfunction(p.L, ui_handler_c)
	lua.pushinteger(p.L, lua.Integer(ref))
	lua.pushlightuserdata(p.L, &args)
	p.resumes += 1
	prev_slice := plugin_slice_begin(p, .When)
	ok, msg, tb := plugin_call(editor, 2, 1)
	if plugin_slice_end(editor, prev_slice, owner, .When, "ui handler") && ok {
		lua.pop(p.L, 1)
		ok, msg, tb = false, fmt.tprintf("ui handler exceeded its %.0f ms budget", plugin_budget(.When).hard_ms), ""
	}
	if !ok {
		if pl := plugin_find(p, owner); pl != nil {
			plugin_error(editor, pl, msg, tb, false)
		}
		return false
	}
	handled := bool(lua.toboolean(p.L, -1))
	lua.pop(p.L, 1)
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
	b := (^UiItemBuild)(lua.touserdata(L, 1))
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(b.vc.item_ref))
	ui_list_record_push(L, b.editor, b.list, b.pos)
	lua.call(L, 1, 1)
	m := UiMarshal{L = L, editor = b.editor, owner = b.vc.owner}
	m.ids = make([dynamic]string, context.temp_allocator)
	node := ui_marshal(&m, -1, 0)
	if m.err == "" && len(m.ids) > 0 {
		m.err = "item nodes cannot carry an id (use key)"
	}
	if m.err != "" {
		ui_node_free(b.editor, node)
		b.err = strings.clone(m.err, context.temp_allocator)
		return 0
	}
	b.node = node
	return 0
}

ui_item_build :: proc(editor: ^Editor, vc: ^UiNode, list: ^UiList, pos: int) -> ^UiNode {
	p := &editor.plugins
	if p.L == nil {
		return nil
	}
	build := UiItemBuild{editor = editor, vc = vc, list = list, pos = pos}
	lua.pushcfunction(p.L, ui_item_build_c)
	lua.pushlightuserdata(p.L, &build)
	p.resumes += 1
	prev_slice := plugin_slice_begin(p, .When)
	ok, msg, tb := plugin_call(editor, 1, 0)
	plugin_slice_end(editor, prev_slice, vc.owner, .When, "ui item")
	editor.ui.builds += 1
	if !ok || build.err != "" {
		if !ok {
			build.err = msg
		}
		if pl := plugin_find(p, vc.owner); pl != nil {
			plugin_error(editor, pl, fmt.tprintf("item: %s", build.err), tb, false)
		}
		node := new(UiNode)
		node.kind = .Text
		node.owner = vc.owner
		append(&node.spans, UiSpan{text = strings.clone(fmt.tprintf("item error: %s", build.err)), style = {set = {.Fg}, fg = strings.clone("error_foreground")}})
		build.node = node
	}
	node := build.node
	if pos >= ui_list_count(list) {
		ui_node_free(editor, node)
		return nil
	}
	key := ui_list_key(list, pos)
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
	if lua.type(L, 1) == .TABLE {
		lua.getfield(L, 1, "internal")
		internal = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	}
	if !internal {
		return plugin_raise(L, "qed.buf.create: only internal buffers exist so far ({internal = true})")
	}
	pl := api_loaded(L, editor)
	b := ui_internal_create(editor, plugin_name_intern(&editor.plugins, pl.name))
	lua.pushinteger(L, lua.Integer(b.id))
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
	p := &editor.plugins
	b, _ := api_buf(L, editor, 1)
	name := api_string(L, 2)
	if name != "change" {
		lua.L_argerror(L, 2, "buffer event expected: \"change\"")
	}
	if lua.type(L, 3) != .FUNCTION {
		lua.L_argerror(L, 3, "function expected")
	}
	pl := api_loaded(L, editor)
	id := plugin_next_id(p)
	buf := b.id
	lua.settop(L, 3)
	api_handle_push(L, id, {{"remove", qed_hook_off}})
	lua.pushvalue(L, 3)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	append(&p.hooks, PluginHook{id = id, buf = buf, event = .Buf_Changed, owner = pl.name, ref = ref})
	p.subs[.Buf_Changed] += 1
	return 1
}
