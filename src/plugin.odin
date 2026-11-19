package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import lua "lib:lua"
import "lib:tb2"

PLUGIN_TABLE_DEPTH_MAX :: 32
PLUGIN_DIR_DEPTH_MAX :: 8

PluginState :: enum {
	Enabled,
	Disabled,
	Errored,
}

Plugin :: struct {
	name:       string,
	display:    string,
	meta_set:   bool,
	bundled:    bool,
	dir:        string,
	main:       string,
	state:      PluginState,
	env:        c.int,
	cfg:        c.int,
	defaults:   c.int,
	load_ms:    f64,
	last_error: string,
	stamp:      u64,
	cfg_sig:    string,
	unknown:    string,
}

PluginFile :: struct {
	path: string,
	data: string,
}

PluginMem :: struct {
	used, cap: int,
}

Plugins :: struct {
	L:        ^lua.State,
	mem:      ^PluginMem,
	list:     [dynamic]Plugin,
	commands: [dynamic]Command,
	bundled:  []PluginFile,
	init_ms:  f64,
	loading:  bool,
	config_override: Maybe(json.Object),
	edit_depth: int,
	tasks:    [dynamic]PluginTask,
	pool:     [dynamic]PluginPooled,
	hooks:    [dynamic]PluginHook,
	subs:     [PluginEvent]int,
	timers:   [dynamic]PluginTimer,
	procs:    [dynamic]PluginProc,
	saves:    [dynamic]PluginSave,
	queue:    [dynamic]PluginQueued,
	fakes:    [dynamic]PluginFake,
	lsp_results: [dynamic]PluginLspResult,
	slice:    PluginSlice,
	seq:      u64,
	presave:  u64,
	resumes:  int,
	startup_due: bool,
	current:  ^lua.State,
	ui:       PluginUi,
	pane:     PluginPane,
	persist_path: string,
	theme_owner: string,
	names:    [dynamic]string,
	user_dir: string,
	bound:    bool,
	applying: bool,
	setup:    ^Plugin,
	colors:   [dynamic]string,
	deco_ns:  [dynamic]PluginNs,
	ns_seq:   u32,
	status:   [dynamic]PluginStatus,
}

PluginEntry :: struct {
	editor: ^Editor,
	ctx:    runtime.Context,
}

bundled_plugin_files := #load_directory("../plugins")

