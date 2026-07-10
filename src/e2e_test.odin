package main

import "core:fmt"
import "core:os"
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

E2E :: struct {
	ed:   Editor,
	path: string,
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
	tb2.init_fd(i32(slave))
	tb2.set_output_mode(.Truecolor)
	tb2.set_input_mode(.Mouse)
}

// Open the editor on a real file seeded with `content`, exactly as `qed FILE`
// would — the only way a session actually reaches an editable buffer. A `.txt`
// name keeps it plaintext (no LSP / tree-sitter spawns), so tests stay hermetic.
e2e_start :: proc(content := "") -> E2E {
	sync.mutex_lock(&e2e_lock)
	sync.once_do(&e2e_once, e2e_backend_init)
	// Config defaults are already seeded by the @(init) config_seed_defaults;
	// re-applying here would race settings_test's global mutations.
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	tb2.clear()

	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_%d_%d.txt", tmp, posix.getpid(), e2e_seq)
	_ = os.write_entire_file(path, transmute([]u8)content)

	ed := editor_init(path, headless = true)
	return E2E{ed = ed, path = path}
}

e2e_stop :: proc(e: ^E2E) {
	editor_shutdown(&e.ed)
	os.remove(e.path)
	delete(e.path)
	sync.mutex_unlock(&e2e_lock)
}

e2e_key :: proc(e: ^E2E, key: tb2.Key, mod: tb2.Mod = {}, ch: rune = 0) {
	editor_dispatch(&e.ed, tb2.Event{type = .Key, key = key, mod = mod, ch = ch})
}

e2e_type :: proc(e: ^E2E, s: string) {
	for r in s {
		if r == '\n' {
			e2e_key(e, .Enter)
		} else {
			editor_dispatch(&e.ed, tb2.Event{type = .Key, ch = r})
		}
	}
}

e2e_render :: proc(e: ^E2E) {
	editor_render(&e.ed)
}

e2e_cell :: proc(e: ^E2E, x, y: int) -> rune {
	cell: ^tb2.Cell_Raw
	if tb2.get_cell(i32(x), i32(y), 1, &cell) != .Ok {
		return 0
	}
	return rune(cell.ch)
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
