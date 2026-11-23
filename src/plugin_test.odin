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
	term_destroy(ed)
	plugins_shutdown(&ed.plugins)
	for &b in ed.buffers {
		buffer_destroy(&b)
	}
	delete(ed.buffers)
	editor_log_destroy(ed)
	jump_destroy(&ed.jumps)
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
	for cmd in ed.plugins.commands {
		if cmd.bare == name {
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
				setup = function()
					qed.command{name = "Greet", run = function(ctx)
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
	testing.expect_value(t, ed.message_source, "Hello")
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
					qed.command{name = "Cmd", run = function() end}
					local t = nil
					return t.field
				end,
			}`},
		{"fine.lua", `return {setup = function() qed.command{name = "Cmd", run = function() end} end}`},
	})
	defer plugin_test_destroy(ed)

	for pl in ed.plugins.list {
		if pl.name == "fine" {
			testing.expect_value(t, pl.state, PluginState.Enabled)
			continue
		}
		testing.expectf(t, pl.state == .Errored, "%s is errored", pl.name)
		testing.expectf(t, pl.last_error != "", "%s kept its last error", pl.name)
		testing.expectf(t, plugin_test_logged(ed, .Error, pl.display, ""), "%s logged an error under its name", pl.name)
	}
	crash := plugin_find(&ed.plugins, "crash")
	testing.expect(t, strings.contains(crash.last_error, "boom"), "runtime error message kept")
	testing.expect(t, !strings.contains(crash.last_error, "stack traceback"), "last error is the message, not the traceback")
	testing.expect(t, plugin_test_logged(ed, .Debug, "Crash", "stack traceback"), "traceback goes to the Debug log")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "notable").last_error, "must return a table {setup}"), "spec shape enforced")
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
	testing.expect(t, plugin_test_logged(ed, .Info, "B", "b sees\t1\tnil"), "print logs under the plugin, never to stdout")
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
	_ = os.write_entire_file(fmt.tprintf("%s/shadow.lua", dir), transmute([]u8)string(`return {setup = function() qed.command{name = "User", run = function() end} end}`))
	_ = os.write_entire_file(fmt.tprintf("%s/readme.md", dir), transmute([]u8)string("ignored"))

	ed := plugin_test_editor({
		{"shadow.lua", `return {setup = function() qed.command{name = "Bundled", run = function() end} end}`},
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
		{"small.lua", `return {setup = function() qed.command{name = "Cmd", run = function() qed.message(string.rep("y", 3)) end} end}`},
		{"evhog.lua", `return {setup = function()
			qed:on("buf_changed", function() local t = {} for i = 1, 1e7 do t[i] = string.rep("z", 64) .. i end end)
		end}`},
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

	plugin_flush(ed)
	buffer_insert_rune(editor_buffer(ed), 'x')
	plugin_flush(ed)
	evhog := plugin_find(&ed.plugins, "evhog")
	testing.expect_value(t, evhog.state, PluginState.Enabled)
	testing.expect(t, strings.contains(evhog.last_error, "buf_changed handler ran out of Lua memory and was stopped (cap 4 MB"), evhog.last_error)
	testing.expect(t, plugin_test_logged(ed, .Error, "Evhog", "ran out of Lua memory"), "a task out of memory is an error")
}

@(test)
plugin_memory_victim_stays :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"hog.lua", `return {setup = function() hold = {} for i = 1, 36 do hold[i] = string.rep(string.char(64 + i % 26), 100 * 1024) end end}`},
		{"small.lua", `return {setup = function()
			qed.command{name = "Big", run = function() local s = string.rep("y", 512 * 1024) qed.message(#s) end}
			qed.command{name = "Cmd", run = function() qed.message("ok") end}
		end}`},
	}, mem_cap = 4 * 1024 * 1024)
	defer plugin_test_destroy(ed)

	big, ok := plugin_test_command(ed, "Small: Big")
	testing.expect(t, ok, "big registered")
	for _ in 0 ..< 3 {
		command_run(ed, big)
	}
	small := plugin_find(&ed.plugins, "small")
	testing.expect_value(t, small.state, PluginState.Enabled)
	testing.expect_value(t, plugin_find(&ed.plugins, "hog").state, PluginState.Enabled)
	testing.expect(t, strings.contains(small.last_error, "command ran out of Lua memory and was stopped (cap 4 MB, "), small.last_error)
	cmd, _ := plugin_test_command(ed, "Small: Cmd")
	command_run(ed, cmd)
	testing.expect_value(t, ed.message, "ok")
}

@(test)
plugin_config_merge :: proc(t: ^testing.T) {
	cfg := plugin_test_cfg(`{"plugins": {
		"merge": {"nested": {"b": 20, "c": "x"}, "list": [9], "bogus": 1, "enabled": true, "a": "1", "s": null},
		"bare": {"stray": 1},
		"off": {"enabled": false, "typo": 1},
		"broken": {"typo": 1},
		"ghost": {},
		"lines": {},
		"ai": {"chat_command": "x"}
	}}`)
	ed := plugin_test_editor({
		{"merge.lua", `
			local defaults = {a = 1, nested = {b = 2, c = 3}, list = {1, 2}, s = "x"}
			return {
				setup = function(...)
					assert(select("#", ...) == 0, "setup gets no arguments")
					assert(next(qed.config()) == nil, "no keys before qed.options")
					local cfg = qed.options(defaults)
					assert(cfg.a == 1, "default kept, also over a value of the wrong type")
					assert(cfg.s == nil, "null drops a default")
					assert(cfg.nested.b == 20 and cfg.nested.c == 3, "nested objects merge per key")
					assert(#cfg.list == 1 and cfg.list[1] == 9, "arrays replace wholesale")
					assert(cfg.bogus == nil, "unknown keys are ignored")
					assert(cfg.enabled == nil, "enabled is not part of the plugin config")
					assert(defaults.nested.b == 2, "defaults are not mutated")
					cfg.a = 99
					assert(qed.config().a == 1 and qed.config().nested.b == 20, "qed.config matches and the result is a copy")
				end,
			}`},
		{"bare.lua", `return {setup = function() assert(next(qed.config()) == nil) end}`},
		{"off.lua", `return {setup = function() qed.options{a = 1} end}`},
		{"broken.lua", `return {setup = function() qed.options{} error("setup failed") end}`},
		{"ai.lua", `return {setup = function() assert(qed.options{edit_command = "y"}.edit_command == "y") end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)

	merge := plugin_find(&ed.plugins, "merge")
	testing.expect_value(t, merge.last_error, "")
	testing.expect_value(t, merge.state, PluginState.Enabled)
	testing.expect_value(t, plugin_find(&ed.plugins, "bare").last_error, "")
	off := plugin_find(&ed.plugins, "off")
	testing.expect_value(t, off.state, PluginState.Disabled)
	testing.expect_value(t, off.last_error, "")
	testing.expect_value(t, plugin_find(&ed.plugins, "broken").state, PluginState.Errored)
	testing.expect_value(t, reload_logged_count(ed, .Warn, "", `"plugins/merge/bogus"`), 1)
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"plugins/merge/a" (expected a number)`), "a value of the wrong type warns")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"plugins/merge/nested/c" (expected a number)`), "a nested value of the wrong type warns")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"plugins/bare/stray"`), "a plugin without qed.options has no keys")
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `plugins/off/`), "a disabled plugin's keys are not checked")
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `plugins/broken/`), "an errored plugin's keys are not checked")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"plugins/ghost"`), "unknown plugin name warns")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"plugins/lines" moved to "plugins/goto"`), "a renamed plugin says where")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"plugins/ai/chat_command" moved to "plugins/ai/edit_command"`), "a moved plugin key says where")

	ed.plugins.config_override = plugin_test_cfg(`{"plugins": {"merge": {"nested": {"b": 20}, "list": [9], "bogus": 1, "s": null}, "off": {"typo": 1}}}`)
	plugins_config_apply(ed, false)
	testing.expect_value(t, off.state, PluginState.Enabled)
	testing.expect_value(t, merge.state, PluginState.Enabled)
	testing.expect_value(t, reload_logged_count(ed, .Warn, "", `"plugins/off/typo"`), 1)
	testing.expect_value(t, reload_logged_count(ed, .Warn, "", `"plugins/merge/bogus"`), 2)
}

