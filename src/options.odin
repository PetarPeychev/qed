package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import lua "lib:lua"

OptionKind :: enum {
	Bool,
	Int,
	String,
	Text,
	Choice,
	List,
	Map,
	Record,
}

OPTION_KIND_NAMES := [OptionKind]string {
	.Bool   = "bool",
	.Int    = "int",
	.String = "string",
	.Text   = "text",
	.Choice = "choice",
	.List   = "list",
	.Map    = "map",
	.Record = "record",
}

Option :: struct {
	kind:           OptionKind,
	description:    string,
	default:        json.Value,
	min, max:       Maybe(int),
	choices:        []string,
	choices_fn:     bool,
	choices_c:      lua.CFunction,
	choices_ref:    c.int,
	resolved:       []string,
	resolved_ok:    bool,
	of, key, value: ^Option,
	fields:         []OptionField,
}

OptionField :: struct {
	name:   string,
	option: ^Option,
}

embedded_options_data := #load("../config/options.lua", string)

g_core_options: ^Option

option_field :: proc(opt: ^Option, name: string) -> ^Option {
	for f in opt.fields {
		if f.name == name {
			return f.option
		}
	}
	return nil
}

option_kind_of :: proc(name: string) -> (OptionKind, bool) {
	for kind_name, kind in OPTION_KIND_NAMES {
		if kind_name == name {
			return kind, true
		}
	}
	return .Bool, false
}

option_zero :: proc(opt: ^Option) -> json.Value {
	switch opt.kind {
	case .Bool:
		return json.Boolean(false)
	case .Int:
		n := 0
		if lo, ok := opt.min.?; ok && n < lo {
			n = lo
		}
		if hi, ok := opt.max.?; ok && n > hi {
			n = hi
		}
		return json.Integer(n)
	case .String, .Text:
		return json.String("")
	case .Choice:
		return json.String(opt.choices[0] if len(opt.choices) > 0 else "")
	case .List:
		return json.Array{}
	case .Map:
		return json.Object{}
	case .Record:
		obj := make(json.Object)
		for f in opt.fields {
			obj[f.name] = f.option.default
		}
		return obj
	}
	return nil
}

option_expected :: proc(opt: ^Option) -> string {
	switch opt.kind {
	case .Bool:
		return "a boolean"
	case .Int:
		lo, has_lo := opt.min.?
		hi, has_hi := opt.max.?
		switch {
		case has_lo && has_hi:
			return fmt.tprintf("a whole number from %d to %d", lo, hi)
		case has_lo:
			return fmt.tprintf("a whole number >= %d", lo)
		case has_hi:
			return fmt.tprintf("a whole number <= %d", hi)
		}
		return "a whole number"
	case .String:
		return "a single-line string"
	case .Text:
		return "a string"
	case .Choice:
		if opt.choices_fn {
			return fmt.tprintf("one of %s", strings.join(opt.resolved, ", ", context.temp_allocator)) if opt.resolved_ok else "a string"
		}
		return fmt.tprintf("one of %s", strings.join(opt.choices, ", ", context.temp_allocator))
	case .List:
		return "a list"
	case .Map, .Record:
		return "an object"
	}
	return ""
}

option_int_ok :: proc(opt: ^Option, n: i64) -> bool {
	if lo, ok := opt.min.?; ok && n < i64(lo) {
		return false
	}
	if hi, ok := opt.max.?; ok && n > i64(hi) {
		return false
	}
	return true
}

option_key_ok :: proc(opt: ^Option, key: string) -> bool {
	switch {
	case opt.kind != .Choice:
		return true
	case opt.choices_fn:
		return !opt.resolved_ok || slice.contains(opt.resolved, key)
	}
	return slice.contains(opt.choices, key)
}

// the config being loaded names the themes dir, so a test or reload of another path sees its own themes
g_options_config_path: string

