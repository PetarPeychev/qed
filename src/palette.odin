package main

import "core:fmt"
import "core:unicode/utf8"
import "lib:tb2"

Command :: struct {
	name:     string,
	shortcut: string,
	key:      tb2.Key,
	run:      proc(editor: ^Editor),
}

cmd_undo :: proc(editor: ^Editor) {buffer_undo(editor_buffer(editor))}
cmd_redo :: proc(editor: ^Editor) {buffer_redo(editor_buffer(editor))}
cmd_select_all :: proc(editor: ^Editor) {cursor_select_all(editor_buffer(editor))}

cmd_toggle_indent :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.indent = .Spaces if b.indent == .Tabs else .Tabs
	editor.message = fmt.tprintf("Indent: %s", "Tabs" if b.indent == .Tabs else "Spaces")
}

commands := [?]Command {
	{"Open File", "Ctrl+O", .Ctrl_O, picker_open},
	{"Save", "Ctrl+S", .Ctrl_S, editor_save},
	{"Quit", "Ctrl+Q", .Ctrl_Q, editor_request_quit},
	{"Undo", "Ctrl+Z", .Ctrl_Z, cmd_undo},
	{"Redo", "Ctrl+Y", .Ctrl_Y, cmd_redo},
	{"Cut", "Ctrl+X", .Ctrl_X, editor_cut},
	{"Copy", "Ctrl+C", .Ctrl_C, editor_copy},
	{"Paste", "Ctrl+V", .Ctrl_V, editor_paste},
	{"Select All", "Ctrl+A", .Ctrl_A, cmd_select_all},
	{"Toggle Indent (Tabs/Spaces)", "", .Ctrl_Tilde, cmd_toggle_indent},
}

command_for_key :: proc(key: tb2.Key) -> (Command, bool) {
	for cmd in commands {
		if cmd.shortcut != "" && cmd.key == key {
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
	editor.message = ""
	editor.message_error = false
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
	ranked := fuzzy_rank(&p.fuzzy, string(p.query[:]))
	for idx in ranked {
		append(&p.matches, idx)
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
		if len(p.matches) > 0 {
			p.selected = (p.selected + 1) % len(p.matches)
		}
	case .Arrow_Up:
		if len(p.matches) > 0 {
			p.selected = (p.selected - 1 + len(p.matches)) % len(p.matches)
		}
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
		cmd := commands[p.matches[i]]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		sc_fg := COLOR_PANE_SHORTCUT_FG
		if i == p.selected {
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
