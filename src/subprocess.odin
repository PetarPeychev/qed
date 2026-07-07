package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

Subprocess :: struct {
	process: os.Process,
	stdout:  ^os.File,
	out:     strings.Builder,
	running: bool,
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
subprocess_start :: proc(cmd: string, stdin_body: []u8, working_dir: string) -> (Subprocess, bool) {
	posix.sigignore(.SIGPIPE)

	g_subprocess_counter += 1
	tmp := fmt.tprintf("/tmp/qed-subproc-%d-%d.tmp", posix.getpid(), g_subprocess_counter)
	fd, oerr := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o600))
	if oerr != nil {
		return {}, false
	}
	os.write(fd, stdin_body)
	os.close(fd)

	in_file, ierr := os.open(tmp, {.Read})
	if ierr != nil {
		os.remove(tmp)
		return {}, false
	}
	out_r, out_w, perr := os.pipe()
	if perr != nil {
		os.close(in_file)
		os.remove(tmp)
		return {}, false
	}

	process, serr := os.process_start(
		{command = {"sh", "-c", cmd}, working_dir = working_dir, stdin = in_file, stdout = out_w},
	)
	os.close(in_file)
	os.close(out_w)
	os.remove(tmp)
	if serr != nil {
		os.close(out_r)
		return {}, false
	}

	fd_set_nonblock(out_r)
	return Subprocess{process = process, stdout = out_r, out = strings.builder_make(), running = true}, true
}

// Drain whatever is readable now into `p.out`; returns true once stdout hits EOF
// (the child closed it / exited) so the caller can collect the full output.
subprocess_drain :: proc(p: ^Subprocess) -> (done: bool) {
	fd := posix.FD(os.fd(p.stdout))
	buf: [16384]u8
	for {
		n := posix.read(fd, &buf[0], len(buf))
		if n > 0 {
			strings.write_bytes(&p.out, buf[:n])
			continue
		}
		if n == 0 || posix.errno() != .EAGAIN {
			return true
		}
		break
	}
	return false
}

// After a drain reported done: reap the child and return the accumulated output.
// The string is backed by `p.out`, valid until subprocess_destroy.
subprocess_output :: proc(p: ^Subprocess) -> string {
	os.close(p.stdout)
	_, _ = os.process_wait(p.process, time.Second)
	p.running = false
	return strings.to_string(p.out)
}

subprocess_kill :: proc(p: ^Subprocess) {
	if !p.running {
		return
	}
	_ = os.process_kill(p.process)
	os.close(p.stdout)
	_, _ = os.process_wait(p.process, time.Second)
	p.running = false
	subprocess_destroy(p)
}

subprocess_destroy :: proc(p: ^Subprocess) {
	strings.builder_destroy(&p.out)
}
