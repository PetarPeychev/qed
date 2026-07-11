package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

STATUS_ROWS :: 2
HOVER_PANE_MAX_LINES :: 40

Editor :: struct {
	buffers:         [dynamic]Buffer,
	current:         int,
	working_root:    string,
	welcome:         bool,
	scroll_row:      int,
	scroll_sub:      int,
	scroll_col:      int,
	message:         string,
	message_store:   [dynamic]u8,
	message_source:  string,
	message_level:   LogLevel,
	log:             [dynamic]LogEntry,
	logview:         LogView,
	log_file:        ^os.File,
	log_open:        bool,
	quit_dialog:     QuitDialog,
	close_dialog:    CloseDialog,
	conflict_dialog: ConflictDialog,
	merge_dialog:    MergeDialog,
	disk_poll:       time.Tick,
	config_stamp:    DiskStamp,
	theme_stamp:     DiskStamp,
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
	palette:         Palette,
	picker:          Picker,
	bufswitch:       BufSwitch,
	langpick:        LangPick,
	themepick:       ThemePick,
	indentpick:      IndentPick,
	linefind:        LineFind,
	find:            Find,
	projsearch:      ProjSearch,
	rename:          Rename,
	filetree:        FileTree,
	gitstat:         GitStat,
	jumps:           JumpList,
	jump_lock:       bool,
	hover:           [dynamic]u8,
	hover_active:    bool,
	hover_scroll:    int,
	hover_lang:      Language,
	hover_rect:      Rect,
	completion:      Completion,
	format_on_save:  bool,
	trim_trailing_whitespace_on_save: bool,
	ensure_final_newline_on_save: bool,
	save_intent:     SaveIntent,
	save_intent_path: string,
	llm:             Llm,
	aiedit:          AiEdit,
	fim:             Fim,
	terminal:        Terminal,
	inspect:         Inspect,
	headless:        bool,
}

editor_init :: proc(path: string = "", headless := false) -> Editor {
	// headless: a test has already brought up the termbox backend (init_fd on a
	// PTS) and owns its teardown; skip the real-terminal bring-up here.
	if !headless {
		tb2.init()
		tb2.set_output_mode(.Truecolor)
		tb2.set_input_mode(.Mouse)
		tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	}
	clipboard_headless = headless
	editor := Editor {
		buffers        = make([dynamic]Buffer, 0, 8),
		format_on_save = FORMAT_ON_SAVE,
		trim_trailing_whitespace_on_save = TRIM_TRAILING_WHITESPACE_ON_SAVE,
		ensure_final_newline_on_save = ENSURE_FINAL_NEWLINE_ON_SAVE,
		fim            = Fim{enabled = LLM_COMPLETION_ENABLED},
		filetree       = FileTree{show_dotfiles = FILETREE_SHOW_DOTFILES, show_ignored = FILETREE_SHOW_IGNORED},
		logview        = LogView{filter = {.Debug = false, .Info = true, .Warn = true, .Error = true}},
		headless       = headless,
	}
	g_diff_view = GIT_DIFF_VIEW
	if !headless {
		editor_log_seed(&editor)
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
	return editor
}

editor_shutdown :: proc(editor: ^Editor) {
	lsp_stop(editor)
	for &b in editor.buffers {
		buffer_destroy(&b)
	}
	delete(editor.buffers)
	git_stat_destroy(&editor.gitstat)
	editor_save_intent_clear(editor)
	delete(editor.working_root)
	delete(editor.paste_buf)
	delete(editor.message_store)
	editor_log_destroy(editor)
	delete(editor.hover)
	completion_destroy(&editor.completion)
	palette_destroy(&editor.palette)
	picker_destroy(&editor.picker)
	bufswitch_destroy(&editor.bufswitch)
	langpick_destroy(&editor.langpick)
	themepick_destroy(&editor.themepick)
	indentpick_destroy(&editor.indentpick)
	linefind_destroy(&editor.linefind)
	find_destroy(&editor.find)
	projsearch_destroy(&editor.projsearch)
	rename_destroy(&editor.rename)
	filetree_destroy(&editor.filetree)
	jump_destroy(&editor.jumps)
	llm_cancel_all(editor)
	delete(editor.llm.requests)
	fim_dismiss(editor)
	aiedit_destroy(&editor.aiedit)
	term_destroy(editor)
	// Process-global singletons (seeded once at @(init) / lazily, shared across
	// every editor); real main tears them down once at exit. A headless test reuses
	// them across many sessions, so freeing them here would dangle the next one.
	if !editor.headless {
		delete(g_language_rules)
		syntax_shutdown()
		clipboard_shutdown()
		log_tz_shutdown()
		tb2.shutdown()
	}
}

editor_buffer :: proc(editor: ^Editor) -> ^Buffer {
	return &editor.buffers[editor.current]
}

editor_set_language :: proc(editor: ^Editor, lang: Language) {
	b := editor_buffer(editor)
	if b.language == lang {
		return
	}
	if b.lsp_open {
		lsp_did_close(editor, b)
	}
	b.language = lang
	highlight_destroy(&b.hl)
	b.hl = {}
	editor_log(editor, .Info, "", fmt.tprintf("Language: %s", LANGUAGES[lang].name))
}

editor_gutter_width :: proc(editor: ^Editor) -> int {
	return digit_count(len(editor_buffer(editor).lines)) + 2
}

editor_viewport :: proc(editor: ^Editor) -> (w, h: int) {
	w = max(0, int(tb2.width()) - editor_gutter_width(editor))
	h = max(0, int(tb2.height()) - STATUS_ROWS)
	return
}

Overlay :: struct {
	active:   ^bool,
	dispatch: proc(editor: ^Editor, ev: tb2.Event),
	render:   proc(editor: ^Editor),
	mouse:    proc(editor: ^Editor, ev: tb2.Event),
	paste:    proc(editor: ^Editor, text: string),
}

editor_overlays :: proc(editor: ^Editor) -> [18]Overlay {
	return {
		{&editor.terminal.active, term_dispatch, term_render, term_dispatch_mouse, term_paste_overlay},
		{&editor.logview.active, logview_dispatch_key, logview_render, logview_dispatch_mouse, nil},
		{&editor.aiedit.active, aiedit_dispatch_key, aiedit_render, aiedit_dispatch_mouse, aiedit_paste},
		{&editor.palette.active, palette_dispatch_key, palette_render, palette_dispatch_mouse, palette_paste},
		{&editor.picker.active, picker_dispatch_key, picker_render, picker_dispatch_mouse, picker_paste},
		{&editor.bufswitch.active, bufswitch_dispatch_key, bufswitch_render, bufswitch_dispatch_mouse, bufswitch_paste},
		{&editor.langpick.active, langpick_dispatch_key, langpick_render, langpick_dispatch_mouse, langpick_paste},
		{&editor.themepick.active, themepick_dispatch_key, themepick_render, themepick_dispatch_mouse, themepick_paste},
		{&editor.indentpick.active, indentpick_dispatch_key, indentpick_render, indentpick_dispatch_mouse, indentpick_paste},
		{&editor.linefind.active, linefind_dispatch_key, linefind_render, linefind_dispatch_mouse, linefind_paste},
		{&editor.find.active, find_dispatch_key, find_render, find_dispatch_mouse, find_paste},
		{&editor.projsearch.active, projsearch_dispatch_key, projsearch_render, projsearch_dispatch_mouse, projsearch_paste},
		{&editor.rename.active, rename_dispatch_key, rename_render, rename_dispatch_mouse, rename_paste},
		{&editor.filetree.active, filetree_dispatch_key, filetree_render, filetree_dispatch_mouse, filetree_paste},
		{&editor.quit_dialog.active, quit_dialog_dispatch_key, quit_dialog_render, quit_dialog_dispatch_mouse, nil},
		{&editor.close_dialog.active, close_dialog_dispatch_key, close_dialog_render, close_dialog_dispatch_mouse, nil},
		{&editor.conflict_dialog.active, conflict_dialog_dispatch_key, conflict_dialog_render, conflict_dialog_dispatch_mouse, nil},
		{&editor.merge_dialog.active, merge_dialog_dispatch_key, merge_dialog_render, merge_dialog_dispatch_mouse, nil},
	}
}

editor_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	origin := jump_here(editor)
	defer jump_record(editor, origin)
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
	for ov in editor_overlays(editor) {
		if ov.active^ {
			#partial switch ev.type {
			case .Key:
				ov.dispatch(editor, ev)
			case .Mouse:
				if ov.mouse != nil {
					ov.mouse(editor, ev)
				}
			case .Resize:
				editor_scroll(editor)
				if editor.terminal.active {
					term_resize(editor)
				}
			}
			return
		}
	}
	if editor.welcome {
		if ev.type == .Key {
			if command_matches(ev, "Find in Files") {
				projsearch_open(editor)
				return
			}
			if command_matches(ev, "File Tree") {
				filetree_open(editor)
				return
			}
			if command_matches(ev, "Terminal: Toggle") {
				term_toggle(editor)
				return
			}
			if command_matches(ev, "Debug: Message Log") {
				logview_open(editor)
				return
			}
			if command_matches(ev, "Open File") {
				picker_open(editor)
				return
			}
			if command_matches(ev, "Quit") {
				editor_request_quit(editor)
				return
			}
			#partial switch ev.key {
			case .Ctrl_P:
				palette_open(editor)
			}
		}
		return
	}
	#partial switch ev.type {
	case .Key:
		editor_dispatch_key(editor, ev)
	case .Mouse:
		editor_dispatch_mouse(editor, ev)
	case .Resize:
		editor_scroll(editor)
	}
}

