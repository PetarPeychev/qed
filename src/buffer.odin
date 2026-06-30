package main

import "core:os"
import "core:slice"
import "core:strings"

Buffer :: struct {
	path:     string,
	lines:    [dynamic]Line,
	cursor:   Cursor,
	goal_col: int,
}


Line :: struct {
	text: [dynamic]u8,
}

Cursor :: struct {
	row, col: int,
}

buffer_new :: proc() -> Buffer {
	lines := make([dynamic]Line, 0, 64)
	append(&lines, Line{})
	return {path = "", lines = lines, cursor = {0, 0}}
}

buffer_destroy :: proc(buffer: ^Buffer) {
	for &line in buffer.lines {
		delete(line.text)
	}
	delete(buffer.lines)
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

	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		append(&buffer.lines, Line{text = slice.clone_to_dynamic(transmute([]u8)line)})
	}
	if len(buffer.lines) == 0 {
		append(&buffer.lines, Line{})
	}

	buffer.path = path
	buffer.cursor = {0, 0}
	buffer.goal_col = 0

	return .None
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
	return end
}

buffer_delete :: proc(buffer: ^Buffer, from, to: Cursor) -> string {
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

	return strings.to_string(sb)
}
