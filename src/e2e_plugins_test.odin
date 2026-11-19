package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import lua "lib:lua"
import "lib:tb2"

@(private = "file")
g_pt: ^E2E
@(private = "file")
g_pt_target: string

@(private = "file")
PtCase :: struct {
	tests: c.int,
	name:  string,
}

@(private = "file")
pt_api := [?]lua.L_Reg {
	{"key", pt_key},
	{"type", pt_type},
	{"step", pt_step},
	{"wait", pt_wait},
	{"expect_line", pt_expect_line},
	{"expect_cell", pt_expect_cell},
	{"eq", pt_eq},
	{"ok", pt_ok},
	{"fake_spawn", pt_fake_spawn},
	{"config", pt_config},
	{"open", pt_open},
	{"stub", pt_stub},
	{"message", pt_message},
	{"log_has", pt_log_has},
	{"editor", pt_editor},
	{"poll_disk", pt_poll_disk},
	{"pump", pt_pump},
	{"hook_timeout", pt_hook_timeout},
	{"module", pt_module},
	{"ui", pt_ui},
	{"config_path", pt_config_path},
	{nil, nil},
}

@(private = "file")
pt_key :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	s := api_string(L, 1)
	ev := tb2.Event{type = .Key}
	switch s {
	case "Enter":
		ev.key = .Enter
	case "Esc":
		ev.key = .Esc
	case "Tab":
		ev.key = .Tab
	case "Backspace":
		ev.key = .Backspace2
	case "Up":
		ev.key = .Arrow_Up
	case "Down":
		ev.key = .Arrow_Down
	case "Shift+Up":
		ev.key = .Arrow_Up
		ev.mod = .Shift
	case "Shift+Down":
		ev.key = .Arrow_Down
		ev.mod = .Shift
	case "Left":
		ev.key = .Arrow_Left
	case "Right":
		ev.key = .Arrow_Right
	case:
		key, alt, ok := parse_keybind(s)
		if !ok {
			return plugin_raise(L, fmt.tprintf("t.key: unknown key '%s'", s))
		}
		if alt != 0 {
			ev.mod = .Alt
			ev.ch = alt
		} else {
			ev.key = key
		}
	}
	e2e_step(g_pt, ev)
	return 0
}

@(private = "file")
pt_type :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	e2e_type(g_pt, api_string(L, 1))
	return 0
}

@(private = "file")
pt_step :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	plugin_pump(&g_pt.ed)
	return 0
}

@(private = "file")
pt_wait :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	if lua.type(L, 1) != .FUNCTION {
		lua.L_argerror(L, 1, "condition function expected")
	}
	max_ms := api_int(L, 2, "milliseconds expected") if lua.type(L, 2) > .NIL else 5000
	start := time.tick_now()
	for {
		lua.pushvalue(L, 1)
		lua.call(L, 0, 1)
		done := lua.toboolean(L, -1)
		lua.pop(L, 1)
		if done {
			return 0
		}
		if ms_since(start) > f64(max_ms) {
			return plugin_raise(L, fmt.tprintf("t.wait timed out after %d ms", max_ms))
		}
		plugin_pump(&g_pt.ed)
		time.sleep(time.Millisecond)
	}
}

@(private = "file")
pt_expect_line :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	row := api_int(L, 1, "row expected")
	want := api_string(L, 2)
	b, _ := api_buf(L, entry.editor, 3)
	if row < 1 || row > len(b.lines) {
		return plugin_raise(L, fmt.tprintf("line %d: out of range 1..%d", row, len(b.lines)))
	}
	got := string(b.lines[row - 1].text[:])
	if got != want {
		return plugin_raise(L, fmt.tprintf("line %d: got %q, want %q", row, got, want))
	}
	return 0
}

@(private = "file")
pt_expect_cell :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	x := api_int(L, 1, "x expected")
	y := api_int(L, 2, "y expected")
	want, _ := utf8.decode_rune_in_string(api_string(L, 3))
	e2e_render(g_pt)
	if got := e2e_cell(g_pt, x, y); got != want {
		return plugin_raise(L, fmt.tprintf("cell (%d,%d): got %q, want %q", x, y, got, want))
	}
	return 0
}

@(private = "file")
pt_show :: proc(L: ^lua.State, idx: c.int) -> string {
	s, _ := lua.toodinstring_any(L, idx)
	s = strings.clone(s, context.temp_allocator)
	lua.pop(L, 1)
	if lua.type(L, idx) == .STRING {
		return fmt.tprintf("%q", s)
	}
	return s
}