editor_paste_route :: proc(editor: ^Editor, text: string) {
	if len(text) == 0 {
		return
	}
	for ov in editor_overlays(editor) {
		if ov.active^ {
			if ov.paste != nil {
				ov.paste(editor, text)
			}
			return
		}
	}
	if editor.welcome {
		return
	}
	editor_clear_message(editor)
	buffer_paste(editor_buffer(editor), text)
	editor_scroll(editor)
}

editor_mouse_cursor :: proc(editor: ^Editor, x, y: int) -> Cursor {
	b := editor_buffer(editor)
	gutter := editor_gutter_width(editor)
	w, h := editor_viewport(editor)
	if b.wrap && w > 0 {
		row, sub := vpos_down(b, w, editor.scroll_row, editor.scroll_sub, clamp(y, 0, h - 1))
		return {row, editor_wrap_col(b, w, row, sub, gutter, x)}
	}
	row, _ := vpos_down(b, w, editor.scroll_row, 0, clamp(y, 0, h - 1))
	col := col_at_visual(b.lines[row].text[:], editor.scroll_col + max(0, x - gutter))
	return {row, col}
}

editor_wrap_col :: proc(b: ^Buffer, w, row, sub, gutter, x: int) -> int {
	text := b.lines[row].text[:]
	seg_start, seg_end := wrap_segment(text, w, sub)
	target := visual_col(text, seg_start) + max(0, x - gutter)
	return clamp(col_at_visual(text, target), seg_start, seg_end)
}