@(test)
plugin_options_misuse :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"top.lua", `
			local ok, err = pcall(qed.options, {a = 1})
			top_err = tostring(err)
			return {setup = function()
				qed.command{name = "Late", run = function() qed.options{a = 1} end}
			end}`},
		{"twice.lua", `return {setup = function() qed.options{a = 1} qed.options{a = 2} end}`},
		{"notable.lua", `return {setup = function() qed.options(1) end}`},
		{"reserved.lua", `return {setup = function() qed.options{keybinds = {}} end}`},
		{"reserved2.lua", `return {setup = function() qed.options{enabled = true} end}`},
	})
	defer plugin_test_destroy(ed)

	testing.expect(t, strings.contains(sched_var(ed, "top_err"), "only callable during setup"), "the main chunk cannot call qed.options")
	cmd, _ := plugin_test_command(ed, "Top: Late")
	command_run(ed, cmd)
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "top").last_error, "only callable during setup"), "a command cannot call qed.options")
	twice := plugin_find(&ed.plugins, "twice")
	testing.expect_value(t, twice.state, PluginState.Errored)
	testing.expect(t, strings.contains(twice.last_error, "once per load"), "a second call raises")
	testing.expect_value(t, plugin_find(&ed.plugins, "notable").state, PluginState.Errored)
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "reserved").last_error, "'keybinds' is reserved"), "keybinds is reserved")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "reserved2").last_error, "'enabled' is reserved"), "enabled is reserved")
}

