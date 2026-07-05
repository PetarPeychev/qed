package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
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
	server:         string,
	state:          LspState,
	process:        os.Process,
	stdin:          ^os.File,
	stdout:         ^os.File,
	recv:           [dynamic]u8,
	next_id:        int,
	init_id:        int,
	initialized:    bool,
	sync_kind:      int,
	cap_definition: bool,
	cap_hover:      bool,
	cap_format:     bool,
	cap_rename:     bool,
	cap_completion: bool,
	completion_triggers: [dynamic]u8,
	pending:        map[int]LspPending,
}

LspRequest :: enum {
	Definition,
	Hover,
	Format,
	FormatOnSave,
	Rename,
	Completion,
}

// A request awaiting its response. `path`/`rev` locate the target buffer and
// guard against applying stale results (formatting) after the doc has changed.
LspPending :: struct {
	kind: LspRequest,
	path: string,
	rev:  u64,
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
	server := LANGUAGES[b.language].lsp_server
	if server == "" {
		return nil, false
	}
	lsp, ok := g_lsps[server]
	return lsp, ok
}

lsp_status_label :: proc(b: ^Buffer) -> string {
	server := LANGUAGES[b.language].lsp_server
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
		editor_set_message(editor, fmt.tprintf("LSP: failed to start %s", lsp_display_name(server)), true)
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
	root_uri := lsp_json_string(lsp_uri(editor.working_root))
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{{"processId":null,"rootUri":%s,"workspaceFolders":[{{"uri":%s,"name":"root"}}],"capabilities":{{"workspace":{{"configuration":true,"didChangeConfiguration":{{}},"workspaceFolders":true}},"textDocument":{{"publishDiagnostics":{{}},"synchronization":{{}},"definition":{{}},"hover":{{"contentFormat":["plaintext","markdown"]}},"formatting":{{}},"rename":{{}},"completion":{{"contextSupport":true,"completionItem":{{"snippetSupport":false}}}}}}}}}}}}`,
		lsp.init_id,
		root_uri,
		root_uri,
	)
	lsp_send(editor, lsp, body)
	return lsp
}

lsp_shutdown_one :: proc(editor: ^Editor, lsp: ^Lsp) {
	if lsp.state != .Running {
		return
	}
	lsp.next_id += 1
	lsp_send(editor, lsp, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"shutdown","params":null}}`, lsp.next_id))
	lsp_send(editor, lsp, `{"jsonrpc":"2.0","method":"exit","params":null}`)
	if lsp.state != .Running {
		return
	}
	os.close(lsp.stdin)
	os.close(lsp.stdout)
	if _, err := os.process_wait(lsp.process, 200 * time.Millisecond); err != nil {
		_ = os.process_kill(lsp.process)
	}
}

lsp_pending_clear :: proc(lsp: ^Lsp) {
	for _, p in lsp.pending {
		delete(p.path)
	}
	delete(lsp.pending)
	lsp.pending = nil
}

lsp_stop :: proc(editor: ^Editor) {
	for _, lsp in g_lsps {
		lsp_shutdown_one(editor, lsp)
		lsp_pending_clear(lsp)
		delete(lsp.recv)
		delete(lsp.completion_triggers)
		free(lsp)
	}
	delete(g_lsps)
	g_lsps = nil
}

lsp_restart :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	server := LANGUAGES[b.language].lsp_server
	if server == "" {
		editor_set_message(editor, "No language server for this buffer", true)
		return
	}
	name := lsp_display_name(server)
	if lsp, ok := g_lsps[server]; ok {
		lsp_shutdown_one(editor, lsp)
		lsp_pending_clear(lsp)
		delete(lsp.recv)
		delete(lsp.completion_triggers)
		free(lsp)
		delete_key(&g_lsps, server)
		for &bb in editor.buffers {
			if LANGUAGES[bb.language].lsp_server == server {
				buffer_clear_diags(&bb)
				buffer_lsp_changes_clear(&bb)
				bb.lsp_open = false
			}
		}
	}
	editor_set_message(editor, fmt.tprintf("LSP: restarting %s", name))
}

