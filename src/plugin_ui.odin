package main

import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import lua "lib:lua"
import "lib:tb2"

QED_PRELUDE :: #load("prelude.lua", string)

PluginChunk :: struct {
	text, color: string,
}

api_plugin_chunks :: proc(L: ^lua.State, idx: c.int) -> []PluginChunk {
	idx := lua.absindex(L, idx)
	if lua.type(L, idx) != .TABLE {
		plugin_raise(L, "text must be a string or a table of chunks")
	}
	lua.L_checkstack(L, 4, "status chunks")
	n := int(lua.rawlen(L, idx))
	out := make([]PluginChunk, n, context.temp_allocator)
	for i in 1 ..= n {
		#partial switch lua.rawgeti(L, idx, lua.Integer(i)) {
		case .STRING:
			text, _ := lua.toodinstring(L, -1)
			out[i - 1].text = strings.clone(text, context.temp_allocator)
		case .TABLE:
			chunk := lua.gettop(L)
			out[i - 1].text, _ = api_field_string(L, chunk, "text")
			out[i - 1].color, _ = api_field_string(L, chunk, "color")
		case:
			plugin_raise(L, fmt.tprintf("text[%d] must be a string or {{text, color}}", i))
		}
		lua.pop(L, 1)
	}
	return out
}


PluginList :: struct {
	id:    u64,
	owner: string,
	src:   ListSource,
}


@(private = "file")
qed_walk_methods := [?]lua.L_Reg {
	{"count", qed_walk_count},
	{"ready", qed_walk_ready},
	{"ignore", qed_walk_ignore},
	{"within", qed_walk_within},
	{"union", qed_walk_union},
	{"tree", qed_walk_tree},
	{"release", qed_list_release},
}

plugin_prelude_c :: proc "c" (L: ^lua.State) -> c.int {
	if lua.L_loadbuffer(L, raw_data(QED_PRELUDE), c.size_t(len(QED_PRELUDE)), "=qed prelude", "t") != .OK {
		return lua.error(L)
	}
	lua.call(L, 0, 1)
	lua.setfield(L, lua.REGISTRYINDEX, "qed.prelude")
	return 0
}

plugin_prelude_install :: proc(L: ^lua.State) {
	if lua.getfield(L, lua.REGISTRYINDEX, "qed.prelude") != .FUNCTION {
		lua.pop(L, 1)
		return
	}
	lua.pushvalue(L, -2)
	lua.call(L, 1, 0)
	lua.getfield(L, -1, "buf")
	lua.getfield(L, -1, "__object")
	lua.setfield(L, lua.REGISTRYINDEX, QED_BUFFER_OBJECT)
	lua.pushnil(L)
	lua.setfield(L, -2, "__object")
	lua.pop(L, 1)
}

QED_BUFFER_OBJECT :: "qed.buffer_object"

api_buffer_object_push :: proc(L: ^lua.State, id: u64) {
	if lua.getfield(L, lua.REGISTRYINDEX, QED_BUFFER_OBJECT) != .FUNCTION {
		lua.pop(L, 1)
		lua.pushinteger(L, lua.Integer(id))
		return
	}
	lua.pushinteger(L, lua.Integer(id))
	lua.call(L, 1, 1)
}

plugin_list_free :: proc(p: ^Plugins, i: int) {
	list_source_free(&p.lists[i].src)
	ordered_remove(&p.lists, i)
}

plugin_list_index :: proc(p: ^Plugins, id: u64) -> int {
	for l, i in p.lists {
		if l.id == id {
			return i
		}
	}
	return -1
}

plugin_ui_destroy :: proc(p: ^Plugins) {
	for len(p.lists) > 0 {
		plugin_list_free(p, len(p.lists) - 1)
	}
	delete(p.lists)
}

plugin_ui_unload :: proc(editor: ^Editor, owner: string) {
	p := &editor.plugins
	for i := len(p.lists) - 1; i >= 0; i -= 1 {
		if p.lists[i].owner == owner {
			plugin_list_free(p, i)
		}
	}
	if p.theme_owner == owner {
		editor_theme_restore(editor)
		p.theme_owner = ""
	}
}

QED_LIST_META :: "qed.PaneSource"

