package main

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import lua "lib:lua"

UI_LIST_META :: "qed.list"

UiSortKind :: enum u8 {
	None,
	Number,
	String,
}

UiListRecord :: struct {
	key:       string,
	ref:       i32,
	rev:       u64,
	sort_kind: UiSortKind,
	sort_num:  f64,
	sort_str:  string,
}

UiFuzzyMatch :: struct {
	key:   string,
	score: int,
	order: int,
}

UiList :: struct {
	id:           u64,
	owner:        string,
	key_field:    string,
	records:      [dynamic]UiListRecord,
	positions:    map[string]int,
	rev:          u64,
	record_seq:   u64,
	sort_field:   string,
	sort_reverse: bool,
	dependents:   [dynamic]u64,
	source:       u64,
	field:        string,
	query:        string,
	texts:        map[string]string,
	matches:      [dynamic]UiFuzzyMatch,
	source_rev:   u64,
	fuzzy_dirty:  bool,
}

ui_list_find :: proc(ui: ^Ui, id: u64) -> ^UiList {
	if id == 0 {
		return nil
	}
	for l in ui.lists {
		if l.id == id {
			return l
		}
	}
	return nil
}

ui_list_free :: proc(editor: ^Editor, list: ^UiList) {
	L := editor.plugins.L
	for r in list.records {
		if L != nil && r.ref != 0 {
			lua.L_unref(L, lua.REGISTRYINDEX, c.int(r.ref))
		}
		delete(r.key)
		delete(r.sort_str)
	}
	delete(list.records)
	delete(list.positions)
	delete(list.dependents)
	for k, v in list.texts {
		delete(k)
		delete(v)
	}
	delete(list.texts)
	delete(list.matches)
	delete(list.key_field)
	delete(list.sort_field)
	delete(list.field)
	delete(list.query)
	if source := ui_list_find(&editor.ui, list.source); source != nil {
		for d, i in source.dependents {
			if d == list.id {
				unordered_remove(&source.dependents, i)
				break
			}
		}
	}
	free(list)
}

ui_list_remove_by_id :: proc(editor: ^Editor, id: u64) {
	ui := &editor.ui
	for l, i in ui.lists {
		if l.id == id {
			ui_list_free(editor, l)
			ordered_remove(&ui.lists, i)
			return
		}
	}
}

ui_list_reindex :: proc(list: ^UiList) {
	clear(&list.positions)
	if list.source != 0 {
		for m, i in list.matches {
			list.positions[m.key] = i
		}
		return
	}
	for r, i in list.records {
		list.positions[r.key] = i
	}
}

ui_list_count :: proc(list: ^UiList) -> int {
	return len(list.matches) if list.source != 0 else len(list.records)
}

ui_list_key :: proc(list: ^UiList, i: int) -> string {
	return list.matches[i].key if list.source != 0 else list.records[i].key
}

ui_list_position :: proc(list: ^UiList, key: string) -> (int, bool) {
	pos, ok := list.positions[key]
	return pos, ok
}

ui_list_record_rev :: proc(list: ^UiList, i: int) -> u64 {
	if list.source != 0 {
		return list.rev
	}
	return list.records[i].rev
}

ui_list_changed :: proc(editor: ^Editor, list: ^UiList) {
	list.rev += 1
	for d in list.dependents {
		if dep := ui_list_find(&editor.ui, d); dep != nil {
			dep.fuzzy_dirty = true
		}
	}
}

ui_list_settle_all :: proc(editor: ^Editor, list: ^UiList) {
	if list.source == 0 {
		return
	}
	source := ui_list_find(&editor.ui, list.source)
	if source == nil {
		return
	}
	if !list.fuzzy_dirty && list.source_rev == source.rev {
		return
	}
	list.fuzzy_dirty = false
	list.source_rev = source.rev
	clear(&list.matches)
	for r, i in source.records {
		text := list.texts[r.key] or_else ""
		if list.query == "" {
			append(&list.matches, UiFuzzyMatch{r.key, 0, i})
			continue
		}
		if score, ok := fuzzy_match(list.query, text); ok {
			append(&list.matches, UiFuzzyMatch{r.key, score, i})
		}
	}
	slice.sort_by(list.matches[:], proc(a, b: UiFuzzyMatch) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return a.order < b.order
	})
	ui_list_reindex(list)
	list.rev += 1
}

