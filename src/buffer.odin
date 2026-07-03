package main

import "core:os"
import "core:slice"
import "core:strings"
import ts "lib:tree_sitter"

Buffer :: struct {
	path:          string,
	lines:         [dynamic]Line,
	cursor:        Cursor,
	selection:     Maybe(Cursor),
	goal_col:      int,
	saved:         string,
	modified:      bool,
	indent:        IndentStyle,
	line_ending:   LineEnding,
	final_newline: bool,
	undo:          [dynamic]EditGroup,
	redo:          [dynamic]EditGroup,
	open:          EditGroup,
	has_open:      bool,
	open_kind:     Coalesce,
	rev:           u64,
	hl:            Highlight,
	git:           GitGutter,
	diags:         [dynamic]Diagnostic,
	lsp_open:      bool,
	lsp_rev:       u64,
	lsp_changes:   [dynamic]LspChange,
	big:           bool,
}


Line :: struct {
	text: [dynamic]u8,
}

Cursor :: struct {
	row, col: int,
}

LineEnding :: enum {
	LF,
	CRLF,
}

IndentStyle :: enum {
	Spaces,
	Tabs,
}

buffer_new :: proc() -> Buffer {
	lines := make([dynamic]Line, 0, 64)
	append(&lines, Line{})
	buffer := Buffer {
		lines         = lines,
		cursor        = {0, 0},
		line_ending   = .LF,
		final_newline = true,
	}
	buffer.saved = buffer_snapshot(&buffer)
	return buffer
}

buffer_destroy :: proc(buffer: ^Buffer) {
	for &line in buffer.lines {
		delete(line.text)
	}
	delete(buffer.lines)
	delete(buffer.saved)
	delete(buffer.path)

	for &group in buffer.undo {
		group_destroy(&group)
	}
	delete(buffer.undo)
	for &group in buffer.redo {
		group_destroy(&group)
	}
	delete(buffer.redo)
	group_destroy(&buffer.open)
	highlight_destroy(&buffer.hl)
	git_destroy(&buffer.git)
	buffer_clear_diags(buffer)
	delete(buffer.diags)
	buffer_lsp_changes_clear(buffer)
	delete(buffer.lsp_changes)
}

buffer_snapshot :: proc(buffer: ^Buffer) -> string {
	sb := strings.builder_make()
	for line, i in buffer.lines {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_bytes(&sb, line.text[:])
	}
	return strings.to_string(sb)
}

buffer_byte_offset :: proc(buffer: ^Buffer, at: Cursor) -> int {
	off := 0
	for i in 0 ..< at.row {
		off += len(buffer.lines[i].text) + 1
	}
	return off + at.col
}

buffer_recompute_modified :: proc(buffer: ^Buffer) {
	saved := buffer.saved
	pos := 0
	for line, i in buffer.lines {
		if i > 0 {
			if pos >= len(saved) || saved[pos] != '\n' {
				buffer.modified = true
				return
			}
			pos += 1
		}
		t := line.text[:]
		if pos + len(t) > len(saved) || saved[pos:pos + len(t)] != string(t) {
			buffer.modified = true
			return
		}
		pos += len(t)
	}
	buffer.modified = pos != len(saved)
}

BufferOpenError :: enum {
	None,
	FileOpenError,
	FileReadError,
}

buffer_open :: proc(buffer: ^Buffer, path: string) -> BufferOpenError {
	file, err := os.open(path, flags = {.Read, .Create})
	if err != nil {
		return .FileOpenError
	}
	defer os.close(file)

	data: []u8
	data, err = os.read_entire_file(file, context.allocator)
	if err != nil {
		return .FileReadError
	}
	defer delete(data)

	for &line in buffer.lines {
		delete(line.text)
	}
	clear(&buffer.lines)

	text := string(data)
	buffer.big = len(data) >= BIG_FILE_BYTES
	buffer.line_ending = .CRLF if strings.contains(text, "\r\n") else .LF
	buffer.final_newline = len(text) > 0 && text[len(text) - 1] == '\n'

	segments := strings.split(text, "\n", context.temp_allocator)
	if buffer.final_newline {
		segments = segments[:len(segments) - 1]
	}
	for segment in segments {
		s := segment
		if len(s) > 0 && s[len(s) - 1] == '\r' {
			s = s[:len(s) - 1]
		}
		append(&buffer.lines, Line{text = slice.clone_to_dynamic(transmute([]u8)s)})
	}
	if len(buffer.lines) == 0 {
		append(&buffer.lines, Line{})
	}

	buffer.indent = .Spaces
	for line in buffer.lines {
		if len(line.text) == 0 || (line.text[0] != ' ' && line.text[0] != '\t') {
			continue
		}
		buffer.indent = .Tabs if line.text[0] == '\t' else .Spaces
		break
	}

	delete(buffer.path)
	buffer.path = strings.clone(path)
	buffer.cursor = {0, 0}
	buffer.selection = nil
	buffer.goal_col = 0
	delete(buffer.saved)
	buffer.saved = buffer_snapshot(buffer)
	buffer.modified = false
	git_invalidate(buffer)

	return .None
}

BufferSaveError :: enum {
	None,
	NoPath,
	WriteError,
	RenameError,
}

