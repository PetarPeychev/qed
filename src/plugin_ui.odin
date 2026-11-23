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

ViewEvent :: enum {
	Activate,
	Change,
	Query,
	Close,
	Link,
	Tab,
	Expand,
	Submit,
}

view_event_names := [ViewEvent]cstring {
	.Activate = "activate",
	.Change   = "change",
	.Query    = "query",
	.Close    = "close",
	.Link     = "link",
	.Tab      = "tab",
	.Expand   = "expand",
	.Submit   = "submit",
}

UiView :: struct {
	handle:      u64,
	owner:       string,
	view_ref:    i32,
	items_ref:   i32,
	on:          [ViewEvent]i32,
	change_task: u64,
	query_task:  u64,
	// a markdown body's last visible rows, so the close handler can still map them to source rows
	md_closed:   bool,
	md_scroll:   int,
	md_top:      int,
	md_src:      []int,
}

UiViewEvent :: struct {
	handle:   u64,
	kind:     ViewEvent,
	sel:      []int,
	items:    []PaneItem,
	text:     string,
	has_text: bool,
	n:        int,
}

PluginAnswer :: struct {
	handle:    u64,
	ok:        bool,
	items_ref: i32,
	sel:       []int,
	items:     []PaneItem,
	text:      string,
	has_text:  bool,
}

PluginList :: struct {
	id:    u64,
	owner: string,
	src:   ListSource,
}

@(private = "file")
qed_view_methods := [?]lua.L_Reg {
	{"set", qed_view_set},
	{"append", qed_view_append},
	{"update", qed_view_update},
	{"text", qed_view_text},
	{"info", qed_view_info},
	{"markdown", qed_view_markdown},
	{"anchor", qed_view_anchor},
	{"scroll", qed_view_scroll},
	{"source_line", qed_view_source_line},
	{"source_scroll", qed_view_source_scroll},
	{"close", qed_view_close},
	{"wait", qed_view_wait},
	{"marks", qed_view_marks},
	{"footer", qed_view_footer},
	{"tab", qed_view_tab},
	{"preview", qed_view_preview},
	{"expand", qed_view_expand},
	{"reveal", qed_view_reveal},
	{"select", qed_view_select},
	{"selection", qed_view_selection},
	{"on", qed_view_on},
}

@(private = "file")
qed_walk_methods := [?]lua.L_Reg {
	{"count", qed_walk_count},
	{"ready", qed_walk_ready},
	{"ignore", qed_walk_ignore},
	{"within", qed_walk_within},
	{"union", qed_walk_union},
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

plugin_view_index :: proc(p: ^Plugins, handle: u64) -> int {
	for v, i in p.views {
		if v.handle == handle {
			return i
		}
	}
	return -1
}

plugin_view_release :: proc(p: ^Plugins, i: int) {
	v := p.views[i]
	if p.L != nil {
		for ref in ([2]i32{v.view_ref, v.items_ref}) {
			if ref != 0 {
				lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ref))
			}
		}
		for ref in v.on {
			if ref != 0 {
				lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ref))
			}
		}
	}
	delete(v.md_src)
	ordered_remove(&p.views, i)
}

plugin_view_event_free :: proc(ev: UiViewEvent) {
	delete(ev.sel)
	for it in ev.items {
		pane_item_free(it)
	}
	delete(ev.items)
	delete(ev.text)
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
	for len(p.views) > 0 {
		plugin_view_release(p, len(p.views) - 1)
	}
	delete(p.views)
	for ev in p.view_events {
		plugin_view_event_free(ev)
	}
	delete(p.view_events)
	for len(p.lists) > 0 {
		plugin_list_free(p, len(p.lists) - 1)
	}
	delete(p.lists)
}

plugin_ui_unload :: proc(editor: ^Editor, owner: string) {
	p := &editor.plugins
	for i := len(p.views) - 1; i >= 0; i -= 1 {
		if p.views[i].owner == owner {
			plugin_view_release(p, i)
		}
	}
	for i := len(p.view_events) - 1; i >= 0; i -= 1 {
		if plugin_view_index(p, p.view_events[i].handle) < 0 {
			plugin_view_event_free(p.view_events[i])
			ordered_remove(&p.view_events, i)
		}
	}
	for i := len(p.lists) - 1; i >= 0; i -= 1 {
		if p.lists[i].owner == owner {
			plugin_list_free(p, i)
		}
	}
	pane_unload(editor, owner)
	if p.theme_owner == owner {
		editor_theme_restore(editor)
		p.theme_owner = ""
	}
}

plugin_command_id_matches :: proc(editor: ^Editor, id: u64, ev: tb2.Event) -> bool {
	for cmd in editor.plugins.commands {
		if cmd.id == id {
			return plugin_command_matches(cmd, ev)
		}
	}
	return false
}

plugin_view_queue :: proc(editor: ^Editor, pn: ^Pane, kind: ViewEvent, sel: []int) {
	ev := UiViewEvent{handle = pn.handle, kind = kind, sel = sel}
	if len(pn.fields) > 0 {
		ev.text = strings.clone(pane_field_value(editor, &pn.fields[0]))
		ev.has_text = true
	}
	if pn.list.source.kind != .None && len(sel) > 0 {
		ev.items = make([]PaneItem, len(sel))
		for idx, i in sel {
			ev.items[i] = pane_item_clone(list_item(editor, pn, idx))
		}
	}
	append(&editor.plugins.view_events, ev)
}

plugin_view_closed :: proc(editor: ^Editor, pn: ^Pane) {
	pane_save(editor, pn)
	if vi := plugin_view_index(&editor.plugins, pn.handle); vi >= 0 && pn.has_md {
		v := &editor.plugins.views[vi]
		scroll, src := pane_md_visible(editor, pn)
		v.md_closed, v.md_scroll, v.md_src = true, scroll, slice.clone(src)
		v.md_top = pane_geom(editor, pn).text.y
	}
	plugin_view_queue(editor, pn, .Close, nil)
}

plugin_view_tab :: proc(editor: ^Editor, pn: ^Pane) {
	append(&editor.plugins.view_events, UiViewEvent{handle = pn.handle, kind = .Tab, n = pn.tab + 1})
}

plugin_view_expand :: proc(editor: ^Editor, pn: ^Pane, path: string, on: bool) {
	items := make([]PaneItem, 1)
	items[0] = pane_item_clone({label = filepath.base(path), path = path, key = path, dir = true})
	append(&editor.plugins.view_events, UiViewEvent{handle = pn.handle, kind = .Expand, items = items, n = int(on)})
}

plugin_view_submit :: proc(editor: ^Editor, pn: ^Pane, text: string, ok: bool) {
	append(&editor.plugins.view_events, UiViewEvent{handle = pn.handle, kind = .Submit, text = strings.clone(text), has_text = ok})
}

plugin_view_link :: proc(editor: ^Editor, pn: ^Pane, target: string) -> bool {
	vi := plugin_view_index(&editor.plugins, pn.handle)
	if target[0] == '#' && (vi < 0 || editor.plugins.views[vi].on[.Link] == 0) {
		return false
	}
	append(&editor.plugins.view_events, UiViewEvent{handle = pn.handle, kind = .Link, text = strings.clone(target), has_text = true})
	return true
}

plugin_view_activate :: proc(editor: ^Editor, pn: ^Pane) {
	p := &editor.plugins
	if vi := plugin_view_index(p, pn.handle); vi >= 0 && plugin_view_waiting(p, pn, vi) {
		pn.accept = true
		pn.query_at = time.tick_now()
		return
	}
	plugin_view_activate_now(editor, pn)
}

plugin_view_activate_now :: proc(editor: ^Editor, pn: ^Pane) {
	for f in pn.fields {
		if f.mode == .Input || f.mode == .Path {
			plugin_view_queue(editor, pn, .Activate, nil)
			return
		}
	}
	if !pn.has_list || pane_count(editor, pn) == 0 {
		return
	}
	plugin_view_queue(editor, pn, .Activate, pane_selection(editor, pn, context.allocator))
}

pane_selection :: proc(editor: ^Editor, pn: ^Pane, allocator := context.temp_allocator) -> []int {
	if pane_count(editor, pn) == 0 {
		return nil
	}
	lo, hi := pn.list.sel, pn.list.sel
	if a, ok := pn.list.anchor.?; ok && pn.list.multi {
		lo, hi = min(a, pn.list.sel), max(a, pn.list.sel)
	}
	sel := make([]int, hi - lo + 1, allocator)
	for pos in lo ..= hi {
		sel[pos - lo] = pane_item_index(pn, pos)
	}
	return sel
}

