package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import lua "lib:lua"

reload_seq: int

reload_dir :: proc() -> string {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_reload_test_%d_%d", tmp, posix.getpid(), sync.atomic_add(&reload_seq, 1))
	os.make_directory(dir)
	return dir
}

reload_write :: proc(dir, name, src: string) {
	path := fmt.tprintf("%s/%s", dir, name)
	if slash := strings.last_index_byte(path, '/'); slash > len(dir) {
		os.make_directory_all(path[:slash])
	}
	_ = os.write_entire_file(path, transmute([]u8)src)
}

reload_editor :: proc(bundled: []PluginFile, dir: string, cfg_user: json.Object = nil) -> ^Editor {
	ed := plugin_test_editor(bundled, dir, cfg_user)
	plugins_rebind(ed)
	plugin_pump(ed)
	return ed
}

reload_names :: proc(ed: ^Editor) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for pl in ed.plugins.list {
		append(&names, fmt.tprintf("%s:%s:%v", pl.name, "b" if pl.bundled else "u", pl.state))
	}
	return strings.join(names[:], " ", context.temp_allocator)
}

reload_logged_count :: proc(ed: ^Editor, level: LogLevel, source, fragment: string) -> int {
	n := 0
	for e in ed.log {
		if e.level == level && e.source == source && strings.contains(e.text, fragment) {
			n += 1
		}
	}
	return n
}

reload_owned :: proc(p: ^Plugins, name: string) -> int {
	n := 0
	for h in p.hooks {
		n += int(h.owner == name)
	}
	for tm in p.timers {
		n += int(tm.owner == name)
	}
	for pr in p.procs {
		n += int(pr.owner == name)
	}
	for tk in p.tasks {
		n += int(tk.owner == name)
	}
	for th in p.pool {
		n += int(th.owner == name)
	}
	for cmd in p.commands {
		n += int(cmd.owner == name)
	}
	for v in p.views {
		n += int(v.owner == name)
	}
	for tm in container_of(p, Editor, "plugins").terminal.list {
		n += int(tm.owner == name)
	}
	return n
}

@(test)
plugin_reload_file_edit :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	reload_write(dir, "a.lua", `
		big = string.rep("a", 1024 * 1024)
		return {setup = function()
			qed.command{name = "Ver", run = function() qed.message("v1") end}
			qed.every(1000, function() end)
			qed.on("buf_save", function() end)
		end}`)
	ed := reload_editor({{"base.lua", `return {}`}}, dir)
	defer plugin_test_destroy(ed)

	testing.expect(t, !plugins_poll(ed), "an unchanged dir does not reload")
	before := ed.plugins.mem.used
	reload_write(dir, "a.lua", `return {setup = function() qed.command{name = "Ver", run = function() qed.message("v2!") end} end}`)
	testing.expect(t, plugins_poll(ed), "an edited file reloads")
	testing.expect_value(t, reload_names(ed), "base:b:Enabled a:u:Enabled")
	testing.expect(t, ed.plugins.mem.used < before - 512 * 1024, "the old incarnation's memory is reclaimed")
	testing.expect_value(t, len(ed.plugins.timers), 0)
	testing.expect_value(t, len(ed.plugins.hooks), 0)
	testing.expect_value(t, len(ed.plugins.commands), 1)
	sched_run(t, ed, "A: Ver")
	testing.expect_value(t, ed.message, "v2!")
	testing.expect(t, plugin_test_logged(ed, .Info, "A", "reloaded"), "the reload is reported")
	testing.expect(t, !plugins_poll(ed), "the new stamp is kept")
}

