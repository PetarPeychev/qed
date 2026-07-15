package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import "lib:tb2"

LOG_MAX :: 1000
LOG_ROTATE_BYTES :: 1024 * 1024

LogLevel :: enum {
	Debug,
	Info,
	Warn,
	Error,
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
	clear(&editor.message_store)
	editor.message = ""
	editor.message_source = ""
	editor.message_level = .Info
}

// Copy the text into owned storage: callers pass temp-allocator strings, and the
// main loop's free_all would leave editor.message dangling into reused temp memory.
editor_message_show :: proc(editor: ^Editor, level: LogLevel, source, text: string) {
	clear(&editor.message_store)
	append(&editor.message_store, ..transmute([]u8)text)
	editor.message = string(editor.message_store[:])
	editor.message_source = source
	editor.message_level = level
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
		source = source,
		text   = strings.clone(msg),
	}
	append(&editor.log, entry)
	for len(editor.log) > LOG_MAX {
		delete(editor.log[0].text)
		ordered_remove(&editor.log, 0)
	}
	editor_log_disk(editor, entry)
}

editor_log_destroy :: proc(editor: ^Editor) {
	for e in editor.log {
		delete(e.text)
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
	if info, err := os.stat(path, context.temp_allocator); err == nil && info.size > LOG_ROTATE_BYTES {
		os.remove(fmt.tprintf("%s/qed.log.old", dir))
		os.rename(path, fmt.tprintf("%s/qed.log.old", dir))
	}
	h, oerr := os.open(path, {.Write, .Create, .Append}, os.perm(0o644))
	if oerr != nil {
		return
	}
	editor.log_file = h
	os.write(
		h,
		transmute([]u8)fmt.tprintf("=== qed %s — session started %s ===\n", VERSION, log_stamp(time.now())),
	)
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
	os.write(editor.log_file, transmute([]u8)log_line(entry))
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
		append(&editor.log, entry)
	}
}

LogView :: struct {
	active:   bool,
	selected: int,
	anchor:   Maybe(int),
	scroll:   int,
	stick:    bool,
	filter:   [LogLevel]bool,
	history:  bool,
}

logview_sel_range :: proc(v: ^LogView) -> (lo, hi: int) {
	lo, hi = v.selected, v.selected
	if a, ok := v.anchor.?; ok {
		lo, hi = min(a, v.selected), max(a, v.selected)
	}
	return
}

logview_body_h :: proc(editor: ^Editor) -> int {
	lay := logview_layout(editor)
	return max(1, lay.footer_sep_y - lay.body_top)
}

LogLayout :: struct {
	box, inner:            Rect,
	title_sep_y:           int,
	body_top:              int,
	footer_sep_y, footer_y: int,
}

logview_layout :: proc(editor: ^Editor) -> LogLayout {
	base := overlay_layout(editor)
	inner := base.inner
	title_sep_y := inner.y + 1
	body_top := inner.y + 2
	footer_sep_y := inner.y + inner.h - 2
	footer_y := inner.y + inner.h - 1
	return {base.box, inner, title_sep_y, body_top, footer_sep_y, footer_y}
}

logview_filtered :: proc(editor: ^Editor) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	for e, i in editor.log {
		if !editor.logview.filter[e.level] {
			continue
		}
		if e.seeded && !editor.logview.history {
			continue
		}
		append(&out, i)
	}
	return out
}

logview_open :: proc(editor: ^Editor) {
	v := &editor.logview
	v.active = true
	v.anchor = nil
	editor_clear_message(editor)
	n := len(logview_filtered(editor))
	v.selected = max(0, n - 1)
	v.stick = true
	logview_reveal(editor)
}

logview_close :: proc(editor: ^Editor) {
	editor.logview.active = false
}

logview_reveal :: proc(editor: ^Editor, follow := false) {
	v := &editor.logview
	n := len(logview_filtered(editor))
	h := logview_body_h(editor)
	if a, ok := v.anchor.?; ok {
		if n == 0 {
			v.anchor = nil
		} else {
			v.anchor = clamp(a, 0, n - 1)
		}
	}
	if v.stick {
		v.selected = max(0, n - 1)
		v.scroll = max(0, n - h)
		return
	}
	v.selected = clamp(v.selected, 0, max(0, n - 1))
	if follow {
		if v.selected < v.scroll {
			v.scroll = v.selected
		}
		if h > 0 && v.selected >= v.scroll + h {
			v.scroll = v.selected - h + 1
		}
	}
	v.scroll = clamp(v.scroll, 0, max(0, n - h))
}

logview_move :: proc(editor: ^Editor, delta: int, extend := false) {
	v := &editor.logview
	n := len(logview_filtered(editor))
	if n == 0 {
		return
	}
	if !extend {
		v.anchor = nil
	} else if v.anchor == nil {
		v.anchor = v.selected
	}
	v.selected = clamp(v.selected + delta, 0, n - 1)
	v.stick = v.selected == n - 1
	logview_reveal(editor, follow = true)
}

logview_toggle :: proc(editor: ^Editor, level: LogLevel) {
	v := &editor.logview
	v.filter[level] = !v.filter[level]
	v.anchor = nil
	logview_reveal(editor, follow = true)
}

logview_toggle_history :: proc(editor: ^Editor) {
	v := &editor.logview
	v.history = !v.history
	v.anchor = nil
	logview_reveal(editor, follow = true)
}

