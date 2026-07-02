package main

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_picker_file_modified_matches :: proc(t: ^testing.T) {
	root, _ := os.get_working_directory(context.temp_allocator)
	rel := "src/editor.odin"

	full, _ := filepath.join({root, rel}, context.temp_allocator)
	abs, err := filepath.abs(full, context.temp_allocator)
	testing.expectf(t, err == nil, "abs failed: %v", err)

	editor: Editor
	editor.buffers = make([dynamic]Buffer, 0, 1, context.temp_allocator)
	append(&editor.buffers, Buffer{path = abs, modified = true})
	editor.working_root = root

	testing.expect(t, picker_file_modified(&editor, rel), "expected rel to match the modified buffer")

	editor.buffers[0].modified = false
	testing.expect(t, !picker_file_modified(&editor, rel), "unmodified buffer should not be marked")
}

@(test)
test_picker_open_then_mark :: proc(t: ^testing.T) {
	root, _ := os.get_working_directory(context.temp_allocator)
	rel := "src/editor.odin"
	full, _ := filepath.join({root, rel}, context.temp_allocator)

	editor: Editor
	editor.buffers = make([dynamic]Buffer, 0, 2, context.temp_allocator)
	append(&editor.buffers, buffer_new())
	editor.working_root = root

	editor_open_path(&editor, full)

	stored := editor_buffer(&editor).path
	testing.expectf(t, stored == full, "stored path %q should equal opened path %q", stored, full)

	editor_buffer(&editor).modified = true
	testing.expect(t, picker_file_modified(&editor, rel), "reopened file should be marked modified")

	for &b in editor.buffers {
		buffer_destroy(&b)
	}
	delete(editor.buffers)
}
