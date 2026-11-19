package main

import "core:c"
import "core:fmt"
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
}

view_event_names := [ViewEvent]cstring {
	.Activate = "activate",
	.Change   = "change",
	.Query    = "query",
	.Close    = "close",
}

UiView :: struct {
	handle:      u64,
	owner:       string,
	view_ref:    i32,
	items_ref:   i32,
	on:          [ViewEvent]i32,
	change_task: u64,
	query_task:  u64,
}

UiViewEvent :: struct {
	handle:   u64,
	kind:     ViewEvent,
	sel:      []int,
	text:     string,
	has_text: bool,
}

PluginAnswer :: struct {
	handle:    u64,
	ok:        bool,
	items_ref: i32,
	sel:       []int,
	text:      string,
	has_text:  bool,
}

@(private = "file")
qed_view_methods := [?]lua.L_Reg {
	{"set", qed_view_set},
	{"append", qed_view_append},
	{"update", qed_view_update},
	{"text", qed_view_text},
	{"close", qed_view_close},
	{"wait", qed_view_wait},
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
		refs := [?]i32{v.view_ref, v.items_ref, v.on[.Activate], v.on[.Change], v.on[.Query], v.on[.Close]}
		for ref in refs {
			if ref != 0 {
				lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ref))
			}
		}
	}
	ordered_remove(&p.views, i)
}

plugin_view_event_free :: proc(ev: UiViewEvent) {
	delete(ev.sel)
	delete(ev.text)
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
		ev.text = strings.clone(textfield_str(&pn.fields[0].field))
		ev.has_text = true
	}
	append(&editor.plugins.view_events, ev)
}

plugin_view_closed :: proc(editor: ^Editor, pn: ^Pane) {
	pane_save(editor, pn)
	plugin_view_queue(editor, pn, .Close, nil)
}

plugin_view_activate :: proc(editor: ^Editor, pn: ^Pane) {
	p := &editor.plugins
	vi := plugin_view_index(p, pn.handle)
	if pane_query(pn) != nil && (pn.query_due || (vi >= 0 && plugin_task_alive(p, p.views[vi].query_task))) {
		pn.accept = true
		pn.query_at = time.tick_now()
		return
	}
	plugin_view_activate_now(editor, pn)
}

plugin_view_activate_now :: proc(editor: ^Editor, pn: ^Pane) {
	if !pn.has_list {
		for f in pn.fields {
			if f.mode == .Input {
				plugin_view_queue(editor, pn, .Activate, nil)
				return
			}
		}
		return
	}
	if pane_count(pn) == 0 {
		return
	}
	lo, hi := pn.list.sel, pn.list.sel
	if a, ok := pn.list.anchor.?; ok && pn.list.multi {
		lo, hi = min(a, pn.list.sel), max(a, pn.list.sel)
	}
	sel := make([]int, hi - lo + 1)
	for pos in lo ..= hi {
		sel[pos - lo] = pane_item_index(pn, pos)
	}
	plugin_view_queue(editor, pn, .Activate, sel)
}

plugin_views_due :: proc(editor: ^Editor) -> bool {
	for p in editor.panes {
		if p.ctx.lua && (p.query_due || p.accept) {
			return true
		}
	}
	return false
}

plugin_views_pump :: proc(editor: ^Editor) {
	p := &editor.plugins
	now := time.tick_now()
	for i := 0; i < len(p.views); i += 1 {
		v := p.views[i]
		pi := pane_index(editor, v.handle)
		if pi < 0 || !pane_live(editor, &editor.panes[pi]) {
			continue
		}
		if pn := &editor.panes[pi]; pn.query_due && plugin_tick_due(pn.query_at, now) {
			pn.query_due = false
			text := strings.clone(textfield_str(&pane_query(pn).field), context.temp_allocator)
			plugin_task_kill(editor, v.query_task)
			task: u64
			if v.on[.Query] != 0 {
				id, finished := plugin_task_start(editor, v.owner, .Command, {ref = v.on[.Query], args = .View_Text, view_ref = v.view_ref, line = text})
				task = 0 if finished else id
			}
			if j := plugin_view_index(p, v.handle); j >= 0 {
				p.views[j].query_task = task
			}
		}
		j := plugin_view_index(p, v.handle)
		if pi = pane_index(editor, v.handle); pi < 0 || j < 0 {
			continue
		}
		if pn := &editor.panes[pi]; pn.accept && !pn.query_due && !plugin_task_alive(p, p.views[j].query_task) {
			pn.accept = false
			plugin_view_activate_now(editor, pn)
		}
	}
}