option_theme_choices :: proc() -> []string {
	return theme_names(g_options_config_path if g_options_config_path != "" else config_path())
}

option_language_choices :: proc() -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for info, lang in LANGUAGES {
		if lang != .MarkdownInline {
			append(&names, info.name)
		}
	}
	return names[:]
}

// core's choice sources resolve in Odin, so the throwaway state and a plugin's qed.languages agree
option_choices_native :: proc(f: lua.CFunction) -> proc() -> []string {
	if f == lua.CFunction(options_core_themes) || f == lua.CFunction(qed_theme_list) {
		return option_theme_choices
	}
	if f == lua.CFunction(options_core_languages) || f == lua.CFunction(qed_languages) {
		return option_language_choices
	}
	return nil
}

option_resolved_set :: proc(opt: ^Option, names: []string, ok: bool) {
	for name in opt.resolved {
		delete(name, os.heap_allocator())
	}
	delete(opt.resolved, os.heap_allocator())
	opt.resolved, opt.resolved_ok = nil, ok
	if ok {
		opt.resolved = make([]string, len(names), os.heap_allocator())
		for name, i in names {
			opt.resolved[i] = strings.clone(name, os.heap_allocator())
		}
	}
}

// function choices keep their values (heap-owned) until the next resolve; a Lua function runs only with L
option_resolve :: proc(L: ^lua.State, opt: ^Option, path: string, problems: ^[dynamic]string) {
	if opt == nil {
		return
	}
	if opt.choices_fn {
		if native := option_choices_native(opt.choices_c); native != nil {
			option_resolved_set(opt, native(), true)
		} else if L != nil && opt.choices_ref != 0 {
			lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(opt.choices_ref))
			if lua.pcall(L, 0, 1, 0) != .OK {
				msg, _ := lua.toodinstring(L, -1)
				append(problems, fmt.tprintf("%q: its choices function failed (%s)", path, msg))
				option_resolved_set(opt, nil, false)
			} else if lua.type(L, -1) != .TABLE {
				append(problems, fmt.tprintf("%q: its choices function returned no list", path))
				option_resolved_set(opt, nil, false)
			} else {
				names := make([dynamic]string, context.temp_allocator)
				for i in 1 ..= lua.Integer(lua.rawlen(L, -1)) {
					if lua.rawgeti(L, -1, i) == .STRING {
						name, _ := lua.toodinstring(L, -1)
						append(&names, strings.clone(name, context.temp_allocator))
					}
					lua.pop(L, 1)
				}
				option_resolved_set(opt, names[:], true)
			}
			lua.pop(L, 1)
		}
	}
	option_resolve(L, opt.of, path, problems)
	option_resolve(L, opt.key, path, problems)
	option_resolve(L, opt.value, path, problems)
	for f in opt.fields {
		option_resolve(L, f.option, option_path_join(path, f.name), problems)
	}
}

// core's declarations come from a state that is closed after the parse, so only core's own sources may supply choices
option_lua_choices :: proc(opt: ^Option) -> bool {
	if opt == nil {
		return false
	}
	if opt.choices_fn && option_choices_native(opt.choices_c) == nil {
		return true
	}
	if option_lua_choices(opt.of) || option_lua_choices(opt.key) || option_lua_choices(opt.value) {
		return true
	}
	for f in opt.fields {
		if option_lua_choices(f.option) {
			return true
		}
	}
	return false
}

option_unref :: proc(L: ^lua.State, opt: ^Option) {
	if opt == nil {
		return
	}
	if opt.choices_ref != 0 {
		lua.L_unref(L, lua.REGISTRYINDEX, opt.choices_ref)
		opt.choices_ref = 0
	}
	option_resolved_set(opt, nil, false)
	option_unref(L, opt.of)
	option_unref(L, opt.key)
	option_unref(L, opt.value)
	for f in opt.fields {
		option_unref(L, f.option)
	}
}

