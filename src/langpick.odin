package main

import "lib:tb2"

LangPick :: struct {
	using list: FuzzyList,
	names:      [dynamic]string,
	langs:      [dynamic]Language,
}

langpick_destroy :: proc(lp: ^LangPick) {
	fuzzy_list_destroy(&lp.list)
	delete(lp.names)
	delete(lp.langs)
}

langpick_open :: proc(editor: ^Editor) {
	lp := &editor.langpick
	lp.active = true
	fuzzy_list_reset(&lp.list)
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
	fuzzy_list_refilter(&lp.list)
}

langpick_close :: proc(editor: ^Editor) {
	editor.langpick.active = false
	fuzzy_end(&editor.langpick.fuzzy)
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
		fuzzy_list_move_wrap(&lp.list, 1, PALETTE_MAX_ROWS)
	case .Arrow_Up:
		fuzzy_list_move_wrap(&lp.list, -1, PALETTE_MAX_ROWS)
	case:
		if textfield_key(&lp.field, ev) {
			fuzzy_list_refilter(&lp.list)
		}
	}
}

langpick_render :: proc(editor: ^Editor) {
	lp := &editor.langpick
	rows := min(len(lp.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &lp.field)
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
}