lsp_fail :: proc(editor: ^Editor, lsp: ^Lsp) {
	if lsp.state != .Running {
		return
	}
	lsp.state = .Failed
	lsp_pending_clear(lsp)
	os.close(lsp.stdin)
	os.close(lsp.stdout)
	_ = os.process_kill(lsp.process)
	for &b in editor.buffers {
		if LANGUAGES[b.language].lsp_server == lsp.server {
			buffer_clear_diags(&b)
			buffer_lsp_changes_clear(&b)
			b.lsp_open = false
		}
	}
	editor_set_message(editor, fmt.tprintf("LSP: %s stopped", lsp_display_name(lsp.server)), true)
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
		server := LANGUAGES[b.language].lsp_server
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
		lsp_json_string(LANGUAGES[b.language].lsp_id),
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
	// Include the text: ols re-indexes from didSave's `text`, so omitting it makes
	// ols index the file as empty and drop its symbols (breaks cross-file rename).
	text := buffer_snapshot(b)
	defer delete(text)
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didSave","params":{{"textDocument":{{"uri":%s}},"text":%s}}}}`,
		lsp_json_string(lsp_uri(b.path)),
		lsp_json_string(text),
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
				sb := strings.builder_make(context.temp_allocator)
				strings.write_byte(&sb, '[')
				if params, ok := obj["params"].(json.Object); ok {
					if items, ok2 := params["items"].(json.Array); ok2 {
						for item, i in items {
							if i > 0 {
								strings.write_byte(&sb, ',')
							}
							section := ""
							if io, ok3 := item.(json.Object); ok3 {
								section, _ = io["section"].(string)
							}
							strings.write_string(&sb, lsp_config_for_section(section))
						}
					}
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
		if id, ok := lsp_num(id_v); ok {
			if id == lsp.init_id && !lsp.initialized {
				lsp.initialized = true
				lsp.sync_kind = lsp_sync_kind(obj)
				lsp_parse_caps(lsp, obj)
				lsp_send(editor, lsp, `{"jsonrpc":"2.0","method":"initialized","params":{}}`)
				lsp_send(editor, lsp, fmt.tprintf(`{{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{{"settings":{{"python":{{"analysis":{{"diagnosticMode":"%s"}}}},"basedpyright":{{"analysis":{{"diagnosticMode":"%s"}}}}}}}}}}`, LSP_DIAGNOSTIC_MODE, LSP_DIAGNOSTIC_MODE))
				return true
			}
			if p, has := lsp.pending[id]; has {
				delete_key(&lsp.pending, id)
				defer delete(p.path)
				return lsp_handle_response(editor, p, obj)
			}
		}
	}
	return false
}

lsp_config_for_section :: proc(section: string) -> string {
	switch section {
	case "python", "basedpyright", "pyright":
		return fmt.tprintf(`{{"analysis":{{"diagnosticMode":"%s"}}}}`, LSP_DIAGNOSTIC_MODE)
	case "python.analysis", "basedpyright.analysis", "pyright.analysis":
		return fmt.tprintf(`{{"diagnosticMode":"%s"}}`, LSP_DIAGNOSTIC_MODE)
	}
	return "null"
}

lsp_parse_caps :: proc(lsp: ^Lsp, obj: json.Object) {
	result := obj["result"].(json.Object) or_else nil
	caps := result["capabilities"].(json.Object) or_else nil
	lsp.cap_definition = lsp_cap_present(caps["definitionProvider"])
	lsp.cap_hover = lsp_cap_present(caps["hoverProvider"])
	lsp.cap_format = lsp_cap_present(caps["documentFormattingProvider"])
	lsp.cap_rename = lsp_cap_present(caps["renameProvider"])
	lsp.cap_completion = lsp_cap_present(caps["completionProvider"])
	clear(&lsp.completion_triggers)
	if comp, ok := caps["completionProvider"].(json.Object); ok {
		if tc, ok2 := comp["triggerCharacters"].(json.Array); ok2 {
			for t in tc {
				if s, ok3 := t.(string); ok3 && len(s) > 0 {
					append(&lsp.completion_triggers, s[0])
				}
			}
		}
	}
}

