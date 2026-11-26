package cmark_gfm

import "core:c"

foreign import lib "libcmarkgfm.a"

Code_Proc :: proc "c" (user: rawptr, info, code: cstring, first_line: c.int) -> cstring

@(default_calling_convention = "c", link_prefix = "qmd_")
foreign lib {
	init :: proc() ---
	to_html :: proc(md: [^]u8, len: c.size_t, sourcepos: c.int, nonce: u64, code: Code_Proc, user: rawptr) -> cstring ---
	free :: proc(p: cstring) ---
}
