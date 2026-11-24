package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

STATUS_ROWS :: 2
HOVER_PANE_MAX_LINES :: 40
DISK_POLL_MS :: 1000
DIAG_PANE_MARGIN_X :: 2
DIAG_PANE_MAX_LINES :: 8

Editor :: struct {
	safety:          Safety,
	rename:          RenamePrompt,
	buffers:         [dynamic]Buffer,
	current:         int,
	working_root:    string,
	welcome:         bool,
	message:         string,
	message_store:   [dynamic]u8,
	message_source:  string,
	message_level:   LogLevel,
	log:             [dynamic]LogEntry,
	log_seq:         u64,
	plugins:         Plugins,
	log_file:        ^os.File,
	log_open:        bool,
	log_rotated:     bool,
	log_bytes:       int,
	walks:           [dynamic]^Walk,
	disk_poll:       time.Tick,
	config_stamp:    DiskStamp,
	config_written:  DiskStamp,
	theme_stamp:     DiskStamp,
	theme_shown:     string,
	quit:            bool,
	pasting:         bool,
	paste_buf:       [dynamic]u8,
	paste_last_cr:   bool,
	last_click_tick: time.Tick,
	last_click_pos:  Cursor,
	click_count:     int,
	accel_key:       tb2.Key,
	accel_count:     int,
	accel_rem:       f64,
	accel_tick:      time.Tick,
	overlay_click_tick: time.Tick,
	overlay_click_idx:  int,
	searches:        [dynamic]^Search,
	jumps:           JumpList,
	jump_lock:       bool,
	hover:           [dynamic]u8,
	hover_active:    bool,
	hover_lang:      Language,
	hover_gen:       u64,
	caret_popup:     CaretPopup,
	completion:      Completion,
	save_intent:     SaveIntent,
	save_intent_path: string,
	terminal:        Terminals,
	inspect:         Inspect,
	headless:        bool,
	ui:              Ui,
	caret_view:      EditorView,
}

editor_terminal_init :: proc() -> (fallback: string) {
	status := tb2.init()
	if status == .Ok {
		return ""
	}
	term, had_term := os.lookup_env("TERM", context.temp_allocator)
	shown := term if term != "" else "(unset)"
	os.set_env("TERM", "xterm-256color")
	retry := tb2.init()
	if had_term {
		os.set_env("TERM", term)
	} else {
		os.unset_env("TERM")
	}
	if retry != .Ok {
		crash_stderr_restore()
		fmt.eprintfln("qed: cannot initialize the terminal (TERM=%s): %s", shown, tb2.strerror(status))
		os.exit(1)
	}
	return shown
}

editor_init :: proc(path: string = "", headless := false) -> Editor {
	// headless: a test has already brought up the termbox backend (init_fd on a
	// PTS) and owns its teardown; skip the real-terminal bring-up here.
	term_fallback := ""
	if !headless {
		crash_restore_install()
		term_fallback = editor_terminal_init()
		tb2.set_output_mode(.Truecolor)
		tb2.set_input_mode(.Mouse)
		tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
		image_detect_begin()
	}
	clipboard_headless = headless
	editor := Editor {
		buffers        = make([dynamic]Buffer, 0, 8),
		headless       = headless,
	}
	g_diff_view = DIFF_VIEW
	if !headless {
		editor_log_seed(&editor)
	}
	if term_fallback != "" {
		editor_log(&editor, .Warn, "", fmt.tprintf("TERM=%s is unknown here; running as xterm-256color", term_fallback))
	}
	editor.config_stamp = buffer_disk_stamp(config_path())
	editor.theme_stamp = buffer_disk_stamp(theme_path(config_path(), THEME))
	b := buffer_new()
	if path != "" && !os.is_dir(path) {
		abs, err := filepath.abs(path, context.temp_allocator)
		if err != nil {
			abs = path
		}
		editor.working_root, _ = os.get_working_directory(context.allocator)
		if oerr := buffer_open(&b, abs); oerr != .None {
			editor.welcome = true
			editor_log(&editor, .Debug, "Files", fmt.tprintf("open failed: %s (%v)", abs, oerr))
			editor_log(&editor, .Error, "", fmt.tprintf("Cannot open %s", editor_display_path(&editor, abs)))
		} else {
			editor_log(&editor, .Debug, "Lang", fmt.tprintf("detected %s for %s", LANGUAGES[b.language].name, abs))
		}
	} else {
		editor.welcome = true
		if path != "" {
			abs, err := filepath.abs(path, context.allocator)
			editor.working_root = abs if err == nil else strings.clone(path)
		} else {
			editor.working_root, _ = os.get_working_directory(context.allocator)
		}
	}
	append(&editor.buffers, b)
	if !headless {
		clipboard_detect()
		tool := "in-process register"
		switch clipboard_tool {
		case .WlClipboard:
			tool = "wl-copy"
		case .Xclip:
			tool = "xclip"
		case .Pbcopy:
			tool = "pbcopy"
		case .None, .Unknown:
		}
		editor_log(&editor, .Debug, "Clipboard", fmt.tprintf("using %s", tool))
	}
	editor_plugins_start(&editor, g_bundled_plugins, "" if headless else plugin_user_dir(), PLUGIN_MEMORY_MB * 1024 * 1024)
	plugins_rebind(&editor)
	if !headless {
		plugin_stub_write(plugin_stub_dir())
		editor_log(
			&editor,
			.Debug,
			"Startup",
			fmt.tprintf(
				"qed %s · root=%s · %dx%d · %d buffer(s)",
				VERSION,
				editor.working_root,
				tb2.width(),
				tb2.height(),
				len(editor.buffers),
			),
		)
	}
	return editor
}

editor_shutdown :: proc(editor: ^Editor) {
	lsp_stop(editor)
	for &b in editor.buffers {
		buffer_destroy(&b)
	}
	delete(editor.buffers)
	editor_save_intent_clear(editor)
	delete(editor.working_root)
	delete(editor.theme_shown)
	delete(editor.paste_buf)
	delete(editor.message_store)
	editor_log_destroy(editor)
	delete(editor.hover)
	caret_popup_free(&editor.caret_popup)
	completion_destroy(&editor.completion)
	searches_destroy(editor)
	jump_destroy(&editor.jumps)
	term_destroy(editor)
	ui_destroy(editor)
	plugins_shutdown(&editor.plugins)
	walk_destroy_all(editor)
	// Process-global singletons (seeded once at @(init) / lazily, shared across
	// every editor); real main tears them down once at exit. A headless test reuses
	// them across many sessions, so freeing them here would dangle the next one.
	if !editor.headless {
		delete(g_language_rules)
		syntax_shutdown()
		clipboard_shutdown()
		log_tz_shutdown()
		image_shutdown()
		tb2.shutdown()
		crash_stderr_restore()
	}
}

@(private = "file")
g_crash_termios: posix.termios
@(private = "file")
g_crash_fd: posix.FD = -1
@(private = "file")
g_crash_stderr: posix.FD = -1
@(private = "file")
g_crash_note: [1024]u8
@(private = "file")
g_crash_note_len: int

