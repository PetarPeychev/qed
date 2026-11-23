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
e2e_files_start :: proc(content: string, create := true, mode := Maybe(os.Permissions){}) -> E2E {
	sync.mutex_lock(&e2e_lock)
	sync.once_do(&e2e_once, e2e_backend_init)
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	tb2.clear()

	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_files_%d_%d.txt", tmp, posix.getpid(), e2e_seq)
	if create {
		_ = os.write_entire_file(path, transmute([]u8)content)
		if m, has := mode.?; has {
			_ = os.chmod(path, m)
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
e2e_files_open_unreadable_errors :: proc(t: ^testing.T) {
	if posix.geteuid() == 0 {
		return // chmod 000 cannot block root
	}
	e := e2e_start("base content")
	defer e2e_stop(&e)

	tmp, _ := os.temp_dir(context.temp_allocator)
	locked := fmt.tprintf("%s/qed_e2e_locked_%d.txt", tmp, posix.getpid())
	_ = os.write_entire_file(locked, transmute([]u8)string("secret"))
	_ = os.chmod(locked, os.perm(0o000))
	defer os.remove(locked)

	before := e.ed.current
	nbuf := len(e.ed.buffers)
	testing.expect(t, !editor_open_path(&e.ed, locked), "unreadable file must fail to open")
	testing.expect(t, strings.contains(e.ed.message, "Cannot open"), "error lands on the message line")
	testing.expect_value(t, e.ed.message_level, LogLevel.Error)
	testing.expect_value(t, e.ed.current, before)
	testing.expect_value(t, len(e.ed.buffers), nbuf)
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "base content")
}

@(test)
e2e_files_open_missing_still_empty :: proc(t: ^testing.T) {
	e := e2e_start("base content")
	defer e2e_stop(&e)

	tmp, _ := os.temp_dir(context.temp_allocator)
	missing := fmt.tprintf("%s/qed_e2e_missing_%d_%d.txt", tmp, posix.getpid(), e2e_seq)
	testing.expect(t, editor_open_path(&e.ed, missing), "nonexistent path opens as an empty buffer")

	b := editor_buffer(&e.ed)
	testing.expect_value(t, b.path, missing)
	testing.expect_value(t, len(b.lines), 1)
	testing.expect_value(t, len(b.lines[0].text), 0)
	testing.expect_value(t, b.modified, false)
}

@(test)
e2e_files_startup_unreadable_lands_on_welcome :: proc(t: ^testing.T) {
	if posix.geteuid() == 0 {
		return // chmod 000 cannot block root
	}
	e := e2e_files_start("secret", mode = os.perm(0o000))
	defer e2e_stop(&e)

	testing.expect(t, e.ed.welcome, "startup open failure falls back to the welcome screen")
	testing.expect(t, strings.contains(e.ed.message, "Cannot open"), "error lands on the message line")
	b := editor_buffer(&e.ed)
	testing.expect_value(t, b.path, "")
	testing.expect_value(t, b.modified, false)
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
	testing.expect_value(t, b.cursor.row, 0) // row 3 maps into the replaced hunk
	testing.expect_value(t, b.cursor.col, 2) // clamped from col 3
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
	testing.expect(t, safety_dialog(&e.ed) == "conflict", "Ctrl+S should open the conflict dialog")

	e2e_key(&e, .Esc)
	testing.expect(t, safety_dialog(&e.ed) != "conflict", "Esc cancels the dialog")
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

	testing.expect(t, safety_dialog(&e.ed) != "conflict", "dialog closes after choosing")
	testing.expect_value(t, b.modified, false)
	testing.expect_value(t, e2e_read_disk(e.path), "Xfirst line\nsecond line\n") // buffer wins
}

@(test)
e2e_files_reload_undo :: proc(t: ^testing.T) {
	e := e2e_start("aaa\nbbb\nccc\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	e2e_key(&e, .Ctrl_S)
	_ = os.write_entire_file_from_string(e.path, "Xaaa\nYYYY\nccc\nddd\n")
	editor_poll_disk(&e.ed)
	testing.expect_value(t, buffer_snapshot_tmp(b), "Xaaa\nYYYY\nccc\nddd\n")
	testing.expect(t, !b.modified, "a reload is clean")

	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, buffer_snapshot_tmp(b), "Xaaa\nbbb\nccc\n")
	testing.expect(t, b.modified, "undoing the reload differs from disk")
	e2e_key(&e, .Ctrl_Y)
	testing.expect_value(t, buffer_snapshot_tmp(b), "Xaaa\nYYYY\nccc\nddd\n")
	testing.expect(t, !b.modified, "redoing the reload matches disk")
	e2e_key(&e, .Ctrl_Z)
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, buffer_snapshot_tmp(b), "aaa\nbbb\nccc\n")
	testing.expect(t, b.modified, "edits before the reload stay undoable")
}

@(test)
e2e_files_conflict_reload_undo :: proc(t: ^testing.T) {
	e := e2e_start("first line\nsecond line\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	_ = os.write_entire_file_from_string(e.path, "DISK\n")
	editor_poll_disk(&e.ed)
	e2e_key(&e, .Ctrl_S)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, safety_dialog(&e.ed) != "conflict", "dialog closes after choosing")
	testing.expect_value(t, buffer_snapshot_tmp(b), "DISK\n")
	testing.expect(t, !b.modified, "the reloaded buffer is clean")
	testing.expect_value(t, e2e_read_disk(e.path), "DISK\n")

	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, buffer_snapshot_tmp(b), "Xfirst line\nsecond line\n")
	testing.expect(t, b.modified, "the discarded edit comes back unsaved")
	testing.expect(t, !b.disk_conflict, "no conflict: the buffer was loaded from the current disk")
	e2e_key(&e, .Ctrl_S)
	testing.expect_value(t, e2e_read_disk(e.path), "Xfirst line\nsecond line\n")
}

