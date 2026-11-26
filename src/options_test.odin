package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:sys/posix"
import "core:testing"
import lua "lib:lua"

@(private = "file")
declare_src :: proc(src: string) -> (^Option, string) {
	L := lua.newstate(options_core_alloc, nil)
	defer lua.close(L)
	if lua.L_loadbuffer(L, raw_data(src), c.size_t(len(src)), "=test", "t") != .OK || lua.pcall(L, 0, 1, 0) != .OK {
		msg, _ := lua.toodinstring(L, -1)
		return nil, strings.clone(msg, context.temp_allocator)
	}
	context.allocator = context.temp_allocator
	return options_declare(L, -1, "qed.options")
}

@(private = "file")
merge_src :: proc(opt: ^Option, user: string) -> (json.Object, string) {
	v, err := json.parse_string(user, parse_integers = true, allocator = context.temp_allocator)
	assert(err == nil)
	problems := make([dynamic]string, context.temp_allocator)
	merged := option_merge(opt, opt.default, v, "plugins/p", &problems)
	return merged.(json.Object), strings.join(problems[:], ", ", context.temp_allocator)
}

@(test)
test_core_options_declare_every_knob :: proc(t: ^testing.T) {
	core := g_core_options
	testing.expect(t, core != nil && core.kind == .Record, "config/options.lua declares a record")
	for it in config_ints {
		opt := option_field(core, it.key)
		testing.expectf(t, opt != nil && opt.kind == .Int, "%s is an int option", it.key)
	}
	for it in config_bools {
		opt := option_field(core, it.key)
		testing.expectf(t, opt != nil && opt.kind == .Bool, "%s is a bool option", it.key)
	}
	lsp := option_field(core, "lsp")
	testing.expect(t, lsp != nil && lsp.kind == .Record, "lsp is a record")
	for it in config_lsp.ints {
		opt := option_field(lsp, it.key)
		testing.expectf(t, opt != nil && opt.kind == .Int, "lsp.%s is an int option", it.key)
	}
	for it in config_lsp.bools {
		opt := option_field(lsp, it.key)
		testing.expectf(t, opt != nil && opt.kind == .Bool, "lsp.%s is a bool option", it.key)
	}
	theme := option_field(core, "theme")
	testing.expect(t, theme != nil && theme.kind == .Choice && theme.choices_fn, "theme picks from a function")
	image := option_field(core, "image_protocol")
	testing.expect(t, image != nil && image.kind == .Choice && len(image.choices) == 3, "image_protocol has static choices")
	langs := option_field(core, "languages")
	testing.expect(t, langs != nil && langs.kind == .Map && langs.key.kind == .Choice && langs.key.choices_fn, "languages is keyed by a language choice")
	testing.expect(t, langs.value.kind == .Record && option_field(langs.value, "patterns").kind == .List, "a language is a record with a patterns list")
	testing.expect(t, len(g_config_defaults["languages"].(json.Object)) == len(langs.default.(json.Object)), "the language defaults come from the declaration")

	described :: proc(t: ^testing.T, opt: ^Option, name: string) {
		testing.expectf(t, opt.description != "", "%s has a description", name)
		if opt.kind == .Record {
			for f in opt.fields {
				described(t, f.option, fmt.tprintf("%s.%s", name, f.name))
			}
		}
		if opt.kind == .Map && opt.value.kind == .Record {
			for f in opt.value.fields {
				described(t, f.option, fmt.tprintf("%s.*.%s", name, f.name))
			}
		}
	}
	for f in core.fields {
		described(t, f.option, f.name)
	}
}

