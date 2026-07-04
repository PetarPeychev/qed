package main

import "core:fmt"
import "core:unicode/utf8"
import "lib:tb2"

Command :: struct {
	name:     string,
	shortcut: string,
	key:      tb2.Key,
	alt_ch:   rune,
	run:      proc(editor: ^Editor),
}

cmd_undo :: proc(editor: ^Editor) {buffer_undo(editor_buffer(editor))}
cmd_redo :: proc(editor: ^Editor) {buffer_redo(editor_buffer(editor))}
cmd_select_all :: proc(editor: ^Editor) {cursor_select_all(editor_buffer(editor))}

cmd_buffer_start :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.selection = nil
	cursor_move_buffer_start(b)
}

cmd_buffer_end :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.selection = nil
	cursor_move_buffer_end(b)
}

cmd_toggle_comment :: proc(editor: ^Editor) {buffer_toggle_comment(editor_buffer(editor))}
cmd_set_language :: proc(editor: ^Editor) {langpick_open(editor)}
cmd_lsp_restart :: proc(editor: ^Editor) {lsp_restart(editor)}
cmd_lsp_definition :: proc(editor: ^Editor) {lsp_definition(editor)}
cmd_lsp_hover :: proc(editor: ^Editor) {lsp_hover(editor)}
cmd_format :: proc(editor: ^Editor) {format_document(editor)}
cmd_diag_next :: proc(editor: ^Editor) {diag_goto(editor, +1)}
cmd_diag_prev :: proc(editor: ^Editor) {diag_goto(editor, -1)}

cmd_toggle_format_on_save :: proc(editor: ^Editor) {
	editor.format_on_save = !editor.format_on_save
	editor_set_message(editor, fmt.tprintf("Format on save: %s", "on" if editor.format_on_save else "off"))
}

cmd_toggle_indent :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.indent = .Spaces if b.indent == .Tabs else .Tabs
	editor_set_message(editor, fmt.tprintf("Indent: %s", "Tabs" if b.indent == .Tabs else "Spaces"))
}

commands := [?]Command {
	{name = "Open File", shortcut = "Ctrl+o", key = .Ctrl_O, run = picker_open},
	{name = "Find Line", shortcut = "Alt+f", alt_ch = 'f', run = linefind_open},
	{name = "Find in Files", shortcut = "Alt+F", alt_ch = 'F', run = projsearch_open},
	{name = "Go to Start of File", shortcut = "Alt+{", alt_ch = '{', run = cmd_buffer_start},
	{name = "Go to End of File", shortcut = "Alt+}", alt_ch = '}', run = cmd_buffer_end},
	{name = "Jump Back", shortcut = "Alt+,", alt_ch = ',', run = jump_back},
	{name = "Jump Forward", shortcut = "Alt+.", alt_ch = '.', run = jump_forward},
	{name = "Switch Buffer", shortcut = "Ctrl+e", key = .Ctrl_E, run = bufswitch_open},
	{name = "Close Buffer", shortcut = "Ctrl+w", key = .Ctrl_W, run = editor_close_buffer},
	{name = "Save", shortcut = "Ctrl+s", key = .Ctrl_S, run = editor_save},
	{name = "Quit", shortcut = "Ctrl+q", key = .Ctrl_Q, run = editor_request_quit},
	{name = "Undo", shortcut = "Ctrl+z", key = .Ctrl_Z, run = cmd_undo},
	{name = "Redo", shortcut = "Ctrl+y", key = .Ctrl_Y, run = cmd_redo},
	{name = "Cut", shortcut = "Ctrl+x", key = .Ctrl_X, run = editor_cut},
	{name = "Copy", shortcut = "Ctrl+c", key = .Ctrl_C, run = editor_copy},
	{name = "Paste", shortcut = "Ctrl+v", key = .Ctrl_V, run = editor_paste},
	{name = "Select All", shortcut = "Ctrl+a", key = .Ctrl_A, run = cmd_select_all},
	{name = "Toggle Comment", shortcut = "Ctrl+/", key = .Ctrl_Slash, run = cmd_toggle_comment},
	{name = "Toggle Indent (Tabs/Spaces)", key = .Ctrl_Tilde, run = cmd_toggle_indent},
	{name = "Set Language", run = cmd_set_language},
	{name = "Go to Definition", shortcut = "Alt+d", alt_ch = 'd', run = cmd_lsp_definition},
	{name = "Hover", shortcut = "Alt+s", alt_ch = 's', run = cmd_lsp_hover},
	{name = "Format Document", run = cmd_format},
	{name = "Toggle Format on Save", run = cmd_toggle_format_on_save},
	{name = "Next Diagnostic", shortcut = "Alt+>", alt_ch = '>', run = cmd_diag_next},
	{name = "Previous Diagnostic", shortcut = "Alt+<", alt_ch = '<', run = cmd_diag_prev},
	{name = "Restart LSP", run = cmd_lsp_restart},
}

