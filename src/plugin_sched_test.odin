package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import lua "lib:lua"

sched_var :: proc(ed: ^Editor, name: cstring) -> string {
	L := ed.plugins.L
	for pl in ed.plugins.list {
		if pl.env == lua.NOREF {
			continue
		}
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.env))
		lua.pushstring(L, name)
		lua.rawget(L, -2)
		if lua.type(L, -1) != .NIL {
			s, _ := lua.toodinstring_any(L, -1)
			s = strings.clone(s, context.temp_allocator)
			lua.pop(L, 3)
			return s
		}
		lua.pop(L, 2)
	}
	return ""
}

sched_wait :: proc(ed: ^Editor, global: cstring, want: string, max_ms := 3000) -> bool {
	start := time.tick_now()
	for ms_since(start) < f64(max_ms) {
		plugin_pump(ed)
		if sched_var(ed, global) == want {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

sched_run :: proc(t: ^testing.T, ed: ^Editor, name: string, loc := #caller_location) {
	cmd, ok := plugin_test_command(ed, name)
	if testing.expectf(t, ok, "command %s registered", name, loc = loc) {
		command_run(ed, cmd)
	}
}

@(test)
plugin_sched_yield_resume :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"co.lua", `
			return {setup = function()
				qed.command{name = "Co: Sleep", run = function()
					steps = "a"
					qed.sleep(5)
					steps = steps .. "b"
					qed.sleep(0)
					steps = steps .. "c"
				end}
				qed.command{name = "Co: Outer", run = function()
					order = "outer1"
					qed.run("Co: Inner")
					order = order .. " outer2"
				end}
				qed.command{name = "Co: Inner", run = function()
					order = order .. " inner1"
					qed.sleep(1)
					order = order .. " inner2"
				end}
				qed.command{name = "Co: Pcall", run = function()
					local ok = pcall(qed.sleep, 1)
					yielded = tostring(ok)
				end}
				qed.command{name = "Co: Raw", run = function() coroutine.yield() end}
				qed.command{name = "Co: InEdit", run = function()
					local ok, err = pcall(qed.edit, nil, function() qed.sleep(1) end)
					inedit = err:find("cannot wait inside qed.edit") and "refused" or err
				end}
				qed.command{name = "Co: Late", run = function() qed.sleep(1); error("late boom") end}
			end}`},
		{"early.lua", `return {setup = function() qed.sleep(1) end}`},
	})
	defer plugin_test_destroy(ed)

	sched_run(t, ed, "Co: Sleep")
	testing.expect_value(t, sched_var(ed, "steps"), "a")
	testing.expect_value(t, len(ed.plugins.tasks), 1)
	testing.expect(t, sched_wait(ed, "steps", "abc"), "sleep resumes from the pump")
	testing.expect_value(t, len(ed.plugins.tasks), 0)
	testing.expect(t, len(ed.plugins.pool) > 0, "finished coroutines go back to the pool")

	sched_run(t, ed, "Co: Outer")
	testing.expect_value(t, sched_var(ed, "order"), "outer1 inner1 outer2")
	testing.expect(t, sched_wait(ed, "order", "outer1 inner1 outer2 inner2"), "a nested command waits on its own coroutine")

	sched_run(t, ed, "Co: Pcall")
	testing.expect(t, sched_wait(ed, "yielded", "true"), "yielding through pcall works")

	sched_run(t, ed, "Co: InEdit")
	testing.expect_value(t, sched_var(ed, "inedit"), "refused")

	pl := plugin_find(&ed.plugins, "co")
	sched_run(t, ed, "Co: Raw")
	testing.expect(t, strings.contains(pl.last_error, "coroutine.yield"), "a raw yield is an error")
	testing.expect_value(t, len(ed.plugins.tasks), 0)

	sched_run(t, ed, "Co: Late")
	start := time.tick_now()
	for !strings.contains(pl.last_error, "late boom") && ms_since(start) < 2000 {
		plugin_pump(ed)
	}
	testing.expect(t, strings.contains(pl.last_error, "late boom"), "an error after a yield is reported")
	testing.expect(t, plugin_test_logged(ed, .Debug, "co", "stack traceback"), "with a traceback")
	testing.expect_value(t, pl.state, PluginState.Enabled)

	early := plugin_find(&ed.plugins, "early")
	testing.expect_value(t, early.state, PluginState.Errored)
	testing.expect(t, strings.contains(early.last_error, "can only wait"), "setup cannot wait")
}

