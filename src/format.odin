package main

import "core:fmt"
import "core:strings"

format_document :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if LANGUAGES[b.language].formatter != "" {
		format_external(editor, b, false)
		return
	}
	lsp_format(editor)
}

format_external :: proc(editor: ^Editor, b: ^Buffer, save_after: bool) {
	cmd := LANGUAGES[b.language].formatter
	tool := cmd
	if sp := strings.index_byte(cmd, ' '); sp >= 0 {
		tool = cmd[:sp]
	}
	if !shell_command_exists(tool) {
		editor_set_message(editor, fmt.tprintf("Formatter not found: %s", tool), true)
		if save_after {
			editor_save_buffer(editor, b)
		}
		return
	}

	input := buffer_snapshot(b)
	defer delete(input)
	out, ok := shell_filter(cmd, input)
	if !ok || len(out) == 0 {
		editor_set_message(editor, fmt.tprintf("%s failed", tool), true)
		if save_after {
			editor_save_buffer(editor, b)
		}
		return
	}

	body, final_nl := format_normalize(out)
	changed := body != input || final_nl != b.final_newline
	if changed {
		format_apply(b, body)
		b.final_newline = final_nl
		if b == editor_buffer(editor) {
			editor_scroll(editor)
		}
	}
	if save_after {
		editor_save_buffer(editor, b)
	} else {
		editor_set_message(editor, "Formatted" if changed else "No formatting changes")
	}
}

// Strip line terminators to the buffer's storage form: content joined by '\n' with
// the trailing newline hoisted out into a flag (matching buffer_snapshot / final_newline).
format_normalize :: proc(out: string) -> (string, bool) {
	text := out
	if strings.contains_rune(text, '\r') {
		text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	}
	final_nl := len(text) > 0 && text[len(text) - 1] == '\n'
	if final_nl {
		text = text[:len(text) - 1]
	}
	return text, final_nl
}

format_apply :: proc(b: ^Buffer, body: string) {
	old := b.cursor
	last := len(b.lines) - 1
	end := Cursor{last, len(b.lines[last].text)}
	edit_open(b, .Atomic)
	removed := buffer_delete(b, {0, 0}, end)
	append(&b.open.edits, Edit{.Insert, {0, 0}, removed})
	buffer_insert(b, {0, 0}, body)
	append(&b.open.edits, Edit{.Delete, {0, 0}, strings.clone(body)})
	buffer_undo_commit(b)
	b.selection = nil
	row := clamp(old.row, 0, len(b.lines) - 1)
	b.cursor = {row, clamp(old.col, 0, len(b.lines[row].text))}
	cursor_goal_sync(b)
}
