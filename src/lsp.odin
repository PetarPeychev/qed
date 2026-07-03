package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

Diagnostic :: struct {
	from, to: Cursor,
	severity: int,
	message:  string,
}

LspState :: enum {
	Off,
	Running,
	Failed,
}

Lsp :: struct {
	state:       LspState,
	process:     os.Process,
	stdin:       ^os.File,
	stdout:      ^os.File,
	recv:        [dynamic]u8,
	next_id:     int,
	init_id:     int,
	initialized: bool,
}

@(private = "file")
g_lsp: Lsp

lsp_running :: proc() -> bool {
	return g_lsp.state == .Running
}

lsp_wants :: proc(b: ^Buffer) -> bool {
	return strings.has_suffix(b.path, ".odin")
}

lsp_start :: proc(editor: ^Editor) {
	posix.sigignore(.SIGPIPE)

	in_r, in_w, in_err := os.pipe()
	if in_err != nil {
		g_lsp.state = .Failed
		return
	}
	out_r, out_w, out_err := os.pipe()
	if out_err != nil {
		os.close(in_r)
		os.close(in_w)
		g_lsp.state = .Failed
		return
	}

	process, err := os.process_start({
		command     = {LSP_SERVER},
		working_dir = editor.working_root,
		stdin       = in_r,
		stdout      = out_w,
	})
	os.close(in_r)
	os.close(out_w)
	if err != nil {
		os.close(in_w)
		os.close(out_r)
		g_lsp.state = .Failed
		editor.message = "LSP: failed to start ols"
		editor.message_error = true
		return
	}

	fd := posix.FD(os.fd(out_r))
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | transmute(c.int)posix.O_Flags{.NONBLOCK})

	g_lsp.process = process
	g_lsp.stdin = in_w
	g_lsp.stdout = out_r
	g_lsp.state = .Running
	g_lsp.initialized = false

	g_lsp.next_id += 1
	g_lsp.init_id = g_lsp.next_id
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{{"processId":null,"rootUri":%s,"capabilities":{{"textDocument":{{"publishDiagnostics":{{}},"synchronization":{{}}}}}}}}}}`,
		g_lsp.init_id,
		lsp_json_string(lsp_uri(editor.working_root)),
	)
	lsp_send(editor, body)
}

lsp_stop :: proc(editor: ^Editor) {
	if g_lsp.state == .Running {
		g_lsp.next_id += 1
		lsp_send(editor, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"shutdown","params":null}}`, g_lsp.next_id))
		lsp_send(editor, `{"jsonrpc":"2.0","method":"exit","params":null}`)
		if g_lsp.state == .Running {
			os.close(g_lsp.stdin)
			os.close(g_lsp.stdout)
			if _, err := os.process_wait(g_lsp.process, 200 * time.Millisecond); err != nil {
				_ = os.process_kill(g_lsp.process)
			}
		}
	}
	g_lsp.state = .Off
	delete(g_lsp.recv)
	g_lsp.recv = nil
}

lsp_fail :: proc(editor: ^Editor) {
	if g_lsp.state != .Running {
		return
	}
	g_lsp.state = .Failed
	os.close(g_lsp.stdin)
	os.close(g_lsp.stdout)
	_ = os.process_kill(g_lsp.process)
	for &b in editor.buffers {
		buffer_clear_diags(&b)
		b.lsp_open = false
	}
	editor.message = "LSP: ols stopped"
	editor.message_error = true
}

lsp_send :: proc(editor: ^Editor, body: string) {
	if g_lsp.state != .Running {
		return
	}
	msg := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	if _, err := os.write(g_lsp.stdin, transmute([]u8)msg); err != nil {
		lsp_fail(editor)
	}
}

lsp_sync :: proc(editor: ^Editor) {
	if g_lsp.state == .Off {
		for &b in editor.buffers {
			if lsp_wants(&b) {
				lsp_start(editor)
				break
			}
		}
	}
	if !lsp_running() || !g_lsp.initialized {
		return
	}
	for &b in editor.buffers {
		if !lsp_wants(&b) {
			continue
		}
		if !b.lsp_open {
			lsp_did_open(editor, &b)
			lsp_did_save(editor, &b)
		} else if b.rev != b.lsp_rev {
			lsp_did_change(editor, &b)
		}
	}
}

