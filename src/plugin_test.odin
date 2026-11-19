package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import lua "lib:lua"
import "lib:tb2"

PLUGIN_TEST_MEM :: 16 * 1024 * 1024

plugin_test_editor :: proc(bundled: []PluginFile, user_dir := "", cfg_user: json.Object = nil, mem_cap := PLUGIN_TEST_MEM) -> ^Editor {
	ed := new(Editor)
	ed.headless = true
	append(&ed.buffers, test_buffer("hello world"))
	if cfg_user != nil {
		ed.plugins.config_override = cfg_user
	}
	editor_plugins_start(ed, bundled, user_dir, mem_cap)
	return ed
}

plugin_test_destroy :: proc(ed: ^Editor) {
	plugins_shutdown(&ed.plugins)
	for &b in ed.buffers {
		buffer_destroy(&b)
	}
	delete(ed.buffers)
	editor_log_destroy(ed)
	delete(ed.message_store)
	free(ed)
}

plugin_test_cfg :: proc(src: string) -> json.Object {
	v, err := json.parse_string(src, parse_integers = true, allocator = context.temp_allocator)
	assert(err == nil, "test config parses")
	return v.(json.Object)
}

plugin_test_logged :: proc(ed: ^Editor, level: LogLevel, source, fragment: string) -> bool {
	for e in ed.log {
		if e.level == level && e.source == source && strings.contains(e.text, fragment) {
			return true
		}
	}
	return false
}

plugin_test_command :: proc(ed: ^Editor, name: string) -> (Command, bool) {
	for cmd in ed.plugins.commands {
		if cmd.name == name {
			return cmd, true
		}
	}
	return {}, false
}

plugin_test_global :: proc(ed: ^Editor, name: cstring) -> string {
	L := ed.plugins.L
	lua.getglobal(L, name)
	s, _ := lua.toodinstring(L, -1)
	s = strings.clone(s, context.temp_allocator)
	lua.pop(L, 1)
	return s
}

@(test)
plugin_load_ok :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"hello.lua", `
			return {
				setup = function(cfg)
					qed.command{name = "Hello: Greet", run = function(ctx)
						qed.message("hi " .. ctx.path .. " " .. ctx.language .. " " .. ctx.root)
					end}
				end,
			}`},
		{".gitkeep", ""},
		{"notes.txt", "not a plugin"},
	})
	defer plugin_test_destroy(ed)

	testing.expect_value(t, len(ed.plugins.list), 1)
	pl := ed.plugins.list[0]
	testing.expect_value(t, pl.name, "hello")
	testing.expect(t, pl.bundled, "embedded plugin is bundled")
	testing.expect_value(t, pl.state, PluginState.Enabled)
	testing.expect_value(t, pl.last_error, "")
	testing.expect(t, plugin_test_logged(ed, .Debug, "Plugins", "loaded hello (bundled)"), "per-plugin load time is logged")

	cmd, ok := plugin_test_command(ed, "Hello: Greet")
	testing.expect(t, ok, "setup registered the command")
	testing.expect_value(t, cmd.owner, "hello")
	command_run(ed, cmd)
	testing.expect_value(t, ed.message, "hi  text ")
	testing.expect_value(t, ed.message_source, "hello")
}