// Listed file by file so a dir plugin's test.lua stays out of the binary.
bundled_plugin_dir_files := [?]PluginFile {
	{"format/init.lua", #load("../plugins/format/init.lua", string)},
	{"git/init.lua", #load("../plugins/git/init.lua", string)},
	{"git/picker.lua", #load("../plugins/git/picker.lua", string)},
	{"git/repo.lua", #load("../plugins/git/repo.lua", string)},
	{"git/tree.lua", #load("../plugins/git/tree.lua", string)},
	{"pickers/init.lua", #load("../plugins/pickers/init.lua", string)},
	{"search/init.lua", #load("../plugins/search/init.lua", string)},
	{"tasks/init.lua", #load("../plugins/tasks/init.lua", string)},
}

g_bundled_plugins: []PluginFile

@(init)
plugin_bundled_init :: proc "contextless" () {
	context = runtime.default_context()
	files := make([dynamic]PluginFile, os.heap_allocator())
	for f in bundled_plugin_files {
		append(&files, PluginFile{strings.clone(f.name, os.heap_allocator()), string(f.data)})
	}
	for f in bundled_plugin_dir_files {
		append(&files, PluginFile{strings.clone(f.path, os.heap_allocator()), f.data})
	}
	g_bundled_plugins = files[:]
}

@(fini)
plugin_bundled_destroy :: proc "contextless" () {
	context = runtime.default_context()
	for f in g_bundled_plugins {
		delete(f.path, os.heap_allocator())
	}
	delete(g_bundled_plugins, os.heap_allocator())
}

plugin_user_dir :: proc(allocator := context.temp_allocator) -> string {
	dir := config_dir(config_path())
	if dir == "" {
		return ""
	}
	return fmt.aprintf("%s/plugins", dir, allocator = allocator)
}

plugin_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	mem := (^PluginMem)(ud)
	old := int(osize) if ptr != nil else 0
	if nsize == 0 {
		if ptr != nil {
			mem.used -= old
			libc.free(ptr)
		}
		return nil
	}
	if mem.cap > 0 && int(nsize) > old && mem.used - old + int(nsize) > mem.cap {
		return nil
	}
	p := libc.realloc(ptr, nsize)
	if p == nil {
		return nil
	}
	mem.used += int(nsize) - old
	return p
}

plugin_msgh :: proc "c" (L: ^lua.State) -> c.int {
	msg := lua.tolstring(L, 1, nil)
	context = runtime.default_context()
	if msg != nil && strings.contains(string(msg), "\nstack traceback:") {
		return 1
	}
	if msg == nil {
		msg = lua.L_tostring(L, 1)
	}
	lua.L_traceback(L, L, msg, 1)
	return 1
}

plugin_panic :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	msg, _ := lua.toodinstring(L, -1)
	tb2.shutdown()
	fmt.eprintfln("qed: unrecoverable Lua error: %s", msg)
	os.exit(1)
}

plugin_openlibs :: proc "c" (L: ^lua.State) -> c.int {
	lua.L_openlibs(L)
	return 0
}

plugins_open :: proc(p: ^Plugins, mem_cap: int) -> bool {
	start := time.tick_now()
	p.mem = new(PluginMem)
	p.mem.cap = mem_cap
	p.L = lua.newstate(plugin_alloc, p.mem)
	if p.L == nil {
		free(p.mem)
		p.mem = nil
		return false
	}
	lua.atpanic(p.L, plugin_panic)
	lua.getextraspace(p.L)^ = nil
	lua.sethook(p.L, plugin_hook, lua.MASKCOUNT, PLUGIN_HOOK_COUNT)
	lua.pushcfunction(p.L, plugin_openlibs)
	if lua.pcall(p.L, 0, 0, 0) != .OK {
		lua.close(p.L)
		p.L = nil
		free(p.mem)
		p.mem = nil
		return false
	}
	p.init_ms = ms_since(start)
	return true
}

plugins_shutdown :: proc(p: ^Plugins) {
	plugin_ui_destroy(p)
	delete(p.persist_path)
	plugin_sched_shutdown(p)
	for &cmd in p.commands {
		plugin_command_free(&cmd)
	}
	delete(p.commands)
	for &pl in p.list {
		plugin_strings_free(&pl)
	}
	delete(p.list)
	for name in p.names {
		delete(name)
	}
	delete(p.names)
	delete(p.user_dir)
	for k in p.colors {
		delete(k)
	}
	delete(p.colors)
	for ns in p.deco_ns {
		delete(ns.name)
	}
	delete(p.deco_ns)
	for st in p.status {
		plugin_status_free(st)
	}
	delete(p.status)
	if p.L != nil {
		lua.close(p.L)
	}
	free(p.mem)
	p^ = {}
}

editor_plugins_start :: proc(editor: ^Editor, bundled: []PluginFile, user_dir: string, mem_cap: int) {
	p := &editor.plugins
	if !plugins_open(p, mem_cap) {
		editor_log(editor, .Error, "Plugins", "Lua failed to start, plugins disabled")
		return
	}
	p.bundled = bundled
	p.user_dir = strings.clone(user_dir)
	start := time.tick_now()
	for pl in plugins_scan(editor, user_dir, true) {
		plugins_add(p, pl, pl.bundled)
	}
	for &pl in p.list {
		plugin_load(editor, &pl)
	}
	plugins_config_warn(editor)
	p.startup_due = true
	editor_log(
		editor,
		.Debug,
		"Plugins",
		fmt.tprintf("Lua init %.2f ms, %d plugin(s) loaded in %.2f ms", p.init_ms, len(p.list), ms_since(start)),
	)
}

plugins_scan :: proc(editor: ^Editor, user_dir: string, warn: bool) -> []Plugin {
	p := &editor.plugins
	bundled := make([dynamic]Plugin, context.temp_allocator)
	for f in p.bundled {
		slash := strings.index_byte(f.path, '/')
		if slash < 0 && strings.has_suffix(f.path, ".lua") {
			append(&bundled, Plugin{name = f.path[:len(f.path) - 4], main = f.path, bundled = true})
		} else if slash > 0 && f.path[slash:] == "/init.lua" {
			append(&bundled, Plugin{name = f.path[:slash], dir = f.path[:slash], main = f.path, bundled = true})
		}
	}
	user := make([dynamic]Plugin, context.temp_allocator)
	if user_dir != "" {
		if infos, err := os.read_directory_by_path(user_dir, -1, context.temp_allocator); err == nil {
			for info in infos {
				if strings.has_prefix(info.name, ".") {
					continue
				}
				fi := plugin_stat_follow(info)
				if fi.type == .Directory {
					main := fmt.tprintf("%s/%s/init.lua", user_dir, info.name)
					if os.exists(main) {
						dir := fmt.tprintf("%s/%s", user_dir, info.name)
						append(&user, Plugin{name = info.name, dir = dir, main = main, stamp = plugin_dir_stamp(dir)})
					}
				} else if strings.has_suffix(info.name, ".lua") {
					main := fmt.tprintf("%s/%s", user_dir, info.name)
					append(&user, Plugin{name = info.name[:len(info.name) - 4], main = main, stamp = plugin_stamp_mix(0, main, fi)})
				}
			}
		}
	}
	by_name :: proc(a, b: Plugin) -> bool {return a.name < b.name || (a.name == b.name && a.dir < b.dir)}
	slice.sort_by(bundled[:], by_name)
	slice.sort_by(user[:], by_name)
	out := make([dynamic]Plugin, context.temp_allocator)
	for pl in bundled {
		shadowed := false
		for u in user {
			if u.name == pl.name {
				shadowed = true
			}
		}
		if !shadowed {
			append(&out, pl)
		}
	}
	for pl, i in user {
		if i > 0 && user[i - 1].name == pl.name {
			if warn {
				editor_log(editor, .Warn, "Plugins", fmt.tprintf("both %s.lua and %s/ exist, loading %s", pl.name, pl.name, user[i - 1].main))
			}
			continue
		}
		append(&out, pl)
	}
	return out[:]
}

plugin_stat_follow :: proc(info: os.File_Info) -> os.File_Info {
	if info.type != .Symlink {
		return info
	}
	fi, err := os.stat(info.fullpath, context.temp_allocator)
	return fi if err == nil else info
}

plugin_stamp_mix :: proc(h: u64, path: string, fi: os.File_Info) -> u64 {
	x := hash.fnv64a(transmute([]u8)path)
	x ~= u64(time.time_to_unix_nano(fi.modification_time)) * 0x9E3779B97F4A7C15
	x ~= u64(fi.size) * 0xC2B2AE3D27D4EB4F
	return h + x
}

plugin_file_stamp :: proc(path: string) -> u64 {
	fi, err := os.stat(path, context.temp_allocator)
	return plugin_stamp_mix(0, path, fi) if err == nil else 0
}

plugin_stamp_of :: proc(pl: Plugin) -> u64 {
	if pl.bundled {
		return 0
	}
	return plugin_dir_stamp(pl.dir) if pl.dir != "" else plugin_file_stamp(pl.main)
}

plugin_dir_stamp :: proc(dir: string, depth := 0) -> u64 {
	if depth > PLUGIN_DIR_DEPTH_MAX {
		return 0
	}
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return 0
	}
	h: u64
	for info in infos {
		if strings.has_prefix(info.name, ".") {
			continue
		}
		if info.type == .Directory {
			h += plugin_dir_stamp(info.fullpath, depth + 1)
		} else if info.type == .Regular && strings.has_suffix(info.name, ".lua") {
			h = plugin_stamp_mix(h, info.fullpath, info)
		}
	}
	return h
}

plugin_name_intern :: proc(p: ^Plugins, name: string) -> string {
	for n in p.names {
		if n == name {
			return n
		}
	}
	append(&p.names, strings.clone(name))
	return p.names[len(p.names) - 1]
}

plugin_strings_free :: proc(pl: ^Plugin) {
	delete(pl.display)
	delete(pl.dir)
	delete(pl.main)
	delete(pl.last_error)
	delete(pl.cfg_sig)
	delete(pl.unknown)
}

plugins_add :: proc(p: ^Plugins, pl: Plugin, bundled: bool) -> ^Plugin {
	append(&p.list, Plugin {
		name    = plugin_name_intern(p, pl.name),
		bundled = bundled,
		dir     = strings.clone(pl.dir),
		main    = strings.clone(pl.main),
		stamp   = pl.stamp,
		env      = lua.NOREF,
		cfg      = lua.NOREF,
		defaults = lua.NOREF,
	})
	pl := &p.list[len(p.list) - 1]
	plugin_display_reset(pl)
	return pl
}

plugin_title_case :: proc(id: string, allocator := context.allocator) -> string {
	b := make([]u8, len(id), allocator)
	up := true
	for i in 0 ..< len(id) {
		ch := id[i]
		switch {
		case ch == '_':
			ch = ' '
			up = true
		case up && ch >= 'a' && ch <= 'z':
			ch -= 'a' - 'A'
			up = false
		case:
			up = false
		}
		b[i] = ch
	}
	return string(b)
}

plugin_display_reset :: proc(pl: ^Plugin) {
	delete(pl.display)
	pl.display = plugin_title_case(pl.name)
	pl.meta_set = false
}

plugin_label :: proc(p: ^Plugins, owner: string) -> string {
	if pl := plugin_find(p, owner); pl != nil {
		return pl.display
	}
	return owner
}

plugin_find :: proc(p: ^Plugins, name: string) -> ^Plugin {
	for &pl in p.list {
		if pl.name == name {
			return &pl
		}
	}
	return nil
}

plugin_source :: proc(p: ^Plugins, pl: ^Plugin, path: string) -> (string, bool) {
	if pl.bundled {
		for f in p.bundled {
			if f.path == path {
				return f.data, true
			}
		}
		return "", false
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

plugin_chunkname :: proc(pl: ^Plugin, path: string) -> cstring {
	if pl.bundled {
		return fmt.ctprintf("@plugins/%s", path)
	}
	return fmt.ctprintf("@%s", path)
}

plugin_cfg_entry :: proc(cfg: json.Object, name: string) -> json.Object {
	plugins, _ := cfg["plugins"].(json.Object)
	entry, _ := plugins[name].(json.Object)
	return entry
}

plugin_cfg_enabled :: proc(name: string, cfg_user: json.Object) -> bool {
	if v, ok := plugin_cfg_entry(cfg_user, name)["enabled"].(json.Boolean); ok {
		return bool(v)
	}
	if v, ok := plugin_cfg_entry(g_config_defaults, name)["enabled"].(json.Boolean); ok {
		return bool(v)
	}
	return true
}

plugins_config_warn :: proc(editor: ^Editor) {
	plugins, _ := editor_config_user(editor)["plugins"].(json.Object)
	problems := make([dynamic]string, context.temp_allocator)
	for name in plugins {
		if plugin_find(&editor.plugins, name) == nil {
			append(&problems, fmt.tprintf("unknown plugins/%q", name))
		}
	}
	if len(problems) > 0 {
		slice.sort(problems[:])
		editor_log(editor, .Warn, "", fmt.tprintf("config.json: ignoring %s", strings.join(problems[:], ", ", context.temp_allocator)))
	}
}

plugin_keys_warn :: proc(editor: ^Editor, pl: ^Plugin) {
	if pl.state != .Enabled {
		return
	}
	problems := make([dynamic]string, context.temp_allocator)
	if pl.unknown != "" {
		append(&problems, fmt.tprintf("unknown %s", pl.unknown))
	}
	kb_v, has_kb := plugin_cfg_entry(editor_config_user(editor), pl.name)["keybinds"]
	kb, kb_ok := kb_v.(json.Object)
	if has_kb && !kb_ok {
		append(&problems, fmt.tprintf("plugins/%s/keybinds", pl.name))
	}
	unknown := make([dynamic]string, context.temp_allocator)
	for key in kb {
		found := false
		for cmd in editor.plugins.commands {
			found ||= cmd.owner == pl.name && cmd.config_name == key
		}
		if !found {
			append(&unknown, fmt.tprintf("plugins/%s/keybinds/%q", pl.name, key))
		}
	}
	if len(unknown) > 0 {
		slice.sort(unknown[:])
		append(&problems, fmt.tprintf("unknown %s", strings.join(unknown[:], ", ", context.temp_allocator)))
	}
	if len(problems) > 0 {
		editor_log(editor, .Warn, "", fmt.tprintf("config.json: ignoring %s", strings.join(problems[:], ", ", context.temp_allocator)))
	}
}

plugin_enter :: proc(editor: ^Editor, entry: ^PluginEntry) -> rawptr {
	slot := lua.getextraspace(editor.plugins.L)
	prev := slot^
	entry^ = {editor, context}
	slot^ = entry
	return prev
}

plugin_leave :: proc(editor: ^Editor, prev: rawptr) {
	lua.getextraspace(editor.plugins.L)^ = prev
}

plugin_entry :: proc "c" (L: ^lua.State) -> ^PluginEntry {
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.RIDX_MAINTHREAD)
	main := lua.tothread(L, -1)
	lua.pop(L, 1)
	return (^PluginEntry)(lua.getextraspace(main)^)
}

plugin_unavailable :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushodinstring(L, "qed API unavailable here")
	return lua.error(L)
}

plugin_call :: proc(editor: ^Editor, nargs, nresults: c.int) -> (ok: bool, message, traceback: string) {
	L := editor.plugins.L
	base := lua.gettop(L) - nargs
	lua.pushcfunction(L, plugin_msgh)
	lua.insert(L, base)
	entry: PluginEntry
	prev := plugin_enter(editor, &entry)
	prev_current := editor.plugins.current
	editor.plugins.current = L
	status := lua.pcall(L, nargs, nresults, base)
	editor.plugins.current = prev_current
	plugin_leave(editor, prev)
	if status == .OK {
		lua.remove(L, base)
		return true, "", ""
	}
	full, _ := lua.toodinstring(L, -1)
	full = strings.clone(full, context.temp_allocator)
	lua.settop(L, base - 1)
	if i := strings.index(full, "\nstack traceback:"); i >= 0 {
		return false, full[:i], full[i + 1:]
	}
	return false, full, ""
}

plugin_error :: proc(editor: ^Editor, pl: ^Plugin, message, traceback: string, disable: bool) {
	delete(pl.last_error)
	pl.last_error = strings.clone(message)
	editor_log(editor, .Error, pl.display, message)
	if traceback != "" {
		editor_log(editor, .Debug, pl.display, traceback)
	}
	if disable {
		plugin_unload(editor, pl)
		pl.state = .Errored
	}
}

PluginLoad :: struct {
	pl:  ^Plugin,
	src: string,
}

plugin_load :: proc(editor: ^Editor, pl: ^Plugin, check_enabled := true) {
	p := &editor.plugins
	delete(pl.cfg_sig)
	pl.cfg_sig = strings.clone(plugin_cfg_sig(pl.name, editor_config_user(editor)))
	if check_enabled && !plugin_cfg_enabled(pl.name, editor_config_user(editor)) {
		pl.state = .Disabled
		return
	}
	pl.state = .Enabled
	delete(pl.last_error)
	pl.last_error = ""
	start := time.tick_now()
	defer pl.load_ms = ms_since(start)
	if p.L == nil {
		plugin_error(editor, pl, "Lua is not running", "", false)
		pl.state = .Errored
		return
	}
	src, found := plugin_source(p, pl, pl.main)
	if !found {
		plugin_error(editor, pl, fmt.tprintf("cannot read %s", pl.main), "", true)
		return
	}
	args := PluginLoad{pl, src}
	lua.pushcfunction(p.L, plugin_load_c)
	lua.pushlightuserdata(p.L, &args)
	p.loading = true
	prev_slice := plugin_slice_begin(p, .Setup)
	ok, msg, tb := plugin_call(editor, 1, 0)
	killed := plugin_slice_end(editor, prev_slice, pl.name, .Setup, "setup")
	p.loading = false
	p.setup = nil
	if killed {
		ok, msg, tb = false, fmt.tprintf("setup exceeded its %.0f ms budget", plugin_budgets[.Setup].hard_ms), ""
	}
	if !ok {
		plugin_error(editor, pl, msg, tb, true)
		return
	}
	editor_log(editor, .Debug, "Plugins", fmt.tprintf("loaded %s (%s) in %.2f ms", pl.name, "bundled" if pl.bundled else "user", ms_since(start)))
	if !p.applying {
		plugin_keys_warn(editor, pl)
	}
	if p.bound && !p.startup_due {
		plugin_queue(editor, {event = .Startup, only = pl.name})
	}
}

plugin_reload :: proc(editor: ^Editor, pl: ^Plugin) {
	if pl.state == .Enabled {
		plugin_unload(editor, pl)
	}
	plugin_load(editor, pl)
}

plugin_reload_report :: proc(editor: ^Editor, pl: ^Plugin, what: string) {
	if pl.state == .Enabled {
		editor_log(editor, .Info, pl.display, what)
	}
}

plugin_cfg_sig :: proc(name: string, cfg_user: json.Object) -> string {
	entry := plugin_cfg_entry(cfg_user, name)
	rest := make(json.Object, context.temp_allocator)
	for k, v in entry {
		if k != "enabled" && k != "keybinds" {
			rest[k] = v
		}
	}
	sb := strings.builder_make(context.temp_allocator)
	json_write_value(&sb, rest, 0)
	return strings.to_string(sb)
}

plugin_subscribed :: proc(p: ^Plugins, name: string, event: PluginEvent) -> bool {
	for h in p.hooks {
		if h.owner == name && h.event == event {
			return true
		}
	}
	return false
}

plugins_poll :: proc(editor: ^Editor) -> bool {
	p := &editor.plugins
	if p.L == nil || p.user_dir == "" {
		return false
	}
	want := plugins_scan(editor, p.user_dir, false)
	same := len(want) == len(p.list)
	for w, i in want {
		if !same {
			break
		}
		pl := p.list[i]
		same = pl.name == w.name && pl.bundled == w.bundled && pl.main == w.main && pl.stamp == w.stamp
	}
	if same {
		return false
	}
	plugins_sync(editor, want)
	return true
}

plugins_sync :: proc(editor: ^Editor, want: []Plugin) {
	p := &editor.plugins
	match :: proc(pl: Plugin, w: Plugin) -> bool {
		return pl.name == w.name && pl.bundled == w.bundled && pl.main == w.main
	}
	kept := make([]int, len(p.list), context.temp_allocator)
	for &pl, i in p.list {
		kept[i] = -1
		for w, j in want {
			if match(pl, w) {
				kept[i] = j
			}
		}
		changed := kept[i] < 0 || want[kept[i]].stamp != pl.stamp
		if changed && pl.state == .Enabled {
			plugin_unload(editor, &pl)
		}
		if kept[i] < 0 && pl.state != .Disabled {
			editor_log(editor, .Info, pl.display, "unloaded")
		}
	}
	next := make([dynamic]Plugin, 0, len(want))
	loads := make([dynamic]string, context.temp_allocator)
	reloads := make([dynamic]bool, context.temp_allocator)
	for w, j in want {
		found := -1
		for k, i in kept {
			if k == j {
				found = i
			}
		}
		if found < 0 {
			append(&next, Plugin{name = plugin_name_intern(p, w.name), bundled = w.bundled, dir = strings.clone(w.dir), main = strings.clone(w.main), stamp = w.stamp, env = lua.NOREF, cfg = lua.NOREF, defaults = lua.NOREF})
			plugin_display_reset(&next[len(next) - 1])
			append(&loads, w.name)
			append(&reloads, false)
			continue
		}
		pl := p.list[found]
		if pl.stamp != w.stamp {
			pl.stamp = w.stamp
			append(&loads, w.name)
			append(&reloads, true)
		}
		append(&next, pl)
	}
	for &pl, i in p.list {
		if kept[i] < 0 {
			plugin_strings_free(&pl)
		}
	}
	selected := ""
	if pl := pluginview_selected(editor); pl != nil {
		selected = pl.name
	}
	delete(p.list)
	p.list = next
	for pl, i in p.list {
		if pl.name == selected {
			editor.pluginview.selected = i
		}
	}
	for name, i in loads {
		pl := plugin_find(p, name)
		plugin_load(editor, pl)
		plugin_reload_report(editor, pl, "reloaded" if reloads[i] else "loaded")
	}
}

plugins_config_sync :: proc(editor: ^Editor) {
	p := &editor.plugins
	if p.L == nil {
		return
	}
	cfg := editor_config_user(editor)
	for i in 0 ..< len(p.list) {
		pl := &p.list[i]
		want := plugin_cfg_enabled(pl.name, cfg)
		switch {
		case want == (pl.state == .Disabled):
			plugin_enabled_set(editor, pl, want)
		case pl.cfg_sig == plugin_cfg_sig(pl.name, cfg):
		case pl.state != .Disabled && (pl.state == .Errored || !plugin_subscribed(p, pl.name, .Config_Changed)):
			plugin_reload(editor, pl)
			plugin_reload_report(editor, pl, "reloaded (config changed)")
		case:
			delete(pl.cfg_sig)
			pl.cfg_sig = strings.clone(plugin_cfg_sig(pl.name, cfg))
		}
	}
}

plugins_config_apply :: proc(editor: ^Editor, theme_changed: bool, parsed := true) {
	p := &editor.plugins
	p.applying = true
	plugins_config_refresh(editor)
	if parsed {
		plugins_config_sync(editor)
	}
	plugin_queue(editor, {event = .Config_Changed})
	if theme_changed {
		plugin_queue(editor, {event = .Theme_Changed})
	}
	plugin_flush(editor)
	p.applying = false
	plugins_rebind(editor)
	for &pl in p.list {
		plugin_keys_warn(editor, &pl)
	}
	plugins_config_warn(editor)
}

plugin_load_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	args := (^PluginLoad)(lua.touserdata(L, 1))
	pl := args.pl
	plugin_env_create(L, pl)
	if lua.L_loadbuffer(L, raw_data(args.src), c.size_t(len(args.src)), plugin_chunkname(pl, pl.main), "t") != .OK {
		return lua.error(L)
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.env))
	lua.setupvalue(L, -2, 1)
	lua.call(L, 0, 1)
	if lua.type(L, -1) != .TABLE {
		return plugin_raise(L, fmt.tprintf("%s must return a table {setup}", pl.main))
	}
	spec := lua.gettop(L)
	lua.pushodinstring(L, "setup")
	setup_type := lua.rawget(L, spec)
	if setup_type != .FUNCTION && setup_type != .NIL {
		return plugin_raise(L, "spec.setup must be a function")
	}
	lua.pushnil(L)
	plugin_config_push(entry.editor, pl, lua.gettop(L))
	lua.settop(L, spec + 1)
	if setup_type == .NIL {
		return 0
	}
	entry.editor.plugins.setup = pl
	lua.call(L, 0, 0)
	entry.editor.plugins.setup = nil
	return 0
}

plugin_config_refresh_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	pl := (^Plugin)(lua.touserdata(L, 1))
	if pl.defaults != lua.NOREF {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.defaults))
	} else {
		lua.pushnil(L)
	}
	plugin_config_push(entry.editor, pl, lua.gettop(L))
	return 0
}