logview_copy :: proc(editor: ^Editor) {
	v := &editor.logview
	filtered := logview_filtered(editor)
	if len(filtered) == 0 || v.selected >= len(filtered) {
		return
	}
	lo, hi := logview_sel_range(v)
	lo = clamp(lo, 0, len(filtered) - 1)
	hi = clamp(hi, 0, len(filtered) - 1)
	sb := strings.builder_make(context.temp_allocator)
	for pos in lo ..= hi {
		if pos > lo {
			strings.write_byte(&sb, '\n')
		}
		e := editor.log[filtered[pos]]
		if e.source != "" {
			fmt.sbprintf(&sb, "%s: %s", e.source, e.text)
		} else {
			strings.write_string(&sb, e.text)
		}
	}
	clipboard_set(strings.to_string(sb))
	if hi > lo {
		editor_log(editor, .Info, "", fmt.tprintf("Copied %d entries", hi - lo + 1))
	} else {
		editor_log(editor, .Info, "", "Copied to clipboard")
	}
}

logview_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	if command_matches(ev, "Debug: Message Log") {
		logview_close(editor)
		return
	}
	if command_matches(ev, "Copy") {
		logview_copy(editor)
		return
	}
	#partial switch ev.key {
	case .Esc:
		logview_close(editor)
		return
	case .Arrow_Up:
		logview_move(editor, -1, ev_shift(ev))
		return
	case .Arrow_Down:
		logview_move(editor, +1, ev_shift(ev))
		return
	}
	switch ev.ch {
	case 'd':
		logview_toggle(editor, .Debug)
	case 'i':
		logview_toggle(editor, .Info)
	case 'w':
		logview_toggle(editor, .Warn)
	case 'e':
		logview_toggle(editor, .Error)
	case 'h':
		logview_toggle_history(editor)
	}
}

logview_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	v := &editor.logview
	lay := logview_layout(editor)
	n := len(logview_filtered(editor))
	h := logview_body_h(editor)
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		v.stick = false
		overlay_scroll_by(&v.scroll, -WHEEL_SCROLL_LINES, n, h)
	case .Mouse_Wheel_Down:
		overlay_scroll_by(&v.scroll, WHEEL_SCROLL_LINES, n, h)
		v.stick = v.scroll >= max(0, n - h)
	case .Mouse_Left:
		if !mouse_in_rect(ev, lay.box) {
			if !ev_motion(ev) {
				logview_close(editor)
			}
			return
		}
		off := overlay_row_off(ev, Rect{lay.inner.x, lay.body_top, lay.inner.w, h})
		if off < 0 {
			return
		}
		idx := v.scroll + off
		if idx >= n {
			return
		}
		v.selected = idx
		v.anchor = nil
		v.stick = idx == n - 1
	}
}

logview_level_fg :: proc(level: LogLevel) -> tb2.Color {
	switch level {
	case .Debug:
		return COLOR_PANE_SHORTCUT_FG
	case .Info:
		return COLOR_PANE_FG
	case .Warn:
		return COLOR_WARN_FG
	case .Error:
		return COLOR_ERROR_FG
	}
	return COLOR_PANE_FG
}

logview_render :: proc(editor: ^Editor) {
	v := &editor.logview
	lay := logview_layout(editor)
	inner := pane_draw_box(lay.box)
	logview_reveal(editor)

	pane_text(inner.x + 1, inner.y, inner.w - 2, "Message Log", COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_hline(lay.box, lay.title_sep_y)

	filtered := logview_filtered(editor)
	h := max(1, lay.footer_sep_y - lay.body_top)
	if len(filtered) == 0 {
		pane_text(inner.x + 1, lay.body_top, inner.w - 2, "(no messages)", COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	sel_lo, sel_hi := logview_sel_range(v)
	end := min(v.scroll + h, len(filtered))
	for pos in v.scroll ..< end {
		e := editor.log[filtered[pos]]
		y := lay.body_top + (pos - v.scroll)
		fg := logview_level_fg(e.level)
		bg := COLOR_PANE_BG
		if pos >= sel_lo && pos <= sel_hi {
			bg = COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		row: string
		if e.source != "" {
			row = fmt.tprintf("%s  %s: %s", log_clock(e.time), e.source, e.text)
		} else {
			row = fmt.tprintf("%s  %s", log_clock(e.time), e.text)
		}
		pane_text(inner.x + 1, y, inner.w - 2, row, fg, bg)
	}
	pane_draw_scrollbar(lay.box.x + lay.box.w - 1, lay.body_top, h, v.scroll, len(filtered))

	pane_hline(lay.box, lay.footer_sep_y)
	logview_render_footer(editor, inner, lay.footer_y)
	tb2.hide_cursor()
}

logview_render_footer :: proc(editor: ^Editor, inner: Rect, y: int) {
	v := &editor.logview
	Toggle :: struct {
		label: string,
		on:    bool,
	}
	toggles := [?]Toggle {
		{"d debug", v.filter[.Debug]},
		{"i info", v.filter[.Info]},
		{"w warn", v.filter[.Warn]},
		{"e error", v.filter[.Error]},
		{"h history", v.history},
	}
	total := 0
	for tg, i in toggles {
		total += len(tg.label)
		if i > 0 {
			total += 2
		}
	}
	tx := inner.x + inner.w - 1 - total
	actions_w := max(0, tx - (inner.x + 1) - 1)
	pane_text(inner.x + 1, y, actions_w, fmt.tprintf("↑↓ select  Shift+↑↓ extend  %s copy", command_shortcut("Copy")), COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	for tg in toggles {
		fg := COLOR_PANE_PROMPT_FG if tg.on else COLOR_PANE_SHORTCUT_FG
		pane_text(tx, y, len(tg.label), tg.label, fg, COLOR_PANE_BG)
		tx += len(tg.label) + 2
	}
}