plugin_views_due :: proc(editor: ^Editor) -> bool {
	for p in editor.panes {
		if p.ctx.lua && (p.query_due || p.accept) {
			return true
		}
	}
	return false
}

plugin_view_handles :: proc(p: ^Plugins) -> []u64 {
	hs := make([]u64, len(p.views), context.temp_allocator)
	for v, i in p.views {
		hs[i] = v.handle
	}
	return hs
}

plugin_view_waiting :: proc(p: ^Plugins, pn: ^Pane, vi: int) -> bool {
	return pane_query(pn) != nil && (pn.query_due || (!pn.landed && plugin_task_alive(p, p.views[vi].query_task)))
}

plugin_views_pump :: proc(editor: ^Editor) {
	p := &editor.plugins
	now := time.tick_now()
	for h in plugin_view_handles(p) {
		vi, pi := plugin_view_index(p, h), pane_index(editor, h)
		if vi < 0 || pi < 0 || !pane_live(editor, &editor.panes[pi]) {
			continue
		}
		v := p.views[vi]
		if pn := &editor.panes[pi]; pn.query_due && plugin_tick_due(pn.query_at, now) {
			pn.query_due, pn.landed = false, false
			text := strings.clone(textfield_str(&pane_query(pn).field), context.temp_allocator)
			plugin_task_kill(editor, v.query_task)
			task: u64
			if v.on[.Query] != 0 {
				id, finished := plugin_task_start(editor, v.owner, .Command, {ref = v.on[.Query], args = .View_Text, view_ref = v.view_ref, line = text})
				task = 0 if finished else id
			}
			if j := plugin_view_index(p, h); j >= 0 {
				p.views[j].query_task = task
			}
		}
		vi, pi = plugin_view_index(p, h), pane_index(editor, h)
		if vi < 0 || pi < 0 {
			continue
		}
		if pn := &editor.panes[pi]; pn.accept && !plugin_view_waiting(p, pn, vi) {
			pn.accept = false
			plugin_view_activate_now(editor, pn)
		}
	}
}

// walk lists rebuild their rows on every refill, so their selection is tracked by key
plugin_view_moved :: proc(editor: ^Editor, pn: ^Pane) -> (item: int, moved: bool) {
	item = pane_item_index(pn, pn.list.sel)
	if pn.list.source.kind != .Walk {
		moved = item != pn.notified
		pn.notified = item
		return
	}
	key := pane_selected_key(editor, pn)
	moved = pn.notified < 0 || key != pn.notified_key
	pn.notified = item
	delete(pn.notified_key)
	pn.notified_key = strings.clone(key)
	return
}

plugin_views_flush :: proc(editor: ^Editor) {
	p := &editor.plugins
	for h in plugin_view_handles(p) {
		vi, pi := plugin_view_index(p, h), pane_index(editor, h)
		if vi < 0 || pi < 0 || !pane_live(editor, &editor.panes[pi]) {
			continue
		}
		v := p.views[vi]
		pn := &editor.panes[pi]
		if pane_count(editor, pn) == 0 {
			continue
		}
		item, moved := plugin_view_moved(editor, pn)
		if !moved {
			continue
		}
		if v.on[.Change] == 0 {
			continue
		}
		plugin_task_kill(editor, v.change_task)
		start := PluginStart{ref = v.on[.Change], args = .View_Item, view_ref = v.view_ref, item_ref = v.items_ref, item = item + 1}
		one: [1]PaneItem
		if pn.list.source.kind != .None {
			one[0] = list_item(editor, pn, item)
			start.pitems = one[:]
		}
		task, finished := plugin_task_start(editor, v.owner, .Command, start)
		if j := plugin_view_index(p, h); j >= 0 {
			p.views[j].change_task = 0 if finished else task
		}
	}
	for _ in 0 ..< PLUGIN_FLUSH_ROUNDS {
		if len(p.view_events) == 0 {
			break
		}
		batch := p.view_events
		p.view_events = {}
		for ev in batch {
			plugin_view_event(editor, ev)
			plugin_view_event_free(ev)
		}
		delete(batch)
	}
}

plugin_view_event :: proc(editor: ^Editor, ev: UiViewEvent) {
	p := &editor.plugins
	vi := plugin_view_index(p, ev.handle)
	if vi < 0 {
		return
	}
	v := p.views[vi]
	#partial switch ev.kind {
	case .Link:
		if v.on[.Link] != 0 {
			plugin_task_start(editor, v.owner, .Command, {ref = v.on[.Link], args = .View_Text, view_ref = v.view_ref, line = ev.text})
		}
		return
	case .Tab:
		if v.on[.Tab] != 0 {
			plugin_task_start(editor, v.owner, .Command, {ref = v.on[.Tab], args = .View_Int, view_ref = v.view_ref, item = ev.n})
		}
		return
	case .Expand:
		if v.on[.Expand] != 0 {
			plugin_task_start(editor, v.owner, .Command, {ref = v.on[.Expand], args = .View_Expand, view_ref = v.view_ref, item = ev.n, pitems = ev.items})
		}
		return
	case .Submit:
		if v.on[.Submit] != 0 {
			plugin_task_start(editor, v.owner, .Command, {ref = v.on[.Submit], args = .View_Submit, view_ref = v.view_ref, item = int(ev.has_text), line = ev.text})
		}
		return
	}
	if ev.kind == .Close {
		plugin_task_kill(editor, v.change_task)
		plugin_task_kill(editor, v.query_task)
	}
	prev := p.answer
	p.answer = {handle = ev.handle, ok = ev.kind == .Activate, items_ref = v.items_ref, sel = ev.sel, items = ev.items, text = ev.text, has_text = ev.has_text}
	for w in plugin_waiters(p, .Pane, ev.handle) {
		plugin_task_resume(editor, w, 0)
	}
	p.answer = prev
	if ref := v.on[ev.kind]; ref != 0 {
		args := PluginArgs.View_Items if ev.kind == .Activate else .View
		plugin_task_start(editor, v.owner, .Command, {ref = ref, args = args, view_ref = v.view_ref, item_ref = v.items_ref, items = ev.sel, pitems = ev.items, view = ev.handle if ev.kind == .Activate else 0})
	}
	if ev.kind == .Close {
		if vi = plugin_view_index(p, ev.handle); vi >= 0 {
			plugin_view_release(p, vi)
		}
	}
}

QED_LIST_META :: "qed.PaneSource"

qed_fs_dirs :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	path := editor.working_root
	dotfiles := false
	#partial switch lua.type(L, 1) {
	case .NIL, .NONE:
	case .TABLE:
		if s, ok := api_field_string(L, 1, "path"); ok {
			path = api_path(editor, s)
		}
		dotfiles = api_opt_bool(L, 1, "dotfiles")
	case:
		lua.L_argerror(L, 1, "options table expected")
	}
	lua.settop(L, 0)
	src := api_list_push(L, editor, .Dirs)
	src.path = strings.clone(path)
	src.dotfiles = dotfiles
	return 1
}

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

qed_buf_line_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	b, _ := api_buf(L, editor, 1)
	id := b.id
	lua.settop(L, 0)
	api_list_push(L, editor, .Lines).buf = id
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

api_view_handle_check :: proc(L: ^lua.State, pn: ^Pane) {
	if pn != nil && pn.list.source.kind != .None {
		plugin_raise(L, "the list is backed by a list handle; replace it with View:set")
	}
}

