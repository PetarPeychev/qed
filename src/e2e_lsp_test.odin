package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

// A minimal JSON-RPC-over-stdio LSP server in Python: it answers `initialize`
// (advertising incremental sync + hover/definition/rename/completion providers),
// publishes two canned diagnostics on didOpen/didChange, and returns canned
// hover / definition / rename (a WorkspaceEdit touching two files) / completion
// (one item carrying an auto-import `additionalTextEdits`) responses. The sibling
// file path is baked in by the harness so every canned URI is deterministic.
FAKE_LSP_BODY :: `
import sys, json

def read_msg():
    length = 0
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if line == b"":
            break
        if b":" in line:
            k, v = line.split(b":", 1)
            if k.strip().lower() == b"content-length":
                length = int(v.strip())
    data = b""
    while len(data) < length:
        chunk = sys.stdin.buffer.read(length - len(data))
        if not chunk:
            break
        data += chunk
    return json.loads(data.decode("utf-8"))

def send(obj):
    data = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: " + str(len(data)).encode("ascii") + b"\r\n\r\n")
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()

def reply(mid, result):
    send({"jsonrpc": "2.0", "id": mid, "result": result})

def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})

def publish(uri):
    notify("textDocument/publishDiagnostics", {
        "uri": uri,
        "diagnostics": [
            {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
             "severity": 2, "message": "fake warning on alpha"},
            {"range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 2}},
             "severity": 1, "message": "fake error on xy"},
        ],
    })

while True:
    msg = read_msg()
    if msg is None:
        break
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        sys.stderr.buffer.write(b"fake stderr line\n")
        sys.stderr.buffer.flush()
        reply(mid, {"capabilities": {
            "textDocumentSync": 2,
            "hoverProvider": True,
            "definitionProvider": True,
            "renameProvider": True,
            "documentFormattingProvider": True,
            "completionProvider": {"triggerCharacters": ["."]},
        }})
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        publish(msg["params"]["textDocument"]["uri"])
    elif method == "textDocument/hover":
        reply(mid, {"contents": {"kind": "markdown", "value": "hover: canned hover text"}})
    elif method == "textDocument/definition":
        uri = msg["params"]["textDocument"]["uri"]
        reply(mid, {"uri": uri, "range": {"start": {"line": 12, "character": 0},
                                          "end": {"line": 12, "character": 4}}})
    elif method == "textDocument/rename":
        uri = msg["params"]["textDocument"]["uri"]
        sib = "file://" + SIBLING
        reply(mid, {"changes": {
            uri: [{"range": {"start": {"line": 1, "character": 4}, "end": {"line": 1, "character": 10}},
                   "newText": "renamed"}],
            sib: [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 6}},
                   "newText": "renamed"}],
        }})
    elif method == "textDocument/formatting":
        reply(mid, [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
                     "newText": "formatted\n"}])
    elif method == "textDocument/completion":
        reply(mid, {"isIncomplete": False, "items": [
            {"label": "alphabet", "additionalTextEdits": [
                {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
                 "newText": "import added\n"}]},
            {"label": "alpine"},
            {"label": "beta"},
        ]})
    elif method == "shutdown":
        reply(mid, None)
    elif method == "exit":
        break
    elif mid is not None:
        reply(mid, None)
`

// Under e2e_lock a single session runs at a time, so these session-scoped globals
// (the fake server wired into LANGUAGES[.Plain], its command string) are exclusive.
@(private = "file")
g_fake_saved: LanguageInfo
@(private = "file")
g_fake_cmd: string