@(test)
plugin_options_info :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"good.lua", `return {setup = function()
			qed.options({a = 1, mode = "x", nested = {k = "v"}}, {a = "The a knob", mode = {description = "Mode", choices = {"x", "y"}}})
		end}`},
		{"unknown.lua", `return {setup = function() qed.options({a = 1}, {b = "nope"}) end}`},
		{"field.lua", `return {setup = function() qed.options({a = 1}, {a = {desc = "typo"}}) end}`},
		{"choice.lua", `return {setup = function() qed.options({mode = "z"}, {mode = {choices = {"x", "y"}}}) end}`},
		{"empty.lua", `return {setup = function() qed.options({mode = "x"}, {mode = {choices = {}}}) end}`},
		{"probe.lua", `return {setup = function()
			qed.command{name = "Probe", run = function()
				for _, p in ipairs(qed.plugins()) do
					if p.id == "good" then
						probe = p.state .. " " .. p.options.a .. " " .. p.options.nested.k .. " " .. p.info.a .. " " .. p.info.mode.choices[2]
					elseif p.id == "unknown" then
						probe_unknown = p.state .. " " .. tostring(p.options)
					end
				end
			end}
		end}`},
	})
	defer plugin_test_destroy(ed)

	testing.expect_value(t, plugin_find(&ed.plugins, "good").state, PluginState.Enabled)
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "unknown").last_error, "info for unknown option 'b'"), "info must name a declared option")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "field").last_error, "unknown field 'desc'"), "info fields are checked")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "choice").last_error, "default must be one of the choices"), "the default is one of the choices")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "empty").last_error, "non-empty list of strings"), "choices must not be empty")
	cmd, _ := plugin_test_command(ed, "Probe: Probe")
	command_run(ed, cmd)
	testing.expect_value(t, sched_var(ed, "probe"), "enabled 1 v The a knob y")
	testing.expect_value(t, sched_var(ed, "probe_unknown"), "errored nil")
}