api_pane_item_push :: proc(L: ^lua.State, it: PaneItem) {
	lua.L_checkstack(L, 3, "item")
	lua.createtable(L, 0, 4)
	lua.pushodinstring(L, it.label)
	lua.setfield(L, -2, "label")
	if it.path != "" {
		lua.pushodinstring(L, it.path)
		lua.setfield(L, -2, "path")
	}
	if it.detail != "" {
		lua.pushodinstring(L, it.detail)
		lua.setfield(L, -2, "detail")
	}
	if it.buf != 0 {
		api_buffer_object_push(L, it.buf)
		lua.setfield(L, -2, "buf")
	}
	if it.row > 0 {
		api_pos_push(L, {it.row - 1, max(0, it.col - 1)})
		lua.setfield(L, -2, "pos")
	}
	if it.dir {
		lua.pushboolean(L, true)
		lua.setfield(L, -2, "dir")
	}
	if it.depth > 0 {
		lua.pushinteger(L, lua.Integer(it.depth))
		lua.setfield(L, -2, "depth")
	}
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

api_view_item :: proc(L: ^lua.State, editor: ^Editor, t: c.int) -> (it: PaneItem) {
	it.label, _ = api_field_string(L, t, "label")
	it.detail, _ = api_field_string(L, t, "detail")
	it.path, _ = api_field_string(L, t, "path")
	it.key, _ = api_field_string(L, t, "key")
	#partial switch lua.getfield(L, t, "pos") {
	case .TABLE:
		it.row, _ = api_field_int(L, lua.gettop(L), "row")
		it.col, _ = api_field_int(L, lua.gettop(L), "col")
	case .NIL:
	case:
		plugin_raise(L, "pos must be a table {row, col}")
	}
	lua.pop(L, 1)
	#partial switch lua.getfield(L, t, "buf") {
	case .NUMBER, .TABLE:
		it.buf = api_buffer_id(L, -1)
	case .NIL:
	case:
		plugin_raise(L, "buf must be a buffer")
	}
	lua.pop(L, 1)
	#partial switch lua.getfield(L, t, "cells") {
	case .TABLE:
		ct := lua.gettop(L)
		it.cells = make([]string, int(lua.rawlen(L, ct)), context.temp_allocator)
		for i in 0 ..< len(it.cells) {
			if lua.rawgeti(L, ct, lua.Integer(i + 1)) != .STRING {
				plugin_raise(L, "cells must be a list of strings")
			}
			sv, _ := lua.toodinstring(L, -1)
			it.cells[i] = strings.clone(sv, context.temp_allocator)
			lua.pop(L, 1)
		}
	case .NIL:
	case:
		plugin_raise(L, "cells must be a list of strings")
	}
	lua.pop(L, 1)
	if it.label == "" {
		it.label = it.path
	}
	if it.path != "" {
		it.path = api_path(editor, it.path)
	}
	return
}

api_view_items :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> []PaneItem {
	idx := lua.absindex(L, idx)
	lua.L_checkstack(L, 4, "view items")
	n := int(lua.rawlen(L, idx))
	out := make([]PaneItem, n, context.temp_allocator)
	for i in 1 ..= n {
		#partial switch lua.rawgeti(L, idx, lua.Integer(i)) {
		case .STRING:
			s, _ := lua.toodinstring(L, -1)
			out[i - 1].label = strings.clone(s, context.temp_allocator)
		case .TABLE:
			out[i - 1] = api_view_item(L, editor, lua.gettop(L))
		case:
			plugin_raise(L, fmt.tprintf("items[%d] must be a string or a table", i))
		}
		lua.pop(L, 1)
	}
	return out
}

api_pane_lines :: proc(L: ^lua.State, idx: c.int) -> []PaneLine {
	idx := lua.absindex(L, idx)
	if lua.type(L, idx) != .TABLE {
		plugin_raise(L, "lines must be a table")
	}
	lua.L_checkstack(L, 4, "pane lines")
	n := int(lua.rawlen(L, idx))
	out := make([]PaneLine, n, context.temp_allocator)
	for i in 1 ..= n {
		#partial switch lua.rawgeti(L, idx, lua.Integer(i)) {
		case .STRING:
			s, _ := lua.toodinstring(L, -1)
			out[i - 1].text = strings.clone(s, context.temp_allocator)
		case .TABLE:
			t := lua.gettop(L)
			out[i - 1].text, _ = api_field_string(L, t, "text")
			out[i - 1].color, _ = api_field_string(L, t, "color")
		case:
			plugin_raise(L, fmt.tprintf("lines[%d] must be a string or {{text, color}}", i))
		}
		lua.pop(L, 1)
	}
	return out
}

api_items_order :: proc(items: []PaneItem, sort: bool) -> []int {
	Keyed :: struct {
		key: string,
		idx: int,
	}
	keyed := make([]Keyed, len(items), context.temp_allocator)
	for it, i in items {
		keyed[i] = {pane_item_key(it), i}
	}
	if sort {
		slice.sort_by(keyed, proc(a, b: Keyed) -> bool {return a.key < b.key || (a.key == b.key && a.idx < b.idx)})
	}
	perm := make([]int, len(items), context.temp_allocator)
	for k, i in keyed {
		perm[i] = k.idx
	}
	return perm
}

api_items_copy_order :: proc(L: ^lua.State, src, dst: c.int, perm: []int) {
	for j, i in perm {
		lua.rawgeti(L, src, lua.Integer(j + 1))
		lua.rawseti(L, dst, lua.Integer(i + 1))
	}
}

api_items_ordered :: proc(items: []PaneItem, perm: []int) -> []PaneItem {
	out := make([]PaneItem, len(perm), context.temp_allocator)
	for j, i in perm {
		out[i] = items[j]
	}
	return out
}