editor_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	if editor.hover_active && mouse_in_rect(ev, editor.hover_rect) {
		#partial switch ev.key {
		case .Mouse_Wheel_Up:
			editor.hover_scroll = max(0, editor.hover_scroll - WHEEL_SCROLL_LINES)
			return
		case .Mouse_Wheel_Down:
			editor.hover_scroll += WHEEL_SCROLL_LINES
			return
		}
	}
	editor_clear_message(editor)
	editor.hover_active = false
	completion_dismiss(editor)
	fim_dismiss(editor)
	b := editor_buffer(editor)

	#partial switch ev.key {
	case .Mouse_Left:
		buffer_undo_commit(b)
		if ev_motion(ev) {
			selection_set_anchor(b)
			w, h := editor_viewport(editor)
			gutter := editor_gutter_width(editor)
			y := int(ev.y)
			if b.wrap && w > 0 {
				tr, ts: int
				switch {
				case y <= 0:
					tr, ts = vpos_up(b, w, editor.scroll_row, editor.scroll_sub, 1)
				case y >= h - 1:
					tr, ts = vpos_down(b, w, editor.scroll_row, editor.scroll_sub, h)
				case:
					tr, ts = vpos_down(b, w, editor.scroll_row, editor.scroll_sub, y)
				}
				b.cursor = {tr, editor_wrap_col(b, w, tr, ts, gutter, int(ev.x))}
				cursor_goal_sync(b)
				editor_scroll(editor)
				return
			}
			row: int
			switch {
			case y <= 0:
				row, _ = vpos_up(b, w, editor.scroll_row, 0, 1)
			case y >= h - 1:
				row, _ = vpos_down(b, w, editor.scroll_row, 0, h)
			case:
				row, _ = vpos_down(b, w, editor.scroll_row, 0, y)
			}
			col := col_at_visual(b.lines[row].text[:], editor.scroll_col + max(0, int(ev.x) - gutter))
			b.cursor = {row, col}
			cursor_goal_sync(b)
			editor_scroll(editor)
			return
		}
		pos := editor_mouse_cursor(editor, int(ev.x), int(ev.y))
		recent :=
			editor.click_count > 0 &&
			time.duration_milliseconds(time.tick_since(editor.last_click_tick)) <= f64(DOUBLE_CLICK_MS) &&
			pos == editor.last_click_pos
		editor.click_count = editor.click_count + 1 if recent else 1
		if editor.click_count > 3 {
			editor.click_count = 1
		}
		editor.last_click_tick = time.tick_now()
		editor.last_click_pos = pos

		switch editor.click_count {
		case 2:
			from, to := word_range_at(b, pos)
			b.selection = from
			b.cursor = to
			cursor_goal_sync(b)
		case 3:
			from, to := line_range_at(b, pos.row)
			b.selection = from
			b.cursor = to
			cursor_goal_sync(b)
		case:
			b.selection = nil
			b.cursor = pos
			cursor_goal_sync(b)
		}
		editor_scroll(editor)
	case .Mouse_Wheel_Up:
		w, _ := editor_viewport(editor)
		editor.scroll_row, editor.scroll_sub = vpos_up(b, w, editor.scroll_row, editor.scroll_sub, WHEEL_SCROLL_LINES)
	case .Mouse_Wheel_Down:
		w, h := editor_viewport(editor)
		last := len(b.lines) - 1
		max_r, max_s := vpos_up(b, w, last, line_rows(b, w, last) - 1, h - 1)
		r, s := vpos_down(b, w, editor.scroll_row, editor.scroll_sub, WHEEL_SCROLL_LINES)
		if vpos_cmp(r, s, max_r, max_s) > 0 {
			r, s = max_r, max_s
		}
		editor.scroll_row, editor.scroll_sub = r, s
	}
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

editor_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	if editor.completion.active {
		if completion_key(editor, ev) {
			editor_scroll(editor)
			return
		}
		if !completion_keeps(ev) {
			completion_dismiss(editor)
		}
	}
	if !editor.completion.active && fim_ghost_active(editor) {
		if fim_ghost_key(editor, ev) {
			return
		}
		fim_dismiss(editor)
	}
	editor_clear_message(editor)
	editor.hover_active = false
	b := editor_buffer(editor)
	ctrl := ev_ctrl(ev)
	shift := ev_shift(ev)
	alt := ev_alt(ev)

	if alt && ev.ch != 0 {
		if cmd, ok := command_for_alt(ev.ch); ok {
			cmd.run(editor)
		}
		return
	}

	if cmd, ok := command_for_key(ev.key); ok {
		cmd.run(editor)
		return
	}

	if alt {
		#partial switch ev.key {
		case .Arrow_Up:
			buffer_move_lines(b, -1)
			editor_scroll(editor)
			return
		case .Arrow_Down:
			buffer_move_lines(b, +1)
			editor_scroll(editor)
			return
		}
	}

	#partial switch ev.key {
	case .Ctrl_P:
		palette_open(editor)
		return
	case .Esc:
		// Passive inspector close, slotted last: overlays, completion and the FIM
		// ghost all consume Esc before reaching here, so nothing existing changes.
		if editor.inspect.active {
			inspect_close(editor)
		}
		return
	case .Enter:
		if selection_active(b) {
			buffer_replace_selection(b, "\n")
		} else {
			buffer_newline(b)
		}
	case .Tab:
		buffer_indent(b)
	case .Back_Tab:
		buffer_dedent(b)
	case .Backspace, .Backspace2:
		if selection_active(b) {
			buffer_delete_selection(b)
		} else if !buffer_backspace_pair(b) {
			buffer_backspace(b)
		}
	case .Delete:
		if selection_active(b) {
			buffer_delete_selection(b)
		} else {
			buffer_delete_forward(b)
		}
	case .Arrow_Left, .Arrow_Right, .Arrow_Up, .Arrow_Down:
		buffer_undo_commit(b)
		sel_from, sel_to, had_sel := selection_range(b)
		if shift {
			selection_set_anchor(b)
		} else {
			b.selection = nil
		}
		collapse := had_sel && !shift && !ctrl && !alt
		step := 1 if ctrl || alt || collapse else editor_accel_step(editor, ev.key)
		#partial switch ev.key {
		case .Arrow_Left:
			if alt {
				cursor_move_home_smart(b)
			} else if collapse {
				b.cursor = sel_from
				cursor_goal_sync(b)
			} else if ctrl {
				cursor_move_word_left(b)
			} else {
				for _ in 0 ..< step {
					cursor_move_left(b)
				}
			}
		case .Arrow_Right:
			if alt {
				cursor_move_end(b)
			} else if collapse {
				b.cursor = sel_to
				cursor_goal_sync(b)
			} else if ctrl {
				cursor_move_word_right(b)
			} else {
				for _ in 0 ..< step {
					cursor_move_right(b)
				}
			}
		case .Arrow_Up:
			if ctrl {
				cursor_paragraph_prev(b)
			} else {
				cursor_move_up_n(b, step)
			}
		case .Arrow_Down:
			if ctrl {
				cursor_paragraph_next(b)
			} else {
				cursor_move_down_n(b, step)
			}
		}
	case:
		if ev.ch == 0 {
			return
		}
		handled := buffer_type_pair(b, ev.ch)
		if !handled && ev.ch <= 0x7f {
			handled = buffer_close_dedent(b, u8(ev.ch))
		}
		if !handled {
			buffer_type_rune(b, ev.ch)
		}
	}
	editor_scroll(editor)
	completion_after(editor, ev)
	fim_after(editor, ev)
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
	editor.scroll_row = 0
	editor.scroll_sub = 0
	editor.scroll_col = 0
	editor_scroll(editor)
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
	editor.jump_lock = true
	idx := editor.current
	lsp_did_close(editor, &editor.buffers[idx])
	buffer_destroy(&editor.buffers[idx])
	ordered_remove(&editor.buffers, idx)
	if len(editor.buffers) == 0 {
		append(&editor.buffers, buffer_new())
		editor.current = 0
		editor.welcome = true
		editor.scroll_row = 0
		editor.scroll_sub = 0
		editor.scroll_col = 0
	} else {
		editor_switch_to(editor, min(idx, len(editor.buffers) - 1))
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

	scratch := editor.buffers[0]
	if len(editor.buffers) == 1 && scratch.path == "" && !scratch.modified {
		buffer_destroy(&editor.buffers[0])
		editor.buffers[0] = b
		editor_switch_to(editor, 0)
	} else {
		append(&editor.buffers, b)
		editor_switch_to(editor, len(editor.buffers) - 1)
	}
	return true
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
	scratch := editor.buffers[0]
	if len(editor.buffers) == 1 && scratch.path == "" && !scratch.modified {
		buffer_destroy(&editor.buffers[0])
		editor.buffers[0] = b
		return 0
	}
	append(&editor.buffers, b)
	return len(editor.buffers) - 1
}

