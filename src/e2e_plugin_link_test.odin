package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
OWNER :: `
local regs = {}
return {setup = function()
	assert(not pcall(qed.plugin, "use"), "qed.plugin raises during setup")
	qed.export{
		add = function(x)
			regs[qed.caller()] = x
			return #x, qed.caller()
		end,
		list = function()
			local out = {}
			for k, v in pairs(regs) do
				out[#out + 1] = k .. "=" .. v
			end
			table.sort(out)
			return table.concat(out, ",")
		end,
		slow = function()
			qed.sleep(5)
			return qed.caller()
		end,
		fail = function()
			error("boom")
		end,
		echo = function()
			return qed.plugin("own").who()
		end,
		who = function()
			return qed.caller()
		end,
	}
	assert(not pcall(qed.export, {}), "qed.export once per load")
	qed.on("plugin_unloaded", function(id)
		regs[id] = nil
	end)
	qed.command{name = "Late Export", run = function()
		local ok, err = pcall(qed.export, {})
		qed.message(err)
	end}
end}`

@(private = "file")
USER :: `
local own
local function say(...)
	local out = {}
	for i = 1, select("#", ...) do
		out[#out + 1] = tostring((select(i, ...)))
	end
	qed.message(table.concat(out, " "))
end
return {setup = function()
	qed.on("startup", function() own = qed.plugin("own") end)
	qed.command{name = "Add", run = function() say(own.add("abc")) end}
	qed.command{name = "List", run = function() say(own.list()) end}
	qed.command{name = "Slow", run = function() say("slow", own.slow()) end}
	qed.command{name = "Fail", run = function() say(pcall(own.fail)) end}
	qed.command{name = "Echo", run = function() say(own.echo()) end}
	qed.command{name = "Stale", run = function() say(pcall(own.add, "x")) end}
	qed.command{name = "Fetch", run = function() own = qed.plugin("own"); say(own ~= nil) end}
	qed.command{name = "Missing", run = function() say(tostring(qed.plugin("nope")), tostring(qed.caller())) end}
end}`

@(private = "file")
link_plugin :: proc(e: ^E2E, name, src: string) -> ^Plugin {
	path := fmt.tprintf("%s/%s.plugin.lua", e.dir, name)
	_ = os.write_entire_file(path, transmute([]u8)src)
	pl := plugins_add(&e.ed.plugins, Plugin{name = name, main = path}, false)
	plugin_load(&e.ed, pl)
	return pl
}

@(private = "file")
link_run :: proc(e: ^E2E, name: string) -> string {
	cmd, ok := plugin_test_command(&e.ed, name)
	assert(ok, name)
	plugin_command_run(&e.ed, cmd)
	e2e_git_settle(e)
	return e.ed.message
}

@(private = "file")
link_logged :: proc(e: ^E2E, source, text: string) -> int {
	n := 0
	for l in e.ed.log {
		n += int(l.source == source && l.text == text)
	}
	return n
}

@(test)
e2e_plugin_exports :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	own := link_plugin(&e, "own", OWNER)
	use := link_plugin(&e, "use", USER)
	use2 := link_plugin(&e, "use2", USER)
	testing.expect_value(t, own.state, PluginState.Enabled)
	testing.expect_value(t, use.state, PluginState.Enabled)
	e2e_git_settle(&e)

	testing.expect_value(t, link_run(&e, "Use: Add"), "3 use")
	testing.expect_value(t, link_run(&e, "Use2: Add"), "3 use2")
	testing.expect_value(t, link_run(&e, "Use: List"), "use2=abc,use=abc")
	testing.expect_value(t, link_run(&e, "Use: Echo"), "own")
	testing.expect_value(t, link_run(&e, "Use: Slow"), "slow use")
	testing.expect(t, strings.has_prefix(link_run(&e, "Use: Fail"), "false "), "an export's error reaches the caller")
	testing.expect(t, strings.contains(e.ed.message, "boom"), e.ed.message)
	testing.expect_value(t, link_run(&e, "Use: Missing"), "nil nil")
	testing.expect_value(t, link_run(&e, "Own: Late Export"), "qed.export() is only callable during setup")
	testing.expect_value(t, len(e.ed.plugins.calls), 0)

	plugin_unload(&e.ed, use2)
	e2e_git_settle(&e)
	testing.expect_value(t, link_run(&e, "Use: List"), "use=abc")

	cmd, _ := plugin_test_command(&e.ed, "Use: Slow")
	plugin_command_run(&e.ed, cmd)
	testing.expect_value(t, len(e.ed.plugins.calls), 1)
	plugin_unload(&e.ed, use)
	testing.expect_value(t, len(e.ed.plugins.calls), 0)
	plugin_load(&e.ed, use)
	e2e_git_settle(&e)

	plugin_reload(&e.ed, own)
	e2e_git_settle(&e)
	msg := link_run(&e, "Use: Stale")
	testing.expect(t, strings.has_prefix(msg, "false ") && strings.contains(msg, "plugin 'own' was unloaded"), msg)
	testing.expect_value(t, link_run(&e, "Use: Fetch"), "true")
	testing.expect_value(t, link_run(&e, "Use: Add"), "3 use")
	plugin_enabled_set(&e.ed, own, false)
	testing.expect_value(t, link_run(&e, "Use: Fetch"), "false")
}

