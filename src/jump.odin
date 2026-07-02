package main

import "core:strings"

Jump :: struct {
	path: string,
	row:  int,
	col:  int,
}

JumpList :: struct {
	entries: [dynamic]Jump,
	index:   int,
}

jump_destroy :: proc(jl: ^JumpList) {
	for e in jl.entries {
		delete(e.path)
	}
	delete(jl.entries)
}

jump_here :: proc(editor: ^Editor) -> Jump {
	b := editor_buffer(editor)
	return {path = b.path, row = b.cursor.row, col = b.cursor.col}
}

jump_record :: proc(editor: ^Editor, origin: Jump) {
	if editor.jump_lock {
		editor.jump_lock = false
		return
	}
	jl := &editor.jumps
	dest := jump_here(editor)

	if len(jl.entries) == 0 {
		append(&jl.entries, Jump{strings.clone(origin.path), origin.row, origin.col})
		jl.index = 0
	}

	row_delta := dest.row - origin.row
	if row_delta < 0 {
		row_delta = -row_delta
	}

	if origin.path == dest.path && row_delta <= JUMP_THRESHOLD {
		cur := &jl.entries[jl.index]
		if cur.path != dest.path {
			delete(cur.path)
			cur.path = strings.clone(dest.path)
		}
		cur.row = dest.row
		cur.col = dest.col
		return
	}

	for i in jl.index + 1 ..< len(jl.entries) {
		delete(jl.entries[i].path)
	}
	resize(&jl.entries, jl.index + 1)
	append(&jl.entries, Jump{strings.clone(dest.path), dest.row, dest.col})
	jl.index = len(jl.entries) - 1
}

jump_go :: proc(editor: ^Editor, target: Jump) {
	editor.jump_lock = true
	if target.path != "" {
		editor_open_path(editor, target.path)
	} else {
		idx := editor_find_buffer(editor, "")
		if idx < 0 {
			return
		}
		editor_switch_to(editor, idx)
	}
	b := editor_buffer(editor)
	row := clamp(target.row, 0, len(b.lines) - 1)
	col := clamp(target.col, 0, len(b.lines[row].text))
	b.selection = nil
	b.cursor = {row, col}
	cursor_goal_sync(b)
	_, h := editor_viewport(editor)
	editor.scroll_row = row - h / 2
	editor_scroll(editor)
}

jump_back :: proc(editor: ^Editor) {
	jl := &editor.jumps
	if jl.index <= 0 {
		editor.message = "No earlier position"
		return
	}
	jl.index -= 1
	jump_go(editor, jl.entries[jl.index])
}

jump_forward :: proc(editor: ^Editor) {
	jl := &editor.jumps
	if jl.index >= len(jl.entries) - 1 {
		editor.message = "No later position"
		return
	}
	jl.index += 1
	jump_go(editor, jl.entries[jl.index])
}