plugins_config_refresh :: proc(editor: ^Editor) {
	p := &editor.plugins
	if p.L == nil {
		return
	}
	for &pl in p.list {
		if pl.state != .Enabled || pl.cfg == lua.NOREF {
			continue
		}
		lua.pushcfunction(p.L, plugin_config_refresh_c)
		lua.pushlightuserdata(p.L, &pl)
		if ok, msg, tb := plugin_call(editor, 1, 0); !ok {
			plugin_error(editor, &pl, msg, tb, false)
		}
	}
}

plugin_unload :: proc(editor: ^Editor, pl: ^Plugin) {
	p := &editor.plugins
	plugin_ui_unload(editor, pl.name)
	plugin_sched_unload(editor, pl.name)
	term_unload(editor, pl.name)
	plugin_deco_unload(editor, pl.name)
	plugin_status_unload(p, pl.name)
	diffbase_unload(editor, pl.name)
	filetree_provider_unload(editor, pl.name)
	for i := len(p.commands) - 1; i >= 0; i -= 1 {
		if p.commands[i].owner == pl.name {
			plugin_command_remove(editor, i)
		}
	}
	if pl.env != lua.NOREF {
		lua.L_unref(p.L, lua.REGISTRYINDEX, pl.env)
		pl.env = lua.NOREF
	}
	if pl.cfg != lua.NOREF {
		lua.L_unref(p.L, lua.REGISTRYINDEX, pl.cfg)
		pl.cfg = lua.NOREF
	}
	if pl.defaults != lua.NOREF {
		lua.L_unref(p.L, lua.REGISTRYINDEX, pl.defaults)
		pl.defaults = lua.NOREF
	}
	// Twice: a __gc object survives one cycle and its closure keeps the env alive.
	lua.gc(p.L, .COLLECT)
	lua.gc(p.L, .COLLECT)
	plugin_display_reset(pl)
}