@(test)
plugin_reload_dir_plugin :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	reload_write(dir, "dp/init.lua", `return {setup = function() qed.command{name = "Dp: Ver", run = function() qed.message(require("sub.lib").v) end} end}`)
	reload_write(dir, "dp/sub/lib.lua", `return {v = "one"}`)
	ed := reload_editor({}, dir)
	defer plugin_test_destroy(ed)

	sched_run(t, ed, "Dp: Ver")
	testing.expect_value(t, ed.message, "one")
	reload_write(dir, "dp/sub/lib.lua", `return {v = "three"}`)
	testing.expect(t, plugins_poll(ed), "a file nested inside a dir plugin reloads it")
	sched_run(t, ed, "Dp: Ver")
	testing.expect_value(t, ed.message, "three")
	reload_write(dir, "dp/sub/new.lua", "return {}")
	testing.expect(t, plugins_poll(ed), "a Lua file added inside a dir plugin reloads it")
	reload_write(dir, "dp/notes.txt", "x")
	reload_write(dir, "dp/.init.lua.swp", "x")
	reload_write(dir, "dp/.git/HEAD", "x")
	reload_write(dir, "dp/.git/hooks/x.lua", "x")
	reload_write(dir, ".hidden.lua", "return {}")
	reload_write(dir, ".hiddendir/init.lua", "return {}")
	reload_write(dir, "target/lib.lua", "return {}")
	e2e_run(fmt.tprintf("ln -s %s %s", shell_quote(fmt.tprintf("%s/target", dir)), shell_quote(fmt.tprintf("%s/dp/linked", dir))))
	testing.expect(t, !plugins_poll(ed), "non-Lua files, dot entries, dot plugins and symlinks inside a dir plugin are ignored")
	reload_write(dir, "target/lib.lua", "return {v = 1}")
	testing.expect(t, !plugins_poll(ed), "a symlink below the top level is not followed")
	testing.expect_value(t, reload_names(ed), "dp:u:Enabled")
}

@(test)
plugin_reload_add_remove :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	reload_write(dir, "a.lua", `
		starts = 0
		return {setup = function() qed.on("startup", function() starts = starts + 1 end) end}`)
	ed := reload_editor({{"base.lua", `return {}`}}, dir)
	defer plugin_test_destroy(ed)
	testing.expect_value(t, sched_var(ed, "starts"), "1")

	reload_write(dir, "c.lua", `return {setup = function()
		qed.command{name = "Cmd", run = function() end}
		qed.on("startup", function() c_started = true end)
	end}`)
	reload_write(dir, "b.lua", `big = string.rep("b", 1024 * 1024) return {setup = function() qed.command{name = "Cmd", run = function() end} end}`)
	testing.expect(t, plugins_poll(ed), "added files load")
	testing.expect_value(t, reload_names(ed), "base:b:Enabled a:u:Enabled b:u:Enabled c:u:Enabled")
	plugin_pump(ed)
	testing.expect_value(t, sched_var(ed, "c_started"), "true")
	testing.expect_value(t, sched_var(ed, "starts"), "1")

	before := ed.plugins.mem.used
	os.remove(fmt.tprintf("%s/b.lua", dir))
	testing.expect(t, plugins_poll(ed), "a removed file unloads")
	testing.expect_value(t, reload_names(ed), "base:b:Enabled a:u:Enabled c:u:Enabled")
	_, has_b := plugin_test_command(ed, "B: Cmd")
	testing.expect(t, !has_b, "a removed plugin's commands go")
	testing.expect_value(t, reload_owned(&ed.plugins, "b"), 0)
	testing.expect(t, ed.plugins.mem.used < before - 512 * 1024, "a removed plugin's memory is reclaimed")
	testing.expect(t, plugin_test_logged(ed, .Info, "B", "unloaded"), "the removal is reported")

	reload_write(dir, "b.lua", `return {setup = function() qed.command{name = "Again", run = function() end} end}`)
	testing.expect(t, plugins_poll(ed), "a plugin can come back under the same name")
	_, again := plugin_test_command(ed, "B: Again")
	testing.expect(t, again, "the returning plugin loads")
	testing.expect_value(t, len(ed.plugins.names), 4)
}