option_scalar :: proc(opt: ^Option, v: json.Value) -> (json.Value, bool) {
	#partial switch opt.kind {
	case .Bool:
		_, ok := v.(json.Boolean)
		return v, ok
	case .Int:
		n: i64
		#partial switch x in v {
		case json.Integer:
			n = x
		case json.Float:
			if x != math.trunc(x) || abs(x) > 1e15 {
				return nil, false
			}
			n = i64(x)
		case:
			return nil, false
		}
		return json.Integer(n), option_int_ok(opt, n)
	case .String:
		s, ok := v.(json.String)
		return v, ok && !strings.contains_rune(string(s), '\n')
	case .Text:
		_, ok := v.(json.String)
		return v, ok
	case .Choice:
		s, ok := v.(json.String)
		return v, ok && option_key_ok(opt, string(s))
	}
	return nil, false
}

option_path_join :: proc(path, key: string) -> string {
	return key if path == "" else fmt.tprintf("%s/%s", path, key)
}

option_invalid :: proc(opt: ^Option, path: string) -> string {
	return fmt.tprintf("%q (expected %s)", path, option_expected(opt))
}

option_merge :: proc(opt: ^Option, base, user: json.Value, path: string, problems: ^[dynamic]string) -> json.Value {
	switch opt.kind {
	case .Bool, .Int, .String, .Text, .Choice:
		v, ok := option_scalar(opt, user)
		if !ok {
			append(problems, option_invalid(opt, path))
			return base
		}
		return v
	case .List:
		arr, ok := user.(json.Array)
		if !ok {
			append(problems, option_invalid(opt, path))
			return base
		}
		before := len(problems)
		out := make(json.Array, len(arr), context.temp_allocator)
		for item, i in arr {
			out[i] = option_merge(opt.of, opt.of.default, item, fmt.tprintf("%s/%d", path, i + 1), problems)
		}
		return base if len(problems) > before else out
	case .Map:
		obj, ok := user.(json.Object)
		if !ok {
			append(problems, option_invalid(opt, path))
			return base
		}
		out := make(json.Object, context.temp_allocator)
		for k, v in base.(json.Object) or_else nil {
			out[k] = v
		}
		for k, v in obj {
			child := option_path_join(path, k)
			if !option_key_ok(opt.key, k) {
				append(problems, config_unknown_msg(child))
				continue
			}
			if _, is_null := v.(json.Null); is_null {
				delete_key(&out, k)
				continue
			}
			before := len(problems)
			merged := option_merge(opt.value, out[k] if k in out else opt.value.default, v, child, problems)
			if k in out || len(problems) == before {
				out[k] = merged
			}
		}
		return out
	case .Record:
		obj, ok := user.(json.Object)
		if !ok {
			append(problems, option_invalid(opt, path))
			return base
		}
		out := make(json.Object, context.temp_allocator)
		for k, v in base.(json.Object) or_else nil {
			out[k] = v
		}
		for k, v in obj {
			child := option_path_join(path, k)
			field := option_field(opt, k)
			if field == nil {
				append(problems, config_unknown_msg(child))
				continue
			}
			out[k] = option_merge(field, out[k] if k in out else field.default, v, child, problems)
		}
		return out
	}
	return base
}