plugin_env_create :: proc(L: ^lua.State, pl: ^Plugin) {
	lua.newtable(L)
	env := lua.gettop(L)
	lua.newtable(L)
	lua.pushglobaltable(L)
	lua.setfield(L, -2, "__index")
	lua.setmetatable(L, env)

	plugin_qed_push(L, pl.name)
	lua.setfield(L, env, "qed")

	lua.pushodinstring(L, pl.name)
	lua.newtable(L)
	lua.pushcclosure(L, plugin_require, 2)
	lua.setfield(L, env, "require")

	lua.pushodinstring(L, pl.name)
	lua.pushcclosure(L, plugin_print, 1)
	lua.setfield(L, env, "print")

	pl.env = lua.L_ref(L, lua.REGISTRYINDEX)
}

plugin_raise :: proc(L: ^lua.State, msg: string) -> c.int {
	lua.pushodinstring(L, msg)
	return lua.error(L)
}

plugin_owner :: proc(L: ^lua.State, editor: ^Editor) -> ^Plugin {
	name, _ := lua.toodinstring(L, lua.upvalueindex(1))
	return plugin_find(&editor.plugins, name)
}

plugin_require :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return plugin_unavailable(L)
	}
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	pl := plugin_owner(L, editor)
	name, _ := lua.toodinstring(L, 1)
	if lua.type(L, 1) != .STRING || name == "" {
		return lua.L_argerror(L, 1, "module name expected")
	}
	lua.settop(L, 1)
	if lua.getfield(L, lua.upvalueindex(2), lua.tolstring(L, 1, nil)) != .NIL {
		return 1
	}
	lua.pop(L, 1)
	lua.getfield(L, lua.REGISTRYINDEX, lua.LOADED_TABLE)
	if lua.getfield(L, -1, lua.tolstring(L, 1, nil)) != .NIL {
		return 1
	}
	lua.pop(L, 2)
	if pl == nil || pl.dir == "" {
		return plugin_raise(L, fmt.tprintf("module '%s' not found (single-file plugins can only require standard libraries)", name))
	}
	parts := strings.split(name, ".", context.temp_allocator)
	for part in parts {
		if part == "" || strings.contains_any(part, "/\\") {
			return plugin_raise(L, fmt.tprintf("invalid module name '%s'", name))
		}
	}
	rel := strings.join(parts, "/", context.temp_allocator)
	candidates := [2]string{fmt.tprintf("%s/%s.lua", pl.dir, rel), fmt.tprintf("%s/%s/init.lua", pl.dir, rel)}
	for path in candidates {
		src, ok := plugin_source(p, pl, path)
		if !ok {
			continue
		}
		if lua.L_loadbuffer(L, raw_data(src), c.size_t(len(src)), plugin_chunkname(pl, path), "t") != .OK {
			return lua.error(L)
		}
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.env))
		lua.setupvalue(L, -2, 1)
		lua.pushvalue(L, 1)
		lua.call(L, 1, 1)
		if lua.type(L, -1) == .NIL {
			lua.pop(L, 1)
			lua.pushboolean(L, true)
		}
		lua.pushvalue(L, 1)
		lua.pushvalue(L, -2)
		lua.rawset(L, lua.upvalueindex(2))
		return 1
	}
	return plugin_raise(L, fmt.tprintf("module '%s' not found in %s", name, pl.dir))
}