editor_copy :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if selection_active(b) {
		from, to, _ := selection_range(b)
		clipboard_set(buffer_text_range(b, from, to))
	} else {
		line := b.lines[b.cursor.row].text[:]
		clipboard_set(strings.concatenate({string(line), "\n"}, context.temp_allocator))
	}
}

editor_cut :: proc(editor: ^Editor) {
	editor_copy(editor)
	b := editor_buffer(editor)
	if selection_active(b) {
		buffer_delete_selection(b)
	} else {
		buffer_delete_line(b)
	}
	editor_scroll(editor)
}

editor_paste :: proc(editor: ^Editor) {
	text := clipboard_get(context.temp_allocator)
	if len(text) == 0 {
		return
	}
	buffer_paste(editor_buffer(editor), text)
	editor_scroll(editor)
}

editor_save :: proc(editor: ^Editor) {
	editor_save_full(editor, editor_buffer(editor))
}

editor_save_full :: proc(editor: ^Editor, b: ^Buffer) {
	trimmed, newlined := buffer_save_fixups(b, editor.trim_trailing_whitespace_on_save, editor.ensure_final_newline_on_save)
	if trimmed > 0 || newlined {
		editor_log(editor, .Debug, "Save", fmt.tprintf("fixups: trimmed %d line(s), final-newline=%v", trimmed, newlined))
	}
	if editor.format_on_save {
		if LANGUAGES[b.language].formatter != "" {
			format_external(editor, b, true)
			return
		}
		if lsp_send_format(editor, b, .FormatOnSave) {
			return
		}
	}
	editor_save_buffer(editor, b)
}

editor_save_path :: proc(editor: ^Editor, path: string) {
	if idx := editor_find_buffer(editor, path); idx >= 0 {
		editor_save_buffer(editor, &editor.buffers[idx])
	}
}

