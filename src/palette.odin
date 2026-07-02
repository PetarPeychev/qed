package main

import "core:slice"
import "core:unicode/utf8"
import "lib:tb2"

Command :: struct {
	name:     string,
	shortcut: string,
	run:      proc(editor: ^Editor),
}

cmd_undo :: proc(editor: ^Editor) {buffer_undo(&editor.buffer)}
cmd_redo :: proc(editor: ^Editor) {buffer_redo(&editor.buffer)}
cmd_select_all :: proc(editor: ^Editor) {cursor_select_all(&editor.buffer)}

commands := [?]Command {
	{"Save", "Ctrl+S", editor_save},
	{"Quit", "Ctrl+Q", editor_request_quit},
	{"Undo", "Ctrl+Z", cmd_undo},
	{"Redo", "Ctrl+Y", cmd_redo},
	{"Cut", "Ctrl+X", editor_cut},
	{"Copy", "Ctrl+C", editor_copy},
	{"Paste", "Ctrl+V", editor_paste},
	{"Select All", "Ctrl+A", cmd_select_all},
}

Palette :: struct {
	active:   bool,
	query:    [dynamic]u8,
	matches:  [dynamic]int,
	selected: int,
}

palette_destroy :: proc(p: ^Palette) {
	delete(p.query)
	delete(p.matches)
}

palette_open :: proc(editor: ^Editor) {
	p := &editor.palette
	p.active = true
	clear(&p.query)
	p.selected = 0
	editor.message = ""
	editor.message_error = false
	palette_filter(editor)
}

palette_close :: proc(editor: ^Editor) {
	editor.palette.active = false
}

ascii_lower :: proc(c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

fuzzy_separator :: proc(c: u8) -> bool {
	return char_class(c) != .Word
}

fuzzy_match :: proc(pattern, text: string) -> (score: int, ok: bool) {
	if len(pattern) == 0 {
		return 0, true
	}
	pi := 0
	prev_match := -2
	for ti := 0; ti < len(text) && pi < len(pattern); ti += 1 {
		if ascii_lower(text[ti]) != ascii_lower(pattern[pi]) {
			continue
		}
		score += 1
		if ti == prev_match + 1 {
			score += 3
		}
		if ti == 0 || fuzzy_separator(text[ti - 1]) {
			score += 5
		}
		prev_match = ti
		pi += 1
	}
	return score, pi == len(pattern)
}

ScoreIdx :: struct {
	score: int,
	idx:   int,
}

palette_filter :: proc(editor: ^Editor) {
	p := &editor.palette
	clear(&p.matches)
	p.selected = 0
	q := string(p.query[:])

	entries := make([dynamic]ScoreIdx, 0, len(commands), context.temp_allocator)
	for cmd, i in commands {
		if score, ok := fuzzy_match(q, cmd.name); ok {
			append(&entries, ScoreIdx{score, i})
		}
	}
	slice.sort_by(entries[:], proc(a, b: ScoreIdx) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return a.idx < b.idx
	})
	for e in entries {
		append(&p.matches, e.idx)
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
	box := pane_center(PALETTE_WIDTH, 2 + rows)
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
