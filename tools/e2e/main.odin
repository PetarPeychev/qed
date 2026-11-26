package e2e

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "lib:pty"
import "lib:vterm"

SANDBOX_PREFIX :: "/tmp/qed-e2e-"
SANDBOX_MASK :: "XXXXXX"
SEND_STALL_MS :: 5000
GOLDEN_DIR :: "tools/e2e/golden"
SCENARIO_DIR :: "tools/e2e/scenarios"
KEY_QUIET_MS :: 80
TYPE_QUIET_MS :: 15
SNAP_QUIET_MS :: 150
SNAP_RETRY_MS :: 3000
SETTLE_MAX_MS :: 3000
STYLE_RUNES :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&*+,-./:;<=>?@^_~αβγδεζηθικλμνξοπρστυφχψωΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"

Mode :: enum {
	Verify,
	Update,
	Demo,
	Matrix,
}

Step :: struct {
	op:   string,
	args: []string,
	rest: string,
	body: string,
	line: int,
}

Scenario :: struct {
	name:     string,
	title:    string,
	w, h:     int,
	requires: [dynamic]string,
	steps:    [dynamic]Step,
}

Session :: struct {
	fd:             posix.FD,
	pid:            posix.pid_t,
	vt:             ^vterm.VTerm,
	screen:         ^vterm.Screen,
	state:          ^vterm.State,
	w, h:           int,
	cursor_visible: bool,
	exited:         bool,
	stalled:        bool,
	clock:          f64,
	record:         strings.Builder,
	utf8_tail:      [dynamic]u8,
	truecolor_seen: bool,
	tail:           [8]u8,
}

Run :: struct {
	mode:     Mode,
	qed:      string,
	term:     string,
	colorterm: bool,
	w, h:     int,
	out:      string,
	failures: [dynamic]string,
	snaps:    int,
	retried:  int,
	truecolor_without_colorterm: bool,
}

screen_callbacks: vterm.ScreenCallbacks
sandbox, sandbox_token, root_dir, home_dir, bin_dir: string

session_settermprop :: proc "c" (prop: c.int, val: ^vterm.Value, user: rawptr) -> c.int {
	s := (^Session)(user)
	if prop == 1 {
		s.cursor_visible = val.number != 0
	}
	return 1
}

tick_elapsed :: proc(t: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(t))
}