editor_save_buffer :: proc(editor: ^Editor, b: ^Buffer) {
	if buffer_disk_changed(b) {
		editor_save_intent_clear(editor)
		conflict_dialog_open(editor)
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
		if lsp_format_pending() {
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
		editor_log(editor, .Info, "", "Saved")
		lsp_did_save(editor, b)
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
		if b == editor_buffer(editor) {
			editor_scroll(editor)
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

editor_maybe_poll_disk :: proc(editor: ^Editor) -> bool {
	if time.duration_milliseconds(time.tick_since(editor.disk_poll)) < f64(DISK_POLL_MS) {
		return false
	}
	editor.disk_poll = time.tick_now()
	git_stat_maybe_start(editor)
	changed := editor_maybe_reload_config(editor)
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
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	term_reload_colors(editor)
}

editor_maybe_reload_config :: proc(editor: ^Editor) -> bool {
	path := config_path()
	if path == "" {
		return false
	}
	now := buffer_disk_stamp(path)
	tnow := buffer_disk_stamp(theme_path(path, THEME))
	cfg_changed := now.ok && (now.mtime != editor.config_stamp.mtime || now.size != editor.config_stamp.size)
	theme_changed := tnow.ok && (tnow.mtime != editor.theme_stamp.mtime || tnow.size != editor.theme_stamp.size)
	if !cfg_changed && !theme_changed {
		return false
	}
	editor_log(editor, .Debug, "Config", fmt.tprintf("hot-reload: config=%v theme=%v (%s)", cfg_changed, theme_changed, path))
	message, is_error := config_load_from(path)
	editor.config_stamp = buffer_disk_stamp(path)
	editor.theme_stamp = buffer_disk_stamp(theme_path(path, THEME))
	editor_retheme(editor)
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
		editor_reload_buffer(editor, &b)
		changed = true
	}
	return changed
}

editor_scroll :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	w, h := editor_viewport(editor)
	b.wrap_width = w
	cur := b.cursor

	if b.wrap && w > 0 {
		editor.scroll_col = 0
		editor_scroll_vert(editor, b, w, h)
		return
	}
	editor.scroll_sub = 0
	editor_scroll_vert(editor, b, w, h)

	cur_vcol := visual_col(b.lines[cur.row].text[:], cur.col)
	if cur_vcol < editor.scroll_col + SCROLL_MARGIN {
		editor.scroll_col = cur_vcol - SCROLL_MARGIN
	}
	if cur_vcol > editor.scroll_col + w - 1 - SCROLL_MARGIN {
		editor.scroll_col = cur_vcol - w + 1 + SCROLL_MARGIN
	}
	editor.scroll_col = max(0, editor.scroll_col)
}

editor_scroll_vert :: proc(editor: ^Editor, b: ^Buffer, w, h: int) {
	cur := b.cursor
	cur_sub := 0
	if b.wrap && w > 0 {
		cur_sub = wrap_subrow(b.lines[cur.row].text[:], w, cur.col)
	}

	top_r := clamp(editor.scroll_row, 0, len(b.lines) - 1)
	top_s := clamp(editor.scroll_sub, 0, line_rows(b, w, top_r) - 1)

	mr, ms := vpos_up(b, w, cur.row, cur_sub, SCROLL_MARGIN)
	if vpos_cmp(top_r, top_s, mr, ms) > 0 {
		top_r, top_s = mr, ms
	}
	lr, ls := vpos_up(b, w, cur.row, cur_sub, h - 1 - SCROLL_MARGIN)
	if vpos_cmp(top_r, top_s, lr, ls) < 0 {
		top_r, top_s = lr, ls
	}
	last := len(b.lines) - 1
	max_r, max_s := vpos_up(b, w, last, line_rows(b, w, last) - 1, h - 1)
	if vpos_cmp(top_r, top_s, max_r, max_s) > 0 {
		top_r, top_s = max_r, max_s
	}
	editor.scroll_row = top_r
	editor.scroll_sub = top_s
}

editor_goto :: proc(editor: ^Editor, row, col: int) {
	b := editor_buffer(editor)
	r := clamp(row, 0, len(b.lines) - 1)
	b.selection = nil
	b.cursor = {r, clamp(col, 0, len(b.lines[r].text))}
	cursor_goal_sync(b)
	_, h := editor_viewport(editor)
	editor.scroll_row = r - h / 2
	editor.scroll_sub = 0
	editor_scroll(editor)
}

editor_render :: proc(editor: ^Editor) {
	tb2.clear()
	if editor.welcome {
		editor_render_welcome(editor)
	} else {
		_, vh := editor_viewport(editor)
		if !editor_buffer(editor).big {
			highlight_update(editor_buffer(editor), editor.scroll_row, editor.scroll_row + vh - 1)
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
			git_gutter_update(editor_buffer(editor))
		}
		editor_render_buffer(editor)
	}
	editor_render_status(editor)

	if editor.inspect.active && !editor.welcome {
		inspect_render(editor)
	}

	for ov in editor_overlays(editor) {
		if ov.active^ {
			ov.render(editor)
			tb2.present()
			return
		}
	}
	if editor.welcome {
		tb2.hide_cursor()
	} else {
		b := editor_buffer(editor)
		gutter := editor_gutter_width(editor)
		w, h := editor_viewport(editor)
		text := b.lines[b.cursor.row].text[:]
		cx, cy: int
		above := false
		cur_sub := 0
		if b.wrap && w > 0 {
			seg := wrap_seg_start(text, w, b.cursor.col)
			cur_sub = wrap_subrow(text, w, b.cursor.col)
			cx = gutter + visual_col(text, b.cursor.col) - visual_col(text, seg)
			above =
				b.cursor.row < editor.scroll_row ||
				(b.cursor.row == editor.scroll_row && cur_sub < editor.scroll_sub)
		} else {
			cx = gutter + visual_col(text, b.cursor.col) - editor.scroll_col
			above = b.cursor.row < editor.scroll_row
		}
		cy = -1 if above else vpos_dist(b, w, editor.scroll_row, editor.scroll_sub, b.cursor.row, cur_sub, h)
		if above || cy < 0 || cy >= h || cx < gutter || cx >= gutter + w {
			tb2.hide_cursor()
		} else {
			tb2.set_cursor(i32(cx), i32(cy))
			if editor.completion.active {
				completion_render(editor, cx, cy)
			} else if fim_ghost_active(editor) {
				// A wrapped buffer draws the ghost inline in editor_render_buffer.
				if !(b.wrap && w > 0) {
					fim_render(editor, cx, cy)
				}
			} else if editor.hover_active {
				editor_render_hover_pane(editor, cx, cy)
			} else {
				editor_render_diag_pane(editor, cx, cy)
			}
		}
	}
	tb2.present()
}

editor_render_diag_pane :: proc(editor: ^Editor, cx, cy: int) {
	b := editor_buffer(editor)
	d, ok := diagnostic_at(b, b.cursor)
	if !ok {
		return
	}
	text_w := int(tb2.width()) - 2 * DIAG_PANE_MARGIN_X - 2
	if text_w < 8 {
		return
	}
	lines := wrap_text(d.message, text_w)
	editor_render_text_pane(editor, cx, cy, lines[:], diagnostic_color(d.severity))
}

editor_render_hover_pane :: proc(editor: ^Editor, cx, cy: int) {
	editor.hover_rect = {}
	text_w := int(tb2.width()) - 2 * DIAG_PANE_MARGIN_X - 2
	if text_w < 8 {
		return
	}
	lines := md_render(string(editor.hover[:]), text_w, editor.hover_lang)
	if len(lines) == 0 {
		return
	}
	sw := int(tb2.width())
	_, h := editor_viewport(editor)
	room_below := h - (cy + 1)
	room_above := cy
	view_h := min(len(lines), HOVER_PANE_MAX_LINES, max(room_below, room_above) - 2)
	if view_h <= 0 {
		return
	}
	editor.hover_scroll = clamp(editor.hover_scroll, 0, max(0, len(lines) - view_h))
	content_w := 0
	for i in editor.hover_scroll ..< editor.hover_scroll + view_h {
		content_w = max(content_w, md_line_width(lines[i]))
	}
	content_w = clamp(content_w, 1, text_w)
	pane_w := content_w + 2
	pane_h := view_h + 2
	y := room_below >= pane_h ? cy + 1 : cy - pane_h
	x := clamp(cx, 0, max(0, sw - pane_w))
	editor.hover_rect = {x, y, pane_w, pane_h}
	box := pane_draw_box({x, y, pane_w, pane_h})
	for i in 0 ..< view_h {
		md_draw_line(box.x, box.y + i, box.w, lines[editor.hover_scroll + i], COLOR_PANE_BG)
	}
}

editor_render_text_pane :: proc(editor: ^Editor, cx, cy: int, lines: []string, fg: tb2.Color, max_lines := DIAG_PANE_MAX_LINES) {
	if len(lines) == 0 {
		return
	}
	sw := int(tb2.width())
	_, h := editor_viewport(editor)
	room_below := h - (cy + 1)
	room_above := cy
	content_h := min(len(lines), max_lines, max(room_below, room_above) - 2)
	if content_h <= 0 {
		return
	}
	content_w := 0
	for line in lines[:content_h] {
		content_w = max(content_w, len(line))
	}
	pane_w := content_w + 2
	pane_h := content_h + 2
	y := room_below >= pane_h ? cy + 1 : cy - pane_h
	x := clamp(cx, 0, max(0, sw - pane_w))
	box := pane_draw_box({x, y, pane_w, pane_h})
	for line, i in lines[:content_h] {
		pane_text(box.x, box.y + i, box.w, line, fg, COLOR_PANE_BG)
	}
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
editor_render_ghost_line :: proc(editor: ^Editor, b: ^Buffer, row, gutter, w, h, screen_y: int, colors: []tb2.Color, line_bg: tb2.Color) -> int {
	text := b.lines[row].text[:]
	cut := b.cursor.col
	glines := strings.split(editor.fim.ghost, "\n", context.temp_allocator)
	mark := git_mark_at(b, row)

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
		for s in 0 ..< len(segs) {
			if sy >= h {
				return sy
			}
			seg_start := segs[s]
			seg_end := segs[s + 1] if s + 1 < len(segs) else len(ct)
			x_origin := visual_col(ct, seg_start)
			editor_render_gutter(sy, gutter, row + 1, true, 0, mark, !first_row)
			editor_render_text_row(gutter, sy, w, ct, ccol[:], x_origin, line_bg, -1, -1, nil, seg_start, seg_end)
			sy += 1
			first_row = false
		}
	}
	return sy
}

editor_render_ghost_gutter :: proc(y, width: int) {
	tb2.set_cell(0, i32(y), '▌', COLOR_GIT_DEL, COLOR_GUTTER_BG)
	for x in 1 ..< width {
		tb2.set_cell(i32(x), i32(y), ' ', COLOR_GUTTER_FG, COLOR_GUTTER_BG)
	}
}

// Draws a hunk's removed/base lines as dim-red, non-wrapping ghost rows (one
// screen row each, clipped). Above-hunk lines paired with their live counterpart
// get the changed span emphasized. Returns the next screen row.
editor_render_hunk_ghosts :: proc(editor: ^Editor, b: ^Buffer, row, gutter, w, h: int, above: bool, screen_y: int) -> int {
	hunk, ok := git_hunk_at(b, row, above)
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
		old := transmute([]u8)b.git.base_text[hunk.lo + gi]
		df, dt := -1, -1
		if above && gi < hunk.new_n && hunk.row + gi < len(b.lines) {
			ospan, _ := git_word_span(string(old), string(b.lines[hunk.row + gi].text[:]))
			df, dt = ospan[0], ospan[1]
		}
		ccol := make([]tb2.Color, len(old), context.temp_allocator)
		for i in 0 ..< len(old) {
			ccol[i] = COLOR_GHOST_FG
		}
		editor_render_ghost_gutter(sy, gutter)
		editor_render_text_row(gutter, sy, w, old, ccol, 0, ghost_bg, -1, -1, nil, 0, len(old), df, dt, word_bg)
		sy += 1
	}
	return sy
}

editor_render_buffer :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	gutter := editor_gutter_width(editor)
	w, h := editor_viewport(editor)

	sel_from, sel_to, sel_ok := selection_range(b)

	bra, brm: Cursor
	br_ok := false
	if !b.big && !sel_ok {
		bra, brm, br_ok = bracket_match(b)
	}

	ai_rows: [][2]int
	if len(editor.llm.requests) > 0 {
		ai_rows = llm_active_rows(editor, b)
	}

	conflicts := merge_scan(b)
	conflict_spans := merge_word_map(b, conflicts)

	b.wrap_width = w
	wrapping := b.wrap && w > 0
	gap := fim_ghost_gap(editor)
	// While a ghost shows, the cursor line is drawn only up to the caret; the
	// suffix is relocated after the ghost by fim_render (else it'd paint over it).
	ghost_cut := !editor.completion.active && fim_ghost_active(editor)
	screen_y := 0
	for row := editor.scroll_row; row < len(b.lines) && screen_y < h; row += 1 {
		current := row == b.cursor.row
		severity := 0
		for d in b.diags {
			if row >= d.from.row && row <= d.to.row && (severity == 0 || d.severity < severity) {
				severity = d.severity
			}
		}
		mark := git_mark_at(b, row)

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
		ai_edit := false
		for r in ai_rows {
			if row >= r[0] && row <= r[1] {
				ai_edit = true
				break
			}
		}
		side, cmark := merge_side(conflicts, row)
		colors := highlight_colors(b, row)
		if cmark {
			mc := make([]tb2.Color, len(text), context.temp_allocator)
			for i in 0 ..< len(text) {
				mc[i] = merge_side_color(side)
			}
			colors = mc
		}
		line_bg := editor_line_bg(current, ai_edit, mark, g_diff_view, side, cmark)

		// A modification's changed span on the live line, emphasized against its base pair.
		diff_from, diff_to := -1, -1
		diff_bg := tb2.Color(0)
		if g_diff_view && mark == .Modified {
			if old, ok := git_pair_old(b, row); ok {
				_, nspan := git_word_span(old, string(text[:]))
				diff_from, diff_to = nspan[0], nspan[1]
				diff_bg = color_over(line_bg, COLOR_GIT_MOD, GIT_DIFF_WORD_TINT)
			}
		}
		if (side == .Ours || side == .Theirs) && !cmark {
			if sp, ok := conflict_spans[row]; ok {
				diff_from, diff_to = sp[0], sp[1]
				diff_bg = color_over(line_bg, merge_side_color(side), CONFLICT_WORD_TINT)
			}
		}

		match_spans: [][2]int
		if editor.find.active {
			match_spans = find_row_spans(editor, row)
		}

		// Deleted/replaced base lines render as dim-red ghost rows: above a
		// modification, below a pure deletion. Hidden for the top line.
		if row != editor.scroll_row {
			screen_y = editor_render_hunk_ghosts(editor, b, row, gutter, w, h, true, screen_y)
			if screen_y >= h {
				break
			}
		}

		ghost_row := ghost_cut && row == b.cursor.row
		if wrapping {
			if ghost_row {
				// Ghost + suffix wrap as one flow, pushing lines below down by the
				// rows they consume (no separate gap needed).
				screen_y = editor_render_ghost_line(editor, b, row, gutter, w, h, screen_y, colors, line_bg)
			} else {
				segs := line_wrap(text[:], w)
				start_sub := editor.scroll_sub if row == editor.scroll_row else 0
				for s in start_sub ..< len(segs) {
					if screen_y >= h {
						break
					}
					seg_start := segs[s]
					seg_end := segs[s + 1] if s + 1 < len(segs) else len(text)
					x_origin := visual_col(text[:], seg_start)
					editor_render_gutter(screen_y, gutter, row + 1, current, severity, mark, s > 0)
					editor_render_text_row(gutter, screen_y, w, text[:], colors, x_origin, line_bg, row_sel_from, row_sel_to, underlines[:], seg_start, seg_end, diff_from, diff_to, diff_bg, match_spans, COLOR_FIND_MATCH_BG)
					screen_y += 1
				}
			}
		} else {
			// Unwrapped: ghost + suffix stay on one row (clipped), drawn by
			// fim_render, so cut the real line at the caret and reserve gap rows.
			text_end := b.cursor.col if ghost_row else len(text)
			editor_render_gutter(screen_y, gutter, row + 1, current, severity, mark, false)
			editor_render_text_row(gutter, screen_y, w, text[:], colors, editor.scroll_col, line_bg, row_sel_from, row_sel_to, underlines[:], 0, text_end, diff_from, diff_to, diff_bg, match_spans, COLOR_FIND_MATCH_BG)
			screen_y += 1
			if gap > 0 && row == b.cursor.row {
				screen_y += gap
			}
		}
		if screen_y < h {
			screen_y = editor_render_hunk_ghosts(editor, b, row, gutter, w, h, false, screen_y)
		}
	}

}