crash_restore_install :: proc() {
	fd := posix.open("/dev/tty", {.RDWR, .CLOEXEC})
	if fd < 0 || posix.tcgetattr(fd, &g_crash_termios) != .OK {
		return
	}
	g_crash_fd = fd
	// Odin writes panic and bounds messages to stderr, which would land on the alt screen and vanish
	if dir := log_state_dir(); dir != "" {
		os.make_directory_all(dir)
		path := fmt.tprintf("%s/crash.log", dir)
		log_fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if log_fd >= 0 {
			g_crash_stderr = posix.dup(2)
			posix.dup2(log_fd, 2)
			posix.close(log_fd)
			g_crash_note_len = copy(g_crash_note[:], fmt.tprintf("qed crashed; details in %s\n", path))
		}
	}
	act := posix.sigaction_t{sa_handler = crash_restore, sa_flags = {.RESETHAND}}
	for sig in ([]posix.Signal{.SIGSEGV, .SIGBUS, .SIGFPE, .SIGILL, .SIGTRAP, .SIGABRT}) {
		posix.sigaction(sig, &act, nil)
	}
}

crash_stderr_restore :: proc "contextless" () {
	if g_crash_stderr >= 0 {
		posix.dup2(g_crash_stderr, 2)
		posix.close(g_crash_stderr)
		g_crash_stderr = -1
	}
}

// Only async-signal-safe calls; the raised signal is delivered under SIG_DFL once the handler returns.
crash_restore :: proc "c" (sig: posix.Signal) {
	reset := "\x1b[?1006l\x1b[?1015l\x1b[?1002l\x1b[?1000l\x1b[?2004l\x1b[0m\x1b[?25h\x1b[?1l\x1b>\x1b[?1049l"
	posix.write(g_crash_fd, raw_data(reset), len(reset))
	posix.tcsetattr(g_crash_fd, .TCSAFLUSH, &g_crash_termios)
	if g_crash_stderr >= 0 && g_crash_note_len > 0 {
		posix.write(g_crash_stderr, &g_crash_note[0], uint(g_crash_note_len))
	}
	posix.raise(sig)
}

editor_buffer :: proc(editor: ^Editor) -> ^Buffer {
	return &editor.buffers[editor.current]
}

editor_set_language :: proc(editor: ^Editor, b: ^Buffer, lang: Language) -> bool {
	if b.language == lang {
		return false
	}
	if b.lsp_open {
		lsp_did_close(editor, b)
	}
	b.language = lang
	highlight_destroy(&b.hl)
	b.hl = {}
	plugin_queue(editor, {event = .Language_Changed, buf = b.id})
	return true
}

editor_change_root :: proc(editor: ^Editor, root: string) {
	for i := len(editor.buffers) - 1; i >= 0; i -= 1 {
		b := &editor.buffers[i]
		if b.path != "" && !path_under(b.path, root) {
			editor_close_index(editor, i)
		}
	}
	root := strings.clone(root)
	plugin_queue(editor, {event = .Root_Changed, a = editor.working_root, b = root})
	delete(editor.working_root)
	editor.working_root = root
	editor.hover_active = false
	lsp_restart_all(editor)
	editor_log(editor, .Info, "", fmt.tprintf("Working directory: %s", root))
}

editor_gutter_width :: proc(editor: ^Editor) -> int {
	return digit_count(len(editor_buffer(editor).lines)) + 2
}

editor_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	origin := jump_here(editor)
	defer jump_record(editor, origin)
	if ev.type == .Reply {
		image_reply(editor)
		return
	}
	if g_image_detect.pending && (ev.type == .Key || ev.type == .Mouse) {
		image_detect_end(editor)
	}
	if ev.type == .Resize && !editor.headless {
		image_cell_refresh(editor)
	}
	#partial switch ev.type {
	case .Paste_Begin:
		editor.pasting = true
		editor.paste_last_cr = false
		clear(&editor.paste_buf)
		return
	case .Paste_End:
		editor.pasting = false
		editor_paste_route(editor, string(editor.paste_buf[:]))
		clear(&editor.paste_buf)
		return
	case .Key:
		if editor.pasting {
			editor_paste_accumulate(editor, ev)
			return
		}
	case .Mouse:
		if editor.pasting {
			return
		}
	}
	if rename_prompt_open(editor) {
		// a click outside the prompt cancels it; its Enter and Esc act only while it has focus
		if ev.type == .Mouse && ev.key == .Mouse_Left {
			if box := ui_find(&editor.ui, "#/rename"); box == nil || !ui_rect_has(box.rect, int(ev.x), int(ev.y)) {
				rename_close(editor)
			}
		}
		if ev.type == .Key && editor.ui.focus == "#/rename_field" && rename_key(editor, ev) {
			return
		}
	}
	if ui_dispatch(editor, ev) {
		return
	}
	if editor.welcome {
		if ev.type == .Key {
			if command_matches(ev, "Quit") {
				editor_request_quit(editor)
				return
			}
			if command_matches(ev, "Command Palette") {
				palette_open(editor)
				return
			}
			// the one rule: a command that does not apply lets its chord pass to the next
			for cmd in editor.plugins.commands {
				if cmd.scope == "" && cmd.welcome && plugin_command_matches(cmd, ev, false) && plugin_command_when(editor, cmd) {
					plugin_command_run(editor, cmd)
					return
				}
			}
		}
		return
	}
}

editor_paste_route :: proc(editor: ^Editor, text: string) {
	if len(text) == 0 || safety_open(editor) {
		return
	}
	if ui_paste(editor, text) {
		return
	}
	if editor.welcome {
		return
	}
	editor_clear_message(editor)
	buffer_paste(editor_buffer(editor), text)
}

editor_wrap_col :: proc(b: ^Buffer, w, row, sub, gutter, x: int) -> int {
	text := b.lines[row].text[:]
	seg_start, seg_end := wrap_segment(buffer_line_wrap(b, row, w), len(text), sub)
	target := visual_col(text, seg_start) + max(0, x - gutter)
	return clamp(col_at_visual(text, target), seg_start, seg_end)
}

editor_paste_accumulate :: proc(editor: ^Editor, ev: tb2.Event) {
	if ev.ch != 0 {
		bytes, n := utf8.encode_rune(ev.ch)
		append(&editor.paste_buf, ..bytes[:n])
		editor.paste_last_cr = false
		return
	}
	#partial switch ev.key {
	case .Enter:
		append(&editor.paste_buf, '\n')
		editor.paste_last_cr = true
	case .Ctrl_J:
		if !editor.paste_last_cr {
			append(&editor.paste_buf, '\n')
		}
		editor.paste_last_cr = false
	case .Tab:
		append(&editor.paste_buf, '\t')
		editor.paste_last_cr = false
	case:
		editor.paste_last_cr = false
	}
}

editor_accel_step :: proc(editor: ^Editor, key: tb2.Key) -> int {
	if !CURSOR_ACCEL {
		return 1
	}
	gap := time.duration_milliseconds(time.tick_since(editor.accel_tick))
	if key == editor.accel_key && gap <= f64(CURSOR_ACCEL_INTERVAL_MS) {
		editor.accel_count += 1
	} else {
		editor.accel_count = 1
		editor.accel_rem = 0
	}
	editor.accel_key = key
	editor.accel_tick = time.tick_now()

	vel := 1.0 + f64(editor.accel_count - 1) / f64(max(1, CURSOR_ACCEL_RAMP_PRESSES))
	vel = min(vel, f64(CURSOR_ACCEL_MAX_STEP))
	editor.accel_rem += vel
	step := int(editor.accel_rem)
	editor.accel_rem -= f64(step)
	return step
}

editor_request_quit :: proc(editor: ^Editor) {
	if editor_any_modified(editor) {
		quit_dialog_open(editor)
	} else {
		editor.quit = true
	}
}

editor_any_modified :: proc(editor: ^Editor) -> bool {
	for &b in editor.buffers {
		if b.modified {
			return true
		}
	}
	return false
}

