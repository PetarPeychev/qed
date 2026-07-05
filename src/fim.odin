package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

@(private = "file")
g_fim_counter: int

@(private = "file")
fim_log :: proc(format: string, args: ..any) {
	if os.get_env("QED_FIM_DEBUG", context.temp_allocator) == "" {
		return
	}
	fd, err := os.open("/tmp/qed-fim.log", {.Write, .Create, .Append}, os.perm(0o644))
	if err != nil {
		return
	}
	os.write(fd, transmute([]u8)fmt.tprintf(format, ..args))
	os.write(fd, []u8{'\n'})
	os.close(fd)
}

Fim :: struct {
	enabled:    bool,
	warned:     bool,
	want:       bool,
	request_at: time.Tick,
	running:    bool,
	process:    os.Process,
	stdout:     ^os.File,
	out:        strings.Builder,
	req_path:   string,
	req_at:     Cursor,
	ghost:      string,
	ghost_at:   Cursor,
}

fim_active :: proc(editor: ^Editor) -> bool {
	return editor.fim.running || editor.fim.want
}

fim_ghost_active :: proc(editor: ^Editor) -> bool {
	f := &editor.fim
	return len(f.ghost) > 0 && editor_buffer(editor).cursor == f.ghost_at
}

// Extra screen rows the shown ghost reserves below the cursor line (its inline
// first line adds none). The buffer render pushes real rows down by this much so
// the continuation lines land on blank rows instead of over existing text.
fim_ghost_gap :: proc(editor: ^Editor) -> int {
	if editor.completion.active || !fim_ghost_active(editor) {
		return 0
	}
	return strings.count(editor.fim.ghost, "\n")
}

fim_clear_ghost :: proc(f: ^Fim) {
	if len(f.ghost) > 0 {
		delete(f.ghost)
		f.ghost = ""
	}
}

fim_kill_request :: proc(f: ^Fim) {
	if !f.running {
		return
	}
	_ = os.process_kill(f.process)
	os.close(f.stdout)
	_, _ = os.process_wait(f.process, time.Second)
	strings.builder_destroy(&f.out)
	delete(f.req_path)
	f.running = false
}

fim_dismiss :: proc(editor: ^Editor) {
	f := &editor.fim
	f.want = false
	fim_clear_ghost(f)
	fim_kill_request(f)
}

// Fresh edit -> any in-flight request and shown ghost are stale; drop them and
// arm the debounce for a new one.
fim_queue :: proc(editor: ^Editor) {
	f := &editor.fim
	fim_clear_ghost(f)
	fim_kill_request(f)
	f.want = true
	f.request_at = time.tick_now()
	fim_log("queued (enabled=%v)", f.enabled)
}

fim_after :: proc(editor: ^Editor, ev: tb2.Event) {
	f := &editor.fim
	if !f.enabled || editor.completion.active {
		return
	}
	b := editor_buffer(editor)
	if b.big || selection_active(b) {
		return
	}
	if u8(ev.mod) & (u8(tb2.Mod.Ctrl) | u8(tb2.Mod.Alt)) != 0 {
		return
	}
	#partial switch ev.key {
	case .Enter, .Backspace, .Backspace2, .Delete:
		fim_queue(editor)
		return
	}
	if ev.ch >= 0x20 {
		fim_queue(editor)
	}
}

fim_due :: proc(editor: ^Editor) -> bool {
	f := &editor.fim
	if !f.want || editor.completion.active {
		return false
	}
	return time.duration_milliseconds(time.tick_since(f.request_at)) >= f64(LLM_COMPLETION_DEBOUNCE_MS)
}

