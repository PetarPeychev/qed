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

subprocess_spawn :: proc(command: []string, stdin_body: []u8, working_dir: string, env: []string = nil, capture_stderr := false) -> (Subprocess, os.Error, bool) {
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

	process, serr := os.process_start(
		{command = command, working_dir = working_dir, env = env, stdin = in_file, stdout = out_w, stderr = err_w},
	)
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

// Drain whatever is readable now into `p.out`; returns true once stdout hits EOF
// (the child closed it / exited) so the caller can collect the full output.
subprocess_drain :: proc(p: ^Subprocess) -> (done: bool) {
	done = subprocess_drain_file(p.stdout, &p.out)
	if p.stderr != nil && !subprocess_drain_file(p.stderr, &p.err) {
		done = false
	}
	return
}

subprocess_drain_file :: proc(file: ^os.File, sb: ^strings.Builder) -> (eof: bool) {
	fd := posix.FD(os.fd(file))
	buf: [16384]u8
	for {
		n := posix.read(fd, &buf[0], len(buf))
		if n > 0 {
			strings.write_bytes(sb, buf[:n])
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