qed_ui_open :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "spec table expected")
	}
	lua.settop(L, 1)
	lua.L_checkstack(L, 8, "ui spec")
	pl := api_loaded(L, editor)
	if p.setup != nil {
		plugin_raise(L, "qed.ui.open cannot run during setup")
	}
	spec: Pane
	spec.id, _ = api_field_string(L, 1, "id")
	spec.modal = api_opt_bool(L, 1, "modal")
	spec.title, _ = api_field_string(L, 1, "title")
	spec.scope, _ = api_field_string(L, 1, "scope")
	place, _ := api_field_string(L, 1, "place")
	switch place {
	case "", "center":
		spec.place = .Center
	case "full":
		spec.place = .Full
	case "split":
		spec.place = .Split
	case:
		plugin_raise(L, `place must be "center", "full" or "split"`)
	}
	size, _ := api_field_string(L, 1, "size")
	switch {
	case size == "" && spec.place == .Split, size == "split:code" && spec.place == .Split:
		spec.size = .Code
	case size == "split:tree" && spec.place == .Split:
		spec.size = .Tree
	case size == "" || size == "palette" && spec.place == .Center:
		spec.size = .Palette
	case size == "dialog" && spec.place == .Center:
		spec.size = .Dialog
	case:
		plugin_raise(L, fmt.tprintf("size %q does not fit place %q", size, place))
	}
	kind, _ := api_field_string(L, 1, "kind")
	if kind != "" && kind != "exclusive" && kind != "child" {
		plugin_raise(L, `kind must be "exclusive" or "child"`)
	}
	focus_t := lua.getfield(L, 1, "focus")
	passive := focus_t == .BOOLEAN && !lua.toboolean(L, -1)
	lua.pop(L, 1)
	if focus_t != .NIL && focus_t != .BOOLEAN {
		plugin_raise(L, "focus must be a boolean")
	}
	parent: u64
	#partial switch lua.getfield(L, 1, "parent") {
	case .TABLE:
		id, ok := api_field_int(L, lua.gettop(L), "id")
		if !ok {
			plugin_raise(L, "parent must be a view")
		}
		parent = u64(id)
	case .NIL:
	case:
		plugin_raise(L, "parent must be a view")
	}
	lua.pop(L, 1)

	texts: []string
	given: []bool
	#partial switch lua.getfield(L, 1, "fields") {
	case .TABLE:
		t := lua.gettop(L)
		n := int(lua.rawlen(L, t))
		spec.fields = make([]PaneField, n, context.temp_allocator)
		texts = make([]string, n, context.temp_allocator)
		given = make([]bool, n, context.temp_allocator)
		for i in 0 ..< n {
			if lua.rawgeti(L, t, lua.Integer(i + 1)) != .TABLE {
				plugin_raise(L, fmt.tprintf("fields[%d] must be a table", i + 1))
			}
			ft := lua.gettop(L)
			f := &spec.fields[i]
			f.prompt, _ = api_field_string(L, ft, "prompt")
			texts[i], given[i] = api_field_string(L, ft, "text")
			mode, _ := api_field_string(L, ft, "mode")
			switch mode {
			case "", "filter":
				f.mode = .Filter
			case "query":
				f.mode = .Query
			case "input":
				f.mode = .Input
			case "path":
				f.mode = .Path
			case:
				plugin_raise(L, `mode must be "filter", "query", "input" or "path"`)
			}
			f.count = api_opt_bool(L, ft, "count")
			f.esc_clears = api_opt_bool(L, ft, "esc_clears")
			f.hint, _ = api_field_string(L, ft, "hint")
			lua.pop(L, 1)
		}
	case .NIL:
	case:
		plugin_raise(L, "fields must be a table")
	}
	lua.pop(L, 1)

	items: []PaneItem
	selected := 0
	#partial switch lua.getfield(L, 1, "list") {
	case .TABLE:
		t := lua.gettop(L)
		spec.has_list = true
		#partial switch lua.getfield(L, t, "items") {
		case .TABLE:
			if li := api_list_handle(L, editor, -1); li >= 0 {
				spec.list.source = p.lists[li].src
			} else {
				items = api_view_items(L, editor, -1)
			}
		case .NIL:
		case:
			plugin_raise(L, "items must be a table")
		}
		lua.pop(L, 1)
		spec.list.multi = api_opt_bool(L, t, "multi")
		spec.list.sort = api_opt_bool(L, t, "sort")
		spec.list.tree = api_opt_bool(L, t, "tree")
		if spec.list.tree && spec.list.source.kind != .Walk {
			plugin_raise(L, "list.tree needs a qed.fs.walk handle")
		}
		spec.list.columns = api_columns(L, t)
		spec.list.empty, _ = api_field_string(L, t, "empty")
		if lua.getfield(L, t, "max") != .NIL {
			spec.list.max = max(0, api_int(L, -1, "max must be an integer"))
		}
		lua.pop(L, 1)
		if lua.getfield(L, t, "selected") != .NIL {
			selected = api_int(L, -1, "selected must be an item index")
		}
		lua.pop(L, 1)
	case .NIL:
	case:
		plugin_raise(L, "list must be a table")
	}
	lua.pop(L, 1)

	#partial switch lua.getfield(L, 1, "preview") {
	case .STRING:
		s, _ := lua.toodinstring(L, -1)
		if s != "auto" {
			plugin_raise(L, `preview must be "auto" or false`)
		}
		spec.auto_preview = true
	case .NIL:
	case .BOOLEAN:
		if lua.toboolean(L, -1) {
			plugin_raise(L, `preview must be "auto" or false`)
		}
	case:
		plugin_raise(L, `preview must be "auto" or false`)
	}
	lua.pop(L, 1)

	#partial switch lua.getfield(L, 1, "text") {
	case .TABLE:
		spec.text = api_pane_lines(L, -1)
	case .NIL:
	case:
		plugin_raise(L, "text must be a table")
	}
	lua.pop(L, 1)

	if md, ok := api_field_string(L, 1, "markdown"); ok {
		if spec.place != .Full || spec.has_list || len(spec.text) > 0 {
			plugin_raise(L, `markdown needs place = "full" and no list or text`)
		}
		spec.md, spec.has_md = md, true
		if dir, dir_ok := api_field_string(L, 1, "markdown_dir"); dir_ok {
			spec.md_dir = dir
		}
	}
	if info, ok := api_field_string(L, 1, "info"); ok {
		if spec.place == .Center {
			plugin_raise(L, `info needs place = "full" or "split"`)
		}
		spec.info = info
	}
	backdrop, _ := api_field_string(L, 1, "backdrop")
	switch backdrop {
	case "", "none":
	case "dim":
		spec.backdrop = .Dim
	case "blank":
		spec.backdrop = .Blank
	case:
		plugin_raise(L, `backdrop must be "none", "dim" or "blank"`)
	}
	if lua.getfield(L, 1, "max_width") != .NIL {
		spec.max_width = api_int(L, -1, "max_width must be an integer")
		if spec.max_width < 1 || spec.place == .Split {
			plugin_raise(L, `max_width must be positive, for place "center" or "full"`)
		}
		spec.max_width = max(spec.max_width, PANE_MIN_WIDTH)
	}
	lua.pop(L, 1)

	#partial switch lua.getfield(L, 1, "footer") {
	case .TABLE:
		spec.footer, _ = api_hints(L, lua.gettop(L))
		spec.chips, _ = api_chips(L, lua.gettop(L))
	case .NIL:
	case:
		plugin_raise(L, "footer must be a table {hints?, chips?}")
	}
	lua.pop(L, 1)
	spec.tabs = api_tabs(L, 1)
	if lua.getfield(L, 1, "tab") != .NIL {
		spec.tab = api_int(L, -1, "tab must be a tab index") - 1
		if spec.tab < 0 || spec.tab >= len(spec.tabs) {
			plugin_raise(L, "tab is out of range")
		}
	}
	lua.pop(L, 1)

	on_t := lua.getfield(L, 1, "on")
	if on_t != .NIL && on_t != .TABLE {
		plugin_raise(L, "on must be a table of handlers")
	}
	if on_t == .TABLE {
		for name in view_event_names {
			tp := lua.getfield(L, -1, name)
			lua.pop(L, 1)
			if tp != .NIL && tp != .FUNCTION {
				plugin_raise(L, fmt.tprintf("on.%s must be a function", name))
			}
		}
	}
	lua.pop(L, 1)

	if pane_safety_open(editor) {
		return api_fail(L, "busy")
	}
	switch {
	case passive:
		spec.kind = .Passive
	case parent != 0:
		i := pane_index(editor, parent)
		if i < 0 || !pane_live(editor, &editor.panes[i]) {
			return api_fail(L, "closed")
		}
		spec.kind, spec.parent = .Child, parent
	case kind == "child":
		// only a user's command, or an activate over its own view, may stack over a pane or overlay it does not own
		t := plugin_task_of(p, L)
		user := t != nil && t.user
		if f := pane_focus(editor); f != nil {
			from_view := t != nil && t.view != 0 && (f.handle == t.view || pane_descends(editor, f, t.view))
			if !user && !from_view && f.owner != pl.name {
				return api_fail(L, "busy")
			}
			spec.kind, spec.parent = .Child, f.handle
		} else if ov := editor_overlay_active(editor); ov != nil {
			if !user {
				return api_fail(L, "busy")
			}
			spec.kind, spec.over = .Child, ov
		}
	}
	keep := len(items)
	if spec.list.max > 0 && keep > spec.list.max {
		keep = spec.list.max
		spec.list.more = true
	}
	perm := api_items_order(items[:keep], spec.list.sort)
	spec.list.items = make([dynamic]PaneItem, 0, keep, context.temp_allocator)
	append(&spec.list.items, ..api_items_ordered(items, perm))
	spec.owner = plugin_name_intern(p, pl.name)
	spec.ctx.lua = true
	spec.on = {activate = plugin_view_activate, close = plugin_view_closed, link = plugin_view_link, tab = plugin_view_tab, submit = plugin_view_submit, expand = plugin_view_expand}
	if t := plugin_task_of(p, L); t != nil {
		spec.toggle = t.command
	}
	if lua.getfield(L, 1, "toggle") == .BOOLEAN {
		if lua.toboolean(L, -1) {
			plugin_raise(L, "toggle must be a command name or false")
		}
		spec.toggle = 0
	} else if toggle, ok := api_field_string(L, 1, "toggle"); ok {
		spec.toggle = 0
		for cmd in p.commands {
			if cmd.name == toggle {
				spec.toggle = cmd.id
			}
		}
		if spec.toggle == 0 {
			plugin_raise(L, fmt.tprintf("toggle: no command %q", toggle))
		}
	}
	lua.pop(L, 1)
	spec.jump_closes = api_opt_bool(L, 1, "jump_closes")
	pn := pane_open(editor, spec)
	if pn == nil {
		return api_fail(L, "busy")
	}
	handle := pn.handle
	saved := pane_saved_find(editor, spec.id) if spec.id != "" else nil
	restored := saved != nil
	for &f, i in pn.fields {
		text := texts[i]
		if given[i] {
			restored = restored && text == ""
		}
		textfield_set(&f.field, text)
		if f.mode != .Input && f.mode != .Path {
			textfield_select_all(&f.field)
		}
	}
	if saved != nil {
		pn.scroll = saved.scroll
		if pn.list.tree {
			for key, on in saved.expanded {
				pane_tree_set(pn, key, on)
			}
		}
	}
	pane_list_load(editor, pn)
	rows := pane_geom(editor, pn).list.h
	if selected > 0 {
		pane_select(editor, pn, selected - 1, rows)
		pn.list.moved = true
	} else if restored && saved.key != "" && list_restores(pn.list.source.kind) {
		pn.list.restore = strings.clone(saved.key)
		pane_restore(editor, pn, rows)
	}
	if pane_count(editor, pn) > 0 {
		plugin_view_moved(editor, pn)
	}
	if pane_query(pn) != nil {
		pn.query_due = true
		pn.query_at = time.tick_now()
	}

	api_handle_push(L, handle, qed_view_methods[:])
	lua.pushvalue(L, -1)
	v := UiView {
		handle   = handle,
		owner    = spec.owner,
		view_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX)),
	}
	lua.createtable(L, c.int(keep), 0)
	if lua.getfield(L, 1, "list") == .TABLE && lua.getfield(L, -1, "items") == .TABLE && spec.list.source.kind == .None {
		api_items_copy_order(L, lua.gettop(L), lua.gettop(L) - 2, perm)
	}
	lua.settop(L, 3)
	v.items_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	if lua.getfield(L, 1, "on") == .TABLE {
		for name, ev in view_event_names {
			if lua.getfield(L, 3, name) == .FUNCTION {
				v.on[ev] = i32(lua.L_ref(L, lua.REGISTRYINDEX))
			} else {
				lua.pop(L, 1)
			}
		}
	}
	lua.settop(L, 2)
	append(&p.views, v)
	// a timer or event opening a pane must not wipe a message the user has not read
	if t := plugin_task_of(p, L); t == nil || t.user {
		editor_clear_message(editor)
	}
	if i := pane_index(editor, handle); i >= 0 {
		pane_preview_sync(editor, &editor.panes[i])
	}
	return 1
}

