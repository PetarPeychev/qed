package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "lib:tb2"
import "lib:vterm"

TAP_MARKER :: "\x1b]0;qed-tap\x07"

// everything termbox wrote since the last call, up to a marker written behind it
e2e_tap_sync :: proc() -> []u8 {
	posix.write(posix.FD(e2e_slave), raw_data(string(TAP_MARKER)), len(TAP_MARKER))
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 5 {
		sync.mutex_lock(&e2e_tap_lock)
		at := strings.index(string(e2e_tap[:]), TAP_MARKER)
		if at >= 0 {
			out := make([]u8, at, context.temp_allocator)
			copy(out, e2e_tap[:at])
			remove_range(&e2e_tap, 0, at + len(TAP_MARKER))
			sync.mutex_unlock(&e2e_tap_lock)
			return out
		}
		sync.mutex_unlock(&e2e_tap_lock)
		time.sleep(time.Millisecond)
	}
	return nil
}

@(private = "file")
vterm_feed :: proc(vt: ^vterm.VTerm, bytes: []u8) {
	if len(bytes) > 0 {
		vterm.input_write(vt, raw_data(bytes), c.size_t(len(bytes)))
	}
}

@(private = "file")
vterm_rune :: proc(screen: ^vterm.Screen, x, y: int) -> rune {
	cell: vterm.ScreenCell
	vterm.screen_get_cell(screen, {c.int(y), c.int(x)}, &cell)
	return rune(cell.chars[0]) if cell.chars[0] != 0 && cell.chars[0] != max(u32) else ' '
}

// what termbox means a cell to show, when it is a lone width-1 codepoint (else ok = false)
@(private = "file")
back_plain :: proc(x, y: int) -> (r: rune, w: int, ok: bool) {
	cell: ^tb2.Cell_Raw
	if tb2.get_cell(i32(x), i32(y), 1, &cell) != .Ok {
		return 0, 1, false
	}
	if cell.nech > 0 {
		return 0, max(int(tb2.cluster_width(cast([^]rune)cell.ech, cell.nech)), 1), false
	}
	cw := int(tb2.wcwidth(rune(cell.ch)))
	return rune(cell.ch), max(cw, 1), cw == 1
}

@(private = "file")
Vt :: struct {
	vt:     ^vterm.VTerm,
	screen: ^vterm.Screen,
}

// libvterm stands in for a terminal whose width table and clustering differ from termbox's
@(private = "file")
vt_begin :: proc(entered := false) -> Vt {
	if !entered {
		e2e_enter()
	}
	v: Vt
	v.vt = vterm.new(E2E_H, E2E_W)
	vterm.set_utf8(v.vt, 1)
	v.screen = vterm.obtain_screen(v.vt)
	vterm.screen_reset(v.screen, 1)
	sync.mutex_lock(&e2e_tap_lock)
	e2e_tapping = true
	clear(&e2e_tap)
	sync.mutex_unlock(&e2e_tap_lock)
	e2e_tap_sync()
	tb2.invalidate()
	return v
}

@(private = "file")
vt_end :: proc(v: ^Vt, entered := false) {
	sync.mutex_lock(&e2e_tap_lock)
	e2e_tapping = false
	clear(&e2e_tap)
	sync.mutex_unlock(&e2e_tap_lock)
	vterm.free(v.vt)
	if !entered {
		sync.mutex_unlock(&e2e_lock)
	}
}

// presents the back buffer, then: every lone width-1 glyph termbox placed is at that column in
// the terminal, and with `all` every cell matches (blank where termbox has no plain glyph)
@(private = "file")
vt_present_check :: proc(t: ^testing.T, v: ^Vt, label: string, all: bool) -> (sent: int) {
	tb2.present()
	out := e2e_tap_sync()
	vterm_feed(v.vt, out)
	for y in 0 ..< E2E_H {
		for x := 0; x < E2E_W; {
			want, w, ok := back_plain(x, y)
			got := vterm_rune(v.screen, x, y)
			if ok && want != ' ' {
				testing.expectf(t, got == want, "%s row %d col %d: terminal shows %q, termbox has %q", label, y, x, got, want)
			} else if all {
				testing.expectf(t, got == ' ', "%s row %d col %d: stale %q, termbox has a blank", label, y, x, got)
			}
			x += w if !all else 1
		}
	}
	return len(out)
}

@(private = "file")
ODD_ROWS := []string {
	"नेपाली भाषामा अनुवाद गरिएको सन्देश | end",
	"क्षेत्र श्रीमान् ज्ञान क़ क्\u200dष क्\u200cष | end",
	"zero width: a\u200bb\u200cc\u200dd\ufeffe | end",
	"emoji: 😀👍🏽👨\u200d👩\u200d👧\u200d👦🇧🇬🏳️\u200d🌈 1️⃣ ❤️ ❤ | end",
	"combining: e\u0301 Z̵̡̛̰ ñ̃̃ | end",
	"\u0301 lone mark | end",
	"wide: 漢字かなカナ한국어 全角ＡＢＣ | end",
	"thai: กำ น้ำ\t| tab end",
}