plugin_log_level :: proc(s: string) -> (LogLevel, bool) {
	switch s {
	case "debug":
		return .Debug, true
	case "info":
		return .Info, true
	case "warn":
		return .Warn, true
	case "error":
		return .Error, true
	}
	return .Info, false
}

plugin_print :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return plugin_unavailable(L)
	}
	context = entry.ctx
	pl := plugin_owner(L, entry.editor)
	n := lua.gettop(L)
	lua.checkstack(L, n)
	sb := strings.builder_make(context.temp_allocator)
	for i in 1 ..= n {
		if i > 1 {
			strings.write_byte(&sb, '\t')
		}
		s, _ := lua.toodinstring_any(L, i)
		strings.write_string(&sb, s)
	}
	if pl != nil {
		editor_log(entry.editor, .Info, pl.display, strings.to_string(sb), show = false)
	}
	return 0
}

qed_log :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return plugin_unavailable(L)
	}
	context = entry.ctx
	pl := plugin_owner(L, entry.editor)
	lvl_s, _ := lua.toodinstring(L, 1)
	level, ok := plugin_log_level(lvl_s)
	if lua.type(L, 1) != .STRING || !ok {
		return lua.L_argerror(L, 1, "level must be \"debug\", \"info\", \"warn\" or \"error\"")
	}
	text, _ := lua.toodinstring_any(L, 2)
	if pl != nil {
		editor_log(entry.editor, level, pl.display, text, show = false)
	}
	return 0
}

qed_message :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return plugin_unavailable(L)
	}
	context = entry.ctx
	pl := plugin_owner(L, entry.editor)
	lua.settop(L, 2)
	text, _ := lua.toodinstring_any(L, 1)
	text = strings.clone(text, context.temp_allocator)
	level := LogLevel.Info
	lvl_idx: c.int = 2
	if lua.type(L, 2) == .TABLE {
		lua.pushnil(L)
		for lua.next(L, 2) != 0 {
			k: string
			if lua.type(L, -2) == .STRING {
				k, _ = lua.toodinstring(L, -2)
			}
			if k != "level" {
				return plugin_raise(L, fmt.tprintf("qed.message: unknown option '%s'", lua.L_tostring(L, -2)))
			}
			lua.pop(L, 1)
		}
		lua.getfield(L, 2, "level")
		lvl_idx = lua.gettop(L)
	}
	if lua.type(L, lvl_idx) > .NIL {
		lvl_s, _ := lua.toodinstring(L, lvl_idx)
		lvl, ok := plugin_log_level(lvl_s)
		if lua.type(L, lvl_idx) != .STRING || !ok {
			return lua.L_argerror(L, 2, "level must be \"debug\", \"info\", \"warn\" or \"error\"")
		}
		level = lvl
	}
	if pl != nil {
		editor_log(entry.editor, level, pl.display, text)
	}
	return 0
}

qed_command :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return plugin_unavailable(L)
	}
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	pl := plugin_owner(L, editor)
	if lua.type(L, 1) != .TABLE {
		return lua.L_argerror(L, 1, "table expected")
	}
	lua.settop(L, 1)
	if lua.getfield(L, 1, "name") != .STRING {
		return lua.L_argerror(L, 1, "name must be a string")
	}
	name, _ := lua.toodinstring(L, -1)
	if name == "" {
		return lua.L_argerror(L, 1, "name must not be empty")
	}
	if lua.getfield(L, 1, "run") != .FUNCTION {
		return lua.L_argerror(L, 1, "run must be a function")
	}
	when_t := lua.getfield(L, 1, "when")
	if when_t != .FUNCTION && when_t != .NIL {
		return lua.L_argerror(L, 1, "when must be a function")
	}
	key_t := lua.getfield(L, 1, "key")
	if key_t != .STRING && key_t != .NIL {
		return lua.L_argerror(L, 1, "key must be a string")
	}
	key_s, _ := lua.toodinstring(L, 5)
	if key_t == .STRING && key_s != "" {
		if _, _, kok := parse_keybind(key_s); !kok {
			return plugin_raise(L, fmt.tprintf("invalid key '%s' for command '%s'", key_s, name))
		}
	}
	scope_t := lua.getfield(L, 1, "scope")
	scope_s, _ := lua.toodinstring(L, 6)
	if (scope_t != .STRING && scope_t != .NIL) || (scope_t == .STRING && scope_s != "editor" && scope_s != "filetree") {
		return lua.L_argerror(L, 1, "scope must be \"editor\" or \"filetree\"")
	}
	welcome_t := lua.getfield(L, 1, "welcome")
	if welcome_t != .BOOLEAN && welcome_t != .NIL {
		return lua.L_argerror(L, 1, "welcome must be a boolean")
	}
	welcome := bool(lua.toboolean(L, 7))
	keybind_t := lua.getfield(L, 1, "keybind")
	if keybind_t != .STRING && keybind_t != .NIL {
		return lua.L_argerror(L, 1, "keybind must be a string")
	}
	keybind_s, _ := lua.toodinstring(L, 8)
	if keybind_t == .STRING && keybind_s == "" {
		return lua.L_argerror(L, 1, "keybind must not be empty")
	}
	filetree := scope_s == "filetree"
	if pl == nil || pl.state != .Enabled {
		return plugin_raise(L, "plugin is not loaded")
	}
	visible := fmt.tprintf("%s: %s", pl.display, name)
	if plugin_command_taken(p, visible, filetree) {
		return plugin_raise(L, fmt.tprintf("command '%s' already exists", visible))
	}
	lua.pushvalue(L, 3)
	ref := i32(lua.L_ref(L, lua.REGISTRYINDEX))
	when_ref: i32
	if when_t == .FUNCTION {
		lua.pushvalue(L, 4)
		when_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	}
	id := plugin_next_id(p)
	cmd := Command {
		name        = strings.clone(visible),
		bare        = strings.clone(name),
		owner       = pl.name,
		id          = id,
		filetree    = filetree,
		welcome     = welcome,
		key_default = strings.clone(key_s) if key_t == .STRING else "",
		config_name = strings.clone(keybind_s if keybind_t == .STRING else name),
		ref         = ref,
		when_ref    = when_ref,
	}
	if problem, from_user := plugin_command_bind(p, &cmd, editor_config_user(editor)); problem != "" && p.bound && !p.applying {
		if from_user {
			editor_log(editor, .Warn, "", fmt.tprintf("config.json: ignoring %s", problem))
		} else {
			editor_log(editor, .Warn, pl.display, fmt.tprintf("ignoring key for %s", problem))
		}
	}
	append(&p.commands, cmd)
	api_handle_push(L, id, {{"remove", qed_command_remove}})
	return 1
}

