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
	server:      string,
	state:       LspState,
	process:     os.Process,
	stdin:       ^os.File,
	stdout:      ^os.File,
	recv:        [dynamic]u8,
	next_id:     int,
	init_id:     int,
	initialized: bool,
	sync_kind:   int,
}

// One entry in a `textDocument/didChange` batch: an LSP range (UTF-16 columns)
// in pre-change coordinates plus its replacement text. Recorded per primitive
// edit so large files send only the diff instead of the whole document.
LspChange :: struct {
	start_line, start_char: int,
	end_line, end_char:     int,
	text:                   string,
}

LSP_SYNC_FULL :: 1
LSP_SYNC_INCREMENTAL :: 2

@(private = "file")
g_lsps: map[string]^Lsp

lsp_running :: proc() -> bool {
	for _, lsp in g_lsps {
		if lsp.state == .Running {
			return true
		}
	}
	return false
}

lsp_display_name :: proc(server: string) -> string {
	if sp := strings.index_byte(server, ' '); sp >= 0 {
		return server[:sp]
	}
	return server
}

lsp_for :: proc(b: ^Buffer) -> (^Lsp, bool) {
	server := language_info(b.path).lsp_server
	if server == "" {
		return nil, false
	}
	lsp, ok := g_lsps[server]
	return lsp, ok
}

lsp_status_label :: proc(b: ^Buffer) -> string {
	server := language_info(b.path).lsp_server
	if server == "" {
		return ""
	}
	name := lsp_display_name(server)
	lsp, ok := g_lsps[server]
	if !ok {
		return fmt.tprintf("%s …", name)
	}
	switch lsp.state {
	case .Running:
		return name
	case .Failed:
		return fmt.tprintf("%s ✗", name)
	case .Off:
		return fmt.tprintf("%s …", name)
	}
	return name
}

lsp_start :: proc(editor: ^Editor, server: string) -> ^Lsp {
	posix.sigignore(.SIGPIPE)

	lsp := new(Lsp)
	lsp.server = server
	g_lsps[server] = lsp

	in_r, in_w, in_err := os.pipe()
	if in_err != nil {
		lsp.state = .Failed
		return lsp
	}
	out_r, out_w, out_err := os.pipe()
	if out_err != nil {
		os.close(in_r)
		os.close(in_w)
		lsp.state = .Failed
		return lsp
	}

	process, err := os.process_start({
		command     = strings.fields(server, context.temp_allocator),
		working_dir = editor.working_root,
		stdin       = in_r,
		stdout      = out_w,
	})
	os.close(in_r)
	os.close(out_w)
	if err != nil {
		os.close(in_w)
		os.close(out_r)
		lsp.state = .Failed
		editor.message = fmt.tprintf("LSP: failed to start %s", lsp_display_name(server))
		editor.message_error = true
		return lsp
	}

	fd := posix.FD(os.fd(out_r))
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | transmute(c.int)posix.O_Flags{.NONBLOCK})

	lsp.process = process
	lsp.stdin = in_w
	lsp.stdout = out_r
	lsp.state = .Running
	lsp.initialized = false

	lsp.next_id += 1
	lsp.init_id = lsp.next_id
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{{"processId":null,"rootUri":%s,"capabilities":{{"textDocument":{{"publishDiagnostics":{{}},"synchronization":{{}}}}}}}}}}`,
		lsp.init_id,
		lsp_json_string(lsp_uri(editor.working_root)),
	)
	lsp_send(editor, lsp, body)
	return lsp
}

lsp_stop :: proc(editor: ^Editor) {
	for _, lsp in g_lsps {
		if lsp.state == .Running {
			lsp.next_id += 1
			lsp_send(editor, lsp, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"shutdown","params":null}}`, lsp.next_id))
			lsp_send(editor, lsp, `{"jsonrpc":"2.0","method":"exit","params":null}`)
			if lsp.state == .Running {
				os.close(lsp.stdin)
				os.close(lsp.stdout)
				if _, err := os.process_wait(lsp.process, 200 * time.Millisecond); err != nil {
					_ = os.process_kill(lsp.process)
				}
			}
		}
		delete(lsp.recv)
		free(lsp)
	}
	delete(g_lsps)
	g_lsps = nil
}