lsp_cap_present :: proc(v: json.Value) -> bool {
	#partial switch t in v {
	case json.Boolean:
		return bool(t)
	case json.Object:
		return true
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

lsp_ready :: proc(b: ^Buffer) -> (^Lsp, bool) {
	lsp, ok := lsp_for(b)
	if !ok || lsp.state != .Running || !lsp.initialized || !b.lsp_open {
		return nil, false
	}
	return lsp, true
}

lsp_ensure_synced :: proc(editor: ^Editor, b: ^Buffer) {
	if b.rev != b.lsp_rev {
		lsp_did_change(editor, b)
	}
}

lsp_pending_add :: proc(lsp: ^Lsp, kind: LspRequest, b: ^Buffer) -> int {
	lsp.next_id += 1
	id := lsp.next_id
	lsp.pending[id] = LspPending {
		kind = kind,
		path = strings.clone(b.path),
		rev  = b.rev,
	}
	return id
}

lsp_definition :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if LANGUAGES[b.language].lsp_server == "" {
		editor_set_message(editor, "No language server for this buffer", true)
		return
	}
	lsp, ok := lsp_ready(b)
	if !ok {
		editor_set_message(editor, "Language server not ready", true)
		return
	}
	if !lsp.cap_definition {
		editor_set_message(editor, "Server has no go-to-definition", true)
		return
	}
	lsp_ensure_synced(editor, b)
	id := lsp_pending_add(lsp, .Definition, b)
	ch := col_to_utf16(b.lines[b.cursor.row].text[:], b.cursor.col)
	lsp_send(
		editor,
		lsp,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"method":"textDocument/definition","params":{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}}}}}}`,
			id,
			lsp_json_string(lsp_uri(b.path)),
			b.cursor.row,
			ch,
		),
	)
}

lsp_hover :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if LANGUAGES[b.language].lsp_server == "" {
		editor_set_message(editor, "No language server for this buffer", true)
		return
	}
	lsp, ok := lsp_ready(b)
	if !ok {
		editor_set_message(editor, "Language server not ready", true)
		return
	}
	if !lsp.cap_hover {
		editor_set_message(editor, "Server has no hover", true)
		return
	}
	lsp_ensure_synced(editor, b)
	id := lsp_pending_add(lsp, .Hover, b)
	ch := col_to_utf16(b.lines[b.cursor.row].text[:], b.cursor.col)
	lsp_send(
		editor,
		lsp,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"method":"textDocument/hover","params":{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}}}}}}`,
			id,
			lsp_json_string(lsp_uri(b.path)),
			b.cursor.row,
			ch,
		),
	)
}

lsp_rename_ready :: proc(editor: ^Editor, b: ^Buffer) -> (^Lsp, bool) {
	if LANGUAGES[b.language].lsp_server == "" {
		editor_set_message(editor, "No language server for this buffer", true)
		return nil, false
	}
	lsp, ok := lsp_ready(b)
	if !ok {
		editor_set_message(editor, "Language server not ready", true)
		return nil, false
	}
	if !lsp.cap_rename {
		editor_set_message(editor, "Server has no rename", true)
		return nil, false
	}
	return lsp, true
}

lsp_rename_send :: proc(editor: ^Editor, new_name: string) {
	b := editor_buffer(editor)
	lsp, ok := lsp_rename_ready(editor, b)
	if !ok {
		return
	}
	lsp_ensure_synced(editor, b)
	id := lsp_pending_add(lsp, .Rename, b)
	ch := col_to_utf16(b.lines[b.cursor.row].text[:], b.cursor.col)
	lsp_send(
		editor,
		lsp,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"method":"textDocument/rename","params":{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}},"newName":%s}}}}`,
			id,
			lsp_json_string(lsp_uri(b.path)),
			b.cursor.row,
			ch,
			lsp_json_string(new_name),
		),
	)
}

lsp_apply_rename :: proc(editor: ^Editor, obj: json.Object) -> bool {
	result, ok := obj["result"].(json.Object)
	if !ok {
		editor_set_message(editor, "Cannot rename symbol", true)
		return true
	}
	files := 0
	total := 0
	touched_current := false
	tx := tx_next()
	apply :: proc(editor: ^Editor, uri: string, edits: json.Array, tx: int, files: ^int, touched_current: ^bool) {
		idx := editor_load_buffer(editor, lsp_uri_to_path(uri))
		if idx < 0 {
			return
		}
		if lsp_apply_text_edits(&editor.buffers[idx], edits, tx) {
			files^ += 1
			if idx == editor.current {
				touched_current^ = true
			}
		}
	}
	if changes, has := result["changes"].(json.Object); has {
		total = len(changes)
		for uri, v in changes {
			edits := v.(json.Array) or_continue
			apply(editor, uri, edits, tx, &files, &touched_current)
		}
	} else if doc_changes, has2 := result["documentChanges"].(json.Array); has2 {
		total = len(doc_changes)
		for item in doc_changes {
			dc := item.(json.Object) or_continue
			td := dc["textDocument"].(json.Object) or_continue
			uri := td["uri"].(string) or_continue
			edits := dc["edits"].(json.Array) or_continue
			apply(editor, uri, edits, tx, &files, &touched_current)
		}
	}
	if files == 0 {
		editor_set_message(editor, "No rename changes")
		return true
	}
	if touched_current {
		editor_scroll(editor)
	}
	if files < total {
		editor_set_message(editor, fmt.tprintf("Renamed in %d/%d files (rest unreadable)", files, total), true)
	} else {
		editor_set_message(editor, fmt.tprintf("Renamed in %d file%s", files, "" if files == 1 else "s"))
	}
	return true
}

lsp_format :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if LANGUAGES[b.language].lsp_server == "" {
		editor_set_message(editor, "No language server for this buffer", true)
		return
	}
	if !lsp_send_format(editor, b, .Format) {
		editor_set_message(editor, "Formatting not available", true)
	}
}

lsp_send_format :: proc(editor: ^Editor, b: ^Buffer, kind: LspRequest) -> bool {
	lsp, ok := lsp_ready(b)
	if !ok || !lsp.cap_format {
		return false
	}
	lsp_ensure_synced(editor, b)
	id := lsp_pending_add(lsp, kind, b)
	lsp_send(
		editor,
		lsp,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"method":"textDocument/formatting","params":{{"textDocument":{{"uri":%s}},"options":{{"tabSize":%d,"insertSpaces":%s}}}}}}`,
			id,
			lsp_json_string(lsp_uri(b.path)),
			b.indent_width,
			"true" if b.indent == .Spaces else "false",
		),
	)
	return true
}