buffer_save :: proc(buffer: ^Buffer) -> BufferSaveError {
	if buffer.path == "" {
		return .NoPath
	}

	ending := "\r\n" if buffer.line_ending == .CRLF else "\n"
	sb := strings.builder_make(context.temp_allocator)
	for line, i in buffer.lines {
		if i > 0 {
			strings.write_string(&sb, ending)
		}
		strings.write_bytes(&sb, line.text[:])
	}
	if buffer.final_newline {
		strings.write_string(&sb, ending)
	}
	data := strings.to_string(sb)

	tmp := strings.concatenate({buffer.path, ".qed-tmp"}, context.temp_allocator)
	fd, open_err := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o644))
	if open_err != nil {
		return .WriteError
	}
	_, write_err := os.write(fd, transmute([]u8)data)
	os.close(fd)
	if write_err != nil {
		os.remove(tmp)
		return .WriteError
	}
	if os.rename(tmp, buffer.path) != nil {
		os.remove(tmp)
		return .RenameError
	}

	buffer_undo_commit(buffer)
	delete(buffer.saved)
	buffer.saved = buffer_snapshot(buffer)
	buffer.modified = false
	git_invalidate(buffer)

	return .None
}

buffer_text_range :: proc(buffer: ^Buffer, from, to: Cursor, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	if from.row == to.row {
		strings.write_bytes(&sb, buffer.lines[from.row].text[from.col:to.col])
	} else {
		strings.write_bytes(&sb, buffer.lines[from.row].text[from.col:])
		strings.write_byte(&sb, '\n')
		for r in from.row + 1 ..< to.row {
			strings.write_bytes(&sb, buffer.lines[r].text[:])
			strings.write_byte(&sb, '\n')
		}
		strings.write_bytes(&sb, buffer.lines[to.row].text[:to.col])
	}
	return strings.to_string(sb)
}

buffer_insert :: proc(buffer: ^Buffer, at: Cursor, text: string) -> Cursor {
	line := &buffer.lines[at.row]
	tail := slice.clone(line.text[at.col:])
	defer delete(tail)
	resize(&line.text, at.col)

	end := at
	rest := text
	segment_index := 0
	for {
		segment := rest
		nl := strings.index_byte(rest, '\n')
		if nl >= 0 {
			segment = rest[:nl]
		}

		if segment_index == 0 {
			append(&buffer.lines[end.row].text, ..transmute([]u8)segment)
			end.col = at.col + len(segment)
		} else {
			new_line: Line
			append(&new_line.text, ..transmute([]u8)segment)
			inject_at(&buffer.lines, end.row + 1, new_line)
			end.row += 1
			end.col = len(segment)
		}

		segment_index += 1
		if nl < 0 {
			break
		}
		rest = rest[nl + 1:]
	}

	append(&buffer.lines[end.row].text, ..tail)

	start_byte := u32(buffer_byte_offset(buffer, at))
	highlight_record_edit(&buffer.hl, ts.InputEdit {
		start_byte    = start_byte,
		old_end_byte  = start_byte,
		new_end_byte  = u32(buffer_byte_offset(buffer, end)),
		start_point   = {u32(at.row), u32(at.col)},
		old_end_point = {u32(at.row), u32(at.col)},
		new_end_point = {u32(end.row), u32(end.col)},
	})
	lsp_change_record(buffer, at, at, text)

	buffer_recompute_modified(buffer)
	buffer.rev += 1
	return end
}

buffer_delete :: proc(buffer: ^Buffer, from, to: Cursor) -> string {
	start_byte := u32(buffer_byte_offset(buffer, from))
	highlight_record_edit(&buffer.hl, ts.InputEdit {
		start_byte    = start_byte,
		old_end_byte  = u32(buffer_byte_offset(buffer, to)),
		new_end_byte  = start_byte,
		start_point   = {u32(from.row), u32(from.col)},
		old_end_point = {u32(to.row), u32(to.col)},
		new_end_point = {u32(from.row), u32(from.col)},
	})
	lsp_change_record(buffer, from, to, "")

	sb := strings.builder_make()

	if from.row == to.row {
		line := &buffer.lines[from.row]
		strings.write_bytes(&sb, line.text[from.col:to.col])
		n := to.col - from.col
		copy(line.text[from.col:], line.text[to.col:])
		resize(&line.text, len(line.text) - n)
	} else {
		strings.write_bytes(&sb, buffer.lines[from.row].text[from.col:])
		strings.write_byte(&sb, '\n')
		for r in from.row + 1 ..< to.row {
			strings.write_bytes(&sb, buffer.lines[r].text[:])
			strings.write_byte(&sb, '\n')
		}
		last := &buffer.lines[to.row]
		strings.write_bytes(&sb, last.text[:to.col])

		last_tail := slice.clone(last.text[to.col:])
		resize(&buffer.lines[from.row].text, from.col)
		append(&buffer.lines[from.row].text, ..last_tail)
		delete(last_tail)

		for r in from.row + 1 ..= to.row {
			delete(buffer.lines[r].text)
		}
		remove_range(&buffer.lines, from.row + 1, to.row + 1)
	}

	if len(buffer.lines) == 0 {
		append(&buffer.lines, Line{})
	}

	buffer_recompute_modified(buffer)
	buffer.rev += 1
	return strings.to_string(sb)
}
