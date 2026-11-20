package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "lib:tb2"

E2E_EVENT_PLUGIN :: `
	trace = ""
	local function rec(name)
		return function(...)
			local parts = {name}
			for _, v in ipairs({...}) do parts[#parts + 1] = tostring(v) end
			trace = trace .. table.concat(parts, " ") .. ";"
		end
	end
	return {setup = function()
		for _, e in ipairs({"startup", "buf_open", "buf_close", "buf_enter", "buf_pre_save", "buf_save",
				"buf_reload", "buf_changed", "cursor_moved", "language_changed", "root_changed"}) do
			qed.on(e, rec(e))
		end
		qed.command{name = "Clear", run = function() trace = "" end}
	end}`

e2e_trace :: proc(e: ^E2E) -> string {
	s := sched_var(&e.ed, "trace")
	cmd, _ := plugin_test_command(&e.ed, "Ev: Clear")
	command_run(&e.ed, cmd)
	return s
}

@(test)
e2e_plugin_events :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	pl := e2e_plugin(&e, "ev", E2E_EVENT_PLUGIN)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	first := editor_buffer(&e.ed).id

	plugin_pump(&e.ed)
	testing.expect_value(t, e2e_trace(&e), "startup;")
	plugin_pump(&e.ed)
	testing.expect_value(t, e2e_trace(&e), "")

	e2e_key(&e, tb2.Key(0), {}, 'x')
	rev := editor_buffer(&e.ed).rev
	testing.expect_value(t, e2e_trace(&e), fmt.tprintf("buf_changed %d %d true 1 1;cursor_moved %d;", first, rev, first))

	e2e_key(&e, .Ctrl_S)
	testing.expect_value(t, e2e_trace(&e), fmt.tprintf("buf_pre_save %d;buf_save %d;", first, first))

	other := fmt.tprintf("%s.other.txt", e.path)
	_ = os.write_entire_file(other, transmute([]u8)string("two"))
	defer os.remove(other)
	editor_open_path(&e.ed, other)
	plugin_flush(&e.ed)
	second := editor_buffer(&e.ed).id
	testing.expect_value(t, e2e_trace(&e), fmt.tprintf("buf_open %d;buf_enter %d;", second, second))

	editor_set_language(&e.ed, editor_buffer(&e.ed), .Lua)
	plugin_flush(&e.ed)
	testing.expect_value(t, e2e_trace(&e), fmt.tprintf("language_changed %d;", second))

	editor_close_current(&e.ed)
	plugin_flush(&e.ed)
	testing.expect_value(t, e2e_trace(&e), fmt.tprintf("buf_close %d %s;buf_enter %d;", second, other, first))

	_ = os.write_entire_file(e.path, transmute([]u8)string("from disk"))
	editor_reload_buffer(&e.ed, editor_buffer(&e.ed))
	plugin_flush(&e.ed)
	rev = editor_buffer(&e.ed).rev
	testing.expect_value(t, e2e_trace(&e), fmt.tprintf("buf_reload %d;buf_changed %d %d false 1 1;", first, first, rev))

	old := strings.clone(e.ed.working_root, context.temp_allocator)
	root := filepath.dir(e.path)
	editor_change_root(&e.ed, root)
	plugin_flush(&e.ed)
	testing.expect_value(t, e2e_trace(&e), fmt.tprintf("root_changed %s %s;", old, root))
}

@(test)
e2e_plugin_changed_range :: proc(t: ^testing.T) {
	e := e2e_start("0\n1\n2\n3\n4\n5\n6\n7\n8\n9")
	defer e2e_stop(&e)
	e2e_plugin(&e, "rng", `
		got = ""
		return {setup = function()
			qed.on("buf_changed", function(_, _, _, lo, hi) got = got .. lo .. "-" .. hi .. ";" end)
		end}`)
	plugin_flush(&e.ed)
	b := editor_buffer(&e.ed)
	buffer_insert(b, {2, 0}, "x")
	buffer_insert(b, {6, 1}, "\nnew")
	plugin_flush(&e.ed)
	testing.expect_value(t, sched_var(&e.ed, "got"), "3-8;")

	buffer_insert(b, {8, 0}, "y")
	delete(buffer_delete(b, {1, 0}, {4, 0}))
	plugin_flush(&e.ed)
	testing.expect_value(t, sched_var(&e.ed, "got"), "3-8;2-6;")

	delete(buffer_delete(b, {3, 0}, {5, 1}))
	buffer_insert(b, {0, 0}, "a\nb\n")
	plugin_flush(&e.ed)
	testing.expect_value(t, sched_var(&e.ed, "got"), "3-8;2-6;1-6;")
}