editor_find_buffer :: proc(editor: ^Editor, path: string) -> int {
	for &b, i in editor.buffers {
		if b.path == path {
			return i
		}
	}
	return -1
}

editor_switch_to :: proc(editor: ^Editor, idx: int) {
	completion_dismiss(editor)
	editor.current = idx
	editor.welcome = false
	plugin_queue(editor, {event = .Buf_Enter, buf = editor.buffers[idx].id})
}

editor_close_buffer :: proc(editor: ^Editor) {
	if editor.welcome {
		return
	}
	if editor_buffer(editor).modified {
		close_dialog_open(editor)
	} else {
		editor_close_current(editor)
	}
}

editor_close_current :: proc(editor: ^Editor) {
	editor_close_index(editor, editor.current)
}

editor_close_index :: proc(editor: ^Editor, idx: int) {
	editor.jump_lock = true
	plugin_queue(editor, {event = .Buf_Close, buf = editor.buffers[idx].id, a = editor.buffers[idx].path})
	lsp_did_close(editor, &editor.buffers[idx])
	plugin_buffer_hooks_drop(&editor.plugins, editor.buffers[idx].id)
	searches_buffer_closed(editor, editor.buffers[idx].id)
	buffer_destroy(&editor.buffers[idx])
	ordered_remove(&editor.buffers, idx)
	if len(editor.buffers) == 0 {
		append(&editor.buffers, buffer_new())
		editor.current = 0
		editor.welcome = true
		return
	}
	if editor.current == idx {
		editor_switch_to(editor, min(idx, len(editor.buffers) - 1))
	} else if editor.current > idx {
		editor.current -= 1
	}
}

editor_open_path :: proc(editor: ^Editor, path: string) -> bool {
	abs, err := filepath.abs(path, context.temp_allocator)
	if err != nil {
		abs = path
	}
	if idx := editor_find_buffer(editor, abs); idx >= 0 {
		editor_switch_to(editor, idx)
		return true
	}

	b := buffer_new()
	if oerr := buffer_open(&b, abs); oerr != .None {
		buffer_destroy(&b)
		editor_log(editor, .Debug, "Files", fmt.tprintf("open failed: %s (%v)", abs, oerr))
		editor_log(editor, .Error, "", fmt.tprintf("Cannot open %s", editor_display_path(editor, abs)))
		return false
	}
	editor_log(editor, .Debug, "Lang", fmt.tprintf("detected %s for %s", LANGUAGES[b.language].name, editor_display_path(editor, abs)))

	editor_switch_to(editor, editor_add_buffer(editor, b))
	return true
}

// a lone untouched scratch buffer gives way to the new one
editor_add_buffer :: proc(editor: ^Editor, b: Buffer) -> int {
	plugin_queue(editor, {event = .Buf_Open, buf = b.id})
	scratch := editor.buffers[0]
	if len(editor.buffers) == 1 && scratch.path == "" && !scratch.modified {
		plugin_buffer_hooks_drop(&editor.plugins, scratch.id)
		searches_buffer_closed(editor, scratch.id)
		buffer_destroy(&editor.buffers[0])
		editor.buffers[0] = b
		return 0
	}
	append(&editor.buffers, b)
	return len(editor.buffers) - 1
}

editor_load_buffer :: proc(editor: ^Editor, path: string) -> int {
	abs, err := filepath.abs(path, context.temp_allocator)
	if err != nil {
		abs = path
	}
	if idx := editor_find_buffer(editor, abs); idx >= 0 {
		return idx
	}
	b := buffer_new()
	if buffer_open(&b, abs) != .None {
		buffer_destroy(&b)
		return -1
	}
	return editor_add_buffer(editor, b)
}

editor_copy :: proc(editor: ^Editor) {
	buffer_copy(editor_buffer(editor))
}

buffer_copy :: proc(b: ^Buffer) {
	if selection_active(b) {
		from, to, _ := selection_range(b)
		clipboard_set(buffer_text_range(b, from, to))
	} else {
		line := b.lines[b.cursor.row].text[:]
		clipboard_set(strings.concatenate({string(line), "\n"}, context.temp_allocator))
	}
}

editor_cut :: proc(editor: ^Editor) {
	buffer_cut(editor_buffer(editor))
}

buffer_cut :: proc(b: ^Buffer) {
	buffer_copy(b)
	if selection_active(b) {
		buffer_delete_selection(b)
	} else {
		buffer_delete_line(b)
	}
}

editor_paste :: proc(editor: ^Editor) {
	buffer_paste_clipboard(editor_buffer(editor))
}

buffer_paste_clipboard :: proc(b: ^Buffer) {
	text := clipboard_get(context.temp_allocator)
	if len(text) > 0 {
		buffer_paste(b, text)
	}
}

editor_save :: proc(editor: ^Editor) {
	editor_save_full(editor, editor_buffer(editor))
}

editor_save_full :: proc(editor: ^Editor, b: ^Buffer) {
	id := b.id
	if plugin_save_pending(&editor.plugins, id) {
		editor_log(editor, .Info, "", "Save is waiting for plugins")
		return
	}
	if buffer_disk_changed(b) {
		editor_save_id(editor, id)
		return
	}
	if plugin_pre_save(editor, id) != 0 {
		return
	}
	editor_save_id(editor, id)
}

editor_save_id :: proc(editor: ^Editor, id: u64) {
	b, idx := api_buf_find(editor, id)
	if b == nil {
		if editor.save_intent != .None {
			editor_save_intent_clear(editor)
			editor_log(editor, .Warn, "", "Buffer closed before its save finished")
		}
		return
	}
	if idx != editor.current && buffer_disk_changed(b) {
		editor_save_intent_clear(editor)
		editor_log(editor, .Warn, "", fmt.tprintf("%s changed on disk, not saved", editor_display_path(editor, b.path)))
		return
	}
	editor_save_buffer(editor, b)
}

editor_save_buffer :: proc(editor: ^Editor, b: ^Buffer) {
	if buffer_disk_changed(b) {
		editor_save_intent_clear(editor)
		conflict_dialog_open(editor, b)
		return
	}
	editor_force_save(editor, b)
	editor_after_save(editor, b)
}

SaveIntent :: enum {
	None,
	Close,
	Quit,
}

editor_save_intent_set :: proc(editor: ^Editor, intent: SaveIntent, path: string) {
	editor_save_intent_clear(editor)
	editor.save_intent = intent
	editor.save_intent_path = strings.clone(path)
}

editor_save_intent_clear :: proc(editor: ^Editor) {
	editor.save_intent = .None
	if len(editor.save_intent_path) > 0 {
		delete(editor.save_intent_path)
	}
	editor.save_intent_path = ""
}

editor_after_save :: proc(editor: ^Editor, b: ^Buffer) {
	switch editor.save_intent {
	case .None:
	case .Close:
		if b.path != editor.save_intent_path {
			return
		}
		editor_save_intent_clear(editor)
		if !b.modified && b == editor_buffer(editor) {
			editor_close_current(editor)
		}
	case .Quit:
		if len(editor.plugins.saves) > 0 {
			return
		}
		editor_save_intent_clear(editor)
		if editor_any_modified(editor) {
			editor_log(editor, .Error, "", "Save failed")
		} else {
			editor.quit = true
		}
	}
}

