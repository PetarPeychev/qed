package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
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
test_preview_set_file_caps_bytes :: proc(t: ^testing.T) {
	content := make([]u8, PREVIEW_MAX_BYTES + 200 * 1024, context.temp_allocator)
	for &b in content {
		b = 'a'
	}
	path := preview_test_file("big.txt", content)
	defer {os.remove(path);delete(path)}
	p: Preview
	defer preview_destroy(&p)
	preview_set_file(&p, path, 0, 20)
	total := 0
	for line in p.src {
		total += len(line)
	}
	testing.expect(t, total > 0)
	testing.expect(t, total <= PREVIEW_MAX_BYTES)
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

@(test)
test_preview_set_file_crlf_whole :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< PREVIEW_MAX_LINES + 50 {
		fmt.sbprintf(&sb, "line %d\r\n", i)
	}
	path := preview_test_file("crlf.txt", transmute([]u8)strings.to_string(sb))
	defer {os.remove(path);delete(path)}
	p: Preview
	defer preview_destroy(&p)
	preview_set_file(&p, path, 0, 20)
	testing.expect_value(t, len(p.src), PREVIEW_MAX_LINES)
	testing.expect_value(t, len(p.rows), PREVIEW_MAX_LINES)
	testing.expect_value(t, p.src[0], "line 0")
	testing.expect_value(t, p.src[PREVIEW_MAX_LINES - 1], fmt.tprintf("line %d", PREVIEW_MAX_LINES - 1))
	testing.expect_value(t, p.rows[PREVIEW_MAX_LINES - 1].lineno, PREVIEW_MAX_LINES)
}

@(test)
test_preview_max_scroll_cache :: proc(t: ^testing.T) {
	p: Preview
	defer preview_destroy(&p)
	p.no_highlight = true
	for i in 0 ..< 50 {
		append(&p.src, strings.clone(strings.repeat("word ", i % 7, context.temp_allocator)))
	}
	preview_content_build(&p)
	for w in ([]int{0, 12, 30}) {
		p.width = w
		for h in ([]int{5, 10, 60}) {
			testing.expect_value(t, preview_max_scroll(&p, h), preview_max_scroll_compute(&p, len(p.src), h))
			testing.expect_value(t, preview_max_scroll(&p, h), preview_max_scroll_compute(&p, len(p.src), h))
		}
	}
	p.width = 30
	before := preview_max_scroll(&p, 10)
	for s in p.src[40:] {
		delete(s)
	}
	resize(&p.src, 40)
	preview_content_build(&p)
	testing.expect(t, preview_max_scroll(&p, 10) != before)
	testing.expect_value(t, preview_max_scroll(&p, 10), preview_max_scroll_compute(&p, 40, 10))
}

preview_test_c_file :: proc(name: string, pad: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< PREVIEW_MAX_LINES {
		fmt.sbprintf(&sb, "/* %s */ int v%d = %d;\n", strings.repeat("c", pad, context.temp_allocator), i, i)
	}
	return preview_test_file(name, transmute([]u8)strings.to_string(sb))
}

preview_bench_scroll :: proc(p: ^Preview, view_h: int) -> (ms: f64, ticks: int) {
	start := time.tick_now()
	for p.scroll < preview_max_scroll(p, view_h) {
		preview_scroll_by(p, WHEEL_SCROLL_LINES, view_h)
		ticks += 1
	}
	for p.scroll > 0 {
		preview_scroll_by(p, -WHEEL_SCROLL_LINES, view_h)
		ticks += 1
	}
	return time.duration_milliseconds(time.tick_since(start)), ticks
}

preview_highlight :: proc(t: ^testing.T) {
	VIEW_H :: 40
	small := preview_test_c_file("small.c", 4)
	defer {os.remove(small);delete(small)}
	big := preview_test_c_file("big.c", 90)
	defer {os.remove(big);delete(big)}

	p: Preview
	defer preview_destroy(&p)

	preview_set_file(&p, small, 0, VIEW_H)
	p.width = 100
	testing.expect_value(t, len(p.rows), PREVIEW_MAX_LINES)
	testing.expect_value(t, p.hl_hi, PREVIEW_MAX_LINES)
	first_text := raw_data(p.rows[0].text)
	last_colors := raw_data(p.rows[PREVIEW_MAX_LINES - 1].colors)
	testing.expect(t, last_colors != nil)
	ms, ticks := preview_bench_scroll(&p, VIEW_H)
	testing.expect(t, raw_data(p.rows[0].text) == first_text, "scrolling a small file never re-clones rows")
	testing.expect(t, raw_data(p.rows[PREVIEW_MAX_LINES - 1].colors) == last_colors, "scrolling a small file never re-highlights")
	fmt.printfln("preview scroll small: %d ticks, %.3f ms/tick", ticks, ms / f64(max(1, ticks)))

	preview_set_file(&p, big, 0, VIEW_H)
	p.width = 100
	testing.expect(t, p.hl_hi < PREVIEW_MAX_LINES, "a big file colors only the window")
	testing.expect_value(t, p.rows[5].colors[0], COLOR_SYN_COMMENT)
	first_text = raw_data(p.rows[0].text)
	preview_scroll_by(&p, PREVIEW_MAX_LINES, VIEW_H)
	last := len(p.rows) - 1
	testing.expect(t, len(p.rows[last].colors) > 0 && p.rows[last].colors[0] == COLOR_SYN_COMMENT, "scrolled-to tail is colored")
	testing.expect(t, p.rows[5].colors == nil, "colors outside the window are dropped")
	for p.scroll > 0 {
		preview_scroll_by(&p, -WHEEL_SCROLL_LINES, VIEW_H)
	}
	testing.expect(t, len(p.rows[5].colors) > 0 && p.rows[5].colors[0] == COLOR_SYN_COMMENT, "scrolling back up recolors")
	testing.expect(t, raw_data(p.rows[0].text) == first_text, "scrolling a big file never re-clones rows")
	ms, ticks = preview_bench_scroll(&p, VIEW_H)
	fmt.printfln("preview scroll big: %d ticks, %.3f ms/tick", ticks, ms / f64(max(1, ticks)))
}