@(test)
test_core_defaults_from_declarations :: proc(t: ^testing.T) {
	testing.expect(t, g_config_defaults["tab_width"].(json.Integer) == 4, "tab_width default")
	testing.expect(t, g_config_defaults["image_protocol"].(json.String) == "auto", "image_protocol default")
	lsp := g_config_defaults["lsp"].(json.Object)
	testing.expect(t, lsp["completion_max_rows"].(json.Integer) == 8, "lsp record default composed from its fields")
	py := g_config_defaults["languages"].(json.Object)["python"].(json.Object)
	testing.expect(t, py["lsp"].(json.String) == "pyright-langserver --stdio", "map entry default")
	_, has_kb := g_config_defaults["keybinds"]
	testing.expect(t, !has_kb && g_keybind_defaults["core"].(json.Object)["copy"].(json.String) == "Ctrl+c", "keybinds come from config/keybinds.json")
}

@(test)
test_options_merge_validation :: proc(t: ^testing.T) {
	opt, err := declare_src(`return {
		on = {type = "bool", default = false},
		width = {type = "int", default = 5, min = 1, max = 10},
		mode = {type = "choice", choices = {"a", "b"}, default = "a"},
		names = {type = "list", of = "string", default = {"x"}},
		commands = {type = "map", key = {type = "choice", choices = {"python", "go"}}, value = "string", default = {python = "ruff"}},
		server = {type = "record", fields = {cmd = {type = "string", default = "s"}, port = {type = "int", default = 1}}},
	}`)
	testing.expectf(t, err == "", "declares: %s", err)
	if opt == nil {
		return
	}
	merged, problems := merge_src(opt, `{"on": true, "width": 7, "mode": "b", "names": ["y", "z"], "commands": {"go": "gofmt"}, "server": {"port": 2}}`)
	testing.expectf(t, problems == "", "a valid config has no problems: %s", problems)
	testing.expect(t, merged["on"].(json.Boolean) == true && merged["width"].(json.Integer) == 7 && merged["mode"].(json.String) == "b", "scalars")
	testing.expect(t, len(merged["names"].(json.Array)) == 2, "a list replaces")
	cmds := merged["commands"].(json.Object)
	testing.expect(t, cmds["python"].(json.String) == "ruff" && cmds["go"].(json.String) == "gofmt", "a map merges per key")
	server := merged["server"].(json.Object)
	testing.expect(t, server["cmd"].(json.String) == "s" && server["port"].(json.Integer) == 2, "a record merges per field")

	merged, problems = merge_src(opt, `{"stray": 1, "on": 1, "width": 11, "mode": "c", "names": ["y", 2], "commands": {"rust": "x", "go": 3}, "server": {"cmd": true, "host": "h"}}`)
	for want in ([?]string{
		`unknown "plugins/p/stray"`,
		`"plugins/p/on" (expected a boolean)`,
		`"plugins/p/width" (expected a whole number from 1 to 10)`,
		`"plugins/p/mode" (expected one of a, b)`,
		`"plugins/p/names/2" (expected a single-line string)`,
		`unknown "plugins/p/commands/rust"`,
		`"plugins/p/commands/go" (expected a single-line string)`,
		`"plugins/p/server/cmd" (expected a single-line string)`,
		`unknown "plugins/p/server/host"`,
	}) {
		testing.expectf(t, strings.contains(problems, want), "reports %s in %s", want, problems)
	}
	testing.expect(t, merged["on"].(json.Boolean) == false && merged["width"].(json.Integer) == 5 && merged["mode"].(json.String) == "a", "bad scalars keep the default")
	testing.expect(t, len(merged["names"].(json.Array)) == 1, "a list with a bad item keeps the default")
	testing.expect(t, len(merged["commands"].(json.Object)) == 1, "bad map entries are skipped")
	testing.expect(t, merged["server"].(json.Object)["cmd"].(json.String) == "s", "a bad record field keeps its default")

	merged, problems = merge_src(opt, `{"commands": {"python": null}, "names": "x", "server": 3}`)
	testing.expect(t, len(merged["commands"].(json.Object)) == 0, "null drops a map entry")
	testing.expect(t, strings.contains(problems, `"plugins/p/names" (expected a list)`) && strings.contains(problems, `"plugins/p/server" (expected an object)`), "compound type mismatches")
	text_opt, text_err := declare_src(`return {line = {type = "string"}, body = {type = "text"}}`)
	testing.expect(t, text_err == "", "string and text declare")
	_, text_problems := merge_src(text_opt, `{"line": "a\nb", "body": "a\nb"}`)
	testing.expectf(t, text_problems == `"plugins/p/line" (expected a single-line string)`, "a string refuses a newline, a text takes it: %s", text_problems)
	merged, problems = merge_src(opt, `{"width": 3.0}`)
	testing.expect(t, problems == "" && merged["width"].(json.Integer) == 3, "an integral float is a whole number")
}