@(test)
plugin_commands_dispatch :: proc(t: ^testing.T) {
	cfg := plugin_test_cfg(`{"plugins": {"cmd": {"keybinds": {"A": "Alt+k", "Unbound": ""}}}}`)
	ed := plugin_test_editor({
		{"cmd.lua", `
			return {
				setup = function()
					qed.command{name = "A", key = "Alt+j", run = function() qed.run("B") end}
					qed.command{name = "B", key = "Alt+q", run = function() runs = (runs or 0) + 1; qed.message("B " .. runs) end}
					qed.command{name = "Unbound", key = "Alt+w", run = function() end}
					qed.command{name = "Gated", key = "Alt+y", when = function(ctx) return ctx.selection_text ~= nil end, run = function(ctx) qed.message("sel " .. ctx.selection_text) end}
					qed.command{name = "Fail", run = function() error("cmd failed") end}
					qed.command{name = "Unknown", run = function() qed.run("No Such Command") end}
					qed.command{name = "Tree", key = "Alt+j", scope = "filetree", run = function() qed.message("tree") end}
				end,
			}`},
		{"dupe.lua", `return {setup = function() qed.command{name = "A", run = function() end} qed.command{name = "A", run = function() end} end}`},
		{"terminal.lua", `return {setup = function() qed.command{name = "Toggle", run = function() end} end}`},
		{"core.lua", `return {setup = function() qed.command{name = "Save", run = function() end} end}`},
		{"badkey.lua", `return {setup = function() qed.command{name = "Bad: Key", key = "Hyper+x", run = function() end} end}`},
		{"badscope.lua", `return {setup = function() qed.command{name = "Bad: Scope", scope = "", run = function() end} end}`},
		{"norun.lua", `return {setup = function() qed.command{name = "No: Run"} end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)

	for name in ([?]string{"dupe", "terminal", "core", "badkey", "badscope", "norun"}) {
		testing.expectf(t, plugin_find(&ed.plugins, name).state == .Errored, "%s: invalid registration errors the plugin", name)
	}
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "dupe").last_error, "'Dupe: A' already exists"), "duplicate name rejected")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "terminal").last_error, "'Terminal: Toggle' already exists"), "a visible name equal to a builtin is rejected")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "core").last_error, "'Save' is a core command"), "a bare name equal to a core command is rejected")

	alt :: proc(ch: rune) -> tb2.Event {return tb2.Event{type = .Key, ch = ch, mod = .Alt}}
	a, ok := plugin_command_for_event(ed, alt('k'), "")
	testing.expect(t, ok && a.name == "Cmd: A", "config keybind overrides the plugin key")
	testing.expect_value(t, a.shortcut, "Alt+k")
	_, old := plugin_command_for_event(ed, alt('j'), "")
	testing.expect(t, !old, "the plugin default key is gone once overridden")
	_, unbound := plugin_command_for_event(ed, alt('w'), "")
	testing.expect(t, !unbound, "an empty config bind unbinds")
	tree, tok := plugin_command_for_event(ed, alt('j'), "filetree")
	testing.expect(t, tok && tree.name == "Cmd: Tree", "filetree scope dispatches only in the tree")

	plugin_command_chord(ed, a)
	testing.expect_value(t, ed.message, "B 1")
	testing.expect_value(t, ed.message_source, "Cmd")

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
	testing.expect(t, plugin_test_logged(ed, .Error, "Cmd", "cmd failed"), "a command error only logs")
	unknown, _ := plugin_test_command(ed, "Cmd: Unknown")
	command_run(ed, unknown)
	testing.expect(t, strings.contains(pl.last_error, "unknown command 'No Such Command'"), "qed.run rejects unknown names")

	ed.plugins.config_override = nil
	plugins_rebind(ed)
	a2, ok2 := plugin_command_for_event(ed, alt('j'), "")
	testing.expect(t, ok2 && a2.name == "Cmd: A", "rebinding without the override restores the plugin key")
}

@(test)
plugin_unload_cleans :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"keep.lua", `
			sentinel = setmetatable({}, {__gc = function() qed.log("keep finalized") end})
			return {setup = function() qed.command{name = "Cmd", run = function() end} end}`},
		{"drop.lua", `
			big = string.rep("z", 1024 * 1024)
			sentinel = setmetatable({}, {__gc = function() qed.log("drop finalized") end})
			return {setup = function()
				qed.command{name = "One", run = function() qed.message(big) end}
				qed.command{name = "Two", when = function() return #big > 0 end, run = function() qed.message(big) end}
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
	testing.expect(t, !plugin_test_logged(ed, .Info, "Drop", "finalized"), "a finalizer outside a plugin call cannot reach the qed API")
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
	cfg := plugin_test_cfg(`{"keybinds": {"No Such Command": "Alt+x"}, "plugins": {"clash": {"keybinds": {"User": "Ctrl+s", "Bad": "Hyper+q"}}}}`)
	ed := plugin_test_editor({
		{"clash.lua", `
			return {setup = function()
				qed.command{name = "Default", key = "Ctrl+q", run = function() end}
				qed.command{name = "User", run = function() end}
				qed.command{name = "Bad", key = "Alt+j", run = function() end}
			end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)

	plugins_rebind(ed)
	for name in ([?]string{"Clash: Default", "Clash: User", "Clash: Bad"}) {
		cmd, _ := plugin_test_command(ed, name)
		testing.expectf(t, cmd.shortcut == "", "%s stays unbound", name)
	}
	testing.expect(t, plugin_test_logged(ed, .Warn, "Clash", `plugins/clash/keybinds/Default (Ctrl+q is "Quit")`), "a plugin key taken by a builtin warns under the plugin")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `plugins/clash/keybinds/User (Ctrl+s is "Save")`), "a user bind taken by a builtin warns as config")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", "plugins/clash/keybinds/Bad"), "an invalid user bind warns")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `unknown "keybinds/No Such Command"`), "an unknown keybind name warns")
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `"User"`), "plugin command names are known plugin keybinds")
}

@(test)
plugin_meta_display :: proc(t: ^testing.T) {
	cfg := plugin_test_cfg(`{"plugins": {"off_one": {"enabled": false}}}`)
	ed := plugin_test_editor({
		{"my_tools.lua", `return {setup = function()
			qed.command{name = "Run", run = function() qed.message("ran") end}
		end}`},
		{"renamed.lua", `return {setup = function()
			qed.meta{display_name = "Gitty"}
			qed.command{name = "Base", run = function() qed.message("based") end}
			qed.command{name = "After", run = function() end}
		end}`},
		{"off_one.lua", `return {setup = function() qed.meta{display_name = "Never"} end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)

	testing.expect_value(t, plugin_title_case("git", context.temp_allocator), "Git")
	testing.expect_value(t, plugin_title_case("my_tools", context.temp_allocator), "My Tools")
	testing.expect_value(t, plugin_title_case("a_b2_c", context.temp_allocator), "A B2 C")
	testing.expect_value(t, plugin_find(&ed.plugins, "my_tools").display, "My Tools")
	run, ok := plugin_test_command(ed, "My Tools: Run")
	testing.expect(t, ok && run.bare == "Run" && run.config_name == "Run", "the visible name is prefixed with the title-cased id")
	command_run(ed, run)
	testing.expect_value(t, ed.message_source, "My Tools")

	testing.expect_value(t, plugin_find(&ed.plugins, "renamed").display, "Gitty")
	_, base := plugin_test_command(ed, "Gitty: Base")
	_, after := plugin_test_command(ed, "Gitty: After")
	testing.expect(t, base && after, "commands take the display name")
	_, stale := plugin_test_command(ed, "Renamed: Base")
	testing.expect(t, !stale, "the default prefix is gone")

	off := plugin_find(&ed.plugins, "off_one")
	testing.expect_value(t, off.state, PluginState.Disabled)
	testing.expect_value(t, off.display, "Off One")
	testing.expect_value(t, plugin_find(&ed.plugins, "renamed").display, "Gitty")

	ren := plugin_find(&ed.plugins, "renamed")
	plugin_enabled_set(ed, ren, false)
	testing.expect_value(t, ren.display, "Gitty")
	testing.expect(t, plugin_test_logged(ed, .Info, "Gitty", "disabled"), "disabling logs under the last display name")
	plugin_load(ed, ren)
	testing.expect_value(t, ren.display, "Gitty")
	testing.expect(t, plugin_test_logged(ed, .Debug, "Plugins", "loaded renamed"), "code identity stays the id")
}

@(test)
plugin_meta_misuse :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"top.lua", `
			local ok, err = pcall(qed.meta, {display_name = "X"})
			top_err = tostring(err)
			return {setup = function()
				qed.command{name = "Late", run = function() qed.meta{display_name = "Y"} end}
			end}`},
		{"twice.lua", `return {setup = function() qed.meta{display_name = "A"} qed.meta{display_name = "B"} end}`},
		{"unknown.lua", `return {setup = function() qed.meta{display_name = "A", version = 2} end}`},
		{"badtype.lua", `return {setup = function() qed.meta{display_name = 3} end}`},
		{"empty.lua", `return {setup = function() qed.meta{display_name = ""} end}`},
		{"baddesc.lua", `return {setup = function() qed.meta{description = 3} end}`},
		{"x_first.lua", `return {setup = function() qed.command{name = "Go", run = function() end} end}`},
		{"y_clash.lua", `return {setup = function() qed.meta{display_name = "x first"} end}`},
		{"z_late.lua", `return {setup = function()
			qed.command{name = "Go", run = function() end}
			qed.meta{display_name = "Late"}
		end}`},
		{"z_core.lua", `return {setup = function() qed.meta{display_name = "LSP"} end}`},
	})
	defer plugin_test_destroy(ed)

	testing.expect(t, strings.contains(sched_var(ed, "top_err"), "only callable during setup"), "the main chunk cannot call qed.meta")
	cmd, _ := plugin_test_command(ed, "Top: Late")
	command_run(ed, cmd)
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "top").last_error, "only callable during setup"), "a command cannot call qed.meta")
	expect := [?]struct {
		name, fragment: string,
	}{{"twice", "once per load"}, {"unknown", "unknown field 'version'"}, {"badtype", "display_name must be"}, {"empty", "display_name must be"}, {"baddesc", "description must be a string"}, {"y_clash", "display_name 'x first' is taken by plugin 'x_first'"}, {"z_late", "must come before qed.command()"}, {"z_core", "core log label"}}
	for e in expect {
		pl := plugin_find(&ed.plugins, e.name)
		testing.expectf(t, pl.state == .Errored && strings.contains(pl.last_error, e.fragment), "%s: %s (got %q)", e.name, e.fragment, pl.last_error)
	}
	_, late := plugin_test_command(ed, "Z Late: Go")
	testing.expect(t, !late, "a failed setup drops its commands")
	testing.expect_value(t, plugin_find(&ed.plugins, "twice").display, "A")
}

@(test)
plugin_palette_prefix_and_run :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"alpha.lua", `return {setup = function()
			qed.command{name = "Hello", run = function() qed.message("alpha hello") end}
			qed.command{name = "Bare", run = function() qed.run("Hello") end}
			qed.command{name = "Full", run = function() qed.run("Beta: Hello") end}
			qed.command{name = "Other", run = function() qed.run("Only") end}
		end}`},
		{"beta.lua", `return {setup = function()
			qed.command{name = "Hello", run = function() qed.message("beta hello") end}
			qed.command{name = "Only", run = function() end}
		end}`},
	})
	defer plugin_test_destroy(ed)

	palette_open(ed)
	labels := make([dynamic]string, context.temp_allocator)
	for it in test_pane_items(ed, pane_find(ed, "palette")) {
		append(&labels, it.label)
	}
	names := fmt.tprintf("|%s|", strings.join(labels[:], "|", context.temp_allocator))
	pane_end(ed, pane_find(ed, "palette").handle, false)
	delete(ed.panes)
	testing.expect(t, strings.contains(names, "|Alpha: Hello|") && strings.contains(names, "|Beta: Hello|"), "the palette shows prefixed names")
	testing.expect(t, !strings.contains(names, "|Hello|"), "no bare name in the palette")

	run := proc(ed: ^Editor, name: string) {
		cmd, _ := plugin_test_command(ed, name)
		command_run(ed, cmd)
	}
	run(ed, "Alpha: Bare")
	testing.expect_value(t, ed.message, "alpha hello")
	run(ed, "Alpha: Full")
	testing.expect_value(t, ed.message, "beta hello")
	testing.expect_value(t, ed.message_source, "Beta")
	run(ed, "Alpha: Other")
	testing.expect(t, strings.contains(plugin_find(&ed.plugins, "alpha").last_error, "unknown command 'Only'"), "a bare name resolves only within the caller")
}

