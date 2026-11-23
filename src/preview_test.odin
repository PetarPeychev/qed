package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_preview_is_binary :: proc(t: ^testing.T) {
	testing.expect(t, preview_is_binary(transmute([]u8)string("hello\x00world")))
	testing.expect(t, !preview_is_binary(transmute([]u8)string("hello world\n\t")))
	testing.expect(t, !preview_is_binary(nil))
}

@(test)
test_hex_dump_line_full :: proc(t: ^testing.T) {
	data := []u8{0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x00, 0x01, 0x7f, 0xff}
	line := hex_dump_line(data, 0, context.temp_allocator)
	want := "00000000  48 65 6c 6c 6f 20 77 6f  72 6c 64 21 00 01 7f ff  |Hello world!....|"
	testing.expect_value(t, line, want)
}

@(test)
test_hex_dump_line_partial :: proc(t: ^testing.T) {
	line := hex_dump_line([]u8{0x41, 0x0a}, 0x10, context.temp_allocator)
	testing.expect(t, strings.has_prefix(line, "00000010  41 0a "))
	testing.expect(t, strings.has_suffix(line, "|A.|"))
	testing.expect_value(t, len(line), 64)
}

@(test)
test_hex_dump_line_offset_width :: proc(t: ^testing.T) {
	line := hex_dump_line([]u8{0x00}, 0, context.temp_allocator)
	testing.expect(t, strings.has_prefix(line, "00000000  "))
}
