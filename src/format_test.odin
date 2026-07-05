package main

import "core:os"
import "core:testing"

@(private = "file")
save_and_read_last_byte :: proc(b: ^Buffer, path: string) -> (u8, bool) {
	b.path = path
	defer b.path = ""
	if buffer_save(b) != .None {
		return 0, false
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	os.remove(path)
	if err != nil || len(data) == 0 {
		return 0, false
	}
	defer delete(data)
	return data[len(data) - 1], true
}

// Mirrors format_external's decision + apply for a given ruff-style output.
@(private = "file")
apply_format :: proc(b: ^Buffer, out: string) {
	input := buffer_snapshot(b)
	defer delete(input)
	body, final_nl := format_normalize(out)
	if body != input || final_nl != b.final_newline {
		format_apply(b, body)
		b.final_newline = final_nl
	}
}

@(test)
test_format_preserves_trailing_newline :: proc(t: ^testing.T) {
	b := test_buffer("x = 1")
	defer buffer_destroy(&b)
	b.final_newline = true

	apply_format(&b, "x = 1\n") // ruff: no change, keeps newline
	testing.expect(t, b.final_newline, "flag stays true")

	last, ok := save_and_read_last_byte(&b, "/tmp/qed-fmt-preserve.py")
	testing.expect(t, ok)
	testing.expect_value(t, last, u8('\n'))
}

@(test)
test_format_reformats_keeps_newline :: proc(t: ^testing.T) {
	b := test_buffer("x=1") // ruff will reformat this
	defer buffer_destroy(&b)
	b.final_newline = true

	apply_format(&b, "x = 1\n")
	testing.expect(t, b.final_newline, "flag stays true through a content change")

	last, ok := save_and_read_last_byte(&b, "/tmp/qed-fmt-reformat.py")
	testing.expect(t, ok)
	testing.expect_value(t, last, u8('\n'))
}

@(test)
test_format_adds_missing_trailing_newline :: proc(t: ^testing.T) {
	b := test_buffer("x=1")
	defer buffer_destroy(&b)
	b.final_newline = false

	apply_format(&b, "x = 1\n") // ruff reformats and ends with newline
	testing.expect(t, b.final_newline, "flag flips to true")

	last, ok := save_and_read_last_byte(&b, "/tmp/qed-fmt-add.py")
	testing.expect(t, ok)
	testing.expect_value(t, last, u8('\n'))
}
