package main

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
buffer_string :: proc(b: ^Buffer) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for line, i in b.lines {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_bytes(&sb, line.text[:])
	}
	return strings.to_string(sb)
}

@(test)
test_insert_within_line :: proc(t: ^testing.T) {
	b := test_buffer("hello world")
	defer buffer_destroy(&b)

	end := buffer_insert(&b, {0, 5}, " there")

	testing.expect_value(t, buffer_string(&b), "hello there world")
	testing.expect_value(t, end, Cursor{0, 11})
}

@(test)
test_insert_at_end :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)

	end := buffer_insert(&b, {0, 3}, "def")

	testing.expect_value(t, buffer_string(&b), "abcdef")
	testing.expect_value(t, end, Cursor{0, 6})
}

@(test)
test_insert_empty_is_noop :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)

	end := buffer_insert(&b, {0, 2}, "")

	testing.expect_value(t, buffer_string(&b), "abc")
	testing.expect_value(t, end, Cursor{0, 2})
}

@(test)
test_insert_newline_splits_line :: proc(t: ^testing.T) {
	b := test_buffer("hello world")
	defer buffer_destroy(&b)

	end := buffer_insert(&b, {0, 5}, "\n")

	testing.expect_value(t, buffer_string(&b), "hello\n world")
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, end, Cursor{1, 0})
}

@(test)
test_insert_multiline :: proc(t: ^testing.T) {
	b := test_buffer("ac")
	defer buffer_destroy(&b)

	end := buffer_insert(&b, {0, 1}, "1\n22\n333")

	testing.expect_value(t, buffer_string(&b), "a1\n22\n333c")
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, end, Cursor{2, 3})
}

@(test)
test_insert_into_empty_buffer :: proc(t: ^testing.T) {
	b := buffer_new()
	defer buffer_destroy(&b)

	end := buffer_insert(&b, {0, 0}, "first\nsecond")

	testing.expect_value(t, buffer_string(&b), "first\nsecond")
	testing.expect_value(t, end, Cursor{1, 6})
}

@(test)
test_delete_within_line :: proc(t: ^testing.T) {
	b := test_buffer("hello there world")
	defer buffer_destroy(&b)

	removed := buffer_delete(&b, {0, 5}, {0, 11})
	defer delete(removed)

	testing.expect_value(t, removed, " there")
	testing.expect_value(t, buffer_string(&b), "hello world")
}

@(test)
test_delete_joins_lines :: proc(t: ^testing.T) {
	b := test_buffer("hello", " world")
	defer buffer_destroy(&b)

	removed := buffer_delete(&b, {0, 5}, {1, 0})
	defer delete(removed)

	testing.expect_value(t, removed, "\n")
	testing.expect_value(t, buffer_string(&b), "hello world")
	testing.expect_value(t, len(b.lines), 1)
}

@(test)
test_delete_multiline :: proc(t: ^testing.T) {
	b := test_buffer("a1", "22", "333c")
	defer buffer_destroy(&b)

	removed := buffer_delete(&b, {0, 1}, {2, 3})
	defer delete(removed)

	testing.expect_value(t, removed, "1\n22\n333")
	testing.expect_value(t, buffer_string(&b), "ac")
	testing.expect_value(t, len(b.lines), 1)
}

@(test)
test_delete_all_keeps_one_empty_line :: proc(t: ^testing.T) {
	b := test_buffer("first", "second", "third")
	defer buffer_destroy(&b)

	removed := buffer_delete(&b, {0, 0}, {2, 5})
	defer delete(removed)

	testing.expect_value(t, buffer_string(&b), "")
	testing.expect_value(t, len(b.lines), 1)
	testing.expect_value(t, len(b.lines[0].text), 0)
}

@(test)
test_insert_rune_advances_cursor :: proc(t: ^testing.T) {
	b := test_buffer("ac")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}

	buffer_insert_rune(&b, 'b')

	testing.expect_value(t, buffer_string(&b), "abc")
	testing.expect_value(t, b.cursor, Cursor{0, 2})
	testing.expect_value(t, b.goal_col, 2)
}