qed_command_remove :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	id := api_handle_id(L)
	for cmd, i in p.commands {
		if cmd.id == id {
			plugin_command_remove(editor, i)
			lua.pushboolean(L, true)
			return 1
		}
	}
	lua.pushboolean(L, false)
	return 1
}

plugin_command_remove :: proc(editor: ^Editor, i: int) {
	p := &editor.plugins
	if editor.palette.active {
		palette_close(editor)
	}
	lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(p.commands[i].ref))
	if p.commands[i].when_ref != 0 {
		lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(p.commands[i].when_ref))
	}
	plugin_command_free(&p.commands[i])
	ordered_remove(&p.commands, i)
}

qed_run :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return plugin_unavailable(L)
	}
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 1) != .STRING {
		return lua.L_argerror(L, 1, "command name expected")
	}
	if editor.plugins.loading {
		return plugin_raise(L, "qed.run is unavailable while plugins load")
	}
	name, _ := lua.toodinstring(L, 1)
	for cmd in commands {
		if cmd.name == name {
			ran := command_available(editor, name)
			if ran {
				cmd.run(editor)
			}
			lua.pushboolean(L, b32(ran))
			return 1
		}
	}
	caller, _ := lua.toodinstring(L, lua.upvalueindex(1))
	found := -1
	for cmd, i in editor.plugins.commands {
		if cmd.filetree {
			continue
		}
		if cmd.name == name {
			found = i
			break
		}
		if found < 0 && cmd.owner == caller && cmd.bare == name {
			found = i
		}
	}
	if found < 0 {
		return plugin_raise(L, fmt.tprintf("unknown command '%s'", name))
	}
	plugin_command_run(editor, editor.plugins.commands[found])
	lua.pushboolean(L, true)
	return 1
}

plugin_command_taken :: proc(p: ^Plugins, name: string, filetree: bool, skip_owner := "") -> bool {
	for cmd in commands {
		if cmd.name == name {
			return true
		}
	}
	for cmd in filetree_commands {
		if command_config_name(cmd) == name || (filetree && cmd.name == name) {
			return true
		}
	}
	for cmd in p.commands {
		if cmd.name == name && cmd.filetree == filetree && (skip_owner == "" || cmd.owner != skip_owner) {
			return true
		}
	}
	return false
}

plugin_command_free :: proc(cmd: ^Command) {
	delete(cmd.name)
	delete(cmd.bare)
	delete(cmd.shortcut)
	delete(cmd.key_default)
	delete(cmd.config_name)
}

editor_config_user :: proc(editor: ^Editor) -> json.Object {
	if o, ok := editor.plugins.config_override.?; ok {
		return o
	}
	return nil if editor.headless else g_config_user
}

plugin_keybind :: proc(cfg: json.Object, owner, key: string) -> (json.Value, bool) {
	kb, _ := plugin_cfg_entry(cfg, owner)["keybinds"].(json.Object)
	v, ok := kb[key]
	return v, ok
}

plugin_bind_taken :: proc(key: tb2.Key, alt_ch: rune, filetree: bool) -> string {
	for cmd in (filetree_commands[:] if filetree else commands[:]) {
		k, a, sc := command_effective_bind(cmd)
		if sc != "" && a == alt_ch && (alt_ch != 0 || k == key) {
			return cmd.name
		}
	}
	return ""
}

plugin_command_bind :: proc(p: ^Plugins, cmd: ^Command, cfg_user: json.Object) -> (problem: string, from_user: bool) {
	label := fmt.tprintf("plugins/%s/keybinds/%s", cmd.owner, cmd.config_name)
	bind := cmd.key_default
	for other in p.commands {
		if bind != "" {
			break
		}
		if other.owner == cmd.owner && other.config_name == cmd.config_name {
			bind = other.key_default
		}
	}
	if v, ok := plugin_keybind(cfg_user, cmd.owner, cmd.config_name); ok {
		s, is_str := v.(json.String)
		_, _, parses := parse_keybind(string(s))
		if !is_str || (s != "" && !parses) {
			problem = label
		} else {
			bind = string(s)
		}
		from_user = true
	}
	delete(cmd.shortcut)
	cmd.shortcut = ""
	cmd.key = {}
	cmd.alt_ch = 0
	if problem != "" || bind == "" {
		return
	}
	key, alt_ch, ok := parse_keybind(bind)
	if !ok {
		return label, from_user
	}
	if taken := plugin_bind_taken(key, alt_ch, cmd.filetree); taken != "" {
		return fmt.tprintf("%s (%s is %q)", label, bind, taken), from_user
	}
	cmd.key = key
	cmd.alt_ch = alt_ch
	cmd.shortcut = strings.clone(bind)
	return
}

plugins_rebind :: proc(editor: ^Editor) {
	p := &editor.plugins
	cfg_user := editor_config_user(editor)
	if p.mem != nil {
		p.mem.cap = PLUGIN_MEMORY_MB * 1024 * 1024
	}
	problems := config_keybinds_unknown(cfg_user, p.commands[:])
	for &cmd in p.commands {
		problem, from_user := plugin_command_bind(p, &cmd, cfg_user)
		if problem == "" {
			continue
		}
		if from_user {
			append(&problems, problem)
		} else {
			editor_log(editor, .Warn, plugin_label(p, cmd.owner), fmt.tprintf("ignoring key for %s", problem))
		}
	}
	if len(problems) > 0 {
		editor_log(editor, .Warn, "", fmt.tprintf("config.json: ignoring %s", strings.join(problems[:], ", ", context.temp_allocator)))
	}
	p.bound = true
}

plugin_command_matches :: proc(cmd: Command, ev: tb2.Event) -> bool {
	if cmd.shortcut == "" {
		return false
	}
	if ev_alt(ev) && ev.ch != 0 {
		return cmd.alt_ch != 0 && cmd.alt_ch == ev.ch
	}
	return cmd.alt_ch == 0 && cmd.key == ev.key
}

plugin_command_for_event :: proc(editor: ^Editor, ev: tb2.Event, filetree: bool) -> (Command, bool) {
	for cmd in editor.plugins.commands {
		if cmd.filetree == filetree && plugin_command_matches(cmd, ev) {
			return cmd, true
		}
	}
	return {}, false
}

plugin_ctx_push :: proc(L: ^lua.State, editor: ^Editor) {
	lua.createtable(L, 0, 4)
	lua.pushodinstring(L, editor.working_root)
	lua.setfield(L, -2, "root")
	lua.createtable(L, 0, 1)
	lua.pushcfunction(L, plugin_ctx_index)
	lua.setfield(L, -2, "__index")
	lua.setmetatable(L, -2)
	if editor.welcome || len(editor.buffers) == 0 {
		return
	}
	b := editor_buffer(editor)
	lua.pushinteger(L, lua.Integer(b.id))
	lua.setfield(L, -2, "buf")
	lua.pushodinstring(L, b.path)
	lua.setfield(L, -2, "path")
	lua.pushodinstring(L, LANGUAGES[b.language].name)
	lua.setfield(L, -2, "language")
}

plugin_ctx_index :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	if entry == nil {
		return plugin_unavailable(L)
	}
	context = entry.ctx
	key, _ := lua.toodinstring(L, 2)
	editor := entry.editor
	t := &editor.filetree
	switch key {
	case "selection_text":
		if editor.welcome || len(editor.buffers) == 0 {
			return 0
		}
		b := editor_buffer(editor)
		from, to, ok := selection_range(b)
		if !ok {
			return 0
		}
		lua.pushodinstring(L, buffer_text_range(b, from, to))
	case "file":
		e, ok := filetree_selected(t)
		if !t.active || !ok {
			return 0
		}
		lua.pushodinstring(L, e.path)
	case "files":
		if !t.active || len(t.entries) == 0 {
			return 0
		}
		files := filetree_sel_files(editor)
		lua.createtable(L, c.int(len(files)), 0)
		for f, i in files {
			lua.pushodinstring(L, f)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	case:
		return 0
	}
	lua.pushvalue(L, 2)
	lua.pushvalue(L, -2)
	lua.rawset(L, 1)
	return 1
}

