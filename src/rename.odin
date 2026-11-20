package main

rename_open :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if _, ok := lsp_rename_ready(editor, b); !ok {
		return
	}
	from, to := word_range_at(b, b.cursor)
	word := buffer_text_range(b, from, to)
	editor_clear_message(editor)
	p := pane_open(editor, Pane {
		id = "rename",
		place = .Center,
		size = .Palette,
		modal = true,
		fields = []PaneField{{prompt = "Rename to: ", mode = .Input}},
		on = {activate = rename_submit},
	})
	if p != nil {
		textfield_set(&p.fields[0].field, word)
	}
}

rename_submit :: proc(editor: ^Editor, p: ^Pane) {
	name := textfield_str(&p.fields[0].field)
	if len(name) == 0 {
		editor_log(editor, .Error, "Rename", "Empty name")
		return
	}
	lsp_rename_send(editor, name)
}