@(test)
test_options_function_choices :: proc(t: ^testing.T) {
	opt, err := declare_src(`return {
		mode = {type = "choice", choices = function() return {"x", "y"} end, default = "x"},
		langs = {type = "map", key = {type = "choice", choices = function() return {"go"} end}, value = "string"},
	}`)
	testing.expectf(t, err == "", "declares: %s", err)
	if opt == nil {
		return
	}
	merged, problems := merge_src(opt, `{"mode": "z", "langs": {"rust": "r", "go": "g"}}`)
	testing.expectf(t, strings.contains(problems, `"plugins/p/mode" (expected one of x, y)`), "a value outside a function's choices warns: %s", problems)
	testing.expectf(t, strings.contains(problems, `unknown "plugins/p/langs/rust"`), "so does a map key: %s", problems)
	testing.expect(t, merged["mode"].(json.String) == "x" && len(merged["langs"].(json.Object)) == 1, "both keep the default")
	core_problems := make([dynamic]string, context.temp_allocator)
	user, _ := json.parse_string(`{"theme": "no-such-theme", "languages": {"klingon": {}}}`, parse_integers = true, allocator = context.temp_allocator)
	config_merge(user.(json.Object), &core_problems)
	joined := strings.join(core_problems[:], ", ", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, `"theme" (expected one of `) && strings.contains(joined, `unknown "languages/klingon"`), "core resolves its theme and language choices: %s", joined)
}

@(test)
test_options_nested_compounds :: proc(t: ^testing.T) {
	opt, err := declare_src(`return {
		languages = {type = "map", key = "string", value = {type = "record", fields = {
			patterns = {type = "list", of = "string"},
			lsp = {type = "string", default = ""},
		}}, default = {c = {patterns = {"*.c"}}}},
	}`)
	testing.expectf(t, err == "", "declares: %s", err)
	if opt == nil {
		return
	}
	c_entry := opt.default.(json.Object)["languages"].(json.Object)["c"].(json.Object)
	testing.expect(t, c_entry["lsp"].(json.String) == "", "a default entry is filled from the record's field defaults")
	merged, problems := merge_src(opt, `{"languages": {"c": {"lsp": "clangd"}, "zig": {"patterns": ["*.zig"]}, "go": {"patterns": [1]}}}`)
	langs := merged["languages"].(json.Object)
	testing.expect(t, len(langs["c"].(json.Object)["patterns"].(json.Array)) == 1 && langs["c"].(json.Object)["lsp"].(json.String) == "clangd", "a field override keeps its siblings")
	testing.expect(t, langs["zig"].(json.Object)["lsp"].(json.String) == "", "a new entry takes the value template's defaults")
	testing.expect(t, strings.contains(problems, `"plugins/p/languages/go/patterns/1" (expected a single-line string)`), "a nested item is checked")
}