e2e_lsp_start :: proc(seed: string) -> E2E {
	e2e_enter()
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.aprintf("%s/qed_e2e_lsp_%d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(dir)

	main := fmt.aprintf("%s/main.txt", dir)
	defer delete(main)
	sibling := fmt.aprintf("%s/other.txt", dir)
	defer delete(sibling)
	_ = os.write_entire_file(main, transmute([]u8)seed)
	_ = os.write_entire_file(sibling, transmute([]u8)string("target here\nmore"))

	script := fmt.aprintf("%s/fake_lsp.py", dir)
	defer delete(script)
	src := strings.concatenate(
		{"SIBLING = ", lsp_json_string(sibling, context.temp_allocator), "\n", FAKE_LSP_BODY},
		context.temp_allocator,
	)
	_ = os.write_entire_file(script, transmute([]u8)src)

	g_fake_cmd = fmt.aprintf("python3 %s", script)
	g_fake_saved = LANGUAGES[.Plain]
	LANGUAGES[.Plain].lsp_server = g_fake_cmd
	LANGUAGES[.Plain].lsp_id = "plaintext"

	ed := editor_init(main, headless = true)
	return E2E{ed = ed, path = strings.clone(main), dir = dir}
}

// Restore LANGUAGES before e2e_stop unlocks (the running server keeps its own
// pointer into g_fake_cmd, so free it only after editor_shutdown tore it down).
e2e_lsp_stop :: proc(e: ^E2E) {
	LANGUAGES[.Plain] = g_fake_saved
	e2e_stop(e)
	delete(g_fake_cmd)
	g_fake_cmd = ""
}

// Pump the LSP transport until `pred` holds or the deadline passes, mirroring the
// main loop (lsp_sync drives lazy start → didOpen; completion_due fires the
// debounced request). A 1ms poll between reads yields the CPU to the child; the
// wall-clock deadline bounds it so a wedged server can never hang the suite.
e2e_lsp_wait :: proc(e: ^E2E, pred: proc(e: ^E2E) -> bool, timeout_ms := 5000) -> bool {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(timeout_ms) {
		lsp_sync(&e.ed)
		lsp_pump(&e.ed)
		if completion_due(&e.ed) {
			e.ed.completion.want = false
			completion_request(&e.ed)
		}
		if pred(e) {
			return true
		}
		time.sleep(time.Millisecond)
	}
	lsp_pump(&e.ed)
	return pred(e)
}

@(private = "file")
pred_diags :: proc(e: ^E2E) -> bool {return len(editor_buffer(&e.ed).diags) > 0}
@(private = "file")
pred_completion :: proc(e: ^E2E) -> bool {return e.ed.completion.active}
@(private = "file")
pred_hover :: proc(e: ^E2E) -> bool {return e.ed.hover_active}
@(private = "file")
pred_two_buffers :: proc(e: ^E2E) -> bool {return len(e.ed.buffers) >= 2}
@(private = "file")
pred_def_jump :: proc(e: ^E2E) -> bool {return editor_buffer(&e.ed).cursor.row == 12}
@(private = "file")
pred_quit :: proc(e: ^E2E) -> bool {return e.ed.quit}
@(private = "file")
pred_stderr :: proc(e: ^E2E) -> bool {
	for entry in e.ed.log {
		if entry.level == .Debug && entry.source == "LSP" && strings.contains(entry.text, "fake stderr line") {
			return true
		}
	}
	return false
}

e2e_alt :: proc(e: ^E2E, ch: rune) {
	e2e_step(e, tb2.Event{type = .Key, mod = .Alt, ch = ch})
}

e2e_grid_has :: proc(e: ^E2E, needle: string) -> bool {
	for y in 0 ..< int(tb2.height()) {
		sb := strings.builder_make(context.temp_allocator)
		for x in 0 ..< int(tb2.width()) {
			r := e2e_cell(e, x, y)
			strings.write_rune(&sb, r if r != 0 else ' ')
		}
		if strings.contains(strings.to_string(sb), needle) {
			return true
		}
	}
	return false
}

first_rune :: proc(s: string) -> rune {
	r, _ := utf8.decode_rune(s)
	return r
}

@(test)
e2e_lsp_diagnostics :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("alpha beta\nmiddle\nxyzzy")
	defer e2e_lsp_stop(&e)

	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "diagnostics should arrive")
	b := editor_buffer(&e.ed)
	testing.expect_value(t, len(b.diags), 2)

	e2e_render(&e)
	g := editor_gutter_width(&e.ed)

	// Underline attr on the diagnostic range ("alpha", cols 0..5 on row 0).
	warn := e2e_cell_raw(&e, g + 0, 0)
	testing.expect_value(t, rune(warn.ch), 'a')
	testing.expect(t, (u64(warn.fg) & u64(tb2.Color.Underline)) != 0, "row 0 diag range is underlined")

	// Gutter severity glyph: warning on row 0, error on row 2.
	testing.expect_value(t, e2e_cell(&e, g - 1, 0), first_rune(diagnostic_glyph(2)))
	testing.expect_value(t, e2e_cell(&e, g - 1, 2), first_rune(diagnostic_glyph(1)))

	// Next/prev-diagnostic move the cursor onto the diagnostic anchors.
	b.cursor = {1, 0}
	e2e_alt(&e, '>')
	testing.expect_value(t, editor_buffer(&e.ed).cursor.row, 2)

	b.cursor = {1, 0}
	e2e_alt(&e, '<')
	testing.expect_value(t, editor_buffer(&e.ed).cursor.row, 0)
}