@(test)
e2e_plugin_export_misuse :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	bad := link_plugin(&e, "bad", `return {setup = function()
		assert(not pcall(qed.export, {x = 1}), "only functions")
		assert(not pcall(qed.export, {[1] = print}), "only names")
		assert(not pcall(qed.export, "x"), "a table")
		qed.command{name = "Emit", run = function()
			local ok, err = pcall(qed.emit, "other:x")
			qed.message(err)
		end}
		qed.command{name = "Bad Event", run = function()
			local ok, err = pcall(qed.on, "nope", print)
			qed.message(tostring(ok))
		end}
	end}`)
	testing.expect_value(t, bad.state, PluginState.Enabled)
	e2e_git_settle(&e)
	testing.expect_value(t, link_run(&e, "Bad: Emit"), "event name must be 'bad:<event>'")
	testing.expect_value(t, link_run(&e, "Bad: Bad Event"), "false")
}

@(test)
e2e_plugin_custom_events :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	link_plugin(&e, "src", `return {setup = function()
		qed.command{name = "Ping", run = function() qed.emit("src:ping", {n = 7}) end}
		qed.command{name = "Pong", run = function() qed.emit("src:pong") end}
	end}`)
	dst := link_plugin(&e, "dst", `return {setup = function()
		qed.on("src:ping", function(d) qed.log("ping " .. d.n) end)
		qed.on("src:pong", function(d) qed.log("pong " .. tostring(d)) end)
		qed.on("other:ping", function() qed.log("wrong") end)
	end}`)
	e2e_git_settle(&e)
	subs := e.ed.plugins.subs[.Custom]
	link_run(&e, "Src: Ping")
	link_run(&e, "Src: Pong")
	testing.expect_value(t, link_logged(&e, "Dst", "ping 7"), 1)
	testing.expect_value(t, link_logged(&e, "Dst", "pong nil"), 1)
	testing.expect_value(t, link_logged(&e, "Dst", "wrong"), 0)
	plugin_unload(&e.ed, dst)
	plugin_flush(&e.ed)
	cmd, _ := plugin_test_command(&e.ed, "Src: Ping")
	plugin_command_run(&e.ed, cmd)
	testing.expect_value(t, len(e.ed.plugins.queue), 0)
	testing.expect_value(t, e.ed.plugins.subs[.Custom], subs - 3)
}

@(test)
e2e_plugin_lifecycle_events :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("one\n")
	defer e2e_stop(&e)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)
	nav_write(e.path, "two\n")
	link_plugin(&e, "rec", `return {setup = function()
		qed.on("plugin_loaded", function(id) qed.log("loaded " .. id) end)
		qed.on("plugin_unloaded", function(id) qed.log("unloaded " .. id) end)
	end}`)
	e2e_git_settle(&e)
	testing.expect_value(t, link_logged(&e, "Rec", "loaded rec"), 0)
	ft := plugin_find(&e.ed.plugins, "filetree")
	git := plugin_find(&e.ed.plugins, "git")

	nav_alt(&e, 'g')
	nav_scan(&e)
	testing.expect_value(t, ft_tabs(&e.ed), "All|Open|Git|Unsaved")
	testing.expect_value(t, ft_scope(&e.ed), "Git")
	testing.expect(t, nav_select(&e.ed, "file.txt"), "the Git tab lists the change")
	e2e_key(&e, .Esc)

	plugin_reload(&e.ed, ft)
	e2e_git_settle(&e)
	testing.expect_value(t, link_logged(&e, "Rec", "unloaded filetree"), 1)
	testing.expect_value(t, link_logged(&e, "Rec", "loaded filetree"), 1)
	nav_alt(&e, 'g')
	nav_scan(&e)
	testing.expect_value(t, ft_scope(&e.ed), "Git")
	testing.expect(t, nav_select(&e.ed, "file.txt"), "git re-adds its tab to the reloaded tree")
	testing.expect_value(t, ft_mark(&e.ed, e.path).bar, "git_modified")

	plugin_unload(&e.ed, git)
	e2e_git_settle(&e)
	testing.expect_value(t, ft_tabs(&e.ed), "All|Open|Unsaved")
	testing.expect_value(t, ft_scope(&e.ed), "All")
	testing.expect_value(t, len(ft_pane(&e.ed).marks), 0)
	plugin_load(&e.ed, git)
	e2e_git_settle(&e)
	testing.expect_value(t, ft_tabs(&e.ed), "All|Open|Git|Unsaved")
	testing.expect_value(t, ft_mark(&e.ed, e.path).bar, "git_modified")

	plugin_reload(&e.ed, git)
	e2e_git_settle(&e)
	testing.expect_value(t, link_logged(&e, "Rec", "unloaded git"), 2)
	testing.expect_value(t, link_logged(&e, "Rec", "loaded git"), 2)
	testing.expect_value(t, ft_tabs(&e.ed), "All|Open|Git|Unsaved")
	unloaded, loaded := -1, -1
	for l, i in e.ed.log {
		if l.source == "Rec" && l.text == "unloaded git" {
			unloaded = i
		}
		if l.source == "Rec" && l.text == "loaded git" {
			loaded = i
		}
	}
	testing.expect(t, unloaded >= 0 && unloaded < loaded, "unloaded comes before loaded")

	e2e_plugin_config(&e, "git", `{"enabled": false}`, hot = true)
	e2e_git_settle(&e)
	testing.expect_value(t, ft_tabs(&e.ed), "All|Open|Unsaved")
	e2e_plugin_config(&e, "git", `{"enabled": true}`, hot = true)
	e2e_git_settle(&e)
	testing.expect_value(t, ft_tabs(&e.ed), "All|Open|Git|Unsaved")
	e2e_plugin_config(&e, "filetree", `{"enabled": false}`, hot = true)
	e2e_git_settle(&e)
	testing.expect(t, !filetree_active(&e.ed), "disabling the tree closes it")
	_, has_git := plugin_test_command(&e.ed, "Git: Changes")
	testing.expect(t, has_git, "git keeps its command")
	cmd, _ := plugin_test_command(&e.ed, "Git: Changes")
	testing.expect(t, !plugin_command_when(&e.ed, cmd), "but hides it without the tree")
	e2e_plugin_config(&e, "filetree", `{"enabled": true}`, hot = true)
	e2e_git_settle(&e)
	testing.expect(t, plugin_command_when(&e.ed, cmd), "and offers it again with the tree back")
	nav_alt(&e, 'g')
	nav_scan(&e)
	testing.expect_value(t, ft_scope(&e.ed), "Git")
	testing.expect(t, nav_select(&e.ed, "file.txt"))
}