@(test)
test_options_declaration_errors :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{`return {a = {type = "nope"}}`, "unknown type 'nope'"},
		{`return {a = {type = "int", default = "x"}}`, "a/default: expected a whole number"},
		{`return {a = {type = "int", default = 0, min = 1}}`, "a/default: expected a whole number >= 1"},
		{`return {a = {type = "choice", choices = {"x"}, default = "y"}}`, "a/default: expected one of x"},
		{`return {a = {type = "choice", choices = {}}}`, "choices must be a non-empty list"},
		{`return {a = {type = "record", fields = {b = "bool"}, default = {}}}`, "a record's default comes from its fields"},
		{`return {a = {type = "map", key = "int", value = "string"}}`, "a map key must be a string or a choice"},
		{`return {a = {type = "bool", desc = "typo"}}`, "unknown field 'desc' for a bool"},
		{`return {a = {type = "list", of = "list"}}`, "a list needs a declaration table"},
		{`return {a = {type = "list", of = "string", default = {1}}}`, "a/default/1: expected a single-line string"},
		{`return {a = {type = "choice", choices = function() return {"x"} end}}`, "a: a choice from a function needs a default"},
		{`return {a = {type = "list", of = {type = "choice", choices = function() return {"x"} end}}}`, ""},
		{`return {a = {type = "choice", choices = function() return {"x"} end, default = "y"}}`, "a/default: expected one of x"},
	}
	for tc in cases {
		_, err := declare_src(tc[0])
		testing.expectf(t, err == "" if tc[1] == "" else strings.contains(err, tc[1]), "%s raises %q, got %q", tc[0], tc[1], err)
	}
}

@(private = "file")
schema_menu_type :: proc(e: ^E2E, filter: string) {
	e2e_key(e, .Ctrl_A)
	e2e_type(e, filter)
	e2e_ui_settle(e)
}

@(private = "file")
schema_menu_user :: proc(t: ^testing.T, path: string) -> json.Object {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the config file exists")
	v, _ := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	plugins := v.(json.Object)["plugins"].(json.Object) or_else nil
	return plugins["shapes"].(json.Object) or_else nil
}

@(test)
e2e_settings_typed_compounds :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_schema_%d.json", tmp, posix.getpid())
	defer os.remove(path)
	e.ed.plugins.persist_path = path
	_ = os.write_entire_file(path, transmute([]u8)string(`{"plugins": {"shapes": {"servers": [{"name": "a", "port": 2, "on": true}], "tags": {"one": null}}}}`))
	e2e_plugin(&e, "shapes", `return {setup = function() qed.options{
		servers = {type = "list", of = {type = "record", fields = {name = "string", port = {type = "int", default = 1}, on = "bool"}}},
		groups = {type = "map", key = "string", value = {type = "map", key = "string", value = "string"}},
		tags = {type = "map", key = "string", value = "string", default = {one = "1", two = "2"}},
	} end}`)
	ft_run(&e.ed, "Settings: Open Config UI")
	e2e_ui_settle(&e)

	schema_menu_type(&e, "shapes.tags")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "1 entry") && e2e_grid_has(&e, "(removed)"), "a default entry dropped by null is gone, as core sees it, and listed as removed")
	testing.expect(t, e2e_grid_has(&e, "▎shapes.tags"), "and the map is marked as set")

	schema_menu_type(&e, "shapes.servers[1].port")
	e2e_key(&e, .Ctrl_D)
	e2e_ui_settle(&e)
	server := schema_menu_user(t, path)["servers"].(json.Array)[0].(json.Object)
	testing.expect(t, server["port"].(json.Integer) == 1 && server["name"].(json.String) == "a", "Ctrl+d resets an int field inside a list item")
	schema_menu_type(&e, "shapes.servers[1].name")
	e2e_key(&e, .Ctrl_D)
	e2e_ui_settle(&e)
	schema_menu_type(&e, "shapes.servers[1].on")
	e2e_key(&e, .Ctrl_D)
	e2e_ui_settle(&e)
	server = schema_menu_user(t, path)["servers"].(json.Array)[0].(json.Object)
	testing.expect(t, server["name"].(json.String) == "" && server["on"].(json.Boolean) == false, "and a string and a bool field")

	schema_menu_type(&e, "shapes.groups")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	e2e_type(&e, "y\n")
	e2e_ui_settle(&e)
	groups, ok := schema_menu_user(t, path)["groups"].(json.Object)
	_, entry_ok := groups["y"].(json.Object)
	testing.expect(t, ok && entry_ok, "a new entry of a map of maps is written as an empty object")
	e2e_key(&e, .Esc)
	e2e_key(&e, .Esc)
}