api_view_live :: proc(L: ^lua.State, editor: ^Editor) -> (pn: ^Pane, vi: int) {
	handle := api_handle_id(L)
	vi = plugin_view_index(&editor.plugins, handle)
	pi := pane_index(editor, handle)
	if vi < 0 || pi < 0 {
		return nil, -1
	}
	return &editor.panes[pi], vi
}

qed_view_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "items table expected")
	}
	#partial switch lua.type(L, 3) {
	case .NIL, .NONE, .TABLE:
	case:
		lua.L_argerror(L, 3, "options table expected")
	}
	lua.settop(L, 3)
	if li := api_list_handle(L, editor, 2); li >= 0 {
		return api_view_set_handle(L, editor, li)
	}
	items := api_view_items(L, editor, 2)
	selected := 0
	more := false
	hint := ""
	columns: Maybe([]PaneColumn)
	if lua.type(L, 3) == .TABLE {
		if lua.getfield(L, 3, "selected") != .NIL {
			selected = api_int(L, -1, "selected must be an item index")
		}
		lua.pop(L, 1)
		more = api_opt_bool(L, 3, "more")
		hint, _ = api_field_string(L, 3, "hint")
		if lua.getfield(L, 3, "columns") != .NIL {
			columns = api_columns(L, 3)
		}
		lua.pop(L, 1)
	}
	pn, vi := api_view_live(L, editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	handle := pn.handle
	keep := len(items)
	if pn.list.max > 0 && keep > pn.list.max {
		keep = pn.list.max
		more = true
	}
	perm := api_items_order(items[:keep], pn.list.sort)
	lua.createtable(L, c.int(keep), 0)
	api_items_copy_order(L, 2, 4, perm)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	vi = plugin_view_index(p, handle)
	lua.L_unref(L, lua.REGISTRYINDEX, c.int(p.views[vi].items_ref))
	p.views[vi].items_ref = ref
	pn = &editor.panes[pane_index(editor, handle)]
	list_source_free(&pn.list.source)
	pane_items_clear(pn)
	pane_items_add(pn, api_items_ordered(items, perm))
	if cols, ok := columns.?; ok {
		pane_columns_set(pn, cols)
	}
	pn.list.more, pn.list.fit_n = more, 0
	pn.landed = true
	delete(pn.list.hint)
	pn.list.hint = strings.clone(hint)
	pane_refilter(editor, pn)
	rows := pane_geom(editor, pn).list.h
	pn.list.sel, pn.list.scroll, pn.list.anchor = 0, 0, nil
	if selected > 0 {
		delete(pn.list.restore)
		pn.list.restore = ""
		pn.list.sel = clamp(selected - 1, 0, max(0, pane_count(editor, pn) - 1))
		pn.list.moved = true
		pn.list.scroll = max(0, pn.list.sel - rows / 2)
		pane_scroll_fit(pn, rows)
	} else {
		pane_restore(editor, pn, rows)
	}
	pn.notified = -1
	pane_preview_sync(editor, pn)
	lua.pushboolean(L, true)
	return 1
}

api_view_set_handle :: proc(L: ^lua.State, editor: ^Editor, li: int) -> c.int {
	p := &editor.plugins
	src := p.lists[li].src
	selected, hint := "", ""
	if lua.type(L, 3) == .TABLE {
		if k, ok := api_field_string(L, 3, "selected"); ok {
			selected = api_path(editor, k) if src.kind == .Walk else k
		}
		hint, _ = api_field_string(L, 3, "hint")
	}
	pn, vi := api_view_live(L, editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if pn.list.tree && src.kind != .Walk {
		plugin_raise(L, "a tree list needs a qed.fs.walk handle")
	}
	keep := strings.clone(pane_selected_key(editor, pn), context.temp_allocator)
	lua.createtable(L, 0, 0)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	lua.L_unref(L, lua.REGISTRYINDEX, c.int(p.views[vi].items_ref))
	p.views[vi].items_ref = ref
	list_source_free(&pn.list.source)
	pane_items_clear(pn)
	pn.list.source = list_source_clone(src)
	pn.list.more, pn.landed, pn.list.fit_n = false, true, 0
	delete(pn.list.hint)
	pn.list.hint = strings.clone(hint)
	pane_list_load(editor, pn)
	if selected != "" {
		keep = selected
	}
	if keep != "" && list_restores(src.kind) {
		delete(pn.list.restore)
		pn.list.restore = strings.clone(keep)
		pane_restore(editor, pn, pane_geom(editor, pn).list.h)
		delete(pn.list.restore)
		pn.list.restore = ""
	}
	pane_preview_sync(editor, pn)
	lua.pushboolean(L, true)
	return 1
}

api_hints :: proc(L: ^lua.State, t: c.int) -> ([]PaneHint, bool) {
	tp := lua.getfield(L, t, "hints")
	defer lua.pop(L, 1)
	if tp == .NIL {
		return nil, false
	}
	if tp != .TABLE {
		plugin_raise(L, "hints must be a list of {label, cmd?}")
	}
	h := lua.gettop(L)
	out := make([]PaneHint, int(lua.rawlen(L, h)), context.temp_allocator)
	for i in 0 ..< len(out) {
		if lua.rawgeti(L, h, lua.Integer(i + 1)) != .TABLE {
			plugin_raise(L, fmt.tprintf("hints[%d] must be a table {{label, cmd?}}", i + 1))
		}
		out[i].label, _ = api_field_string(L, lua.gettop(L), "label")
		out[i].cmd, _ = api_field_string(L, lua.gettop(L), "cmd")
		lua.pop(L, 1)
	}
	return out, true
}

api_chips :: proc(L: ^lua.State, t: c.int) -> ([]PaneChip, bool) {
	tp := lua.getfield(L, t, "chips")
	defer lua.pop(L, 1)
	if tp == .NIL {
		return nil, false
	}
	if tp != .TABLE {
		plugin_raise(L, "chips must be a list of {label, cmd, on?}")
	}
	h := lua.gettop(L)
	out := make([]PaneChip, int(lua.rawlen(L, h)), context.temp_allocator)
	for i in 0 ..< len(out) {
		if lua.rawgeti(L, h, lua.Integer(i + 1)) != .TABLE {
			plugin_raise(L, fmt.tprintf("chips[%d] must be a table {{label, cmd, on?}}", i + 1))
		}
		ct := lua.gettop(L)
		out[i].label, _ = api_field_string(L, ct, "label")
		out[i].cmd, _ = api_field_string(L, ct, "cmd")
		out[i].on = api_opt_bool(L, ct, "on")
		lua.pop(L, 1)
	}
	return out, true
}

api_tabs :: proc(L: ^lua.State, t: c.int) -> []PaneTab {
	tp := lua.getfield(L, t, "tabs")
	defer lua.pop(L, 1)
	if tp == .NIL {
		return nil
	}
	return api_tab_list(L, lua.gettop(L))
}

api_tab_list :: proc(L: ^lua.State, h: c.int) -> []PaneTab {
	if lua.type(L, h) != .TABLE {
		plugin_raise(L, "tabs must be a list of labels or {label, cmd?}")
	}
	out := make([]PaneTab, int(lua.rawlen(L, h)), context.temp_allocator)
	for i in 0 ..< len(out) {
		#partial switch lua.rawgeti(L, h, lua.Integer(i + 1)) {
		case .STRING:
			sv, _ := lua.toodinstring(L, -1)
			out[i].label = strings.clone(sv, context.temp_allocator)
		case .TABLE:
			out[i].label, _ = api_field_string(L, lua.gettop(L), "label")
			out[i].cmd, _ = api_field_string(L, lua.gettop(L), "cmd")
		case:
			plugin_raise(L, fmt.tprintf("tabs[%d] must be a label or {{label, cmd?}}", i + 1))
		}
		lua.pop(L, 1)
	}
	return out
}

