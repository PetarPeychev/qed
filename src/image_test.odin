package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"
import "vendor:zlib"

@(private = "file")
TEST_PNG_RGBA8 := [?]u8{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
	0x24, 0x00, 0x00, 0x00, 0x07, 0x74, 0x49, 0x4d, 0x45, 0x07, 0xea, 0x0b, 0x15, 0x17, 0x2e, 0x0e,
	0x9e, 0xca, 0x95, 0x26, 0x00, 0x00, 0x00, 0x17, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x05, 0xc1,
	0x01, 0x01, 0x00, 0x00, 0x00, 0x82, 0x20, 0xa6, 0xf7, 0xdc, 0x40, 0x24, 0xa1, 0xc1, 0x01, 0x3d,
	0x57, 0x05, 0x7c, 0x5a, 0xea, 0x04, 0xde, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
	0x42, 0x60, 0x82,
}

@(private = "file")
TEST_PNG_GRAY16 := [?]u8{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x6e, 0x1b, 0x97,
	0x2b, 0x00, 0x00, 0x00, 0x0f, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0x6c, 0x60, 0x60, 0x60,
	0x60, 0x60, 0x00, 0x00, 0x03, 0x0e, 0x00, 0x82, 0x33, 0x23, 0x7f, 0xd3, 0x00, 0x00, 0x00, 0x00,
	0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
}

@(private = "file")
TEST_JPEG := [?]u8{
	0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xc0,
	0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x08, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11,
	0x01, 0xff, 0xc4, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0xff, 0xc4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xc4, 0x00,
	0x15, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x09, 0x0a, 0xff, 0xc4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01,
	0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00, 0x3e, 0x15, 0xd2, 0xee, 0xff, 0xd9,
}

@(private = "file")
image_fixture_dir :: proc(name: string) -> string {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/qed_image_%s_%d", tmp, name, posix.getpid())
	os.make_directory_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/pic.png", dir), TEST_PNG_RGBA8[:])
	_ = os.write_entire_file(fmt.tprintf("%s/gray.png", dir), TEST_PNG_GRAY16[:])
	_ = os.write_entire_file(fmt.tprintf("%s/photo.jpg", dir), TEST_JPEG[:])
	return dir
}

@(private = "file")
image_fixture_drop :: proc(dir: string) {
	for f in ([]string{"pic.png", "gray.png", "photo.jpg", "README.md"}) {
		os.remove(fmt.tprintf("%s/%s", dir, f))
	}
	os.remove(dir)
}

@(test)
image_reply_parse_kinds :: proc(t: ^testing.T) {
	kind, term := image_reply_parse("\x1b_Gi=31;OK\x1b\\")
	testing.expect_value(t, kind, ImageReply.Kitty_Ok)
	kind, _ = image_reply_parse("\x1b_Gi=31;ENOENT:no such image\x1b\\")
	testing.expect_value(t, kind, ImageReply.Kitty_Error)
	kind, _ = image_reply_parse("\x1b_Gi=7;OK\x1b\\")
	testing.expect_value(t, kind, ImageReply.None)
	kind, _ = image_reply_parse("\x1b[?61;4;6;7;14;21;22;23;24;28;32;42c")
	testing.expect_value(t, kind, ImageReply.Da1)
	kind, term = image_reply_parse("\x1bP>|kitty(0.51.0)\x1b\\")
	testing.expect_value(t, kind, ImageReply.Version)
	testing.expect_value(t, term, "kitty(0.51.0)")
	testing.expect(t, image_term_placeholders(term), "kitty draws placeholders")
	testing.expect(t, image_term_placeholders("ghostty 1.2.0"), "Ghostty draws placeholders")
	testing.expect(t, !image_term_placeholders("WezTerm 20240203-110809-5046fc22"), "WezTerm draws them as text")
}

@(test)
image_query_wraps_for_tmux :: proc(t: ^testing.T) {
	testing.expect_value(t, image_query(false), "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[>0q\x1b[c")
	testing.expect_value(t, image_query(true), "\x1bPtmux;\x1b\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\x1b\\\x1b\\\x1bPtmux;\x1b\x1b[>0q\x1b\\\x1bPtmux;\x1b\x1b[c\x1b\\\x1b[c")
}

@(test)
image_header_sizes :: proc(t: ^testing.T) {
	w, h, ok := image_header_size(TEST_PNG_RGBA8[:])
	testing.expect(t, ok && w == 2 && h == 2, "PNG IHDR")
	w, h, ok = image_header_size(TEST_PNG_GRAY16[:])
	testing.expect(t, ok && w == 3 && h == 1, "16-bit PNG IHDR")
	w, h, ok = image_header_size(TEST_JPEG[:])
	testing.expect(t, ok && w == 8 && h == 8, "JPEG SOF after DQT")
	_, _, ok = image_header_size(TEST_JPEG[:100])
	testing.expect(t, !ok, "a JPEG head without its SOF has no size")
	_, _, ok = image_header_size(transmute([]u8)string("\x89PNG\r\n\x1a\nshort"))
	testing.expect(t, !ok, "a truncated PNG has no size")
}