fuzzy_positions :: proc(pattern, text: string, allocator := context.temp_allocator) -> [dynamic]int {
	out := make([dynamic]int, allocator)
	if len(pattern) == 0 {
		return out
	}
	pi := 0
	want := ascii_lower(pattern[0])
	for ti := 0; ti < len(text) && pi < len(pattern); ti += 1 {
		if ascii_lower(text[ti]) != want {
			continue
		}
		append(&out, ti)
		pi += 1
		if pi < len(pattern) {
			want = ascii_lower(pattern[pi])
		}
	}
	return out
}

api_ui_list :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> ^UiList {
	idx := lua.absindex(L, idx)
	if lua.type(L, idx) != .TABLE || lua.getmetatable(L, idx) == 0 {
		return nil
	}
	lua.getfield(L, lua.REGISTRYINDEX, UI_LIST_META)
	is_list := lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 2)
	if !is_list {
		return nil
	}
	id, _ := api_field_int(L, idx, "id")
	list := ui_list_find(&editor.ui, u64(id))
	if list == nil {
		plugin_raise(L, "list is gone")
	}
	return list
}

api_ui_list_self :: proc(L: ^lua.State, editor: ^Editor) -> ^UiList {
	list := api_ui_list(L, editor, 1)
	if list == nil {
		lua.L_argerror(L, 1, "qed.list expected (call with ':')")
	}
	return list
}

api_ui_list_push :: proc(L: ^lua.State, editor: ^Editor, owner: string) -> ^UiList {
	p := &editor.plugins
	id := plugin_next_id(p)
	lua.createtable(L, 0, 1)
	lua.pushinteger(L, lua.Integer(id))
	lua.setfield(L, -2, "id")
	if lua.getfield(L, lua.REGISTRYINDEX, UI_LIST_META) != .TABLE {
		lua.pop(L, 1)
		lua.createtable(L, 0, 4)
		lua.createtable(L, 0, len(ui_list_methods))
		for m in ui_list_methods {
			lua.pushcfunction(L, m.func)
			lua.setfield(L, -2, m.name)
		}
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, qed_list_gc_ui)
		lua.setfield(L, -2, "__gc")
		lua.pushboolean(L, false)
		lua.setfield(L, -2, "__metatable")
		lua.pushvalue(L, -1)
		lua.setfield(L, lua.REGISTRYINDEX, UI_LIST_META)
	}
	lua.setmetatable(L, -2)
	list := new(UiList)
	list.id = id
	list.owner = plugin_name_intern(p, owner)
	append(&editor.ui.lists, list)
	return list
}

ui_list_methods := [?]lua.L_Reg {
	{"append", qed_list_append},
	{"insert", qed_list_insert},
	{"set", qed_list_set},
	{"remove", qed_list_remove},
	{"clear", qed_list_clear},
	{"get", qed_list_get},
	{"at", qed_list_at},
	{"index_of", qed_list_index_of},
	{"count", qed_list_count},
	{"sort", qed_list_sort},
	{"set_query", qed_list_set_query},
}

qed_list_gc_ui :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return 0
	}
	context = entry.ctx
	lua.getfield(L, 1, "id")
	id := u64(lua.tointeger(L, -1))
	ui_list_remove_by_id(entry.editor, id)
	return 0
}

qed_list_new :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table {key} expected")
	}
	key, has := api_field_string(L, 1, "key")
	if !has || key == "" {
		lua.L_argerror(L, 1, "key: the name of the identity field")
	}
	lua.pushnil(L)
	for lua.next(L, 1) != 0 {
		k, _ := lua.toodinstring(L, -2)
		if lua.type(L, -2) != .STRING || k != "key" {
			plugin_raise(L, fmt.tprintf("qed.list.new: unknown field '%s'", k))
		}
		lua.pop(L, 1)
	}
	pl := api_loaded(L, editor)
	lua.settop(L, 0)
	list := api_ui_list_push(L, editor, pl.name)
	list.key_field = strings.clone(key)
	return 1
}

