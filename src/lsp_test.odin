package main

import "core:strings"
import "core:testing"

// The incremental didChange stream must let a server reconstruct the document
// exactly: applying each recorded LSP range replacement (UTF-16 columns) to the
// base text has to reproduce the live buffer, including multi-byte and astral
// characters where byte offsets and UTF-16 columns diverge.
@(test)
test_lsp_incremental_sync :: proc(t: ^testing.T) {
	b := buffer_new()
	defer buffer_destroy(&b)
	b.lsp_open = true

	buffer_insert(&b, Cursor{0, 0}, "int main() {\n\treturn 0;\n}\n")
	base := buffer_snapshot(&b)
	defer delete(base)
	buffer_lsp_changes_clear(&b) // server's view is now `base`; track from here

	buffer_insert(&b, Cursor{0, 0}, "// π header\n") // 2-byte rune, 1 UTF-16 unit
	buffer_insert(&b, Cursor{3, 1}, "unsigned ") // mid-line insert
	astral := buffer_insert(&b, Cursor{0, 0}, "😀ok\n") // 4-byte rune, 2 UTF-16 units
	_ = astral
	buffer_insert(&b, Cursor{0, len("😀ok")}, "!") // insert past the astral char
	del := buffer_delete(&b, Cursor{4, 0}, Cursor{4, 1}) // delete a tab
	delete(del)
	multi := buffer_delete(&b, Cursor{1, 0}, Cursor{2, 0}) // delete across a line break
	delete(multi)

	doc := strings.clone(base)
	for ch in b.lsp_changes {
		next := lsp_apply_change(doc, ch)
		delete(doc)
		doc = next
	}
	defer delete(doc)

	snap := buffer_snapshot(&b)
	defer delete(snap)
	testing.expectf(t, doc == snap, "reconstructed\n%q\n!= snapshot\n%q", doc, snap)
}

@(private = "file")
lsp_apply_change :: proc(doc: string, ch: LspChange) -> string {
	start := lsp_byte_offset(doc, ch.start_line, ch.start_char)
	end := lsp_byte_offset(doc, ch.end_line, ch.end_char)
	return strings.concatenate({doc[:start], ch.text, doc[end:]})
}

@(private = "file")
lsp_byte_offset :: proc(doc: string, line, char16: int) -> int {
	off := 0
	for _ in 0 ..< line {
		nl := strings.index_byte(doc[off:], '\n')
		off += nl + 1
	}
	rest := doc[off:]
	if nl := strings.index_byte(rest, '\n'); nl >= 0 {
		rest = rest[:nl]
	}
	return off + col_from_utf16(transmute([]u8)rest, char16)
}