session_start :: proc(s: ^Session, qed: string, args: []string, env: []string, w, h: int) -> bool {
	argv := make([]cstring, len(args) + 2, context.temp_allocator)
	argv[0] = strings.clone_to_cstring(qed, context.temp_allocator)
	for a, i in args {
		argv[i + 1] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	envp := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env {
		envp[i] = strings.clone_to_cstring(e, context.temp_allocator)
	}
	pid: c.int
	fd := pty.qed_pty_spawn(c.int(h), c.int(w), raw_data(argv), raw_data(envp), strings.clone_to_cstring(root_dir, context.temp_allocator), &pid)
	if fd < 0 {
		return false
	}
	s.fd = posix.FD(fd)
	s.pid = posix.pid_t(pid)
	flags := posix.fcntl(s.fd, .GETFL)
	posix.fcntl(s.fd, .SETFL, flags | transmute(i32)posix.O_Flags{.NONBLOCK})
	s.w, s.h = w, h
	s.vt = vterm.new(c.int(h), c.int(w))
	vterm.set_utf8(s.vt, 1)
	s.state = vterm.obtain_state(s.vt)
	s.screen = vterm.obtain_screen(s.vt)
	screen_callbacks.settermprop = session_settermprop
	vterm.screen_set_callbacks(s.screen, &screen_callbacks, s)
	vterm.screen_enable_altscreen(s.screen, 1)
	vterm.screen_reset(s.screen, 1)
	s.cursor_visible = true
	s.record = strings.builder_make()
	fmt.sbprintf(&s.record, `{{"version": 2, "width": %d, "height": %d, "env": {{"TERM": "xterm-256color"}}}}`, w, h)
	strings.write_byte(&s.record, '\n')
	return true
}

session_stop :: proc(s: ^Session) {
	if !s.exited {
		posix.kill(-s.pid, .SIGKILL)
		posix.kill(s.pid, .SIGKILL)
	}
	status: c.int
	posix.waitpid(s.pid, &status, {})
	posix.close(s.fd)
	vterm.free(s.vt)
	strings.builder_destroy(&s.record)
	delete(s.utf8_tail)
}

session_cast_write :: proc(s: ^Session, data: []u8) {
	append(&s.utf8_tail, ..data)
	buf := s.utf8_tail[:]
	cut := len(buf)
	for i := len(buf) - 1; i >= 0 && i >= len(buf) - 4; i -= 1 {
		b := buf[i]
		if b < 0x80 {
			break
		}
		if b >= 0xC0 {
			need := 2 if b < 0xE0 else 3 if b < 0xF0 else 4
			if len(buf) - i < need {
				cut = i
			}
			break
		}
	}
	if cut == 0 {
		return
	}
	fmt.sbprintf(&s.record, "[%.3f, \"o\", \"", s.clock)
	json_escape_write(&s.record, string(buf[:cut]))
	strings.write_string(&s.record, "\"]\n")
	remove_range(&s.utf8_tail, 0, cut)
}

session_cast_event :: proc(s: ^Session, code, text: string) {
	if s.vt == nil {
		return
	}
	fmt.sbprintf(&s.record, "[%.3f, \"%s\", \"", s.clock, code)
	json_escape_write(&s.record, text)
	strings.write_string(&s.record, "\"]\n")
}

key_caption :: proc(token: string) -> string {
	name, _, count := strings.partition(token, "*")
	parts := strings.split(name, "+", context.temp_allocator)
	key := parts[len(parts) - 1]
	mods := parts[:len(parts) - 1]
	if key == "" && len(parts) > 1 {
		key = "+"
		mods = parts[:len(parts) - 2]
	}
	sb := strings.builder_make(context.temp_allocator)
	for m in mods {
		if m == "" {
			continue
		}
		fmt.sbprintf(&sb, "%s%s+", strings.to_upper(m[:1], context.temp_allocator), m[1:])
	}
	switch {
	case key == "pgup":
		strings.write_string(&sb, "PgUp")
	case key == "pgdn":
		strings.write_string(&sb, "PgDn")
	case len(key) > 1:
		fmt.sbprintf(&sb, "%s%s", strings.to_upper(key[:1], context.temp_allocator), key[1:])
	case:
		strings.write_string(&sb, key)
	}
	if count != "" {
		fmt.sbprintf(&sb, " ×%s", count)
	}
	return strings.to_string(sb)
}

json_escape_write :: proc(sb: ^strings.Builder, text: string) {
	for r in text {
		switch {
		case r == '"':
			strings.write_string(sb, `\"`)
		case r == '\\':
			strings.write_string(sb, `\\`)
		// '<' too, so a cast inlines into the demo page's <script> as is
		case r < 0x20 || r == 0x7f || r == '<':
			fmt.sbprintf(sb, `\u%04x`, int(r))
		case:
			strings.write_rune(sb, r)
		}
	}
}

session_flush_output :: proc(s: ^Session) {
	buf: [4096]u8
	for {
		n := vterm.output_read(s.vt, &buf[0], len(buf))
		if n == 0 {
			break
		}
		session_send(s, buf[:n])
	}
}

session_send :: proc(s: ^Session, data: []u8) {
	off := 0
	start := time.tick_now()
	for off < len(data) && !s.exited && !s.stalled {
		rest := data[off:]
		n := posix.write(s.fd, raw_data(rest), c.size_t(len(rest)))
		if n > 0 {
			off += n
			continue
		}
		errno := posix.errno()
		if errno == .EINTR {
			continue
		}
		if errno != .EAGAIN {
			return
		}
		if tick_elapsed(start) > SEND_STALL_MS {
			s.stalled = true
			return
		}
		session_pump(s, 5, 10)
	}
}

session_feed :: proc(s: ^Session, data: []u8) {
	for b in data {
		copy(s.tail[:], s.tail[1:])
		s.tail[7] = b
		if string(s.tail[2:]) == "\x1b[38;2" || string(s.tail[2:]) == "\x1b[48;2" {
			s.truecolor_seen = true
		}
	}
	session_cast_write(s, data)
	vterm.input_write(s.vt, raw_data(data), len(data))
	session_flush_output(s)
}

session_pump :: proc(s: ^Session, quiet_ms, max_ms: f64) -> bool {
	start := time.tick_now()
	last := start
	got := false
	buf: [65536]u8
	for !s.exited {
		wait := max(1, min(quiet_ms - tick_elapsed(last), max_ms - tick_elapsed(start)))
		pfd := posix.pollfd{fd = s.fd, events = {.IN}}
		posix.poll(&pfd, 1, c.int(wait))
		for {
			n := posix.read(s.fd, &buf[0], len(buf))
			if n > 0 {
				session_feed(s, buf[:n])
				got = true
				last = time.tick_now()
				continue
			}
			errno := posix.errno()
			if n == 0 || (errno != .EAGAIN && errno != .EINTR) {
				s.exited = true
			}
			break
		}
		if tick_elapsed(last) >= quiet_ms || tick_elapsed(start) >= max_ms {
			break
		}
	}
	return got
}

session_settle :: proc(s: ^Session, quiet: f64) {
	session_pump(s, quiet, SETTLE_MAX_MS)
}

session_text :: proc(s: ^Session, allocator := context.temp_allocator) -> []string {
	rows := make([]string, s.h, allocator)
	for y in 0 ..< s.h {
		sb := strings.builder_make(allocator)
		for x in 0 ..< s.w {
			cell: vterm.ScreenCell
			vterm.screen_get_cell(s.screen, {c.int(y), c.int(x)}, &cell)
			if cell.chars[0] == 0xFFFFFFFF {
				continue
			}
			if cell.chars[0] == 0 {
				strings.write_byte(&sb, ' ')
				continue
			}
			for ch in cell.chars {
				if ch == 0 {
					break
				}
				strings.write_rune(&sb, rune(ch))
			}
		}
		row, _ := strings.replace_all(strings.trim_right(strings.to_string(sb), " "), sandbox_token, SANDBOX_MASK, allocator)
		rows[y] = clock_mask(row)
	}
	return rows
}

// wall-clock times (the message log's HH:MM:SS) differ per run: goldens see a fixed mask
clock_mask :: proc(row: string) -> string {
	bytes := transmute([]u8)row
	digit :: proc(b: u8) -> bool {return b >= '0' && b <= '9'}
	for i := 0; i + 8 <= len(bytes); i += 1 {
		window := bytes[i:i + 8]
		if digit(window[0]) && digit(window[1]) && window[2] == ':' && digit(window[3]) && digit(window[4]) && window[5] == ':' && digit(window[6]) && digit(window[7]) {
			copy(window, "HH:MM:SS")
			i += 7
		}
	}
	return row
}

session_contains :: proc(s: ^Session, text: string) -> bool {
	for row in session_text(s) {
		if strings.contains(row, text) {
			return true
		}
	}
	return false
}

color_format :: proc(s: ^Session, col: vterm.Color, default_flag: u8) -> string {
	if col.type & default_flag != 0 {
		return "-"
	}
	cc := col
	vterm.screen_convert_color_to_rgb(s.screen, &cc)
	return fmt.tprintf("#%02x%02x%02x", cc.v0, cc.v1, cc.v2)
}

session_snapshot :: proc(s: ^Session) -> string {
	text := session_text(s)
	styles: [dynamic]string
	style_rows := make([]string, s.h, context.temp_allocator)
	for y in 0 ..< s.h {
		sb := strings.builder_make(context.temp_allocator)
		for x in 0 ..< s.w {
			cell: vterm.ScreenCell
			vterm.screen_get_cell(s.screen, {c.int(y), c.int(x)}, &cell)
			if cell.chars[0] == 0xFFFFFFFF {
				continue
			}
			ds := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&ds, "fg=%s bg=%s", color_format(s, cell.fg, vterm.COLOR_DEFAULT_FG), color_format(s, cell.bg, vterm.COLOR_DEFAULT_BG))
			if cell.attrs & vterm.ATTR_BOLD != 0 {strings.write_string(&ds, " bold")}
			if cell.attrs & vterm.ATTR_UNDERLINE != 0 {strings.write_string(&ds, " underline")}
			if cell.attrs & vterm.ATTR_ITALIC != 0 {strings.write_string(&ds, " italic")}
			if cell.attrs & vterm.ATTR_REVERSE != 0 {strings.write_string(&ds, " reverse")}
			if cell.attrs & (1 << 7) != 0 {strings.write_string(&ds, " strike")}
			desc := strings.to_string(ds)
			idx, found := slice.linear_search(styles[:], desc)
			if !found {
				idx = len(styles)
				append(&styles, desc)
			}
			strings.write_rune(&sb, style_encode(idx))
		}
		style_rows[y] = strings.to_string(sb)
	}
	sb := strings.builder_make(context.temp_allocator)
	pos: vterm.Pos
	vterm.state_get_cursorpos(s.state, &pos)
	if s.cursor_visible {
		fmt.sbprintf(&sb, "qed-e2e snapshot %dx%d cursor %d,%d\n", s.w, s.h, pos.col, pos.row)
	} else {
		fmt.sbprintf(&sb, "qed-e2e snapshot %dx%d cursor hidden\n", s.w, s.h)
	}
	strings.write_string(&sb, "-- text\n")
	for row in text {
		fmt.sbprintf(&sb, "%s\n", row)
	}
	strings.write_string(&sb, "-- style\n")
	for row in style_rows {
		fmt.sbprintf(&sb, "%s\n", row)
	}
	strings.write_string(&sb, "-- legend\n")
	for st, i in styles {
		fmt.sbprintf(&sb, "%c %s\n", style_encode(i), st)
	}
	delete(styles)
	return strings.to_string(sb)
}