@(test)
plugin_load_error_disables :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"broken.lua", "return {"},
		{"crash.lua", `error("boom")`},
		{"notable.lua", "return 42"},
		{"halfway.lua", `
			return {
				setup = function()
					qed.command{name = "Halfway: Cmd", run = function() end}
					local t = nil
					return t.field
				end,
			}`},
		{"fine.lua", `return {setup = function() qed.command{name = "Fine: Cmd", run = function() end} end}`},
	})
	defer plugin_test_destroy(ed)

	for pl in ed.plugins.list {
		if pl.name == "fine" {
			testing.expect_value(t, pl.state, PluginState.Enabled)
			continue
		}
		testing.expectf(t, pl.state == .Errored, "%s is errored", pl.name)
		testing.expectf(t, pl.last_error != "", "%s kept its last error", pl.name)
		testing.expectf(t, plugin_test_logged(ed, .Error, pl.name, ""), "%s logged an error under its name", pl.name)
	}
	crash := plugin_find(&ed.plugins, "crash")
	testing.expect(t, strings.contains(crash.last_error, "boom"), "runtime error message kept")
	testing.expect(t, !strings.contains(crash.last_error, "stack traceback"), "last error is the message, not the traceback")
	testing.expect(t, plugin_test_logged(ed, .Debug, "crash", "stack traceback"), "traceback goes to the Debug log")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "notable").last_error, "must return a table"), "spec shape enforced")
	_, half := plugin_test_command(ed, "Halfway: Cmd")
	testing.expect(t, !half, "a failed setup unregisters what it registered")
	_, fine := plugin_test_command(ed, "Fine: Cmd")
	testing.expect(t, fine, "a healthy plugin is unaffected")
}

@(test)
plugin_env_isolation :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"a.lua", `leaked = "a"; return {setup = function() string.qed_shared = true end}`},
		{"b.lua", `
			return {
				setup = function()
					if leaked ~= nil or _G.leaked ~= nil then error("global leaked across plugins") end
					if string.format("%d", 7) ~= "7" then error("stdlib missing") end
					print("b sees", 1, nil)
				end,
			}`},
	})
	defer plugin_test_destroy(ed)

	testing.expect_value(t, plugin_find(&ed.plugins, "a").state, PluginState.Enabled)
	testing.expect_value(t, plugin_find(&ed.plugins, "b").state, PluginState.Enabled)
	testing.expect_value(t, plugin_find(&ed.plugins, "b").last_error, "")
	testing.expect_value(t, plugin_test_global(ed, "leaked"), "")
	testing.expect(t, plugin_test_logged(ed, .Info, "b", "b sees\t1\tnil"), "print logs under the plugin, never to stdout")
}

@(test)
plugin_require_scoping :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"dirp/init.lua", `
			local util = require("util")
			local again = require("util")
			local sub = require("sub")
			local deep = require("sub.deep")
			local str = require("string")
			assert(util == again, "require caches")
			assert(util.loads == 1, "module body runs once")
			assert(sub.name == "sub" and deep.name == "deep", "init.lua and dotted names resolve")
			assert(str == string, "standard libraries stay requirable")
			assert(shared_from_util == true, "modules share the plugin's _ENV")
			for _, bad in ipairs({"..util", "a/b", "missing"}) do
				local ok, err = pcall(require, bad)
				assert(not ok, "require " .. bad .. " must fail")
			end
			return {}`},
		{"dirp/util.lua", `shared_from_util = true; counter = (counter or 0) + 1; return {loads = counter}`},
		{"dirp/sub/init.lua", `return {name = "sub"}`},
		{"dirp/sub/deep.lua", `return {name = "deep"}`},
		{"other/init.lua", `return {setup = function() require("util") end}`},
		{"single.lua", `return {setup = function() require("dirp.util") end}`},
	})
	defer plugin_test_destroy(ed)

	dirp := plugin_find(&ed.plugins, "dirp")
	testing.expect_value(t, dirp.state, PluginState.Enabled)
	testing.expect_value(t, dirp.last_error, "")
	other := plugin_find(&ed.plugins, "other")
	testing.expect_value(t, other.state, PluginState.Errored)
	testing.expect(t, strings.contains(other.last_error, "module 'util' not found"), "another plugin's dir is out of reach")
	single := plugin_find(&ed.plugins, "single")
	testing.expect_value(t, single.state, PluginState.Errored)
	testing.expect(t, strings.contains(single.last_error, "single-file"), "single-file plugins cannot require local modules")
}