editor_force_save :: proc(editor: ^Editor, b: ^Buffer) {
	switch buffer_save(b) {
	case .None:
		editor_log(editor, .Debug, "Save", fmt.tprintf("wrote %s (%d lines, %v)", editor_display_path(editor, b.path), len(b.lines), b.line_ending))
		editor_log(editor, .Info, "", "Saved")
		lsp_did_save(editor, b)
		plugin_queue(editor, {event = .Buf_Save, buf = b.id})
	case .NoPath:
		editor_log(editor, .Error, "", "No file name")
	case .WriteError:
		editor_log(editor, .Debug, "Save", fmt.tprintf("temp write failed: %s", editor_display_path(editor, b.path)))
		editor_log(editor, .Error, "", "Save failed")
	case .RenameError:
		editor_log(editor, .Debug, "Save", fmt.tprintf("atomic rename failed: %s", editor_display_path(editor, b.path)))
		editor_log(editor, .Error, "", "Save failed")
	}
}

editor_reload_buffer :: proc(editor: ^Editor, b: ^Buffer) {
	lsp_did_close(editor, b)
	switch buffer_reload(b) {
	case .None:
		plugin_queue(editor, {event = .Buf_Reload, buf = b.id})
		if b == editor_buffer(editor) {
			editor_log(editor, .Info, "", "Reloaded from disk")
		} else {
			editor_log(editor, .Info, "", fmt.tprintf("reloaded %s from disk", editor_display_path(editor, b.path)), show = false)
		}
	case .FileOpenError, .FileReadError:
		editor_log(editor, .Error, "", "Reload failed")
	}
}

editor_display_path :: proc(editor: ^Editor, path: string) -> string {
	root := editor.working_root
	if root != "" && len(path) > len(root) + 1 && path[len(root)] == '/' && strings.has_prefix(path, root) {
		return fmt.tprintf("%s/%s", filepath.base(root), path[len(root) + 1:])
	}
	return path
}

editor_poll_wait_ms :: proc(editor: ^Editor) -> int {
	return clamp(DISK_POLL_MS - int(time.duration_milliseconds(time.tick_since(editor.disk_poll))), 0, DISK_POLL_MS)
}

editor_maybe_poll_disk :: proc(editor: ^Editor) -> bool {
	if time.duration_milliseconds(time.tick_since(editor.disk_poll)) < f64(DISK_POLL_MS) {
		return false
	}
	editor.disk_poll = time.tick_now()
	changed := plugins_poll(editor)
	if editor_maybe_reload_config(editor) {
		changed = true
	}
	if editor_poll_disk(editor) {
		changed = true
	}
	return changed
}

editor_retheme :: proc(editor: ^Editor) {
	syntax_recolor()
	for &b in editor.buffers {
		b.hl.top = -1 // force a repaint so the per-char color cache picks up the new theme
	}
	for _, md in editor.ui.markdowns {
		ui_markdown_reset(md)
	}
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	term_reload_colors(editor)
}

editor_theme_current :: proc(editor: ^Editor) -> string {
	return editor.theme_shown if editor.theme_shown != "" else THEME
}

editor_theme_set :: proc(editor: ^Editor, name: string, persist: bool) -> (ok: bool, err: string) {
	if !slice.contains(theme_names(config_path()), name) {
		return false, fmt.tprintf("unknown theme '%s'", name)
	}
	theme_preview(config_path(), name)
	editor_retheme(editor)
	delete(editor.theme_shown)
	editor.theme_shown = ""
	if !persist {
		if name != THEME {
			editor.theme_shown = strings.clone(name)
		}
		return true, ""
	}
	path := editor.plugins.persist_path if editor.headless else config_path()
	written := theme_persist(path, name)
	plugin_queue(editor, {event = .Theme_Changed})
	editor.config_stamp = buffer_disk_stamp(config_path())
	editor.theme_stamp = buffer_disk_stamp(theme_path(config_path(), THEME))
	if !written {
		return false, "cannot write the theme to config.json"
	}
	return true, ""
}

editor_theme_restore :: proc(editor: ^Editor) {
	if editor.theme_shown == "" {
		return
	}
	delete(editor.theme_shown)
	editor.theme_shown = ""
	theme_preview(config_path(), THEME)
	editor_retheme(editor)
}

editor_maybe_reload_config :: proc(editor: ^Editor) -> bool {
	path := config_path()
	if path == "" {
		return false
	}
	now := buffer_disk_stamp(path)
	tnow := buffer_disk_stamp(theme_path(path, THEME))
	cfg_changed := now.ok && (now.mtime != editor.config_stamp.mtime || now.size != editor.config_stamp.size)
	own_write := cfg_changed && now.mtime == editor.config_written.mtime && now.size == editor.config_written.size
	theme_changed := tnow.ok && (tnow.mtime != editor.theme_stamp.mtime || tnow.size != editor.theme_stamp.size)
	if !cfg_changed && !theme_changed {
		return false
	}
	editor_log(editor, .Debug, "Config", fmt.tprintf("hot-reload: config=%v theme=%v (%s)", cfg_changed, theme_changed, path))
	message, is_error := config_load_from(path)
	// a theme previewed from an open plugin pane (the theme picker) stays shown over a reload
	picker := ui_layer_used(&editor.ui, "pane") || ui_layer_used(&editor.ui, "alert")
	if !picker || editor.theme_shown == "" || !theme_preview(path, editor.theme_shown) {
		delete(editor.theme_shown)
		editor.theme_shown = ""
		theme_preview(path, THEME)
	}
	editor.config_stamp = buffer_disk_stamp(path)
	editor.theme_stamp = buffer_disk_stamp(theme_path(path, THEME))
	editor_retheme(editor)
	lsp_enabled_sync(editor)
	if !editor.headless {
		image_detect_sync()
	}
	plugins_config_apply(editor, theme_changed, !g_config_user_broken)
	if own_write && !theme_changed {
		return true
	}
	if message == "" {
		message = "config.json reloaded"
	}
	editor_log(editor, .Warn if is_error else .Info, "", message)
	return true
}

editor_poll_disk :: proc(editor: ^Editor) -> bool {
	cur := editor_buffer(editor)
	changed := false
	for &b in editor.buffers {
		if b.path == "" || !buffer_disk_changed(&b) {
			continue
		}
		if b.modified {
			if !b.disk_conflict {
				b.disk_conflict = true
				editor_log(editor, .Debug, "Files", fmt.tprintf("disk conflict (unsaved edits): %s", editor_display_path(editor, b.path)))
				if &b == cur {
					editor_log(editor, .Warn, "", "File changed on disk — you have unsaved edits")
					changed = true
				}
			}
			continue
		}
		if highlight_busy(&b) {
			continue // don't swap content under a running parse; retry next poll
		}
		editor_log(editor, .Debug, "Files", fmt.tprintf("disk changed, auto-reloading %s", editor_display_path(editor, b.path)))
		editor_reload_buffer(editor, &b)
		changed = true
	}
	return changed
}

editor_goto :: proc(editor: ^Editor, row, col: int) {
	b := editor_buffer(editor)
	r := clamp(row, 0, len(b.lines) - 1)
	b.selection = nil
	b.cursor = {r, clamp(col, 0, len(b.lines[r].text))}
	cursor_goal_sync(b)
	if _, state := ui_buffer_view(editor, b); state != nil {
		state.center = true
	}
}

