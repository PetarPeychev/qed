package main

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import lua "lib:lua"

UI_LIST_META :: "qed.List"
UI_FUZZY_LIST_META :: "qed.FuzzyList"

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
	rev:   u64,
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
	fuzzy:        bool,
	source:       u64,
	source_ref:   i32,
	field:        string,
	query:        string,
	query_gen:    u64,
	texts:        map[string]string,
	matches:      [dynamic]UiFuzzyMatch,
	source_rev:   u64,
	fuzzy_dirty:  bool,
}

ui_list_find :: proc(ui: ^Ui, id: u64) -> ^UiList {
	if id == 0 {
		return nil
	}
	for list in ui.lists {
		if list.id == id {
			return list
		}
	}
	return nil
}

ui_list_free :: proc(editor: ^Editor, list: ^UiList) {
	L := editor.plugins.L
	for dependent_id in list.dependents {
		if dependent := ui_list_find(&editor.ui, dependent_id); dependent != nil {
			clear(&dependent.matches)
			clear(&dependent.positions)
			dependent.source = 0
			dependent.rev += 1
		}
	}
	if L != nil && list.source_ref != 0 {
		lua.L_unref(L, lua.REGISTRYINDEX, c.int(list.source_ref))
	}
	for record in list.records {
		if L != nil && record.ref != 0 {
			lua.L_unref(L, lua.REGISTRYINDEX, c.int(record.ref))
		}
		delete(record.key)
		delete(record.sort_str)
	}
	delete(list.records)
	delete(list.positions)
	delete(list.dependents)
	for key, value in list.texts {
		delete(key)
		delete(value)
	}
	delete(list.texts)
	delete(list.matches)
	delete(list.key_field)
	delete(list.sort_field)
	delete(list.field)
	delete(list.query)
	if source := ui_list_find(&editor.ui, list.source); source != nil {
		for dependent, i in source.dependents {
			if dependent == list.id {
				unordered_remove(&source.dependents, i)
				break
			}
		}
	}
	free(list)
}

ui_list_remove_by_id :: proc(editor: ^Editor, id: u64) {
	ui := &editor.ui
	for list, i in ui.lists {
		if list.id == id {
			ui_list_free(editor, list)
			ordered_remove(&ui.lists, i)
			return
		}
	}
}

ui_list_reindex :: proc(list: ^UiList) {
	clear(&list.positions)
	if list.fuzzy {
		for match, i in list.matches {
			list.positions[match.key] = i
		}
		return
	}
	for record, i in list.records {
		list.positions[record.key] = i
	}
}

ui_list_count :: proc(list: ^UiList) -> int {
	return len(list.matches) if list.fuzzy else len(list.records)
}

ui_list_key :: proc(list: ^UiList, i: int) -> string {
	return list.matches[i].key if list.fuzzy else list.records[i].key
}

ui_list_position :: proc(list: ^UiList, key: string) -> (int, bool) {
	pos, ok := list.positions[key]
	return pos, ok
}

ui_list_record_rev :: proc(list: ^UiList, i: int) -> u64 {
	if list.fuzzy {
		return list.matches[i].rev ~ (list.query_gen << 40)
	}
	return list.records[i].rev
}

ui_list_changed :: proc(editor: ^Editor, list: ^UiList) {
	list.rev += 1
	for dependent_id in list.dependents {
		if dependent := ui_list_find(&editor.ui, dependent_id); dependent != nil {
			dependent.fuzzy_dirty = true
			dependent.rev += 1
		}
	}
}