@(test)
plugin_reload_shadowing :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	ed := reload_editor({
		{"sh.lua", `return {setup = function() qed.command{name = "Bundled", run = function() end} end}`},
		{"zz.lua", `return {}`},
	}, dir)
	defer plugin_test_destroy(ed)

	reload_write(dir, "sh.lua", `return {setup = function() qed.command{name = "User", run = function() end} end}`)
	testing.expect(t, plugins_poll(ed), "a same-name user plugin appears")
	testing.expect_value(t, reload_names(ed), "zz:b:Enabled sh:u:Enabled")
	_, bundled := plugin_test_command(ed, "Sh: Bundled")
	_, user := plugin_test_command(ed, "Sh: User")
	testing.expect(t, user && !bundled, "the user plugin shadows the bundled one")

	os.remove(fmt.tprintf("%s/sh.lua", dir))
	testing.expect(t, plugins_poll(ed), "the user plugin disappears")
	testing.expect_value(t, reload_names(ed), "sh:b:Enabled zz:b:Enabled")
	_, bundled = plugin_test_command(ed, "Sh: Bundled")
	_, user = plugin_test_command(ed, "Sh: User")
	testing.expect(t, bundled && !user, "the bundled plugin comes back in load order")
}

@(test)
plugin_reload_enabled_flip :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	reload_write(dir, "u.lua", `return {setup = function() qed.command{name = "Cmd", run = function() end} end}`)
	reload_write(dir, "bad.lua", `return {setup = function() error("boom") end}`)
	ed := reload_editor({{"bun.lua", `return {setup = function() qed.command{name = "Cmd", run = function() end} end}`}}, dir)
	defer plugin_test_destroy(ed)

	ed.plugins.config_override = plugin_test_cfg(`{"plugins": {"u": {"enabled": false}, "bun": {"enabled": false}, "bad": {"enabled": false}}}`)
	plugins_config_apply(ed, false)
	testing.expect_value(t, reload_names(ed), "bun:b:Disabled bad:u:Disabled u:u:Disabled")
	testing.expect_value(t, len(ed.plugins.commands), 0)

	ed.plugins.config_override = plugin_test_cfg(`{"plugins": {"u": {"enabled": true}}}`)
	plugins_config_apply(ed, false)
	testing.expect_value(t, reload_names(ed), "bun:b:Enabled bad:u:Errored u:u:Enabled")
	testing.expect_value(t, len(ed.plugins.commands), 2)
	testing.expect(t, plugin_test_logged(ed, .Info, "U", "enabled"), "enabling is reported")
	testing.expect(t, plugin_test_logged(ed, .Info, "U", "disabled"), "disabling is reported")
	plugins_config_apply(ed, false)
	testing.expect_value(t, reload_logged_count(ed, .Error, "Bad", "boom"), 2)

	ed.plugins.config_override = plugin_test_cfg(`{"plugins": {"u": {"enabled": false}}}`)
	plugins_config_apply(ed, false, parsed = false)
	testing.expect_value(t, reload_names(ed), "bun:b:Enabled bad:u:Errored u:u:Enabled")
	plugins_config_apply(ed, false)
	testing.expect_value(t, plugin_find(&ed.plugins, "u").state, PluginState.Disabled)
	os.remove(fmt.tprintf("%s/u.lua", dir))
	plugins_poll(ed)
	testing.expect(t, !plugin_test_logged(ed, .Info, "U", "unloaded"), "removing a disabled plugin is not reported as an unload")
}