highlight_clips_view :: proc(b: ^Buffer, w, h, scroll_row, scroll_sub, scroll_col: int, ghost: bool, top, bot: int) -> []HighlightClip {
	clips := make([dynamic]HighlightClip, context.temp_allocator)
	if w <= 0 {
		return nil
	}
	for row in max(top, 0) ..= min(bot, len(b.lines) - 1) {
		text := b.lines[row].text[:]
		if len(text) < HIGHLIGHT_CLIP_BYTES {
			continue
		}
		lo, hi: int
		if b.wrap {
			// A ghost line wraps from its start, its text only pushing the line's bytes further down.
			segs := buffer_line_wrap(b, row, w)
			sub := clamp(scroll_sub, 0, len(segs) - 1) if row == scroll_row && !(ghost && row == b.cursor.row) else 0
			lo = segs[sub]
			hi = segs[sub + h + 1] if sub + h + 1 < len(segs) else len(text)
		} else {
			lo = col_at_visual(text, scroll_col - 1)
			hi = col_at_visual(text, scroll_col + w + 1)
		}
		append(&clips, HighlightClip{row, lo, hi})
	}
	return clips[:]
}

editor_render :: proc(editor: ^Editor) {
	image_frame_begin()
	tb2.clear()
	editor.caret_view = {}
	ui_prepare(editor)
	editor_syntax_errors_report(editor)
	tree_base := ui_layer_used(&editor.ui, "base")
	if tree_base {
		ui_render(editor)
		if editor.inspect.active && !editor.welcome {
			inspect_render(editor)
		}
		editor_render_overlays(editor, true)
		return
	}
	// without the layout plugin only other mounts draw (the welcome screen is its background mount)
	ui_render(editor)
	if !editor_render_overlays(editor, false) {
		tb2.hide_cursor()
		tb2.present()
	}
}

editor_caret_area :: proc(editor: ^Editor) -> EditorView {
	return editor.caret_view
}

editor_syntax_errors_report :: proc(editor: ^Editor) {
	if g_syntax_error != "" {
		editor_log(editor, .Error, "Syntax", fmt.tprintf("failed to load %s grammar", g_syntax_error))
		editor_log(editor, .Debug, "Syntax", fmt.tprintf("%s %s compile failed", g_syntax_error, g_syntax_error_detail))
		g_syntax_error = ""
		g_syntax_error_detail = ""
	}
	if g_syntax_inject_error != "" {
		editor_log(editor, .Debug, "Syntax", fmt.tprintf("injection query compile failed: %s", g_syntax_inject_error))
		g_syntax_inject_error = ""
	}
}

editor_render_overlays :: proc(editor: ^Editor, tree_base: bool) -> (done: bool) {
	ui_render_alert(editor)
	if editor.ui.caret_shown {
		tb2.set_cursor(i32(editor.ui.caret.x), i32(editor.ui.caret.y))
		tb2.present()
		return true
	}
	if tree_base || ui_focused(editor) != nil {
		tb2.hide_cursor()
		tb2.present()
		return true
	}
	return false
}

wrap_text :: proc(text: string, width: int, allocator := context.temp_allocator) -> [dynamic]string {
	lines := make([dynamic]string, allocator)
	for raw in strings.split(text, "\n", allocator) {
		words := strings.fields(raw, allocator)
		if len(words) == 0 {
			if len(lines) > 0 {
				append(&lines, "")
			}
			continue
		}
		sb := strings.builder_make(allocator)
		for word in words {
			w := word
			for {
				if strings.builder_len(sb) > 0 && strings.builder_len(sb) + 1 + len(w) > width {
					append(&lines, strings.clone(strings.to_string(sb), allocator))
					strings.builder_reset(&sb)
				}
				if len(w) <= width {
					break
				}
				append(&lines, w[:width])
				w = w[width:]
			}
			if strings.builder_len(sb) > 0 {
				strings.write_byte(&sb, ' ')
			}
			strings.write_string(&sb, w)
		}
		if strings.builder_len(sb) > 0 {
			append(&lines, strings.clone(strings.to_string(sb), allocator))
		}
	}
	for len(lines) > 0 && lines[len(lines) - 1] == "" {
		pop(&lines)
	}
	return lines
}

// Lays out the cursor's logical line as prefix + dimmed ghost + suffix and
// renders it through the wrap machinery, so ghost and the relocated suffix obey
// the same soft-wrap rules as real text. Ghost newlines are hard breaks. Returns
// the next screen row.
editor_render_ghost_line :: proc(editor: ^Editor, b: ^Buffer, view: ^EditorView, row, screen_y: int, colors: []tb2.Color, line_bg: tb2.Color) -> int {
	gutter, w, h := view.gutter, view.w, view.y + view.h
	text := b.lines[row].text[:]
	cut := b.cursor.col
	glines := strings.split(b.deco.inline.text, "\n", context.temp_allocator)
	mark := diff_mark_at(b, row)

	sy := screen_y
	first_row := true
	color_at :: proc(colors: []tb2.Color, i: int) -> tb2.Color {
		return colors[i] if colors != nil && i < len(colors) else COLOR_FG
	}
	for gl, gi in glines {
		content := make([dynamic]u8, context.temp_allocator)
		ccol := make([dynamic]tb2.Color, context.temp_allocator)
		if gi == 0 {
			append(&content, ..text[:cut])
			for i in 0 ..< cut {
				append(&ccol, color_at(colors, i))
			}
		}
		append(&content, ..transmute([]u8)gl)
		for _ in 0 ..< len(gl) {
			append(&ccol, COLOR_GHOST_FG)
		}
		if gi == len(glines) - 1 {
			append(&content, ..text[cut:])
			for i in cut ..< len(text) {
				append(&ccol, color_at(colors, i))
			}
		}

		ct := content[:]
		segs := line_wrap(ct, w)
		x_origin := 0
		for s in 0 ..< len(segs) {
			if sy >= h {
				return sy
			}
			seg_start := segs[s]
			seg_end := segs[s + 1] if s + 1 < len(segs) else len(ct)
			if gutter > 0 {
				editor_render_gutter(view.x, sy, gutter, row + 1, true, 0, mark, !first_row, view.gutter_bg)
			}
			editor_render_text_row(view.x + gutter, sy, w, ct, ccol[:], x_origin, line_bg, -1, -1, nil, seg_start, seg_end)
			x_origin = visual_col_from(ct, seg_start, x_origin, seg_end)
			sy += 1
			first_row = false
		}
	}
	return sy
}

editor_render_ghost_gutter :: proc(left, y, width: int, mark: rune = '▌') {
	if width <= 0 {
		return
	}
	tb2.set_cell(i32(left), i32(y), mark, COLOR_GIT_DEL, COLOR_GUTTER_BG)
	for x in 1 ..< width {
		tb2.set_cell(i32(left + x), i32(y), ' ', COLOR_GUTTER_FG, COLOR_GUTTER_BG)
	}
}

// Draws a hunk's removed/base lines as dim-red, non-wrapping ghost rows (one
// screen row each, clipped). Above-hunk lines paired with their live counterpart
// get the changed span emphasized. Returns the next screen row.
editor_render_hunk_ghosts :: proc(b: ^Buffer, view: ^EditorView, row: int, above: bool, screen_y: int) -> int {
	gutter, w, h := view.gutter, view.w, view.y + view.h
	hunk, ok := diff_hunk_at(b, row, above)
	if !ok {
		return screen_y
	}
	ghost_bg := color_over(COLOR_BG, COLOR_GIT_DEL, GIT_DIFF_GHOST_TINT)
	word_bg := color_over(COLOR_BG, COLOR_GIT_DEL, GIT_DIFF_WORD_TINT)
	sy := screen_y
	for gi in 0 ..< hunk.hi - hunk.lo {
		if sy >= h {
			break
		}
		old := transmute([]u8)b.base.base_text[hunk.lo + gi]
		df, dt := -1, -1
		if above && gi < hunk.new_n && hunk.row + gi < len(b.lines) {
			ospan, _ := diff_word_span(string(old), string(b.lines[hunk.row + gi].text[:]))
			df, dt = ospan[0], ospan[1]
		}
		ccol := make([]tb2.Color, len(old), context.temp_allocator)
		for i in 0 ..< len(old) {
			ccol[i] = COLOR_GHOST_FG
		}
		editor_render_ghost_gutter(view.x, sy, gutter)
		editor_render_text_row(view.x + gutter, sy, w, old, ccol, 0, ghost_bg, -1, -1, nil, 0, len(old), df, dt, word_bg)
		sy += 1
	}
	return sy
}