style_encode :: proc(i: int) -> rune {
	n := 0
	for r in STYLE_RUNES {
		if n == i {
			return r
		}
		n += 1
	}
	return '?'
}

SnapFile :: struct {
	header: string,
	text:   []string,
	style:  [][]rune,
	legend: map[rune]string,
}

snap_parse :: proc(data: string) -> (f: SnapFile, ok: bool) {
	lines := strings.split_lines(data, context.temp_allocator)
	if len(lines) < 2 {
		return
	}
	f.header = lines[0]
	fields := strings.fields(lines[0], context.temp_allocator)
	if len(fields) < 3 {
		return
	}
	dims := strings.split(fields[2], "x", context.temp_allocator)
	h := int_parse(dims[1]) if len(dims) == 2 else 0
	if len(lines) < 3 + 2 * h {
		return
	}
	f.text = lines[2:2 + h]
	f.style = make([][]rune, h, context.temp_allocator)
	for i in 0 ..< h {
		f.style[i] = utf8.string_to_runes(lines[3 + h + i], context.temp_allocator)
	}
	f.legend = make(map[rune]string, context.temp_allocator)
	for l in lines[4 + 2 * h:] {
		if l == "" {
			continue
		}
		r, size := utf8.decode_rune_in_string(l)
		f.legend[r] = l[size + 1:] if len(l) > size else ""
	}
	return f, true
}

snap_diff :: proc(golden, actual: string) -> string {
	g, gok := snap_parse(golden)
	a, aok := snap_parse(actual)
	sb := strings.builder_make(context.temp_allocator)
	if !gok || !aok || len(g.text) != len(a.text) {
		fmt.sbprintf(&sb, "    golden: %s\n    actual: %s\n", g.header, a.header)
		return strings.to_string(sb)
	}
	if g.header != a.header {
		fmt.sbprintf(&sb, "    header\n      - %s\n      + %s\n", g.header, a.header)
	}
	lines := 0
	pending, pending_from, pending_to := "", 0, 0
	for y in 0 ..= len(g.text) {
		row := ""
		if y < len(g.text) && g.text[y] == a.text[y] {
			rb := strings.builder_make(context.temp_allocator)
			gs, as := g.style[y], a.style[y]
			x := 0
			for x < max(len(gs), len(as)) {
				gd := g.legend[gs[x]] if x < len(gs) else "?"
				ad := a.legend[as[x]] if x < len(as) else "?"
				end := x + 1
				for end < max(len(gs), len(as)) {
					gd2 := g.legend[gs[end]] if end < len(gs) else "?"
					ad2 := a.legend[as[end]] if end < len(as) else "?"
					if gd2 != gd || ad2 != ad {
						break
					}
					end += 1
				}
				if gd != ad {
					fmt.sbprintf(&rb, " cols %d-%d style: %s -> %s;", x, end - 1, gd, ad)
				}
				x = end
			}
			row = strings.to_string(rb)
		}
		if row == pending && row != "" {
			pending_to = y
			continue
		}
		if pending != "" && lines <= 40 {
			if pending_from == pending_to {
				fmt.sbprintf(&sb, "    row %d%s\n", pending_from, pending)
			} else {
				fmt.sbprintf(&sb, "    rows %d-%d%s\n", pending_from, pending_to, pending)
			}
			lines += 1
		}
		pending, pending_from, pending_to = row, y, y
		if y < len(g.text) && g.text[y] != a.text[y] && lines <= 40 {
			fmt.sbprintf(&sb, "    row %d text\n      - |%s|\n      + |%s|\n", y, g.text[y], a.text[y])
			lines += 3
		}
	}
	if lines > 40 {
		strings.write_string(&sb, "    ...\n")
	}
	return strings.to_string(sb)
}

snap_show :: proc(data: string) {
	f, ok := snap_parse(data)
	if !ok {
		fmt.eprintln("qed-e2e: not a snapshot")
		return
	}
	for row, y in f.text {
		runes := utf8.string_to_runes(row, context.temp_allocator)
		prev: rune = 0
		for st, x in f.style[y] {
			ch := runes[x] if x < len(runes) else ' '
			if st == prev {
				fmt.printf("%c", ch)
				continue
			}
			prev = st
			desc := f.legend[st]
			sgr := strings.builder_make(context.temp_allocator)
			strings.write_string(&sgr, "\x1b[0")
			for part in strings.fields(desc, context.temp_allocator) {
				switch {
				case strings.has_prefix(part, "fg=#"), strings.has_prefix(part, "bg=#"):
					v, _ := strconv.parse_int(part[4:], 16)
					fmt.sbprintf(&sgr, ";%d;2;%d;%d;%d", 38 if part[0] == 'f' else 48, (v >> 16) & 255, (v >> 8) & 255, v & 255)
				case part == "bold":
					strings.write_string(&sgr, ";1")
				case part == "italic":
					strings.write_string(&sgr, ";3")
				case part == "underline":
					strings.write_string(&sgr, ";4")
				case part == "reverse":
					strings.write_string(&sgr, ";7")
				}
			}
			fmt.printf("%sm%c", strings.to_string(sgr), ch)
		}
		fmt.print("\x1b[0m\n")
	}
}

scenario_parse :: proc(path: string) -> (sc: Scenario, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("qed-e2e: cannot read %s", path)
		return
	}
	sc.name = strings.trim_suffix(filepath.base(path), ".e2e")
	lines := strings.split_lines(string(data))
	header := true
	for i := 0; i < len(lines); i += 1 {
		line := strings.trim_right(lines[i], " \t\r")
		header = header && strings.has_prefix(line, "#")
		if header {
			sc.title = strings.trim_space(fmt.aprintf("%s %s", sc.title, strings.trim_space(line[1:])))
		}
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		op, _, rest := strings.partition(line, " ")
		step := Step{op = op, rest = rest, args = strings.fields(rest), line = i + 1}
		switch op {
		case "size":
			sc.w, sc.h = size_parse(rest)
			continue
		case "requires":
			append(&sc.requires, ..step.args)
			continue
		case "file", "home-file", "config", "expect-file":
			sb := strings.builder_make()
			i += 1
			for i < len(lines) && strings.trim_right(lines[i], "\r") != "end" {
				fmt.sbprintf(&sb, "%s\n", lines[i])
				i += 1
			}
			step.body = strings.to_string(sb)
		}
		append(&sc.steps, step)
	}
	return sc, true
}