option_from_lua :: proc(L: ^lua.State, idx: c.int, opt: ^Option, path: string) -> (json.Value, string) {
	idx := lua.absindex(L, idx)
	lua.L_checkstack(L, 4, "value nested too deeply")
	bad := fmt.tprintf("%s: expected %s", path, option_expected(opt))
	switch opt.kind {
	case .Bool:
		if lua.type(L, idx) != .BOOLEAN {
			return nil, bad
		}
		return json.Boolean(lua.toboolean(L, idx)), ""
	case .Int:
		if lua.type(L, idx) != .NUMBER {
			return nil, bad
		}
		v: json.Value = json.Integer(lua.tointeger(L, idx)) if lua.isinteger(L, idx) else json.Float(lua.tonumberx(L, idx, nil))
		n, ok := option_scalar(opt, v)
		if !ok {
			return nil, bad
		}
		return n, ""
	case .String, .Text, .Choice:
		if lua.type(L, idx) != .STRING {
			return nil, bad
		}
		s, _ := lua.toodinstring(L, idx)
		if opt.kind == .Choice && !option_key_ok(opt, s) || opt.kind == .String && strings.contains_rune(s, '\n') {
			return nil, bad
		}
		return json.String(strings.clone(s)), ""
	case .List:
		if lua.type(L, idx) != .TABLE || !option_lua_sequence(L, idx) {
			return nil, bad
		}
		n := int(lua.rawlen(L, idx))
		arr := make(json.Array, n)
		for i in 1 ..= n {
			lua.rawgeti(L, idx, lua.Integer(i))
			v, err := option_from_lua(L, -1, opt.of, fmt.tprintf("%s/%d", path, i))
			lua.pop(L, 1)
			if err != "" {
				return nil, err
			}
			arr[i - 1] = v
		}
		return arr, ""
	case .Map, .Record:
		if lua.type(L, idx) != .TABLE {
			return nil, bad
		}
		obj := make(json.Object)
		lua.pushnil(L)
		for lua.next(L, idx) != 0 {
			if lua.type(L, -2) != .STRING {
				lua.pop(L, 2)
				return nil, fmt.tprintf("%s: keys must be strings", path)
			}
			k, _ := lua.toodinstring(L, -2)
			child := fmt.tprintf("%s/%s", path, k)
			sub := opt.value
			if opt.kind == .Record {
				sub = option_field(opt, k)
				if sub == nil {
					lua.pop(L, 2)
					return nil, fmt.tprintf("%s: unknown field '%s'", path, k)
				}
			} else if !option_key_ok(opt.key, k) {
				lua.pop(L, 2)
				return nil, fmt.tprintf("%s: key '%s' is not %s", path, k, option_expected(opt.key))
			}
			v, err := option_from_lua(L, -1, sub, child)
			if err != "" {
				lua.pop(L, 2)
				return nil, err
			}
			obj[strings.clone(k)] = v
			lua.pop(L, 1)
		}
		if opt.kind == .Record {
			for f in opt.fields {
				if f.name not_in obj {
					obj[f.name] = f.option.default
				}
			}
		}
		return obj, ""
	}
	return nil, bad
}

option_lua_sequence :: proc(L: ^lua.State, idx: c.int) -> bool {
	n := lua.Integer(lua.rawlen(L, idx))
	count: lua.Integer
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		count += 1
		is_index := lua.isinteger(L, -2) && lua.tointeger(L, -2) >= 1 && lua.tointeger(L, -2) <= n
		lua.pop(L, 1)
		if !is_index {
			lua.pop(L, 1)
			return false
		}
	}
	return count == n
}

OPTION_FIELDS := [OptionKind][]string {
	.Bool   = {},
	.Int    = {"min", "max"},
	.String = {},
	.Text   = {},
	.Choice = {"choices"},
	.List   = {"of"},
	.Map    = {"key", "value"},
	.Record = {"fields"},
}