@(test)
image_cells_fit :: proc(t: ^testing.T) {
	cols, rows := image_cells(80, 64, 100, 24, 8, 16)
	testing.expect_value(t, cols, 10)
	testing.expect_value(t, rows, 4)
	cols, rows = image_cells(800, 400, 50, 24, 8, 16)
	testing.expect_value(t, cols, 50)
	testing.expect_value(t, rows, 13)
	cols, rows = image_cells(100, 1000, 50, 10, 10, 20)
	testing.expect_value(t, rows, 10)
	testing.expect_value(t, cols, 2)
	cols, rows = image_cells(80, 64, 100, 24, 0, 0)
	testing.expect_value(t, cols, 10)
	testing.expect_value(t, rows, 4)
	cols, rows = image_cells(5000, 10, 400, 24, 1, 1)
	testing.expect_value(t, cols, len(IMAGE_DIACRITICS))
	cols, rows = image_cells(0, 10, 40, 24, 8, 16)
	testing.expect_value(t, cols, 0)
}

@(test)
image_placeholder_cells :: proc(t: ^testing.T) {
	for d in IMAGE_DIACRITICS {
		testing.expectf(t, tb2.wcwidth(d) == 0, "diacritic %x is zero width", d)
	}
	row := image_placeholder_row(2, len(IMAGE_DIACRITICS))
	cells := md_clusters(row)
	testing.expect_value(t, len(cells), len(IMAGE_DIACRITICS))
	for c, i in cells {
		runes := utf8.string_to_runes(c, context.temp_allocator)
		testing.expect_value(t, len(runes), 3)
		testing.expect_value(t, runes[0], IMAGE_PLACEHOLDER)
		testing.expect_value(t, runes[1], IMAGE_DIACRITICS[2])
		testing.expect_value(t, runes[2], IMAGE_DIACRITICS[i])
		testing.expect_value(t, cluster_width(transmute([]u8)c), 1)
	}
	testing.expect_value(t, md_text_width(row), len(IMAGE_DIACRITICS))
}

@(test)
image_decode_formats :: proc(t: ^testing.T) {
	rgba, w, h, ok := image_decode(TEST_PNG_RGBA8[:], context.temp_allocator)
	testing.expect(t, ok, "8-bit RGBA PNG decodes")
	testing.expect_value(t, w, 2)
	testing.expect_value(t, h, 2)
	testing.expect_value(t, len(rgba), 16)
	want := []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 128, 0, 0, 0, 0}
	for v, i in want {
		testing.expectf(t, rgba[i] == v, "rgba8 byte %d: %d, want %d", i, rgba[i], v)
	}
	rgba, w, h, ok = image_decode(TEST_PNG_GRAY16[:], context.temp_allocator)
	testing.expect(t, ok, "16-bit gray PNG decodes")
	testing.expect_value(t, w, 3)
	testing.expect_value(t, len(rgba), 12)
	testing.expect_value(t, rgba[0], 0x80)
	testing.expect_value(t, rgba[2], 0x80)
	testing.expect_value(t, rgba[3], 255)
	rgba, w, h, ok = image_decode(TEST_JPEG[:], context.temp_allocator)
	testing.expect(t, ok, "JPEG decodes")
	testing.expect_value(t, w, 8)
	testing.expectf(t, abs(int(rgba[1]) - 200) < 8, "JPEG green %d near 200", rgba[1])
	_, _, _, ok = image_decode(transmute([]u8)string("not an image"), context.temp_allocator)
	testing.expect(t, !ok, "garbage does not decode")
}

@(test)
image_fit_averages :: proc(t: ^testing.T) {
	src := []u8{0, 0, 0, 255, 100, 100, 100, 255, 200, 200, 200, 255, 100, 100, 100, 255}
	out, w, h := image_fit(src, 2, 2, {1, 1}, context.temp_allocator)
	testing.expect_value(t, w, 1)
	testing.expect_value(t, h, 1)
	testing.expect_value(t, out[0], 100)
	testing.expect_value(t, out[3], 255)
	wide := []u8{0, 0, 0, 255, 60, 60, 60, 255, 120, 120, 120, 255, 180, 180, 180, 255}
	out, w, h = image_fit(wide, 4, 1, {3, 3}, context.temp_allocator)
	testing.expect_value(t, w, 3)
	testing.expect_value(t, h, 1)
	testing.expect_value(t, out[0], 0)
	testing.expect_value(t, out[8], 150)
	_, w, h = image_fit(make([]u8, 48 * 32 * 4, context.temp_allocator), 48, 32, {100, 20}, context.temp_allocator)
	testing.expect(t, w == 30 && h == 20, "fits the tighter side, keeps the aspect")
}