int_parse :: proc(s: string) -> int {
	n, _ := strconv.parse_int(s)
	return n
}

size_parse :: proc(s: string) -> (w, h: int) {
	a, _, b := strings.partition(s, "x")
	return int_parse(a), int_parse(b)
}

session_key :: proc(s: ^Session, name: string) -> bool {
	parts := strings.split(name, "+", context.temp_allocator)
	key := parts[len(parts) - 1]
	if key == "" && len(parts) > 1 {
		key = "+"
	}
	mod := vterm.MOD_NONE
	for p in parts[:len(parts) - 1] {
		switch p {
		case "ctrl":
			mod |= vterm.MOD_CTRL
		case "alt":
			mod |= vterm.MOD_ALT
		case "shift":
			mod |= vterm.MOD_SHIFT
		case "":
		case:
			return false
		}
	}
	named := vterm.Key.None
	switch key {
	case "enter":
		named = .Enter
	case "tab":
		named = .Tab
	case "backspace":
		named = .Backspace
	case "esc":
		named = .Escape
	case "up":
		named = .Up
	case "down":
		named = .Down
	case "left":
		named = .Left
	case "right":
		named = .Right
	case "insert":
		named = .Ins
	case "delete":
		named = .Del
	case "home":
		named = .Home
	case "end":
		named = .End
	case "pgup":
		named = .PageUp
	case "pgdn":
		named = .PageDown
	}
	// libvterm's VTERM_KEY_FUNCTION(n) is 256 + n
	if len(key) >= 2 && key[0] == 'f' {
		if n, ok := strconv.parse_int(key[1:]); ok && n >= 1 && n <= 12 {
			named = vterm.Key(256 + n)
		}
	}
	if named != .None {
		vterm.keyboard_key(s.vt, named, mod)
		session_flush_output(s)
		return true
	}
	if key == "space" {
		key = " "
	}
	r, size := utf8.decode_rune_in_string(key)
	if size != len(key) {
		return false
	}
	out: [8]u8
	n := 0
	if mod & vterm.MOD_ALT != 0 {
		out[n] = 0x1b
		n += 1
	}
	if mod & vterm.MOD_CTRL != 0 {
		switch {
		case r >= 'a' && r <= 'z', r >= '@' && r <= '_':
			out[n] = u8(r) & 0x1f
		case r == '/':
			out[n] = 0x1f
		case r == ' ':
			out[n] = 0
		case:
			return false
		}
		n += 1
	} else {
		enc, w := utf8.encode_rune(r)
		copy(out[n:], enc[:w])
		n += w
	}
	session_send(s, out[:n])
	return true
}

mouse_click :: proc(s: ^Session, x, y: int) {
	vterm.mouse_move(s.vt, c.int(y), c.int(x), vterm.MOD_NONE)
	vterm.mouse_button(s.vt, 1, true, vterm.MOD_NONE)
	session_flush_output(s)
	vterm.mouse_button(s.vt, 1, false, vterm.MOD_NONE)
	session_flush_output(s)
}

env_build :: proc(run: ^Run) -> []string {
	env := make([dynamic]string, context.temp_allocator)
	append(&env,
		fmt.tprintf("PATH=%s:/usr/local/bin:/usr/bin:/bin", bin_dir),
		fmt.tprintf("HOME=%s", home_dir),
		fmt.tprintf("XDG_CONFIG_HOME=%s/.config", home_dir),
		fmt.tprintf("XDG_STATE_HOME=%s/.local/state", home_dir),
		fmt.tprintf("XDG_DATA_HOME=%s/.local/share", home_dir),
		fmt.tprintf("XDG_CACHE_HOME=%s/.cache", home_dir),
		"PS1=qed$ ",
		"USER=qed",
		"SHELL=/bin/sh",
		"LANG=C.UTF-8",
		"LC_ALL=C.UTF-8",
		"TZ=UTC",
		"GIT_CONFIG_NOSYSTEM=1",
		fmt.tprintf("GIT_CONFIG_GLOBAL=%s/.gitconfig", home_dir),
		fmt.tprintf("GIT_CEILING_DIRECTORIES=%s", sandbox),
		"GIT_AUTHOR_DATE=2026-01-01T00:00:00Z",
		"GIT_COMMITTER_DATE=2026-01-01T00:00:00Z",
		fmt.tprintf("TERM=%s", run.term),
	)
	if run.colorterm {
		append(&env, "COLORTERM=truecolor")
	}
	return env[:]
}

sandbox_reset :: proc() -> bool {
	clipboard := fmt.tprintf("%s/clipboard", sandbox)
	os.remove(clipboard)
	os.remove_all(root_dir)
	os.remove_all(home_dir)
	os.remove_all(bin_dir)
	for d in ([]string{root_dir, fmt.tprintf("%s/.config/qed", home_dir), fmt.tprintf("%s/.local/state", home_dir), bin_dir}) {
		if os.make_directory_all(d) != nil {
			return false
		}
	}
	exec := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	_ = os.write_entire_file(fmt.tprintf("%s/.config/qed/config.json", home_dir), "{\"lsp\": {\"enabled\": false}}\n")
	_ = os.write_entire_file(fmt.tprintf("%s/.gitconfig", home_dir), "[user]\n\tname = qed\n\temail = qed@example.invalid\n[init]\n\tdefaultBranch = main\n")
	_ = os.write_entire_file(fmt.tprintf("%s/wl-copy", bin_dir), fmt.tprintf("#!/bin/sh\ncat > %s\n", clipboard), exec)
	_ = os.write_entire_file(fmt.tprintf("%s/wl-paste", bin_dir), fmt.tprintf("#!/bin/sh\ncat %s 2>/dev/null\n", clipboard), exec)
	return true
}

tool_exists :: proc(name: string) -> bool {
	for d in ([]string{bin_dir, "/usr/local/bin", "/usr/bin", "/bin"}) {
		if os.exists(fmt.tprintf("%s/%s", d, name)) {
			return true
		}
	}
	return false
}

