package pty

import "core:c"
import "core:strings"

foreign import lib "libqedpty.a"
foreign import _util "system:util"

@(default_calling_convention = "c")
foreign lib {
	qed_pty_spawn :: proc(rows, cols: c.int, shell, cwd: cstring, out_pid: ^c.int) -> c.int ---
	qed_pty_resize :: proc(fd, rows, cols: c.int) ---
}

spawn :: proc(rows, cols: int, shell, cwd: string) -> (fd: int, pid: int) {
	sh := strings.clone_to_cstring(shell, context.temp_allocator)
	cw := strings.clone_to_cstring(cwd, context.temp_allocator)
	p: c.int
	f := qed_pty_spawn(c.int(rows), c.int(cols), sh, cw, &p)
	return int(f), int(p)
}

resize :: proc(fd, rows, cols: int) {
	qed_pty_resize(c.int(fd), c.int(rows), c.int(cols))
}
