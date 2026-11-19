package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

Subprocess :: struct {
	id:        u64,
	process:   os.Process,
	stdout:    ^os.File,
	stderr:    ^os.File,
	out:       strings.Builder,
	err:       strings.Builder,
	running:   bool,
	exit_code: int,
}

@(private = "file")
g_subprocess_counter: int

fd_set_nonblock :: proc(file: ^os.File) {
	fd := posix.FD(os.fd(file))
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | transmute(c.int)posix.O_Flags{.NONBLOCK})
}

// Spawn `cmd` under `sh -c` with `stdin_body` on its stdin and a non-blocking pipe
// on its stdout, for main-loop polling via subprocess_drain. The body goes through
// a temp file (not a pipe) so a large body can't deadlock before the child reads,
// and the temp is unlinked immediately — so the command MUST consume stdin, never a
// `@file` reference to the temp (see the FIM curl quirk in DESIGN.md).
subprocess_start :: proc(cmd: string, stdin_body: []u8, working_dir: string) -> (Subprocess, os.Error, bool) {
	return subprocess_spawn({"sh", "-c", cmd}, stdin_body, working_dir)
}

subprocess_spawn :: proc(command: []string, stdin_body: []u8, working_dir: string, env: []string = nil, capture_stderr := false, group := false) -> (Subprocess, os.Error, bool) {
	posix.sigignore(.SIGPIPE)

	g_subprocess_counter += 1
	tmp := fmt.tprintf("/tmp/qed-subproc-%d-%d.tmp", posix.getpid(), g_subprocess_counter)
	fd, oerr := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o600))
	if oerr != nil {
		return {}, oerr, false
	}
	os.write(fd, stdin_body)
	os.close(fd)

	in_file, ierr := os.open(tmp, {.Read})
	if ierr != nil {
		os.remove(tmp)
		return {}, ierr, false
	}
	out_r, out_w, perr := os.pipe()
	if perr != nil {
		os.close(in_file)
		os.remove(tmp)
		return {}, perr, false
	}

	err_r, err_w: ^os.File
	if capture_stderr {
		r, w, eerr := os.pipe()
		if eerr != nil {
			os.close(in_file)
			os.close(out_r)
			os.close(out_w)
			os.remove(tmp)
			return {}, eerr, false
		}
		err_r, err_w = r, w
	}

	process: os.Process
	serr: os.Error
	if group {
		process, serr = subprocess_start_group(command, env, working_dir, in_file, out_w, err_w)
	} else {
		process, serr = os.process_start(
			{command = command, working_dir = working_dir, env = env, stdin = in_file, stdout = out_w, stderr = err_w},
		)
	}
	os.close(in_file)
	os.close(out_w)
	if err_w != nil {
		os.close(err_w)
	}
	os.remove(tmp)
	if serr != nil {
		os.close(out_r)
		if err_r != nil {
			os.close(err_r)
		}
		return {}, serr, false
	}

	fd_set_nonblock(out_r)
	sp := Subprocess{id = u64(g_subprocess_counter), process = process, stdout = out_r, out = strings.builder_make(), running = true}
	if err_r != nil {
		fd_set_nonblock(err_r)
		sp.stderr = err_r
		sp.err = strings.builder_make()
	}
	return sp, nil, true
}

subprocess_exe_path :: proc(name: string) -> (string, bool) {
	if strings.index_byte(name, '/') >= 0 {
		return name, posix.access(strings.clone_to_cstring(name, context.temp_allocator), {.X_OK}) == .OK
	}
	for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		path := fmt.tprintf("%s/%s", dir if dir != "" else ".", name)
		st: posix.stat_t
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		if posix.stat(cpath, &st) == .OK && posix.S_ISREG(st.st_mode) && posix.access(cpath, {.X_OK}) == .OK {
			return path, true
		}
	}
	return "", false
}

