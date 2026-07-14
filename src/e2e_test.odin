package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "lib:pty"
import "lib:tb2"

// End-to-end harness: drives the real Editor headless. termbox is brought up on
// a fixed-size (80×24) PTS with no controlling tty, synthetic tb2.Events are fed
// straight to editor_dispatch, and editor_render draws into termbox's back buffer
// — which we read back cell-by-cell. So a test exercises event → dispatch → action
// → render and can assert on both buffer state and what actually lands on screen.
//
// termbox is a process-global singleton the multi-threaded test runner shares, and
// it does not survive repeated init_fd/shutdown cycles — so the backend is brought
// up exactly once (e2e_once) for the whole process and never torn down, while a
// mutex serializes e2e sessions against each other.
E2E_W :: 80
E2E_H :: 24

e2e_lock: sync.Mutex
e2e_once: sync.Once
e2e_seq: int
e2e_slave: int
e2e_peek_events: [8]tb2.Event
e2e_peek_pos, e2e_peek_len: int

E2E :: struct {
	ed:      Editor,
	path:    string,
	dir:     string, // scratch dir (git fixture); removed recursively on stop
	resized: bool,   // restore the shared 80×24 backend on stop
}

e2e_backend_init :: proc() {
	master, slave, ok := pty.open(E2E_H, E2E_W)
	assert(ok, "pty.open failed")
	// Nothing consumes the terminal output; a background thread drains the master
	// so a large frame (truecolor SGR per cell) never blocks tb2.present on a full
	// pty buffer. It runs for the process lifetime (never joined) — non-blocking so
	// it can't wedge on a read after the process winds down.
	flags := posix.fcntl(posix.FD(master), .GETFL)
	posix.fcntl(posix.FD(master), .SETFL, flags | transmute(i32)posix.O_Flags{.NONBLOCK})
	thread.create_and_start_with_poly_data(master, proc(fd: int) {
		buf: [4096]u8
		for {
			for posix.read(posix.FD(fd), &buf[0], len(buf)) > 0 {}
			thread.yield()
		}
	})
	e2e_slave = slave
	// CI runners leave TERM unset or `dumb`, which termbox2 can't map to any
	// terminfo/builtin caps — init_fd then fails and the back buffer we read
	// back stays blank. Force an xterm-family value (builtin caps, terminfo or
	// not) so read-back works regardless of the runner's environment.
	posix.setenv("TERM", "xterm-256color", true)
	assert(tb2.init_fd(i32(slave)) == .Ok, "tb2.init_fd failed")
	tb2.set_output_mode(.Truecolor)
	tb2.set_input_mode(.Mouse)
}

e2e_enter :: proc() {
	sync.mutex_lock(&e2e_lock)
	sync.once_do(&e2e_once, e2e_backend_init)
	// Config defaults are already seeded by the @(init) config_seed_defaults;
	// re-applying here would race settings_test's global mutations.
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	tb2.clear()
}

// Open the editor on a real file seeded with `content`, exactly as `qed FILE`
// would — the only way a session actually reaches an editable buffer. A `.txt`
// name keeps it plaintext (no LSP / tree-sitter spawns), so tests stay hermetic.
e2e_start :: proc(content := "") -> E2E {
	e2e_enter()

	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_%d_%d.txt", tmp, posix.getpid(), e2e_seq)
	_ = os.write_entire_file(path, transmute([]u8)content)

	ed := editor_init(path, headless = true)
	return E2E{ed = ed, path = path}
}

e2e_stop :: proc(e: ^E2E) {
	editor_shutdown(&e.ed)
	if e.resized {
		e2e_apply_size(E2E_W, E2E_H)
	}
	os.remove(e.path)
	delete(e.path)
	if e.dir != "" {
		e2e_run(fmt.tprintf("rm -rf %s", shell_quote(e.dir)))
		delete(e.dir)
	}
	sync.mutex_unlock(&e2e_lock)
}

e2e_key :: proc(e: ^E2E, key: tb2.Key, mod: tb2.Mod = {}, ch: rune = 0) {
	e2e_step(e, tb2.Event{type = .Key, key = key, mod = mod, ch = ch})
}

// Drive the real main-loop body (main.odin editor_step). `following` seeds the
// synthetic peek queue so the bare-Esc ALT retag can be exercised headlessly.
e2e_step :: proc(e: ^E2E, ev: tb2.Event, following: ..tb2.Event) {
	e2e_peek_pos = 0
	e2e_peek_len = len(following)
	for f, i in following {
		e2e_peek_events[i] = f
	}
	editor_step(&e.ed, ev, e2e_peek)
}

e2e_peek :: proc(ms: int) -> (tb2.Event, bool) {
	if e2e_peek_pos >= e2e_peek_len {
		return {}, false
	}
	ev := e2e_peek_events[e2e_peek_pos]
	e2e_peek_pos += 1
	return ev, true
}

e2e_mouse :: proc(e: ^E2E, x, y: int, button: tb2.Key = .Mouse_Left, motion := false, mod: tb2.Mod = {}) {
	m := mod
	if motion {
		m = tb2.Mod(u8(m) | u8(tb2.Mod.Motion))
	}
	editor_dispatch(&e.ed, tb2.Event{type = .Mouse, key = button, x = i32(x), y = i32(y), mod = m})
}