@(test)
plugin_sched_event_error_disables :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"ev.lua", `
			return {setup = function()
				qed.command{name = "Ev: Cmd", run = function() end}
				qed.on("startup", function() qed.sleep(1); error("handler boom") end)
				qed.every(1000, function() end)
			end}`},
	})
	defer plugin_test_destroy(ed)

	pl := plugin_find(&ed.plugins, "ev")
	start := time.tick_now()
	for pl.state == .Enabled && ms_since(start) < 2000 {
		plugin_pump(ed)
	}
	testing.expect_value(t, pl.state, PluginState.Errored)
	testing.expect(t, strings.contains(pl.last_error, "handler boom"), "handler error kept")
	_, has := plugin_test_command(ed, "Ev: Cmd")
	testing.expect(t, !has, "the plugin is unloaded")
	testing.expect_value(t, len(ed.plugins.timers), 0)
	testing.expect_value(t, len(ed.plugins.hooks), 0)
}

@(test)
plugin_sched_spawn :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"sp.lua", `
			return {setup = function()
				qed.command{name = "Sp: Run", run = function()
					local r = qed.spawn{cmd = "echo out; echo err 1>&2; exit 3"}
					result = r.code .. "|" .. r.stdout .. "|" .. r.stderr
				end}
				qed.command{name = "Sp: Lines", run = function()
					local got = {}
					local r = qed.spawn{argv = {"printf", "a\nb\r\nc"}, on_line = function(l) got[#got + 1] = l end}
					lines = table.concat(got, ",") .. "|" .. r.code
				end}
				qed.command{name = "Sp: Env", run = function()
					local r = qed.spawn{cmd = "pwd; echo $QED_T", cwd = "/", env = {QED_T = "bar"}, stdin = "ignored"}
					env = r.stdout
				end}
				qed.command{name = "Sp: Stdin", run = function()
					stdin = qed.spawn{cmd = "tr a-z A-Z", stdin = "shout"}.stdout
				end}
				qed.command{name = "Sp: Bad", run = function()
					local ok, err = pcall(qed.spawn, {cmd = "x", argv = {"y"}})
					bad = ok and "accepted" or "rejected"
				end}
				qed.command{name = "Sp: Bg", run = function()
					local p = qed.spawn_bg{cmd = "exec sleep 30"}
					bgpid = tostring(p.pid)
					p:kill()
					local r = p:wait()
					bg = "killed " .. tostring(r.code ~= 0)
				end}
				qed.command{name = "Sp: Orphan", run = function()
					orphan = tostring(qed.spawn_bg{cmd = "exec sleep 30"}.pid)
				end}
			end}`},
	})
	defer plugin_test_destroy(ed)

	sched_run(t, ed, "Sp: Run")
	testing.expect(t, sched_wait(ed, "result", "3|out\n|err\n"), "exit code, stdout and stderr")
	sched_run(t, ed, "Sp: Lines")
	testing.expect(t, sched_wait(ed, "lines", "a,b,c|0"), "on_line streams each stdout line")
	sched_run(t, ed, "Sp: Env")
	testing.expect(t, sched_wait(ed, "env", "/\nbar\n"), "cwd and env")
	sched_run(t, ed, "Sp: Stdin")
	testing.expect(t, sched_wait(ed, "stdin", "SHOUT"), "stdin")
	sched_run(t, ed, "Sp: Bad")
	testing.expect_value(t, sched_var(ed, "bad"), "rejected")
	sched_run(t, ed, "Sp: Bg")
	testing.expect(t, sched_wait(ed, "bg", "killed true"), "kill ends the process and wait returns")

	sched_run(t, ed, "Sp: Orphan")
	pid: posix.pid_t
	pid_s := sched_var(ed, "orphan")
	for ch in pid_s {
		pid = pid * 10 + posix.pid_t(ch - '0')
	}
	testing.expect(t, pid > 0 && posix.kill(pid, posix.Signal(0)) == .OK, "background process runs")
	plugin_unload(ed, plugin_find(&ed.plugins, "sp"))
	testing.expect_value(t, len(ed.plugins.procs), 0)
	testing.expect(t, posix.kill(pid, posix.Signal(0)) != .OK, "unload kills background processes")
}