@(test)
e2e_files_reload_keeps_latest_step :: proc(t: ^testing.T) {
	e := e2e_start("base\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	e2e_key(&e, .Ctrl_S)
	_ = os.write_entire_file_from_string(e.path, "first reload\n")
	editor_poll_disk(&e.ed)
	e2e_type(&e, "Y")
	e2e_key(&e, .Ctrl_S)
	_ = os.write_entire_file_from_string(e.path, "second reload, longer\n")
	editor_poll_disk(&e.ed)
	testing.expect_value(t, len(b.undo), 2)

	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, buffer_snapshot_tmp(b), "fYirst reload\n")
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, buffer_snapshot_tmp(b), "first reload\n")
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, buffer_snapshot_tmp(b), "first reload\n")
	testing.expect(t, b.modified, "the first reload's content differs from disk")
}

@(test)
e2e_files_grown_buffer_reload_clears_undo :: proc(t: ^testing.T) {
	e := e2e_start("small\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	big := strings.repeat("qed big file test line\n", 100000)
	buffer_paste(b, big)
	delete(big)
	_ = os.write_entire_file_from_string(e.path, "small, changed\n")
	b.modified = false
	editor_poll_disk(&e.ed)
	testing.expect_value(t, buffer_snapshot_tmp(b), "small, changed\n")
	testing.expect_value(t, len(b.undo), 0)
}

@(test)
e2e_files_big_reload_clears_undo :: proc(t: ^testing.T) {
	e := e2e_start("small\n")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	e2e_key(&e, .Ctrl_S)
	big := strings.repeat("qed big file test line\n", 100000)
	_ = os.write_entire_file_from_string(e.path, big)
	delete(big)
	editor_poll_disk(&e.ed)
	testing.expect(t, b.big, "the reloaded file is big")
	testing.expect_value(t, len(b.undo), 0)
	testing.expect_value(t, len(b.redo), 0)
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, len(b.lines), 100001)
	testing.expect(t, !b.modified, "nothing to undo")
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

@(private = "file")
format_save :: proc(content: string, markdown: bool) -> string {
	e := e2e_start(content)
	defer e2e_stop(&e)
	if markdown {
		editor_set_language(&e.ed, editor_buffer(&e.ed), .Markdown)
	}
	e2e_plugin_config(&e, "format", `{"trim_whitespace_on_save": true, "final_newline_on_save": true}`)
	e2e_type(&e, "z")
	e2e_key(&e, .Ctrl_S)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return editor_buffer(&e.ed).modified})
	return strings.clone(e2e_read_disk(e.path), context.temp_allocator)
}

@(test)
e2e_files_format_trim_on_save :: proc(t: ^testing.T) {
	testing.expect_value(t, format_save("a  \nb\t\nkeep\nhard break  \n   \nx \t\nlast  ", false), "za\nb\nkeep\nhard break\n\nx\nlast\n")
	testing.expect_value(t, format_save("a  \n  \nhard break  \nx \t\nlast  ", true), "za  \n\nhard break  \nx\nlast  \n")
	testing.expect_value(t, format_save("clean", false), "zclean\n")
}

@(test)
e2e_files_conflict_before_pre_save :: proc(t: ^testing.T) {
	e := e2e_start("first line   \nsecond line\n")
	defer e2e_stop(&e)
	e2e_plugin_config(&e, "format", `{"trim_whitespace_on_save": true}`)
	b := editor_buffer(&e.ed)
	e2e_type(&e, "X")
	_ = os.write_entire_file_from_string(e.path, "DISK\n")
	editor_poll_disk(&e.ed)
	e2e_key(&e, .Ctrl_S)
	testing.expect(t, safety_dialog(&e.ed) == "conflict", "Ctrl+S opens the conflict dialog")
	e2e_key(&e, .Esc)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return len(e.ed.plugins.tasks) > 0})
	testing.expect_value(t, string(b.lines[0].text[:]), "Xfirst line   ")
	testing.expect_value(t, e2e_read_disk(e.path), "DISK\n")
	e2e_key(&e, .Ctrl_S)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return len(e.ed.plugins.tasks) > 0})
	testing.expect_value(t, e2e_read_disk(e.path), "Xfirst line\nsecond line\n")
}