@(test)
plugin_user_dir_load :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_plugin_test_%d", tmp, posix.getpid())
	os.make_directory(dir)
	os.make_directory(fmt.tprintf("%s/dirp", dir))
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	_ = os.write_entire_file(fmt.tprintf("%s/dirp/init.lua", dir), transmute([]u8)string(`return {setup = function() qed.command{name = require("names").cmd, run = function() end} end}`))
	_ = os.write_entire_file(fmt.tprintf("%s/dirp/names.lua", dir), transmute([]u8)string(`return {cmd = "Dir: Cmd"}`))
	_ = os.write_entire_file(fmt.tprintf("%s/shadow.lua", dir), transmute([]u8)string(`return {setup = function() qed.command{name = "Shadow: User", run = function() end} end}`))
	_ = os.write_entire_file(fmt.tprintf("%s/readme.md", dir), transmute([]u8)string("ignored"))

	ed := plugin_test_editor({
		{"shadow.lua", `return {setup = function() qed.command{name = "Shadow: Bundled", run = function() end} end}`},
		{"zeta.lua", `return {}`},
	}, dir)
	defer plugin_test_destroy(ed)

	names := make([dynamic]string, context.temp_allocator)
	for pl in ed.plugins.list {
		append(&names, fmt.tprintf("%s:%v", pl.name, pl.bundled))
	}
	testing.expect_value(t, strings.join(names[:], " ", context.temp_allocator), "zeta:true dirp:false shadow:false")
	_, user := plugin_test_command(ed, "Shadow: User")
	_, bundled := plugin_test_command(ed, "Shadow: Bundled")
	testing.expect(t, user && !bundled, "a user plugin replaces the bundled one of the same name")
	_, dirc := plugin_test_command(ed, "Dir: Cmd")
	testing.expect(t, dirc, "user dir plugin requires its own module from disk")
}

@(test)
plugin_memory_cap :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"hog.lua", `
			local t = {}
			for i = 1, 1e7 do t[i] = string.rep("x", 64) .. i end
			return {}`},
		{"small.lua", `return {setup = function() qed.command{name = "Small: Cmd", run = function() qed.message(string.rep("y", 3)) end} end}`},
	}, mem_cap = 4 * 1024 * 1024)
	defer plugin_test_destroy(ed)

	hog := plugin_find(&ed.plugins, "hog")
	testing.expect_value(t, hog.state, PluginState.Errored)
	testing.expect(t, strings.contains(hog.last_error, "not enough memory"), "OOM is a catchable plugin error")
	testing.expect(t, ed.plugins.mem.used <= ed.plugins.mem.cap, "the cap holds")
	cmd, ok := plugin_test_command(ed, "Small: Cmd")
	testing.expect(t, ok, "the state survives OOM")
	command_run(ed, cmd)
	testing.expect_value(t, ed.message, "yyy")
}

