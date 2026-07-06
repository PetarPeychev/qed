package main

import "core:c"
import "core:os"
import "core:sys/posix"
import "lib:pty"
import "lib:tb2"
import "lib:vterm"

Terminal :: struct {
	active: bool,
	alive:  bool,
	pty_fd: int,
	pid:    int,
	vt:     ^vterm.VTerm,
	screen: ^vterm.Screen,
	cols:   int,
	rows:   int,
}

term_alive :: proc(editor: ^Editor) -> bool {
	return editor.terminal.alive
}

term_grid_size :: proc(editor: ^Editor) -> (cols, rows: int) {
	lay := overlay_layout(editor)
	return lay.inner.w, lay.inner.h
}

term_toggle :: proc(editor: ^Editor) {
	t := &editor.terminal
	if t.active {
		t.active = false
		return
	}
	if t.vt == nil || !t.alive {
		term_free_vt(t)
		if !term_start(editor) {
			return
		}
	}
	t.active = true
	term_resize(editor)
}

term_start :: proc(editor: ^Editor) -> bool {
	t := &editor.terminal
	cols, rows := term_grid_size(editor)
	if cols < 1 || rows < 1 {
		editor_set_message(editor, "Terminal: window too small", true)
		return false
	}
	shell := os.get_env("SHELL", context.temp_allocator)
	if shell == "" {
		shell = "/bin/sh"
	}
	fd, pid := pty.spawn(rows, cols, shell, editor.working_root)
	if fd < 0 {
		editor_set_message(editor, "Terminal: failed to start shell", true)
		return false
	}
	nfd := posix.FD(fd)
	flags := posix.fcntl(nfd, .GETFL)
	posix.fcntl(nfd, .SETFL, flags | transmute(c.int)posix.O_Flags{.NONBLOCK})

	vt := vterm.new(c.int(rows), c.int(cols))
	vterm.set_utf8(vt, 1)
	screen := vterm.obtain_screen(vt)
	vterm.screen_enable_altscreen(screen, 1)
	state := vterm.obtain_state(vt)
	for i in 0 ..< 16 {
		col := term_color(COLOR_TERM_ANSI[i])
		vterm.state_set_palette_color(state, c.int(i), &col)
	}
	fg := term_color(COLOR_TERM_FG)
	bg := term_color(COLOR_TERM_BG)
	vterm.screen_set_default_colors(screen, &fg, &bg)
	vterm.screen_reset(screen, 1)

	t.vt = vt
	t.screen = screen
	t.pty_fd = fd
	t.pid = pid
	t.cols = cols
	t.rows = rows
	t.alive = true
	return true
}

term_resize :: proc(editor: ^Editor) {
	t := &editor.terminal
	if t.vt == nil {
		return
	}
	cols, rows := term_grid_size(editor)
	if cols < 1 || rows < 1 || (cols == t.cols && rows == t.rows) {
		return
	}
	t.cols = cols
	t.rows = rows
	vterm.set_size(t.vt, c.int(rows), c.int(cols))
	if t.alive {
		pty.resize(t.pty_fd, rows, cols)
	}
}

term_pump :: proc(editor: ^Editor) -> bool {
	t := &editor.terminal
	if t.vt == nil || !t.alive {
		return false
	}
	fd := posix.FD(t.pty_fd)
	buf: [16384]u8
	got := false
	for {
		n := posix.read(fd, &buf[0], len(buf))
		if n > 0 {
			vterm.input_write(t.vt, &buf[0], c.size_t(n))
			got = true
			continue
		}
		if n == 0 || posix.errno() != .EAGAIN {
			term_mark_exited(editor)
			return true
		}
		break
	}
	return got && t.active
}

term_mark_exited :: proc(editor: ^Editor) {
	t := &editor.terminal
	if !t.alive {
		return
	}
	t.alive = false
	posix.close(posix.FD(t.pty_fd))
	status: c.int
	posix.waitpid(posix.pid_t(t.pid), &status, {.NOHANG})
	editor_set_message(editor, "Terminal: process exited")
}

term_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.terminal
	alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
	if alt && (ev.ch == 't' || ev.ch == 'T') {
		t.active = false
		return
	}
	if !t.alive {
		t.active = false
		return
	}
	term_send_key(t, ev)
	term_flush_output(t)
}