ui_list_settle_all :: proc(editor: ^Editor, list: ^UiList) {
	if !list.fuzzy {
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
	for record, i in source.records {
		text := list.texts[record.key] or_else ""
		if list.query == "" {
			append(&list.matches, UiFuzzyMatch{record.key, 0, i, record.rev})
			continue
		}
		if score, ok := fuzzy_match(list.query, text); ok {
			append(&list.matches, UiFuzzyMatch{record.key, score, i, record.rev})
		}
	}
	slice.sort_by(list.matches[:], proc(left, right: UiFuzzyMatch) -> bool {
		if left.score != right.score {
			return left.score > right.score
		}
		return left.order < right.order
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

api_ui_list_lookup :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> (list: ^UiList, gone: bool) {
	idx := lua.absindex(L, idx)
	if lua.type(L, idx) != .TABLE || lua.getmetatable(L, idx) == 0 {
		return nil, false
	}
	lua.getfield(L, lua.REGISTRYINDEX, UI_LIST_META)
	is_list := lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 1)
	lua.getfield(L, lua.REGISTRYINDEX, UI_FUZZY_LIST_META)
	is_list = is_list || lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 2)
	if !is_list {
		return nil, false
	}
	id, _ := api_field_int(L, idx, "id")
	list = ui_list_find(&editor.ui, u64(id))
	return list, list == nil
}

api_ui_list :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> ^UiList {
	list, gone := api_ui_list_lookup(L, editor, idx)
	if gone {
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

api_ui_list_push :: proc(L: ^lua.State, editor: ^Editor, owner: string, fuzzy: bool) -> ^UiList {
	plugins := &editor.plugins
	id := plugin_next_id(plugins)
	lua.createtable(L, 0, 1)
	lua.pushinteger(L, lua.Integer(id))
	lua.setfield(L, -2, "id")
	meta_name: cstring = UI_FUZZY_LIST_META if fuzzy else UI_LIST_META
	methods := ui_fuzzy_list_methods[:] if fuzzy else ui_list_methods[:]
	if lua.getfield(L, lua.REGISTRYINDEX, meta_name) != .TABLE {
		lua.pop(L, 1)
		lua.createtable(L, 0, 4)
		lua.createtable(L, 0, c.int(len(methods)))
		for method in methods {
			lua.pushcfunction(L, method.func)
			lua.setfield(L, -2, method.name)
		}
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, qed_list_gc_ui)
		lua.setfield(L, -2, "__gc")
		lua.pushboolean(L, false)
		lua.setfield(L, -2, "__metatable")
		lua.pushvalue(L, -1)
		lua.setfield(L, lua.REGISTRYINDEX, meta_name)
	}
	lua.setmetatable(L, -2)
	list := new(UiList)
	list.id = id
	list.fuzzy = fuzzy
	list.owner = plugin_name_intern(plugins, owner)
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
}

ui_fuzzy_list_methods := [?]lua.L_Reg {
	{"get", qed_list_get},
	{"at", qed_list_at},
	{"index_of", qed_list_index_of},
	{"count", qed_list_count},
	{"set_query", qed_list_set_query},
	{"positions", qed_list_positions},
}

qed_list_gc_ui :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return 0
	}
	context = entry.ctx
	lua.getfield(L, 1, "id")
	append(&entry.editor.ui.lists_dead, u64(lua.tointeger(L, -1)))
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
		field_name, _ := lua.toodinstring(L, -2)
		if lua.type(L, -2) != .STRING || field_name != "key" {
			plugin_raise(L, fmt.tprintf("qed.list.new: unknown field '%s'", field_name))
		}
		lua.pop(L, 1)
	}
	plugin := api_loaded(L, editor)
	lua.settop(L, 0)
	list := api_ui_list_push(L, editor, plugin.name, false)
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
		text, _ := lua.toodinstring(L, -1)
		return strings.clone(text, context.temp_allocator)
	case .NUMBER:
		if lua.isinteger(L, -1) {
			return fmt.tprintf("%d", lua.tointeger(L, -1))
		}
		return fmt.tprintf("%v", lua.tonumberx(L, -1, nil))
	}
	plugin_raise(L, fmt.tprintf("record has no '%s' (the list's key field)", list.key_field))
	return ""
}

ui_list_sort_value :: proc(L: ^lua.State, list: ^UiList, idx: c.int, record: ^UiListRecord) {
	if list.sort_field == "" {
		return
	}
	idx := lua.absindex(L, idx)
	lua.pushodinstring(L, list.sort_field)
	lua.rawget(L, idx)
	defer lua.pop(L, 1)
	delete(record.sort_str)
	record.sort_str = ""
	#partial switch lua.type(L, -1) {
	case .NUMBER:
		record.sort_kind = .Number
		record.sort_num = f64(lua.tonumberx(L, -1, nil))
	case .STRING:
		text, _ := lua.toodinstring(L, -1)
		record.sort_kind = .String
		record.sort_str = strings.clone(text)
	case:
		record.sort_kind = .None
	}
}

ui_list_less :: proc(list: ^UiList, left, right: UiListRecord) -> bool {
	less := false
	if left.sort_kind != right.sort_kind {
		less = left.sort_kind < right.sort_kind
	} else if left.sort_kind == .Number {
		less = left.sort_num < right.sort_num
	} else {
		less = left.sort_str < right.sort_str
	}
	if list.sort_reverse {
		return !less && (left.sort_kind != right.sort_kind || left.sort_num != right.sort_num || left.sort_str != right.sort_str)
	}
	return less
}