plugin_views_flush :: proc(editor: ^Editor) {
	p := &editor.plugins
	for i := 0; i < len(p.views); i += 1 {
		v := p.views[i]
		pi := pane_index(editor, v.handle)
		if pi < 0 || !pane_live(editor, &editor.panes[pi]) {
			continue
		}
		pn := &editor.panes[pi]
		if pane_count(pn) == 0 {
			continue
		}
		item := pane_item_index(pn, pn.list.sel)
		if item == pn.notified {
			continue
		}
		pn.notified = item
		if v.on[.Change] == 0 {
			continue
		}
		plugin_task_kill(editor, v.change_task)
		task, finished := plugin_task_start(editor, v.owner, .Command, {ref = v.on[.Change], args = .View_Item, view_ref = v.view_ref, item_ref = v.items_ref, item = item + 1})
		if j := plugin_view_index(p, v.handle); j >= 0 {
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
	if ev.kind == .Close {
		plugin_task_kill(editor, v.change_task)
		plugin_task_kill(editor, v.query_task)
	}
	prev := p.answer
	p.answer = {handle = ev.handle, ok = ev.kind == .Activate, items_ref = v.items_ref, sel = ev.sel, text = ev.text, has_text = ev.has_text}
	for w in plugin_waiters(p, .Pane, ev.handle) {
		plugin_task_resume(editor, w, 0)
	}
	p.answer = prev
	if ref := v.on[ev.kind]; ref != 0 {
		args := PluginArgs.View_Items if ev.kind == .Activate else .View
		plugin_task_start(editor, v.owner, .Command, {ref = ref, args = args, view_ref = v.view_ref, item_ref = v.items_ref, items = ev.sel})
	}
	if ev.kind == .Close {
		if vi = plugin_view_index(p, ev.handle); vi >= 0 {
			plugin_view_release(p, vi)
		}
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
	case .NIL:
	case:
		plugin_raise(L, "pos must be a table {row, col}")
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
			plugin_raise(L, fmt.tprintf("lines[%d] must be a string or {text, color}", i))
		}
		lua.pop(L, 1)
	}
	return out
}

api_items_copy :: proc(L: ^lua.State, src: c.int, dst: c.int, from, n: int) {
	for i in 1 ..= n {
		lua.rawgeti(L, src, lua.Integer(i))
		lua.rawseti(L, dst, lua.Integer(from + i))
	}
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
	spec.title, _ = api_field_string(L, 1, "title")
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
			case:
				plugin_raise(L, `mode must be "filter", "query" or "input"`)
			}
			f.count = api_opt_bool(L, ft, "count")
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
			items = api_view_items(L, editor, -1)
		case .NIL:
		case:
			plugin_raise(L, "items must be a table")
		}
		lua.pop(L, 1)
		spec.list.multi = api_opt_bool(L, t, "multi")
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

	#partial switch lua.getfield(L, 1, "footer") {
	case .TABLE:
		if lua.getfield(L, -1, "hints") == .TABLE {
			t := lua.gettop(L)
			n := int(lua.rawlen(L, t))
			spec.footer = make([]PaneHint, n, context.temp_allocator)
			for i in 0 ..< n {
				if lua.rawgeti(L, t, lua.Integer(i + 1)) != .TABLE {
					plugin_raise(L, fmt.tprintf("hints[%d] must be a table {label, cmd?}", i + 1))
				}
				spec.footer[i].label, _ = api_field_string(L, lua.gettop(L), "label")
				spec.footer[i].cmd, _ = api_field_string(L, lua.gettop(L), "cmd")
				lua.pop(L, 1)
			}
		}
		lua.pop(L, 1)
	case .NIL:
	case:
		plugin_raise(L, "footer must be a table {hints}")
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
		if f := pane_focus(editor); f != nil {
			spec.kind, spec.parent = .Child, f.handle
		} else if ov := editor_overlay_active(editor); ov != nil {
			spec.kind, spec.over = .Child, ov
		}
	}
	keep := len(items)
	if spec.list.max > 0 && keep > spec.list.max {
		keep = spec.list.max
		spec.list.more = true
	}
	spec.list.items = make([dynamic]PaneItem, 0, keep, context.temp_allocator)
	append(&spec.list.items, ..items[:keep])
	spec.owner = plugin_name_intern(p, pl.name)
	spec.ctx.lua = true
	spec.on = {activate = plugin_view_activate, close = plugin_view_closed}
	if t := plugin_task_of(p, L); t != nil {
		spec.toggle = t.command
	}
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
			restored = false
		} else if saved != nil && i < len(saved.texts) {
			text = saved.texts[i]
		}
		textfield_set(&f.field, text)
		if f.mode != .Input {
			textfield_select_all(&f.field)
		}
	}
	pane_refilter(pn)
	rows := pane_geom(editor, pn).list.h
	if selected > 0 {
		pane_select(pn, selected - 1, rows)
	} else if restored && saved.key != "" {
		pn.list.restore = strings.clone(saved.key)
		pane_restore(pn, rows)
	}
	if pane_count(pn) > 0 {
		pn.notified = pane_item_index(pn, pn.list.sel)
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
	if lua.getfield(L, 1, "list") == .TABLE && lua.getfield(L, -1, "items") == .TABLE {
		api_items_copy(L, lua.gettop(L), lua.gettop(L) - 2, 0, keep)
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
	editor_clear_message(editor)
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

pane_refilter_keep :: proc(p: ^Pane) {
	if pane_filter(p) == nil {
		return
	}
	prev := pane_item_index(p, p.list.sel) if pane_count(p) > 0 else -1
	pane_refilter(p)
	for m, i in p.list.matches {
		if m == prev {
			p.list.sel = i
		}
	}
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
	items := api_view_items(L, editor, 2)
	selected := 0
	more := false
	hint := ""
	if lua.type(L, 3) == .TABLE {
		if lua.getfield(L, 3, "selected") != .NIL {
			selected = api_int(L, -1, "selected must be an item index")
		}
		lua.pop(L, 1)
		more = api_opt_bool(L, 3, "more")
		hint, _ = api_field_string(L, 3, "hint")
	}
	pn, vi := api_view_live(L, editor)
	if pn == nil {
		lua.pushboolean(L, false)
		return 1
	}
	handle := pn.handle
	keep := len(items)
	if pn.list.max > 0 && keep > pn.list.max {
		keep = pn.list.max
		more = true
	}
	lua.createtable(L, c.int(keep), 0)
	api_items_copy(L, 2, 4, 0, keep)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	vi = plugin_view_index(p, handle)
	lua.L_unref(L, lua.REGISTRYINDEX, c.int(p.views[vi].items_ref))
	p.views[vi].items_ref = ref
	pn = &editor.panes[pane_index(editor, handle)]
	pane_items_clear(pn)
	pane_items_add(pn, items[:keep])
	pn.list.more = more
	delete(pn.list.hint)
	pn.list.hint = strings.clone(hint)
	pane_refilter(pn)
	rows := pane_geom(editor, pn).list.h
	pn.list.sel, pn.list.scroll, pn.list.anchor = 0, 0, nil
	if selected > 0 {
		delete(pn.list.restore)
		pn.list.restore = ""
		pn.list.sel = clamp(selected - 1, 0, max(0, pane_count(pn) - 1))
		pn.list.scroll = max(0, pn.list.sel - rows / 2)
		pane_scroll_fit(pn, rows)
	} else {
		pane_restore(pn, rows)
	}
	pn.notified = -1
	pane_preview_sync(editor, pn)
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
	items := api_view_items(L, editor, 2)
	pn, vi := api_view_live(L, editor)
	if pn == nil {
		lua.pushboolean(L, false)
		return 1
	}
	n := len(pn.list.items)
	room := len(items)
	if pn.list.max > 0 && n + room > pn.list.max {
		room = max(0, pn.list.max - n)
		pn.list.more = true
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(editor.plugins.views[vi].items_ref))
	api_items_copy(L, 2, 3, n, room)
	lua.settop(L, 2)
	prev := pane_item_index(pn, pn.list.sel) if pane_count(pn) > 0 else -1
	pane_items_add(pn, items[:room])
	if pane_filter(pn) != nil {
		pane_refilter(pn)
		for m, i in pn.list.matches {
			if m == prev {
				pn.list.sel = i
			}
		}
	}
	pane_restore(pn, pane_geom(editor, pn).list.h)
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
	api_view_item(L, editor, 3)
	pn, vi := api_view_live(L, editor)
	idx := -1
	if pn != nil {
		for it, i in pn.list.items {
			if pane_item_key(it) == key {
				idx = i
				break
			}
		}
	}
	if idx < 0 {
		lua.pushboolean(L, false)
		return 1
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
	pane_item_free(pn.list.items[idx])
	pn.list.items[idx] = pane_item_clone(it)
	pane_refilter_keep(pn)
	pane_preview_sync(editor, pn)
	lua.pushboolean(L, true)
	return 1
}

qed_view_text :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lines := api_pane_lines(L, 2)
	pn, _ := api_view_live(L, entry.editor)
	if pn != nil {
		pane_lines_free(pn.text)
		pn.text = pane_lines_clone(lines)
	}
	lua.pushboolean(L, b32(pn != nil))
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
	if a.ok {
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