@(test)
e2e_lsp_hover :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("alpha beta\nmiddle\nxyzzy")
	defer e2e_lsp_stop(&e)

	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "server should be ready")
	b := editor_buffer(&e.ed)
	b.cursor = {1, 0}

	e2e_alt(&e, 's')
	testing.expect(t, e2e_lsp_wait(&e, pred_hover), "hover response should arrive")
	testing.expect(t, strings.contains(string(e.ed.hover[:]), "canned hover text"), "hover text stored")

	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "canned"), "hover popup renders the canned text")
}

@(test)
e2e_lsp_definition :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	// 15 lines so the canned target (line 12) is a real jump (> jump_threshold).
	e := e2e_lsp_start("alpha beta\nmiddle\nxyzzy\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\ntarget\nl13\nl14")
	defer e2e_lsp_stop(&e)

	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "server should be ready")
	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	e2e_alt(&e, 'd')
	testing.expect(t, e2e_lsp_wait(&e, pred_def_jump), "cursor jumps to the canned definition")
	testing.expect_value(t, editor_buffer(&e.ed).cursor.row, 12)

	// The jump pushed a back entry; back returns to the origin.
	jump_back(&e.ed)
	testing.expect_value(t, editor_buffer(&e.ed).cursor.row, 0)
}

@(test)
e2e_lsp_completion :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("top\n")
	defer e2e_lsp_stop(&e)

	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "server should be ready")
	b := editor_buffer(&e.ed)
	b.cursor = {1, 0}

	e2e_type(&e, "al")
	testing.expect(t, e2e_lsp_wait(&e, pred_completion), "completion popup should open")

	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "alphabet"), "popup shows the canned item")
	testing.expect(t, !e2e_grid_has(&e, "beta"), "popup is filtered by the 'al' prefix")

	// Tab accepts: the current word becomes "alphabet" AND the auto-import edit
	// lands at the top of the file, both in one undo group.
	e2e_key(&e, .Tab)
	b = editor_buffer(&e.ed)
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, string(b.lines[0].text[:]), "import added")
	testing.expect_value(t, string(b.lines[2].text[:]), "alphabet")
	testing.expect_value(t, b.cursor.row, 2)

	e2e_key(&e, .Ctrl_Z)
	b = editor_buffer(&e.ed)
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, string(b.lines[0].text[:]), "top")
}