@(test)
test_present_keeps_a_disagreeing_terminal_in_sync :: proc(t: ^testing.T) {
	v := vt_begin()
	defer vt_end(&v)

	rows := make([dynamic]string, context.temp_allocator)
	append(&rows, ..ODD_ROWS)
	x78 := strings.repeat("x", E2E_W - 2, context.temp_allocator)
	x79 := strings.repeat("x", E2E_W - 1, context.temp_allocator)
	append(&rows, strings.concatenate({x78, "👨\u200d👩\u200d👧\u200d👦"}, context.temp_allocator))
	append(&rows, strings.concatenate({x78, "ना"}, context.temp_allocator))
	append(&rows, strings.concatenate({x79, "e\u0301"}, context.temp_allocator))
	append(&rows, strings.concatenate({x79, "नि"}, context.temp_allocator))
	append(&rows, strings.concatenate({x79, "\u200b"}, context.temp_allocator))
	tb2.clear()
	for s, y in rows {
		draw_row(y, s)
	}
	vt_present_check(t, &v, "frame A", false)

	tb2.clear()
	tb2.print(0, 0, COLOR_FG, COLOR_BG, "plain ascii line")
	vt_present_check(t, &v, "frame B", true)
}

@(private = "file")
vterm_row_text :: proc(screen: ^vterm.Screen, y: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for x in 0 ..< E2E_W {
		cell: vterm.ScreenCell
		vterm.screen_get_cell(screen, {c.int(y), c.int(x)}, &cell)
		if cell.chars[0] == 0 {
			strings.write_byte(&sb, ' ')
		}
		for ch in cell.chars {
			if ch == 0 || ch == max(u32) {
				break
			}
			strings.write_rune(&sb, rune(ch))
		}
	}
	return strings.trim_right_space(strings.to_string(sb))
}

@(private = "file")
draw_row :: proc(y: int, s: string) {
	col := 0
	for cl in md_clusters(s) {
		cw := cluster_width(transmute([]u8)cl)
		if col + cw > E2E_W {
			return
		}
		cell_put_cluster(col, y, transmute([]u8)cl, COLOR_FG, COLOR_BG)
		col += cw
	}
}

// clusters sharing their first codepoint: only the tail differs
@(test)
test_present_resends_a_changed_cluster_tail :: proc(t: ^testing.T) {
	v := vt_begin()
	defer vt_end(&v)
	tb2.clear()
	draw_row(0, "नि e\u0301 🇧🇬 |")
	vt_present_check(t, &v, "first", false)
	tb2.clear()
	draw_row(0, "ना è 🇧🇪 |")
	vt_present_check(t, &v, "second", false)
	got := vterm_row_text(v.screen, 0)
	testing.expectf(t, got == "ना è 🇧🇪 |", "terminal row %q", got)
}

// only changed cells are diffed; what the terminal draws around them must still be right
@(test)
test_present_partial_updates_around_a_disagreeing_cluster :: proc(t: ^testing.T) {
	v := vt_begin()
	defer vt_end(&v)

	x74 := strings.repeat("x", E2E_W - 6, context.temp_allocator)
	tb2.clear()
	draw_row(0, "XYZW")
	draw_row(1, "abcdefghijkl")
	draw_row(2, "xAB")
	vt_present_check(t, &v, "before", true)

	tb2.clear()
	draw_row(0, "❤️ZW")
	draw_row(2, "x\u200bB")
	draw_row(3, strings.concatenate({x74, "👨\u200d👩\u200d👧\u200d👦"}, context.temp_allocator))
	draw_row(1, "👨\u200d👩\u200d👧\u200d👦cdefghijkl")
	vt_present_check(t, &v, "after", false)
	// libvterm draws the VS16 heart 1 wide: the cell it no longer covers must not keep Y
	testing.expectf(t, vterm_rune(v.screen, 1, 0) == ' ', "row 0 col 1 shows %q", vterm_rune(v.screen, 1, 0))
	// 6 columns hold a family even for a terminal that draws it 4 wide
	testing.expectf(t, vterm_rune(v.screen, E2E_W - 6, 3) == 0x1f468, "row 3 col %d shows %q", E2E_W - 6, vterm_rune(v.screen, E2E_W - 6, 3))
	// a lone ZWSP advances nothing: the cell it replaced must not keep A
	testing.expectf(t, vterm_rune(v.screen, 1, 2) == ' ', "row 2 col 1 shows %q", vterm_rune(v.screen, 1, 2))
	// libvterm draws the family 8 wide over cdefgh, which termbox never changed
	for x in 2 ..< 12 {
		want := rune('c' + x - 2)
		testing.expectf(t, vterm_rune(v.screen, x, 1) == want, "row 1 col %d shows %q, want %q", x, vterm_rune(v.screen, x, 1), want)
	}
}