qed_fs_walk :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	root := editor.working_root
	dotfiles, ignored := false, false
	#partial switch lua.type(L, 1) {
	case .NIL, .NONE:
	case .TABLE:
		if s, ok := api_field_string(L, 1, "root"); ok {
			root = api_path(editor, s)
		}
		dotfiles = api_opt_bool(L, 1, "dotfiles")
		ignored = api_opt_bool(L, 1, "ignored")
	case:
		lua.L_argerror(L, 1, "options table expected")
	}
	lua.settop(L, 0)
	src := api_list_push(L, editor, .Walk)
	src.walk = walk_acquire(editor, root, dotfiles, ignored)
	// a new handle sees the disk as of now
	walk_refresh(editor, src.walk)
	return 1
}

api_walk_handle :: proc(L: ^lua.State, editor: ^Editor) -> ^ListSource {
	li := api_list_handle(L, editor, 1)
	if li < 0 || editor.plugins.lists[li].src.kind != .Walk {
		lua.L_argerror(L, 1, "qed.fs.walk handle expected")
	}
	return &editor.plugins.lists[li].src
}

api_paths :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> []string {
	if lua.type(L, idx) != .TABLE {
		lua.L_argerror(L, idx, "list of paths expected")
	}
	n := int(lua.rawlen(L, idx))
	out := make([]string, n, context.temp_allocator)
	for i in 1 ..= n {
		if lua.rawgeti(L, idx, lua.Integer(i)) != .STRING {
			plugin_raise(L, fmt.tprintf("paths[%d] must be a string", i))
		}
		sv, _ := lua.toodinstring(L, -1)
		out[i - 1] = api_path(editor, sv)
		lua.pop(L, 1)
	}
	return out
}

qed_walk_count :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	src := api_walk_handle(L, entry.editor)
	// never a synchronous full walk inside a Lua slice
	if !walk_ready(entry.editor, src) {
		walk_prewarm(entry.editor, src.walk)
		return api_fail(L, "pending")
	}
	lua.pushinteger(L, lua.Integer(len(walk_source_cands(entry.editor, src))))
	return 1
}

qed_walk_ignore :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	src := api_walk_handle(L, editor)
	set := make(map[string]bool, context.temp_allocator)
	if lua.type(L, 2) == .BOOLEAN && !lua.toboolean(L, 2) {
		// not known yet: a walk run now would descend into everything the set will hide
		walk_ignore_set(editor, src.walk.root, set, false)
		walk_stale(src.walk)
		return 0
	}
	for path in api_paths(L, editor, 2) {
		set[path] = true
	}
	walk_ignore_set(editor, src.walk.root, set, true)
	return 0
}

qed_walk_ready :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	src := api_walk_handle(L, entry.editor)
	lua.pushboolean(L, b32(walk_ready(entry.editor, src)))
	return 1
}

qed_walk_within :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	src := api_walk_handle(L, editor)
	if src.wscope != nil {
		plugin_raise(L, "within: the handle is already narrowed")
	}
	paths := api_paths(L, editor, 2)
	w := src.walk
	lua.settop(L, 0)
	dst := api_list_push(L, editor, .Walk)
	w.refs += 1
	dst.walk = w
	dst.wscope = walk_scope_new(w.root, nil, paths, nil)
	return 1
}

qed_walk_union :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	src := api_walk_handle(L, editor)
	paths := api_paths(L, editor, 2)
	w, parent := src.walk, src.wscope
	lua.settop(L, 0)
	dst := api_list_push(L, editor, .Walk)
	w.refs += 1
	dst.walk = w
	dst.wscope = walk_scope_new(w.root, parent, nil, paths)
	dst.wscope.all = parent == nil || parent.all
	return 1
}

qed_walk_tree :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	src := api_walk_handle(L, editor)
	walk, scope := src.walk, src.wscope
	max := 0
	if lua.type(L, 2) == .TABLE {
		if limit, ok := api_field_int(L, 2, "max"); ok {
			max = limit
		}
	}
	plugin := api_loaded(L, editor)
	lua.settop(L, 0)
	list := api_ui_list_push(L, editor, plugin.name, false, tree = true)
	list.tree = walk_tree_new(walk, scope)
	list.tree.max = max
	walk_trees_settle(editor)
	return 1
}