api_columns :: proc(L: ^lua.State, t: c.int) -> []PaneColumn {
	tp := lua.getfield(L, t, "columns")
	defer lua.pop(L, 1)
	if tp == .NIL {
		return nil
	}
	if tp != .TABLE {
		plugin_raise(L, "columns must be a list of {title?, width?, min?, max?, right?}")
	}
	h := lua.gettop(L)
	out := make([]PaneColumn, int(lua.rawlen(L, h)), context.temp_allocator)
	for &col, i in out {
		if lua.rawgeti(L, h, lua.Integer(i + 1)) != .TABLE {
			plugin_raise(L, fmt.tprintf("columns[%d] must be a table {{title?, width?, min?, max?, right?}}", i + 1))
		}
		ct := lua.gettop(L)
		#partial switch lua.getfield(L, ct, "width") {
		case .NIL:
		case .NUMBER:
			n, ok := api_field_int(L, ct, "width")
			if !ok || n < 1 {
				plugin_raise(L, fmt.tprintf(`columns[%d].width must be a positive integer, "fit" or "fill"`, i + 1))
			}
			col.size, col.w = .Fixed, n
		case .STRING:
			switch s, _ := lua.toodinstring(L, -1); s {
			case "fit":
				col.size = .Fit
			case "fill":
			case:
				plugin_raise(L, fmt.tprintf(`columns[%d].width must be a positive integer, "fit" or "fill"`, i + 1))
			}
		case:
			plugin_raise(L, fmt.tprintf(`columns[%d].width must be a positive integer, "fit" or "fill"`, i + 1))
		}
		lua.pop(L, 1)
		if lua.getfield(L, ct, "min") != .NIL {
			n, ok := api_field_int(L, ct, "min")
			if !ok || n < 0 {
				plugin_raise(L, fmt.tprintf("columns[%d].min must be a non-negative integer", i + 1))
			}
			if col.size == .Fixed {
				plugin_raise(L, fmt.tprintf(`columns[%d].min needs width = "fit" or "fill"`, i + 1))
			}
			col.min = n
		}
		lua.pop(L, 1)
		if lua.getfield(L, ct, "max") != .NIL {
			n, ok := api_field_int(L, ct, "max")
			if !ok || n < 1 {
				plugin_raise(L, fmt.tprintf("columns[%d].max must be a positive integer", i + 1))
			}
			if col.size != .Fit {
				plugin_raise(L, fmt.tprintf(`columns[%d].max needs width = "fit"`, i + 1))
			}
			col.max = n
		}
		lua.pop(L, 1)
		if col.max > 0 && col.min > col.max {
			plugin_raise(L, fmt.tprintf("columns[%d].min is above its max", i + 1))
		}
		#partial switch lua.getfield(L, ct, "title") {
		case .NIL:
		case .STRING:
			title, _ := lua.toodinstring(L, -1)
			col.title = strings.clone(title, context.temp_allocator)
		case:
			plugin_raise(L, fmt.tprintf("columns[%d].title must be a string", i + 1))
		}
		lua.pop(L, 1)
		if tp := lua.getfield(L, ct, "right"); tp != .NIL && tp != .BOOLEAN {
			plugin_raise(L, fmt.tprintf("columns[%d].right must be a boolean", i + 1))
		}
		col.right = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		lua.pop(L, 1)
	}
	return out
}

qed_view_marks :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "marks table expected")
	}
	#partial switch lua.type(L, 3) {
	case .NIL, .NONE, .TABLE:
	case:
		lua.L_argerror(L, 3, "options table expected")
	}
	lua.settop(L, 3)
	replace := lua.type(L, 3) == .TABLE && api_opt_bool(L, 3, "replace")
	detail: Maybe(bool)
	if lua.type(L, 3) == .TABLE && lua.getfield(L, 3, "detail") != .NIL {
		detail = bool(lua.toboolean(L, -1))
	}
	total := 0
	if lua.type(L, 3) == .TABLE {
		lua.settop(L, 3)
		total, _ = api_field_int(L, 3, "total")
	}
	pn, _ := api_view_live(L, editor)
	walk := pn != nil && pn.list.source.kind == .Walk
	Parsed :: struct {
		key:  string,
		mark: PaneMark,
		drop: bool,
	}
	marks := make([dynamic]Parsed, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, 2) != 0 {
		if lua.type(L, -2) != .STRING {
			plugin_raise(L, "marks: keys must be strings")
		}
		ks, _ := lua.toodinstring(L, -2)
		key := api_path(editor, ks) if walk else strings.clone(ks, context.temp_allocator)
		#partial switch lua.type(L, -1) {
		case .BOOLEAN:
			if lua.toboolean(L, -1) {
				plugin_raise(L, fmt.tprintf("marks[%q] must be a table or false", ks))
			}
			append(&marks, Parsed{key = key, drop = true})
		case .TABLE:
			v := lua.gettop(L)
			m: PaneMark
			m.bar, _ = api_field_string(L, v, "bar")
			m.fg, _ = api_field_string(L, v, "fg")
			m.suffix, _ = api_field_string(L, v, "suffix")
			for c in ([2]^string{&m.bar, &m.fg}) {
				if c^ != "" {
					api_theme_color(L, c^)
					id := plugin_color_id(&editor.plugins, c^)
					c^ = editor.plugins.colors[id - 1]
				}
			}
			added, aok := api_field_int(L, v, "added")
			removed, rok := api_field_int(L, v, "removed")
			if added < 0 || removed < 0 {
				plugin_raise(L, fmt.tprintf("marks[%q]: added and removed must not be negative", ks))
			}
			m.added, m.removed, m.sizes = added, removed, aok || rok
			m.dim = api_opt_bool(L, v, "dim")
			append(&marks, Parsed{key = key, mark = m})
		case:
			plugin_raise(L, fmt.tprintf("marks[%q] must be a table or false", ks))
		}
		lua.pop(L, 1)
	}
	if pn == nil {
		return api_fail(L, "closed")
	}
	if d, ok := detail.?; ok {
		pn.marks_plain = !d
	}
	if replace {
		pane_marks_clear(pn)
		// a map rehash at 50k marks is the slowest step of a push; size it once
		reserve(&pn.marks, total)
	}
	for m in marks {
		if m.drop {
			pane_mark_drop(pn, m.key)
		} else {
			pane_mark_set(pn, m.key, m.mark)
		}
	}
	lua.pushboolean(L, true)
	return 1
}

qed_view_footer :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "footer table expected")
	}
	lua.settop(L, 2)
	hints, has_hints := api_hints(L, 2)
	chips, has_chips := api_chips(L, 2)
	input := 0
	prompt, text: string
	mode := PaneFieldMode.Input
	#partial switch lua.getfield(L, 2, "input") {
	case .TABLE:
		input = 1
		prompt, _ = api_field_string(L, 3, "prompt")
		text, _ = api_field_string(L, 3, "text")
		switch m, _ := api_field_string(L, 3, "mode"); m {
		case "", "input":
		case "chord":
			mode = .Chord
		case:
			plugin_raise(L, `input mode must be "input" or "chord"`)
		}
	case .BOOLEAN:
		if lua.toboolean(L, -1) {
			plugin_raise(L, "input must be a table {prompt?, text?, mode?} or false")
		}
		input = -1
	case .NIL:
	case:
		plugin_raise(L, "input must be a table {prompt?, text?, mode?} or false")
	}
	lua.pop(L, 1)
	pn, _ := api_view_live(L, editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if has_hints {
		for h in pn.footer {
			delete(h.label)
			delete(h.cmd)
		}
		delete(pn.footer)
		pn.footer = make([]PaneHint, len(hints))
		for h, i in hints {
			pn.footer[i] = {strings.clone(h.label), strings.clone(h.cmd)}
		}
	}
	if has_chips {
		pane_chips_set(pn, chips)
	}
	switch input {
	case 1:
		pane_footer_input(pn, prompt, "" if mode == .Chord else text, mode)
	case -1:
		pn.footer_input = false
	}
	lua.pushboolean(L, true)
	return 1
}

qed_view_tab :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	set := lua.type(L, 2) > .NIL
	i := api_int(L, 2, "tab index expected") - 1 if set else 0
	tabs := api_tab_list(L, 3) if lua.type(L, 3) > .NIL else nil
	pn, _ := api_view_live(L, entry.editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	count := len(tabs) if lua.type(L, 3) > .NIL else len(pn.tabs)
	if set && (i < 0 || i >= count) {
		plugin_raise(L, "tab is out of range")
	}
	if lua.type(L, 3) > .NIL {
		pane_tabs_set(pn, tabs)
	}
	if set {
		pn.tab = i
	}
	lua.pushinteger(L, lua.Integer(pn.tab + 1))
	return 1
}

