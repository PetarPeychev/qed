package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "lib:tb2"

// Files-coverage e2e sessions. Some cases need a starting condition e2e_start
// can't produce (a path that doesn't exist yet, or a pre-existing executable
// seed), so this mirrors e2e_start with those knobs; e2e_stop tears it down.
e2e_files_start :: proc(content: string, create := true, mode := os.Permissions{}) -> E2E {
	sync.mutex_lock(&e2e_lock)
	sync.once_do(&e2e_once, e2e_backend_init)
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	tb2.clear()

	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_files_%d_%d.txt", tmp, posix.getpid(), e2e_seq)
	if create {
		_ = os.write_entire_file(path, transmute([]u8)content)
		if mode != {} {
			_ = os.chmod(path, mode)
		}
	}

	ed := editor_init(path, headless = true)
	return E2E{ed = ed, path = path}
}

e2e_read_disk :: proc(path: string) -> string {
	data, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data)
}

@(test)
e2e_files_save_roundtrip_lf :: proc(t: ^testing.T) {
	e := e2e_start("hello\nworld\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect_value(t, b.line_ending, LineEnding.LF)
	testing.expect_value(t, len(b.lines), 3) // trailing newline is a real empty last line

	e2e_type(&e, "X")
	e2e_key(&e, .Ctrl_S)

	testing.expect_value(t, b.modified, false)
	testing.expect_value(t, e2e_read_disk(e.path), "Xhello\nworld\n")
}

@(test)
e2e_files_save_roundtrip_crlf :: proc(t: ^testing.T) {
	e := e2e_start("hello\r\nworld\r\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect_value(t, b.line_ending, LineEnding.CRLF)

	e2e_type(&e, "X")
	e2e_key(&e, .Ctrl_S)

	testing.expect_value(t, b.modified, false)
	testing.expect_value(t, e2e_read_disk(e.path), "Xhello\r\nworld\r\n")
}

@(test)
e2e_files_save_creates_missing :: proc(t: ^testing.T) {
	e := e2e_files_start("", create = false)
	defer e2e_stop(&e)

	testing.expect(t, !os.exists(e.path), "seed file should not exist yet")

	b := editor_buffer(&e.ed)
	testing.expect_value(t, len(b.lines), 1)

	e2e_type(&e, "line1\nline2")
	e2e_key(&e, .Ctrl_S)

	testing.expect(t, os.exists(e.path), "save should create the file")
	testing.expect_value(t, e2e_read_disk(e.path), "line1\nline2")
}

@(test)
e2e_files_save_preserves_mode :: proc(t: ^testing.T) {
	e := e2e_files_start("#!/bin/sh\necho hi\n", mode = os.perm(0o755))
	defer e2e_stop(&e)

	e2e_type(&e, "X")
	e2e_key(&e, .Ctrl_S)

	fi, err := os.stat(e.path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, .Execute_User in fi.mode, "saved file should stay executable")
}

@(test)
e2e_files_external_clean_reload :: proc(t: ^testing.T) {
	e := e2e_start("aaa\nbbb\nccc\nddd\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.cursor = {3, 3}

	// A shorter rewrite changes the size, so the poll notices even inside one second.
	_ = os.write_entire_file_from_string(e.path, "xy\n")
	editor_poll_disk(&e.ed)

	testing.expect_value(t, b.modified, false)
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, string(b.lines[0].text[:]), "xy")
	testing.expect_value(t, b.cursor.row, 1) // clamped from row 3
	testing.expect_value(t, b.cursor.col, 0) // clamped from col 3
}

@(test)
e2e_files_conflict_cancel :: proc(t: ^testing.T) {
	e := e2e_start("first line\nsecond line\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	_ = os.write_entire_file_from_string(e.path, "DISK\n")
	editor_poll_disk(&e.ed)
	testing.expect(t, b.disk_conflict, "poll should flag the conflict on a dirty buffer")

	e2e_key(&e, .Ctrl_S)
	testing.expect(t, e.ed.conflict_dialog.active, "Ctrl+S should open the conflict dialog")

	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.conflict_dialog.active, "Esc cancels the dialog")
	testing.expect(t, b.modified, "buffer keeps its unsaved edit")
	testing.expect_value(t, string(b.lines[0].text[:]), "Xfirst line")
	testing.expect_value(t, e2e_read_disk(e.path), "DISK\n") // nothing written
}

@(test)
e2e_files_conflict_overwrite :: proc(t: ^testing.T) {
	e := e2e_start("first line\nsecond line\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	_ = os.write_entire_file_from_string(e.path, "DISK\n")
	editor_poll_disk(&e.ed)

	e2e_key(&e, .Ctrl_S)
	e2e_key(&e, .Arrow_Down) // Cancel -> Overwrite
	e2e_key(&e, .Enter)

	testing.expect(t, !e.ed.conflict_dialog.active, "dialog closes after choosing")
	testing.expect_value(t, b.modified, false)
	testing.expect_value(t, e2e_read_disk(e.path), "Xfirst line\nsecond line\n") // buffer wins
}

@(test)
e2e_files_conflict_reload :: proc(t: ^testing.T) {
	e := e2e_start("first line\nsecond line\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	_ = os.write_entire_file_from_string(e.path, "DISK\n")
	editor_poll_disk(&e.ed)

	e2e_key(&e, .Ctrl_S)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down) // Cancel -> Overwrite -> Reload
	e2e_key(&e, .Enter)

	testing.expect(t, !e.ed.conflict_dialog.active, "dialog closes after choosing")
	testing.expect_value(t, b.modified, false)
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, string(b.lines[0].text[:]), "DISK") // disk wins in the buffer
	testing.expect_value(t, e2e_read_disk(e.path), "DISK\n")
}

@(test)
e2e_files_big :: proc(t: ^testing.T) {
	big := strings.repeat("qed big file test line\n", 100000) // ~2.3 MB > BIG_FILE_BYTES
	e := e2e_start(big)
	delete(big)
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect(t, b.big, "a >= 2 MB file opens with big set")
	testing.expect(t, b.hl.tree == nil, "highlight is skipped for a big buffer")

	e2e_type(&e, "X")
	testing.expect_value(t, string(b.lines[0].text[:2]), "Xq")

	// Rendering a big buffer still works (highlight/git gated off, not crashing).
	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	testing.expect_value(t, e2e_cell(&e, gutter + 0, 0), 'X')
}