ui_list_record_key :: proc(L: ^lua.State, list: ^UiList, idx: c.int) -> string {
	idx := lua.absindex(L, idx)
	if lua.type(L, idx) != .TABLE {
		lua.L_argerror(L, idx, "record table expected")
	}
	lua.pushodinstring(L, list.key_field)
	lua.rawget(L, idx)
	defer lua.pop(L, 1)
	#partial switch lua.type(L, -1) {
	case .STRING:
		s, _ := lua.toodinstring(L, -1)
		return strings.clone(s, context.temp_allocator)
	case .NUMBER:
		if lua.isinteger(L, -1) {
			return fmt.tprintf("%d", lua.tointeger(L, -1))
		}
		return fmt.tprintf("%v", lua.tonumberx(L, -1, nil))
	}
	plugin_raise(L, fmt.tprintf("record has no '%s' (the list's key field)", list.key_field))
	return ""
}

ui_list_sort_value :: proc(L: ^lua.State, list: ^UiList, idx: c.int, r: ^UiListRecord) {
	if list.sort_field == "" {
		return
	}
	idx := lua.absindex(L, idx)
	lua.pushodinstring(L, list.sort_field)
	lua.rawget(L, idx)
	defer lua.pop(L, 1)
	delete(r.sort_str)
	r.sort_str = ""
	#partial switch lua.type(L, -1) {
	case .NUMBER:
		r.sort_kind = .Number
		r.sort_num = f64(lua.tonumberx(L, -1, nil))
	case .STRING:
		s, _ := lua.toodinstring(L, -1)
		r.sort_kind = .String
		r.sort_str = strings.clone(s)
	case:
		r.sort_kind = .None
	}
}

ui_list_less :: proc(list: ^UiList, a, b: UiListRecord) -> bool {
	less := false
	if a.sort_kind != b.sort_kind {
		less = a.sort_kind < b.sort_kind
	} else if a.sort_kind == .Number {
		less = a.sort_num < b.sort_num
	} else {
		less = a.sort_str < b.sort_str
	}
	if list.sort_reverse {
		return !less && (a.sort_kind != b.sort_kind || a.sort_num != b.sort_num || a.sort_str != b.sort_str)
	}
	return less
}

ui_list_texts_update :: proc(L: ^lua.State, editor: ^Editor, list: ^UiList, key: string, idx: c.int) {
	idx := lua.absindex(L, idx)
	for d in list.dependents {
		dep := ui_list_find(&editor.ui, d)
		if dep == nil {
			continue
		}
		lua.pushodinstring(L, dep.field)
		lua.rawget(L, idx)
		text := ""
		if lua.type(L, -1) == .STRING {
			text, _ = lua.toodinstring(L, -1)
		}
		if old, ok := dep.texts[key]; ok {
			delete(old)
			dep.texts[key] = strings.clone(text)
		} else {
			dep.texts[strings.clone(key)] = strings.clone(text)
		}
		lua.pop(L, 1)
		dep.fuzzy_dirty = true
	}
}

ui_list_mutable :: proc(L: ^lua.State, list: ^UiList) {
	if list.source != 0 {
		plugin_raise(L, "a fuzzy list follows its source; change the source list")
	}
}