// Bracketed paste: the same Paste_Begin / keys / Paste_End the real terminal
// emits, routed through editor_step (the main-loop body) exactly like input.
e2e_paste :: proc(e: ^E2E, text: string) {
	e2e_step(e, tb2.Event{type = .Paste_Begin})
	for r in text {
		switch r {
		case '\n':
			e2e_step(e, tb2.Event{type = .Key, key = .Enter})
		case '\t':
			e2e_step(e, tb2.Event{type = .Key, key = .Tab})
		case:
			e2e_step(e, tb2.Event{type = .Key, ch = r})
		}
	}
	e2e_step(e, tb2.Event{type = .Paste_End})
}

// termbox caches its size and only re-reads it on a SIGWINCH-driven resize event.
// Resize the shared PTS, raise SIGWINCH on this thread so termbox re-reads +
// re-fits its cellbufs, then hand the editor a Resize event. e2e_stop restores
// 80×24 so later sessions (the backend is a process singleton) are unaffected.
e2e_resize :: proc(e: ^E2E, w, h: int) {
	e2e_apply_size(w, h)
	e.resized = true
	editor_dispatch(&e.ed, tb2.Event{type = .Resize, w = i32(w), h = i32(h)})
}

e2e_apply_size :: proc(w, h: int) {
	pty.resize(e2e_slave, h, w)
	posix.pthread_kill(posix.pthread_self(), posix.Signal(posix.SIGWINCH))
	ev: tb2.Event
	tb2.peek_event(&ev, 1000)
}

e2e_run :: proc(cmd: string) -> bool {
	c := strings.clone_to_cstring(cmd, context.temp_allocator)
	stream := popen(c, "r")
	if stream == nil {
		return false
	}
	buf: [1024]u8
	for fread(&buf[0], 1, len(buf), stream) > 0 {}
	return pclose(stream) == 0
}

// A scratch git repo with `seed` committed as `name`, opened through the real
// `qed FILE` entry path so git-gutter / diff-view / file-tree consumers see a
// live worktree-vs-HEAD diff. e2e_stop removes the repo dir.
e2e_git_start :: proc(seed: string, name := "file.txt") -> E2E {
	e2e_enter()
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.aprintf("%s/qed_e2e_git_%d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(dir)
	file := fmt.aprintf("%s/%s", dir, name)
	_ = os.write_entire_file(file, transmute([]u8)seed)
	e2e_run(
		fmt.tprintf(
			"cd %s && git init -q && git config user.email e2e@qed.test && git config user.name qed && git config commit.gpgsign false && git add %s && git commit -q -m seed",
			shell_quote(dir),
			shell_quote(name),
		),
	)
	ed := editor_init(file, headless = true)
	return E2E{ed = ed, path = file, dir = dir}
}

// Writes an executable `#!/bin/sh` stub with `body` (canned output or a
// stdin→stdout filter) to a temp path, for wiring into config `llm.chat_command`,
// a language `formatter`, or the FIM curl command. Caller frees the returned path.
e2e_stub_script :: proc(body: string) -> string {
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_stub_%d_%d.sh", tmp, posix.getpid(), e2e_seq)
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("#!/bin/sh\n%s\n", body))
	e2e_run(fmt.tprintf("chmod +x %s", shell_quote(path)))
	return path
}

e2e_type :: proc(e: ^E2E, s: string) {
	for r in s {
		if r == '\n' {
			e2e_key(e, .Enter)
		} else {
			editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = r})
		}
	}
	if filetree_filter_pending(&e.ed) {
		filetree_filter_flush(&e.ed)
	}
}

e2e_render :: proc(e: ^E2E) {
	editor_render(&e.ed)
}

e2e_cell_raw :: proc(e: ^E2E, x, y: int) -> tb2.Cell_Raw {
	cell: ^tb2.Cell_Raw
	if tb2.get_cell(i32(x), i32(y), 1, &cell) != .Ok {
		return {}
	}
	return cell^
}

e2e_cell :: proc(e: ^E2E, x, y: int) -> rune {
	return rune(e2e_cell_raw(e, x, y).ch)
}

e2e_cell_fg :: proc(e: ^E2E, x, y: int) -> tb2.Color {
	return e2e_cell_raw(e, x, y).fg
}

e2e_cell_bg :: proc(e: ^E2E, x, y: int) -> tb2.Color {
	return e2e_cell_raw(e, x, y).bg
}

e2e_rgb :: proc(c: tb2.Color) -> u64 {
	return u64(c) & COLOR_RGB_MASK
}

