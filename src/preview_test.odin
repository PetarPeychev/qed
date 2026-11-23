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

preview_test_file :: proc(name: string, content: []u8) -> string {
	path := fmt.tprintf("/tmp/qed_preview_%d_%s", posix.getpid(), name)
	_ = os.write_entire_file(path, content)
	return path
}

preview_test_load :: proc(e: ^E2E, path: string) -> Buffer {
	buffer := buffer_new()
	ui_internal_load(&e.ed, &buffer, path)
	return buffer
}

@(test)
test_preview_load_small_binary :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	path := preview_test_file("bin.dat", []u8{0x7f, 'E', 'L', 'F', 0x00, 0x01, 0x02})
	defer os.remove(path)
	buffer := preview_test_load(&e, path)
	defer buffer_destroy(&buffer)
	testing.expect(t, strings.has_suffix(string(buffer.lines[0].text[:]), "|.ELF...|"), "a binary file loads as a hexdump")
}

@(test)
test_preview_read_caps_bytes_at_a_line :: proc(t: ^testing.T) {
	content := make([]u8, PREVIEW_MAX_BYTES + 200 * 1024, context.temp_allocator)
	for &b, i in content {
		b = '\n' if i % 100 == 99 else 'a'
	}
	path := preview_test_file("big.txt", content)
	defer os.remove(path)
	data, ok := ui_preview_read(path)
	testing.expect(t, ok && len(data) > 0 && len(data) <= PREVIEW_MAX_BYTES, "capped at PREVIEW_MAX_BYTES")
	testing.expect(t, len(data) > 0 && data[len(data) - 1] == '\n', "cut back to a whole line")
}

@(test)
test_preview_load_text_stays_text :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	path := preview_test_file("text.txt", transmute([]u8)string("plain text\nline two\n"))
	defer os.remove(path)
	buffer := preview_test_load(&e, path)
	defer buffer_destroy(&buffer)
	testing.expect_value(t, string(buffer.lines[0].text[:]), "plain text")
	testing.expect_value(t, string(buffer.lines[1].text[:]), "line two")
}

@(test)
test_preview_load_crlf_whole :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 3000 {
		fmt.sbprintf(&sb, "line %d\r\n", i)
	}
	path := preview_test_file("crlf.txt", transmute([]u8)strings.to_string(sb))
	defer os.remove(path)
	buffer := preview_test_load(&e, path)
	defer buffer_destroy(&buffer)
	testing.expect_value(t, string(buffer.lines[0].text[:]), "line 0")
	testing.expect_value(t, string(buffer.lines[2999].text[:]), "line 2999")
}
