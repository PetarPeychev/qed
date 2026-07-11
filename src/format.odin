package main

import "core:fmt"
import "core:strings"

line_trailing_ws :: proc(text: []u8) -> int {
	n := 0
	for n < len(text) && (text[len(text) - 1 - n] == ' ' || text[len(text) - 1 - n] == '\t') {
		n += 1
	}
	return n
}

line_trim_len :: proc(text: []u8, markdown: bool) -> int {
	n := line_trailing_ws(text)
	if n == 0 {
		return 0
	}
	// Two+ trailing spaces on a markdown content line are a hard line break.
	if markdown && n < len(text) && text[len(text) - 1] == ' ' && text[len(text) - 2] == ' ' {
		return 0
	}
	return n
}

buffer_save_fixups :: proc(b: ^Buffer, trim_ws, final_newline: bool) {
	md := b.language == .Markdown
	last_text := b.lines[len(b.lines) - 1].text[:]
	last_trim := line_trim_len(last_text, md) if trim_ws else 0
	add_newline := final_newline && len(last_text) > last_trim

	need := add_newline
	if trim_ws && !need {
		for line in b.lines {
			if line_trim_len(line.text[:], md) > 0 {
				need = true
				break
			}
		}
	}
	if !need {
		return
	}

	cur := b.cursor
	anchor, has_anchor := b.selection.?

	edit_open(b, .Atomic)
	if trim_ws {
		for row in 0 ..< len(b.lines) {
			text := b.lines[row].text[:]
			n := line_trim_len(text, md)
			if n == 0 {
				continue
			}
			start := len(text) - n
			edit_delete(b, {row, start}, {row, len(text)})
			if cur.row == row && cur.col > start {
				cur.col = start
			}
			if has_anchor && anchor.row == row && anchor.col > start {
				anchor.col = start
			}
		}
	}
	if add_newline {
		last := len(b.lines) - 1
		edit_insert(b, {last, len(b.lines[last].text)}, "\n")
	}
	buffer_undo_commit(b)

	b.cursor = cur
	cursor_goal_sync(b)
	if has_anchor {
		b.selection = anchor
	}
}

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

	body := format_normalize(out)
	changed := body != input
	if changed {
		format_apply(b, body)
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

format_normalize :: proc(out: string) -> string {
	text := out
	if strings.contains_rune(text, '\r') {
		text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	}
	return text
}

format_apply :: proc(b: ^Buffer, body: string) {
	old := b.cursor
	last := len(b.lines) - 1
	end := Cursor{last, len(b.lines[last].text)}
	edit_open(b, .Atomic)
	edit_delete(b, {0, 0}, end)
	edit_insert(b, {0, 0}, body)
	buffer_undo_commit(b)
	b.selection = nil
	row := clamp(old.row, 0, len(b.lines) - 1)
	b.cursor = {row, clamp(old.col, 0, len(b.lines[row].text))}
	cursor_goal_sync(b)
}