@(test)
test_insert_text_newline_moves_to_next_row :: proc(t: ^testing.T) {
	b := test_buffer("ab")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}

	buffer_insert_text(&b, "\n")

	testing.expect_value(t, buffer_string(&b), "a\nb")
	testing.expect_value(t, b.cursor, Cursor{1, 0})
}

@(test)
test_backspace_within_line :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.cursor = {0, 2}

	buffer_backspace(&b)

	testing.expect_value(t, buffer_string(&b), "ac")
	testing.expect_value(t, b.cursor, Cursor{0, 1})
}

@(test)
test_backspace_joins_lines :: proc(t: ^testing.T) {
	b := test_buffer("ab", "cd")
	defer buffer_destroy(&b)
	b.cursor = {1, 0}

	buffer_backspace(&b)

	testing.expect_value(t, buffer_string(&b), "abcd")
	testing.expect_value(t, len(b.lines), 1)
	testing.expect_value(t, b.cursor, Cursor{0, 2})
}

@(test)
test_backspace_at_buffer_start_is_noop :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.cursor = {0, 0}

	buffer_backspace(&b)

	testing.expect_value(t, buffer_string(&b), "abc")
	testing.expect_value(t, b.cursor, Cursor{0, 0})
}

@(test)
test_delete_forward_joins_lines :: proc(t: ^testing.T) {
	b := test_buffer("ab", "cd")
	defer buffer_destroy(&b)
	b.cursor = {0, 2}

	buffer_delete_forward(&b)

	testing.expect_value(t, buffer_string(&b), "abcd")
	testing.expect_value(t, len(b.lines), 1)
	testing.expect_value(t, b.cursor, Cursor{0, 2})
}

@(test)
test_delete_forward_at_buffer_end_is_noop :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.cursor = {0, 3}

	buffer_delete_forward(&b)

	testing.expect_value(t, buffer_string(&b), "abc")
	testing.expect_value(t, b.cursor, Cursor{0, 3})
}

@(test)
test_insert_tab_at_stop_inserts_full_width :: proc(t: ^testing.T) {
	b := test_buffer("x")
	defer buffer_destroy(&b)
	b.cursor = {0, 0}

	buffer_insert_tab(&b)

	testing.expect_value(t, buffer_string(&b), "    x")
	testing.expect_value(t, b.cursor, Cursor{0, 4})
}

@(test)
test_insert_tab_aligns_to_next_stop :: proc(t: ^testing.T) {
	b := test_buffer("ab")
	defer buffer_destroy(&b)
	b.cursor = {0, 2}

	buffer_insert_tab(&b)

	testing.expect_value(t, buffer_string(&b), "ab  ")
	testing.expect_value(t, b.cursor, Cursor{0, 4})
}

@(test)
test_insert_tab_tabs_mode_inserts_tab :: proc(t: ^testing.T) {
	b := test_buffer("x")
	defer buffer_destroy(&b)
	b.indent = .Tabs
	b.cursor = {0, 0}

	buffer_insert_tab(&b)

	testing.expect_value(t, buffer_string(&b), "\tx")
	testing.expect_value(t, b.cursor, Cursor{0, 1})
}

@(test)
test_dedent_tabs_mode_removes_one_tab :: proc(t: ^testing.T) {
	b := test_buffer("\t\tx")
	defer buffer_destroy(&b)
	b.indent = .Tabs
	b.cursor = {0, 3}

	buffer_dedent(&b)

	testing.expect_value(t, buffer_string(&b), "\tx")
	testing.expect_value(t, b.cursor, Cursor{0, 2})
}

@(test)
test_modified_clears_when_content_reverts :: proc(t: ^testing.T) {
	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect(t, !b.modified)

	buffer_insert_text(&b, "hello")
	testing.expect(t, b.modified)

	buffer_insert_text(&b, "\nworld")
	testing.expect(t, b.modified)

	delete(buffer_delete(&b, {0, 0}, b.cursor))
	testing.expect(t, !b.modified)
}