@(private = "file")
pt_eq :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	lua.settop(L, 3)
	got, want := pt_show(L, 1), pt_show(L, 2)
	if lua.type(L, 1) != lua.type(L, 2) || got != want {
		what, _ := lua.toodinstring(L, 3)
		return plugin_raise(L, fmt.tprintf("%s: got %s, want %s", what if what != "" else "t.eq", got, want))
	}
	return 0
}

@(private = "file")
pt_ok :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	if !lua.toboolean(L, 1) {
		what, _ := lua.toodinstring(L, 2)
		return plugin_raise(L, what if what != "" else "t.ok failed")
	}
	return 0
}

@(private = "file")
pt_fake_spawn :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	pattern := strings.clone(api_string(L, 1), context.temp_allocator)
	f := PluginFake {
		pattern = pattern,
	}
	if lua.type(L, 2) == .TABLE {
		f.stdout, _ = api_field_string(L, 2, "stdout")
		f.stderr, _ = api_field_string(L, 2, "stderr")
		f.code, _ = api_field_int(L, 2, "code")
		f.delay_ms, _ = api_field_int(L, 2, "delay_ms")
	}
	e2e_spawn_fake(g_pt, f.pattern, f.stdout, f.code, f.delay_ms, f.stderr)
	return 0
}

@(private = "file")
pt_config :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "config table expected")
	}
	sb := strings.builder_make(context.temp_allocator)
	if err := api_json_write(L, 1, &sb, 0); err != "" {
		return plugin_raise(L, err)
	}
	hot := false
	if lua.type(L, 2) == .TABLE {
		lua.getfield(L, 2, "hot")
		hot = bool(lua.toboolean(L, -1))
	}
	e2e_plugin_config(g_pt, g_pt_target, strings.to_string(sb), hot)
	return 0
}

@(private = "file")
pt_pump :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	ms := api_int(L, 1, "milliseconds expected")
	start := time.tick_now()
	for ms_since(start) < f64(ms) {
		plugin_pump(&g_pt.ed)
		time.sleep(time.Millisecond)
	}
	return 0
}

@(private = "file")
pt_hook_timeout :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	PLUGIN_HOOK_TIMEOUT_MS = api_int(L, 1, "milliseconds expected")
	return 0
}

@(private = "file")
pt_module :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	on := bool(lua.toboolean(L, 2))
	switch api_string(L, 1) {
	case "lsp":
		LSP_ENABLED = on
	case "ai":
		AI_ENABLED = on
	case "git":
		GIT_ENABLED = on
	case:
		return plugin_raise(L, "t.module: lsp, ai or git expected")
	}
	return 0
}

@(private = "file")
pt_open :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path, _ := filepath.join({g_pt.dir, api_string(L, 1)}, context.temp_allocator)
	content := api_string(L, 2) if lua.type(L, 2) > .NIL else ""
	path_ensure_parent_dir(path)
	_ = os.write_entire_file(path, transmute([]u8)content)
	if !editor_open_path(entry.editor, path) {
		return plugin_raise(L, fmt.tprintf("t.open: cannot open %s", path))
	}
	lua.pushinteger(L, lua.Integer(editor_buffer(entry.editor).id))
	return 1
}

@(private = "file")
pt_stub :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	e2e_seq += 1
	path := fmt.tprintf("%s/stub_%d.sh", g_pt.dir, e2e_seq)
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("#!/bin/sh\n%s\n", api_string(L, 1)))
	e2e_run(fmt.tprintf("chmod +x %s", shell_quote(path)))
	lua.pushodinstring(L, shell_quote(path))
	return 1
}

@(private = "file")
pt_level_name := [LogLevel]string {
	.Debug = "debug",
	.Info  = "info",
	.Warn  = "warn",
	.Error = "error",
}

@(private = "file")
pt_message :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, entry.editor.message)
	lua.pushodinstring(L, pt_level_name[entry.editor.message_level])
	lua.pushodinstring(L, entry.editor.message_source)
	return 3
}

@(private = "file")
pt_log_has :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	level := api_string(L, 1)
	source := api_string(L, 2)
	needle := api_string(L, 3)
	found := false
	for e in entry.editor.log {
		found ||= pt_level_name[e.level] == level && e.source == source && strings.contains(e.text, needle)
	}
	lua.pushboolean(L, b32(found))
	return 1
}

