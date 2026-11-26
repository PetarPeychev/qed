package litehtml

import "core:c"

// one block: split imports reorder the archives and the C++ runtime resolves before litehtml needs it
when ODIN_OS == .Darwin {
	foreign import lib {"liblitehtml.a", "system:c++"}
} else when #config(QED_STATIC_CXX, false) {
	foreign import lib {"liblitehtml.a", "libstdcxx.a", "system:m"}
} else {
	foreign import lib {"liblitehtml.a", "system:stdc++", "system:m"}
}

BOLD :: 1
ITALIC :: 2
MONO :: 4
UNDERLINE :: 8
STRIKE :: 16

Rect :: struct {
	x, y, w, h: f32,
}

Border :: struct {
	width: f32,
	style: c.int,
	color: u32,
}

Callbacks :: struct {
	user:       rawptr,
	text_width: proc "c" (user: rawptr, text: cstring, font: c.int) -> f32,
	draw_text:  proc "c" (user: rawptr, text: cstring, font: c.int, color: u32, pos: Rect),
	fill:       proc "c" (user: rawptr, color: u32, box: Rect, clip: Rect),
	borders:    proc "c" (user: rawptr, sides: [^]Border, box: Rect),
	marker:     proc "c" (user: rawptr, type: c.int, index: c.int, color: u32, font: c.int, pos: Rect),
	image_size: proc "c" (user: rawptr, src: cstring, w, h: ^c.int),
	draw_image: proc "c" (user: rawptr, src: cstring, box: Rect),
	set_clip:   proc "c" (user: rawptr, box: Rect),
	del_clip:   proc "c" (user: rawptr),
}

Walk_Proc :: proc "c" (user: rawptr, tag, href, sourcepos, alt, id: cstring, box: Rect)

Doc :: struct {}

@(default_calling_convention = "c", link_prefix = "qlh_")
foreign lib {
	create :: proc(html, master_css, user_css: cstring, cb: ^Callbacks, cell_w, cell_h: c.int) -> ^Doc ---
	render :: proc(doc: ^Doc, width: f32) -> f32 ---
	height :: proc(doc: ^Doc) -> f32 ---
	draw :: proc(doc: ^Doc, clip: Rect) ---
	walk :: proc(doc: ^Doc, walk_proc: Walk_Proc, user: rawptr) ---
	destroy :: proc(doc: ^Doc) ---
}