option_parse :: proc(L: ^lua.State, idx: c.int, path: string, in_compound := false) -> (^Option, string) {
	idx := lua.absindex(L, idx)
	top := lua.gettop(L)
	lua.L_checkstack(L, 8, "declaration nested too deeply")
	fail :: proc(L: ^lua.State, top: c.int, msg: string) -> (^Option, string) {
		lua.settop(L, top)
		return nil, msg
	}
	opt := new(Option)
	type_name: string
	#partial switch lua.type(L, idx) {
	case .STRING:
		type_name, _ = lua.toodinstring(L, idx)
	case .TABLE:
		if lua.getfield(L, idx, "type") != .STRING {
			return fail(L, top, fmt.tprintf("%s: type expected", path))
		}
		type_name, _ = lua.toodinstring(L, -1)
		type_name = strings.clone(type_name, context.temp_allocator)
		lua.pop(L, 1)
	case:
		return fail(L, top, fmt.tprintf("%s: declaration table or type name expected", path))
	}
	kind, known := option_kind_of(type_name)
	if !known {
		return fail(L, top, fmt.tprintf("%s: unknown type '%s'", path, type_name))
	}
	opt.kind = kind
	if lua.type(L, idx) == .STRING {
		if kind == .Choice || kind == .List || kind == .Map || kind == .Record {
			return fail(L, top, fmt.tprintf("%s: a %s needs a declaration table", path, type_name))
		}
		opt.default = option_zero(opt)
		lua.newtable(L)
		option_push(L, lua.gettop(L), opt, type_name)
		return opt, ""
	}

	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		lua.pop(L, 1)
		if lua.type(L, -1) != .STRING {
			return fail(L, top, fmt.tprintf("%s: unknown field '%s' for a %s", path, lua.L_tostring(L, -1), type_name))
		}
		name, _ := lua.toodinstring(L, -1)
		if name != "type" && name != "description" && name != "default" && !slice.contains(OPTION_FIELDS[kind], name) {
			return fail(L, top, fmt.tprintf("%s: unknown field '%s' for a %s", path, name, type_name))
		}
	}
	#partial switch lua.getfield(L, idx, "description") {
	case .NIL:
	case .STRING:
		s, _ := lua.toodinstring(L, -1)
		opt.description = strings.clone(s)
	case:
		return fail(L, top, fmt.tprintf("%s: description must be a string", path))
	}
	lua.pop(L, 1)

	lua.newtable(L)
	norm := lua.gettop(L)
	switch kind {
	case .Bool, .String, .Text:
	case .Int:
		for bound in ([2]cstring{"min", "max"}) {
			t := lua.getfield(L, idx, bound)
			if t == .NIL {
				lua.pop(L, 1)
				continue
			}
			if !lua.isinteger(L, -1) {
				return fail(L, top, fmt.tprintf("%s: %s must be a whole number", path, bound))
			}
			n := int(lua.tointeger(L, -1))
			if bound == "min" {
				opt.min = n
			} else {
				opt.max = n
			}
			lua.setfield(L, norm, bound)
		}
		if lo, ok := opt.min.?; ok {
			if hi, hok := opt.max.?; hok && lo > hi {
				return fail(L, top, fmt.tprintf("%s: min is above max", path))
			}
		}
	case .Choice:
		#partial switch lua.getfield(L, idx, "choices") {
		case .FUNCTION:
			opt.choices_fn = true
			opt.choices_c = lua.tocfunction(L, -1)
			if option_choices_native(opt.choices_c) == nil {
				lua.pushvalue(L, -1)
				opt.choices_ref = lua.L_ref(L, lua.REGISTRYINDEX)
			}
			unchecked := make([dynamic]string, context.temp_allocator)
			option_resolve(L, opt, path, &unchecked)
		case .TABLE:
			n := int(lua.rawlen(L, -1))
			if n == 0 || !option_lua_sequence(L, lua.gettop(L)) {
				return fail(L, top, fmt.tprintf("%s: choices must be a non-empty list of strings or a function", path))
			}
			choices := make([]string, n)
			for i in 1 ..= n {
				if lua.rawgeti(L, -1, lua.Integer(i)) != .STRING {
					return fail(L, top, fmt.tprintf("%s: choices must be a non-empty list of strings or a function", path))
				}
				s, _ := lua.toodinstring(L, -1)
				choices[i - 1] = strings.clone(s)
				lua.pop(L, 1)
			}
			opt.choices = choices
		case:
			return fail(L, top, fmt.tprintf("%s: choices must be a non-empty list of strings or a function", path))
		}
		lua.setfield(L, norm, "choices")
	case .List:
		lua.getfield(L, idx, "of")
		of, err := option_parse(L, -1, fmt.tprintf("%s/of", path), true)
		if err != "" {
			return fail(L, top, err)
		}
		opt.of = of
		lua.setfield(L, norm, "of")
		lua.pop(L, 1)
	case .Map:
		for part in ([2]cstring{"key", "value"}) {
			lua.getfield(L, idx, part)
			sub, err := option_parse(L, -1, fmt.tprintf("%s/%s", path, part), true)
			if err != "" {
				return fail(L, top, err)
			}
			if part == "key" {
				if sub.kind != .String && sub.kind != .Choice {
					return fail(L, top, fmt.tprintf("%s/key: a map key must be a string or a choice", path))
				}
				opt.key = sub
			} else {
				opt.value = sub
			}
			lua.setfield(L, norm, part)
			lua.pop(L, 1)
		}
	case .Record:
		if lua.getfield(L, idx, "fields") != .TABLE {
			return fail(L, top, fmt.tprintf("%s: fields table expected", path))
		}
		fields_idx := lua.gettop(L)
		lua.newtable(L)
		fields := make([dynamic]OptionField)
		lua.pushnil(L)
		for lua.next(L, fields_idx) != 0 {
			if lua.type(L, -2) != .STRING {
				return fail(L, top, fmt.tprintf("%s: field names must be strings", path))
			}
			k, _ := lua.toodinstring(L, -2)
			name := strings.clone(k)
			sub, err := option_parse(L, -1, fmt.tprintf("%s/%s", path, name), in_compound)
			if err != "" {
				return fail(L, top, err)
			}
			append(&fields, OptionField{name, sub})
			lua.setfield(L, fields_idx + 1, strings.clone_to_cstring(name, context.temp_allocator))
			lua.pop(L, 1)
		}
		slice.sort_by(fields[:], proc(a, b: OptionField) -> bool {return a.name < b.name})
		opt.fields = fields[:]
		lua.setfield(L, norm, "fields")
		lua.pop(L, 1)
	}

	if lua.getfield(L, idx, "default") == .NIL {
		if opt.choices_fn && !in_compound {
			return fail(L, top, fmt.tprintf("%s: a choice from a function needs a default", path))
		}
		opt.default = option_zero(opt)
	} else if kind == .Record {
		return fail(L, top, fmt.tprintf("%s: a record's default comes from its fields", path))
	} else {
		v, err := option_from_lua(L, -1, opt, fmt.tprintf("%s/default", path))
		if err != "" {
			return fail(L, top, err)
		}
		opt.default = v
	}
	lua.pop(L, 1)
	option_push(L, norm, opt, type_name)
	return opt, ""
}