lsp_did_open :: proc(editor: ^Editor, b: ^Buffer) {
	text := buffer_snapshot(b)
	defer delete(text)
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":%s,"languageId":"odin","version":%d,"text":%s}}}}}}`,
		lsp_json_string(lsp_uri(b.path)),
		b.rev,
		lsp_json_string(text),
	)
	lsp_send(editor, body)
	b.lsp_open = true
	b.lsp_rev = b.rev
}

lsp_did_change :: proc(editor: ^Editor, b: ^Buffer) {
	text := buffer_snapshot(b)
	defer delete(text)
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":%s,"version":%d}},"contentChanges":[{{"text":%s}}]}}}}`,
		lsp_json_string(lsp_uri(b.path)),
		b.rev,
		lsp_json_string(text),
	)
	lsp_send(editor, body)
	b.lsp_rev = b.rev
}

lsp_did_save :: proc(editor: ^Editor, b: ^Buffer) {
	if !b.lsp_open {
		return
	}
	if b.rev != b.lsp_rev {
		lsp_did_change(editor, b)
	}
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didSave","params":{{"textDocument":{{"uri":%s}}}}}}`,
		lsp_json_string(lsp_uri(b.path)),
	)
	lsp_send(editor, body)
}

lsp_did_close :: proc(editor: ^Editor, b: ^Buffer) {
	if !b.lsp_open {
		return
	}
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":%s}}}}}}`,
		lsp_json_string(lsp_uri(b.path)),
	)
	lsp_send(editor, body)
	b.lsp_open = false
	buffer_clear_diags(b)
}

lsp_pump :: proc(editor: ^Editor) -> bool {
	if !lsp_running() {
		return false
	}
	fd := posix.FD(os.fd(g_lsp.stdout))
	buf: [16384]u8
	for {
		n := posix.read(fd, &buf[0], len(buf))
		if n > 0 {
			append(&g_lsp.recv, ..buf[:n])
			continue
		}
		if n == 0 {
			lsp_fail(editor)
			return true
		}
		if posix.errno() != .EAGAIN {
			lsp_fail(editor)
			return true
		}
		break
	}
	changed := false
	for {
		body, ok := lsp_next_frame()
		if !ok {
			break
		}
		if lsp_handle(editor, body) {
			changed = true
		}
	}
	return changed
}

lsp_next_frame :: proc() -> (string, bool) {
	head := strings.index(string(g_lsp.recv[:]), "\r\n\r\n")
	if head < 0 {
		return "", false
	}
	length := -1
	for line in strings.split(string(g_lsp.recv[:head]), "\r\n", context.temp_allocator) {
		if strings.has_prefix(line, "Content-Length:") {
			length, _ = strconv.parse_int(strings.trim_space(line[len("Content-Length:"):]))
		}
	}
	if length < 0 {
		clear(&g_lsp.recv)
		return "", false
	}
	total := head + 4 + length
	if len(g_lsp.recv) < total {
		return "", false
	}
	body := strings.clone(string(g_lsp.recv[head + 4:total]), context.temp_allocator)
	copy(g_lsp.recv[:], g_lsp.recv[total:])
	resize(&g_lsp.recv, len(g_lsp.recv) - total)
	return body, true
}

lsp_handle :: proc(editor: ^Editor, body: string) -> bool {
	value, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != nil {
		return false
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return false
	}

	if method_v, has_method := obj["method"]; has_method {
		method, _ := method_v.(string)
		if id_v, has_id := obj["id"]; has_id {
			id, _ := lsp_num(id_v)
			result := "null"
			if method == "workspace/configuration" {
				n := 1
				if params, ok := obj["params"].(json.Object); ok {
					if items, ok2 := params["items"].(json.Array); ok2 {
						n = len(items)
					}
				}
				sb := strings.builder_make(context.temp_allocator)
				strings.write_byte(&sb, '[')
				for i in 0 ..< n {
					if i > 0 {
						strings.write_byte(&sb, ',')
					}
					strings.write_string(&sb, "null")
				}
				strings.write_byte(&sb, ']')
				result = strings.to_string(sb)
			}
			lsp_send(editor, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":%s}}`, id, result))
			return false
		}
		if method == "textDocument/publishDiagnostics" {
			return lsp_handle_diagnostics(editor, obj)
		}
		return false
	}

	if id_v, has_id := obj["id"]; has_id {
		if id, ok := lsp_num(id_v); ok && id == g_lsp.init_id && !g_lsp.initialized {
			g_lsp.initialized = true
			lsp_send(editor, `{"jsonrpc":"2.0","method":"initialized","params":{}}`)
			return true
		}
	}
	return false
}

lsp_handle_diagnostics :: proc(editor: ^Editor, obj: json.Object) -> bool {
	params, params_ok := obj["params"].(json.Object)
	if !params_ok {
		return false
	}
	uri, uri_ok := params["uri"].(string)
	if !uri_ok {
		return false
	}
	idx := editor_find_buffer(editor, lsp_uri_to_path(uri))
	if idx < 0 {
		return false
	}
	b := &editor.buffers[idx]

	buffer_clear_diags(b)
	if arr, ok := params["diagnostics"].(json.Array); ok {
		for item in arr {
			d_obj := item.(json.Object) or_continue
			r := d_obj["range"].(json.Object) or_continue
			start := r["start"].(json.Object) or_continue
			end := r["end"].(json.Object) or_continue
			severity := 1
			if s, has := lsp_num(d_obj["severity"]); has {
				severity = s
			}
			message := ""
			if m, has := d_obj["message"].(string); has {
				message = m
			}
			append(&b.diags, Diagnostic{
				from     = lsp_cursor(b, start),
				to       = lsp_cursor(b, end),
				severity = severity,
				message  = strings.clone(message),
			})
		}
	}
	return true
}

lsp_num :: proc(v: json.Value) -> (int, bool) {
	#partial switch n in v {
	case json.Float:
		return int(n), true
	case json.Integer:
		return int(n), true
	}
	return 0, false
}