// Like os.process_start, but the child leads its own process group so a kill reaches its descendants.
subprocess_start_group :: proc(command: []string, env: []string, working_dir: string, stdin, stdout, stderr: ^os.File) -> (os.Process, os.Error) {
	exe, found := subprocess_exe_path(command[0])
	if !found {
		return {}, .Not_Exist
	}
	cexe := strings.clone_to_cstring(exe, context.temp_allocator)
	cargs := make([]cstring, len(command) + 1, context.temp_allocator)
	for a, i in command {
		cargs[i] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	envs := env
	if envs == nil {
		envs, _ = os.environ(context.temp_allocator)
	}
	cenv := make([]cstring, len(envs) + 1, context.temp_allocator)
	for e, i in envs {
		cenv[i] = strings.clone_to_cstring(e, context.temp_allocator)
	}
	cdir := strings.clone_to_cstring(working_dir, context.temp_allocator)
	in_fd := posix.FD(os.fd(stdin))
	out_fd := posix.FD(os.fd(stdout))
	err_fd := posix.FD(os.fd(stderr)) if stderr != nil else out_fd
	fail_byte := [1]u8{1}
	report: [2]posix.FD
	if posix.pipe(&report) != .OK {
		return {}, .Unknown
	}
	posix.fcntl(report[1], .SETFD, posix.FD_CLOEXEC)
	pid := posix.fork()
	if pid < 0 {
		posix.close(report[0])
		posix.close(report[1])
		return {}, .Unknown
	}
	if pid == 0 {
		posix.close(report[0])
		posix.setpgid(0, 0)
		posix.dup2(in_fd, 0)
		posix.dup2(out_fd, 1)
		posix.dup2(err_fd, 2)
		if working_dir != "" && posix.chdir(cdir) != .OK {
			posix.write(report[1], &fail_byte[0], 1)
			posix._exit(126)
		}
		posix.execve(cexe, raw_data(cargs), raw_data(cenv))
		posix.write(report[1], &fail_byte[0], 1)
		posix._exit(126)
	}
	posix.setpgid(pid, pid)
	posix.close(report[1])
	failed: [1]u8
	n := posix.read(report[0], &failed[0], 1)
	posix.close(report[0])
	if n > 0 {
		status: c.int
		posix.waitpid(pid, &status, {})
		return {}, .Not_Exist
	}
	return os.process_open(int(pid))
}

subprocess_kill_group :: proc(p: ^Subprocess) {
	if p.process.pid > 0 {
		posix.kill(-posix.pid_t(p.process.pid), .SIGKILL)
	}
	_ = os.process_kill(p.process)
}

// Drain whatever is readable now into `p.out`; returns true once stdout hits EOF
// (the child closed it / exited) so the caller can collect the full output.
subprocess_drain :: proc(p: ^Subprocess, max_out := 0) -> (done: bool) {
	done = subprocess_drain_file(p.stdout, &p.out, max_out)
	if p.stderr != nil && !subprocess_drain_file(p.stderr, &p.err) {
		done = false
	}
	return
}

subprocess_drain_file :: proc(file: ^os.File, sb: ^strings.Builder, max := 0) -> (eof: bool) {
	fd := posix.FD(os.fd(file))
	buf: [16384]u8
	total := 0
	for max == 0 || total < max {
		n := posix.read(fd, &buf[0], len(buf))
		if n > 0 {
			strings.write_bytes(sb, buf[:n])
			total += n
			continue
		}
		if n == 0 || posix.errno() != .EAGAIN {
			return true
		}
		break
	}
	return false
}

subprocess_close_pipes :: proc(p: ^Subprocess) {
	os.close(p.stdout)
	if p.stderr != nil {
		os.close(p.stderr)
		p.stderr = nil
	}
}

subprocess_reap :: proc(p: ^Subprocess) -> (exited: bool) {
	state, err := os.process_wait(p.process, 0)
	if err == os.General_Error.Timeout {
		return false
	}
	subprocess_close_pipes(p)
	p.exit_code = state.exit_code
	p.running = false
	return true
}

// After a drain reported done: reap the child and return the accumulated output.
// The string is backed by `p.out`, valid until subprocess_destroy.
subprocess_output :: proc(p: ^Subprocess) -> string {
	subprocess_close_pipes(p)
	state, _ := os.process_wait(p.process, time.Second)
	p.exit_code = state.exit_code
	p.running = false
	return strings.to_string(p.out)
}

subprocess_kill :: proc(p: ^Subprocess) {
	if !p.running {
		return
	}
	_ = os.process_kill(p.process)
	subprocess_close_pipes(p)
	_, _ = os.process_wait(p.process, time.Second)
	p.running = false
	subprocess_destroy(p)
}

subprocess_destroy :: proc(p: ^Subprocess) {
	strings.builder_destroy(&p.out)
	strings.builder_destroy(&p.err)
}
