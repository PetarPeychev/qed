package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

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

preview_test_file :: proc(name: string, content: []u8) -> string {
	path := fmt.aprintf("/tmp/qed_preview_%d_%s", posix.getpid(), name)
	_ = os.write_entire_file(path, content)
	return path
}

@(test)
test_preview_set_file_empty :: proc(t: ^testing.T) {
	path := preview_test_file("empty.txt", nil)
	defer {os.remove(path);delete(path)}
	p: Preview
	defer preview_destroy(&p)
	preview_set_file(&p, path, 0, 20)
	testing.expect(t, p.empty)
	testing.expect(t, !p.hex)
	testing.expect_value(t, len(p.src), 0)
}

@(test)
test_preview_set_file_small_binary :: proc(t: ^testing.T) {
	path := preview_test_file("bin.dat", []u8{0x7f, 'E', 'L', 'F', 0x00, 0x01, 0x02})
	defer {os.remove(path);delete(path)}
	p: Preview
	defer preview_destroy(&p)
	preview_set_file(&p, path, 0, 20)
	testing.expect(t, p.hex)
	testing.expect(t, !p.empty)
	testing.expect_value(t, len(p.rows), 1)
	testing.expect(t, strings.has_suffix(p.rows[0].text, "|.ELF...|"))
}

@(test)
test_preview_set_file_text_stays_text :: proc(t: ^testing.T) {
	path := preview_test_file("text.txt", transmute([]u8)string("plain text\nline two\n"))
	defer {os.remove(path);delete(path)}
	p: Preview
	defer preview_destroy(&p)
	preview_set_file(&p, path, 0, 20)
	testing.expect(t, !p.hex)
	testing.expect(t, !p.empty)
	testing.expect_value(t, p.src[0], "plain text")
}