@(private = "file")
image_payload_chunks :: proc(payload: []u8) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	rest := string(payload)
	for rest != "" {
		end := strings.index(rest, "\x1b\\")
		if end < 0 {
			append(&out, rest)
			break
		}
		append(&out, rest[:end + 2])
		rest = rest[end + 2:]
	}
	return out[:]
}

@(private = "file")
image_payload_data :: proc(payload: []u8) -> []u8 {
	sb := strings.builder_make(context.temp_allocator)
	for c in image_payload_chunks(payload) {
		strings.write_string(&sb, c[strings.index_byte(c, ';') + 1:len(c) - 2])
	}
	data, _ := base64.decode(strings.to_string(sb), allocator = context.temp_allocator)
	return data
}

@(test)
image_payload_chunks_wrap :: proc(t: ^testing.T) {
	chunks := image_payload_chunks(image_kitty_payload(make([]u8, 40 * 40 * 4, context.temp_allocator), "a=t,f=100,i=7,q=2", false, context.temp_allocator))
	testing.expect_value(t, len(chunks), 3)
	testing.expect(t, strings.has_prefix(chunks[0], "\x1b_Ga=t,f=100,i=7,q=2,m=1;"), "first chunk carries the keys")
	testing.expect(t, strings.has_prefix(chunks[1], "\x1b_Gm=1;"), "middle chunk continues")
	testing.expect(t, strings.has_prefix(chunks[2], "\x1b_Gm=0;"), "last chunk ends")
	for c in chunks {
		testing.expect(t, strings.has_suffix(c, "\x1b\\"), "chunk terminated")
		testing.expect(t, len(c) <= IMAGE_CHUNK + 64, "chunk within the protocol's size")
	}
	wrapped := string(image_kitty_payload(make([]u8, 40 * 40 * 4, context.temp_allocator), "a=t,f=100,i=7,q=2", true, context.temp_allocator))
	want := strings.concatenate({image_tmux_wrap(chunks[0]), image_tmux_wrap(chunks[1]), image_tmux_wrap(chunks[2])}, context.temp_allocator)
	testing.expect_value(t, wrapped, want)
	testing.expect_value(t, image_kitty_place(7, 10, 4), "\x1b_Ga=p,U=1,i=7,p=1,c=10,r=4,q=2\x1b\\")
}

@(test)
image_payload_png_passthrough :: proc(t: ^testing.T) {
	payload, ok := image_payload(TEST_PNG_RGBA8[:], 0x123456, {100, 100}, false, context.temp_allocator)
	testing.expect(t, ok, "a PNG prepares")
	b64, _ := base64.encode(TEST_PNG_RGBA8[:], allocator = context.temp_allocator)
	testing.expect_value(t, string(payload), fmt.tprintf("\x1b_Ga=t,f=100,i=1193046,q=2,m=0;%s\x1b\\", b64))

	payload, ok = image_payload(TEST_SHOT, 9, {48, 32}, false, context.temp_allocator)
	testing.expect(t, ok && strings.has_prefix(string(payload), "\x1b_Ga=t,f=100,i=9,q=2,"), "a PNG exactly its box goes as its file")
	payload, ok = image_payload(TEST_SHOT, 9, {47, 100}, false, context.temp_allocator)
	testing.expect(t, ok, "a PNG over its box prepares")
	testing.expect(t, strings.has_prefix(string(payload), "\x1b_Ga=t,f=32,o=z,s=47,v=31,i=9,q=2,"), "a PNG a pixel over its box is decoded and scaled to fit")
}

@(test)
image_payload_jpeg_deflated :: proc(t: ^testing.T) {
	payload, ok := image_payload(TEST_JPEG[:], 5, {100, 100}, false, context.temp_allocator)
	testing.expect(t, ok, "a JPEG prepares")
	testing.expect(t, strings.has_prefix(string(payload), "\x1b_Ga=t,f=32,o=z,s=8,v=8,i=5,q=2,m=0;"), "decoded RGBA goes deflated")
	packed := image_payload_data(payload)
	rgba, _, _, _ := image_decode(TEST_JPEG[:], context.temp_allocator)
	out := make([]u8, len(rgba) + 16, context.temp_allocator)
	size := zlib.uLongf(len(out))
	testing.expect_value(t, zlib.uncompress(raw_data(out), &size, raw_data(packed), zlib.uLong(len(packed))), zlib.OK)
	testing.expect_value(t, int(size), len(rgba))
	testing.expect(t, string(out[:size]) == string(rgba), "inflates to the decoded pixels")
	_, ok = image_payload(transmute([]u8)string("not an image"), 5, {100, 100}, false, context.temp_allocator)
	testing.expect(t, !ok, "garbage fails")
}