@(test)
plugin_config_merge :: proc(t: ^testing.T) {
	cfg := plugin_test_cfg(`{"plugins": {
		"merge": {"nested": {"b": 20}, "list": [9], "bogus": 1, "enabled": true},
		"off": {"enabled": false},
		"ghost": {}
	}}`)
	ed := plugin_test_editor({
		{"merge.lua", `
			local defaults = {a = 1, nested = {b = 2, c = 3}, list = {1, 2}}
			return {
				defaults = defaults,
				setup = function(cfg)
					assert(cfg.a == 1, "default kept")
					assert(cfg.nested.b == 20 and cfg.nested.c == 3, "nested objects merge per key")
					assert(#cfg.list == 1 and cfg.list[1] == 9, "arrays replace wholesale")
					assert(cfg.bogus == nil, "unknown keys are ignored")
					assert(cfg.enabled == nil, "enabled is not part of the plugin config")
					assert(defaults.nested.b == 2, "defaults are not mutated")
				end,
			}`},
		{"off.lua", `return {setup = function() error("disabled plugins never run") end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)

	merge := plugin_find(&ed.plugins, "merge")
	testing.expect_value(t, merge.last_error, "")
	testing.expect_value(t, merge.state, PluginState.Enabled)
	off := plugin_find(&ed.plugins, "off")
	testing.expect_value(t, off.state, PluginState.Disabled)
	testing.expect_value(t, off.last_error, "")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `plugins/merge/"bogus"`), "unknown plugin key warns")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `plugins/"ghost"`), "unknown plugin name warns")
}

@(test)
plugin_commands_dispatch :: proc(t: ^testing.T) {
	cfg := plugin_test_cfg(`{"keybinds": {"Cmd: A": "Alt+k", "Cmd: Unbound": ""}}`)
	ed := plugin_test_editor({
		{"cmd.lua", `
			return {
				setup = function()
					qed.command{name = "Cmd: A", key = "Alt+j", run = function() qed.run("Cmd: B") end}
					qed.command{name = "Cmd: B", key = "Alt+q", run = function() runs = (runs or 0) + 1; qed.message("B " .. runs) end}
					qed.command{name = "Cmd: Unbound", key = "Alt+w", run = function() end}
					qed.command{name = "Cmd: Gated", key = "Alt+y", when = function(ctx) return ctx.selection_text ~= nil end, run = function(ctx) qed.message("sel " .. ctx.selection_text) end}
					qed.command{name = "Cmd: Fail", run = function() error("cmd failed") end}
					qed.command{name = "Cmd: Unknown", run = function() qed.run("No Such Command") end}
					qed.command{name = "Cmd: Tree", key = "Alt+j", scope = "filetree", run = function() qed.message("tree") end}
				end,
			}`},
		{"dupe.lua", `return {setup = function() qed.command{name = "Cmd: A", run = function() end} end}`},
		{"builtin.lua", `return {setup = function() qed.command{name = "Save", run = function() end} end}`},
		{"badkey.lua", `return {setup = function() qed.command{name = "Bad: Key", key = "Hyper+x", run = function() end} end}`},
		{"badscope.lua", `return {setup = function() qed.command{name = "Bad: Scope", scope = "nowhere", run = function() end} end}`},
		{"norun.lua", `return {setup = function() qed.command{name = "No: Run"} end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)

	for name in ([?]string{"dupe", "builtin", "badkey", "badscope", "norun"}) {
		testing.expectf(t, plugin_find(&ed.plugins, name).state == .Errored, "%s: invalid registration errors the plugin", name)
	}
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "dupe").last_error, "already exists"), "duplicate name rejected")

	alt :: proc(ch: rune) -> tb2.Event {return tb2.Event{type = .Key, ch = ch, mod = .Alt}}
	a, ok := plugin_command_for_event(ed, alt('k'), false)
	testing.expect(t, ok && a.name == "Cmd: A", "config keybind overrides the plugin key")
	testing.expect_value(t, a.shortcut, "Alt+k")
	_, old := plugin_command_for_event(ed, alt('j'), false)
	testing.expect(t, !old, "the plugin default key is gone once overridden")
	_, unbound := plugin_command_for_event(ed, alt('w'), false)
	testing.expect(t, !unbound, "an empty config bind unbinds")
	tree, tok := plugin_command_for_event(ed, alt('j'), true)
	testing.expect(t, tok && tree.name == "Cmd: Tree", "filetree scope dispatches only in the tree")

	plugin_command_chord(ed, a)
	testing.expect_value(t, ed.message, "B 1")
	testing.expect_value(t, ed.message_source, "cmd")

	gated, _ := plugin_test_command(ed, "Cmd: Gated")
	editor_clear_message(ed)
	plugin_command_chord(ed, gated)
	testing.expect_value(t, ed.message, "")
	b := editor_buffer(ed)
	b.selection = Cursor{0, 0}
	b.cursor = Cursor{0, 5}
	plugin_command_chord(ed, gated)
	testing.expect_value(t, ed.message, "sel hello")

	fail, _ := plugin_test_command(ed, "Cmd: Fail")
	command_run(ed, fail)
	pl := plugin_find(&ed.plugins, "cmd")
	testing.expect_value(t, pl.state, PluginState.Enabled)
	testing.expect(t, strings.contains(pl.last_error, "cmd failed"), "a command error is kept")
	testing.expect(t, plugin_test_logged(ed, .Error, "cmd", "cmd failed"), "a command error only logs")
	unknown, _ := plugin_test_command(ed, "Cmd: Unknown")
	command_run(ed, unknown)
	testing.expect(t, strings.contains(pl.last_error, "unknown command 'No Such Command'"), "qed.run rejects unknown names")

	ed.plugins.config_override = nil
	plugins_rebind(ed)
	a2, ok2 := plugin_command_for_event(ed, alt('j'), false)
	testing.expect(t, ok2 && a2.name == "Cmd: A", "rebinding without the override restores the plugin key")
}

