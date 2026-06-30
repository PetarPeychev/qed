package main

import "core:os"
import "core:slice"
import "core:strings"

Buffer :: struct {
	path:   string,
	lines:  [dynamic]Line,
	cursor: Cursor,
}


Line :: struct {
	text: [dynamic]u8,
}

Cursor :: struct {
	row, col: int,
}

buffer_new :: proc() -> Buffer {
	return {file = "", lines = make([dynamic]Line, 0, 64), cursor = {0, 0}}
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

	data: []u8
	data, err = os.read_entire_file(file, context.allocator)
	if err != nil {
		return .FileReadError
	}

	for &line in buffer.lines {
		delete(line.text)
	}
	clear(&buffer.lines)

	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		append(&buffer.lines, Line{text = slice.clone_to_dynamic(transmute([]u8)line)})
	}

	buffer.cursor = {0, 0}

	return .None
}