@(test)
image_box_rows :: proc(t: ^testing.T) {
	testing.expect_value(t, image_box_row(0, 12, 3, "Welcome"), "┌──────────┐")
	testing.expect_value(t, image_box_row(1, 12, 3, "Welcome"), "│⋯ Welcome │")
	testing.expect_value(t, image_box_row(2, 12, 3, "Welcome"), "└──────────┘")
	testing.expect_value(t, image_box_row(1, 8, 4, "Welcome screen"), "│⋯ Wel…│")
	testing.expect_value(t, image_box_row(2, 8, 4, "Welcome screen"), "│      │")
	testing.expect_value(t, image_box_row(1, 6, 3, ""), "│    │")
	testing.expect_value(t, image_box_row(0, 9, 1, "pic"), "  ⋯ pic  ")
	testing.expect_value(t, image_box_row(1, 9, 2, "pic"), "         ")
}

@(test)
image_markdown_blocks :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	saved, saved_cell := IMAGE_PROTOCOL, g_image_cell
	defer {
		IMAGE_PROTOCOL, g_image_cell = saved, saved_cell
		image_shutdown()
	}
	dir := image_fixture_dir("md")
	defer image_fixture_drop(dir)
	g_image_cell = {1, 1}
	src := "# T\n\n![pic](pic.png)\n\nInline ![pic](pic.png) here.\n\n![gone](missing.png)\n\n<p align=\"center\"><img src=\"photo.jpg\" alt=\"p\"></p>\n\n> [![pic](pic.png)](https://x.y)"

	IMAGE_PROTOCOL = .None
	doc := md_render(src, 40, .Plain, dir)
	testing.expect(t, strings.contains(md_doc_text(doc), "[image: pic]"), "no protocol: alt text")
	testing.expect_value(t, len(doc.images), 0)

	IMAGE_PROTOCOL = .Kitty
	doc = md_render(src, 40, .Plain, dir)
	testing.expect(t, strings.contains(md_doc_text(doc), "[image: gone]"), "a missing file stays alt text")
	testing.expect_value(t, len(doc.images), 4)
	if len(doc.images) == 4 {
		testing.expect(t, doc.images[0].ref.id == doc.images[1].ref.id && doc.images[0].ref.id != doc.images[2].ref.id, "the same file shares one image")
		first := doc.images[0]
		testing.expect_value(t, first.ref.cols, 2)
		testing.expect_value(t, first.ref.rows, 2)
		testing.expect_value(t, first.x, 0)
		testing.expect(t, doc.images[3].x >= 2 && strings.has_prefix(md_row_text(doc, doc.images[3].y), "│"), "a quoted image keeps the quote bar")
	}

	hover := md_render(src, 40, .Plain)
	testing.expect_value(t, len(hover.images), 0)
}

@(test)
image_markdown_mixed_blocks :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
	saved, saved_cell := IMAGE_PROTOCOL, g_image_cell
	defer {
		IMAGE_PROTOCOL, g_image_cell = saved, saved_cell
		image_shutdown()
	}
	dir := image_fixture_dir("mixed")
	defer image_fixture_drop(dir)
	g_image_cell = {1, 1}
	src := "Before ![pic](pic.png) after `![x](pic.png)` end\n\n<table><tr>\n<td><img src=\"pic.png\"><br><em>One</em></td>\n<td><img src=\"gray.png\"><br><em>Two</em></td>\n</tr></table>\n\n<p><img src=\"missing.png\" alt=\"gone\"> lost <img src=\"pic.png\"></p>\n\n<p align=\"center\">\n  <img src=\"gray.png\"\n       width=\"200\">\n</p>"

	IMAGE_PROTOCOL = .Kitty
	doc := md_render(src, 40, .Plain, dir)
	text := md_doc_text(doc)
	testing.expect_value(t, len(doc.images), 5)
	testing.expect(t, strings.contains(text, "after ![x](pic.png) end"), "an image in code stays text")
	testing.expect(t, strings.contains(text, "[image: gone] lost"), "a missing image keeps its alt text in the paragraph")
	testing.expect(t, strings.contains(text, "One") && strings.contains(text, "Two"), "captions under table images")
	if len(doc.images) == 5 {
		testing.expectf(t, doc.images[4].ref.cols == 25, "an <img width> is honoured as CSS pixels, 8 per column: %d", doc.images[4].ref.cols)
	}

	IMAGE_PROTOCOL = .None
	off := md_render(src, 40, .Plain, dir)
	off_text := md_doc_text(off)
	testing.expect_value(t, len(off.images), 0)
	testing.expect(t, strings.contains(off_text, "Before [image: pic] after"), "no protocol: alt text inline")
	testing.expect_value(t, strings.count(off_text, "[image]"), 4)
}