ui_list_texts_update :: proc(L: ^lua.State, editor: ^Editor, list: ^UiList, key: string, idx: c.int) {
	idx := lua.absindex(L, idx)
	for dependent in list.dependents {
		dep := ui_list_find(&editor.ui, dependent)
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
	if list.fuzzy {
		plugin_raise(L, "a fuzzy list follows its source; change the source list")
	}
}

ui_list_store :: proc(L: ^lua.State, editor: ^Editor, list: ^UiList, idx: c.int, at: int) {
	idx := lua.absindex(L, idx)
	key := ui_list_record_key(L, list, idx)
	if key in list.positions {
		plugin_raise(L, fmt.tprintf("duplicate key '%s'", key))
	}
	record := UiListRecord{}
	ui_list_sort_value(L, list, idx, &record)
	ui_list_texts_update(L, editor, list, key, idx)
	lua.pushvalue(L, idx)
	record.ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	record.key = strings.clone(key)
	list.record_seq += 1
	record.rev = list.record_seq
	pos := at
	if list.sort_field != "" {
		lo, hi := 0, len(list.records)
		for lo < hi {
			mid := (lo + hi) / 2
			if ui_list_less(list, record, list.records[mid]) {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		pos = lo
	}
	pos = clamp(pos, 0, len(list.records))
	if pos == len(list.records) {
		append(&list.records, record)
	} else {
		if len(list.records) == cap(list.records) {
			reserve(&list.records, 2 * cap(list.records) + 8)
		}
		inject_at(&list.records, pos, record)
	}
	for i in pos ..< len(list.records) {
		list.positions[list.records[i].key] = i
	}
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
		text, _ := lua.toodinstring(L, idx)
		return strings.clone(text, context.temp_allocator)
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
	lua.pushodinstring(L, list.key_field)
	lua.rawget(L, 3)
	if lua.type(L, -1) != .NIL {
		return plugin_raise(L, fmt.tprintf("set: '%s' is the key field; remove and append to change it", list.key_field))
	}
	lua.pop(L, 1)
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
		moved := list.records[pos]
		ordered_remove(&list.records, pos)
		ui_list_sort_value(L, list, record, &moved)
		lo, hi := 0, len(list.records)
		for lo < hi {
			mid := (lo + hi) / 2
			if ui_list_less(list, moved, list.records[mid]) {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		if len(list.records) == cap(list.records) {
			reserve(&list.records, 2 * cap(list.records) + 8)
		}
		inject_at(&list.records, lo, moved)
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
	record := list.records[pos]
	lua.L_unref(L, lua.REGISTRYINDEX, c.int(record.ref))
	ordered_remove(&list.records, pos)
	for dependent in list.dependents {
		if dep := ui_list_find(&editor.ui, dependent); dep != nil {
			text_key, text_value := delete_key(&dep.texts, record.key)
			delete(text_key)
			delete(text_value)
		}
	}
	delete(record.key)
	delete(record.sort_str)
	for i in pos ..< len(list.records) {
		list.positions[list.records[i].key] = i
	}
	ui_list_changed(editor, list)
	return 0
}

qed_list_clear :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_mutable(L, list)
	for record in list.records {
		lua.L_unref(L, lua.REGISTRYINDEX, c.int(record.ref))
		delete(record.key)
		delete(record.sort_str)
	}
	clear(&list.records)
	for dependent in list.dependents {
		if dep := ui_list_find(&editor.ui, dependent); dep != nil {
			for text_key, text_value in dep.texts {
				delete(text_key)
				delete(text_value)
			}
			clear(&dep.texts)
		}
	}
	ui_list_reindex(list)
	ui_list_changed(editor, list)
	return 0
}

ui_list_record_push :: proc(L: ^lua.State, editor: ^Editor, list: ^UiList, pos: int) {
	if !list.fuzzy {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(list.records[pos].ref))
		return
	}
	source := ui_list_find(&editor.ui, list.source)
	if source == nil {
		lua.pushnil(L)
		return
	}
	source_pos, ok := source.positions[list.matches[pos].key]
	if !ok {
		lua.pushnil(L)
		return
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(source.records[source_pos].ref))
}

qed_list_positions :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	list := api_ui_list_self(L, editor)
	ui_list_settle_all(editor, list)
	key := ui_list_key_arg(L, 2)
	if _, ok := list.positions[key]; !ok {
		lua.pushnil(L)
		return 1
	}
	offsets := fuzzy_positions(list.query, list.texts[key] or_else "")
	lua.createtable(L, c.int(len(offsets)), 0)
	for offset, i in offsets {
		lua.pushinteger(L, lua.Integer(offset + 1))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
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
	for &record in list.records {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(record.ref))
		ui_list_sort_value(L, list, -1, &record)
		lua.pop(L, 1)
	}
	context.user_ptr = list
	slice.stable_sort_by(list.records[:], proc(left, right: UiListRecord) -> bool {
		return ui_list_less((^UiList)(context.user_ptr), left, right)
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
	if !list.fuzzy {
		plugin_raise(L, "set_query is for qed.fuzzy.list lists")
	}
	query := api_string(L, 2)
	if query != list.query {
		delete(list.query)
		list.query = strings.clone(query)
		list.query_gen += 1
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
	if source.fuzzy {
		lua.L_argerror(L, 1, "a fuzzy list cannot be a source")
	}
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "table {field} expected")
	}
	field, has := api_field_string(L, 2, "field")
	if !has || field == "" {
		lua.L_argerror(L, 2, "field: the record field to match")
	}
	plugin := api_loaded(L, editor)
	lua.settop(L, 1)
	source_ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	list := api_ui_list_push(L, editor, plugin.name, true)
	list.source = source.id
	list.source_ref = source_ref
	list.field = strings.clone(field)
	list.fuzzy_dirty = true
	append(&source.dependents, list.id)
	for record in source.records {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(record.ref))
		lua.pushodinstring(L, field)
		lua.rawget(L, -2)
		text := ""
		if lua.type(L, -1) == .STRING {
			text, _ = lua.toodinstring(L, -1)
		}
		list.texts[strings.clone(record.key)] = strings.clone(text)
		lua.pop(L, 2)
	}
	return 1
}