plugin_invoke_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.tointeger(L, 1))
	plugin_ctx_push(L, entry.editor)
	lua.call(L, 1, 1)
	return 1
}

plugin_invoke :: proc(editor: ^Editor, owner: string, ref: i32, nresults: c.int) -> bool {
	p := &editor.plugins
	lua.pushcfunction(p.L, plugin_invoke_c)
	lua.pushinteger(p.L, lua.Integer(ref))
	p.resumes += 1
	prev_slice := plugin_slice_begin(p, .When)
	ok, msg, tb := plugin_call(editor, 1, nresults)
	if plugin_slice_end(editor, prev_slice, owner, .When, "command when") && ok {
		lua.pop(p.L, nresults)
		ok, msg, tb = false, fmt.tprintf("command when exceeded its %.0f ms budget", plugin_budgets[.When].hard_ms), ""
	}
	if !ok {
		if pl := plugin_find(p, owner); pl != nil {
			plugin_error(editor, pl, msg, tb, false)
		}
	}
	return ok
}

plugin_command_when :: proc(editor: ^Editor, cmd: Command) -> bool {
	if cmd.when_ref == 0 {
		return true
	}
	L := editor.plugins.L
	if !plugin_invoke(editor, cmd.owner, cmd.when_ref, 1) {
		return false
	}
	res := bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	return res
}

plugin_command_run :: proc(editor: ^Editor, cmd: Command) {
	plugin_task_start(editor, cmd.owner, .Command, {ref = cmd.ref, args = .Ctx, command = cmd.id})
}

plugin_command_chord :: proc(editor: ^Editor, cmd: Command) {
	if plugin_command_when(editor, cmd) {
		plugin_command_run(editor, cmd)
	}
}

plugin_json_push :: proc(L: ^lua.State, v: json.Value) {
	lua.L_checkstack(L, 3, "config nested too deeply")
	switch x in v {
	case json.Null:
		lua.pushnil(L)
	case json.Integer:
		lua.pushinteger(L, lua.Integer(x))
	case json.Float:
		lua.pushnumber(L, lua.Number(x))
	case json.Boolean:
		lua.pushboolean(L, b32(x))
	case json.String:
		lua.pushodinstring(L, string(x))
	case json.Array:
		lua.createtable(L, c.int(len(x)), 0)
		for e, i in x {
			plugin_json_push(L, e)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	case json.Object:
		lua.createtable(L, 0, c.int(len(x)))
		for k, e in x {
			lua.pushodinstring(L, k)
			plugin_json_push(L, e)
			lua.rawset(L, -3)
		}
	}
}

plugin_table_copy :: proc(L: ^lua.State, idx: c.int, depth := 0) {
	if depth > PLUGIN_TABLE_DEPTH_MAX {
		plugin_raise(L, "table is nested too deeply")
	}
	lua.L_checkstack(L, 5, "table is nested too deeply")
	idx := lua.absindex(L, idx)
	lua.newtable(L)
	lua.pushnil(L)
	for lua.next(L, idx) != 0 {
		lua.pushvalue(L, -2)
		lua.insert(L, -2)
		if lua.type(L, -1) == .TABLE {
			plugin_table_copy(L, -1, depth + 1)
			lua.remove(L, -2)
		}
		lua.rawset(L, -4)
	}
}

plugin_table_merge :: proc(L: ^lua.State, idx: c.int, src: json.Object) {
	lua.L_checkstack(L, 4, "config nested too deeply")
	idx := lua.absindex(L, idx)
	for k, v in src {
		if sub, is_obj := v.(json.Object); is_obj {
			lua.pushodinstring(L, k)
			if lua.rawget(L, idx) == .TABLE {
				plugin_table_merge(L, -1, sub)
				lua.pop(L, 1)
				continue
			}
			lua.pop(L, 1)
		}
		lua.pushodinstring(L, k)
		plugin_json_push(L, v)
		lua.rawset(L, idx)
	}
}

plugin_config_push :: proc(editor: ^Editor, pl: ^Plugin, defaults_idx: c.int) {
	L := editor.plugins.L
	has_defaults := lua.type(L, defaults_idx) == .TABLE
	if has_defaults {
		plugin_table_copy(L, defaults_idx)
	} else {
		lua.newtable(L)
	}
	cfg := lua.gettop(L)
	user := make(json.Object, context.temp_allocator)
	unknown := make([dynamic]string, context.temp_allocator)
	for k, v in plugin_cfg_entry(editor_config_user(editor), pl.name) {
		if k == "enabled" || k == "keybinds" {
			continue
		}
		known := false
		if has_defaults {
			lua.pushodinstring(L, k)
			known = lua.rawget(L, defaults_idx) != .NIL
			lua.pop(L, 1)
		}
		if known {
			user[k] = v
		} else {
			append(&unknown, fmt.tprintf("plugins/%s/%q", pl.name, k))
		}
	}
	plugin_table_merge(L, cfg, user)
	lua.pushodinstring(L, "enabled")
	lua.pushnil(L)
	lua.rawset(L, cfg)
	if pl.cfg != lua.NOREF {
		lua.L_unref(L, lua.REGISTRYINDEX, pl.cfg)
	}
	plugin_table_copy(L, cfg)
	pl.cfg = lua.L_ref(L, lua.REGISTRYINDEX)
	slice.sort(unknown[:])
	delete(pl.unknown)
	pl.unknown = strings.join(unknown[:], ", ")
}

PluginView :: struct {
	active:   bool,
	selected: int,
	scroll:   int,
	viewing:  bool,
	source:   Preview,
}

pluginview_open :: proc(editor: ^Editor) {
	v := &editor.pluginview
	v.active = true
	v.viewing = false
	v.selected = clamp(v.selected, 0, max(0, len(editor.plugins.list) - 1))
	editor_clear_message(editor)
}

pluginview_close :: proc(editor: ^Editor) {
	v := &editor.pluginview
	v.active = false
	v.viewing = false
	preview_reset(&v.source)
}

pluginview_body_h :: proc(editor: ^Editor) -> int {
	lay := logview_layout(editor)
	return max(1, lay.footer_sep_y - lay.body_top)
}

pluginview_selected :: proc(editor: ^Editor) -> ^Plugin {
	v := &editor.pluginview
	if v.selected < 0 || v.selected >= len(editor.plugins.list) {
		return nil
	}
	return &editor.plugins.list[v.selected]
}

pluginview_move :: proc(editor: ^Editor, delta: int) {
	v := &editor.pluginview
	n := len(editor.plugins.list)
	if n == 0 {
		return
	}
	v.selected = clamp(v.selected + delta, 0, n - 1)
	h := pluginview_body_h(editor)
	if v.selected < v.scroll {
		v.scroll = v.selected
	}
	if v.selected >= v.scroll + h {
		v.scroll = v.selected - h + 1
	}
}

plugin_enabled_set :: proc(editor: ^Editor, pl: ^Plugin, enable: bool) {
	if !enable {
		if pl.state == .Enabled {
			plugin_unload(editor, pl)
		}
		pl.state = .Disabled
		editor_log(editor, .Info, pl.display, "disabled")
		return
	}
	plugin_load(editor, pl, check_enabled = false)
	plugin_reload_report(editor, pl, "enabled")
}

pluginview_toggle :: proc(editor: ^Editor) {
	pl := pluginview_selected(editor)
	if pl == nil {
		return
	}
	enable := pl.state == .Disabled
	path := editor.plugins.persist_path if editor.headless else config_path()
	if path == "" || !config_persist_path_to(path, {"plugins", pl.name, "enabled"}, json.Boolean(enable)) {
		editor_log(editor, .Error, "", "Cannot update config.json (unwritable or not valid JSON)")
		return
	}
	plugin_enabled_set(editor, pl, enable)
}

pluginview_reload :: proc(editor: ^Editor) {
	pl := pluginview_selected(editor)
	if pl == nil {
		return
	}
	if pl.state == .Disabled {
		editor_log(editor, .Warn, "", fmt.tprintf("%s is disabled (e enables it)", pl.display))
		return
	}
	pl.stamp = plugin_stamp_of(pl^)
	plugin_reload(editor, pl)
	plugin_reload_report(editor, pl, "reloaded")
}

pluginview_enter :: proc(editor: ^Editor) {
	v := &editor.pluginview
	pl := pluginview_selected(editor)
	if pl == nil {
		return
	}
	if !pl.bundled {
		main := strings.clone(pl.main, context.temp_allocator)
		pluginview_close(editor)
		editor_open_path(editor, main)
		return
	}
	src, ok := plugin_source(&editor.plugins, pl, pl.main)
	if !ok {
		return
	}
	preview_set_text(&v.source, pl.main, src, pluginview_body_h(editor))
	v.viewing = true
}

pluginview_source_close :: proc(editor: ^Editor) {
	editor.pluginview.viewing = false
	preview_reset(&editor.pluginview.source)
}

pluginview_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	v := &editor.pluginview
	if command_matches(ev, "Debug: Plugins") {
		pluginview_close(editor)
		return
	}
	if v.viewing {
		h := pluginview_body_h(editor)
		#partial switch ev.key {
		case .Esc:
			pluginview_source_close(editor)
		case .Arrow_Up:
			preview_scroll_by(&v.source, -1, h)
		case .Arrow_Down:
			preview_scroll_by(&v.source, 1, h)
		case .Pgup:
			preview_scroll_by(&v.source, -h, h)
		case .Pgdn:
			preview_scroll_by(&v.source, h, h)
		case .Home:
			preview_scroll_by(&v.source, -len(v.source.src), h)
		case .End:
			preview_scroll_by(&v.source, len(v.source.src), h)
		}
		return
	}
	#partial switch ev.key {
	case .Esc:
		pluginview_close(editor)
		return
	case .Arrow_Up:
		pluginview_move(editor, -1)
		return
	case .Arrow_Down:
		pluginview_move(editor, +1)
		return
	case .Enter:
		pluginview_enter(editor)
		return
	}
	switch ev.ch {
	case 'e':
		pluginview_toggle(editor)
	case 'r':
		pluginview_reload(editor)
	case 'l':
		if pl := pluginview_selected(editor); pl != nil {
			logview_open(editor, pl.display)
		}
	}
}