@(private = "file")
image_feed :: proc(s: string) {
	posix.write(posix.FD(e2e_master), raw_data(s), len(s))
}

@(private = "file")
image_next :: proc(ms: i32 = 500) -> (tb2.Event, string) {
	ev: tb2.Event
	if tb2.peek_event(&ev, ms) != .Ok {
		return {}, ""
	}
	buf: [^]u8
	n := tb2.reply(&buf)
	return ev, strings.clone(string(buf[:n]), context.temp_allocator)
}

@(test)
e2e_image_replies :: proc(t: ^testing.T) {
	e2e_enter()
	defer sync.mutex_unlock(&e2e_lock)
	for want in ([]string{"\x1b[?61;4;42c", "\x1b_Gi=31;OK\x1b\\", "\x1bP>|kitty(0.51.0)\x1b\\"}) {
		image_feed(want)
		ev, bytes := image_next()
		testing.expect_value(t, ev.type, tb2.Event_Kind.Reply)
		testing.expect_value(t, bytes, want)
	}
	image_feed("x")
	ev, _ := image_next()
	testing.expect(t, ev.type == .Key && ev.ch == 'x', "input after a reply still parses")

	image_feed("\x1b_G")
	chars: [dynamic]rune
	defer delete(chars)
	for {
		ev, _ = image_next(100)
		if ev.type == {} {
			break
		}
		testing.expect(t, ev.type == .Key, "a typed Alt+_ G is keys")
		append(&chars, ev.ch)
	}
	testing.expect(t, len(chars) >= 2 && chars[len(chars) - 2] == '_' && chars[len(chars) - 1] == 'G', "the typed keys arrive without waiting for more input")
}

@(test)
e2e_image_late_reply :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	testing.expect(t, !g_image_detect.pending, "detection is over")
	image_feed("a\x1b_Gi=31;OK\x1b\\\x1bP>|kitty(0.35)\x1b\\hello")
	for {
		ev, _ := image_next(100)
		if ev.type == {} {
			break
		}
		e2e_step(&e, ev)
	}
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "ahello")
}

@(private = "file")
image_md_pending :: proc(e: ^E2E) -> bool {
	e2e_render(e)
	node := ui_find(&e.ed.ui, "#markdown/markdown_body")
	if node == nil {
		return true
	}
	md, found := e.ed.ui.markdowns[node.identity]
	return !found || md.job != nil || md.doc == nil || len(md.doc.rows) == 0
}

@(test)
e2e_image_preview :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved, saved_cell, saved_tmux := IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux
	defer {
		IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = saved, saved_cell, saved_tmux
		image_shutdown()
	}
	IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = .Kitty, {1, 1}, false
	dir := image_fixture_dir("e2e")
	defer image_fixture_drop(dir)
	md := fmt.tprintf("%s/README.md", dir)
	_ = os.write_entire_file(md, transmute([]u8)string("# Pics\n\n![pic](pic.png)\n\nafter\n"))
	testing.expect(t, editor_open_path(&e.ed, md), "opens the doc")
	sync.mutex_lock(&e2e_tap_lock)
	e2e_tapping = true
	clear(&e2e_tap)
	sync.mutex_unlock(&e2e_tap_lock)
	defer {
		sync.mutex_lock(&e2e_tap_lock)
		e2e_tapping = false
		clear(&e2e_tap)
		sync.mutex_unlock(&e2e_tap_lock)
	}
	e2e_tap_sync()
	e2e_key(&e, tb2.Key(0), .Alt, 'p')
	testing.expect(t, e2e_pump_while(&e, image_md_pending), "the preview renders")
	e2e_render(&e)
	testing.expect(t, e2e_pump_while(&e, proc(e: ^E2E) -> bool {
		image_pump(&e.ed)
		return image_busy()
	}), "the image decodes once drawn")
	e2e_render(&e)
	tb2.present()
	out := string(e2e_tap_sync())

	found := false
	for y in 0 ..< E2E_H {
		for x in 0 ..< E2E_W {
			cell := e2e_cell_raw(&e, x, y)
			if rune(cell.ch) != IMAGE_PLACEHOLDER || found {
				continue
			}
			found = true
			testing.expect_value(t, cell.nech, 3)
			ech := cast([^]rune)cell.ech
			testing.expect_value(t, ech[1], IMAGE_DIACRITICS[0])
			testing.expect_value(t, ech[2], IMAGE_DIACRITICS[0])
			right := e2e_cell_raw(&e, x + 1, y)
			below := e2e_cell_raw(&e, x, y + 1)
			testing.expect(t, right.nech == 3 && below.nech == 3, "the image spans 2x2 cells")
			if right.nech == 3 && below.nech == 3 {
				testing.expect_value(t, (cast([^]rune)right.ech)[2], IMAGE_DIACRITICS[1])
				testing.expect_value(t, (cast([^]rune)below.ech)[1], IMAGE_DIACRITICS[1])
			}
			id := u32(e2e_rgb(cell.fg))
			testing.expect(t, strings.contains(out, fmt.tprintf("\x1b_Ga=t,f=100,i=%d,q=2,m=0;", id)), "the PNG goes out once, as its file")
			testing.expect(t, strings.contains(out, fmt.tprintf("\x1b_Ga=p,U=1,i=%d,p=1,c=2,r=2,q=2\x1b\\", id)), "with a virtual placement of its cell size")
			testing.expect(t, strings.contains(out, "\U0010EEEE"), "the placeholder cells reach the terminal")
		}
	}
	testing.expect(t, found, "the preview shows placeholder cells")
	testing.expect(t, e2e_grid_has_words(&e, "after"), "text below the image renders")

	e2e_render(&e)
	tb2.present()
	again := string(e2e_tap_sync())
	testing.expect(t, !strings.contains(again, "\x1b_G"), "a redraw sends nothing new")
}

