package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
log_ring_caps_and_evicts :: proc(t: ^testing.T) {
	ed := Editor{headless = true}
	defer {
		editor_log_destroy(&ed)
		delete(ed.message_store)
	}

	for i in 0 ..< LOG_MAX + 5 {
		editor_log(&ed, .Info, "", fmt.tprintf("%d", i), show = false)
	}
	testing.expect_value(t, len(ed.log), LOG_MAX)
	// The oldest 5 were evicted; the ring keeps entries 5 .. LOG_MAX+4.
	testing.expect_value(t, ed.log[0].text, "5")
	testing.expect_value(t, ed.log[LOG_MAX - 1].text, fmt.tprintf("%d", LOG_MAX + 4))
}

@(test)
log_empty_never_logs :: proc(t: ^testing.T) {
	ed := Editor{headless = true}
	defer {
		editor_log_destroy(&ed)
		delete(ed.message_store)
	}

	editor_log(&ed, .Info, "Config", "hello")
	testing.expect_value(t, len(ed.log), 1)
	testing.expect_value(t, ed.message, "hello")

	// An empty message clears the line and is never appended to the ring.
	editor_log(&ed, .Info, "Config", "")
	testing.expect_value(t, len(ed.log), 1)
	testing.expect_value(t, ed.message, "")
}

@(test)
log_debug_never_shows :: proc(t: ^testing.T) {
	ed := Editor{headless = true}
	defer {
		editor_log_destroy(&ed)
		delete(ed.message_store)
	}

	editor_log(&ed, .Info, "", "visible")
	testing.expect_value(t, ed.message, "visible")

	// Debug is always log-only: it lands in the ring but never touches the line,
	// even with show = true.
	editor_log(&ed, .Debug, "LSP", "trace", show = true)
	testing.expect_value(t, len(ed.log), 2)
	testing.expect_value(t, ed.log[1].level, LogLevel.Debug)
	testing.expect_value(t, ed.message, "visible")
}

@(test)
log_seed_parses_disk_lines :: proc(t: ^testing.T) {
	ed := Editor{headless = true}
	defer {
		editor_log_destroy(&ed)
		delete(ed.message_store)
	}

	fixture :=
		"=== qed v0.9.0 — session started 2026-07-10 09:15:00 ===\n" +
		"2026-07-10 09:15:01 [ERROR] LSP: failed to start taplo\n" +
		"2026-07-10 09:15:02 [DEBUG] trace detail\n" +
		"not a log line at all\n" +
		"2026-07-10 09:15:03 [INFO] Saved foo.txt\n"
	editor_log_seed_text(&ed, fixture)

	testing.expect_value(t, len(ed.log), 5)
	testing.expect_value(t, ed.log[0].level, LogLevel.Info)
	testing.expect_value(t, ed.log[0].text, "=== qed v0.9.0 — session started 2026-07-10 09:15:00 ===")
	testing.expect_value(t, log_stamp(ed.log[0].time), "2026-07-10 09:15:00")
	testing.expect_value(t, ed.log[1].level, LogLevel.Error)
	testing.expect_value(t, ed.log[1].source, "")
	testing.expect_value(t, ed.log[1].text, "LSP: failed to start taplo")
	testing.expect_value(t, log_stamp(ed.log[1].time), "2026-07-10 09:15:01")
	testing.expect_value(t, ed.log[2].level, LogLevel.Debug)
	testing.expect_value(t, ed.log[3].level, LogLevel.Info)
	testing.expect_value(t, ed.log[3].text, "not a log line at all")
	testing.expect_value(t, log_stamp(ed.log[3].time), "2026-07-10 09:15:02")
	testing.expect_value(t, ed.log[4].text, "Saved foo.txt")
	testing.expect_value(t, ed.message, "")
}

@(test)
log_line_formats_source_and_level :: proc(t: ^testing.T) {
	// The stamp renders in local wall-clock, so assert the surrounding format around a
	// deterministic stamp rather than a fixed UTC string.
	stamp := log_stamp(time.Time{})

	with_source := log_line(LogEntry{time = time.Time{}, level = .Error, source = "LSP", text = "failed to start taplo"})
	testing.expect_value(t, with_source, fmt.tprintf("%s [ERROR] LSP: failed to start taplo\n", stamp))

	bare := log_line(LogEntry{time = time.Time{}, level = .Info, source = "", text = "Replaced 3 matches"})
	testing.expect_value(t, bare, fmt.tprintf("%s [INFO] Replaced 3 matches\n", stamp))

	dbg := log_line(LogEntry{time = time.Time{}, level = .Debug, source = "", text = "trace"})
	testing.expect_value(t, dbg, fmt.tprintf("%s [DEBUG] trace\n", stamp))
}

@(test)
log_disk_rotates_mid_session :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_log_rotate_%d", tmp, posix.getpid())
	os.make_directory(dir)
	posix.setenv("XDG_STATE_HOME", strings.clone_to_cstring(dir, context.temp_allocator), true)
	ed := Editor{}
	line := strings.repeat("x", 1000, context.temp_allocator)
	for _ in 0 ..< LOG_ROTATE_BYTES / 1000 + 50 {
		editor_log(&ed, .Info, "T", line, show = false)
	}
	editor_log_destroy(&ed)
	delete(ed.message_store)
	posix.unsetenv("XDG_STATE_HOME")
	cur, cerr := os.stat(fmt.tprintf("%s/qed/qed.log", dir), context.temp_allocator)
	old, oerr := os.stat(fmt.tprintf("%s/qed/qed.log.old", dir), context.temp_allocator)
	testing.expect(t, cerr == nil && oerr == nil, "rotated during the session")
	testing.expect(t, cur.size < LOG_ROTATE_BYTES, "the live log stays under the cap")
	testing.expect(t, old.size > LOG_ROTATE_BYTES, "the old one holds the rest")
	os.remove(fmt.tprintf("%s/qed/qed.log", dir))
	os.remove(fmt.tprintf("%s/qed/qed.log.old", dir))
	os.remove(fmt.tprintf("%s/qed", dir))
	os.remove(dir)
}