@(private = "file")
PARK_OWNER :: `
return {setup = function()
	qed.export{
		park = function()
			qed.sleep(30)
			qed.log("parked code still runs")
		end,
		stash = function()
			return function() return pcall(qed.defer, 0, function() end) end
		end,
	}
end}`

@(private = "file")
PARK_USER :: `
local own, stale
return {setup = function()
	qed.on("startup", function() own = qed.plugin("own") end)
	qed.command{name = "Park", run = function() own.park() end}
	qed.command{name = "Stash", run = function() stale = own.stash() end}
	qed.command{name = "Stale", run = function() qed.message(tostring(stale())) end}
	qed.command{name = "Raw", run = function()
		local co = coroutine.create(function() return qed.plugin("own").stash() end)
		local ok, err = coroutine.resume(co)
		qed.message(tostring(ok) .. " " .. tostring(err))
	end}
end}`

@(test)
e2e_plugin_export_unload_stops_callers :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	own := link_plugin(&e, "own", PARK_OWNER)
	link_plugin(&e, "use", PARK_USER)
	e2e_git_settle(&e)

	link_run(&e, "Use: Stash")
	testing.expect_value(t, link_run(&e, "Use: Stale"), "true")
	cmd, _ := plugin_test_command(&e.ed, "Use: Park")
	plugin_command_run(&e.ed, cmd)
	testing.expect_value(t, len(e.ed.plugins.calls), 1)
	plugin_reload(&e.ed, own)
	testing.expect_value(t, len(e.ed.plugins.calls), 0)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return true}, 80)
	testing.expect_value(t, link_logged(&e, "Own", "parked code still runs"), 0)
	testing.expect(t, plugin_test_logged(&e.ed, .Warn, "Use", "task stopped: Own unloaded during a call into it"), "the caller's task ends with a warning")
	testing.expect_value(t, link_run(&e, "Use: Stale"), "false")
	msg := link_run(&e, "Use: Raw")
	testing.expect(t, strings.has_prefix(msg, "false ") && strings.contains(msg, "not a coroutine of your own"), msg)
	testing.expect_value(t, len(e.ed.plugins.calls), 0)
}

@(test)
e2e_plugin_export_unload_mid_open :: proc(t: ^testing.T) {
	e := e2e_root_start("x")
	defer e2e_stop(&e)
	e2e_plugin_config(&e, "git", `{"enabled": false}`)
	link_plugin(&e, "big", `return {setup = function()
		qed.command{name = "Open", run = function()
			local ft = qed.plugin("filetree")
			local paths = {}
			for i = 1, 5000 do
				paths[i] = qed.root() .. "/f" .. i
			end
			ft.set_tab{label = "Big", paths = paths}
			ft.open("Big")
			qed.log("opened")
		end}
	end}`)
	e2e_git_settle(&e)
	cmd, _ := plugin_test_command(&e.ed, "Big: Open")
	plugin_command_run(&e.ed, cmd)
	testing.expect_value(t, len(e.ed.plugins.calls), 1)
	plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "filetree"))
	e2e_git_settle(&e)
	testing.expect_value(t, link_logged(&e, "Big", "opened"), 0)
	testing.expect(t, !filetree_active(&e.ed), "the unloaded tree's open does not finish")
	testing.expect_value(t, len(e.ed.plugins.calls), 0)
}