lsp_fail :: proc(editor: ^Editor, lsp: ^Lsp) {
	if lsp.state != .Running {
		return
	}
	lsp.state = .Failed
	os.close(lsp.stdin)
	os.close(lsp.stdout)
	_ = os.process_kill(lsp.process)
	for &b in editor.buffers {
		if language_info(b.path).lsp_server == lsp.server {
			buffer_clear_diags(&b)
			buffer_lsp_changes_clear(&b)
			b.lsp_open = false
		}
	}
	editor.message = fmt.tprintf("LSP: %s stopped", lsp_display_name(lsp.server))
	editor.message_error = true
}

lsp_send :: proc(editor: ^Editor, lsp: ^Lsp, body: string) {
	if lsp.state != .Running {
		return
	}
	msg := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	if _, err := os.write(lsp.stdin, transmute([]u8)msg); err != nil {
		lsp_fail(editor, lsp)
	}
}

lsp_sync :: proc(editor: ^Editor) {
	for &b in editor.buffers {
		if b.big {
			continue
		}
		server := language_info(b.path).lsp_server
		if server == "" {
			continue
		}
		lsp, ok := g_lsps[server]
		if !ok {
			lsp = lsp_start(editor, server)
		}
		if lsp.state != .Running || !lsp.initialized {
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
	lsp, ok := lsp_for(b)
	if !ok {
		return
	}
	text := buffer_snapshot(b)
	defer delete(text)
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":%s,"languageId":%s,"version":%d,"text":%s}}}}}}`,
		lsp_json_string(lsp_uri(b.path)),
		lsp_json_string(language_info(b.path).lsp_id),
		b.rev,
		lsp_json_string(text),
	)
	lsp_send(editor, lsp, body)
	b.lsp_open = true
	b.lsp_rev = b.rev
	buffer_lsp_changes_clear(b)
}

lsp_did_change :: proc(editor: ^Editor, b: ^Buffer) {
	lsp, ok := lsp_for(b)
	if !ok {
		return
	}

	changes: string
	if lsp.sync_kind == LSP_SYNC_INCREMENTAL {
		sb := strings.builder_make(context.temp_allocator)
		strings.write_byte(&sb, '[')
		for ch, i in b.lsp_changes {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(
				&sb,
				`{{"range":{{"start":{{"line":%d,"character":%d}},"end":{{"line":%d,"character":%d}}}},"text":%s}}`,
				ch.start_line,
				ch.start_char,
				ch.end_line,
				ch.end_char,
				lsp_json_string(ch.text),
			)
		}
		strings.write_byte(&sb, ']')
		changes = strings.to_string(sb)
	} else {
		text := buffer_snapshot(b)
		defer delete(text)
		changes = fmt.tprintf(`[{{"text":%s}}]`, lsp_json_string(text))
	}

	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":%s,"version":%d}},"contentChanges":%s}}}}`,
		lsp_json_string(lsp_uri(b.path)),
		b.rev,
		changes,
	)
	lsp_send(editor, lsp, body)
	buffer_lsp_changes_clear(b)
	b.lsp_rev = b.rev
}

lsp_did_save :: proc(editor: ^Editor, b: ^Buffer) {
	if !b.lsp_open {
		return
	}
	lsp, ok := lsp_for(b)
	if !ok {
		return
	}
	if b.rev != b.lsp_rev {
		lsp_did_change(editor, b)
	}
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didSave","params":{{"textDocument":{{"uri":%s}}}}}}`,
		lsp_json_string(lsp_uri(b.path)),
	)
	lsp_send(editor, lsp, body)
}

lsp_did_close :: proc(editor: ^Editor, b: ^Buffer) {
	if !b.lsp_open {
		return
	}
	if lsp, ok := lsp_for(b); ok {
		body := fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":%s}}}}}}`,
			lsp_json_string(lsp_uri(b.path)),
		)
		lsp_send(editor, lsp, body)
	}
	b.lsp_open = false
	buffer_clear_diags(b)
}

