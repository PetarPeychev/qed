package main

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "lib:pty"
import "lib:tb2"
import "lib:vterm"

TermLine :: struct {
	cells: []vterm.ScreenCell,
}

// row = virtual line index over the scrollback ring (0..sb_len) then the live
// screen (sb_len..sb_len+rows); col = grid column.
TermPos :: struct {
	row, col: int,
}

Terminal :: struct {
	active:      bool,
	alive:       bool,
	pty_fd:      int,
	pid:         int,
	vt:          ^vterm.VTerm,
	screen:      ^vterm.Screen,
	cols:        int,
	rows:        int,
	mouse_btn:   int,
	altscreen:   bool,
	mouse_mode:  bool,
	sel_active:  bool,
	sel_drag:    bool,
	sel_anchor:  TermPos,
	sel_end:     TermPos,
	// Scrollback ring of lines pushed off the top of the main screen; sb_view is
	// how many lines we're scrolled up from the live bottom (0 = live).
	sb_ring:   []TermLine,
	sb_start:  int,
	sb_len:    int,
	sb_view:   int,
	ctx:       runtime.Context,
}

term_callbacks := vterm.ScreenCallbacks {
	settermprop = term_sb_settermprop,
	sb_pushline = term_sb_pushline,
	sb_popline  = term_sb_popline,
	sb_clear    = term_sb_clear,
}

term_sb_pushline :: proc "c" (cols: c.int, cells: [^]vterm.ScreenCell, user: rawptr) -> c.int {
	t := (^Terminal)(user)
	if len(t.sb_ring) == 0 {
		return 0
	}
	context = t.ctx
	line := make([]vterm.ScreenCell, int(cols))
	for i in 0 ..< int(cols) {
		line[i] = cells[i]
	}
	rc := len(t.sb_ring)
	grew := t.sb_len < rc
	slot: int
	if grew {
		slot = (t.sb_start + t.sb_len) % rc
		t.sb_len += 1
	} else {
		slot = t.sb_start
		delete(t.sb_ring[slot].cells)
		t.sb_start = (t.sb_start + 1) % rc
	}
	t.sb_ring[slot] = {line}
	// Keep a scrolled-up viewport pinned to the same lines as output streams in.
	if t.sb_view > 0 && grew {
		t.sb_view = min(t.sb_view + 1, t.sb_len)
	}
	return 1
}

term_sb_popline :: proc "c" (cols: c.int, cells: [^]vterm.ScreenCell, user: rawptr) -> c.int {
	t := (^Terminal)(user)
	if t.sb_len == 0 {
		return 0
	}
	context = t.ctx
	t.sb_len -= 1
	slot := (t.sb_start + t.sb_len) % len(t.sb_ring)
	line := t.sb_ring[slot].cells
	for i in 0 ..< int(cols) {
		if i < len(line) {
			cells[i] = line[i]
		} else {
			cells[i] = {}
			cells[i].width = 1
		}
	}
	delete(line)
	t.sb_ring[slot] = {}
	if t.sb_view > t.sb_len {
		t.sb_view = t.sb_len
	}
	return 1
}

term_sb_clear :: proc "c" (user: rawptr) -> c.int {
	t := (^Terminal)(user)
	context = t.ctx
	term_sb_free(t)
	return 1
}

term_sb_settermprop :: proc "c" (prop: c.int, val: ^vterm.Value, user: rawptr) -> c.int {
	if prop == vterm.PROP_ALTSCREEN {
		t := (^Terminal)(user)
		t.altscreen = val.number != 0
		t.sb_view = 0
	} else if prop == vterm.PROP_MOUSE {
		t := (^Terminal)(user)
		t.mouse_mode = val.number != 0
	}
	return 1
}

term_sb_free :: proc(t: ^Terminal) {
	for &l in t.sb_ring {
		delete(l.cells)
		l = {}
	}
	t.sb_start = 0
	t.sb_len = 0
	t.sb_view = 0
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

	t.ctx = context
	if t.sb_ring == nil {
		t.sb_ring = make([]TermLine, max(1, TERM_SCROLLBACK))
	}
	term_sb_free(t)
	t.altscreen = false
	vterm.screen_set_callbacks(screen, &term_callbacks, t)

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
	alt := ev_alt(ev)
	if alt && (ev.ch == 't' || ev.ch == 'T') {
		t.active = false
		return
	}
	// Full-screen programs (alt-screen) own Escape; at a plain shell prompt it
	// defocuses the pane instead (config-gated).
	if ev.key == .Esc && !alt && TERMINAL_ESCAPE_CLOSES && !t.altscreen {
		t.active = false
		return
	}
	if !t.alive {
		t.active = false
		return
	}
	t.sb_view = 0
	t.sel_active = false
	term_send_key(t, ev)
	term_flush_output(t)
}

