package main

import "core:fmt"
import "core:strings"
import "lib:tb2"

ThemePick :: struct {
	using list: FuzzyList,
	names:      [dynamic]string,
	original:   string,
}

themepick_destroy :: proc(tp: ^ThemePick) {
	fuzzy_list_destroy(&tp.list)
	for n in tp.names {
		delete(n)
	}
	delete(tp.names)
	delete(tp.original)
}

themepick_open :: proc(editor: ^Editor) {
	tp := &editor.themepick
	tp.active = true
	fuzzy_list_reset(&tp.list)
	editor_set_message(editor, "")

	for n in tp.names {
		delete(n)
	}
	clear(&tp.names)
	for n in theme_names(config_path()) {
		append(&tp.names, strings.clone(n))
	}

	delete(tp.original)
	tp.original = strings.clone(THEME)

	tp.fuzzy = fuzzy_begin(tp.names[:])
	fuzzy_list_refilter(&tp.list)
	for m, i in tp.matches {
		if tp.names[m] == THEME {
			tp.selected = i
			break
		}
	}
	fuzzy_list_scroll(&tp.list, PALETTE_MAX_ROWS)
}

themepick_close :: proc(editor: ^Editor) {
	editor.themepick.active = false
	fuzzy_end(&editor.themepick.fuzzy)
}

themepick_apply :: proc(editor: ^Editor, name: string) {
	theme_preview(config_path(), name)
	editor_retheme(editor)
}

themepick_preview_selected :: proc(editor: ^Editor) {
	tp := &editor.themepick
	if len(tp.matches) == 0 {
		return
	}
	themepick_apply(editor, tp.names[tp.matches[tp.selected]])
}

themepick_commit :: proc(editor: ^Editor) {
	tp := &editor.themepick
	if len(tp.matches) == 0 {
		return
	}
	name := tp.names[tp.matches[tp.selected]]
	themepick_apply(editor, name)
	theme_persist(name)
	editor.config_stamp = buffer_disk_stamp(config_path())
	editor.theme_stamp = buffer_disk_stamp(theme_path(config_path(), THEME))
	msg := fmt.tprintf("Theme: %s", name)
	themepick_close(editor)
	editor_set_message(editor, msg)
}

themepick_cancel :: proc(editor: ^Editor) {
	tp := &editor.themepick
	themepick_apply(editor, tp.original)
	themepick_close(editor)
}

themepick_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	tp := &editor.themepick
	#partial switch ev.key {
	case .Esc:
		themepick_cancel(editor)
	case .Enter:
		themepick_commit(editor)
	case .Arrow_Down:
		fuzzy_list_move(&tp.list, 1, PALETTE_MAX_ROWS)
		themepick_preview_selected(editor)
	case .Arrow_Up:
		fuzzy_list_move(&tp.list, -1, PALETTE_MAX_ROWS)
		themepick_preview_selected(editor)
	case:
		if textfield_key(&tp.field, ev) {
			fuzzy_list_refilter(&tp.list)
			themepick_preview_selected(editor)
		}
	}
}

themepick_paste :: proc(editor: ^Editor, text: string) {
	tp := &editor.themepick
	if textfield_insert_flat(&tp.field, text) {
		fuzzy_list_refilter(&tp.list)
		themepick_preview_selected(editor)
	}
}

themepick_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	tp := &editor.themepick
	prev := tp.selected
	fuzzy_list_center_mouse(editor, &tp.list, ev, themepick_commit, themepick_cancel)
	if tp.active && tp.selected != prev {
		themepick_preview_selected(editor)
	}
}

themepick_render :: proc(editor: ^Editor) {
	tp := &editor.themepick
	rows := min(len(tp.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &tp.field)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := tp.scroll + i
		name := tp.names[tp.matches[idx]]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if idx == tp.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, name, fg, bg)
	}
}