lsp_handle_response :: proc(editor: ^Editor, p: LspPending, obj: json.Object) -> bool {
	if e, has := obj["error"].(json.Object); has {
		msg := e["message"].(string) or_else "request failed"
		editor_set_message(editor, fmt.tprintf("LSP: %s", msg), true)
		if p.kind == .FormatOnSave {
			editor_save_path(editor, p.path)
		}
		return true
	}
	switch p.kind {
	case .Definition:
		return lsp_apply_definition(editor, obj)
	case .Hover:
		return lsp_apply_hover(editor, obj)
	case .Format:
		return lsp_apply_format(editor, p, obj, false)
	case .FormatOnSave:
		return lsp_apply_format(editor, p, obj, true)
	case .Rename:
		return lsp_apply_rename(editor, obj)
	case .Completion:
		return completion_apply(editor, p, obj)
	}
	return false
}

lsp_definition_target :: proc(result: json.Value) -> (uri: string, rng: json.Object, ok: bool) {
	#partial switch r in result {
	case json.Object:
		if u, has := r["uri"].(string); has {
			return u, r["range"].(json.Object) or_else nil, true
		}
	case json.Array:
		if len(r) == 0 {
			return
		}
		first := r[0].(json.Object) or_return
		if u, has := first["uri"].(string); has {
			return u, first["range"].(json.Object) or_else nil, true
		}
		if u, has := first["targetUri"].(string); has {
			sel := first["targetSelectionRange"].(json.Object) or_else (first["targetRange"].(json.Object) or_else nil)
			return u, sel, true
		}
	}
	return
}

lsp_apply_definition :: proc(editor: ^Editor, obj: json.Object) -> bool {
	uri, rng, ok := lsp_definition_target(obj["result"])
	start, sok := rng["start"].(json.Object)
	if !ok || !sok {
		editor_set_message(editor, "No definition found")
		return true
	}
	path := lsp_uri_to_path(uri)
	line, _ := lsp_num(start["line"])
	ch, _ := lsp_num(start["character"])

	origin := jump_here(editor)
	editor_open_path(editor, path)
	b := editor_buffer(editor)
	row := clamp(line, 0, len(b.lines) - 1)
	col := col_from_utf16(b.lines[row].text[:], ch)
	b.selection = nil
	b.cursor = {row, col}
	cursor_goal_sync(b)
	_, h := editor_viewport(editor)
	editor.scroll_row = row - h / 2
	editor_scroll(editor)
	jump_record(editor, origin)
	return true
}

lsp_hover_contents :: proc(v: json.Value) -> string {
	#partial switch c in v {
	case json.String:
		return string(c)
	case json.Object:
		if val, ok := c["value"].(string); ok {
			return val
		}
	case json.Array:
		sb := strings.builder_make(context.temp_allocator)
		for e in c {
			part := lsp_hover_contents(e)
			if part == "" {
				continue
			}
			if strings.builder_len(sb) > 0 {
				strings.write_byte(&sb, '\n')
			}
			strings.write_string(&sb, part)
		}
		return strings.to_string(sb)
	}
	return ""
}

