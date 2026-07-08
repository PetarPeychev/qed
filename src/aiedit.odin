package main

import "lib:tb2"

AiEdit :: struct {
	active: bool,
	field:  TextField,
	from:   Cursor,
	to:     Cursor,
}

aiedit_destroy :: proc(a: ^AiEdit) {
	textfield_destroy(&a.field)
}

aiedit_open :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	from, to, ok := selection_range(b)
	if !ok {
		editor_set_message(editor, "AI edit: select a block first", true)
		return
	}
	a := &editor.aiedit
	a.active = true
	a.from = from
	a.to = to
	textfield_reset(&a.field)
	editor_set_message(editor, "")
}

aiedit_close :: proc(editor: ^Editor) {
	editor.aiedit.active = false
}

aiedit_submit :: proc(editor: ^Editor) {
	a := &editor.aiedit
	instruction := textfield_str(&a.field)
	from, to := a.from, a.to
	aiedit_close(editor)
	if len(instruction) == 0 {
		editor_set_message(editor, "AI edit: empty instruction", true)
		return
	}
	llm_chat_send(editor, instruction, from, to)
}

aiedit_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	a := &editor.aiedit
	#partial switch ev.key {
	case .Esc:
		aiedit_close(editor)
	case .Enter:
		aiedit_submit(editor)
	case:
		textfield_key(&a.field, ev)
	}
}

aiedit_paste :: proc(editor: ^Editor, text: string) {
	textfield_insert_flat(&editor.aiedit.field, text)
}

aiedit_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	if ev.key != .Mouse_Left {
		return
	}
	box := pane_center(editor, PALETTE_WIDTH, 1)
	if !mouse_in_rect(ev, box) {
		if !ev_motion(ev) {
			aiedit_close(editor)
		}
		return
	}
	label := "AI edit: "
	tx := box.x + 2 + len(label)
	tw := box.x + box.w - 2 - tx
	textfield_mouse(&editor.aiedit.field, tx, box.y + 1, tw, ev)
}

aiedit_render :: proc(editor: ^Editor) {
	a := &editor.aiedit
	box := pane_center(editor, PALETTE_WIDTH, 1)
	inner := pane_draw_box(box)

	label := "AI edit: "
	pane_text(inner.x + 1, inner.y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner.x + 1 + len(label)
	tw := inner.x + inner.w - 1 - tx
	textfield_render(tx, inner.y, tw, &a.field)
}
