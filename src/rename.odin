package main

import "core:strings"
import "lib:tb2"

// the LSP rename prompt: core-built qed.ui nodes in the alert layer (an editor over an internal buffer), no Lua
RenamePrompt :: struct {
	handle: u64,
	buffer: ^Buffer,
}

rename_prompt_open :: proc(editor: ^Editor) -> bool {
	return editor.rename.handle != 0
}

rename_open :: proc(editor: ^Editor) {
	if rename_prompt_open(editor) || safety_open(editor) {
		return
	}
	b := editor_buffer(editor)
	if _, ok := lsp_rename_ready(editor, b); !ok {
		return
	}
	from, to := word_range_at(b, b.cursor)
	word := buffer_text_range(b, from, to)
	editor_clear_message(editor)
	buffer := ui_internal_create(editor, "")
	buffer_set_text(buffer, word)
	buffer.cursor = {0, len(word)}
	buffer.selection = Cursor{0, 0}

	box := ui_core_node(.Box, "rename")
	box.float, box.anchor, box.border = .Screen, .Top, true
	box.width = {form = .Cells, value = SAFETY_WIDTH}
	box.height = {form = .Fit}
	box.margin = {3, 2, 2, 2}
	box.style = ui_core_pane_style()
	row := ui_core_node(.Row)
	ui_core_add(box, row)
	prompt := ui_core_text("Rename to: ", fg = "pane_prompt_foreground")
	ui_core_add(row, prompt)
	field := ui_core_node(.Editor, "rename_field")
	field.buffer = buffer.id
	field.height = {form = .Cells, value = 1}
	field.grow, field.grow_set = 1, true
	field.scope = make([]string, 1)
	field.scope[0] = strings.clone("editor")
	ui_core_add(row, field)
	editor.rename = {handle = ui_mount_add(editor, "", "alert", box), buffer = buffer}
	ui_resolve(editor)
	ui_focus_set(editor, field.identity)
}

rename_close :: proc(editor: ^Editor) {
	if !rename_prompt_open(editor) {
		return
	}
	ui_mount_remove(editor, editor.rename.handle)
	ui_internal_close(editor, editor.rename.buffer.id)
	editor.rename = {}
}

// Enter submits and Esc cancels; every other key edits the field
rename_key :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	#partial switch ev.key {
	case .Enter:
		name, _ := strings.replace_all(buffer_snapshot(editor.rename.buffer, context.temp_allocator), "\n", "", context.temp_allocator)
		rename_close(editor)
		if len(name) == 0 {
			editor_log(editor, .Error, "Rename", "Empty name")
			return true
		}
		lsp_rename_send(editor, name)
		return true
	case .Esc:
		rename_close(editor)
		return true
	}
	return false
}