@(test)
plugin_keybinds_namespaced :: proc(t: ^testing.T) {
	cfg := plugin_test_cfg(`{
		"keybinds": {"Run": "Alt+u", "File Tree: Restore File": "Alt+o"},
		"plugins": {
			"a": {"keybinds": {"Run": "Alt+k", "Nope": "Alt+x", "Search": "Alt+n"}},
			"b": {"keybinds": {}},
			"c": {"enabled": false, "keybinds": {"Whatever": "Alt+w"}}
		}
	}`)
	ed := plugin_test_editor({
		{"a.lua", `return {setup = function()
			qed.command{name = "Run", key = "Alt+1", run = function() end}
			qed.command{name = "Search", key = "Alt+j", run = function() end}
			qed.command{name = "Search Tree", keybind = "Search", scope = "filetree", run = function() end}
		end}`},
		{"b.lua", `return {setup = function() qed.command{name = "Run", key = "Alt+2", run = function() end} end}`},
		{"c.lua", `return {setup = function() qed.command{name = "Whatever", run = function() end} end}`},
		{"d.lua", `return {setup = function()
			qed.command{name = "Clash", key = "Alt+2", run = function() end}
			qed:on("startup", function() qed.command{name = "Later", run = function() end} end)
		end}`},
	}, cfg_user = cfg)
	defer plugin_test_destroy(ed)
	ed.plugins.config_override = plugin_test_cfg(`{
		"keybinds": {"Run": "Alt+u", "File Tree: Restore File": "Alt+o"},
		"plugins": {
			"a": {"keybinds": {"Run": "Alt+k", "Nope": "Alt+x", "Search": "Alt+n"}},
			"b": {"keybinds": {}},
			"c": {"enabled": false, "keybinds": {"Whatever": "Alt+w"}},
			"d": {"keybinds": {"Later": "Alt+3"}}
		}
	}`)
	plugins_rebind(ed)
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `"Nope"`), "unknown plugin keybinds wait for the startup flush")
	plugin_pump(ed)
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `"Later"`), "a command registered by a startup handler is known")
	testing.expect(t, plugin_test_logged(ed, .Warn, "D", `plugins/d/keybinds/Clash (Alt+2 is "B: Run")`), "a key taken by another plugin's command warns")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"keybinds/File Tree: Restore File" moved to "plugins/git/keybinds/Restore File"`), "old bundled bind names say where they moved")

	alt :: proc(ch: rune) -> tb2.Event {return tb2.Event{type = .Key, ch = ch, mod = .Alt}}
	a, aok := plugin_command_for_event(ed, alt('k'), "")
	testing.expect(t, aok && a.name == "A: Run", "plugins.a.keybinds overrides a's key")
	_, old := plugin_command_for_event(ed, alt('1'), "")
	testing.expect(t, !old, "a's default is replaced")
	b, bok := plugin_command_for_event(ed, alt('2'), "")
	testing.expect(t, bok && b.name == "B: Run", "the same bare name in b keeps its own key")
	tree, tok := plugin_command_for_event(ed, alt('n'), "filetree")
	testing.expect(t, tok && tree.name == "A: Search Tree", "keybind shares the bind key within the plugin")
	ed_search, sok := plugin_command_for_event(ed, alt('n'), "")
	testing.expect(t, sok && ed_search.name == "A: Search", "both sharing commands move together")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `unknown "plugins/a/keybinds/Nope"`), "an unknown command in a loaded plugin's keybinds warns")
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `plugins/a/keybinds/"Run"`), "known commands do not warn")
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", "Whatever"), "a disabled plugin's keybinds do not warn")
	testing.expect(t, plugin_test_logged(ed, .Warn, "", `"keybinds/Run" moved to "plugins/`), "a plugin command in the top-level keybinds warns where it moved")

	plugin_enabled_set(ed, plugin_find(&ed.plugins, "b"), false)
	_, gone := plugin_command_for_event(ed, alt('2'), "")
	testing.expect(t, !gone, "disabling a plugin drops its binds")

	ed.plugins.config_override = plugin_test_cfg(`{"plugins": {"a": {"keybinds": {"Run": 5}}}}`)
	plugins_config_apply(ed, false)
	testing.expect(t, plugin_test_logged(ed, .Warn, "", "plugins/a/keybinds/Run"), "an invalid plugin bind warns")
	shared, shok := plugin_command_for_event(ed, alt('j'), "filetree")
	testing.expect(t, shok && shared.name == "A: Search Tree", "a keybind sharer without key takes the shared default")
	_, a1 := plugin_command_for_event(ed, alt('1'), "")
	testing.expect(t, !a1, "an invalid user bind leaves the command unbound")
}

