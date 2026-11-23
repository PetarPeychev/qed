package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import "lib:tb2"

LOG_MAX :: 1000
LOG_ROTATE_BYTES :: 4 * 1024 * 1024

LogLevel :: enum {
	Debug,
	Info,
	Warn,
	Error,
}

log_level_names := [LogLevel]string {
	.Debug = "debug",
	.Info  = "info",
	.Warn  = "warn",
	.Error = "error",
}

// source is a short subsystem tag ("LSP", "Format", …); it is always a compile-time
// string literal at the call sites, so it is stored unowned. text is cloned and
// freed when the entry is evicted from the ring (or at editor_shutdown).
LogEntry :: struct {
	time:   time.Time,
	level:  LogLevel,
	source: string,
	text:   string,
	seeded: bool,
	seq:    u64,
}

log_level_tag :: proc(level: LogLevel) -> string {
	switch level {
	case .Debug:
		return "DEBUG"
	case .Info:
		return "INFO"
	case .Warn:
		return "WARN"
	case .Error:
		return "ERROR"
	}
	return "INFO"
}

editor_clear_message :: proc(editor: ^Editor) {
	if editor.message != "" {
		plugin_queue(editor, {event = .Message})
	}
	clear(&editor.message_store)
	editor.message = ""
	editor.message_source = ""
	editor.message_level = .Info
}

// callers pass temp strings, which the main loop's free_all would leave dangling
editor_message_show :: proc(editor: ^Editor, level: LogLevel, source, text: string) {
	clear(&editor.message_store)
	append(&editor.message_store, ..transmute([]u8)source)
	append(&editor.message_store, ..transmute([]u8)text)
	editor.message_source = string(editor.message_store[:len(source)])
	editor.message = string(editor.message_store[len(source):])
	editor.message_level = level
	plugin_message_queue(editor)
}

plugin_message_queue :: proc(editor: ^Editor, only := "") {
	if editor.message == "" {
		return
	}
	source := editor.message_source
	text := fmt.tprintf("%s: %s", source, editor.message) if source != "" else editor.message
	plugin_queue(editor, {event = .Message, a = text, b = log_level_names[editor.message_level], only = only})
}

editor_log :: proc(editor: ^Editor, level: LogLevel, source, msg: string, show := true) {
	shown := show && level != .Debug
	if msg == "" {
		if shown {
			editor_clear_message(editor)
		}
		return
	}
	if shown {
		editor_message_show(editor, level, source, msg)
	}
	entry := LogEntry {
		time   = time.now(),
		level  = level,
		source = strings.clone(source),
		text   = strings.clone(msg),
	}
	editor.log_seq += 1
	entry.seq = editor.log_seq
	append(&editor.log, entry)
	for len(editor.log) > LOG_MAX {
		delete(editor.log[0].text)
		delete(editor.log[0].source)
		ordered_remove(&editor.log, 0)
	}
	editor_log_disk(editor, entry)
}

editor_log_destroy :: proc(editor: ^Editor) {
	for e in editor.log {
		delete(e.text)
		delete(e.source)
	}
	delete(editor.log)
	if editor.log_open && editor.log_file != nil {
		os.close(editor.log_file)
	}
}

// Heap-backed and loaded once so it outlives any per-test tracking allocator; nil
// means UTC (either the local zone is UTC or it could not be resolved).
@(private = "file")
local_tz: ^datetime.TZ_Region
@(private = "file")
local_tz_loaded: bool

log_tz :: proc() -> ^datetime.TZ_Region {
	if !local_tz_loaded {
		local_tz_loaded = true
		local_tz, _ = timezone.region_load("local", os.heap_allocator())
	}
	return local_tz
}

log_local :: proc(t: time.Time) -> datetime.DateTime {
	dt, ok := time.time_to_datetime(t)
	if ok {
		if loc, lok := timezone.datetime_to_tz(dt, log_tz()); lok {
			return loc
		}
	}
	return dt
}

log_tz_shutdown :: proc() {
	timezone.region_destroy(local_tz, os.heap_allocator())
	local_tz = nil
	local_tz_loaded = false
}

log_stamp :: proc(t: time.Time, allocator := context.temp_allocator) -> string {
	dt := log_local(t)
	return fmt.aprintf(
		"%04d-%02d-%02d %02d:%02d:%02d",
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
		allocator = allocator,
	)
}

log_clock :: proc(t: time.Time) -> string {
	dt := log_local(t)
	return fmt.tprintf("%02d:%02d:%02d", dt.hour, dt.minute, dt.second)
}