command_for_key :: proc(key: tb2.Key) -> (Command, bool) {
	for cmd in commands {
		if cmd.alt_ch == 0 && cmd.shortcut != "" && cmd.key == key {
			return cmd, true
		}
	}
	return {}, false
}

command_for_alt :: proc(ch: rune) -> (Command, bool) {
	for cmd in commands {
		if cmd.alt_ch != 0 && cmd.alt_ch == ch {
			return cmd, true
		}
	}
	return {}, false
}

Palette :: struct {
	active:   bool,
	query:    [dynamic]u8,
	matches:  [dynamic]int,
	selected: int,
	scroll:   int,
	fuzzy:    Fuzzy,
	names:    [dynamic]string,
}

palette_destroy :: proc(p: ^Palette) {
	fuzzy_end(&p.fuzzy)
	delete(p.query)
	delete(p.matches)
	delete(p.names)
}

palette_open :: proc(editor: ^Editor) {
	p := &editor.palette
	p.active = true
	clear(&p.query)
	p.selected = 0
	p.scroll = 0
	editor_set_message(editor, "")
	clear(&p.names)
	for cmd in commands {
		append(&p.names, cmd.name)
	}
	p.fuzzy = fuzzy_begin(p.names[:])
	palette_filter(editor)
}

palette_close :: proc(editor: ^Editor) {
	editor.palette.active = false
	fuzzy_end(&editor.palette.fuzzy)
}

palette_filter :: proc(editor: ^Editor) {
	p := &editor.palette
	clear(&p.matches)
	p.selected = 0
	p.scroll = 0
	ranked := fuzzy_rank(&p.fuzzy, string(p.query[:]))
	for idx in ranked {
		append(&p.matches, idx)
	}
}

palette_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.palette
	n := len(p.matches)
	if n == 0 {
		return
	}
	p.selected = (p.selected + delta + n) % n
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if p.selected >= p.scroll + PALETTE_MAX_ROWS {
		p.scroll = p.selected - PALETTE_MAX_ROWS + 1
	}
}

palette_execute :: proc(editor: ^Editor) {
	p := &editor.palette
	if len(p.matches) == 0 {
		return
	}
	cmd := commands[p.matches[p.selected]]
	palette_close(editor)
	cmd.run(editor)
	editor_scroll(editor)
}

palette_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.palette
	#partial switch ev.key {
	case .Esc, .Ctrl_P:
		palette_close(editor)
	case .Enter:
		palette_execute(editor)
	case .Arrow_Down:
		palette_move(editor, 1)
	case .Arrow_Up:
		palette_move(editor, -1)
	case .Backspace, .Backspace2:
		if len(p.query) > 0 {
			resize(&p.query, len(p.query) - 1)
			palette_filter(editor)
		}
	case:
		if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			append(&p.query, ..bytes[:n])
			palette_filter(editor)
		}
	}
}

palette_render :: proc(editor: ^Editor) {
	p := &editor.palette
	rows := min(len(p.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	pane_text(inner.x + 1, inner.y, 2, "> ", COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_text(inner.x + 3, inner.y, inner.w - 4, string(p.query[:]), COLOR_PANE_FG, COLOR_PANE_BG)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := p.scroll + i
		cmd := commands[p.matches[idx]]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		sc_fg := COLOR_PANE_SHORTCUT_FG
		if idx == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			sc_fg = COLOR_PANE_SEL_FG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, cmd.name, fg, bg)
		sx := inner.x + inner.w - 1 - len(cmd.shortcut)
		pane_text(sx, y, len(cmd.shortcut), cmd.shortcut, sc_fg, bg)
	}

	cx := min(inner.x + 3 + len(p.query), inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(inner.y))
}