@(test)
plugin_ctx_selection_lazy :: proc(t: ^testing.T) {
	lines := make([]string, 200_000)
	defer delete(lines)
	for &l in lines {
		l = "abcdefghijabcdefghijabcdefghijabcdefghij"
	}
	ed := new(Editor)
	ed.headless = true
	append(&ed.buffers, test_buffer(..lines))
	editor_plugins_start(ed, {{"lazy.lua", `return {setup = function()
		qed.command{name = "Skip", run = function() qed.message("ran") end}
		qed.command{name = "Read", run = function(ctx) qed.message(tostring(#ctx.selection_text)) end}
		qed.command{name = "Late", run = function(ctx)
			qed.edit(ctx.buf, function() ctx.buf:insert({row = 1, col = 1}, "x") end)
			qed.message(tostring(ctx.selection_text))
		end}
	end}`}}, "", 4 * 1024 * 1024)
	defer plugin_test_destroy(ed)
	cursor_select_all(&ed.buffers[0])
	skip, _ := plugin_test_command(ed, "Lazy: Skip")
	command_run(ed, skip)
	testing.expect_value(t, ed.message, "ran")
	testing.expect(t, ed.plugins.mem.used < 2 * 1024 * 1024, "a command that never reads the selection copies none of it")
	cursor_select_all(&ed.buffers[0])
	ed.buffers[0].selection = Cursor{0, 0}
	ed.buffers[0].cursor = Cursor{0, 5}
	read, _ := plugin_test_command(ed, "Lazy: Read")
	command_run(ed, read)
	testing.expect_value(t, ed.message, "5")
	late, _ := plugin_test_command(ed, "Lazy: Late")
	command_run(ed, late)
	testing.expect_value(t, ed.message, "nil")
}