log_state_dir :: proc(allocator := context.temp_allocator) -> string {
	if xdg := os.get_env("XDG_STATE_HOME", context.temp_allocator); xdg != "" {
		return fmt.aprintf("%s/qed", xdg, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return fmt.aprintf("%s/.local/state/qed", home, allocator = allocator)
}

// Any disk-logging failure is silent: the in-memory ring is the source of truth and
// logging must never crash or spam the message line.
editor_log_open :: proc(editor: ^Editor) {
	editor.log_open = true
	editor.log_file = nil
	dir := log_state_dir()
	if dir == "" {
		return
	}
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/qed.log", dir)
	editor.log_bytes = 0
	if info, err := os.stat(path, context.temp_allocator); err == nil {
		editor.log_bytes = int(info.size)
	}
	if editor.log_bytes > LOG_ROTATE_BYTES {
		os.remove(fmt.tprintf("%s/qed.log.old", dir))
		os.rename(path, fmt.tprintf("%s/qed.log.old", dir))
		editor.log_bytes = 0
	}
	h, oerr := os.open(path, {.Write, .Create, .Append}, os.perm(0o644))
	if oerr != nil {
		return
	}
	editor.log_file = h
	what := "session continues" if editor.log_rotated else "session started"
	editor_log_write(editor, fmt.tprintf("=== qed %s, %s %s ===\n", VERSION, what, log_stamp(time.now())))
}

editor_log_write :: proc(editor: ^Editor, line: string) {
	os.write(editor.log_file, transmute([]u8)line)
	editor.log_bytes += len(line)
}

editor_log_disk :: proc(editor: ^Editor, entry: LogEntry) {
	if editor.headless {
		return
	}
	if !editor.log_open {
		editor_log_open(editor)
	}
	if editor.log_file == nil {
		return
	}
	editor_log_write(editor, log_line(entry))
	if editor.log_bytes > LOG_ROTATE_BYTES {
		os.close(editor.log_file)
		editor.log_file = nil
		editor.log_rotated = true
		editor_log_open(editor)
	}
}

log_line :: proc(entry: LogEntry) -> string {
	if entry.source != "" {
		return fmt.tprintf(
			"%s [%s] %s: %s\n",
			log_stamp(entry.time),
			log_level_tag(entry.level),
			entry.source,
			entry.text,
		)
	}
	return fmt.tprintf("%s [%s] %s\n", log_stamp(entry.time), log_level_tag(entry.level), entry.text)
}

log_level_parse :: proc(tag: string) -> (LogLevel, bool) {
	switch tag {
	case "DEBUG":
		return .Debug, true
	case "INFO":
		return .Info, true
	case "WARN":
		return .Warn, true
	case "ERROR":
		return .Error, true
	}
	return .Info, false
}

// Disk stamps are local wall-clock; reverse-convert through the tz region so the
// pane's UTC→local render doesn't shift the clock twice.
log_parse_stamp :: proc(s: string) -> (t: time.Time, ok: bool) {
	if len(s) < 19 || s[4] != '-' || s[7] != '-' || s[10] != ' ' || s[13] != ':' || s[16] != ':' {
		return
	}
	num :: proc(s: string) -> (n: int, ok: bool) {
		for c in s {
			if c < '0' || c > '9' {
				return
			}
			n = n * 10 + int(c - '0')
		}
		return n, true
	}
	y := num(s[0:4]) or_return
	mon := num(s[5:7]) or_return
	d := num(s[8:10]) or_return
	h := num(s[11:13]) or_return
	mi := num(s[14:16]) or_return
	sec := num(s[17:19]) or_return
	dt := datetime.DateTime{{i64(y), i8(mon), i8(d)}, {i8(h), i8(mi), i8(sec), 0}, log_tz()}
	udt := timezone.datetime_to_utc(dt) or_return
	return time.datetime_to_time(udt)
}

log_seed_entry :: proc(line: string, last: time.Time) -> LogEntry {
	entry := LogEntry{time = last, level = .Info, seeded = true}
	if strings.has_prefix(line, "=== ") {
		if idx := strings.index(line, "session started "); idx >= 0 {
			if t, ok := log_parse_stamp(line[idx + len("session started "):]); ok {
				entry.time = t
			}
		}
	} else if t, ok := log_parse_stamp(line); ok && len(line) > 21 && line[19:21] == " [" {
		rest := line[21:]
		if end := strings.index(rest, "] "); end >= 0 {
			if level, lok := log_level_parse(rest[:end]); lok {
				entry.time = t
				entry.level = level
				entry.text = strings.clone(rest[end + 2:])
				return entry
			}
		}
	}
	entry.text = strings.clone(line)
	return entry
}

editor_log_seed :: proc(editor: ^Editor) {
	dir := log_state_dir()
	if dir == "" {
		return
	}
	data, err := os.read_entire_file(fmt.tprintf("%s/qed.log", dir), context.temp_allocator)
	if err != nil {
		return
	}
	editor_log_seed_text(editor, string(data))
}

editor_log_seed_text :: proc(editor: ^Editor, data: string) {
	lines := strings.split_lines(data, context.temp_allocator)
	start := max(0, len(lines) - LOG_MAX)
	last: time.Time
	for line in lines[start:] {
		if line == "" {
			continue
		}
		entry := log_seed_entry(line, last)
		last = entry.time
		editor.log_seq += 1
		entry.seq = editor.log_seq
		append(&editor.log, entry)
	}
}

ms_since :: proc(t: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(t))
}
