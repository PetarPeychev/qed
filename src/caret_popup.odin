package main

import "core:fmt"
import "core:strings"
import "lib:tb2"

// a tiny configured hover width still leaves a readable box
HOVER_MIN_WIDTH :: 20

CARET_OUTLET :: "caret"

CaretPopup :: struct {
	handle:    u64,
	target:    string,
	signature: string,
	// the diagnostic box closed by the wheel stays closed until the caret moves
	diag_closed_at: Maybe(Cursor),
}

@(private = "file")
buffer_is_elsewhere :: proc(editor: ^Editor, at: Cursor) -> bool {
	return len(editor.buffers) == 0 || editor_buffer(editor).cursor != at
}

caret_diagnostic_close :: proc(editor: ^Editor) {
	if editor.caret_popup.handle != 0 && strings.has_prefix(editor.caret_popup.signature, "diag|") {
		editor.caret_popup.diag_closed_at = editor_buffer(editor).cursor
	}
}

caret_popup_free :: proc(popup: ^CaretPopup) {
	delete(popup.target)
	delete(popup.signature)
}

caret_popup_sync :: proc(editor: ^Editor) {
	ui := &editor.ui
	popup := &editor.caret_popup
	target, signature := "", ""
	root: ^UiNode
	if at, closed := popup.diag_closed_at.?; closed && buffer_is_elsewhere(editor, at) {
		popup.diag_closed_at = nil
	}
	focus := ui_focused(editor)
	buffer := ui_buffer(editor, focus.buffer) if focus != nil && focus.kind == .Editor else nil
	if buffer != nil && ui_node_edits(focus) && ui_editor_shows_current(editor, buffer) {
		target = focus.identity
		ghost := inline_active(editor)
		c := &editor.completion
		if c.active && len(c.matches) > 0 {
			signature = caret_completion_signature(editor, target)
			if signature != popup.signature {
				root = caret_completion_build(editor, buffer)
			}
		} else if !ghost && editor.hover_active && len(editor.hover) > 0 {
			signature = fmt.tprintf("hover|%s|%d|%d|%d", target, tb2.width(), HOVER_MAX_WIDTH, editor.hover_gen)
			if signature != popup.signature {
				root = caret_hover_build(editor)
			}
		} else if d, ok := diagnostic_at(buffer, buffer.cursor); !ghost && ok && popup.diag_closed_at == nil {
			signature = fmt.tprintf("diag|%s|%d|%d|%s", target, tb2.width(), d.severity, d.message)
			if signature != popup.signature {
				root = caret_diag_build(d)
			}
		}
	}
	if signature == popup.signature {
		return
	}
	delete(popup.signature)
	popup.signature = strings.clone(signature)
	delete(popup.target)
	popup.target = strings.clone(target)
	ui.dirty = true
	if root == nil {
		if popup.handle != 0 {
			ui_mount_remove(editor, popup.handle)
			popup.handle = 0
		}
		return
	}
	if popup.handle == 0 || !ui_mount_replace(editor, popup.handle, root) {
		popup.handle = ui_mount_add(editor, "", CARET_OUTLET, root)
	}
	if rows := ui_find_in(root, "caret_completion_rows"); rows != nil {
		state := ui_node_state(ui, rows)
		delete(state.highlighted)
		state.highlighted = strings.clone(fmt.tprintf("%d", editor.completion.selected))
	}
	if scroll := ui_find_in(root, "caret_hover_scroll"); scroll != nil {
		ui_node_state(ui, scroll).offset = 0
	}
}

caret_popup_root :: proc(editor: ^Editor) -> ^UiNode {
	for mount in editor.ui.mounts {
		if mount.handle == editor.caret_popup.handle && mount.root.parent != nil {
			return mount.root
		}
	}
	return nil
}

ui_find_in :: proc(node: ^UiNode, id: string) -> ^UiNode {
	if node.id == id {
		return node
	}
	for child in node.children {
		if found := ui_find_in(child, id); found != nil {
			return found
		}
	}
	return nil
}

@(private = "file")
caret_box :: proc(id: string, width, height: int) -> ^UiNode {
	box := ui_core_node(.Box, id)
	box.float, box.anchor, box.border = .Screen, .Cursor, true
	box.width = {form = .Cells, value = width}
	box.height = {form = .Cells, value = height}
	box.style = ui_core_pane_style()
	return box
}