term_mods :: proc(ev: tb2.Event) -> vterm.Modifier {
	mod := vterm.MOD_NONE
	if ev_shift(ev) {
		mod |= vterm.MOD_SHIFT
	}
	if ev_alt(ev) {
		mod |= vterm.MOD_ALT
	}
	if ev_ctrl(ev) {
		mod |= vterm.MOD_CTRL
	}
	return mod
}

term_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	t := &editor.terminal
	motion := ev_motion(ev)
	shift := ev_shift(ev)
	mod := term_mods(ev)
	lay := overlay_layout(editor)
	// A plain shell doesn't grab the mouse, so a drag there is a local text
	// selection; a mouse-mode program (vim/htop) takes it unless Shift forces local.
	local := !t.mouse_mode || shift

	// A release ends an in-progress selection (auto-copy) or clears the held
	// button so vterm doesn't keep it "down" after a drag that left the pane.
	if ev.key == .Mouse_Release {
		if t.sel_drag {
			t.sel_drag = false
			term_copy_selection(editor)
			return
		}
		if t.alive && t.mouse_btn != 0 {
			vterm.mouse_button(t.vt, c.int(t.mouse_btn), false, mod)
			t.mouse_btn = 0
			term_flush_output(t)
		}
		return
	}

	// Local text selection (plain-shell drag, or Shift over a mouse-mode program).
	// Handles drag-extend even when the pointer leaves the pane, and is robust to
	// tmux/WT dropping the clean button-press or injecting a stray release mid-drag:
	// a fresh press re-anchors, and a bare motion starts a drag if one isn't live.
	if local && ev.key == .Mouse_Left {
		if !motion && !mouse_in_rect(ev, lay.box) {
			t.active = false
			return
		}
		row := clamp(int(ev.y) - lay.inner.y, 0, t.rows - 1)
		col := clamp(int(ev.x) - lay.inner.x, 0, t.cols - 1)
		vi := term_vi_at(t, row)
		if !motion || !t.sel_drag {
			t.sel_drag = true
			t.sel_active = true
			t.sel_anchor = {vi, col}
		}
		t.sel_end = {vi, col}
		return
	}

	if !mouse_in_rect(ev, lay.box) {
		if ev.key == .Mouse_Left && !motion {
			t.active = false
		}
		return
	}
	if !t.alive {
		return
	}
	row := clamp(int(ev.y) - lay.inner.y, 0, t.rows - 1)
	col := clamp(int(ev.x) - lay.inner.x, 0, t.cols - 1)

	// Position first: vterm reads the stored cell for the button report.
	vterm.mouse_move(t.vt, c.int(row), c.int(col), mod)
	if !motion {
		#partial switch ev.key {
		case .Mouse_Left:
			t.sel_active = false
			t.mouse_btn = 1
			vterm.mouse_button(t.vt, 1, true, mod)
		case .Mouse_Middle:
			t.mouse_btn = 2
			vterm.mouse_button(t.vt, 2, true, mod)
		case .Mouse_Right:
			t.mouse_btn = 3
			vterm.mouse_button(t.vt, 3, true, mod)
		case .Mouse_Wheel_Up:
			if t.altscreen {
				vterm.mouse_button(t.vt, 4, true, mod)
			} else {
				t.sb_view = min(t.sb_view + WHEEL_SCROLL_LINES, t.sb_len)
			}
		case .Mouse_Wheel_Down:
			if t.altscreen {
				vterm.mouse_button(t.vt, 5, true, mod)
			} else {
				t.sb_view = max(0, t.sb_view - WHEEL_SCROLL_LINES)
			}
		}
	}
	term_flush_output(t)
}

term_vi_at :: proc(t: ^Terminal, screen_row: int) -> int {
	v := clamp(t.sb_view, 0, t.sb_len)
	return t.sb_len - v + screen_row
}

term_sel_bounds :: proc(t: ^Terminal) -> (s, e: TermPos) {
	a, b := t.sel_anchor, t.sel_end
	if a.row < b.row || (a.row == b.row && a.col <= b.col) {
		return a, b
	}
	return b, a
}

term_selected :: proc(t: ^Terminal, vi, col: int) -> bool {
	if !t.sel_active {
		return false
	}
	s, e := term_sel_bounds(t)
	if vi < s.row || vi > e.row {
		return false
	}
	c0 := s.col if vi == s.row else 0
	c1 := e.col if vi == e.row else t.cols - 1
	return col >= c0 && col <= c1
}