qed_view_preview :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	mode := lua.type(L, 2)
	path, base: string
	has_base, diff_only := false, true
	#partial switch mode {
	case .BOOLEAN:
		if lua.toboolean(L, 2) {
			plugin_raise(L, `preview must be false, "auto" or {path, base?, diff_only?}`)
		}
	case .STRING:
		if s, _ := lua.toodinstring(L, 2); s != "auto" {
			plugin_raise(L, `preview must be false, "auto" or {path, base?, diff_only?}`)
		}
	case .TABLE:
		ps, ok := api_field_string(L, 2, "path")
		if !ok {
			plugin_raise(L, "preview: path expected")
		}
		path = api_path(editor, ps)
		base, has_base = api_field_string(L, 2, "base")
		if lua.getfield(L, 2, "diff_only") != .NIL {
			diff_only = bool(lua.toboolean(L, -1))
		}
		lua.pop(L, 1)
	case:
		lua.L_argerror(L, 2, `false, "auto" or a table expected`)
	}
	pn, _ := api_view_live(L, editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	g := pane_geom(editor, pn)
	#partial switch mode {
	case .BOOLEAN:
		pn.preview_off, pn.preview_due = true, false
		preview_reset(&pn.preview)
	case .STRING:
		pn.preview_off = false
		delete(pn.preview_key)
		pn.preview_key = ""
		pane_preview_sync(editor, pn)
	case .TABLE:
		if !g.has_preview {
			break
		}
		if has_base {
			preview_set_diff(&pn.preview, path, g.preview.h, diff_only, base)
		} else {
			preview_set_file(&pn.preview, path, 0, g.preview.h)
		}
	}
	lua.pushboolean(L, true)
	return 1
}

qed_view_expand :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	toggle := lua.type(L, 2) <= .NIL
	all := toggle || lua.type(L, 2) == .BOOLEAN
	path := ""
	on := bool(lua.toboolean(L, 2))
	if !all {
		path = api_path(editor, api_string(L, 2))
		on = lua.type(L, 3) <= .NIL || bool(lua.toboolean(L, 3))
	}
	pn, _ := api_view_live(L, editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if !pn.list.tree {
		plugin_raise(L, "expand needs a list.tree view")
	}
	ok := true
	if toggle {
		on = !pane_tree_any_expanded(pn)
	}
	if all {
		ok = pane_tree_expand_all(editor, pn, on)
	} else {
		pane_tree_set(pn, path, on)
		list_walk_fill(editor, pn)
	}
	if !ok {
		return api_fail(L, "loading")
	}
	lua.pushboolean(L, true)
	return 1
}

qed_view_reveal :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	path := api_path(editor, api_string(L, 2))
	pn, _ := api_view_live(L, editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if !pn.list.tree {
		plugin_raise(L, "reveal needs a list.tree view")
	}
	if f := pane_filter(pn); f != nil {
		textfield_reset(&f.field)
	}
	if !pane_tree_reveal(editor, pn, path) {
		return api_fail(L, "not listed")
	}
	lua.pushboolean(L, true)
	return 1
}

qed_view_selection :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	pn, _ := api_view_live(L, editor)
	if pn == nil || !pn.has_list {
		return 0
	}
	n := pane_count(editor, pn)
	if n == 0 {
		lua.pushnil(L)
		lua.pushnil(L)
		lua.pushnil(L)
	} else {
		api_pane_item_push(L, list_item(editor, pn, pane_item_index(pn, pn.list.sel)))
		lua.pushinteger(L, lua.Integer(pn.list.sel + 1))
		if a, ok := pn.list.anchor.?; ok {
			lua.pushinteger(L, lua.Integer(a + 1))
		} else {
			lua.pushnil(L)
		}
	}
	lua.pushinteger(L, lua.Integer(n))
	return 4
}

qed_view_select :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	row := api_int(L, 2, "row must be an integer")
	anchor, ranged := 0, lua.type(L, 3) > .NIL
	if ranged {
		anchor = api_int(L, 3, "anchor must be an integer")
	}
	pn, _ := api_view_live(L, editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if !pn.has_list {
		plugin_raise(L, "select needs a view with a list")
	}
	if n := pane_count(editor, pn); n > 0 {
		pn.list.sel = clamp(row - 1, 0, n - 1)
		pn.list.anchor = nil
		if ranged && pn.list.multi {
			pn.list.anchor = clamp(anchor - 1, 0, n - 1)
		}
		pn.list.moved = true
		delete(pn.list.restore)
		pn.list.restore = ""
		pane_scroll_fit(pn, pane_geom(editor, pn).list.h)
	}
	lua.pushboolean(L, true)
	return 1
}

qed_view_on :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	name := api_string(L, 2)
	ev: Maybe(ViewEvent)
	for n, e in view_event_names {
		if string(n) == name {
			ev = e
		}
	}
	e, ok := ev.?
	if !ok {
		lua.L_argerror(L, 2, "view event name expected")
	}
	tp := lua.type(L, 3)
	if tp != .FUNCTION && !(tp == .BOOLEAN && !lua.toboolean(L, 3)) && tp > .NIL {
		lua.L_argerror(L, 3, "function or false expected")
	}
	_, vi := api_view_live(L, entry.editor)
	if vi < 0 {
		return api_fail(L, "closed")
	}
	if old := p.views[vi].on[e]; old != 0 {
		lua.L_unref(L, lua.REGISTRYINDEX, c.int(old))
		p.views[vi].on[e] = 0
	}
	if tp == .FUNCTION {
		lua.pushvalue(L, 3)
		p.views[vi].on[e] = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	}
	lua.pushboolean(L, true)
	return 1
}

qed_view_append :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "items table expected")
	}
	lua.settop(L, 2)
	pn, vi := api_view_live(L, editor)
	api_view_handle_check(L, pn)
	items := api_view_items(L, editor, 2)
	if pn == nil {
		return api_fail(L, "closed")
	}
	n := len(pn.list.items)
	room := len(items)
	if pn.list.max > 0 && n + room > pn.list.max {
		room = max(0, pn.list.max - n)
		pn.list.more = true
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(editor.plugins.views[vi].items_ref))
	rows := pane_geom(editor, pn).list.h
	sel, anchor := pane_marks(editor, pn)
	filtered := pane_filter(pn) != nil
	for it, k in items[:room] {
		pos := len(pn.list.items)
		if pn.list.sort {
			key := pane_item_key(it)
			lo, hi := 0, pos
			for lo < hi {
				mid := (lo + hi) / 2
				if pane_item_key(pn.list.items[mid]) <= key {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			pos = lo
		}
		for j := len(pn.list.items); j > pos; j -= 1 {
			lua.rawgeti(L, 3, lua.Integer(j))
			lua.rawseti(L, 3, lua.Integer(j + 1))
		}
		lua.rawgeti(L, 2, lua.Integer(k + 1))
		lua.rawseti(L, 3, lua.Integer(pos + 1))
		inject_at(&pn.list.items, pos, pane_item_clone(it))
		if pos < pn.list.fit_n {
			pane_columns_seen(pn, pn.list.columns, it, pn.list.fit_cap)
			pn.list.fit_n = min(pn.list.fit_n + 1, COLUMN_FIT_SAMPLE)
		}
		if !filtered && pn.list.moved && pos < pn.list.scroll {
			pn.list.scroll += 1
		}
		sel += 1 if sel >= 0 && pos <= sel else 0
		anchor += 1 if anchor >= 0 && pos <= anchor else 0
	}
	lua.settop(L, 2)
	pn.landed = true
	if filtered {
		pane_refilter_keep(editor, pn, rows, sel, anchor)
	} else if pn.list.moved {
		pn.list.sel = max(0, sel)
		if anchor >= 0 {
			pn.list.anchor = anchor
		}
		pane_scroll_fit(pn, rows)
	}
	pane_restore(editor, pn, rows)
	pane_preview_sync(editor, pn)
	lua.pushboolean(L, true)
	return 1
}

qed_view_update :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	key := strings.clone(api_string(L, 2), context.temp_allocator)
	if lua.type(L, 3) != .TABLE {
		lua.L_argerror(L, 3, "fields table expected")
	}
	lua.settop(L, 3)
	pn, vi := api_view_live(L, editor)
	api_view_handle_check(L, pn)
	api_view_item(L, editor, 3)
	idx := -1
	if pn != nil {
		for it, i in pn.list.items {
			if pane_item_key(it) == key {
				idx = i
				break
			}
		}
	}
	if pn == nil {
		return api_fail(L, "closed")
	}
	if idx < 0 {
		return api_fail(L, "not found")
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(editor.plugins.views[vi].items_ref))
	if lua.rawgeti(L, 4, lua.Integer(idx + 1)) != .TABLE {
		s, _ := lua.toodinstring(L, -1)
		label := strings.clone(s, context.temp_allocator)
		lua.pop(L, 1)
		lua.createtable(L, 0, 2)
		lua.pushodinstring(L, label)
		lua.setfield(L, -2, "label")
	}
	lua.pushnil(L)
	for lua.next(L, 3) != 0 {
		lua.pushvalue(L, -2)
		lua.insert(L, -2)
		lua.rawset(L, 5)
	}
	it := api_view_item(L, editor, 5)
	lua.rawseti(L, 4, lua.Integer(idx + 1))
	lua.settop(L, 3)
	sel, anchor := pane_marks(editor, pn)
	pane_item_free(pn.list.items[idx])
	pn.list.items[idx] = pane_item_clone(it)
	if pane_filter(pn) != nil {
		pane_refilter_keep(editor, pn, pane_geom(editor, pn).list.h, sel, anchor)
	}
	pane_preview_sync(editor, pn)
	lua.pushboolean(L, true)
	return 1
}