@(test)
test_insert_delete_roundtrip :: proc(t: ^testing.T) {
	b := test_buffer("ac")
	defer buffer_destroy(&b)

	end := buffer_insert(&b, {0, 1}, "1\n22\n333")
	removed := buffer_delete(&b, {0, 1}, end)
	defer delete(removed)

	testing.expect_value(t, removed, "1\n22\n333")
	testing.expect_value(t, buffer_string(&b), "ac")
}

@(private = "file")
save_roundtrip :: proc(t: ^testing.T, path: string, content: string) {
	testing.expect(t, os.write_entire_file(path, transmute([]u8)content) == nil)
	defer os.remove(path)

	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect_value(t, buffer_open(&b, path), BufferOpenError.None)

	testing.expect_value(t, buffer_save(&b), BufferSaveError.None)

	written, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(written), content)
}

@(test)
test_open_detects_lf_no_final_newline :: proc(t: ^testing.T) {
	path := "/tmp/qed-test-lf"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("a\nb")) == nil)
	defer os.remove(path)

	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect_value(t, buffer_open(&b, path), BufferOpenError.None)

	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, buffer_string(&b), "a\nb")
	testing.expect_value(t, b.line_ending, LineEnding.LF)
}

@(test)
test_open_detects_crlf_final_newline :: proc(t: ^testing.T) {
	path := "/tmp/qed-test-crlf"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("a\r\nb\r\n")) == nil)
	defer os.remove(path)

	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect_value(t, buffer_open(&b, path), BufferOpenError.None)

	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, buffer_string(&b), "a\nb\n")
	testing.expect_value(t, b.line_ending, LineEnding.CRLF)
}

@(test)
test_save_preserves_lf :: proc(t: ^testing.T) {
	save_roundtrip(t, "/tmp/qed-test-save-lf", "a\nb\n")
}

@(test)
test_save_preserves_lf_no_final_newline :: proc(t: ^testing.T) {
	save_roundtrip(t, "/tmp/qed-test-save-lf-nonl", "a\nb")
}

@(test)
test_save_preserves_crlf :: proc(t: ^testing.T) {
	save_roundtrip(t, "/tmp/qed-test-save-crlf", "a\r\nb\r\n")
}

@(test)
test_save_creates_missing_parent_dirs :: proc(t: ^testing.T) {
	root := "/tmp/qed-test-save-mkdirs"
	os.remove_all(root)
	defer os.remove_all(root)

	path := "/tmp/qed-test-save-mkdirs/a/b/file.txt"
	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect_value(t, buffer_open(&b, path), BufferOpenError.None)
	buffer_insert(&b, {0, 0}, "hello\nworld")

	testing.expect_value(t, buffer_save(&b), BufferSaveError.None)

	written, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(written), "hello\nworld")
}

@(test)
test_save_into_existing_dir :: proc(t: ^testing.T) {
	root := "/tmp/qed-test-save-existing"
	os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	path := "/tmp/qed-test-save-existing/file.txt"
	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect_value(t, buffer_open(&b, path), BufferOpenError.None)
	buffer_insert(&b, {0, 0}, "content")

	testing.expect_value(t, buffer_save(&b), BufferSaveError.None)

	written, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(written), "content")
}

@(test)
test_save_parent_is_file_errors :: proc(t: ^testing.T) {
	parent := "/tmp/qed-test-save-parentfile"
	os.remove_all(parent)
	testing.expect(t, os.write_entire_file(parent, transmute([]u8)string("x")) == nil)
	defer os.remove_all(parent)

	path := "/tmp/qed-test-save-parentfile/file.txt"
	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect_value(t, buffer_open(&b, path), BufferOpenError.None)
	buffer_insert(&b, {0, 0}, "data")

	testing.expect_value(t, buffer_save(&b), BufferSaveError.WriteError)

	testing.expect(t, !os.is_dir(parent))
	testing.expect(t, !os.exists(path))
}