editor_render_status :: proc(editor: ^Editor) {
	full_w := int(tb2.width())
	_, h := editor_viewport(editor)
	status, right: string
	lsp_seg := ""
	lsp_fg := COLOR_PANE_FG
	if editor.welcome {
		status = fmt.tprintf(" %s", editor.working_root)
		right = fmt.tprintf("qed %s", VERSION)
	} else {
		b := editor_buffer(editor)
		name := editor_display_path(editor, b.path) if b.path != "" else "[No Name]"
		status = fmt.tprintf(" %s %s", ICON_STATUS_FILE, name)
		if b.modified {
			status = fmt.tprintf("%s %s", status, ICON_MODIFIED)
		}
		status = fmt.tprintf("%s  %d/%d", status, b.cursor.row + 1, len(b.lines))
		indent := "Tabs" if b.indent == .Tabs else fmt.tprintf("Spaces:%d", b.indent_width)
		right = fmt.tprintf("%s %s", ICON_STATUS_LANG, LANGUAGES[b.language].name)
		if b.big {
			right = fmt.tprintf("%s  big", right)
		} else if label, fg, ok := lsp_status_label(b); ok {
			lsp_seg = fmt.tprintf("%s %s", ICON_STATUS_LSP, label)
			lsp_fg = fg
			right = fmt.tprintf("%s  %s", right, lsp_seg)
		}
		right = fmt.tprintf("%s  %s %s", right, ICON_STATUS_INDENT, indent)
		if n := len(editor.llm.requests); n > 0 {
			right = fmt.tprintf("AI:%d  %s", n, right)
		}
	}
	if editor.gitstat.branch != "" {
		status = fmt.tprintf("%s  %s %s", status, ICON_STATUS_BRANCH, editor.gitstat.branch)
		if editor.gitstat.ahead > 0 {
			status = fmt.tprintf("%s %s%d", status, ICON_STATUS_AHEAD, editor.gitstat.ahead)
		}
		if editor.gitstat.behind > 0 {
			sep := "" if editor.gitstat.ahead > 0 else " "
			status = fmt.tprintf("%s%s%s%d", status, sep, ICON_STATUS_BEHIND, editor.gitstat.behind)
		}
	}
	if len(editor.buffers) > 1 {
		status = fmt.tprintf("%s  [%d/%d]", status, editor.current + 1, len(editor.buffers))
	}
	editor_render_row(0, h, full_w, status, COLOR_PANE_FG, COLOR_PANE_BG)
	right_w := visual_width(transmute([]u8)right)
	right_x := max(0, full_w - right_w - 1)
	right_cstr := strings.clone_to_cstring(right, context.temp_allocator)
	tb2.print(i32(right_x), i32(h), COLOR_PANE_FG, COLOR_PANE_BG, right_cstr)
	if lsp_seg != "" && lsp_fg != COLOR_PANE_FG {
		if off := strings.index(right, lsp_seg); off >= 0 {
			seg_x := right_x + visual_width(transmute([]u8)right[:off])
			tb2.print(i32(seg_x), i32(h), lsp_fg, COLOR_PANE_BG, strings.clone_to_cstring(lsp_seg, context.temp_allocator))
		}
	}
	message_fg := COLOR_FG
	#partial switch editor.message_level {
	case .Warn:
		message_fg = COLOR_WARN_FG
	case .Error:
		message_fg = COLOR_ERROR_FG
	}
	msg := editor.message
	if editor.message_source != "" && editor.message != "" {
		msg = fmt.tprintf("%s: %s", editor.message_source, editor.message)
	}
	editor_render_row(0, h + 1, full_w, msg, message_fg, COLOR_BG)
}