@(test)
plugin_sched_timers :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"tm.lua", `
			return {setup = function()
				ticks, once = 0, 0
				qed.defer(0, function() once = once + 1 end)
				local stopped = qed.defer(1, function() error("stopped timers never fire") end)
				stopped:stop()
				local every
				every = qed.every(2, function()
					ticks = ticks + 1
					if ticks == 3 then every:stop(); done = "yes" end
				end)
				qed.every(5, function() end)
			end}`},
	})
	defer plugin_test_destroy(ed)

	testing.expect(t, sched_wait(ed, "done", "yes"), "every ticks until stopped")
	time.sleep(10 * time.Millisecond)
	plugin_pump(ed)
	testing.expect_value(t, sched_var(ed, "ticks"), "3")
	testing.expect_value(t, sched_var(ed, "once"), "1")
	pl := plugin_find(&ed.plugins, "tm")
	testing.expect_value(t, pl.last_error, "")
	testing.expect_value(t, len(ed.plugins.timers), 1)
	testing.expect(t, plugin_timeout_ms(ed, 1000) <= 6, "the poll timeout is clamped to the next timer")
	plugin_unload(ed, pl)
	testing.expect_value(t, len(ed.plugins.timers), 0)
}

@(test)
plugin_sched_budgets :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"busy.lua", `
			return {setup = function()
				qed.on("buf_changed", function() while true do end end)
			end}`},
		{"sneaky.lua", `
			return {setup = function()
				qed.on("cursor_moved", function()
					while true do pcall(function() while true do end end) end
				end)
			end}`},
		{"cmd.lua", `
			return {setup = function()
				qed.command{name = "Cmd: Slow", run = function()
					local t = os.clock()
					while os.clock() - t < 0.1 do end
					slow = "done"
				end}
				qed.command{name = "Cmd: Forever", run = function() while true do end end}
			end}`},
	})
	defer plugin_test_destroy(ed)

	plugin_flush(ed)
	b := editor_buffer(ed)
	buffer_insert_rune(b, 'x')
	start := time.tick_now()
	plugin_flush(ed)
	testing.expect(t, ms_since(start) < 500, "runaway handlers are cut off quickly")
	busy := plugin_find(&ed.plugins, "busy")
	testing.expect_value(t, busy.state, PluginState.Errored)
	testing.expect(t, strings.contains(busy.last_error, "buf_changed handler exceeded its 20 ms budget"), busy.last_error)
	sneaky := plugin_find(&ed.plugins, "sneaky")
	testing.expect_value(t, sneaky.state, PluginState.Errored)
	testing.expect(t, strings.contains(sneaky.last_error, "budget"), "pcall cannot swallow the budget")
	testing.expect_value(t, len(ed.plugins.tasks), 0)

	sched_run(t, ed, "Cmd: Slow")
	cmd := plugin_find(&ed.plugins, "cmd")
	testing.expect_value(t, sched_var(ed, "slow"), "done")
	testing.expect_value(t, cmd.last_error, "")
	start = time.tick_now()
	sched_run(t, ed, "Cmd: Forever")
	elapsed := ms_since(start)
	testing.expect(t, elapsed >= 1900 && elapsed < 4000, "commands get 2 s")
	testing.expect(t, strings.contains(cmd.last_error, "command exceeded its 2000 ms budget"), cmd.last_error)
	testing.expect_value(t, cmd.state, PluginState.Enabled)
}