term_cell_at :: proc(t: ^Terminal, vi, col: int, cell: ^vterm.ScreenCell) {
	if vi >= t.sb_len {
		vterm.screen_get_cell(t.screen, {c.int(vi - t.sb_len), c.int(col)}, cell)
		return
	}
	line := t.sb_ring[(t.sb_start + vi) % len(t.sb_ring)].cells
	if col >= 0 && col < len(line) {
		cell^ = line[col]
	} else {
		cell^ = {}
		cell.width = 1
	}
}

term_copy_selection :: proc(editor: ^Editor) {
	t := &editor.terminal
	// A plain click (no drag) selects nothing — just clear any prior highlight.
	if !t.sel_active || t.sel_anchor == t.sel_end {
		t.sel_active = false
		return
	}
	s, e := term_sel_bounds(t)
	out := strings.builder_make(context.temp_allocator)
	for vi in s.row ..= e.row {
		c0 := s.col if vi == s.row else 0
		c1 := e.col if vi == e.row else t.cols - 1
		line := strings.builder_make(context.temp_allocator)
		for col := c0; col <= c1; {
			cell: vterm.ScreenCell
			term_cell_at(t, vi, col, &cell)
			w := int(cell.width)
			if w < 1 {
				w = 1
			}
			if cell.chars[0] == 0 {
				strings.write_rune(&line, ' ')
			} else {
				for k in 0 ..< len(cell.chars) {
					if cell.chars[k] == 0 {
						break
					}
					strings.write_rune(&line, rune(cell.chars[k]))
				}
			}
			col += w
		}
		strings.write_string(&out, strings.trim_right(strings.to_string(line), " "))
		if vi < e.row {
			strings.write_byte(&out, '\n')
		}
	}
	text := strings.to_string(out)
	if len(text) == 0 {
		return
	}
	clipboard_set(text)
	editor_set_message(editor, "Terminal: copied selection")
}

term_paste_overlay :: proc(editor: ^Editor, text: string) {
	term_paste(&editor.terminal, text)
}

term_paste :: proc(t: ^Terminal, text: string) {
	if !t.alive || t.vt == nil || len(text) == 0 {
		return
	}
	// Bracket the paste when the guest enabled it (no-op otherwise); the markers
	// go through vterm's output, so flush them around the raw body.
	vterm.keyboard_start_paste(t.vt)
	term_flush_output(t)
	body := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for i in 0 ..< len(text) {
		append(&body, '\r' if text[i] == '\n' else text[i])
	}
	term_write_all(t, body[:])
	vterm.keyboard_end_paste(t.vt)
	term_flush_output(t)
	t.sb_view = 0
	t.sel_active = false
}

term_write_all :: proc(t: ^Terminal, data: []u8) {
	fd := posix.FD(t.pty_fd)
	off := 0
	for off < len(data) {
		rem := len(data) - off
		n := posix.write(fd, &data[off], c.size_t(rem))
		if n > 0 {
			off += int(n)
			continue
		}
		if posix.errno() != .EAGAIN {
			break
		}
	}
}

term_send_key :: proc(t: ^Terminal, ev: tb2.Event) {
	mod := term_mods(ev)

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
	v := clamp(t.sb_view, 0, t.sb_len)
	base := t.sb_len + t.rows - rows - v
	for row in 0 ..< rows {
		vi := base + row
		live := vi >= t.sb_len
		sb_line: []vterm.ScreenCell
		if !live {
			sb_line = t.sb_ring[(t.sb_start + vi) % len(t.sb_ring)].cells
		}
		for col := 0; col < cols; {
			cell: vterm.ScreenCell
			switch {
			case live:
				vterm.screen_get_cell(t.screen, {c.int(vi - t.sb_len), c.int(col)}, &cell)
			case col < len(sb_line):
				cell = sb_line[col]
			case:
				cell.width = 1
			}
			w := int(cell.width)
			if w < 1 {
				w = 1
			}
			fg, bg := term_cell_colors(t, &cell)
			if term_selected(t, vi, col) {
				fg, bg = bg, fg
			}
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
	if t.active && t.alive && v == 0 {
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
	term_sb_free(t)
	delete(t.sb_ring)
	t.sb_ring = nil
}

term_free_vt :: proc(t: ^Terminal) {
	if t.vt != nil {
		vterm.free(t.vt)
		t.vt = nil
		t.screen = nil
	}
	term_sb_free(t)
	t.alive = false
}