pluginview_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	v := &editor.pluginview
	lay := logview_layout(editor)
	n := len(editor.plugins.list)
	h := pluginview_body_h(editor)
	if v.viewing {
		#partial switch ev.key {
		case .Mouse_Wheel_Up:
			preview_scroll_by(&v.source, -WHEEL_SCROLL_LINES, h)
		case .Mouse_Wheel_Down:
			preview_scroll_by(&v.source, WHEEL_SCROLL_LINES, h)
		case .Mouse_Left:
			if !mouse_in_rect(ev, lay.box) && !ev_motion(ev) {
				pluginview_source_close(editor)
			}
		}
		return
	}
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		overlay_scroll_by(&v.scroll, -WHEEL_SCROLL_LINES, n, h)
	case .Mouse_Wheel_Down:
		overlay_scroll_by(&v.scroll, WHEEL_SCROLL_LINES, n, h)
	case .Mouse_Left:
		if !mouse_in_rect(ev, lay.box) {
			if !ev_motion(ev) {
				pluginview_close(editor)
			}
			return
		}
		off := overlay_row_off(ev, Rect{lay.inner.x, lay.body_top, lay.inner.w, h})
		if off >= 0 && v.scroll + off < n {
			v.selected = v.scroll + off
			if !ev_motion(ev) && overlay_double_click(editor, v.selected) {
				pluginview_enter(editor)
			}
		}
	}
}

pluginview_row :: proc(pl: Plugin, name_w: int) -> string {
	state := "enabled"
	switch pl.state {
	case .Enabled:
	case .Disabled:
		state = "disabled"
	case .Errored:
		state = "errored"
	}
	source := "bundled" if pl.bundled else "user"
	load := fmt.tprintf("%10s", fmt.tprintf("%.2f ms", pl.load_ms)) if pl.state != .Disabled else ""
	return fmt.tprintf("%-*s  %-7s  %-8s  %s", name_w, pl.display, source, state, load)
}

pluginview_render :: proc(editor: ^Editor) {
	v := &editor.pluginview
	p := &editor.plugins
	lay := logview_layout(editor)
	inner := pane_draw_box(lay.box)
	h := pluginview_body_h(editor)
	if v.viewing {
		pl := pluginview_selected(editor)
		pane_text(inner.x + 1, inner.y, inner.w - 2, fmt.tprintf("plugins/%s  ·  bundled, read-only", v.source.path), COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
		pane_hline(lay.box, lay.title_sep_y)
		preview_ensure(&v.source, h)
		preview_render(&v.source, inner.x, lay.body_top, inner.w - 1, h)
		pane_draw_scrollbar(lay.box.x + lay.box.w - 1, lay.body_top, h, v.source.scroll, preview_total(&v.source))
		pane_hline(lay.box, lay.footer_sep_y)
		fork := fmt.tprintf("%s/%s", p.user_dir, pl.dir if pl != nil && pl.dir != "" else v.source.path)
		if home := os.get_env("HOME", context.temp_allocator); home != "" && strings.has_prefix(fork, home) {
			fork = fmt.tprintf("~%s", fork[len(home):])
		}
		pane_text(inner.x + 1, lay.footer_y, inner.w - 2, fmt.tprintf("Esc back  ·  fork: copy to %s", fork), COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
		tb2.hide_cursor()
		return
	}
	title := "Plugins (Lua failed to start)" if p.L == nil else fmt.tprintf("Plugins  ·  Lua init %.2f ms", p.init_ms)
	pane_text(inner.x + 1, inner.y, inner.w - 2, title, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_hline(lay.box, lay.title_sep_y)

	n := len(p.list)
	if n == 0 {
		pane_text(inner.x + 1, lay.body_top, inner.w - 2, "(no plugins)", COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	v.selected = clamp(v.selected, 0, max(0, n - 1))
	name_w := 4
	for pl in p.list {
		name_w = max(name_w, len(pl.display))
	}
	v.scroll = clamp(v.scroll, 0, max(0, n - h))
	for i in v.scroll ..< min(v.scroll + h, n) {
		pl := p.list[i]
		y := lay.body_top + i - v.scroll
		fg := COLOR_PANE_FG
		switch pl.state {
		case .Enabled:
		case .Disabled:
			fg = COLOR_PANE_SHORTCUT_FG
		case .Errored:
			fg = COLOR_ERROR_FG
		}
		bg := COLOR_PANE_BG
		if i == v.selected {
			bg = COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, pluginview_row(pl, name_w), fg, bg)
	}
	pane_draw_scrollbar(lay.box.x + lay.box.w - 1, lay.body_top, h, v.scroll, n)

	pane_hline(lay.box, lay.footer_sep_y)
	if v.selected < n && p.list[v.selected].last_error != "" {
		err, _ := strings.replace_all(p.list[v.selected].last_error, "\n", " ", context.temp_allocator)
		pane_text(inner.x + 1, lay.footer_y, inner.w - 2, err, COLOR_ERROR_FG, COLOR_PANE_BG)
	} else {
		pane_text(inner.x + 1, lay.footer_y, inner.w - 2, "↑↓ select  Enter open  e enable/disable  r reload  l log  Esc close", COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	tb2.hide_cursor()
}