fim_request :: proc(editor: ^Editor) {
	f := &editor.fim
	f.want = false
	b := editor_buffer(editor)
	if b.big || selection_active(b) {
		fim_log("request skipped: big=%v selection=%v", b.big, selection_active(b))
		return
	}
	key := os.get_env(LLM_COMPLETION_API_KEY_ENV, context.temp_allocator)
	if key == "" {
		fim_log("request skipped: $%s empty", LLM_COMPLETION_API_KEY_ENV)
		if !f.warned {
			f.warned = true
			editor_set_message(editor, fmt.tprintf("Inline completion: $%s is not set", LLM_COMPLETION_API_KEY_ENV), true)
		}
		return
	}

	last := len(b.lines) - 1
	lo := max(0, b.cursor.row - LLM_COMPLETION_CONTEXT_LINES)
	hi := min(last, b.cursor.row + LLM_COMPLETION_CONTEXT_LINES)
	prefix := buffer_text_range(b, {lo, 0}, b.cursor, context.temp_allocator)
	suffix := buffer_text_range(b, b.cursor, {hi, len(b.lines[hi].text)}, context.temp_allocator)
	body := fmt.tprintf(
		`{{"model":%s,"prompt":%s,"suffix":%s,"max_tokens":%d,"temperature":0}}`,
		lsp_json_string(LLM_COMPLETION_MODEL),
		lsp_json_string(prefix),
		lsp_json_string(suffix),
		LLM_COMPLETION_MAX_TOKENS,
	)

	g_fim_counter += 1
	tmp := fmt.tprintf("/tmp/qed-fim-%d-%d.json", posix.getpid(), g_fim_counter)
	fd, oerr := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o600))
	if oerr != nil {
		fim_log("request skipped: temp open failed %v", oerr)
		return
	}
	os.write(fd, transmute([]u8)body)
	os.close(fd)
	in_file, ierr := os.open(tmp, {.Read})
	if ierr != nil {
		os.remove(tmp)
		fim_log("request skipped: temp reopen failed %v", ierr)
		return
	}

	out_r, out_w, perr := os.pipe()
	if perr != nil {
		os.close(in_file)
		os.remove(tmp)
		fim_log("request skipped: pipe failed %v", perr)
		return
	}
	cmd := fmt.tprintf(
		"curl -s --max-time 10 -X POST '%s' -H 'Content-Type: application/json' -H \"Authorization: Bearer $%s\" --data-binary @- 2>/dev/null",
		LLM_COMPLETION_ENDPOINT,
		LLM_COMPLETION_API_KEY_ENV,
	)
	posix.sigignore(.SIGPIPE)
	process, serr := os.process_start(
		{command = {"sh", "-c", cmd}, working_dir = editor.working_root, stdin = in_file, stdout = out_w},
	)
	os.close(in_file)
	os.close(out_w)
	os.remove(tmp)
	if serr != nil {
		fim_log("request FAILED to start: %v (working_dir=%q)", serr, editor.working_root)
		os.close(out_r)
		return
	}
	fim_log("request started at (%d,%d) prefix=%dB suffix=%dB", b.cursor.row, b.cursor.col, len(prefix), len(suffix))

	nfd := posix.FD(os.fd(out_r))
	flags := posix.fcntl(nfd, .GETFL)
	posix.fcntl(nfd, .SETFL, flags | transmute(c.int)posix.O_Flags{.NONBLOCK})

	f.process = process
	f.stdout = out_r
	f.out = strings.builder_make()
	f.req_path = strings.clone(b.path)
	f.req_at = b.cursor
	f.running = true
}

fim_pump :: proc(editor: ^Editor) -> bool {
	f := &editor.fim
	if !f.running {
		return false
	}
	fd := posix.FD(os.fd(f.stdout))
	buf: [16384]u8
	done := false
	for {
		n := posix.read(fd, &buf[0], len(buf))
		if n > 0 {
			strings.write_bytes(&f.out, buf[:n])
			continue
		}
		if n == 0 || posix.errno() != .EAGAIN {
			done = true
		}
		break
	}
	if !done {
		return false
	}

	os.close(f.stdout)
	_, _ = os.process_wait(f.process, time.Second)
	raw := strings.to_string(f.out)
	text := strings.trim_right(fim_parse(raw), "\n")
	b := editor_buffer(editor)
	moved := b.path != f.req_path || b.cursor != f.req_at
	fim_log("response %dB -> parsed %dB, moved=%v sel=%v raw=%q", len(raw), len(text), moved, selection_active(b), raw[:min(len(raw), 200)])
	if !moved && !selection_active(b) && len(strings.trim_space(text)) > 0 {
		f.ghost = strings.clone(text)
		f.ghost_at = b.cursor
	}
	strings.builder_destroy(&f.out)
	delete(f.req_path)
	f.running = false
	return true
}

