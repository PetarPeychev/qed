package main

import "lib:tb2"

Rename :: struct {
	active: bool,
	field:  TextField,
}

rename_destroy :: proc(r: ^Rename) {
	textfield_destroy(&r.field)
}

rename_open :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if _, ok := lsp_rename_ready(editor, b); !ok {
		return
	}
	from, to := word_range_at(b, b.cursor)
	word := buffer_text_range(b, from, to)
	r := &editor.rename
	r.active = true
	textfield_set(&r.field, word)
	editor_clear_message(editor)
}

rename_close :: proc(editor: ^Editor) {
	editor.rename.active = false
}

rename_submit :: proc(editor: ^Editor) {
	r := &editor.rename
	name := textfield_str(&r.field)
	rename_close(editor)
	if len(name) == 0 {
		editor_log(editor, .Error, "Rename", "Empty name")
		return
	}
	lsp_rename_send(editor, name)
}

rename_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	r := &editor.rename
	#partial switch ev.key {
	case .Esc:
		rename_close(editor)
	case .Enter:
		rename_submit(editor)
	case:
		textfield_key(&r.field, ev)
	}
}

rename_paste :: proc(editor: ^Editor, text: string) {
	textfield_insert_flat(&editor.rename.field, text)
}

rename_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	if ev.key != .Mouse_Left {
		return
	}
	box := pane_center(editor, PALETTE_WIDTH, 1)
	if !mouse_in_rect(ev, box) {
		if !ev_motion(ev) {
			rename_close(editor)
		}
		return
	}
	label := "Rename to: "
	tx := box.x + 2 + len(label)
	tw := box.x + box.w - 2 - tx
	textfield_mouse(&editor.rename.field, tx, box.y + 1, tw, ev)
}

rename_render :: proc(editor: ^Editor) {
	r := &editor.rename
	box := pane_center(editor, PALETTE_WIDTH, 1)
	inner := pane_draw_box(box)

	label := "Rename to: "
	pane_text(inner.x + 1, inner.y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner.x + 1 + len(label)
	tw := inner.x + inner.w - 1 - tx
	textfield_render(tx, inner.y, tw, &r.field)
}