@(private = "file")
image_pump_idle :: proc(editor: ^Editor) {
	for _ in 0 ..< 5000 {
		image_pump(editor)
		if !image_busy() {
			return
		}
		time.sleep(time.Millisecond)
	}
}

@(test)
e2e_image_doc_many_images :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved, saved_cell := IMAGE_PROTOCOL, g_image_cell
	defer {
		IMAGE_PROTOCOL, g_image_cell = saved, saved_cell
		image_shutdown()
	}
	IMAGE_PROTOCOL, g_image_cell = .Kitty, {1, 1}
	dir := image_fixture_dir("many")
	defer image_fixture_drop(dir)
	N :: 20
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< N {
		_ = os.write_entire_file(fmt.tprintf("%s/m%d.png", dir, i), TEST_PNG_RGBA8[:])
		fmt.sbprintf(&sb, "![m%d](m%d.png)\n\n", i, i)
	}
	defer for i in 0 ..< N {
		os.remove(fmt.tprintf("%s/m%d.png", dir, i))
	}
	refs := image_md_refs(md_render(strings.to_string(sb), 40, .Plain, dir))
	testing.expect_value(t, len(refs), N)

	show :: proc(e: ^E2E, refs: []ImageRef) {
		image_frame_begin()
		for r in refs {
			image_show(r)
		}
		image_pump_idle(&e.ed)
	}
	show(&e, refs[:])
	for r in refs {
		state, known := image_state(r.id)
		testing.expect(t, known && state == .Ready, "every image shown in one frame stays, even past the cap")
	}
	show(&e, refs[N - 3:])
	heavy := 0
	for img in g_images {
		heavy += 1 if image_heavy(img) else 0
	}
	testing.expect(t, heavy <= IMAGE_CACHE_MAX, "images off screen give back their pixels and terminal copies")
	for r in refs[N - 3:] {
		state, _ := image_state(r.id)
		testing.expect(t, state == .Ready, "the visible ones stay loaded")
	}
	for r in refs {
		_, known := image_state(r.id)
		testing.expect(t, known, "no id a render emitted goes stale")
	}
	again := image_md_refs(md_render(strings.to_string(sb), 40, .Plain, dir))
	for r, i in again {
		testing.expect(t, r.id == refs[i].id, "a re-render keeps the ids")
	}
	show(&e, refs[:1])
	state, _ := image_state(refs[0].id)
	testing.expect(t, state == .Ready, "an unloaded image reloads when shown again")
}

@(private = "file")
image_md_refs :: proc(doc: ^MdDoc) -> []ImageRef {
	out := make([dynamic]ImageRef, context.temp_allocator)
	for img in doc.images {
		append(&out, img.ref)
	}
	return out[:]
}

@(test)
e2e_ui_image_node :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved, saved_cell, saved_tmux := IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux
	defer {
		IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = saved, saved_cell, saved_tmux
		image_shutdown()
	}
	dir := image_fixture_dir("node")
	defer image_fixture_drop(dir)
	IMAGE_PROTOCOL = .None
	e2e_plugin(&e, "uitest", fmt.tprintf(`return {{setup = function()
	qed.command{{id = "run", name = "Run", run = function()
		qed.ui.mount("pane", qed.ui.image{{float = "screen", anchor = "top_left", width = 20, height = 6, path = %q}})
	end}}
end}}`, fmt.tprintf("%s/pic.png", dir)))
	ut_run(&e, "Run")
	testing.expect(t, strings.has_prefix(e2e_row_text(&e, 0), "[image: pic.png]"), "without graphics the node shows its alt text")
	IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = .Kitty, {1, 1}, false
	for _ in 0 ..< 50 {
		image_pump(&e.ed)
		e2e_render(&e)
		if e2e_cell(&e, 0, 0) == IMAGE_PLACEHOLDER {
			break
		}
		time.sleep(time.Millisecond * 10)
	}
	testing.expect_value(t, e2e_cell(&e, 0, 0), IMAGE_PLACEHOLDER)
}