option_push :: proc(L: ^lua.State, norm: c.int, opt: ^Option, type_name: string) {
	lua.pushodinstring(L, type_name)
	lua.setfield(L, norm, "type")
	lua.pushodinstring(L, opt.description)
	lua.setfield(L, norm, "description")
	plugin_json_push(L, opt.default)
	lua.setfield(L, norm, "default")
}

options_declare :: proc(L: ^lua.State, idx: c.int, label: string) -> (^Option, string) {
	idx := lua.absindex(L, idx)
	lua.L_checkstack(L, 4, "declaration nested too deeply")
	opt := new(Option)
	opt.kind = .Record
	fields := make([dynamic]OptionField)
	lua.newtable(L)
	norm := lua.gettop(L)
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		if lua.type(L, -2) != .STRING {
			lua.settop(L, norm - 1)
			return nil, fmt.tprintf("%s: option names must be strings", label)
		}
		k, _ := lua.toodinstring(L, -2)
		name := strings.clone(k)
		sub, err := option_parse(L, -1, fmt.tprintf("%s: %s", label, name))
		if err != "" {
			lua.settop(L, norm - 1)
			return nil, err
		}
		append(&fields, OptionField{name, sub})
		lua.setfield(L, norm, strings.clone_to_cstring(name, context.temp_allocator))
		lua.pop(L, 1)
	}
	slice.sort_by(fields[:], proc(a, b: OptionField) -> bool {return a.name < b.name})
	opt.fields = fields[:]
	opt.default = option_zero(opt)
	return opt, ""
}