scenario_fail :: proc(run: ^Run, sc: ^Scenario, step: Step, s: ^Session, msg: string) {
	append(&run.failures, fmt.aprintf("%s:%d (%s %dx%d): %s", sc.name, step.line, run.term, run.w, run.h, msg))
	fmt.printfln("  FAIL %s:%d %s", sc.name, step.line, msg)
	if s.vt != nil {
		dir := fmt.tprintf("%s/%s", run.out, sc.name)
		os.make_directory_all(dir)
		path := fmt.tprintf("%s/FAIL-line%d.txt", dir, step.line)
		_ = os.write_entire_file(path, session_snapshot(s))
		fmt.printfln("    screen: %s", path)
	}
	crash, err := os.read_entire_file(fmt.tprintf("%s/.local/state/qed/crash.log", home_dir), context.temp_allocator)
	if err == nil && len(crash) > 0 {
		fmt.printfln("    crash.log:\n%s", string(crash))
	}
}

scenario_run :: proc(run: ^Run, sc: ^Scenario) -> bool {
	for r in sc.requires {
		if !tool_exists(r) {
			fmt.printfln("  skip %s (needs %s)", sc.name, r)
			return true
		}
	}
	if !sandbox_reset() {
		fmt.eprintfln("qed-e2e: cannot create sandbox under %s", sandbox)
		return false
	}
	failed_before := len(run.failures)
	s: Session
	defer if s.vt != nil {session_stop(&s)}
	timeout := 5000.0
	for step in sc.steps {
		if s.vt != nil && (s.exited || s.stalled) && step.op != "expect-file" && step.op != "expect-exit" {
			scenario_fail(run, sc, step, &s, "qed exited unexpectedly" if s.exited else "qed stopped reading input")
			return false
		}
		switch step.op {
		case "file":
			path := fmt.tprintf("%s/%s", root_dir, step.rest)
			os.make_directory_all(filepath.dir(path))
			_ = os.write_entire_file(path, step.body)
			session_cast_event(&s, "i", fmt.tprintf("edit %s", step.rest))
		case "config":
			_ = os.write_entire_file(fmt.tprintf("%s/.config/qed/config.json", home_dir), step.body)
			session_cast_event(&s, "i", "edit config.json")
		case "home-file":
			// a file under the sandbox HOME (a user plugin, say); never the real home
			path := fmt.tprintf("%s/%s", home_dir, step.rest)
			os.make_directory_all(filepath.dir(path))
			_ = os.write_entire_file(path, step.body)
			session_cast_event(&s, "i", fmt.tprintf("edit ~/%s", step.rest))
		case "wheel":
			if len(step.args) < 3 {
				scenario_fail(run, sc, step, &s, "wheel needs X Y up|down [count]")
				return false
			}
			x, y := int_parse(step.args[0]), int_parse(step.args[1])
			button := c.int(4 if step.args[2] == "up" else 5)
			count := max(1, int_parse(step.args[3]) if len(step.args) > 3 else 1)
			vterm.mouse_move(s.vt, c.int(y), c.int(x), vterm.MOD_NONE)
			for i in 0 ..< count {
				s.clock += 0.1
				if i == 0 {
					session_cast_event(&s, "i", fmt.tprintf("wheel %s ×%d at %d,%d", step.args[2], count, x, y) if count > 1 else fmt.tprintf("wheel %s at %d,%d", step.args[2], x, y))
				}
				vterm.mouse_button(s.vt, button, true, vterm.MOD_NONE)
				session_flush_output(&s)
				session_pump(&s, 10, 100)
			}
			session_settle(&s, KEY_QUIET_MS)
		case "expect-exit":
			start := time.tick_now()
			for !s.exited {
				if tick_elapsed(start) > timeout {
					scenario_fail(run, sc, step, &s, "timed out: expect-exit")
					return false
				}
				session_pump(&s, 20, 50)
			}
		case "timeout":
			timeout = f64(int_parse(step.rest))
		case "run":
			if s.vt != nil {
				session_stop(&s)
				s = {}
			}
			if !session_start(&s, run.qed, step.args, env_build(run), run.w, run.h) {
				scenario_fail(run, sc, step, &s, "spawn failed")
				return false
			}
			session_settle(&s, SNAP_QUIET_MS)
		case "wait":
			start := time.tick_now()
			for !session_contains(&s, step.rest) {
				if tick_elapsed(start) > timeout || s.exited {
					scenario_fail(run, sc, step, &s, fmt.tprintf("timed out: wait %q", step.rest))
					return false
				}
				session_pump(&s, 20, 50)
			}
			session_settle(&s, KEY_QUIET_MS)
		case "wait-gone":
			start := time.tick_now()
			for session_contains(&s, step.rest) {
				if tick_elapsed(start) > timeout || s.exited {
					scenario_fail(run, sc, step, &s, fmt.tprintf("timed out: wait-gone %q", step.rest))
					return false
				}
				session_pump(&s, 20, 50)
			}
			session_settle(&s, KEY_QUIET_MS)
		case "key":
			for tok in step.args {
				name, _, count := strings.partition(tok, "*")
				n := max(1, int_parse(count))
				for i in 0 ..< n {
					s.clock += 0.35
					if i == 0 {
						session_cast_event(&s, "i", key_caption(tok))
					}
					if !session_key(&s, name) {
						scenario_fail(run, sc, step, &s, fmt.tprintf("bad key: %s", tok))
						return false
					}
					session_settle(&s, KEY_QUIET_MS)
				}
			}
		case "type":
			for r, i in step.rest {
				s.clock += 0.07
				if i == 0 {
					session_cast_event(&s, "i", fmt.tprintf("type `%s`", step.rest))
				}
				enc, w := utf8.encode_rune(r)
				session_send(&s, enc[:w])
				session_pump(&s, TYPE_QUIET_MS, 500)
			}
			session_settle(&s, KEY_QUIET_MS)
		case "click", "dclick":
			if len(step.args) < 2 {
				scenario_fail(run, sc, step, &s, "click needs X Y")
				return false
			}
			x, y := int_parse(step.args[0]), int_parse(step.args[1])
			s.clock += 0.4
			session_cast_event(&s, "i", fmt.tprintf("%s %d,%d", "double-click" if step.op == "dclick" else "click", x, y))
			mouse_click(&s, x, y)
			if step.op == "dclick" {
				session_pump(&s, 10, 100)
				mouse_click(&s, x, y)
			}
			session_settle(&s, KEY_QUIET_MS)
		case "drag":
			if len(step.args) < 4 {
				scenario_fail(run, sc, step, &s, "drag needs X1 Y1 X2 Y2")
				return false
			}
			x1, y1 := int_parse(step.args[0]), int_parse(step.args[1])
			x2, y2 := int_parse(step.args[2]), int_parse(step.args[3])
			s.clock += 0.3
			session_cast_event(&s, "i", fmt.tprintf("drag %d,%d to %d,%d", x1, y1, x2, y2))
			vterm.mouse_move(s.vt, c.int(y1), c.int(x1), vterm.MOD_NONE)
			vterm.mouse_button(s.vt, 1, true, vterm.MOD_NONE)
			session_flush_output(&s)
			session_pump(&s, 10, 200)
			steps := max(abs(x2 - x1), abs(y2 - y1), 1)
			for i in 1 ..= steps {
				s.clock += 0.03
				vterm.mouse_move(s.vt, c.int(y1 + (y2 - y1) * i / steps), c.int(x1 + (x2 - x1) * i / steps), vterm.MOD_NONE)
				session_flush_output(&s)
				session_pump(&s, 5, 200)
			}
			vterm.mouse_button(s.vt, 1, false, vterm.MOD_NONE)
			session_flush_output(&s)
			session_settle(&s, KEY_QUIET_MS)
		case "expect-file":
			path := fmt.tprintf("%s/%s", root_dir, step.rest)
			session_settle(&s, KEY_QUIET_MS)
			data, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil || string(data) != step.body {
				scenario_fail(run, sc, step, &s, fmt.tprintf("%s: want %q, got %q", step.rest, step.body, string(data)))
				return false
			}
		case "snap":
			if !snap_step(run, sc, step, &s) {
				return false
			}
		case:
			scenario_fail(run, sc, step, &s, fmt.tprintf("unknown op: %s", step.op))
			return false
		}
		free_all(context.temp_allocator)
	}
	if run.mode == .Demo && s.vt != nil {
		// the player drops a marker at the recording's very end; this empty event keeps the last snap's marker
		fmt.sbprintf(&s.record, "[%.3f, \"o\", \"\"]\n", s.clock)
		path := fmt.tprintf("%s/%s.cast", run.out, sc.name)
		_ = os.write_entire_file(path, strings.to_string(s.record))
		fmt.printfln("  cast %s", path)
	}
	if s.vt != nil && s.truecolor_seen && !run.colorterm {
		run.truecolor_without_colorterm = true
	}
	return len(run.failures) == failed_before
}

