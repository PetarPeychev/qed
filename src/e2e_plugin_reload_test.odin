package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "lib:tb2"

e2e_reload_start :: proc() -> (E2E, string) {
	e := e2e_start("abc")
	dir := reload_dir()
	e.ed.plugins.user_dir = strings.clone(dir)
	e.ed.plugins.persist_path = fmt.aprintf("%s/config.json", dir)
	plugin_pump(&e.ed)
	return e, dir
}

e2e_reload_stop :: proc(e: ^E2E, dir: string) {
	e2e_stop(e)
	e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
}

e2e_reload_select :: proc(e: ^E2E, name: string) {
	for pl, i in e.ed.plugins.list {
		if pl.name == name {
			e.ed.pluginview.selected = i
		}
	}
}

e2e_reload_row_y :: proc(e: ^E2E, name: string) -> int {
	lay := logview_layout(&e.ed)
	for pl, i in e.ed.plugins.list {
		if pl.name == name {
			return lay.body_top + i - e.ed.pluginview.scroll
		}
	}
	return -1
}

@(test)
e2e_plugin_reload_teardown :: proc(t: ^testing.T) {
	e, dir := e2e_reload_start()
	defer e2e_reload_stop(&e, dir)

	reload_write(dir, "t.lua", `
		big = string.rep("z", 2 * 1024 * 1024)
		return {setup = function()
			qed.command{name = "T: Pick", run = function() picked = qed.pick{items = {"a", "b"}} end}
			qed.command{name = "T: Sleep", run = function() qed.sleep(60000) end}
			qed.command{name = "T: Proc", run = function() proc = qed.spawn_bg{cmd = "sleep 30 & sleep 30; wait"} end}
			qed.every(20, function() end)
		end}`)
	testing.expect(t, plugins_poll(&e.ed), "the new user plugin loads")
	p := &e.ed.plugins
	for name in ([?]string{"T: Sleep", "T: Proc", "T: Pick"}) {
		cmd, ok := plugin_test_command(&e.ed, name)
		if testing.expectf(t, ok, "%s registered", name) {
			command_run(&e.ed, cmd)
		}
	}
	testing.expect(t, p.ui.active, "the pick modal is open")
	owned_procs := proc(p: ^Plugins) -> (n: int) {
		for pr in p.procs {
			n += int(pr.owner == "t")
		}
		return
	}
	testing.expect_value(t, owned_procs(p), 1)
	testing.expect(t, reload_owned(p, "t") >= 6, "commands, tasks, process and timer are owned")
	pgid: posix.pid_t
	for pr in p.procs {
		if pr.owner == "t" {
			pgid = posix.pid_t(pr.sp.process.pid)
		}
	}
	before := p.mem.used

	reload_write(dir, "t.lua", `return {setup = function()
		qed.on("startup", function() qed.pane{title = "Hello pane", lines = {"x"}} end)
	end}`)
	testing.expect(t, plugins_poll(&e.ed), "the edit reloads")
	testing.expect(t, !p.ui.active, "the modal closes")
	testing.expect_value(t, owned_procs(p), 0)
	testing.expect(t, posix.kill(-pgid, posix.Signal(0)) != .OK, "the process group is gone")
	testing.expect_value(t, reload_owned(p, "t"), 1)
	testing.expect(t, p.mem.used < before - 1024 * 1024, "the old incarnation's heap is reclaimed")
	plugin_pump(&e.ed)
	testing.expect(t, p.pane.active, "a plugin loaded at runtime gets its startup event")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Hello pane"), "the pane renders")

	reload_write(dir, "t.lua", `return {setup = function() end}`)
	plugins_poll(&e.ed)
	testing.expect(t, !p.pane.active, "the pane closes on reload")
	testing.expect_value(t, reload_owned(p, "t"), 0)
	e2e_render(&e)
}