// a lone wide codepoint is drawn alike by every terminal: no blanking or resending around it
@(test)
test_present_sends_plain_wide_text_once :: proc(t: ^testing.T) {
	v := vt_begin()
	defer vt_end(&v)
	tb2.clear()
	draw_row(0, strings.repeat("字", E2E_W / 2, context.temp_allocator))
	vt_present_check(t, &v, "first", false)
	tb2.clear()
	draw_row(0, strings.repeat("漢", E2E_W / 2, context.temp_allocator))
	sent := vt_present_check(t, &v, "second", false)
	// 3 UTF-8 bytes per char plus one cursor move, colors and the final cursor
	testing.expectf(t, sent < 3 * E2E_W / 2 + 80, "%d bytes for %d chars", sent, E2E_W / 2)
	got := vterm_row_text(v.screen, 0)
	testing.expectf(t, got == strings.repeat("漢", E2E_W / 2, context.temp_allocator), "terminal row %q", got)
}

@(test)
test_pane_text_draws_clusters :: proc(t: ^testing.T) {
	e2e_enter()
	defer sync.mutex_unlock(&e2e_lock)
	Case :: struct {
		text:  string,
		width: int,
		cells: []rune,
	}
	cases := []Case {
		{"漢字ab", 6, {0x6f22, 0, 0x5b57, 0, 'a', 'b'}},
		{"e\u0301x", 2, {'e', 'x'}},
		{"क्षेab", 4, {0x0915, 0, 'a', 'b'}},
	}
	for c in cases {
		tb2.clear()
		got := draw_text(0, 0, 20, c.text, COLOR_FG, COLOR_BG)
		testing.expectf(t, got == c.width, "%q: %d columns, want %d", c.text, got, c.width)
		for want, x in c.cells {
			cell: ^tb2.Cell_Raw
			tb2.get_cell(i32(x), 0, 1, &cell)
			if want != 0 {
				testing.expectf(t, rune(cell.ch) == want, "%q col %d: %q, want %q", c.text, x, rune(cell.ch), want)
			}
		}
	}
	tb2.clear()
	testing.expect(t, draw_text(0, 0, 3, "ab漢", COLOR_FG, COLOR_BG) == 2, "a wide char past the width is left out")
}

// wide clusters of the row underneath straddle both edges of a box drawn over it
@(test)
test_box_edges_over_wide_clusters :: proc(t: ^testing.T) {
	v := vt_begin()
	defer vt_end(&v)

	left, right := 10, 50
	clusters := []string{"ली", "श्री", "漢", "👨\u200d👩\u200d👧\u200d👦", "🇧🇬", "❤️", "👍🏽"}
	odd := strings.join(ODD_ROWS, "\n", context.temp_allocator)
	code := strings.repeat("static int helper(struct state *s, const char *name, size_t len) {\n", E2E_H, context.temp_allocator)
	for text, f in ([]string{odd, code, odd}) {
		tb2.clear()
		for c, y in clusters {
			cw := md_text_width(c)
			lead := strings.repeat("x", left - 1, context.temp_allocator)
			mid := strings.repeat("y", right - left - cw + 1, context.temp_allocator)
			draw_row(y, strings.concatenate({lead, c, mid, c, "zzz"}, context.temp_allocator))
		}
		inner := draw_box({left, -1, right - left + 1, len(clusters) + 2})
		for line, y in strings.split_lines(text, context.temp_allocator)[:len(clusters)] {
			draw_text(inner.x, y, inner.w, line, COLOR_FG, COLOR_PANE_BG)
		}
		vt_present_check(t, &v, fmt.tprintf("frame %d", f), false)
		for c, y in clusters {
			for x in ([]int{left, right}) {
				got := vterm_rune(v.screen, x, y)
				testing.expectf(t, got == '│', "frame %d, %q row: col %d shows %q, want the border", f, c, x, got)
			}
		}
	}
}

// a readonly editor node beside a list swaps between odd text and plain code (a picker preview moving between hits)
@(test)
test_preview_swap_keeps_a_disagreeing_terminal_in_sync :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	odd := strings.join(ODD_ROWS, "\n", context.temp_allocator)
	code := strings.repeat("static int helper(struct state *s, const char *name, size_t len) {\n", E2E_H, context.temp_allocator)
	ft_lua(&e.ed, `
		_G.swap_buffer = qed.buf.create{internal = true}
		qed.ui.mount("pane", qed.ui.row{float = "screen", width = "100%", height = "100%", separator = true,
			qed.ui.text{width = 19, "list"},
			qed.ui.editor{id = "swap_preview", buffer = swap_buffer, grow = 1, readonly = true}})
		return 0`)
	e2e_render(&e)
	v := vt_begin(true)
	defer vt_end(&v, true)
	node := ui_find(&e.ed.ui, "#fthelper/swap_preview")
	testing.expect(t, node != nil, "the preview editor is mounted")
	if node == nil {
		return
	}
	for text, i in ([]string{odd, code, odd, code}) {
		buffer_set_text(ui_buffer(&e.ed, node.buffer), text)
		e2e_render(&e)
		vt_present_check(t, &v, fmt.tprintf("preview %d", i), false)
		if text != odd {
			continue
		}
		for y in ([]int{0, 4, 6}) {
			got := vterm_row_text(v.screen, y)
			testing.expectf(t, strings.contains(got, ODD_ROWS[y][:12]), "preview %d row %d: terminal shows %q", i, y, got)
		}
	}
}