@(test)
e2e_type_and_edit :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	e2e_type(&e, "hello")
	b := editor_buffer(&e.ed)
	testing.expect_value(t, string(b.lines[0].text[:]), "hello")
	testing.expect_value(t, b.cursor.col, 5)

	// The physical Backspace key sends 0x7f (.Backspace2); 0x08 (.Backspace) is
	// Ctrl+H, which qed binds to find-replace.
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, string(b.lines[0].text[:]), "hell")

	e2e_type(&e, "\nworld")
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, string(b.lines[1].text[:]), "world")

	// The text must actually reach the screen, past the gutter.
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	testing.expect_value(t, e2e_cell(&e, gutter + 0, 0), 'h')
	testing.expect_value(t, e2e_cell(&e, gutter + 3, 0), 'l')
	testing.expect_value(t, e2e_cell(&e, gutter + 0, 1), 'w')
}

@(test)
e2e_find_flow :: proc(t: ^testing.T) {
	e := e2e_start("foo\nbar\nfoo")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	e2e_key(&e, .Ctrl_F)
	testing.expect(t, e.ed.find.active, "Ctrl+F should open find")

	e2e_type(&e, "foo")
	e2e_key(&e, .Enter)
	// Wrap from row 0 lands the cursor on the next match (row 2).
	testing.expect_value(t, b.cursor.row, 2)
}

@(test)
e2e_mouse_click_and_word :: proc(t: ^testing.T) {
	e := e2e_start("hello world")
	defer e2e_stop(&e)
	e2e_render(&e)

	b := editor_buffer(&e.ed)
	gutter := editor_gutter_width(&e.ed)

	// A single click lands the cursor at that screen cell.
	e2e_mouse(&e, gutter + 6, 0)
	testing.expect_value(t, b.cursor.row, 0)
	testing.expect_value(t, b.cursor.col, 6)
	testing.expect(t, !selection_active(b), "single click should not select")

	// A second click at the same cell (same thread → within DOUBLE_CLICK_MS)
	// selects the word under it.
	e2e_mouse(&e, gutter + 6, 0)
	testing.expect(t, selection_active(b), "double click should select the word")
	from, _, _ := selection_range(b)
	testing.expect_value(t, from.col, 6)
	testing.expect_value(t, b.cursor.col, 11)
}

@(test)
e2e_paste_buffer_and_overlay :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_paste(&e, "one\ntwo\nthree")
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, string(b.lines[2].text[:]), "three")

	// A paste is a single undo group: one Ctrl+Z clears it whole.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, len(b.lines), 1)
	testing.expect_value(t, string(b.lines[0].text[:]), "")

	// Into an overlay text field a multi-line paste flattens to one line.
	e2e_key(&e, .Ctrl_F)
	testing.expect(t, e.ed.find.active, "Ctrl+F should open find")
	e2e_paste(&e, "a\nb\nc")
	testing.expect_value(t, textfield_str(&e.ed.find.field), "a b c")
}

@(test)
e2e_resize_rewraps :: proc(t: ^testing.T) {
	e := e2e_start("wordone wordtwo wordthree wordfour wordfive\ntail")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect(t, b.wrap, "line wrap is on by default")
	gutter := editor_gutter_width(&e.ed)

	// At full width the long line fits one row, so "tail" is the second row.
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, gutter, 0), 'w')
	testing.expect_value(t, e2e_cell(&e, gutter, 1), 't')

	// Narrowing forces the long line to wrap, pushing "tail" further down.
	e2e_resize(&e, 20, E2E_H)
	testing.expect_value(t, int(tb2.width()), 20)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, gutter, 0), 'w')
	testing.expect(t, e2e_cell(&e, gutter, 1) != 't', "long line should now occupy row 1")
}

@(test)
e2e_git_gutter_mark :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("line one\nline two\nline three\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	// Editing a committed line marks it modified in the gutter (computed in render).
	b.cursor = {1, len(b.lines[1].text)}
	e2e_type(&e, "X")
	e2e_render(&e)
	testing.expect_value(t, git_mark_at(b, 1), GitMark.Modified)
	testing.expect_value(t, git_mark_at(b, 0), GitMark.None)
}

@(test)
e2e_stub_formatter :: proc(t: ^testing.T) {
	e := e2e_start("hello\nworld")
	defer e2e_stop(&e)

	stub := e2e_stub_script("tr 'a-z' 'A-Z'")
	defer {
		os.remove(stub)
		delete(stub)
	}

	b := editor_buffer(&e.ed)
	old := LANGUAGES[.Plain].formatter
	LANGUAGES[.Plain].formatter = stub
	defer LANGUAGES[.Plain].formatter = old

	format_document(&e.ed)
	testing.expect_value(t, string(b.lines[0].text[:]), "HELLO")
	testing.expect_value(t, string(b.lines[1].text[:]), "WORLD")

	// The whole format is one undo group.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "hello")
}

@(test)
e2e_alt_esc_retag :: proc(t: ^testing.T) {
	e := e2e_start("first\nsecond")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {0, 0}

	// A bare Esc followed by a printable within the ALT window dispatches as
	// Alt+<char>: Alt+} is Go to End of File.
	e2e_step(&e, tb2.Event{type = .Key, key = .Esc}, tb2.Event{type = .Key, ch = '}'})
	testing.expect_value(t, b.cursor.row, 1)
	testing.expect_value(t, b.cursor.col, len(b.lines[1].text))
}
