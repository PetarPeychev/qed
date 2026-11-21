package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "lib:tb2"
import "lib:vterm"

e2e_term_screen_has :: proc(t: ^Terminal, needle: string) -> bool {
	for row in 0 ..< t.rows {
		sb := strings.builder_make(context.temp_allocator)
		for col in 0 ..< t.cols {
			cell: vterm.ScreenCell
			vterm.screen_get_cell(t.screen, {c.int(row), c.int(col)}, &cell)
			strings.write_rune(&sb, rune(cell.chars[0]) if cell.chars[0] != 0 else ' ')
		}
		if strings.contains(strings.to_string(sb), needle) {
			return true
		}
	}
	return false
}

e2e_term_until :: proc(e: ^E2E, timeout_ms: int, cond: proc(t: ^Terminal) -> bool, t: ^Terminal) -> bool {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(timeout_ms) {
		term_pump(&e.ed)
		if cond(t) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return cond(t)
}

e2e_term_exited :: proc(t: ^Terminal) -> bool {
	return !t.alive
}

e2e_term_alt_t :: proc(e: ^E2E) {
	e2e_step(e, tb2.Event{type = .Key, mod = .Alt, ch = 't'})
}

@(test)
e2e_term_sessions_independent :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	a, ok_a := term_create(&e.ed, {name = "a", cmd = "echo alpha_out; sleep 30"})
	b, ok_b := term_create(&e.ed, {name = "b", cmd = "echo beta_out; sleep 30"})
	if !testing.expect(t, ok_a && ok_b, "both sessions start") {
		return
	}
	testing.expect(t, !e.ed.terminal.active, "a created session starts hidden")
	testing.expect(t, e2e_term_until(&e, 4000, proc(t: ^Terminal) -> bool {return e2e_term_screen_has(t, "alpha_out")}, a), "a gets its output")
	testing.expect(t, e2e_term_until(&e, 4000, proc(t: ^Terminal) -> bool {return e2e_term_screen_has(t, "beta_out")}, b), "b gets its output")
	testing.expect(t, !e2e_term_screen_has(a, "beta_out") && !e2e_term_screen_has(b, "alpha_out"), "outputs stay separate")

	term_show(&e.ed, a)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "alpha_out") && !e2e_grid_has(&e, "beta_out"), "only the shown session renders")
	testing.expect(t, e2e_grid_has(&e, " a "), "the pane title names the session")
	term_show(&e.ed, b)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "beta_out") && !e2e_grid_has(&e, "alpha_out"), "showing b switches the overlay")
}

@(test)
e2e_term_hidden_drains :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	f, ok := term_create(&e.ed, {name = "flood", cmd = "head -c 3000000 /dev/zero | tr '\\0' x; echo; echo flood_done"})
	if !testing.expect(t, ok, "flood starts") {
		return
	}
	testing.expect(t, e2e_term_until(&e, 10000, e2e_term_exited, f), "a hidden session that floods its PTY still runs to completion")
	testing.expect_value(t, f.code, 0)
	testing.expect(t, e2e_term_screen_has(f, "flood_done"), "its output reached the emulator")
	testing.expect(t, !e.ed.terminal.active, "it was never shown")
}

@(test)
e2e_term_flood_bounded :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	f, ok := term_create(&e.ed, {name = "yes", cmd = "yes"})
	if !testing.expect(t, ok, "yes starts") {
		return
	}
	time.sleep(100 * time.Millisecond)
	more := 0
	for _ in 0 ..< 20 {
		start := time.tick_now()
		term_pump(&e.ed)
		testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 200, "a pump returns while the session floods")
		if e.ed.terminal.more {
			more += 1
		}
	}
	testing.expect(t, more > 0, "a flooding session reports more to drain")
	testing.expect(t, e2e_term_screen_has(f, "y"), "the flood keeps reaching the emulator")
	term_kill(&e.ed, f)
	term_pump(&e.ed)
	testing.expect(t, !e.ed.terminal.more, "nothing left once it is killed")
}