@(test)
e2e_plugin_flush_rounds_logged :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "loop", `return {setup = function()
		qed.on("buf_changed", function(b) qed.buf.insert(b, {row = 1, col = 1}, "x") end)
	end}`)
	plugin_flush(&e.ed)
	e2e_type(&e, "y")
	plugin_flush(&e.ed)
	testing.expect(t, plugin_test_logged(&e.ed, .Debug, "plugins", "all 16 flush rounds used"), "an endless edit loop is logged")
}

@(test)
e2e_plugin_coalesce :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	e2e_plugin(&e, "quiet", `return {setup = function() qed.command{name = "Cmd", run = function() end} end}`)
	plugin_pump(&e.ed)
	before := e.ed.plugins.resumes
	for r in "plain" {
		e2e_key(&e, tb2.Key(0), {}, r)
	}
	e2e_key(&e, .Arrow_Left)
	testing.expect_value(t, e.ed.plugins.resumes, before)

	e2e_plugin(&e, "count", `
		changed = 0
		return {setup = function() qed.on("buf_changed", function() changed = changed + 1 end) end}`)
	plugin_pump(&e.ed)
	for r in "abc" {
		e2e_key(&e, tb2.Key(0), {}, r)
	}
	testing.expect_value(t, sched_var(&e.ed, "changed"), "3")
	e2e_type(&e, "defgh")
	testing.expect_value(t, sched_var(&e.ed, "changed"), "3")
	plugin_flush(&e.ed)
	testing.expect_value(t, sched_var(&e.ed, "changed"), "4")
	e2e_paste(&e, "pasted text")
	testing.expect_value(t, sched_var(&e.ed, "changed"), "5")
}

@(test)
e2e_plugin_pre_save_spawn :: proc(t: ^testing.T) {
	e := e2e_start("messy")
	defer e2e_stop(&e)
	e2e_spawn_fake(&e, "fakefmt", "TIDY\n", delay_ms = 40)
	pl := e2e_plugin(&e, "fmt", `
		return {setup = function()
			qed.on("buf_pre_save", function(b)
				local rev = qed.buf.rev(b)
				local r = qed.spawn{cmd = "fakefmt --stdin", stdin = qed.buf.text(b)}
				local n = qed.buf.line_count(b)
				qed.edit(b, function()
					qed.buf.replace(b, {row = 1, col = 1}, {row = n, col = #qed.buf.line(b, n) + 1}, r.stdout)
				end, {rev = rev})
			end)
		end}`)
	b := editor_buffer(&e.ed)
	e2e_key(&e, tb2.Key(0), {}, '!')
	start := time.tick_now()
	e2e_key(&e, .Ctrl_S)
	data, _ := os.read_entire_file(e.path, context.temp_allocator)
	testing.expect_value(t, string(data), "messy")
	testing.expect(t, plugin_save_pending(&e.ed.plugins, b.id), "the save waits on the fake formatter")
	plugin_pump(&e.ed)
	testing.expect(t, plugin_save_pending(&e.ed.plugins, b.id), "the fake delay holds")
	pending :: proc(e: ^E2E) -> bool {return len(e.ed.plugins.saves) > 0}
	testing.expect(t, e2e_pump_while(&e, pending), "the save completes")
	testing.expect(t, ms_since(start) >= 40, "not before the fake delay")
	data, _ = os.read_entire_file(e.path, context.temp_allocator)
	testing.expect_value(t, string(data), "TIDY\n")
	testing.expect(t, !b.modified, "saved")
	testing.expect_value(t, pl.last_error, "")
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "!messy")
}