@(private = "file")
pt_editor :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	ed := entry.editor
	lua.createtable(L, 0, 8)
	lua.pushboolean(L, b32(ed.quit))
	lua.setfield(L, -2, "quit")
	lua.pushboolean(L, b32(ed.welcome))
	lua.setfield(L, -2, "welcome")
	switch {
	case ed.quit_dialog.active:
		lua.pushodinstring(L, "quit")
	case ed.close_dialog.active:
		lua.pushodinstring(L, "close")
	case ed.conflict_dialog.active:
		lua.pushodinstring(L, "conflict")
	case:
		lua.pushnil(L)
	}
	lua.setfield(L, -2, "dialog")
	lua.pushboolean(L, b32(!ed.welcome && editor_buffer(ed).disk_conflict))
	lua.setfield(L, -2, "disk_conflict")
	lua.pushboolean(L, b32(ed.terminal.active))
	lua.setfield(L, -2, "terminal")
	lua.pushboolean(L, b32(ed.filetree.active))
	lua.setfield(L, -2, "tree")
	if pn := &ed.plugins.pane; pn.active {
		lua.createtable(L, 0, 3)
		lua.pushodinstring(L, pn.title)
		lua.setfield(L, -2, "title")
		lua.pushodinstring(L, pn.footer)
		lua.setfield(L, -2, "footer")
		lua.createtable(L, c.int(len(pn.lines)), 0)
		for l, i in pn.lines {
			lua.createtable(L, 0, 2)
			lua.pushodinstring(L, l.text)
			lua.setfield(L, -2, "text")
			lua.pushodinstring(L, l.color)
			lua.setfield(L, -2, "color")
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		lua.setfield(L, -2, "lines")
		lua.setfield(L, -2, "pane")
	}
	return 1
}

@(private = "file")
pt_poll_disk :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor_poll_disk(entry.editor)
	return 0
}

@(private = "file")
pt_ui :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	ui := &p.ui
	if !ui.active {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 4)
	kinds := [PluginUiKind]string{.Pick = "pick", .Prompt = "prompt", .Confirm = "confirm"}
	lua.pushodinstring(L, kinds[ui.kind])
	lua.setfield(L, -2, "kind")
	lua.pushodinstring(L, textfield_str(&ui.field))
	lua.setfield(L, -2, "query")
	lua.pushinteger(L, lua.Integer(len(ui.matches)))
	lua.setfield(L, -2, "matches")
	if ui.kind == .Confirm {
		lua.pushodinstring(L, ui.labels[ui.selected])
		lua.setfield(L, -2, "selected")
	} else if len(ui.matches) > 0 {
		lua.pushodinstring(L, ui.labels[ui.matches[ui.selected]])
		lua.setfield(L, -2, "selected")
	}
	return 1
}

@(private = "file")
pt_config_path :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, entry.editor.plugins.persist_path)
	return 1
}

@(private = "file")
pt_load_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	args := (^PluginLoad)(lua.touserdata(L, 1))
	plugin_env_create(L, args.pl)
	if lua.L_loadbuffer(L, raw_data(args.src), c.size_t(len(args.src)), plugin_chunkname(args.pl, args.pl.main), "t") != .OK {
		return lua.error(L)
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(args.pl.env))
	lua.setupvalue(L, -2, 1)
	lua.call(L, 0, 1)
	if lua.type(L, -1) != .TABLE {
		return plugin_raise(L, fmt.tprintf("%s must return a table of test functions", args.pl.main))
	}
	return 1
}

@(private = "file")
pt_case_c :: proc "c" (L: ^lua.State) -> c.int {
	context = plugin_entry(L).ctx
	tc := (^PtCase)(lua.touserdata(L, 1))
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(tc.tests))
	lua.pushodinstring(L, tc.name)
	lua.rawget(L, -2)
	lua.newtable(L)
	lua.L_setfuncs(L, raw_data(pt_api[:]), 0)
	lua.call(L, 1, 0)
	return 0
}