snap_step :: proc(run: ^Run, sc: ^Scenario, step: Step, s: ^Session) -> bool {
	run.snaps += 1
	name := step.args[0] if len(step.args) > 0 else ""
	session_settle(s, SNAP_QUIET_MS)
	golden_path := fmt.tprintf("%s/%s/%s.txt", GOLDEN_DIR, sc.name, name)
	actual := session_snapshot(s)
	out_dir := fmt.tprintf("%s/%s", run.out, sc.name)
	switch run.mode {
	case .Update:
		start := time.tick_now()
		for {
			session_pump(s, SNAP_QUIET_MS, SNAP_QUIET_MS * 2)
			next := session_snapshot(s)
			if next == actual {
				break
			}
			actual = next
			if tick_elapsed(start) > SNAP_RETRY_MS || s.exited {
				scenario_fail(run, sc, step, s, fmt.tprintf("snap %s never stable", name))
				return false
			}
		}
		os.make_directory_all(filepath.dir(golden_path))
		_ = os.write_entire_file(golden_path, actual)
	case .Verify:
		data, err := os.read_entire_file(golden_path, context.temp_allocator)
		if err != nil {
			scenario_fail(run, sc, step, s, fmt.tprintf("no golden %s (run update)", golden_path))
			return false
		}
		golden := string(data)
		if actual != golden {
			run.retried += 1
		}
		start := time.tick_now()
		for actual != golden && tick_elapsed(start) < SNAP_RETRY_MS && !s.exited {
			session_pump(s, 30, 60)
			actual = session_snapshot(s)
		}
		if actual != golden {
			os.make_directory_all(out_dir)
			path := fmt.tprintf("%s/%s.txt", out_dir, name)
			_ = os.write_entire_file(path, actual)
			append(&run.failures, fmt.aprintf("%s snap %s differs", sc.name, name))
			fmt.printfln("  FAIL %s snap %s (diff -u %s %s)\n%s", sc.name, name, golden_path, path, snap_diff(golden, actual))
			return true
		}
	case .Demo:
		sentence := strings.trim_space(strings.trim_prefix(strings.trim_space(step.rest), name))
		session_cast_event(s, "m", fmt.tprintf("%s: %s", name, sentence) if sentence != "" else name)
		s.clock += 1.5
		os.make_directory_all(out_dir)
		_ = os.write_entire_file(fmt.tprintf("%s/%s.txt", out_dir, name), actual)
	case .Matrix:
		os.make_directory_all(out_dir)
		_ = os.write_entire_file(fmt.tprintf("%s/%s.txt", out_dir, name), actual)
	}
	return true
}

scenarios_load :: proc(names: []string) -> [dynamic]Scenario {
	list: [dynamic]Scenario
	paths: [dynamic]string
	if len(names) == 0 {
		files, _ := os.read_directory_by_path(SCENARIO_DIR, -1, context.allocator)
		for f in files {
			if strings.has_suffix(f.name, ".e2e") {
				append(&paths, fmt.aprintf("%s/%s", SCENARIO_DIR, f.name))
			}
		}
		slice.sort(paths[:])
	} else {
		for n in names {
			append(&paths, n if strings.has_suffix(n, ".e2e") else fmt.aprintf("%s/%s.e2e", SCENARIO_DIR, n))
		}
	}
	for p in paths {
		if sc, ok := scenario_parse(p); ok {
			append(&list, sc)
		}
	}
	return list
}

