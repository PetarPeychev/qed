package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

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
image_halve_averages :: proc(t: ^testing.T) {
	src := []u8{0, 0, 0, 255, 100, 100, 100, 255, 200, 200, 200, 255, 100, 100, 100, 255}
	out, w, h := image_halve(src, 2, 2, context.temp_allocator)
	testing.expect_value(t, w, 1)
	testing.expect_value(t, h, 1)
	testing.expect_value(t, out[0], 100)
	testing.expect_value(t, out[3], 255)
}

@(test)
image_transmit_chunks :: proc(t: ^testing.T) {
	img := Image{id = 0x123456, rw = 40, rh = 40, rgba = make([]u8, 40 * 40 * 4, context.temp_allocator)}
	chunks := image_kitty_transmit(&img)
	testing.expect_value(t, len(chunks), 3)
	testing.expect(t, strings.has_prefix(chunks[0], "\x1b_Ga=t,f=32,s=40,v=40,i=1193046,q=2,m=1;"), "first chunk carries the format")
	testing.expect(t, strings.has_prefix(chunks[1], "\x1b_Gm=1;"), "middle chunk continues")
	testing.expect(t, strings.has_prefix(chunks[2], "\x1b_Gm=0;"), "last chunk ends")
	for c in chunks {
		testing.expect(t, strings.has_suffix(c, "\x1b\\"), "chunk terminated")
		testing.expect(t, len(c) <= IMAGE_CHUNK + 64, "chunk within the protocol's size")
	}
	testing.expect_value(t, image_kitty_place(7, 10, 4), "\x1b_Ga=p,U=1,i=7,p=1,c=10,r=4,q=2\x1b\\")
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
	lines := md_render(src, 40, .Plain, dir)
	testing.expect(t, strings.contains(md_all_text(lines), "[image: pic]"), "no protocol: alt text")
	for l in lines {
		testing.expect(t, l.image.id == 0, "no protocol: no image lines")
	}

	IMAGE_PROTOCOL = .Kitty
	lines = md_render(src, 40, .Plain, dir)
	text := md_all_text(lines)
	testing.expect(t, strings.contains(text, "Inline [image: pic] here."), "an image inside text stays alt text")
	testing.expect(t, strings.contains(text, "[image: gone]"), "a missing file stays alt text")
	ids: [dynamic]u32
	defer delete(ids)
	for l in lines {
		if l.image.id != 0 && (len(ids) == 0 || ids[len(ids) - 1] != l.image.id) {
			append(&ids, l.image.id)
		}
	}
	testing.expect_value(t, len(ids), 3)
	if len(ids) == 3 {
		testing.expect(t, ids[0] == ids[2] && ids[0] != ids[1], "the same file shares one image")
	}
	first := -1
	for l, i in lines {
		if l.image.id != 0 {
			first = i
			break
		}
	}
	if first >= 0 {
		l := lines[first]
		testing.expect_value(t, l.image.cols, 2)
		testing.expect_value(t, l.image.rows, 2)
		testing.expect_value(t, len(l.spans), 1)
		testing.expect_value(t, l.spans[0].fg, image_color(l.image.id))
		testing.expect_value(t, l.spans[0].text, image_placeholder_row(0, 2))
		testing.expect_value(t, lines[first + 1].spans[0].text, image_placeholder_row(1, 2))
	}
	quoted := lines[len(lines) - 1]
	testing.expect(t, quoted.image.id != 0 && len(quoted.spans) == 2 && quoted.spans[0].text == "│ ", "a quoted image keeps the quote bar")

	hover := md_render(src, 40, .Plain)
	for l in hover {
		testing.expect(t, l.image.id == 0, "a render without a base dir shows no images")
	}
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
	if len(e.ed.panes) == 0 {
		return true
	}
	top := &e.ed.panes[len(e.ed.panes) - 1]
	if !top.has_md || top.md_job != nil || len(top.md_lines) == 0 {
		pane_stack_pump(&e.ed, true)
		e2e_render(e)
		return true
	}
	return false
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
			testing.expect(t, strings.contains(out, fmt.tprintf("\x1b_Ga=t,f=32,s=2,v=2,i=%d,q=2,m=0;", id)), "the image goes out once")
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

@(test)
e2e_image_file_preview :: proc(t: ^testing.T) {
	e2e_enter()
	defer sync.mutex_unlock(&e2e_lock)
	saved, saved_cell := IMAGE_PROTOCOL, g_image_cell
	defer {
		IMAGE_PROTOCOL, g_image_cell = saved, saved_cell
		image_shutdown()
	}
	dir := image_fixture_dir("preview")
	defer image_fixture_drop(dir)
	g_image_cell = {1, 1}
	p: Preview
	defer preview_destroy(&p)

	IMAGE_PROTOCOL = .None
	preview_set_file(&p, fmt.tprintf("%s/pic.png", dir), 0, 10)
	testing.expect(t, p.image == 0 && p.hex, "no protocol: an image file previews as a hexdump")

	IMAGE_PROTOCOL = .Kitty
	preview_set_file(&p, fmt.tprintf("%s/pic.png", dir), 0, 10)
	testing.expect(t, p.image != 0 && !p.hex, "an image file previews as the image")
	tb2.clear()
	preview_render(&p, 0, 0, 40, 10)
	cell: ^tb2.Cell_Raw
	tb2.get_cell(2, 1, 1, &cell)
	testing.expect_value(t, rune(cell.ch), IMAGE_PLACEHOLDER)
	testing.expect_value(t, u32(u64(cell.fg) & COLOR_RGB_MASK), p.image)
	tb2.get_cell(2, 2, 1, &cell)
	testing.expect(t, rune(cell.ch) != IMAGE_PLACEHOLDER, "a 2x2 image takes two rows")

	preview_set_file(&p, fmt.tprintf("%s/gray.png", dir), 0, 10)
	image_shutdown()
	os.remove(fmt.tprintf("%s/gray.png", dir))
	tb2.clear()
	preview_render(&p, 0, 0, 40, 10)
	sb := strings.builder_make(context.temp_allocator)
	for x in 0 ..< 40 {
		tb2.get_cell(i32(x), 0, 1, &cell)
		strings.write_rune(&sb, rune(cell.ch))
	}
	testing.expect(t, strings.contains(strings.to_string(sb), PREVIEW_IMAGE_FAILED_TEXT), "a preview whose image left the cache and the disk says so")

	_ = os.write_entire_file(fmt.tprintf("%s/fake.png", dir), transmute([]u8)string("\x89PNG\r\n\x1a\nbroken"))
	defer os.remove(fmt.tprintf("%s/fake.png", dir))
	preview_set_file(&p, fmt.tprintf("%s/fake.png", dir), 0, 10)
	testing.expect(t, p.image == 0, "an undecodable image falls back to the plain preview")
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
image_md_refs :: proc(lines: []MdLine) -> []ImageRef {
	out := make([dynamic]ImageRef, context.temp_allocator)
	for l in lines {
		if l.image.id != 0 && (len(out) == 0 || out[len(out) - 1].id != l.image.id) {
			append(&out, l.image)
		}
	}
	return out[:]
}