@(test)
plugin_reload_config_change :: proc(t: ^testing.T) {
	ed := reload_editor({
		{"plain.lua", `
			loads = (loads or 0) + 1
			return {setup = function()
				local cfg = qed.options{greeting = "hi"}
				qed.command{name = "Greet", run = function() qed.message(cfg.greeting) end}
			end}`},
		{"aware.lua", `
			aware_loads = (aware_loads or 0) + 1
			return {setup = function()
				qed.options{greeting = "hi", list = {1}, other = 1}
				qed.on("config_changed", function(changed)
					local keys = {}
					for k in pairs(changed) do keys[#keys + 1] = k end
					table.sort(keys)
					seen, seen_keys = qed.config().greeting, table.concat(keys, ",")
				end)
			end}`},
	}, "")
	defer plugin_test_destroy(ed)

	ed.plugins.config_override = plugin_test_cfg(`{"plugins": {"plain": {"greeting": "yo"}, "aware": {"greeting": "hey"}}}`)
	plugins_config_apply(ed, false)
	sched_run(t, ed, "Plain: Greet")
	testing.expect_value(t, ed.message, "yo")
	testing.expect(t, plugin_test_logged(ed, .Info, "Plain", "reloaded (config changed)"), "a plugin without config_changed reloads")
	testing.expect(t, !plugin_test_logged(ed, .Info, "Aware", "reloaded"), "a plugin with config_changed keeps its state")
	testing.expect_value(t, sched_var(ed, "seen"), "hey")
	testing.expect_value(t, sched_var(ed, "seen_keys"), "greeting")
	testing.expect_value(t, sched_var(ed, "aware_loads"), "1")
	testing.expect_value(t, plugin_find(&ed.plugins, "aware").cfg_sig, plugin_cfg_sig("aware", ed.plugins.config_override.?))
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", "unknown"), "keys declared by qed.options are known after a reload")

	editor_clear_message(ed)
	plugins_config_apply(ed, false)
	testing.expect_value(t, reload_logged_count(ed, .Info, "Plain", "reloaded"), 1)
	testing.expect_value(t, sched_var(ed, "seen_keys"), "")

	ed.plugins.config_override = plugin_test_cfg(`{"plugins": {"plain": {"greeting": "yo"}, "aware": {"list": [2]}}}`)
	plugins_config_apply(ed, false)
	testing.expect_value(t, sched_var(ed, "seen_keys"), "greeting,list")
}

@(test)
plugin_reload_error_keeps_running :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	reload_write(dir, "e.lua", `return {setup = function() qed.command{name = "Cmd", run = function() end} end}`)
	reload_write(dir, "ok.lua", `return {setup = function() qed.command{name = "Cmd", run = function() qed.message("ok") end} end}`)
	ed := reload_editor({}, dir)
	defer plugin_test_destroy(ed)

	reload_write(dir, "e.lua", `return {setup = function( qed.command end}`)
	testing.expect(t, plugins_poll(ed), "the broken edit is noticed")
	e := plugin_find(&ed.plugins, "e")
	testing.expect_value(t, e.state, PluginState.Errored)
	testing.expect(t, e.last_error != "", "the syntax error is kept for the pane")
	_, has := plugin_test_command(ed, "E: Cmd")
	testing.expect(t, !has, "the broken plugin's old commands are gone")
	sched_run(t, ed, "Ok: Cmd")
	testing.expect_value(t, ed.message, "ok")

	reload_write(dir, "e.lua", `return {setup = function() qed.command{name = "Fixed", run = function() end} end}`)
	testing.expect(t, plugins_poll(ed), "the fix is noticed")
	e = plugin_find(&ed.plugins, "e")
	testing.expect_value(t, e.state, PluginState.Enabled)
	testing.expect_value(t, e.last_error, "")
}

@(test)
plugin_reload_keybind_order :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	ed := reload_editor({
		{"cmds.lua", `
			local handles = {}
			local function register(list)
				for _, h in ipairs(handles) do h:remove() end
				handles = {}
				for _, s in ipairs(list) do
					handles[#handles + 1] = qed.command{name = s.name, key = s.key, run = function() end}
				end
			end
			return {setup = function()
				register(qed.options{list = {}}.list)
				qed.on("config_changed", function() register(qed.config().list) end)
			end}`},
	}, dir)
	defer plugin_test_destroy(ed)

	ed.plugins.config_override = plugin_test_cfg(`{
		"plugins": {"cmds": {"keybinds": {"Late": "Alt+k"}, "list": [{"name": "Late"}, {"name": "Leave", "key": "Ctrl+q"}]}}
	}`)
	plugins_config_apply(ed, false)
	testing.expect(t, !plugin_test_logged(ed, .Warn, "", `"Late"`), "a keybind for a command added by config_changed is known")
	late, ok := plugin_test_command(ed, "Cmds: Late")
	testing.expect(t, ok && late.shortcut == "Alt+k", "the new command takes its user bind")
	testing.expect_value(t, reload_logged_count(ed, .Warn, "Cmds", `plugins/cmds/keybinds/Leave (Ctrl+q is "Quit")`), 1)

	reload_write(dir, "late.lua", `return {setup = function() qed.command{name = "Store", key = "Ctrl+s", run = function() end} end}`)
	plugins_poll(ed)
	testing.expect_value(t, reload_logged_count(ed, .Warn, "Late", `plugins/late/keybinds/Store (Ctrl+s is "Save")`), 1)
}