usage :: proc() {
	fmt.eprintln(`usage: qed-e2e verify|update|demo|matrix|show [flags] [scenario...]
  verify            run scenarios, compare snaps to tools/e2e/golden (exit 1 on any diff)
  update            run scenarios, rewrite goldens
  demo --out DIR    (--size COLSxROWS, default 160x45) run scenarios, write DIR/<name>.cast and .html
  matrix            run every scenario per --sizes x --terms, compare TERM variants
  show FILE         print a snapshot file in color
flags: --qed PATH (./qed)  --term T (xterm-256color)  --no-colorterm
       --sizes 40x12,80x24,...  --terms xterm-256color,screen,...  (TERM:256 drops COLORTERM)`)
	os.exit(2)
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
	}
	run := Run{qed = "./qed", term = "xterm-256color", colorterm = true}
	demo_size := "160x45"
	sizes := "40x12,80x24,120x40,200x60"
	terms := "xterm-256color,tmux-256color,screen,linux,xterm-256color:256"
	names: [dynamic]string
	switch args[0] {
	case "verify":
		run.mode = .Verify
	case "update":
		run.mode = .Update
	case "demo":
		run.mode = .Demo
	case "matrix":
		run.mode = .Matrix
	case "show":
		if len(args) < 2 {
			usage()
		}
		data, err := os.read_entire_file(args[1], context.allocator)
		if err != nil {
			fmt.eprintfln("qed-e2e: cannot read %s", args[1])
			os.exit(1)
		}
		snap_show(string(data))
		return
	case:
		usage()
	}
	for i := 1; i < len(args); i += 1 {
		switch args[i] {
		case "--qed", "--term", "--out", "--sizes", "--terms", "--size":
			if i + 1 >= len(args) {
				usage()
			}
			v := args[i + 1]
			switch args[i] {
			case "--qed":
				run.qed = v
			case "--term":
				run.term = v
			case "--out":
				run.out = v
			case "--size":
				demo_size = v
			case "--sizes":
				sizes = v
			case "--terms":
				terms = v
			}
			i += 1
		case "--no-colorterm":
			run.colorterm = false
		case:
			append(&names, args[i])
		}
	}
	if run.mode == .Demo && run.out == "" {
		run.out = "tools/e2e/demo"
	}
	qed_path, _ := filepath.abs(run.qed, context.allocator)
	run.qed = qed_path
	if !os.exists(run.qed) {
		fmt.eprintfln("qed-e2e: %s not built (run ./build.sh)", run.qed)
		os.exit(1)
	}
	template := strings.clone_to_cstring(SANDBOX_PREFIX + SANDBOX_MASK, context.allocator)
	if posix.mkdtemp(([^]u8)(template)) == nil {
		fmt.eprintln("qed-e2e: cannot create a sandbox under /tmp")
		os.exit(1)
	}
	sandbox = string(template)
	sandbox_token = sandbox[len(SANDBOX_PREFIX):]
	root_dir = fmt.aprintf("%s/root", sandbox)
	home_dir = fmt.aprintf("%s/home", sandbox)
	bin_dir = fmt.aprintf("%s/bin", sandbox)
	if run.out == "" {
		run.out = fmt.aprintf("%s/out", sandbox)
	}
	os.make_directory_all(run.out)
	list := scenarios_load(names[:])
	start := time.tick_now()
	if run.mode == .Matrix {
		matrix_run(&run, list[:], strings.split(sizes, ","), strings.split(terms, ","))
	} else {
		for &sc in list {
			run.w, run.h = sc.w, sc.h
			if sc.w == 0 {
				run.w, run.h = 80, 24
				if run.mode == .Demo {
					run.w, run.h = size_parse(demo_size)
				}
			}
			fmt.printfln("%s", sc.name)
			scenario_run(&run, &sc)
			if run.mode == .Demo {
				demo_render(&run, &sc)
			}
		}
		if run.mode == .Demo {
			_ = os.write_entire_file(fmt.tprintf("%s/player.js", run.out), PLAYER_JS)
			_ = os.write_entire_file(fmt.tprintf("%s/player.css", run.out), PLAYER_CSS)
			_ = os.write_entire_file(fmt.tprintf("%s/player.LICENSE", run.out), PLAYER_LICENSE)
			all := scenarios_load(nil)
			demo_index(&run, all[:])
		}
	}
	fmt.printfln("%d scenarios, %d snaps (%d settled late), %d failures, %.1fs", len(list), run.snaps, run.retried, len(run.failures), tick_elapsed(start) / 1000)
	if run.truecolor_without_colorterm {
		fmt.println("note: qed emitted truecolor SGR with COLORTERM unset")
	}
	keep := len(run.failures) > 0 || strings.has_prefix(run.out, sandbox)
	if keep && (run.mode == .Matrix || run.mode == .Demo || len(run.failures) > 0) {
		fmt.printfln("output kept in %s", run.out)
	} else {
		os.remove_all(sandbox)
	}
	if len(run.failures) > 0 {
		for f in run.failures {
			fmt.printfln("  %s", f)
		}
		os.exit(1)
	}
}

PLAYER_JS :: #load("../../lib/asciinema-player/asciinema-player.min.js", string)
PLAYER_CSS :: #load("../../lib/asciinema-player/asciinema-player.css", string)
PLAYER_LICENSE :: #load("../../lib/asciinema-player/LICENSE", string)

DEMO_PAGE_STYLE :: `
:root { color-scheme: dark; }
html, body { margin: 0; height: 100%; background: #16181d; color: #c8ccd4; font: 14px system-ui, sans-serif; }
body { display: flex; flex-direction: column; }
header { padding: 10px 16px; display: flex; flex-wrap: wrap; gap: 6px 18px; align-items: baseline; }
h1 { font-size: 17px; margin: 0; font-family: monospace; }
a { color: #61afef; }
#desc, .desc { color: #9aa0aa; }
#step { font-family: monospace; color: #e5c07b; }
#keys { margin-left: auto; color: #8a909a; }
kbd { font-family: monospace; border: 1px solid #4a505a; border-radius: 3px; padding: 0 4px; color: #c8ccd4; }
select { background: #22252c; color: #c8ccd4; border: 1px solid #4a505a; }
#player { flex: 1; min-height: 0; padding: 0 16px; }
#caption { min-height: 3.2em; padding: 8px 16px 12px; display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: center; font-size: 16px; }
#caption kbd { font-size: 15px; padding: 1px 6px; background: #22252c; }
#sentence { flex-basis: 100%; color: #e5e9f0; }
ul { list-style: none; margin: 0; padding: 0 16px; }
li { padding: 4px 0; }
li a { font-family: monospace; font-size: 15px; margin-right: 12px; }
`