lsp_apply_hover :: proc(editor: ^Editor, obj: json.Object) -> bool {
	text := ""
	if result, has := obj["result"].(json.Object); has {
		text = lsp_hover_contents(result["contents"])
	}
	text = strings.trim_space(text)
	if text == "" {
		editor_set_message(editor, "No hover info")
		return true
	}
	clear(&editor.hover)
	append(&editor.hover, ..transmute([]u8)text)
	editor.hover_active = true
	return true
}

lsp_apply_format :: proc(editor: ^Editor, p: LspPending, obj: json.Object, save_after: bool) -> bool {
	idx := editor_find_buffer(editor, p.path)
	if idx < 0 {
		return false
	}
	b := &editor.buffers[idx]
	if b.rev != p.rev {
		if save_after {
			editor_save_path(editor, p.path)
		} else {
			editor_set_message(editor, "Format skipped: buffer changed", true)
		}
		return true
	}
	applied := false
	if edits, ok := obj["result"].(json.Array); ok && len(edits) > 0 {
		applied = lsp_apply_text_edits(b, edits)
	}
	if applied {
		b.cursor.row = clamp(b.cursor.row, 0, len(b.lines) - 1)
		b.cursor.col = clamp(b.cursor.col, 0, len(b.lines[b.cursor.row].text))
		b.selection = nil
		cursor_goal_sync(b)
		if b == editor_buffer(editor) {
			editor_scroll(editor)
		}
	}
	if save_after {
		editor_save_path(editor, p.path)
	} else if applied {
		editor_set_message(editor, "Formatted")
	} else {
		editor_set_message(editor, "No formatting changes")
	}
	return true
}

lsp_apply_text_edits :: proc(b: ^Buffer, edits: json.Array, tx: int = 0) -> bool {
	Ranged :: struct {
		from, to: Cursor,
		text:     string,
	}
	list := make([dynamic]Ranged, context.temp_allocator)
	for item in edits {
		e := item.(json.Object) or_continue
		r := e["range"].(json.Object) or_continue
		s := r["start"].(json.Object) or_continue
		en := r["end"].(json.Object) or_continue
		text := e["newText"].(string) or_else ""
		append(&list, Ranged{lsp_cursor(b, s), lsp_cursor(b, en), text})
	}
	if len(list) == 0 {
		return false
	}
	slice.sort_by(list[:], proc(a, b: Ranged) -> bool {
		if a.from.row != b.from.row {
			return a.from.row > b.from.row
		}
		return a.from.col > b.from.col
	})
	edit_open(b, .Atomic)
	for e in list {
		removed := buffer_delete(b, e.from, e.to)
		append(&b.open.edits, Edit{.Insert, e.from, removed})
		buffer_insert(b, e.from, e.text)
		append(&b.open.edits, Edit{.Delete, e.from, strings.clone(e.text)})
	}
	buffer_undo_commit(b)
	if tx != 0 && len(b.undo) > 0 {
		b.undo[len(b.undo) - 1].tx = tx
	}
	return true
}

cursor_before :: proc(a, b: Cursor) -> bool {
	return a.row < b.row || (a.row == b.row && a.col < b.col)
}

diag_goto :: proc(editor: ^Editor, dir: int) {
	b := editor_buffer(editor)
	if len(b.diags) == 0 {
		editor_set_message(editor, "No diagnostics")
		return
	}
	cur := b.cursor
	best, wrap: Cursor
	found, wrap_set := false, false
	for d in b.diags {
		s := d.from
		if dir > 0 {
			if !wrap_set || cursor_before(s, wrap) {
				wrap, wrap_set = s, true
			}
			if cursor_before(cur, s) && (!found || cursor_before(s, best)) {
				best, found = s, true
			}
		} else {
			if !wrap_set || cursor_before(wrap, s) {
				wrap, wrap_set = s, true
			}
			if cursor_before(s, cur) && (!found || cursor_before(best, s)) {
				best, found = s, true
			}
		}
	}
	target := best if found else wrap
	row := clamp(target.row, 0, len(b.lines) - 1)
	b.selection = nil
	b.cursor = {row, clamp(target.col, 0, len(b.lines[row].text))}
	cursor_goal_sync(b)
	editor_scroll(editor)
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