@(private = "file")
caret_completion_signature :: proc(editor: ^Editor, target: string) -> string {
	c := &editor.completion
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "completion|%s|%d|%d|%d|%d|%d|%d|", target, c.items_gen, c.selected, c.scroll, c.anchor_row, c.anchor_col, inline_gap(editor))
	for m in c.matches[c.scroll:min(len(c.matches), c.scroll + COMPLETION_MAX_ROWS)] {
		fmt.sbprintf(&sb, "%d,", m)
	}
	fmt.sbprintf(&sb, "|%d", len(c.matches))
	return strings.to_string(sb)
}

@(private = "file")
caret_completion_build :: proc(editor: ^Editor, buffer: ^Buffer) -> ^UiNode {
	c := &editor.completion
	rows := min(len(c.matches), COMPLETION_MAX_ROWS)
	content_w := 0
	for m in c.matches {
		item := &c.items[m]
		w := len(item.label)
		if item.detail != "" {
			w += 2 + len(item.detail)
		}
		content_w = max(content_w, w)
	}
	content_w = clamp(content_w, 10, COMPLETION_MAX_WIDTH)
	box := caret_box("caret_completion", content_w + 4, rows + 2)
	// the box starts at the completed word, not the caret
	box.cursor_from = Cursor{c.anchor_row, c.anchor_col}
	// a multi-line ghost fills the rows below the caret
	box.cursor_above = inline_gap(editor) > 0
	column := ui_core_node(.Column, "caret_completion_rows")
	column.highlight_style = {set = {.Fg, .Bg}, fg = strings.clone("pane_selection_foreground"), bg = strings.clone("pane_selection_background")}
	ui_core_add(box, column)
	for idx in c.scroll ..< c.scroll + rows {
		item := &c.items[c.matches[idx]]
		row := ui_core_node(.Row)
		row.key = strings.clone(fmt.tprintf("%d", idx))
		label := ui_core_text(fmt.tprintf(" %s", item.label))
		label.grow, label.grow_set = 1, true
		ui_core_add(row, label)
		if item.detail != "" {
			ui_core_add(row, ui_core_text(fmt.tprintf("%s ", item.detail), fg = "pane_shortcut_foreground"))
		}
		ui_core_add(column, row)
	}
	return box
}

@(private = "file")
caret_hover_build :: proc(editor: ^Editor) -> ^UiNode {
	text_w := min(int(tb2.width()) - 2 * DIAG_PANE_MARGIN_X, max(HOVER_MIN_WIDTH, HOVER_MAX_WIDTH)) - 3
	if text_w < 8 {
		return nil
	}
	source := string(editor.hover[:])
	lines := md_render(source, text_w, editor.hover_lang)
	if len(lines) == 0 {
		return nil
	}
	content_w := 0
	for line in lines {
		content_w = max(content_w, md_line_width(line))
	}
	content_w = clamp(content_w, 1, text_w)
	box := caret_box("caret_hover", content_w + 3, min(len(lines), HOVER_PANE_MAX_LINES) + 2)
	scroll := ui_core_node(.Scroll, "caret_hover_scroll")
	ui_core_add(box, scroll)
	body := ui_core_node(.Markdown, "caret_hover_body")
	body.source = strings.clone(source)
	body.md_lang = editor.hover_lang
	ui_core_add(scroll, body)
	return box
}

@(private = "file")
caret_diag_build :: proc(d: ^Diagnostic) -> ^UiNode {
	text_w := int(tb2.width()) - 2 * DIAG_PANE_MARGIN_X - 2
	if text_w < 8 {
		return nil
	}
	lines := wrap_text(d.message, text_w)
	if len(lines) == 0 {
		return nil
	}
	content_w := 0
	for line in lines {
		content_w = max(content_w, len(line))
	}
	shown := min(len(lines), DIAG_PANE_MAX_LINES)
	box := caret_box("caret_diagnostic", content_w + 2, shown + 2)
	color := "diagnostic_info_foreground"
	switch d.severity {
	case 1:
		color = "diagnostic_error_foreground"
	case 2:
		color = "diagnostic_warning_foreground"
	}
	column := ui_core_node(.Column)
	ui_core_add(box, column)
	for line in lines[:shown] {
		ui_core_add(column, ui_core_text(line, fg = color))
	}
	return box
}
