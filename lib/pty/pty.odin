package pty

import "core:c"
import "core:strings"

foreign import lib "libqedpty.a"
foreign import _util "system:util"

@(default_calling_convention = "c")
foreign lib {
	qed_pty_spawn :: proc(rows, cols: c.int, argv: [^]cstring, envp: [^]cstring, cwd: cstring, out_pid: ^c.int) -> c.int ---
	qed_pty_resize :: proc(fd, rows, cols: c.int) ---
	qed_pty_open :: proc(rows, cols: c.int, out_master, out_slave: ^c.int) -> c.int ---
	qed_pty_cell_pixels :: proc(fd: c.int, w, h: ^c.int) ---
}

open :: proc(rows, cols: int) -> (master, slave: int, ok: bool) {
	m, s: c.int
	rc := qed_pty_open(c.int(rows), c.int(cols), &m, &s)
	return int(m), int(s), rc == 0
}

spawn :: proc(rows, cols: int, argv: []string, env: []string, cwd: string) -> (fd: int, pid: int) {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {
		cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	cenv := make([dynamic]cstring, 0, len(env) + 2, context.temp_allocator)
	for kv in env {
		if !strings.has_prefix(kv, "TERM=") {
			append(&cenv, strings.clone_to_cstring(kv, context.temp_allocator))
		}
	}
	append(&cenv, "TERM=xterm-256color", nil)
	cw := strings.clone_to_cstring(cwd, context.temp_allocator)
	p: c.int
	f := qed_pty_spawn(c.int(rows), c.int(cols), raw_data(cargv), raw_data(cenv), cw, &p)
	return int(f), int(p)
}

cell_pixels :: proc(fd: int) -> (w, h: int) {
	cw, ch: c.int
	qed_pty_cell_pixels(c.int(fd), &cw, &ch)
	return int(cw), int(ch)
}

resize :: proc(fd, rows, cols: int) {
	qed_pty_resize(c.int(fd), c.int(rows), c.int(cols))
}