lsp_cursor :: proc(b: ^Buffer, pos: json.Object) -> Cursor {
	row, _ := lsp_num(pos["line"])
	ch, _ := lsp_num(pos["character"])
	row = clamp(row, 0, len(b.lines) - 1)
	return {row, col_from_utf16(b.lines[row].text[:], ch)}
}

col_from_utf16 :: proc(text: []u8, target: int) -> int {
	units := 0
	for i := 0; i < len(text); {
		if units >= target {
			return i
		}
		r, n := utf8.decode_rune(text[i:])
		units += 2 if r >= 0x10000 else 1
		i += n
	}
	return len(text)
}

lsp_uri :: proc(path: string) -> string {
	return strings.concatenate({"file://", path}, context.temp_allocator)
}

lsp_uri_to_path :: proc(uri: string) -> string {
	path := strings.trim_prefix(uri, "file://")
	if !strings.contains_rune(path, '%') {
		return path
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(path); {
		if path[i] == '%' && i + 2 < len(path) {
			hi, hi_ok := hex_digit(path[i + 1])
			lo, lo_ok := hex_digit(path[i + 2])
			if hi_ok && lo_ok {
				strings.write_byte(&sb, hi << 4 | lo)
				i += 3
				continue
			}
		}
		strings.write_byte(&sb, path[i])
		i += 1
	}
	return strings.to_string(sb)
}

hex_digit :: proc(ch: u8) -> (u8, bool) {
	switch ch {
	case '0' ..= '9':
		return ch - '0', true
	case 'a' ..= 'f':
		return ch - 'a' + 10, true
	case 'A' ..= 'F':
		return ch - 'A' + 10, true
	}
	return 0, false
}

lsp_json_string :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&sb, `\"`)
		case '\\':
			strings.write_string(&sb, `\\`)
		case '\n':
			strings.write_string(&sb, `\n`)
		case '\r':
			strings.write_string(&sb, `\r`)
		case '\t':
			strings.write_string(&sb, `\t`)
		case:
			if ch < 0x20 {
				fmt.sbprintf(&sb, `\u%04x`, ch)
			} else {
				strings.write_byte(&sb, ch)
			}
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

buffer_clear_diags :: proc(b: ^Buffer) {
	for &d in b.diags {
		delete(d.message)
	}
	clear(&b.diags)
}

diagnostic_at :: proc(b: ^Buffer, cur: Cursor) -> (^Diagnostic, bool) {
	row_match: ^Diagnostic
	for &d in b.diags {
		after_start := cur.row > d.from.row || (cur.row == d.from.row && cur.col >= d.from.col)
		before_end := cur.row < d.to.row || (cur.row == d.to.row && cur.col <= d.to.col)
		if after_start && before_end {
			return &d, true
		}
		if row_match == nil && d.from.row == cur.row {
			row_match = &d
		}
	}
	return row_match, row_match != nil
}

diagnostic_color :: proc(severity: int) -> tb2.Color {
	switch severity {
	case 1:
		return COLOR_DIAG_ERROR_FG
	case 2:
		return COLOR_DIAG_WARN_FG
	}
	return COLOR_GUTTER_FG
}