@(test)
plugin_gc_runs_between_slices :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"junk.lua", `return {setup = function()
			qed.command{name = "Junk", run = function() local t = {} for i = 1, 100000 do t[i] = {i} end end}
		end}`},
	})
	defer plugin_test_destroy(ed)

	cmd, ok := plugin_test_command(ed, "Junk: Junk")
	testing.expect(t, ok, "junk registered")
	before := ed.plugins.mem.used
	command_run(ed, cmd)
	testing.expect(t, ed.plugins.mem.used > before + 4 * 1024 * 1024, "a slice leaves its garbage for later")
	for i := 0; i < 10_000 && ed.plugins.mem.used > before + 1024 * 1024; i += 1 {
		plugin_pump(ed)
	}
	testing.expect(t, ed.plugins.mem.used < before + 1024 * 1024, "pumps collect it")
}

@(private = "file")
gc_test_count :: proc(t: ^testing.T, ed: ^Editor, name: string) -> string {
	cmd, ok := plugin_test_command(ed, name)
	testing.expect(t, ok, name)
	command_run(ed, cmd)
	return ed.message
}

@(test)
plugin_gc_paces_near_the_cap :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"fin.lua", `
			hold = {}
			for i = 1, 105 do hold[i] = string.rep(string.char(65 + i % 26), 100 * 1024) end
			fins = 0
			return {setup = function()
				qed.command{name = "Drop", run = function() hold = nil end}
				qed.command{name = "Junk", run = function()
					local s = string.rep("j", 1024 * 1024)
					setmetatable({}, {__gc = function() fins = fins + 1 end})
				end}
				qed.command{name = "Count", run = function() qed.message(fins >= 280 and "most" or tostring(fins)) end}
			end}`},
	})
	defer plugin_test_destroy(ed)

	for i := 0; i < 10_000 && (ed.plugins.gc_active || ed.plugins.gc_base == 0); i += 1 {
		plugin_pump(ed)
	}
	testing.expectf(t, ed.plugins.gc_base > PLUGIN_TEST_MEM / 2, "a cycle ended above half the cap (%d)", ed.plugins.gc_base)
	gc_test_count(t, ed, "Fin: Drop")
	junk, _ := plugin_test_command(ed, "Fin: Junk")
	for _ in 0 ..< 300 {
		command_run(ed, junk)
		plugin_pump(ed)
	}
	for i := 0; i < 10_000 && ed.plugins.gc_active; i += 1 {
		plugin_pump(ed)
	}
	testing.expect(t, ed.plugins.gc_base < PLUGIN_TEST_MEM / 2, "the pacer follows the heap down")
	testing.expect_value(t, gc_test_count(t, ed, "Fin: Count"), "most")
}

@(test)
plugin_gc_steps_while_typing :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"hog.lua", `return {setup = function()
			qed:on("buf_changed", function() n = (n or 0) + 1 local s = string.rep("h", 1536 * 1024) end)
			qed.command{name = "N", run = function() qed.message(tostring(n)) end}
		end}`},
	})
	defer plugin_test_destroy(ed)

	no_peek :: proc(ms: int) -> (tb2.Event, bool) {return {}, false}
	plugin_flush(ed)
	test_gc_steps, test_gc_cycles, test_gc_shrinks = 0, 0, 0
	peak := 0
	for _ in 0 ..< 200 {
		editor_step(ed, tb2.Event{type = .Key, ch = 'x'}, no_peek)
		peak = max(peak, ed.plugins.mem.used)
	}
	testing.expect_value(t, gc_test_count(t, ed, "Hog: N"), "200")
	testing.expectf(t, test_gc_steps >= 200, "every keystroke steps the collector (%d steps)", test_gc_steps)
	testing.expectf(t, test_gc_cycles >= 20, "and cycles finish (%d)", test_gc_cycles)
	testing.expect_value(t, test_gc_shrinks, 0)
	testing.expectf(t, peak < PLUGIN_TEST_MEM / 2, "the heap stays far from the cap (peak %d)", peak)
}