@(private = "file")
pt_session :: proc(e: ^E2E, name: string, test: PluginFile) -> (tests: c.int, names: []string, err: string) {
	e2e_enter()
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.aprintf("%s/qed_e2e_plug %d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(dir)
	file := fmt.aprintf("%s/start.txt", dir)
	_ = os.write_entire_file(file, nil)
	e^ = E2E{ed = editor_init(file, headless = true), path = file, dir = dir}
	e.ed.plugins.persist_path = fmt.aprintf("%s/config.json", dir)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(dir)
	g_pt = e
	g_pt_target = name
	p := &e.ed.plugins
	pl := plugins_add(p, Plugin{name = fmt.tprintf("%s_test", name), dir = name, main = test.path}, true)
	args := PluginLoad{pl, test.data}
	lua.pushcfunction(p.L, pt_load_c)
	lua.pushlightuserdata(p.L, &args)
	ok, msg, tb := plugin_call(&e.ed, 1, 1)
	if !ok {
		return 0, nil, fmt.tprintf("%s\n%s", msg, tb)
	}
	list := make([dynamic]string, context.temp_allocator)
	lua.pushnil(p.L)
	for lua.next(p.L, -2) != 0 {
		if lua.type(p.L, -2) == .STRING && lua.type(p.L, -1) == .FUNCTION {
			k, _ := lua.toodinstring(p.L, -2)
			append(&list, strings.clone(k, context.temp_allocator))
		}
		lua.pop(p.L, 1)
	}
	slice.sort(list[:])
	return lua.L_ref(p.L, lua.REGISTRYINDEX), list[:], ""
}

PT_PLUGINS :: #directory + "/../plugins"

@(private = "file")
pt_plugin_dirs :: proc() -> []string {
	infos, _ := os.read_directory_by_path(PT_PLUGINS, -1, context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if info.type == .Directory && os.exists(fmt.tprintf("%s/%s/init.lua", PT_PLUGINS, info.name)) {
			append(&dirs, strings.clone(info.name, context.temp_allocator))
		}
	}
	slice.sort(dirs[:])
	return dirs[:]
}

@(test)
e2e_plugins_test_lua :: proc(t: ^testing.T) {
	testing.expect(t, len(pt_plugin_dirs()) > 0, "found the bundled plugin dirs")
	for name in pt_plugin_dirs() {
		data, err := os.read_entire_file(fmt.tprintf("%s/%s/test.lua", PT_PLUGINS, name), context.temp_allocator)
		if err != nil {
			continue
		}
		f := PluginFile{fmt.tprintf("%s/test.lua", name), string(data)}
		count := 1
		for i := 0; i < count; i += 1 {
			e: E2E
			tests, names, serr := pt_session(&e, name, f)
			if serr != "" {
				testing.expectf(t, false, "plugins/%s: %s", f.path, serr)
				e2e_stop(&e)
				break
			}
			count = len(names)
			if count == 0 {
				testing.expectf(t, false, "plugins/%s defines no tests", f.path)
				e2e_stop(&e)
				break
			}
			saved_timeout, saved_lsp, saved_ai, saved_git := PLUGIN_HOOK_TIMEOUT_MS, LSP_ENABLED, AI_ENABLED, GIT_ENABLED
			saved_theme := strings.clone(THEME, context.temp_allocator)
			saved_reg := clipboard_register
			clipboard_register = ""
			tc := PtCase{tests, names[i]}
			lua.pushcfunction(e.ed.plugins.L, pt_case_c)
			lua.pushlightuserdata(e.ed.plugins.L, &tc)
			ok, msg, tb := plugin_call(&e.ed, 1, 0)
			if !ok {
				testing.expectf(t, false, "plugins/%s %s: %s\n%s", f.path, names[i], msg, tb)
			} else if pl := plugin_find(&e.ed.plugins, name); pl != nil && pl.last_error != "" {
				testing.expectf(t, false, "plugins/%s %s: plugin error: %s", f.path, names[i], pl.last_error)
			}
			PLUGIN_HOOK_TIMEOUT_MS, LSP_ENABLED, AI_ENABLED, GIT_ENABLED = saved_timeout, saved_lsp, saved_ai, saved_git
			delete(clipboard_register)
			clipboard_register = saved_reg
			if THEME != saved_theme || e.ed.theme_shown != "" {
				delete(THEME, os.heap_allocator())
				THEME = strings.clone(saved_theme, os.heap_allocator())
				editor_theme_set(&e.ed, saved_theme, false)
			}
			e2e_stop(&e)
		}
	}
}

@(test)
plugins_bundled_dirs_complete :: proc(t: ^testing.T) {
	for dir in pt_plugin_dirs() {
		files, _ := os.read_directory_by_path(fmt.tprintf("%s/%s", PT_PLUGINS, dir), -1, context.temp_allocator)
		for f in files {
			if !strings.has_suffix(f.name, ".lua") || f.name == "test.lua" {
				continue
			}
			path := fmt.tprintf("%s/%s", dir, f.name)
			listed := false
			for b in bundled_plugin_dir_files {
				listed ||= b.path == path
			}
			testing.expectf(t, listed, "plugins/%s is not embedded: add it to bundled_plugin_dir_files in plugin.odin", path)
		}
	}
	for b in g_bundled_plugins {
		testing.expectf(t, !strings.has_suffix(b.path, "/test.lua"), "%s must not be embedded", b.path)
	}
}