EditorView :: struct {
	buffer:                             ^Buffer,
	x, y, w, h:                         int,
	gutter:                             int,
	scroll_row, scroll_sub, scroll_col: int,
	bg:                                 tb2.Color,
	fg:                                 tb2.Color,
	gutter_bg:                          tb2.Color,
	fg_set:                             bool,
	syntax, current_line:               bool,
	// an unfocused editor with a highlight_style marks its cursor row (a preview's target) in that background
	target_bg:                          Maybe(tb2.Color),
	find, inline:                       bool,
}

editor_render_view :: proc(editor: ^Editor, view: ^EditorView) {
	b := view.buffer
	gutter := view.gutter
	w := view.w
	bottom := view.y + view.h
	text_x := view.x + gutter

	sel_from, sel_to, sel_ok := selection_range(b)

	bra, brm: Cursor
	br_ok := false
	if !b.big && !sel_ok {
		bra, brm, br_ok = bracket_match(b)
	}

	pal := deco_palette(editor.plugins.colors[:])
	drows := deco_rows(b, view.scroll_row, view.scroll_row + view.h, pal)

	b.wrap_width = w
	wrapping := b.wrap && w > 0
	gap := inline_gap(editor) if view.inline else 0
	// inline_render draws the cursor line's suffix after the ghost, so the line stops at the caret
	ghost_cut := view.inline && inline_active(editor)
	screen_y := view.y
	for row := view.scroll_row; row < len(b.lines) && screen_y < bottom; row += 1 {
		current := row == b.cursor.row
		severity := 0
		for d in b.diags {
			if row >= d.from.row && row <= d.to.row && (severity == 0 || d.severity < severity) {
				severity = d.severity
			}
		}
		mark := diff_mark_at(b, row)

		text := b.lines[row].text
		row_sel_from, row_sel_to := -1, -1
		if sel_ok && row >= sel_from.row && row <= sel_to.row {
			row_sel_from = sel_from.col if row == sel_from.row else 0
			row_sel_to = sel_to.col if row == sel_to.row else len(text) + 1
		}
		underlines := make([dynamic][2]int, context.temp_allocator)
		for d in b.diags {
			if row < d.from.row || row > d.to.row {
				continue
			}
			ds := clamp(d.from.col if row == d.from.row else 0, 0, len(text))
			de := clamp(d.to.col if row == d.to.row else len(text), 0, len(text))
			if ds == de {
				de = min(de + 1, len(text))
			}
			if ds < de {
				append(&underlines, [2]int{ds, de})
			}
		}
		if br_ok {
			if bra.row == row {
				append(&underlines, [2]int{bra.col, bra.col + 1})
			}
			if brm.row == row {
				append(&underlines, [2]int{brm.col, brm.col + 1})
			}
		}
		colors: []tb2.Color
		if view.syntax {
			colors = highlight_colors(b, row)
		}
		if len(colors) == 0 && view.fg_set {
			colors = make([]tb2.Color, len(text), context.temp_allocator)
			slice.fill(colors, view.fg)
		}
		drow := drows[row - view.scroll_row] if row - view.scroll_row < len(drows) else DecoRow{}
		line_bg := editor_line_bg(current && view.current_line, mark, diff_view_on(), drow.tints[:], view.bg)
		if target, marked := view.target_bg.?; current && marked {
			line_bg = target
		}

		// A modification's changed span on the live line, emphasized against its base pair.
		diff_from, diff_to := -1, -1
		diff_bg := tb2.Color(0)
		if diff_view_on() && mark == .Modified {
			if old, ok := diff_pair_old(b, row); ok {
				_, nspan := diff_word_span(old, string(text[:]))
				diff_from, diff_to = nspan[0], nspan[1]
				diff_bg = color_over(line_bg, COLOR_GIT_MOD, GIT_DIFF_WORD_TINT)
			}
		}

		match_spans: [][2]int
		if view.find {
			match_spans = find_row_spans(editor, b, row)
		}

		// Deleted/replaced base lines render as dim-red ghost rows: above a
		// modification, below a pure deletion. Hidden for the top line.
		if row != view.scroll_row {
			screen_y = editor_render_deco_ghosts(b, view, row, true, screen_y, pal)
			screen_y = editor_render_hunk_ghosts(b, view, row, true, screen_y)
			if screen_y >= bottom {
				break
			}
		}

		ghost_row := ghost_cut && row == b.cursor.row
		if wrapping {
			if ghost_row {
				// Ghost + suffix wrap as one flow, pushing lines below down by the
				// rows they consume (no separate gap needed).
				screen_y = editor_render_ghost_line(editor, b, view, row, screen_y, colors, line_bg)
			} else {
				segs := buffer_line_wrap(b, row, w)
				start_sub := view.scroll_sub if row == view.scroll_row else 0
				x_origin := visual_col(text[:], segs[start_sub]) if start_sub < len(segs) else 0
				for s in start_sub ..< len(segs) {
					if screen_y >= bottom {
						break
					}
					seg_start := segs[s]
					seg_end := segs[s + 1] if s + 1 < len(segs) else len(text)
					x_end := visual_col_from(text[:], seg_start, x_origin, seg_end)
					if gutter > 0 {
						editor_render_gutter(view.x, screen_y, gutter, row + 1, current, severity, mark, s > 0, view.gutter_bg, drow.glyph, drow.glyph_fg)
					}
					editor_render_text_row(text_x, screen_y, w, text[:], colors, x_origin, line_bg, row_sel_from, row_sel_to, underlines[:], seg_start, seg_end, diff_from, diff_to, diff_bg, match_spans, COLOR_FIND_MATCH_BG, drow.spans[:])
					if s == len(segs) - 1 && len(drow.eols) > 0 {
						editor_render_eol(text_x, screen_y, w, x_end - x_origin + 1, drow.eols[:], line_bg)
					}
					x_origin = x_end
					screen_y += 1
				}
			}
		} else {
			text_end := b.cursor.col if ghost_row else len(text)
			if gutter > 0 {
				editor_render_gutter(view.x, screen_y, gutter, row + 1, current, severity, mark, false, view.gutter_bg, drow.glyph, drow.glyph_fg)
			}
			editor_render_text_row(text_x, screen_y, w, text[:], colors, view.scroll_col, line_bg, row_sel_from, row_sel_to, underlines[:], 0, text_end, diff_from, diff_to, diff_bg, match_spans, COLOR_FIND_MATCH_BG, drow.spans[:])
			if !ghost_row && len(drow.eols) > 0 {
				editor_render_eol(text_x, screen_y, w, visual_col(text[:], len(text)) - view.scroll_col + 1, drow.eols[:], line_bg)
			}
			screen_y += 1
			if gap > 0 && row == b.cursor.row {
				screen_y += gap
			}
		}
		if screen_y < bottom {
			screen_y = editor_render_deco_ghosts(b, view, row, false, screen_y, pal)
		}
		if screen_y < bottom {
			screen_y = editor_render_hunk_ghosts(b, view, row, false, screen_y)
		}
	}
}

StatusSegKind :: enum {
	Plain,
	Path,
	Plugin,
}