@(test)
plugin_unload_cleans :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"keep.lua", `
			sentinel = setmetatable({}, {__gc = function() qed.log("info", "keep finalized") end})
			return {setup = function() qed.command{name = "Keep: Cmd", run = function() end} end}`},
		{"drop.lua", `
			big = string.rep("z", 1024 * 1024)
			sentinel = setmetatable({}, {__gc = function() qed.log("info", "drop finalized") end})
			return {setup = function()
				qed.command{name = "Drop: One", run = function() qed.message(big) end}
				qed.command{name = "Drop: Two", when = function() return #big > 0 end, run = function() qed.message(big) end}
			end}`},
	})
	defer plugin_test_destroy(ed)

	testing.expect_value(t, len(ed.plugins.commands), 3)
	drop := plugin_find(&ed.plugins, "drop")
	env := drop.env
	before := ed.plugins.mem.used
	plugin_unload(ed, drop)
	testing.expect_value(t, len(ed.plugins.commands), 1)
	testing.expect_value(t, ed.plugins.commands[0].name, "Keep: Cmd")
	testing.expect_value(t, drop.env, lua.NOREF)
	testing.expect(t, lua.rawgeti(ed.plugins.L, lua.REGISTRYINDEX, lua.Integer(env)) != .TABLE, "env ref released")
	lua.pop(ed.plugins.L, 1)
	testing.expect(t, ed.plugins.mem.used < before - 1024 * 1024 / 2, "command closures no longer pin the env")
	testing.expect(t, !plugin_test_logged(ed, .Info, "drop", "finalized"), "a finalizer outside a plugin call cannot reach the qed API")
}

@(test)
plugin_run_refused_while_loading :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"early.lua", `return {setup = function() qed.run("Save") end}`},
	})
	defer plugin_test_destroy(ed)

	early := plugin_find(&ed.plugins, "early")
	testing.expect_value(t, early.state, PluginState.Errored)
	testing.expect(t, strings.contains(early.last_error, "unavailable while plugins load"), "qed.run is refused during setup")
}

@(test)
plugin_keybind_warnings :: proc(t: ^testing.T) {
	cfg := plugin_test_cfg(`{"keybinds": {"Clash: User": "Ctrl+s", "Clash: Bad": "Hyper+q", "No Such Command": "Alt+x"}}`)
	ed := plugin_test_editor({
		{"clash.lua", `
			return {setup = function()
				qed.command{name = "Clash: Default", key = "Ctrl+q", run = function() end}
				qed.command{name = "Clash: User", run = function() end}
				qed.command{name = "Clash: Bad", key = "Alt+j", run = function() end}
			end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)

	plugins_rebind(ed)
	for name in ([?]string{"Clash: Default", "Clash: User", "Clash: Bad"}) {
		cmd, _ := plugin_test_command(ed, name)
		testing.expectf(t, cmd.shortcut == "", "%s stays unbound", name)
	}
	testing.expect(t, plugin_test_logged(ed, .Warn, "clash", `keybinds/Clash: Default (Ctrl+q is "Quit")`), "a plugin key taken by a builtin warns under the plugin")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `keybinds/Clash: User (Ctrl+s is "Save")`), "a user bind taken by a builtin warns as config")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", "keybinds/Clash: Bad"), "an invalid user bind warns")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `unknown keybinds/"No Such Command"`), "an unknown keybind name warns")
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `unknown keybinds/"Clash: User"`), "plugin command names are known keybinds")
}