DEMO_PAGE_SCRIPT :: `
const cast = document.getElementById("cast").textContent.trim();
const events = cast.split("\n").slice(1).map(line => JSON.parse(line));
const markers = events.filter(event => event[1] === "m").map(event => {
	const [name, ...sentence] = event[2].split(": ");
	return {time: event[0], name: name, sentence: sentence.join(": ")};
});
const inputs = events.filter(event => event[1] === "i");
const container = document.getElementById("player");
const step = document.getElementById("step");
const caption = document.getElementById("caption");
const speedSelect = document.getElementById("speed");
const pauseBox = document.getElementById("pause");
let player = null;
let isPlaying = false;
let shown = "";
function showStep() {
	const now = player.getCurrentTime() || 0;
	let index = markers.findIndex(marker => marker.time >= now - 0.001);
	if (index < 0) index = markers.length - 1;
	const marker = markers[index];
	const from = index > 0 ? markers[index - 1].time : -1;
	const keys = inputs.filter(input => input[0] > from && input[0] <= now + 0.001).map(input => input[2]);
	const state = JSON.stringify([index, keys]);
	if (state === shown) return;
	shown = state;
	step.textContent = marker ? "step " + (index + 1) + "/" + markers.length + ": " + marker.name : "";
	caption.replaceChildren();
	for (const key of keys) {
		const chip = document.createElement("kbd");
		chip.textContent = key;
		caption.append(chip);
	}
	if (marker && marker.sentence) {
		const sentence = document.createElement("span");
		sentence.id = "sentence";
		sentence.textContent = marker.sentence;
		caption.append(sentence);
	}
}
function mount(time, playing) {
	if (player) player.dispose();
	player = AsciinemaPlayer.create({data: cast}, container, {
		controls: true,
		pauseOnMarkers: pauseBox.checked,
		speed: Number(speedSelect.value),
		fit: "both",
		preload: true,
		terminalFontFamily: "'Cascadia Mono', 'Cascadia Code', Consolas, 'DejaVu Sans Mono', 'Noto Sans Mono', monospace",
	});
	player.addEventListener("playing", () => { isPlaying = true; });
	player.addEventListener("pause", () => { isPlaying = false; });
	player.addEventListener("ended", () => { isPlaying = false; });
	player.seek(time).then(() => { if (playing) player.play(); });
	player.el.focus();
}
speedSelect.addEventListener("change", () => mount(player.getCurrentTime(), isPlaying));
pauseBox.addEventListener("change", () => mount(player.getCurrentTime(), isPlaying));
mount(0, false);
setInterval(showStep, 100);
`

html_escape :: proc(text: string) -> string {
	amp, _ := strings.replace_all(text, "&", "&amp;", context.temp_allocator)
	lt, _ := strings.replace_all(amp, "<", "&lt;", context.temp_allocator)
	return lt
}

demo_page_head :: proc(sb: ^strings.Builder, title, head: string) {
	fmt.sbprintf(sb, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>%s</title>\n", html_escape(title))
	fmt.sbprintf(sb, "%s<style>%s</style>\n</head><body>\n", head, DEMO_PAGE_STYLE)
}

demo_render :: proc(run: ^Run, sc: ^Scenario) {
	cast_path := fmt.tprintf("%s/%s.cast", run.out, sc.name)
	recording, err := os.read_entire_file(cast_path, context.temp_allocator)
	if err != nil {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	demo_page_head(&sb, sc.name, "<link rel=\"stylesheet\" href=\"player.css\">\n")
	fmt.sbprintf(&sb, "<header><h1><a href=\"index.html\">e2e</a> / %s</h1><span id=\"desc\">%s</span><span id=\"step\"></span>\n", html_escape(sc.name), html_escape(sc.title))
	strings.write_string(&sb, `<span id="keys"><kbd>Space</kbd> play/pause &nbsp; <kbd>[</kbd> <kbd>]</kbd> prev/next step &nbsp; <kbd>,</kbd> <kbd>.</kbd> frame back/forward &nbsp; <kbd>?</kbd> all keys &nbsp; `)
	strings.write_string(&sb, `<label><input type="checkbox" id="pause"> pause at each step</label> &nbsp; `)
	strings.write_string(&sb, `<label>speed <select id="speed"><option>0.25</option><option>0.5</option><option selected>1</option><option>2</option><option>4</option></select></label></span></header>`)
	fmt.sbprintf(&sb, "\n<div id=\"player\"></div>\n<div id=\"caption\"></div>\n<script type=\"application/x-asciicast\" id=\"cast\">\n%s</script>\n", string(recording))
	fmt.sbprintf(&sb, "<script src=\"player.js\"></script>\n<script>%s</script>\n</body></html>\n", DEMO_PAGE_SCRIPT)
	html := fmt.tprintf("%s/%s.html", run.out, sc.name)
	_ = os.write_entire_file(html, strings.to_string(sb))
	fmt.printfln("  html %s", html)
}

demo_index :: proc(run: ^Run, list: []Scenario) {
	sb := strings.builder_make(context.temp_allocator)
	demo_page_head(&sb, "qed e2e demos", "")
	strings.write_string(&sb, "<header><h1>qed e2e demos</h1></header>\n<ul>\n")
	for sc in list {
		if !os.exists(fmt.tprintf("%s/%s.html", run.out, sc.name)) {
			continue
		}
		fmt.sbprintf(&sb, "<li><a href=\"%s.html\">%s</a><span class=\"desc\">%s</span></li>\n", html_escape(sc.name), html_escape(sc.name), html_escape(sc.title))
	}
	strings.write_string(&sb, "</ul>\n</body></html>\n")
	path := fmt.tprintf("%s/index.html", run.out)
	_ = os.write_entire_file(path, strings.to_string(sb))
	fmt.printfln("index %s", path)
}

matrix_run :: proc(run: ^Run, list: []Scenario, sizes, terms: []string) {
	base_out := run.out
	for size in sizes {
		run.w, run.h = size_parse(size)
		for t in terms {
			term, _, depth := strings.partition(t, ":")
			run.term = term
			run.colorterm = depth != "256"
			run.out = fmt.aprintf("%s/matrix/%s/%s", base_out, size, strings.trim_suffix(strings.concatenate({term, ":", depth}), ":"))
			os.remove_all(run.out)
			os.make_directory_all(run.out)
			fmt.printfln("== %s %s", size, t)
			for &sc in list {
				scenario_run(run, &sc)
			}
		}
		ref := fmt.tprintf("%s/matrix/%s/%s", base_out, size, terms[0])
		for t in terms[1:] {
			other := fmt.tprintf("%s/matrix/%s/%s", base_out, size, t)
			for &sc in list {
				dir := fmt.tprintf("%s/%s", ref, sc.name)
				files, _ := os.read_directory_by_path(dir, -1, context.temp_allocator)
				for f in files {
					if strings.has_prefix(f.name, "FAIL") {
						continue
					}
					a, aerr := os.read_entire_file(fmt.tprintf("%s/%s", dir, f.name), context.temp_allocator)
					b, berr := os.read_entire_file(fmt.tprintf("%s/%s/%s", other, sc.name, f.name), context.temp_allocator)
					if aerr != nil || berr != nil {
						continue
					}
					if string(a) != string(b) {
						append(&run.failures, fmt.aprintf("%s %s: %s/%s differs from %s", size, t, sc.name, f.name, terms[0]))
						fmt.printfln("  DIFF %s %s %s/%s vs %s\n%s", size, t, sc.name, f.name, terms[0], snap_diff(string(a), string(b)))
					}
				}
			}
		}
	}
	run.out = base_out
}