lsp_pump :: proc(editor: ^Editor) -> bool {
	changed := false
	for _, lsp in g_lsps {
		if lsp.state != .Running {
			continue
		}
		fd := posix.FD(os.fd(lsp.stdout))
		buf: [16384]u8
		failed := false
		for {
			n := posix.read(fd, &buf[0], len(buf))
			if n > 0 {
				append(&lsp.recv, ..buf[:n])
				continue
			}
			if n == 0 || posix.errno() != .EAGAIN {
				lsp_fail(editor, lsp)
				failed = true
			}
			break
		}
		if failed {
			changed = true
			continue
		}
		for {
			body, ok := lsp_next_frame(lsp)
			if !ok {
				break
			}
			if lsp_handle(editor, lsp, body) {
				changed = true
			}
		}
	}
	return changed
}

lsp_next_frame :: proc(lsp: ^Lsp) -> (string, bool) {
	head := strings.index(string(lsp.recv[:]), "\r\n\r\n")
	if head < 0 {
		return "", false
	}
	length := -1
	for line in strings.split(string(lsp.recv[:head]), "\r\n", context.temp_allocator) {
		if strings.has_prefix(line, "Content-Length:") {
			length, _ = strconv.parse_int(strings.trim_space(line[len("Content-Length:"):]))
		}
	}
	if length < 0 {
		clear(&lsp.recv)
		return "", false
	}
	total := head + 4 + length
	if len(lsp.recv) < total {
		return "", false
	}
	body := strings.clone(string(lsp.recv[head + 4:total]), context.temp_allocator)
	copy(lsp.recv[:], lsp.recv[total:])
	resize(&lsp.recv, len(lsp.recv) - total)
	return body, true
}

lsp_handle :: proc(editor: ^Editor, lsp: ^Lsp, body: string) -> bool {
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
			lsp_send(editor, lsp, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":%s}}`, id, result))
			return false
		}
		if method == "textDocument/publishDiagnostics" {
			return lsp_handle_diagnostics(editor, obj)
		}
		return false
	}

	if id_v, has_id := obj["id"]; has_id {
		if id, ok := lsp_num(id_v); ok && id == lsp.init_id && !lsp.initialized {
			lsp.initialized = true
			lsp.sync_kind = lsp_sync_kind(obj)
			lsp_send(editor, lsp, `{"jsonrpc":"2.0","method":"initialized","params":{}}`)
			return true
		}
	}
	return false
}

// The server's `capabilities.textDocumentSync` decides whether we may send
// range-based (incremental) changes; a Full-only server would misread a ranged
// change as the whole new document, so anything but an explicit Incremental
// falls back to full-text sends.
lsp_sync_kind :: proc(obj: json.Object) -> int {
	result := obj["result"].(json.Object) or_else nil
	caps := result["capabilities"].(json.Object) or_else nil
	sync, has := caps["textDocumentSync"]
	if !has {
		return LSP_SYNC_FULL
	}
	#partial switch s in sync {
	case json.Object:
		if n, ok := lsp_num(s["change"]); ok {
			return n
		}
	case:
		if n, ok := lsp_num(sync); ok {
			return n
		}
	}
	return LSP_SYNC_FULL
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

col_to_utf16 :: proc(text: []u8, byte_col: int) -> int {
	units := 0
	end := min(byte_col, len(text))
	for i := 0; i < end; {
		r, n := utf8.decode_rune(text[i:])
		units += 2 if r >= 0x10000 else 1
		i += n
	}
	return units
}

// Record one edit as an LSP change range (only while the doc is open with a
// server; otherwise the next `didOpen` full-text send covers it). Coordinates
// are taken from the current line content, which is the pre-change state for the
// recorded range: `buffer_insert` records after mutation (its prefix up to `at`
// is untouched) and `buffer_delete` before.
lsp_change_record :: proc(b: ^Buffer, start, end: Cursor, text: string) {
	if !b.lsp_open {
		return
	}
	append(&b.lsp_changes, LspChange{
		start_line = start.row,
		start_char = col_to_utf16(b.lines[start.row].text[:], start.col),
		end_line   = end.row,
		end_char   = col_to_utf16(b.lines[end.row].text[:], end.col),
		text       = strings.clone(text),
	})
}

buffer_lsp_changes_clear :: proc(b: ^Buffer) {
	for ch in b.lsp_changes {
		delete(ch.text)
	}
	clear(&b.lsp_changes)
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