editor_render_welcome :: proc(editor: ^Editor) {
	w := int(tb2.width())
	h := max(0, int(tb2.height()) - STATUS_ROWS)

	art := [?]string {
		"  .g8\"\"8q. `7MM\"\"YMMM`7MM\"\"\"Yb.   ",
		".dP'    `YM. MM    `7  MM    `Yb. ",
		"dM'      `MM MM   d    MM     `Mb ",
		"MM        MM MMmmMM    MM      MM ",
		"MM.      ,MP MM   Y ,  MM     ,MP ",
		"`Mb.    ,dP' MM    ,M  MM    ,dP' ",
		"  `\"bmmd\"' .JMMmmmMMM.JMMmmmdP'   ",
		"      MMb                          ",
		"       `bmmd'                      ",
	}
	hints := [?]string {
		"Ctrl+O    Open file",
		"Ctrl+P    Command palette",
		"Ctrl+Q    Quit",
	}

	hint_w := 0
	for line in hints {
		hint_w = max(hint_w, len(line))
	}
	hint_x := max(0, (w - hint_w) / 2)

	y := max(0, h / 2 - (len(art) + 1 + len(hints)) / 2)
	for line in art {
		editor_render_welcome_line(max(0, (w - len(line)) / 2), y, line)
		y += 1
	}
	y += 1
	for line in hints {
		editor_render_welcome_line(hint_x, y, line)
		y += 1
	}
}