@(test)
e2e_term_kill_group :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	k, ok := term_create(&e.ed, {name = "k", cmd = "sleep 30 & sleep 30; wait"})
	if !testing.expect(t, ok, "k starts") {
		return
	}
	pgid := posix.pid_t(k.pid)
	time.sleep(100 * time.Millisecond)
	term_kill(&e.ed, k)
	testing.expect(t, !k.alive, "kill stops the session")
	testing.expect_value(t, k.code, 128 + 9)
	testing.expect(t, e2e_group_gone(pgid), "the whole process group is gone")
	testing.expect(t, term_find(&e.ed, "k") == k, "a killed session keeps its output")

	term_spawn(&e.ed, k)
	testing.expect(t, k.alive && posix.pid_t(k.pid) != pgid, "restart respawns it")
	term_close(&e.ed, k)
	testing.expect(t, term_find(&e.ed, "k") == nil, "close frees it")
}

@(test)
e2e_term_shell_unaffected :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	task, ok := term_create(&e.ed, {name = "task", cmd = "echo task_out; sleep 30"})
	if !testing.expect(t, ok, "the task starts") {
		return
	}
	e2e_term_alt_t(&e)
	sh := term_find(&e.ed, TERM_SHELL)
	if sh == nil || !sh.alive {
		return
	}
	testing.expect(t, e.ed.terminal.active && e.ed.terminal.shown == sh, "Alt+t shows the default shell")
	pid := sh.pid
	e2e_term_settle(&e, 300)
	e2e_type(&e, "echo qed_shell_marker\n")
	_, _, found := e2e_term_wait_row(&e, "qed_shell_marker", 4000)
	testing.expect(t, found, "the shell runs commands")
	e2e_render(&e)
	testing.expect(t, !e2e_grid_has(&e, " shell "), "the default shell pane has no title")
	e2e_term_alt_t(&e)
	testing.expect(t, !e.ed.terminal.active, "Alt+t hides it")

	term_show(&e.ed, task)
	e2e_term_alt_t(&e)
	testing.expect(t, !e.ed.terminal.active, "Alt+t hides a shown task")
	e2e_term_alt_t(&e)
	testing.expect(t, e.ed.terminal.shown == sh && sh.pid == pid, "Alt+t brings back the same shell, not the task")
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.terminal.active, "Esc closes the terminal at the prompt")
	testing.expect(t, task.alive, "the task kept running")

	e2e_term_alt_t(&e)
	e2e_type(&e, "exit\n")
	testing.expect(t, e2e_term_until(&e, 4000, e2e_term_exited, sh), "exiting the shell ends the session")
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.terminal.active, "a key in a dead shell closes the pane")
	e2e_term_alt_t(&e)
	testing.expect(t, sh.alive && sh.pid != pid, "Alt+t starts a fresh shell")
}

@(test)
e2e_term_plugin_unload :: proc(t: ^testing.T) {
	e, dir := e2e_reload_start()
	defer e2e_reload_stop(&e, dir)

	reload_write(dir, "tt.lua", `return {setup = function()
		qed.command{name = "TT: Start", run = function()
			qed.term.create{name = "owned", cmd = "sleep 30 & sleep 30; wait"}
			qed.term.create{name = "kept", cmd = "sleep 30", detach = true}
			qed.term.show("owned")
		end}
	end}`)
	testing.expect(t, plugins_poll(&e.ed), "the plugin loads")
	cmd, ok := plugin_test_command(&e.ed, "TT: Start")
	if !testing.expect(t, ok, "TT: Start registered") {
		return
	}
	command_run(&e.ed, cmd)
	owned, kept := term_find(&e.ed, "owned"), term_find(&e.ed, "kept")
	if !testing.expect(t, owned != nil && kept != nil, "both sessions exist") {
		return
	}
	testing.expect(t, e.ed.terminal.shown == owned, "show switches the overlay")
	testing.expect(t, owned.owner == "tt" && kept.owner == "", "the creator owns the session unless detached")
	pgid := posix.pid_t(owned.pid)

	reload_write(dir, "tt.lua", `return {setup = function() end}`)
	testing.expect(t, plugins_poll(&e.ed), "the edit reloads")
	testing.expect(t, term_find(&e.ed, "owned") == nil, "the owned session is torn down")
	testing.expect(t, e2e_group_gone(pgid), "its process group is gone")
	testing.expect(t, !e.ed.terminal.active && e.ed.terminal.shown == nil, "the pane that showed it closes")
	testing.expect(t, term_find(&e.ed, "kept") == kept && kept.alive, "a detached session survives")
	testing.expect_value(t, reload_owned(&e.ed.plugins, "tt"), 0)
	e2e_render(&e)
}