@(test)
plugin_sched_coalesce :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"quiet.lua", `return {setup = function() qed.command{name = "Quiet: Cmd", run = function() end} end}`},
	})
	defer plugin_test_destroy(ed)
	plugin_pump(ed)
	b := editor_buffer(ed)
	before := ed.plugins.resumes
	for _ in 0 ..< 5 {
		buffer_insert_rune(b, 'x')
		plugin_flush(ed)
	}
	testing.expect_value(t, ed.plugins.resumes, before)

	pl := plugins_add(&ed.plugins, Plugin{name = "count", main = "count.lua"}, true)
	ed.plugins.bundled = {{"count.lua", `
		return {setup = function()
			changed, moved, last = 0, 0, ""
			local h = qed.on("buf_changed", function(b, rev)
				changed = changed + 1
				last = b .. ":" .. rev
			end)
			qed.on("cursor_moved", function(b) moved = moved + 1 end)
			qed.command{name = "Count: Off", run = function() h:off() end}
		end}`}}
	plugin_load(ed, pl)
	testing.expect_value(t, pl.last_error, "")
	for _ in 0 ..< 5 {
		buffer_insert_rune(b, 'y')
	}
	plugin_flush(ed)
	plugin_flush(ed)
	testing.expect_value(t, sched_var(ed, "changed"), "1")
	testing.expect_value(t, sched_var(ed, "moved"), "1")
	testing.expect_value(t, sched_var(ed, "last"), fmt.tprintf("%d:%d", b.id, b.rev))
	sched_run(t, ed, "Count: Off")
	buffer_insert_rune(b, 'z')
	plugin_flush(ed)
	testing.expect_value(t, sched_var(ed, "changed"), "1")
	testing.expect_value(t, ed.plugins.subs[.Buf_Changed], 0)
}

@(test)
plugin_sched_quit :: proc(t: ^testing.T) {
	ed := plugin_test_editor({
		{"bye.lua", `
			return {setup = function()
				qed.on("quit", function() qed.sleep(5); said = "bye" end)
			end}`},
	})
	defer plugin_test_destroy(ed)
	editor_plugins_quit(ed)
	testing.expect_value(t, sched_var(ed, "said"), "bye")
}

@(test)
plugin_sched_pre_save :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_presave_test_%d", tmp, posix.getpid())
	os.make_directory(dir)
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	path := fmt.tprintf("%s/a.txt", dir)
	_ = os.write_entire_file(path, transmute([]u8)string("draft"))

	ed := plugin_test_editor({
		{"pre.lua", `
			return {setup = function()
				qed.on("buf_pre_save", function(b)
					local rev = qed.buf.rev(b)
					qed.sleep(5)
					qed.edit(b, function() qed.buf.insert(b, {row = 1, col = 1}, "[fmt]") end, {rev = rev})
				end)
				qed.on("buf_save", function(b) saved = (saved or 0) + 1 end)
				qed.command{name = "Pre: Save", run = function(ctx)
					local ok = qed.save(ctx.buf)
					after = tostring(ok) .. " " .. tostring(qed.buf.modified(ctx.buf))
				end}
			end}`},
	})
	defer plugin_test_destroy(ed)
	b := editor_buffer(ed)
	buffer_destroy(b)
	b^ = buffer_new()
	testing.expect_value(t, buffer_open(b, path), BufferOpenError.None)
	buffer_insert_rune(b, '!')

	sched_run(t, ed, "Pre: Save")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "draft")
	testing.expect(t, plugin_save_pending(&ed.plugins, b.id), "the save waits for the handler")
	testing.expect(t, sched_wait(ed, "after", "true false"), "qed.save resumes once written")
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "[fmt]!draft")
	plugin_flush(ed)
	testing.expect_value(t, sched_var(ed, "saved"), "1")
}

@(test)
plugin_sched_pre_save_timeout :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/qed_presave_timeout_%d.txt", tmp, posix.getpid())
	_ = os.write_entire_file(path, transmute([]u8)string("v1"))
	defer os.remove(path)

	ed := plugin_test_editor({
		{"slow.lua", `return {setup = function() qed.on("buf_pre_save", function() qed.sleep(60000) end) end}`},
	})
	defer plugin_test_destroy(ed)
	b := editor_buffer(ed)
	buffer_destroy(b)
	b^ = buffer_new()
	buffer_open(b, path)
	buffer_insert_rune(b, '2')
	start := time.tick_now()
	editor_save_full(ed, b)
	for plugin_save_pending(&ed.plugins, b.id) && ms_since(start) < 5000 {
		plugin_pump(ed)
		time.sleep(time.Millisecond)
	}
	elapsed := ms_since(start)
	testing.expect(t, elapsed >= f64(PLUGIN_HOOK_TIMEOUT_MS) - 50 && elapsed < f64(PLUGIN_HOOK_TIMEOUT_MS) + 1000, "the save waits plugin_hook_timeout_ms")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "2v1")
	testing.expect(t, plugin_test_logged(ed, .Warn, "slow", "buf_pre_save handler still running"), "the slow plugin is named")
}
