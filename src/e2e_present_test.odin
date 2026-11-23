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
vt_begin :: proc() -> Vt {
	e2e_enter()
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
vt_end :: proc(v: ^Vt) {
	sync.mutex_lock(&e2e_tap_lock)
	e2e_tapping = false
	clear(&e2e_tap)
	sync.mutex_unlock(&e2e_tap_lock)
	vterm.free(v.vt)
	sync.mutex_unlock(&e2e_lock)
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
		spans := []MdSpan{{text = s, fg = COLOR_FG, bg = COLOR_BG}}
		md_draw_line(0, y, E2E_W, MdLine{spans = spans}, COLOR_BG)
	}
	vt_present_check(t, &v, "frame A", false)

	tb2.clear()
	tb2.print(0, 0, COLOR_FG, COLOR_BG, "plain ascii line")
	vt_present_check(t, &v, "frame B", true)
}