@(test)
e2e_term_master_cloexec :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	a, ok_a := term_create(&e.ed, {name = "a", cmd = "sleep 30"})
	b, ok_b := term_create(&e.ed, {name = "b", cmd = "sleep 30"})
	if !testing.expect(t, ok_a && ok_b, "both sessions start") {
		return
	}
	time.sleep(50 * time.Millisecond)
	index_of := proc(fdinfo: string) -> string {
		data, _ := os.read_entire_file(fdinfo, context.temp_allocator)
		for line in strings.split_lines(string(data), context.temp_allocator) {
			if strings.has_prefix(line, "tty-index:") {
				return strings.trim_space(line[len("tty-index:"):])
			}
		}
		return ""
	}
	a_index := index_of(fmt.tprintf("/proc/self/fdinfo/%d", a.pty_fd))
	if a_index == "" {
		return
	}
	// until the forked child execs it still holds every parent fd, CLOEXEC or not
	self_exe, _ := os.read_link("/proc/self/exe", context.temp_allocator)
	for start := time.tick_now(); time.duration_seconds(time.tick_since(start)) < 5; {
		exe, _ := os.read_link(fmt.tprintf("/proc/%d/exe", b.pid), context.temp_allocator)
		if exe != self_exe {
			break
		}
		time.sleep(time.Millisecond)
	}
	fds, _ := os.read_directory_by_path(fmt.tprintf("/proc/%d/fdinfo", b.pid), -1, context.temp_allocator)
	testing.expect(t, len(fds) > 0, "the later child's fds are readable")
	for f in fds {
		testing.expectf(t, index_of(f.fullpath) != a_index, "the later child holds fd %s on the earlier session's master", f.name)
	}
}

@(test)
e2e_term_send_never_blocks :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	s, ok := term_create(&e.ed, {name = "deaf", cmd = "sleep 30"})
	if !testing.expect(t, ok, "the session starts") {
		return
	}
	big := make([]u8, 3 * TERM_PENDING_MAX, context.temp_allocator)
	for &ch in big {
		ch = 'x'
	}
	start := time.tick_now()
	term_send(s, big)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 1000, "a send to a program that never reads returns at once")
	testing.expect_value(t, len(s.pending), TERM_PENDING_MAX)
	term_pump(&e.ed)
	found := false
	for l in e.ed.log {
		found ||= l.level == .Warn && strings.contains(l.text, "deaf is not reading its input")
	}
	testing.expect(t, found, "the dropped input is logged")
	term_kill(&e.ed, s)
	testing.expect_value(t, len(s.pending), 0)
}

@(test)
e2e_term_kill_shell_job :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)

	sh := term_shell(&e.ed)
	if sh == nil {
		return
	}
	e2e_term_settle(&e, 300)
	term_send(sh, transmute([]u8)string("sh -c \"trap '' HUP; sleep 300\"\r"))
	if !testing.expect(t, e2e_term_until(&e, 4000, term_busy, sh), "the job takes the foreground") {
		return
	}
	job := posix.tcgetpgrp(posix.FD(sh.pty_fd))
	term_kill(&e.ed, sh)
	testing.expect(t, e2e_group_gone(job), "the foreground job's group dies with the shell")
}