@(private = "file")
gc_test_no_idle :: proc(t: ^testing.T, live, rows, mem_cap, keys: int) -> (start, peak: int) {
	ed := plugin_test_editor({
		{"tree.lua", strings.concatenate({fmt.tprintf("LIVE, ROWS = %d, %d\n", live, rows), `
			hold = {}
			return {setup = function()
				qed:on("buf_changed", function()
					if #hold < LIVE then
						for i = #hold + 1, math.min(LIVE, #hold + 50000) do hold[i] = {path = "dir/file" .. i, size = i} end
						return
					end
					local rows = {}
					for i = 1, ROWS do rows[i] = {key = i, spans = {{"a", "s"}, {"b", "t"}}} end
				end)
			end}`}, context.temp_allocator)},
	}, mem_cap = mem_cap)
	defer plugin_test_destroy(ed)

	no_peek :: proc(ms: int) -> (tb2.Event, bool) {return {}, false}
	plugin_flush(ed)
	for _ in 0 ..< live / 50000 + 1 {
		editor_step(ed, tb2.Event{type = .Key, ch = 'x'}, no_peek)
	}
	start = ed.plugins.mem.used
	test_alloc_refusals, test_gc_debt_steps_max = 0, 0
	for _ in 0 ..< keys {
		editor_step(ed, tb2.Event{type = .Key, ch = 'x'}, no_peek)
		peak = max(peak, ed.plugins.mem.used)
	}
	testing.expect_value(t, test_alloc_refusals, 0)
	testing.expectf(t, peak < mem_cap * 7 / 8, "garbage made with no idle time never reaches the cap (peak %d MB)", peak / (1024 * 1024))
	return
}

@(test)
plugin_gc_keeps_up_without_idle :: proc(t: ^testing.T) {
	gc_test_no_idle(t, 100_000, 10_000, 256 * 1024 * 1024, 200)
}

@(test)
plugin_gc_bounded_near_the_cap :: proc(t: ^testing.T) {
	cap := 128 * 1024 * 1024
	start, _ := gc_test_no_idle(t, 450_000, 1000, cap, 100)
	testing.expectf(t, start > cap / 2, "the heap starts past half the cap (%d MB)", start / (1024 * 1024))
	testing.expectf(t, test_gc_debt_steps_max <= PLUGIN_GC_DEBT_STEPS * PLUGIN_GC_NEAR_CAP_SCALE, "one call pays a bounded share of the backlog (%d steps)", test_gc_debt_steps_max)
}

@(test)
plugin_gc_step_frees_bounded :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"churn.lua", `
			hold = {}
			for i = 1, 20000 do hold[i] = {i} end
			return {setup = function()
				qed.command{name = "Junk", run = function() local t = {} for i = 1, 50000 do t[i] = {i} end end}
			end}`},
	})
	defer plugin_test_destroy(ed)

	for i := 0; i < 10_000 && plugin_gc_due(&ed.plugins); i += 1 {
		plugin_gc_step(ed)
	}
	base := ed.plugins.mem.used
	test_gc_step_frees_max, test_gc_cycles = 0, 0
	junk, _ := plugin_test_command(ed, "Churn: Junk")
	command_run(ed, junk)
	plugin_gc_step(ed)
	command_run(ed, junk)
	for i := 0; i < 100_000 && test_gc_cycles < 2; i += 1 {
		ed.plugins.gc_active = true
		plugin_gc_step(ed)
	}
	testing.expect_value(t, test_gc_cycles, 2)
	testing.expectf(t, ed.plugins.mem.used < base + 1024 * 1024, "and collects the garbage (%d over)", ed.plugins.mem.used - base)
	testing.expectf(t, test_gc_step_frees_max > 0 && test_gc_step_frees_max < 10_000, "one collector step frees a bounded batch (%d)", test_gc_step_frees_max)
}

@(test)
plugin_gc_collectgarbage_options :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"gc.lua", `return {setup = function()
			qed.command{name = "Try", run = function()
				local out = {}
				for _, opt in ipairs({"generational", "incremental", "restart", "stop", "isrunning", "setpause"}) do
					out[#out + 1] = opt .. "=" .. tostring((pcall(collectgarbage, opt)))
				end
				out[#out + 1] = "count=" .. type(collectgarbage("count"))
				out[#out + 1] = "step=" .. type(collectgarbage("step"))
				junk = string.rep("g", 4 * 1024 * 1024)
				junk = nil
				out[#out + 1] = "collect=" .. tostring(collectgarbage())
				qed.message(table.concat(out, " "))
			end}
		end}`},
	})
	defer plugin_test_destroy(ed)

	testing.expect_value(t, gc_test_count(t, ed, "Gc: Try"), "generational=false incremental=false restart=false stop=false isrunning=false setpause=false count=number step=boolean collect=0")
	testing.expect(t, !ed.plugins.gc_active, "a plugin's collect ends any pacer cycle")
	testing.expectf(t, ed.plugins.gc_base < 4 * 1024 * 1024, "and rebases it (%d)", ed.plugins.gc_base)
}
