package main

import "core:unicode/utf8"
import "lib:tb2"

LangPick :: struct {
	active:   bool,
	query:    [dynamic]u8,
	matches:  [dynamic]int,
	selected: int,
	scroll:   int,
	fuzzy:    Fuzzy,
	names:    [dynamic]string,
	langs:    [dynamic]Language,
}

langpick_destroy :: proc(lp: ^LangPick) {
	fuzzy_end(&lp.fuzzy)
	delete(lp.query)
	delete(lp.matches)
	delete(lp.names)
	delete(lp.langs)
}

langpick_open :: proc(editor: ^Editor) {
	lp := &editor.langpick
	lp.active = true
	clear(&lp.query)
	lp.selected = 0
	lp.scroll = 0
	editor_set_message(editor, "")
	clear(&lp.names)
	clear(&lp.langs)
	for info, lang in LANGUAGES {
		if lang == .MarkdownInline {
			continue
		}
		append(&lp.names, info.name)
		append(&lp.langs, lang)
	}
	lp.fuzzy = fuzzy_begin(lp.names[:])
	langpick_filter(editor)
}

langpick_close :: proc(editor: ^Editor) {
	editor.langpick.active = false
	fuzzy_end(&editor.langpick.fuzzy)
}

langpick_filter :: proc(editor: ^Editor) {
	lp := &editor.langpick
	clear(&lp.matches)
	lp.selected = 0
	lp.scroll = 0
	ranked := fuzzy_rank(&lp.fuzzy, string(lp.query[:]))
	for idx in ranked {
		append(&lp.matches, idx)
	}
}

langpick_move :: proc(editor: ^Editor, delta: int) {
	lp := &editor.langpick
	n := len(lp.matches)
	if n == 0 {
		return
	}
	lp.selected = (lp.selected + delta + n) % n
	if lp.selected < lp.scroll {
		lp.scroll = lp.selected
	}
	if lp.selected >= lp.scroll + PALETTE_MAX_ROWS {
		lp.scroll = lp.selected - PALETTE_MAX_ROWS + 1
	}
}

langpick_execute :: proc(editor: ^Editor) {
	lp := &editor.langpick
	if len(lp.matches) == 0 {
		return
	}
	lang := lp.langs[lp.matches[lp.selected]]
	langpick_close(editor)
	editor_set_language(editor, lang)
}

langpick_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	lp := &editor.langpick
	#partial switch ev.key {
	case .Esc:
		langpick_close(editor)
	case .Enter:
		langpick_execute(editor)
	case .Arrow_Down:
		langpick_move(editor, 1)
	case .Arrow_Up:
		langpick_move(editor, -1)
	case .Backspace, .Backspace2:
		if len(lp.query) > 0 {
			resize(&lp.query, len(lp.query) - 1)
			langpick_filter(editor)
		}
	case:
		if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			append(&lp.query, ..bytes[:n])
			langpick_filter(editor)
		}
	}
}

langpick_render :: proc(editor: ^Editor) {
	lp := &editor.langpick
	rows := min(len(lp.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	pane_text(inner.x + 1, inner.y, 2, "> ", COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_text(inner.x + 3, inner.y, inner.w - 4, string(lp.query[:]), COLOR_PANE_FG, COLOR_PANE_BG)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := lp.scroll + i
		name := lp.names[lp.matches[idx]]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if idx == lp.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, name, fg, bg)
	}

	cx := min(inner.x + 3 + len(lp.query), inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(inner.y))
}