ui_list_store :: proc(L: ^lua.State, editor: ^Editor, list: ^UiList, idx: c.int, at: int) {
	idx := lua.absindex(L, idx)
	key := ui_list_record_key(L, list, idx)
	if key in list.positions {
		plugin_raise(L, fmt.tprintf("duplicate key '%s'", key))
	}
	r := UiListRecord{}
	ui_list_sort_value(L, list, idx, &r)
	ui_list_texts_update(L, editor, list, key, idx)
	lua.pushvalue(L, idx)
	r.ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	r.key = strings.clone(key)
	list.record_seq += 1
	r.rev = list.record_seq
	pos := at
	if list.sort_field != "" {
		lo, hi := 0, len(list.records)
		for lo < hi {
			mid := (lo + hi) / 2
			if ui_list_less(list, r, list.records[mid]) {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		pos = lo
	}
	pos = clamp(pos, 0, len(list.records))
	inject_at(&list.records, pos, r)
	ui_list_reindex(list)
	ui_list_changed(editor, list)
}

qed_list_append :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	list := api_ui_list_self(L, entry.editor)
	ui_list_mutable(L, list)
	ui_list_store(L, entry.editor, list, 2, len(list.records))
	return 0
}

qed_list_insert :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	list := api_ui_list_self(L, entry.editor)
	ui_list_mutable(L, list)
	pos := api_int(L, 2, "position expected")
	if list.sort_field != "" {
		plugin_raise(L, "the list is sorted; use append")
	}
	if pos < 1 || pos > len(list.records) + 1 {
		lua.L_argerror(L, 2, "position out of range")
	}
	ui_list_store(L, entry.editor, list, 3, pos - 1)
	return 0
}

ui_list_key_arg :: proc(L: ^lua.State, idx: c.int) -> string {
	#partial switch lua.type(L, idx) {
	case .STRING:
		s, _ := lua.toodinstring(L, idx)
		return strings.clone(s, context.temp_allocator)
	case .NUMBER:
		if lua.isinteger(L, idx) {
			return fmt.tprintf("%d", lua.tointeger(L, idx))
		}
		return fmt.tprintf("%v", lua.tonumberx(L, idx, nil))
	}
	lua.L_argerror(L, idx, "key expected")
	return ""
}

qed_list_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_mutable(L, list)
	key := ui_list_key_arg(L, 2)
	if lua.type(L, 3) != .TABLE {
		lua.L_argerror(L, 3, "fields table expected")
	}
	pos, ok := list.positions[key]
	if !ok {
		return api_fail(L, "no such key")
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(list.records[pos].ref))
	record := lua.gettop(L)
	lua.pushnil(L)
	for lua.next(L, 3) != 0 {
		lua.pushvalue(L, -2)
		lua.insert(L, -2)
		lua.rawset(L, record)
	}
	list.record_seq += 1
	list.records[pos].rev = list.record_seq
	ui_list_texts_update(L, editor, list, key, record)
	if list.sort_field != "" {
		r := list.records[pos]
		ordered_remove(&list.records, pos)
		ui_list_sort_value(L, list, record, &r)
		lo, hi := 0, len(list.records)
		for lo < hi {
			mid := (lo + hi) / 2
			if ui_list_less(list, r, list.records[mid]) {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		inject_at(&list.records, lo, r)
		ui_list_reindex(list)
	}
	ui_list_changed(editor, list)
	lua.pushboolean(L, true)
	return 1
}

qed_list_remove :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_mutable(L, list)
	key := ui_list_key_arg(L, 2)
	pos, ok := list.positions[key]
	if !ok {
		return 0
	}
	r := list.records[pos]
	lua.L_unref(L, lua.REGISTRYINDEX, c.int(r.ref))
	ordered_remove(&list.records, pos)
	for d in list.dependents {
		if dep := ui_list_find(&editor.ui, d); dep != nil {
			k, v := delete_key(&dep.texts, r.key)
			delete(k)
			delete(v)
		}
	}
	delete(r.key)
	delete(r.sort_str)
	ui_list_reindex(list)
	ui_list_changed(editor, list)
	return 0
}

qed_list_clear :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_mutable(L, list)
	for r in list.records {
		lua.L_unref(L, lua.REGISTRYINDEX, c.int(r.ref))
		delete(r.key)
		delete(r.sort_str)
	}
	clear(&list.records)
	for d in list.dependents {
		if dep := ui_list_find(&editor.ui, d); dep != nil {
			for k, v in dep.texts {
				delete(k)
				delete(v)
			}
			clear(&dep.texts)
		}
	}
	ui_list_reindex(list)
	ui_list_changed(editor, list)
	return 0
}