StatusChunk :: struct {
	text: string,
	fg:   tb2.Color,
}

StatusSeg :: struct {
	sep, text: string,
	fg:        tb2.Color,
	chunks:    []StatusChunk,
	kind:      StatusSegKind,
	drop:      int,
	hidden:    bool,
}

status_width :: proc(segs: []StatusSeg) -> int {
	w := 0
	first := true
	for s in segs {
		if s.hidden {
			continue
		}
		if !first {
			w += visual_width(transmute([]u8)s.sep)
		}
		w += visual_width(transmute([]u8)s.text)
		first = false
	}
	return w
}

status_overflow :: proc(left, right: []StatusSeg, width: int) -> int {
	need := status_width(left)
	if rw := status_width(right); rw > 0 {
		need += 1 + rw + 1
	}
	return need - width
}

status_path_shorten :: proc(path: string) -> (string, bool) {
	if strings.has_prefix(path, "…/") {
		rest := path[len("…/"):]
		if i := strings.index_byte(rest, '/'); i >= 0 {
			return fmt.tprintf("…/%s", rest[i + 1:]), true
		}
		return rest, true
	}
	if len(path) < 2 {
		return path, false
	}
	if i := strings.index_byte(path[1:], '/'); i >= 0 {
		return fmt.tprintf("…/%s", path[i + 2:]), true
	}
	return path, false
}

status_clip :: proc(text: string, w: int) -> string {
	bytes := transmute([]u8)text
	if visual_width(bytes) <= w {
		return text
	}
	if w <= 0 {
		return ""
	}
	c := col_at_visual(bytes, w - 1)
	if visual_width(bytes[:c]) > w - 1 {
		c = col_at_visual(bytes, w - 2)
	}
	return fmt.tprintf("%s…", text[:c])
}

status_fit :: proc(left, right: []StatusSeg, width: int) {
	path := -1
	for s, i in left {
		if s.kind == .Path {
			path = i
		}
	}
	for status_overflow(left, right, width) > 0 {
		if path >= 0 {
			if short, ok := status_path_shorten(left[path].text); ok {
				left[path].text = short
				continue
			}
		}
		victim: ^StatusSeg
		for side in ([2][]StatusSeg{left, right}) {
			for &s in side {
				if !s.hidden && s.drop > 0 && (victim == nil || s.drop < victim.drop) {
					victim = &s
				}
			}
		}
		if victim == nil {
			break
		}
		victim.hidden = true
	}
	if over := status_overflow(left, right, width); over > 0 && path >= 0 {
		pw := visual_width(transmute([]u8)left[path].text)
		left[path].text = status_clip(left[path].text, pw - over)
	}
	for side in ([2][]StatusSeg{left, right}) {
		for &s in side {
			over := status_overflow(left, right, width)
			if over <= 0 {
				return
			}
			if s.kind != .Plugin || s.hidden {
				continue
			}
			if sw := visual_width(transmute([]u8)s.text); sw - over >= 1 {
				s.text = status_clip(s.text, sw - over)
			} else {
				s.hidden = true
			}
		}
	}
}

status_draw :: proc(segs: []StatusSeg, x, y, max_x: int, bg: tb2.Color) {
	x := x
	first := true
	for s in segs {
		if s.hidden {
			continue
		}
		if !first {
			x += visual_width(transmute([]u8)s.sep)
		}
		first = false
		if len(s.chunks) > 0 {
			cx := x
			for ch in s.chunks {
				if cx < max_x {
					draw_text(cx, y, int(tb2.width()) - cx, ch.text, ch.fg, bg)
				}
				cx += visual_width(transmute([]u8)ch.text)
			}
		} else if x < max_x {
			draw_text(x, y, int(tb2.width()) - x, s.text, s.fg, bg)
		}
		x += visual_width(transmute([]u8)s.text)
	}
}

// the status bar's segments: core ones (path, row/total, language, LSP, indent, diff base, buffer index) and every
// plugin's qed.status segment, in the order the bar fits them
status_segments :: proc(editor: ^Editor, left, right: ^[dynamic]StatusSeg) {
	fg := COLOR_PANE_FG
	if editor.welcome {
		append(left, StatusSeg{text = " ", fg = fg})
		append(left, StatusSeg{text = editor.working_root, fg = fg, kind = .Path})
		append(right, StatusSeg{sep = "  ", text = fmt.tprintf("qed %s", VERSION), fg = fg, drop = 5})
	} else {
		b := editor_buffer(editor)
		name := editor_display_path(editor, b.path) if b.path != "" else "[No Name]"
		append(left, StatusSeg{text = fmt.tprintf(" %s", ICON_STATUS_FILE), fg = fg})
		append(left, StatusSeg{sep = " ", text = name, fg = fg, kind = .Path})
		if b.modified {
			append(left, StatusSeg{sep = " ", text = ICON_MODIFIED, fg = fg})
		}
		append(left, StatusSeg{sep = "  ", text = fmt.tprintf("%d/%d", b.cursor.row + 1, len(b.lines)), fg = fg})

		append(right, StatusSeg{sep = "  ", text = fmt.tprintf("%s %s", ICON_STATUS_LANG, LANGUAGES[b.language].name), fg = fg, drop = 4})
		if b.big {
			append(right, StatusSeg{sep = "  ", text = "big", fg = fg, drop = 3})
		} else if LSP_ENABLED {
			if label, lsp_fg, ok := lsp_status_label(b); ok {
				append(right, StatusSeg{sep = "  ", text = fmt.tprintf("%s %s", ICON_STATUS_LSP, label), fg = lsp_fg, drop = 2})
			}
		}
		indent := "Tabs" if b.indent == .Tabs else fmt.tprintf("Spaces:%d", b.indent_width)
		append(right, StatusSeg{sep = "  ", text = fmt.tprintf("%s %s", ICON_STATUS_INDENT, indent), fg = fg, drop = 1})
	}
	plugin_status_segs(&editor.plugins, left, right, true)
	if !editor.welcome {
		if base := diffbase_active(editor_buffer(editor)); base != nil && base.label != "" {
			append(left, StatusSeg{sep = "  ", text = fmt.tprintf("%s%s", ICON_STATUS_DIFF_BASE, base.label), fg = fg, drop = 8})
		}
	}
	if len(editor.buffers) > 1 {
		append(left, StatusSeg{sep = "  ", text = fmt.tprintf("[%d/%d]", editor.current + 1, len(editor.buffers)), fg = fg, drop = 10})
	}
	plugin_status_segs(&editor.plugins, left, right, false)
}

// the `status` node: the bar fitted to its rect
status_render :: proc(editor: ^Editor, rect: Rect, bg: tb2.Color) {
	left := make([dynamic]StatusSeg, context.temp_allocator)
	right := make([dynamic]StatusSeg, context.temp_allocator)
	status_segments(editor, &left, &right)
	status_fit(left[:], right[:], rect.w)
	editor_render_row(rect.x, rect.y, rect.w, "", COLOR_PANE_FG, bg)
	status_draw(left[:], rect.x, rect.y, rect.x + rect.w, bg)
	if rw := status_width(right[:]); rw > 0 {
		status_draw(right[:], rect.x + rect.w - rw - 1, rect.y, rect.x + rect.w, bg)
	}
}