qed_view_info :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	text := api_string(L, 2)
	pn, _ := api_view_live(L, entry.editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if pn.place == .Center {
		plugin_raise(L, `info needs place = "full" or "split"`)
	}
	delete(pn.info)
	pn.info = strings.clone(text)
	lua.pushboolean(L, true)
	return 1
}

qed_view_text :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lines := api_pane_lines(L, 2)
	pn, _ := api_view_live(L, entry.editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	pane_lines_free(pn.text)
	pn.text = pane_lines_clone(lines)
	lua.pushboolean(L, true)
	return 1
}

qed_view_markdown :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	src := api_string(L, 2)
	pn, _ := api_view_live(L, entry.editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if !pn.has_md {
		plugin_raise(L, "view has no markdown body")
	}
	pane_md_reset(pn)
	delete(pn.md)
	pn.md = strings.clone(src)
	lua.pushboolean(L, true)
	return 1
}

// a call that reads the layout waits out a render still in progress, stepping it from its own slices too
api_md_wait :: proc(L: ^lua.State, editor: ^Editor) -> bool {
	pn, _ := api_view_live(L, editor)
	if pn == nil || !pn.has_md {
		return false
	}
	pane_md_lines(pn, pane_geom(editor, pn).text.w)
	if pn.md_job == nil {
		return false
	}
	p := &editor.plugins
	if t := plugin_task_of(p, L); t != nil && p.current == L && p.edit_depth == 0 && lua.isyieldable(L) {
		if pane_md_step(pn, md_slice_ms) {
			return false
		}
		t.wait = {kind = .Sleep, until = time.tick_now()}
		return true
	}
	pane_md_step(pn, -1)
	return false
}

qed_view_md_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_view_md_k)
	}
	switch ctx {
	case 0:
		return qed_view_anchor(L)
	case 1:
		return qed_view_scroll(L)
	case 2:
		return qed_view_source_line(L)
	}
	return qed_view_source_scroll(L)
}

qed_view_anchor :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	if api_md_wait(L, entry.editor) {
		return lua.yieldk(L, 0, 0, qed_view_md_k)
	}
	slug := strings.clone(api_string(L, 2), context.temp_allocator)
	pn, _ := api_view_live(L, entry.editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if !pn.has_md {
		plugin_raise(L, "view has no markdown body")
	}
	pane_md_lines(pn, pane_geom(entry.editor, pn).text.w)
	for line, i in pn.md_lines {
		if line.slug != "" && line.slug == slug {
			pn.scroll = i
			lua.pushinteger(L, lua.Integer(line.src + 1))
			return 1
		}
	}
	return api_fail(L, "not found")
}

qed_view_scroll :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	if api_md_wait(L, entry.editor) {
		return lua.yieldk(L, 0, 1, qed_view_md_k)
	}
	set := lua.type(L, 2) > .NIL
	row := api_int(L, 2, "row must be an integer") if set else 0
	pn, _ := api_view_live(L, entry.editor)
	if pn == nil {
		if v := api_view_closed(L, entry.editor); v != nil && !set {
			lua.pushinteger(L, lua.Integer(v.md_scroll + 1))
			return 1
		}
		return api_fail(L, "closed")
	}
	if set {
		pn.scroll = row - 1
	}
	g := pane_geom(entry.editor, pn)
	pn.scroll = clamp(pn.scroll, 0, max(0, pane_body_rows(pn, g) - g.text.h))
	lua.pushinteger(L, lua.Integer(pn.scroll + 1))
	return 1
}

api_view_closed :: proc(L: ^lua.State, editor: ^Editor) -> ^UiView {
	vi := plugin_view_index(&editor.plugins, api_handle_id(L))
	if vi < 0 || !editor.plugins.views[vi].md_closed {
		return nil
	}
	return &editor.plugins.views[vi]
}

qed_view_source_line :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	if api_md_wait(L, entry.editor) {
		return lua.yieldk(L, 0, 2, qed_view_md_k)
	}
	src: []int
	top := 0
	if pn, _ := api_view_live(L, entry.editor); pn != nil {
		if !pn.has_md {
			plugin_raise(L, "view has no markdown body")
		}
		_, src = pane_md_visible(entry.editor, pn)
		top = pane_geom(entry.editor, pn).text.y
	} else if v := api_view_closed(L, entry.editor); v != nil {
		src, top = v.md_src, v.md_top
	}
	if len(src) == 0 {
		lua.pushnil(L)
		return 1
	}
	at := api_int(L, 2, "row must be an integer") - 1 - top if lua.type(L, 2) > .NIL else 0
	at = clamp(at, 0, len(src) - 1)
	lua.pushinteger(L, lua.Integer(src[at] + 1))
	lua.pushinteger(L, lua.Integer(top + at + 1))
	return 2
}

qed_view_source_scroll :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	if api_md_wait(L, entry.editor) {
		return lua.yieldk(L, 0, 3, qed_view_md_k)
	}
	src := api_int(L, 2, "row must be an integer")
	set_at := lua.type(L, 3) > .NIL
	at := api_int(L, 3, "row must be an integer") if set_at else 0
	pn, _ := api_view_live(L, entry.editor)
	if pn == nil {
		return api_fail(L, "closed")
	}
	if !pn.has_md {
		plugin_raise(L, "view has no markdown body")
	}
	g := pane_geom(entry.editor, pn)
	lines := pane_md_lines(pn, g.text.w)
	at = clamp(at - 1 - g.text.y if set_at else 0, 0, max(0, g.text.h - 1))
	pn.scroll = clamp(md_line_of_src(lines, src - 1) - at, 0, max(0, len(lines) - g.text.h))
	lua.pushinteger(L, lua.Integer(pn.scroll + 1))
	return 1
}

qed_view_close :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	pane_end(entry.editor, api_handle_id(L), false)
	return 0
}

qed_view_wait :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	handle := api_handle_id(L)
	if plugin_view_index(p, handle) < 0 {
		lua.pushnil(L)
		return 1
	}
	t := api_await(L, p, "view:wait")
	t.wait = {kind = .Pane, id = handle}
	return lua.yieldk(L, 0, lua.KContext(handle), qed_view_wait_k)
}

qed_view_wait_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_view_wait_k)
	}
	context = entry.ctx
	a := entry.editor.plugins.answer
	lua.L_checkstack(L, 5, "view result")
	if a.handle != u64(ctx) {
		lua.pushnil(L)
		return 1
	}
	if a.ok && len(a.items) > 0 {
		lua.createtable(L, c.int(len(a.items)), 0)
		for it, i in a.items {
			api_pane_item_push(L, it)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		lua.pushinteger(L, lua.Integer(a.sel[0] + 1))
	} else if a.ok {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(a.items_ref))
		lua.createtable(L, c.int(len(a.sel)), 0)
		for idx, i in a.sel {
			lua.rawgeti(L, -2, lua.Integer(idx + 1))
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		lua.remove(L, -2)
		if len(a.sel) > 0 {
			lua.pushinteger(L, lua.Integer(a.sel[0] + 1))
		} else {
			lua.pushnil(L)
		}
	} else {
		lua.pushnil(L)
		lua.pushnil(L)
	}
	if a.has_text {
		lua.pushodinstring(L, a.text)
	} else {
		lua.pushnil(L)
	}
	return 3
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
	chunks:                      [dynamic]PaneLine,
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
	chunks: []PaneLine
	lua.getfield(L, 2, "text")
	#partial switch lua.type(L, -1) {
	case .STRING:
		text, _ = lua.toodinstring(L, -1)
		text = api_one_line(strings.clone(text, context.temp_allocator))
	case .TABLE:
		chunks = api_pane_lines(L, lua.gettop(L))
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
		append(&s.chunks, PaneLine{strings.clone(c.text), strings.clone(c.color)})
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