@(test)
e2e_plugin_pane_actions :: proc(t: ^testing.T) {
	e, dir := e2e_reload_start()
	defer e2e_reload_stop(&e, dir)

	reload_write(dir, "alpha.lua", `return {setup = function()
		qed.log("info", "alpha says hi")
		qed.command{name = "Alpha: Cmd", run = function() end}
	end}`)
	plugins_poll(&e.ed)
	editor_log(&e.ed, .Info, "other", "not alpha")

	e2e_key(&e, .Ctrl_P)
	e2e_type(&e, "debug: plugins")
	e2e_key(&e, .Enter)
	v := &e.ed.pluginview
	testing.expect(t, v.active, "the pane opens")
	e2e_reload_select(&e, "alpha")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "alpha    user     enabled"), "the user plugin row")

	_ = os.write_entire_file(e.ed.plugins.persist_path, transmute([]u8)string(`{"tab_width": 2}`))
	stamp := DiskStamp{mtime = 42, ok = true}
	e.ed.config_stamp = stamp
	e2e_key(&e, tb2.Key(0), {}, 'e')
	testing.expect(t, e.ed.config_stamp == stamp, "e leaves the config stamp so the next poll still reloads an external edit")
	alpha := plugin_find(&e.ed.plugins, "alpha")
	testing.expect_value(t, alpha.state, PluginState.Disabled)
	_, has := plugin_test_command(&e.ed, "Alpha: Cmd")
	testing.expect(t, !has, "disabling unloads")
	data, _ := os.read_entire_file(e.ed.plugins.persist_path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"alpha": {`) && strings.contains(string(data), `"enabled": false`), "e persists only plugins.alpha.enabled")
	testing.expect(t, strings.contains(string(data), `"tab_width": 2`), "an unpolled external edit survives the persist")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "alpha    user     disabled"), "the row shows disabled")

	e2e_key(&e, tb2.Key(0), {}, 'r')
	testing.expect(t, strings.contains(e.ed.message, "alpha is disabled"), "r on a disabled plugin explains")

	e2e_key(&e, tb2.Key(0), {}, 'e')
	alpha = plugin_find(&e.ed.plugins, "alpha")
	testing.expect_value(t, alpha.state, PluginState.Enabled)
	data, _ = os.read_entire_file(e.ed.plugins.persist_path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"enabled": true`), "e persists the flip back")

	e2e_key(&e, tb2.Key(0), {}, 'r')
	testing.expect_value(t, reload_logged_count(&e.ed, .Info, "alpha", "reloaded"), 1)
	testing.expect_value(t, reload_logged_count(&e.ed, .Info, "alpha", "alpha says hi"), 3)

	reload_write(dir, "aaa.lua", `return {}`)
	plugins_poll(&e.ed)
	testing.expect_value(t, e.ed.plugins.list[v.selected].name, "alpha")
	e2e_key(&e, tb2.Key(0), {}, 'l')
	testing.expect(t, e.ed.logview.active, "l opens the message log")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Message Log  ·  alpha"), "filtered to the plugin")
	testing.expect(t, e2e_grid_has(&e, "alpha says hi"), "the plugin's entries show")
	testing.expect(t, !e2e_grid_has(&e, "not alpha"), "other sources are hidden")
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.logview.active && v.active, "Esc returns to the plugins pane")

	e2e_reload_select(&e, "format")
	e2e_key(&e, .Enter)
	testing.expect(t, v.viewing, "Enter on a bundled plugin opens its source")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "plugins/format/init.lua  ·  bundled, read-only"), "the read-only title")
	testing.expect(t, e2e_grid_has(&e, "local on = {}"), "the embedded source shows")
	user_dir := e.ed.plugins.user_dir
	e.ed.plugins.user_dir = "/qed-u"
	e2e_render(&e)
	e.ed.plugins.user_dir = user_dir
	testing.expect(t, e2e_grid_has(&e, "fork: copy to /qed-u/format"), "the fork hint points into the user plugin dir")
	e2e_key(&e, .Pgdn)
	testing.expect(t, v.source.scroll > 0, "the source scrolls")
	lay := logview_layout(&e.ed)
	e2e_mouse(&e, lay.inner.x + 2, lay.body_top + 1, .Mouse_Wheel_Up)
	e2e_key(&e, tb2.Key(0), {}, 'e')
	testing.expect_value(t, plugin_find(&e.ed.plugins, "format").state, PluginState.Enabled)
	e2e_key(&e, .Esc)
	testing.expect(t, v.active && !v.viewing, "Esc leaves the source view")

	y := e2e_reload_row_y(&e, "alpha")
	e2e_mouse(&e, lay.inner.x + 2, y)
	testing.expect_value(t, e.ed.plugins.list[v.selected].name, "alpha")
	e2e_mouse(&e, lay.inner.x + 2, y)
	testing.expect(t, !v.active, "a double click opens the user plugin file")
	testing.expect(t, strings.has_suffix(editor_buffer(&e.ed).path, "/alpha.lua"), "the file is open for editing")
	for highlight_busy(editor_buffer(&e.ed)) {
		e2e_render(&e)
	}
}