@(test)
e2e_lsp_format_on_save_quit :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("alpha beta  \nmiddle\nxyzzy")
	defer e2e_lsp_stop(&e)

	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "server should be ready")
	e.ed.format_on_save = true
	e.ed.trim_trailing_whitespace_on_save = true

	e2e_type(&e, "Z")
	e2e_key(&e, .Ctrl_Q)
	testing.expect(t, e.ed.quit_dialog.active, "Ctrl+Q on a modified buffer opens the quit dialog")
	e2e_key(&e, .Enter)

	// The format request is in flight: quit must wait for the chained save.
	testing.expect(t, !e.ed.quit, "quit is deferred while the format response is pending")
	testing.expect_value(t, e.ed.save_intent, SaveIntent.Quit)

	testing.expect(t, e2e_lsp_wait(&e, pred_quit), "quit follows the chained format+save")
	testing.expect_value(t, e2e_read_disk(e.path), "formatted\nZalpha beta\nmiddle\nxyzzy")
	testing.expect_value(t, editor_buffer(&e.ed).modified, false)
}

@(test)
e2e_lsp_status_segment :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("alpha beta\nmiddle\nxyzzy")
	defer e2e_lsp_stop(&e)
	b := editor_buffer(&e.ed)

	// No server spawned yet: the segment reads as starting (dim + ellipsis glyph).
	txt, fg, ok := lsp_status_label(b)
	testing.expect(t, ok, "a configured server yields a segment")
	testing.expect(t, strings.contains(txt, ICON_LSP_STARTING), "starting glyph before spawn")
	testing.expect_value(t, fg, COLOR_PANE_SHORTCUT_FG)

	// One sync spawns the server but nothing pumps the initialize response yet.
	lsp_sync(&e.ed)
	txt, fg, ok = lsp_status_label(b)
	testing.expect(t, strings.contains(txt, ICON_LSP_STARTING), "starting glyph while awaiting initialize")
	testing.expect_value(t, fg, COLOR_PANE_SHORTCUT_FG)

	// Once diagnostics arrive the server has initialized: plain name, no glyph.
	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "server should become ready")
	txt, fg, ok = lsp_status_label(b)
	testing.expect(t, !strings.contains(txt, ICON_LSP_STARTING), "no starting glyph once ready")
	testing.expect(t, !strings.contains(txt, ICON_LSP_FAILED), "not failed once ready")
	testing.expect_value(t, fg, COLOR_PANE_FG)
}

@(test)
e2e_lsp_stderr_log :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("alpha beta\nmiddle\nxyzzy")
	defer e2e_lsp_stop(&e)

	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "server should be ready")
	testing.expect(t, e2e_lsp_wait(&e, pred_stderr), "stderr line lands in the ring as Debug source LSP")
}

@(test)
e2e_lsp_rename_cross_file :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("alpha beta\ndef target\nxyzzy")
	defer e2e_lsp_stop(&e)

	testing.expect(t, e2e_lsp_wait(&e, pred_diags), "server should be ready")
	b := editor_buffer(&e.ed)
	b.cursor = {1, 4}

	e2e_alt(&e, 'r')
	testing.expect(t, e.ed.rename.active, "Alt+r opens the rename box")
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "renamed")
	e2e_key(&e, .Enter)

	testing.expect(t, e2e_lsp_wait(&e, pred_two_buffers), "rename loads the sibling file")

	main := &e.ed.buffers[0]
	testing.expect_value(t, string(main.lines[1].text[:]), "def renamed")

	sib := -1
	for &bb, i in e.ed.buffers {
		if strings.has_suffix(bb.path, "other.txt") {
			sib = i
		}
	}
	testing.expect(t, sib >= 0, "sibling buffer is loaded")
	testing.expect_value(t, string(e.ed.buffers[sib].lines[0].text[:]), "renamed here")
	testing.expect(t, e.ed.buffers[sib].modified, "sibling buffer is modified")

	// One undo reverts the whole cross-buffer rename transaction.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(e.ed.buffers[0].lines[1].text[:]), "def target")
	testing.expect_value(t, string(e.ed.buffers[sib].lines[0].text[:]), "target here")
}