options_core_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	if nsize == 0 {
		libc.free(ptr)
		return nil
	}
	return libc.realloc(ptr, nsize)
}

options_core_capture :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	context.allocator = os.heap_allocator()
	opt, err := options_declare(L, 1, "config/options.lua")
	if err != "" {
		lua.pushodinstring(L, err)
		return lua.error(L)
	}
	if option_lua_choices(opt) {
		lua.pushodinstring(L, "config/options.lua: choices may only be qed.theme.list or qed.languages")
		return lua.error(L)
	}
	g_core_options = opt
	return 0
}

options_core_themes :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushodinstring(L, "themes")
	return 1
}

options_core_languages :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushodinstring(L, "languages")
	return 1
}

options_core_run :: proc "c" (L: ^lua.State) -> c.int {
	lua.createtable(L, 0, 3)
	lua.pushcfunction(L, options_core_capture)
	lua.setfield(L, -2, "options")
	lua.pushcfunction(L, options_core_languages)
	lua.setfield(L, -2, "languages")
	lua.createtable(L, 0, 1)
	lua.pushcfunction(L, options_core_themes)
	lua.setfield(L, -2, "list")
	lua.setfield(L, -2, "theme")
	lua.pushglobaltable(L)
	lua.insert(L, -2)
	lua.setfield(L, -2, "qed")
	lua.pop(L, 1)
	if lua.L_loadbuffer(L, raw_data(embedded_options_data), c.size_t(len(embedded_options_data)), "=config/options.lua", "t") != .OK {
		return lua.error(L)
	}
	lua.call(L, 0, 0)
	return 0
}

// a throwaway state: its theme and language functions only name core's sources (option_choices_native)
options_core_declare :: proc() -> ^Option {
	L := lua.newstate(options_core_alloc, nil)
	assert(L != nil, "config/options.lua: no Lua state")
	defer lua.close(L)
	lua.pushcfunction(L, options_core_run)
	if lua.pcall(L, 0, 0, 0) != .OK {
		msg, _ := lua.toodinstring(L, -1)
		fmt.panicf("config/options.lua: %s", msg)
	}
	assert(g_core_options != nil, "config/options.lua must call qed.options")
	return g_core_options
}

option_at :: proc(opt: ^Option, keys: []string) -> ^Option {
	opt := opt
	for key in keys {
		if opt == nil {
			return nil
		}
		#partial switch opt.kind {
		case .Record:
			opt = option_field(opt, key)
		case .Map:
			opt = opt.value
		case .List:
			opt = opt.of
		case:
			return nil
		}
	}
	return opt
}

// a Lua table carries no list-or-object bit, so an empty one takes its declared shape
option_shape :: proc(opt: ^Option, v: json.Value) -> json.Value {
	#partial switch opt.kind {
	case .List:
		#partial switch x in v {
		case json.Object:
			if len(x) == 0 {
				return json.Array{}
			}
		case json.Array:
			for item, i in x {
				x[i] = option_shape(opt.of, item)
			}
		}
	case .Map, .Record:
		#partial switch x in v {
		case json.Array:
			if len(x) == 0 {
				return make(json.Object, context.temp_allocator)
			}
		case json.Object:
			obj := x
			for k, item in obj {
				sub := opt.value if opt.kind == .Map else option_field(opt, k)
				if sub != nil {
					obj[k] = option_shape(sub, item)
				}
			}
		}
	}
	return v
}