editor_render_welcome_line :: proc(x, y: int, text: string) {
	if y < 0 || y >= int(tb2.height()) {
		return
	}
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	tb2.print(i32(x), i32(y), COLOR_FG, COLOR_BG, cstr)
}

editor_render_gutter :: proc(y, width, number: int, current: bool, severity: int, mark: GitMark, continuation: bool) {
	if continuation {
		for x in 0 ..< width {
			tb2.set_cell(i32(x), i32(y), ' ', COLOR_GUTTER_FG, COLOR_GUTTER_BG)
		}
		return
	}
	mark_ch, mark_fg := git_mark_glyph(mark)
	tb2.set_cell(0, i32(y), mark_ch, mark_fg, COLOR_GUTTER_BG)

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
	tb2.print(1, i32(y), fg, COLOR_GUTTER_BG, cstr)
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

editor_line_bg :: proc(current, ai_edit: bool, mark: GitMark, hunk: bool, side: MergeSide, marker: bool) -> tb2.Color {
	bg := COLOR_BG
	if hunk {
		#partial switch mark {
		case .Added:
			bg = color_over(bg, COLOR_GIT_ADD, GIT_HUNK_TINT)
		case .Modified:
			bg = color_over(bg, COLOR_GIT_MOD, GIT_HUNK_TINT)
		}
	}
	if side != .None {
		bg = color_over(bg, merge_side_color(side), CONFLICT_MARKER_TINT if marker else CONFLICT_TINT)
	}
	if ai_edit {
		bg = color_over(bg, COLOR_AI_EDIT_BG, AI_EDIT_TINT)
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

	vcol := 0
	pstart := -1
	psel := false
	pfg := COLOR_FG
	pbg := bg_normal
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if pstart >= 0 {
			vcol = emit(gutter, y, w, text, pstart, g.byte_index, vcol, x_origin, col_start, col_end, psel, pfg, pbg)
		}
		pstart = g.byte_index
		psel = sel_from >= 0 && g.byte_index >= sel_from && g.byte_index < sel_to
		pfg = colors[pstart] if colors != nil && pstart < len(colors) else COLOR_FG
		if underlined(underlines, pstart) {
			pfg = tb2.Color(u64(pfg) | u64(tb2.Color.Underline))
		}
		pbg = diff_bg if diff_from >= 0 && pstart >= diff_from && pstart < diff_to else bg_normal
		for sp in match_spans {
			if pstart >= sp[0] && pstart < sp[1] {
				pbg = match_bg
				break
			}
		}
	}
	if pstart >= 0 {
		vcol = emit(gutter, y, w, text, pstart, len(text), vcol, x_origin, col_start, col_end, psel, pfg, pbg)
	}
	if col_end >= len(text) && sel_from >= 0 && len(text) >= sel_from && len(text) < sel_to {
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
	cstr := strings.clone_to_cstring(strings.to_string(sb), context.temp_allocator)
	tb2.print(i32(x), i32(y), fg, bg, cstr)
}