// The record goes in after the last call that can raise, so the caller acquires what src owns only then.
api_list_push :: proc(L: ^lua.State, editor: ^Editor, kind: ListSourceKind) -> ^ListSource {
	p := &editor.plugins
	pl := api_loaded(L, editor)
	id := plugin_next_id(p)
	lua.createtable(L, 0, 1)
	lua.pushinteger(L, lua.Integer(id))
	lua.setfield(L, -2, "id")
	if lua.getfield(L, lua.REGISTRYINDEX, QED_LIST_META) != .TABLE {
		lua.pop(L, 1)
		lua.createtable(L, 0, 2)
		lua.pushcfunction(L, qed_list_gc)
		lua.setfield(L, -2, "__gc")
		lua.pushboolean(L, false)
		lua.setfield(L, -2, "__metatable")
		lua.pushvalue(L, -1)
		lua.setfield(L, lua.REGISTRYINDEX, QED_LIST_META)
	}
	lua.setmetatable(L, -2)
	if kind == .Walk {
		for m in qed_walk_methods {
			lua.pushvalue(L, lua.upvalueindex(1))
			lua.pushcclosure(L, m.func, 1)
			lua.setfield(L, -2, m.name)
		}
	}
	append(&p.lists, PluginList{id = id, owner = plugin_name_intern(p, pl.name), src = {kind = kind}})
	return &p.lists[len(p.lists) - 1].src
}

qed_list_release :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	id, _ := api_field_int(L, 1, "id")
	if i := plugin_list_index(p, u64(id)); i >= 0 {
		plugin_list_free(p, i)
	}
	return 0
}

qed_list_gc :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return 0
	}
	context = entry.ctx
	p := &entry.editor.plugins
	lua.getfield(L, 1, "id")
	id := lua.tointeger(L, -1)
	if i := plugin_list_index(p, u64(id)); i >= 0 {
		plugin_list_free(p, i)
	}
	return 0
}

api_list_handle :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> int {
	idx := lua.absindex(L, idx)
	if lua.getmetatable(L, idx) == 0 {
		return -1
	}
	lua.getfield(L, lua.REGISTRYINDEX, QED_LIST_META)
	is_list := lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 2)
	if !is_list {
		return -1
	}
	id, _ := api_field_int(L, idx, "id")
	i := plugin_list_index(&editor.plugins, u64(id))
	if i < 0 {
		plugin_raise(L, "list handle is gone")
	}
	return i
}

api_opt_bool :: proc(L: ^lua.State, t: c.int, key: cstring) -> bool {
	tp := lua.getfield(L, t, key)
	b := bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	if tp != .NIL && tp != .BOOLEAN {
		plugin_raise(L, fmt.tprintf("%s must be a boolean", key))
	}
	return b
}

qed_theme_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	name := strings.clone(api_string(L, 1), context.temp_allocator)
	persist := false
	#partial switch lua.type(L, 2) {
	case .NIL, .NONE:
	case .TABLE:
		lua.getfield(L, 2, "persist")
		persist = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	case:
		lua.L_argerror(L, 2, "options table expected")
	}
	ok, err := editor_theme_set(entry.editor, name, persist)
	if pl := plugin_owner(L, entry.editor); pl != nil && !persist && entry.editor.theme_shown != "" {
		entry.editor.plugins.theme_owner = pl.name
	}
	if !ok {
		return api_fail(L, err)
	}
	lua.pushboolean(L, true)
	return 1
}

qed_theme_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	names := theme_names(config_path())
	lua.createtable(L, c.int(len(names)), 0)
	for n, i in names {
		lua.pushodinstring(L, n)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

qed_theme_current :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, editor_theme_current(entry.editor))
	return 1
}

qed_languages :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.createtable(L, len(Language), 0)
	n := 0
	for info, lang in LANGUAGES {
		if lang == .MarkdownInline {
			continue
		}
		n += 1
		lua.pushodinstring(L, info.name)
		lua.rawseti(L, -2, lua.Integer(n))
	}
	return 1
}

PluginStatus :: struct {
	owner, id, text, color, sep: string,
	chunks:                      [dynamic]PluginChunk,
	right, early:                bool,
	drop:                        int,
}

plugin_status_free :: proc(s: PluginStatus) {
	delete(s.id)
	delete(s.text)
	delete(s.color)
	delete(s.sep)
	for c in s.chunks {
		delete(c.text)
		delete(c.color)
	}
	delete(s.chunks)
}

plugin_status_find :: proc(p: ^Plugins, owner, id: string) -> int {
	for s, i in p.status {
		if s.owner == owner && s.id == id {
			return i
		}
	}
	return -1
}