term_send_key :: proc(t: ^Terminal, ev: tb2.Event) {
	mod := vterm.MOD_NONE
	if (u8(ev.mod) & u8(tb2.Mod.Shift)) != 0 {
		mod |= vterm.MOD_SHIFT
	}
	if (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0 {
		mod |= vterm.MOD_ALT
	}
	if (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0 {
		mod |= vterm.MOD_CTRL
	}

	// Enter/Tab/Backspace/Esc are control-byte keycodes; termbox tags them with a
	// spurious Ctrl modifier that would encode Ctrl+Enter etc. — drop it here.
	base := mod &~ vterm.MOD_CTRL

	#partial switch ev.key {
	case .Enter, .Ctrl_J:
		vterm.keyboard_key(t.vt, .Enter, base)
		return
	case .Tab:
		vterm.keyboard_key(t.vt, .Tab, base)
		return
	case .Back_Tab:
		vterm.keyboard_key(t.vt, .Tab, base | vterm.MOD_SHIFT)
		return
	case .Backspace, .Backspace2:
		vterm.keyboard_key(t.vt, .Backspace, base)
		return
	case .Esc:
		vterm.keyboard_key(t.vt, .Escape, base)
		return
	case .Arrow_Up:
		vterm.keyboard_key(t.vt, .Up, mod)
		return
	case .Arrow_Down:
		vterm.keyboard_key(t.vt, .Down, mod)
		return
	case .Arrow_Left:
		vterm.keyboard_key(t.vt, .Left, mod)
		return
	case .Arrow_Right:
		vterm.keyboard_key(t.vt, .Right, mod)
		return
	case .Delete:
		vterm.keyboard_key(t.vt, .Del, mod)
		return
	case .Insert:
		vterm.keyboard_key(t.vt, .Ins, mod)
		return
	case .Home:
		vterm.keyboard_key(t.vt, .Home, mod)
		return
	case .End:
		vterm.keyboard_key(t.vt, .End, mod)
		return
	case .Pgup:
		vterm.keyboard_key(t.vt, .PageUp, mod)
		return
	case .Pgdn:
		vterm.keyboard_key(t.vt, .PageDown, mod)
		return
	case .Space:
		vterm.keyboard_unichar(t.vt, ' ', mod)
		return
	}

	if ev.ch != 0 {
		vterm.keyboard_unichar(t.vt, u32(ev.ch), mod)
		return
	}
	k := u16(ev.key)
	if k >= 1 && k <= 26 {
		vterm.keyboard_unichar(t.vt, u32('a') + u32(k) - 1, mod | vterm.MOD_CTRL)
	}
}

term_flush_output :: proc(t: ^Terminal) {
	if !t.alive {
		return
	}
	obuf: [4096]u8
	for {
		n := vterm.output_read(t.vt, &obuf[0], c.size_t(len(obuf)))
		if n == 0 {
			break
		}
		posix.write(posix.FD(t.pty_fd), &obuf[0], n)
	}
}

term_render :: proc(editor: ^Editor) {
	t := &editor.terminal
	lay := overlay_layout(editor)
	inner := pane_draw_box(lay.box)
	if t.vt == nil {
		return
	}
	rows := min(t.rows, inner.h)
	cols := min(t.cols, inner.w)
	for row in 0 ..< rows {
		for col := 0; col < cols; {
			cell: vterm.ScreenCell
			vterm.screen_get_cell(t.screen, {c.int(row), c.int(col)}, &cell)
			w := int(cell.width)
			if w < 1 {
				w = 1
			}
			fg, bg := term_cell_colors(t, &cell)
			r := rune(cell.chars[0])
			if r == 0 {
				r = ' '
			}
			x := i32(inner.x + col)
			y := i32(inner.y + row)
			tb2.set_cell(x, y, r, fg, bg)
			for k in 1 ..< len(cell.chars) {
				if cell.chars[k] == 0 {
					break
				}
				tb2.extend_cell(x, y, rune(cell.chars[k]))
			}
			col += w
		}
	}
	if t.active && t.alive {
		cur: vterm.Pos
		vterm.state_get_cursorpos(vterm.obtain_state(t.vt), &cur)
		if int(cur.row) < rows && int(cur.col) < cols {
			tb2.set_cursor(i32(inner.x + int(cur.col)), i32(inner.y + int(cur.row)))
			return
		}
	}
	tb2.hide_cursor()
}

term_cell_colors :: proc(t: ^Terminal, cell: ^vterm.ScreenCell) -> (fg, bg: tb2.Color) {
	f := cell.fg
	b := cell.bg
	fg = term_rgb(t, &f)
	bg = term_rgb(t, &b)
	if (cell.attrs & vterm.ATTR_REVERSE) != 0 {
		fg, bg = bg, fg
	}
	return
}

term_rgb :: proc(t: ^Terminal, col: ^vterm.Color) -> tb2.Color {
	if (col.type & vterm.COLOR_DEFAULT_FG) != 0 {
		return COLOR_TERM_FG
	}
	if (col.type & vterm.COLOR_DEFAULT_BG) != 0 {
		return COLOR_TERM_BG
	}
	vterm.screen_convert_color_to_rgb(t.screen, col)
	return tb2.Color(u32(col.v0) << 16 | u32(col.v1) << 8 | u32(col.v2))
}

term_color :: proc(col: tb2.Color) -> vterm.Color {
	v := u32(col)
	return vterm.Color{type = 0, v0 = u8(v >> 16), v1 = u8(v >> 8), v2 = u8(v)}
}

term_destroy :: proc(editor: ^Editor) {
	t := &editor.terminal
	if t.alive {
		posix.kill(posix.pid_t(t.pid), .SIGKILL)
		posix.close(posix.FD(t.pty_fd))
		status: c.int
		posix.waitpid(posix.pid_t(t.pid), &status, {.NOHANG})
		t.alive = false
	}
	term_free_vt(t)
}

term_free_vt :: proc(t: ^Terminal) {
	if t.vt != nil {
		vterm.free(t.vt)
		t.vt = nil
		t.screen = nil
	}
	t.alive = false
}