fim_parse :: proc(raw: string) -> string {
	val, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	if err != nil {
		return ""
	}
	obj, ok_obj := val.(json.Object)
	if !ok_obj {
		return ""
	}
	choices, ok_ch := obj["choices"].(json.Array)
	if !ok_ch || len(choices) == 0 {
		return ""
	}
	c0, ok_c0 := choices[0].(json.Object)
	if !ok_c0 {
		return ""
	}
	if msg, ok := c0["message"].(json.Object); ok {
		if s, ok := msg["content"].(json.String); ok {
			return string(s)
		}
	}
	if s, ok := c0["text"].(json.String); ok {
		return string(s)
	}
	return ""
}

fim_ghost_key :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	ctrl := (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0
	#partial switch ev.key {
	case .Tab:
		fim_accept(editor)
		return true
	case .Esc:
		fim_dismiss(editor)
		return true
	case .Arrow_Right:
		if ctrl {
			fim_accept_word(editor)
			return true
		}
	}
	return false
}

fim_accept :: proc(editor: ^Editor) {
	f := &editor.fim
	if len(f.ghost) == 0 {
		return
	}
	text := strings.clone(f.ghost, context.temp_allocator)
	buffer_insert_text(editor_buffer(editor), text, .Atomic)
	fim_dismiss(editor)
	editor_scroll(editor)
}

fim_accept_word :: proc(editor: ^Editor) {
	f := &editor.fim
	if len(f.ghost) == 0 {
		return
	}
	n := fim_word_len(f.ghost)
	if n >= len(f.ghost) {
		fim_accept(editor)
		return
	}
	chunk := strings.clone(f.ghost[:n], context.temp_allocator)
	rest := strings.clone(f.ghost[n:])
	b := editor_buffer(editor)
	buffer_insert_text(b, chunk, .Atomic)
	fim_clear_ghost(f)
	if len(strings.trim_space(rest)) == 0 {
		delete(rest)
	} else {
		f.ghost = rest
		f.ghost_at = b.cursor
	}
	editor_scroll(editor)
}

// One accept step: leading blanks + a single same-class token, or a newline plus
// its following indentation. Rune-safe so a multibyte char is never split.
fim_word_len :: proc(s: string) -> int {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	if i < len(s) && s[i] == '\n' {
		i += 1
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
			i += 1
		}
		return i
	}
	if i >= len(s) {
		return i
	}
	r0, n0 := utf8.decode_rune(s[i:])
	cls := char_class(r0)
	i += n0
	for i < len(s) {
		if s[i] == ' ' || s[i] == '\t' || s[i] == '\n' {
			break
		}
		r, n := utf8.decode_rune(s[i:])
		if char_class(r) != cls {
			break
		}
		i += n
	}
	return i
}

fim_render :: proc(editor: ^Editor, cx, cy: int) {
	f := &editor.fim
	if len(f.ghost) == 0 {
		return
	}
	b := editor_buffer(editor)
	gutter := editor_gutter_width(editor)
	_, vh := editor_viewport(editor)
	full_w := int(tb2.width())
	y := cy
	for line, li in strings.split(f.ghost, "\n", context.temp_allocator) {
		bx := cx
		if li > 0 {
			y += 1
			if y >= vh {
				break
			}
			bx = gutter
		}
		bg := COLOR_BG
		if li == 0 {
			bg = editor_line_bg(true, false, git_mark_at(b, b.cursor.row), editor.hunk_highlight)
		}
		for r in line {
			if r == '\t' {
				bx = gutter + ((bx - gutter) / TAB_WIDTH + 1) * TAB_WIDTH
				continue
			}
			if bx >= full_w {
				break
			}
			if bx >= gutter {
				tb2.set_cell(i32(bx), i32(y), r, COLOR_GHOST_FG, bg)
			}
			bx += 1
		}
	}
}