@(private = "file")
TEST_SHOT := #load("../tools/e2e/assets/shot-a.png")

@(private = "file")
image_find_row :: proc(e: ^E2E, text: string) -> int {
	for y in 0 ..< E2E_H {
		if strings.contains(e2e_row_text(e, y), text) {
			return y
		}
	}
	return -1
}

@(test)
e2e_image_loading_box :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved, saved_cell, saved_tmux := IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux
	defer {
		IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = saved, saved_cell, saved_tmux
		image_shutdown()
	}
	IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = .Kitty, {4, 8}, false
	dir := image_fixture_dir("box")
	defer image_fixture_drop(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/pic.png", dir), TEST_SHOT)
	md := fmt.tprintf("%s/README.md", dir)
	_ = os.write_entire_file(md, transmute([]u8)string("# Pics\n\n![Welcome screen](pic.png)\n\nafter\n"))
	testing.expect(t, editor_open_path(&e.ed, md), "opens the doc")
	e2e_key(&e, tb2.Key(0), .Alt, 'p')
	testing.expect(t, e2e_pump_while(&e, image_md_pending), "the preview renders")
	e2e_render(&e)
	top := image_find_row(&e, "┌──────────┐")
	testing.expect(t, top >= 0, "a box holds the image's 12x4 cells while it loads")
	if top < 0 {
		return
	}
	x := 0
	for e2e_cell(&e, x, top) != '┌' {
		x += 1
	}
	testing.expect(t, strings.contains(e2e_row_text(&e, top + 1), "│⋯ Welcome…│"), "the alt text centered, cut to fit")
	testing.expect(t, strings.contains(e2e_row_text(&e, top + 3), "└──────────┘"), "the box spans the image's rows")
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, x, top)), e2e_rgb(md_style().dim))
	testing.expect_value(t, image_find_row(&e, "│ after"), top + 5)

	image_pump_idle(&e.ed)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, x, top), IMAGE_PLACEHOLDER)
	testing.expect_value(t, e2e_cell(&e, x + 11, top + 3), IMAGE_PLACEHOLDER)
	testing.expect(t, image_find_row(&e, "┌──────────┐") < 0, "the box goes once the terminal has the image")
	testing.expect_value(t, image_find_row(&e, "│ after"), top + 5)
}

@(test)
e2e_image_offscreen_stays_probed :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved, saved_cell, saved_tmux := IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux
	defer {
		IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = saved, saved_cell, saved_tmux
		image_shutdown()
	}
	IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = .Kitty, {4, 8}, false
	dir := image_fixture_dir("offscreen")
	defer image_fixture_drop(dir)
	N :: 4
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# Pics\n\n")
	for i in 0 ..< N {
		_ = os.write_entire_file(fmt.tprintf("%s/s%d.png", dir, i), TEST_SHOT)
		fmt.sbprintf(&sb, "![s%d](s%d.png)\n\n", i, i)
		for k in 0 ..< 30 {
			fmt.sbprintf(&sb, "line %d.%d\n\n", i, k)
		}
	}
	defer for i in 0 ..< N {
		os.remove(fmt.tprintf("%s/s%d.png", dir, i))
	}
	md := fmt.tprintf("%s/README.md", dir)
	_ = os.write_entire_file(md, transmute([]u8)strings.to_string(sb))
	testing.expect(t, editor_open_path(&e.ed, md), "opens the doc")
	e2e_key(&e, tb2.Key(0), .Alt, 'p')
	testing.expect(t, e2e_pump_while(&e, image_md_pending), "the preview renders")
	e2e_render(&e)
	image_pump_idle(&e.ed)
	e2e_render(&e)
	state :: proc(name: string) -> ImageState {
		for img in g_images {
			if filepath.base(img.path) == name {
				return img.state
			}
		}
		return .Failed
	}
	testing.expect_value(t, state("s0.png"), ImageState.Ready)
	for i in 1 ..< N {
		testing.expectf(t, state(fmt.tprintf("s%d.png", i)) == .Probed, "s%d.png below the screen is not loaded", i)
	}
	ui_markdown_scroller(&e.ed, ui_find(&e.ed.ui, "#markdown/markdown_body")).offset = 64
	e2e_render(&e)
	testing.expect(t, image_find_row(&e, "⋯ s1") >= 0, "scrolled to s1, loading")
	image_pump_idle(&e.ed)
	testing.expect_value(t, state("s1.png"), ImageState.Ready)
	testing.expect_value(t, state("s2.png"), ImageState.Probed)
}