@(test)
plugin_reload_keeps_order :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	for name in ([?]string{"a", "b"}) {
		reload_write(dir, fmt.tprintf("%s.lua", name), `return {setup = function() qed.on("config_changed", function() qed.log("info", "cc") end) end}`)
	}
	ed := reload_editor({}, dir)
	defer plugin_test_destroy(ed)

	reload_write(dir, "a.lua", `return {setup = function() qed.on("config_changed", function() qed.log("info", "cc!") end) end}`)
	plugins_poll(ed)
	clear_log := len(ed.log)
	plugins_config_apply(ed, false)
	order := make([dynamic]string, context.temp_allocator)
	for e in ed.log[clear_log:] {
		if strings.has_prefix(e.text, "cc") {
			append(&order, e.source)
		}
	}
	testing.expect_value(t, strings.join(order[:], " ", context.temp_allocator), "A B")
}

@(test)
plugin_reload_refs_released :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	src := `
		big = string.rep("r", 1024 * 1024)
		return {setup = function()
			qed.command{name = "Sleep", run = function() qed.sleep(60000) end}
			qed.command{name = "Proc", run = function() p = qed.spawn_bg{cmd = "sleep 30"} end}
			qed.command{name = "Term", run = function() qed.term.create{name = "rterm", cmd = "sleep 30"} end}
			qed.every(20, function() end)
			qed.on("buf_save", function() end)
		end}`
	reload_write(dir, "r.lua", src)
	ed := reload_editor({}, dir)
	defer plugin_test_destroy(ed)
	baseline := ed.plugins.mem.used

	for _ in 0 ..< 3 {
		sched_run(t, ed, "R: Sleep")
		sched_run(t, ed, "R: Proc")
		sched_run(t, ed, "R: Term")
		testing.expect(t, term_find(ed, "rterm") != nil, "the plugin owns a terminal session")
		testing.expect(t, reload_owned(&ed.plugins, "r") > 5, "the plugin owns tasks, procs, timers, hooks and a session")
		pl := plugin_find(&ed.plugins, "r")
		pl.stamp = 0
		plugins_poll(ed)
	}
	testing.expect_value(t, len(ed.plugins.procs), 0)
	testing.expect_value(t, len(ed.plugins.tasks), 0)
	testing.expect_value(t, len(ed.terminal.list), 0)
	testing.expect(t, ed.plugins.mem.used < baseline + 256 * 1024, "repeated reloads do not grow the Lua heap")
	L := ed.plugins.L
	lua.gc(L, .COLLECT)
	refs := 0
	for i in 1 ..= 4096 {
		if lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(i)) == .FUNCTION {
			refs += 1
		}
		lua.pop(L, 1)
	}
	testing.expect_value(t, refs, 5)
}

@(test)
plugin_reload_shared_bind_sibling :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	src := `return {setup = function()
		qed.command{name = "A", scope = "filetree", run = function() end}
		qed.command{name = "A", key = "Alt+q", run = function() end}
	end}`
	reload_write(dir, "s.lua", src)
	ed := reload_editor({}, dir)
	defer plugin_test_destroy(ed)

	tree := proc(ed: ^Editor) -> string {
		for cmd in ed.plugins.commands {
			if cmd.scope == "filetree" {
				return cmd.shortcut
			}
		}
		return "?"
	}
	testing.expect_value(t, tree(ed), "Alt+q")
	reload_write(dir, "s.lua", fmt.tprintf("%s\n", src))
	testing.expect(t, plugins_poll(ed), "the edit reloads")
	testing.expect_value(t, tree(ed), "Alt+q")
}