editor_render_gutter :: proc(left, y, width, number: int, current: bool, severity: int, mark: DiffMark, continuation: bool, bg: tb2.Color, glyph: rune = 0, glyph_fg := tb2.Color(0)) {
	if continuation {
		for x in 0 ..< width {
			tb2.set_cell(i32(left + x), i32(y), ' ', COLOR_GUTTER_FG, bg)
		}
		return
	}
	mark_ch, mark_fg := diff_mark_glyph(mark)
	if mark == .None && glyph != 0 {
		mark_ch, mark_fg = glyph, glyph_fg
	}
	tb2.set_cell(i32(left), i32(y), mark_ch, mark_fg, bg)

	label := fmt.tprintf("%d", number)
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< width - 2 - len(label) {
		strings.write_byte(&sb, ' ')
	}
	strings.write_string(&sb, label)
	if severity > 0 {
		strings.write_string(&sb, diagnostic_glyph(severity))
	} else {
		strings.write_byte(&sb, ' ')
	}
	fg := COLOR_CURRENT_LINE_FG if current else COLOR_GUTTER_FG
	if severity > 0 {
		fg = diagnostic_color(severity)
	}
	cstr := strings.clone_to_cstring(strings.to_string(sb), context.temp_allocator)
	tb2.print(i32(left + 1), i32(y), fg, bg, cstr)
}

color_over :: proc(base, tint: tb2.Color, alpha: f32) -> tb2.Color {
	b := u64(base) & 0xffffff
	t := u64(tint) & 0xffffff
	chan :: proc(base, tint: u64, shift: uint, alpha: f32) -> u64 {
		bc := f32((base >> shift) & 0xff)
		tc := f32((tint >> shift) & 0xff)
		return u64(bc + (tc - bc) * alpha + 0.5) << shift
	}
	return tb2.Color(chan(b, t, 16, alpha) | chan(b, t, 8, alpha) | chan(b, t, 0, alpha))
}

editor_line_bg :: proc(current: bool, mark: DiffMark, hunk: bool, tints: []RowTint = nil, base := COLOR_BG) -> tb2.Color {
	bg := base
	if hunk {
		#partial switch mark {
		case .Added:
			bg = color_over(bg, COLOR_GIT_ADD, GIT_HUNK_TINT)
		case .Modified:
			bg = color_over(bg, COLOR_GIT_MOD, GIT_HUNK_TINT)
		}
	}
	for t in tints {
		bg = color_over(bg, t.color, t.alpha)
	}
	if current {
		bg = color_over(bg, COLOR_CURRENT_LINE_BG, CURRENT_LINE_TINT)
	}
	return bg
}

// Renders the byte range [col_start, col_end) of `text` on screen row `y`.
// `x_origin` is the visual column mapped to screen x 0 (horizontal scroll when
// unwrapped; the segment's start column when wrapped). Clusters outside the
// range still advance the running visual column so tab stops stay absolute.
editor_render_text_row :: proc(
	gutter, y, w: int,
	text: []u8,
	colors: []tb2.Color,
	x_origin: int,
	bg_normal: tb2.Color,
	sel_from, sel_to: int,
	underlines: [][2]int,
	col_start, col_end: int,
	diff_from := -1,
	diff_to := -1,
	diff_bg := tb2.Color(0),
	match_spans: [][2]int = nil,
	match_bg := tb2.Color(0),
	spans: []RowSpan = nil,
) {
	for sx in 0 ..< w {
		tb2.set_cell(i32(gutter + sx), i32(y), ' ', COLOR_FG, bg_normal)
	}

	draw :: proc(gutter, y, sx, w: int, ch: rune, selected: bool, fg_base, bg_normal: tb2.Color) {
		if sx < 0 || sx >= w {
			return
		}
		fg, bg := fg_base, bg_normal
		if selected {
			fg, bg = tb2.Color(u64(COLOR_BG) | color_attrs(fg_base)), COLOR_FG
		}
		tb2.set_cell(i32(gutter + sx), i32(y), ch, fg, bg)
	}

	draw_cluster :: proc(
		gutter, y, w: int,
		cluster: []u8,
		vcol, scroll_col: int,
		selected: bool,
		fg_base, bg_normal: tb2.Color,
	) -> int {
		if cluster[0] == '\t' {
			next := (vcol / TAB_WIDTH + 1) * TAB_WIDTH
			for v in vcol ..< next {
				draw(gutter, y, v - scroll_col, w, ' ', selected, fg_base, bg_normal)
			}
			return next
		}
		sx := vcol - scroll_col
		if sx >= 0 && sx < w {
			r, n := utf8.decode_rune(cluster)
			draw(gutter, y, sx, w, r, selected, fg_base, bg_normal)
			rest := cluster[n:]
			for len(rest) > 0 {
				rr, m := utf8.decode_rune(rest)
				tb2.extend_cell(i32(gutter + sx), i32(y), rr)
				rest = rest[m:]
			}
		}
		return vcol + cluster_width(cluster)
	}

	underlined :: proc(underlines: [][2]int, col: int) -> bool {
		for r in underlines {
			if col >= r[0] && col < r[1] {
				return true
			}
		}
		return false
	}

	emit :: proc(gutter, y, w: int, text: []u8, pstart, pend, vcol, x_origin, col_start, col_end: int, psel: bool, pfg, bg_normal: tb2.Color) -> int {
		if pstart >= col_start && pstart < col_end {
			return draw_cluster(gutter, y, w, text[pstart:pend], vcol, x_origin, psel, pfg, bg_normal)
		}
		return vcol + seg_width(text, pstart, pend, vcol)
	}

	// A wrap segment (col_start > 0) starts at screen x 0, so its visual column is x_origin.
	i := col_start if col_start > 0 else 0
	vcol := x_origin if i > 0 else 0
	next_match := 0
	clipped := false
	for i < len(text) {
		if i >= col_end || vcol - x_origin >= w {
			clipped = true
			break
		}
		e := cluster_end(text, i)
		if vcol + max(TAB_WIDTH, 2) <= x_origin {
			vcol += seg_width(text, i, e, vcol)
			i = e
			continue
		}
		sel := sel_from >= 0 && i >= sel_from && i < sel_to
		fg := colors[i] if colors != nil && i < len(colors) else COLOR_FG
		if underlined(underlines, i) {
			fg = tb2.Color(u64(fg) | u64(tb2.Color.Underline))
		}
		bg := diff_bg if diff_from >= 0 && i >= diff_from && i < diff_to else bg_normal
		for sp in spans {
			if i >= sp.from && i < sp.to {
				if sp.has_fg {
					fg = tb2.Color(u64(sp.fg) | color_attrs(fg))
				}
				if sp.has_bg {
					bg = color_over(bg_normal, sp.bg, sp.alpha) if sp.blend else sp.bg
				}
				fg = tb2.Color(u64(fg) | sp.attrs)
			}
		}
		for next_match < len(match_spans) && match_spans[next_match][1] <= i {
			next_match += 1
		}
		if next_match < len(match_spans) && i >= match_spans[next_match][0] {
			bg = match_bg
		}
		vcol = emit(gutter, y, w, text, i, e, vcol, x_origin, col_start, col_end, sel, fg, bg)
		i = e
	}
	if !clipped && col_end >= len(text) && sel_from >= 0 && len(text) >= sel_from && len(text) < sel_to {
		draw(gutter, y, vcol - x_origin, w, ' ', true, COLOR_FG, bg_normal)
	}
}

editor_render_row :: proc(x, y, w: int, text: string, fg, bg: tb2.Color) {
	bytes := transmute([]u8)text
	row := text
	pad := w - visual_width(bytes)
	if pad < 0 {
		row = text[:col_at_visual(bytes, w)]
		pad = 0
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, row)
	for _ in 0 ..< pad {
		strings.write_byte(&sb, ' ')
	}
	draw_text(x, y, w, strings.to_string(sb), fg, bg)
}