@(test)
image_payload_truncated_png_fails :: proc(t: ^testing.T) {
	testing.expect(t, image_png_whole(TEST_SHOT), "a whole PNG reaches IEND")
	_, ok := image_payload(TEST_SHOT[:len(TEST_SHOT) - 20], 3, {1000, 1000}, false, context.temp_allocator)
	testing.expect(t, !ok, "a PNG cut before IEND fails instead of going out")
	_, ok = image_payload(TEST_PNG_RGBA8[:40], 3, {1000, 1000}, false, context.temp_allocator)
	testing.expect(t, !ok, "a PNG with only its header fails")
}

@(test)
e2e_image_stale_entry_rerenders :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved, saved_cell, saved_tmux := IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux
	defer {
		IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = saved, saved_cell, saved_tmux
		image_shutdown()
	}
	IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = .Kitty, {4, 8}, false
	dir := image_fixture_dir("stale")
	defer image_fixture_drop(dir)
	pic := fmt.tprintf("%s/pic.png", dir)
	_ = os.write_entire_file(pic, TEST_SHOT)
	md := fmt.tprintf("%s/README.md", dir)
	_ = os.write_entire_file(md, transmute([]u8)string("# Pics\n\n![Shot](pic.png)\n\nafter\n"))
	testing.expect(t, editor_open_path(&e.ed, md), "opens the doc")
	e2e_key(&e, tb2.Key(0), .Alt, 'p')
	testing.expect(t, e2e_pump_while(&e, image_md_pending), "the preview renders")
	e2e_render(&e)
	image_pump_idle(&e.ed)
	e2e_render(&e)
	testing.expect(t, image_find_row(&e, "⋯ Shot") < 0, "loaded")

	image_shutdown()
	for _ in 0 ..< 3 {
		e2e_render(&e)
	}
	testing.expect(t, e2e_pump_while(&e, image_md_pending), "a dropped entry renders the doc again")
	e2e_render(&e)
	image_pump_idle(&e.ed)
	e2e_render(&e)
	testing.expect(t, image_find_row(&e, "⋯ Shot") < 0, "the path re-resolves under a new entry and loads, no box left")
	testing.expect(t, len(g_images) == 1 && g_images[0].state == .Ready, "one fresh entry")

	_ = os.write_entire_file(pic, transmute([]u8)string("no longer an image"))
	image_frame_begin()
	testing.expect(t, image_get(pic) == nil, "another view of the path reprobes it to a failure")
	for _ in 0 ..< 3 {
		e2e_render(&e)
		e2e_pump_while(&e, image_md_pending)
	}
	e2e_render(&e)
	testing.expect(t, image_find_row(&e, "⋯ Shot") < 0, "an entry reprobed to a failure leaves no box")
	testing.expect(t, image_find_row(&e, "[image: Shot]") >= 0, "its alt text shows")
}

@(test)
e2e_image_truncated_shows_alt_once :: proc(t: ^testing.T) {
	e := e2e_start()
	defer e2e_stop(&e)
	saved, saved_cell, saved_tmux := IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux
	defer {
		IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = saved, saved_cell, saved_tmux
		image_shutdown()
	}
	IMAGE_PROTOCOL, g_image_cell, g_image_detect.tmux = .Kitty, {4, 8}, false
	dir := image_fixture_dir("truncated")
	defer image_fixture_drop(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/cut.png", dir), TEST_SHOT[:len(TEST_SHOT) - 20])
	md := fmt.tprintf("%s/README.md", dir)
	_ = os.write_entire_file(md, transmute([]u8)string("# Pics\n\n![Cut shot](cut.png)\n\nafter\n"))
	testing.expect(t, editor_open_path(&e.ed, md), "opens the doc")
	e2e_key(&e, tb2.Key(0), .Alt, 'p')
	testing.expect(t, e2e_pump_while(&e, image_md_pending), "the preview renders")
	e2e_render(&e)
	image_pump_idle(&e.ed)
	for _ in 0 ..< 5 {
		e2e_render(&e)
		image_pump_idle(&e.ed)
	}
	testing.expect(t, image_find_row(&e, "[image: Cut shot]") >= 0, "a file the header check passes but the decode fails shows its alt text")
	body := ui_find(&e.ed.ui, "#markdown/markdown_body")
	preview := e.ed.ui.markdowns[body.identity] if body != nil else nil
	gen := preview.gen if preview != nil else 0
	for _ in 0 ..< 5 {
		e2e_render(&e)
	}
	testing.expect(t, preview != nil && preview.gen == gen && preview.job == nil, "and renders no more")
}