plugin_status_unload :: proc(p: ^Plugins, owner: string) {
	for i := len(p.status) - 1; i >= 0; i -= 1 {
		if p.status[i].owner == owner {
			plugin_status_free(p.status[i])
			ordered_remove(&p.status, i)
		}
	}
}

plugin_status_segs :: proc(p: ^Plugins, left, right: ^[dynamic]StatusSeg, early: bool) {
	at := 0
	for s in p.status {
		if s.text == "" || (s.right ? early : s.early != early) {
			continue
		}
		fg := COLOR_PANE_FG
		if s.color != "" {
			fg = g_theme_colors[s.color] or_else COLOR_PANE_FG
		}
		seg := StatusSeg{sep = s.sep, text = s.text, fg = fg, kind = .Plugin, drop = s.drop}
		if len(s.chunks) > 0 {
			chunks := make([]StatusChunk, len(s.chunks), context.temp_allocator)
			for c, i in s.chunks {
				chunks[i] = {c.text, g_theme_colors[c.color] or_else fg}
			}
			seg.chunks = chunks
		}
		if s.right {
			inject_at(right, at, seg)
			at += 1
		} else {
			append(left, seg)
		}
	}
}

api_theme_color :: proc(L: ^lua.State, key: string) {
	if key not_in g_theme_colors {
		plugin_raise(L, fmt.tprintf("unknown theme color '%s'", key))
	}
}

api_one_line :: proc(s: string) -> string {
	if !strings.contains_any(s, "\t\r\n") {
		return s
	}
	out, _ := strings.replace_all(s, "\r\n", " ", context.temp_allocator)
	for ch in ([3]string{"\t", "\r", "\n"}) {
		out, _ = strings.replace_all(out, ch, " ", context.temp_allocator)
	}
	return out
}

qed_status_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	id := api_string(L, 1)
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "table {text, color?, side?, drop?} expected")
	}
	lua.settop(L, 2)
	lua.L_checkstack(L, 4, "status options")
	text := ""
	chunks: []PluginChunk
	lua.getfield(L, 2, "text")
	#partial switch lua.type(L, -1) {
	case .STRING:
		text, _ = lua.toodinstring(L, -1)
		text = api_one_line(strings.clone(text, context.temp_allocator))
	case .TABLE:
		chunks = api_plugin_chunks(L, lua.gettop(L))
		parts := make([]string, len(chunks), context.temp_allocator)
		for &c, i in chunks {
			c.text = api_one_line(c.text)
			if c.color != "" {
				api_theme_color(L, c.color)
			}
			parts[i] = c.text
		}
		text = strings.concatenate(parts, context.temp_allocator)
	case:
		return plugin_raise(L, "text must be a string or a list of {text, color}")
	}
	lua.pop(L, 1)
	sep := "  "
	if v, ok := api_field_string(L, 2, "sep"); ok {
		sep = api_one_line(v)
	}
	lua.getfield(L, 2, "early")
	early := bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	color, _ := api_field_string(L, 2, "color")
	if color != "" {
		api_theme_color(L, color)
	}
	side, _ := api_field_string(L, 2, "side")
	if side != "" && side != "left" && side != "right" {
		return plugin_raise(L, `side must be "left" or "right"`)
	}
	drop := 1
	if lua.getfield(L, 2, "drop") != .NIL {
		drop = api_int(L, -1, "drop must be an integer")
		if drop < 0 {
			return plugin_raise(L, "drop must be >= 0")
		}
	}
	lua.pop(L, 1)
	pl := api_loaded(L, editor)
	owner := plugin_name_intern(p, pl.name)
	s := PluginStatus{owner = owner, text = strings.clone(text), color = strings.clone(color), sep = strings.clone(sep), right = side == "right", early = early, drop = drop}
	for c in chunks {
		append(&s.chunks, PluginChunk{strings.clone(c.text), strings.clone(c.color)})
	}
	if i := plugin_status_find(p, owner, id); i >= 0 {
		s.id = p.status[i].id
		p.status[i].id = ""
		plugin_status_free(p.status[i])
		p.status[i] = s
	} else {
		s.id = strings.clone(id)
		append(&p.status, s)
	}
	return 0
}

qed_status_clear :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	id := api_string(L, 1)
	pl := api_loaded(L, entry.editor)
	if i := plugin_status_find(p, pl.name, id); i >= 0 {
		plugin_status_free(p.status[i])
		ordered_remove(&p.status, i)
	}
	return 0
}