ui_list_record_push :: proc(L: ^lua.State, editor: ^Editor, list: ^UiList, pos: int) {
	if list.source == 0 {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(list.records[pos].ref))
		return
	}
	source := ui_list_find(&editor.ui, list.source)
	m := list.matches[pos]
	if source == nil {
		lua.pushnil(L)
		return
	}
	spos, ok := source.positions[m.key]
	if !ok {
		lua.pushnil(L)
		return
	}
	lua.createtable(L, 0, 1)
	offsets := fuzzy_positions(list.query, list.texts[m.key] or_else "")
	lua.createtable(L, c.int(len(offsets)), 0)
	for o, i in offsets {
		lua.pushinteger(L, lua.Integer(o + 1))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "positions")
	lua.createtable(L, 0, 1)
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(source.records[spos].ref))
	lua.setfield(L, -2, "__index")
	lua.setmetatable(L, -2)
}

qed_list_get :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_settle_all(editor, list)
	key := ui_list_key_arg(L, 2)
	pos, ok := list.positions[key]
	if !ok {
		lua.pushnil(L)
		return 1
	}
	ui_list_record_push(L, editor, list, pos)
	return 1
}

qed_list_at :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_settle_all(editor, list)
	i := api_int(L, 2, "index expected")
	if i < 1 || i > ui_list_count(list) {
		lua.pushnil(L)
		return 1
	}
	ui_list_record_push(L, editor, list, i - 1)
	return 1
}

qed_list_index_of :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_settle_all(editor, list)
	key := ui_list_key_arg(L, 2)
	pos, ok := list.positions[key]
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua.pushinteger(L, lua.Integer(pos + 1))
	return 1
}

qed_list_count :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_settle_all(editor, list)
	lua.pushinteger(L, lua.Integer(ui_list_count(list)))
	return 1
}

qed_list_sort :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_mutable(L, list)
	field := api_string(L, 2)
	reverse := false
	if lua.type(L, 3) == .TABLE {
		lua.getfield(L, 3, "reverse")
		reverse = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	}
	delete(list.sort_field)
	list.sort_field = strings.clone(field)
	list.sort_reverse = reverse
	for &r in list.records {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(r.ref))
		ui_list_sort_value(L, list, -1, &r)
		lua.pop(L, 1)
	}
	context.user_ptr = list
	slice.stable_sort_by(list.records[:], proc(a, b: UiListRecord) -> bool {
		return ui_list_less((^UiList)(context.user_ptr), a, b)
	})
	ui_list_reindex(list)
	ui_list_changed(editor, list)
	return 0
}

qed_list_set_query :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	if list.source == 0 {
		plugin_raise(L, "set_query is for qed.fuzzy.list lists")
	}
	query := api_string(L, 2)
	if query != list.query {
		delete(list.query)
		list.query = strings.clone(query)
		list.fuzzy_dirty = true
	}
	return 0
}

qed_fuzzy_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	source := api_ui_list(L, editor, 1)
	if source == nil {
		lua.L_argerror(L, 1, "qed.list expected")
	}
	if source.source != 0 {
		lua.L_argerror(L, 1, "a fuzzy list cannot be a source")
	}
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "table {field} expected")
	}
	field, has := api_field_string(L, 2, "field")
	if !has || field == "" {
		lua.L_argerror(L, 2, "field: the record field to match")
	}
	pl := api_loaded(L, editor)
	lua.settop(L, 0)
	list := api_ui_list_push(L, editor, pl.name)
	list.source = source.id
	list.field = strings.clone(field)
	list.fuzzy_dirty = true
	append(&source.dependents, list.id)
	for r in source.records {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(r.ref))
		lua.pushodinstring(L, field)
		lua.rawget(L, -2)
		text := ""
		if lua.type(L, -1) == .STRING {
			text, _ = lua.toodinstring(L, -1)
		}
		list.texts[strings.clone(r.key)] = strings.clone(text)
		lua.pop(L, 2)
	}
	return 1
}
