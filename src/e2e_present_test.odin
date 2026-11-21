package main

import "core:c"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "lib:tb2"
import "lib:vterm"

@(private = "file")
TAP_MARKER :: "\x1b]0;qed-tap\x07"

// everything termbox wrote since the last call, up to a marker written behind it
@(private = "file")
tap_sync :: proc() -> []u8 {
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

@(private = "file")
back_ascii :: proc(x, y: int) -> (rune, bool) {
	cell: ^tb2.Cell_Raw
	if tb2.get_cell(i32(x), i32(y), 1, &cell) != .Ok || cell.nech > 0 || cell.ch <= 0x20 || cell.ch >= 0x7f {
		return 0, false
	}
	return rune(cell.ch), true
}

// libvterm stands in for a terminal whose width table and clustering differ from termbox's
@(test)
test_present_keeps_a_disagreeing_terminal_in_sync :: proc(t: ^testing.T) {
	e2e_enter()
	defer sync.mutex_unlock(&e2e_lock)

	vt := vterm.new(E2E_H, E2E_W)
	defer vterm.free(vt)
	vterm.set_utf8(vt, 1)
	screen := vterm.obtain_screen(vt)
	vterm.screen_reset(screen, 1)

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
	tap_sync()
	tb2.invalidate()

	rows := []string {
		"नेपाली भाषामा अनुवाद गरिएको सन्देश | end",
		"क्षेत्र श्रीमान् ज्ञान क़ क्\u200dष क्\u200cष | end",
		"zero width: a\u200bb\u200cc\u200dd\ufeffe | end",
		"emoji: 😀👍🏽👨\u200d👩\u200d👧\u200d👦🇧🇬🏳️\u200d🌈 1️⃣ ❤️ ❤ | end",
		"combining: e\u0301 Z̵̡̛̰ ñ̃̃ | end",
		"\u0301 lone mark | end",
		"wide: 漢字かなカナ한국어 全角ＡＢＣ | end",
		"thai: กำ น้ำ | end",
		strings.concatenate({strings.repeat("x", E2E_W - 2, context.temp_allocator), "👨\u200d👩\u200d👧\u200d👦"}, context.temp_allocator),
		strings.concatenate({strings.repeat("x", E2E_W - 2, context.temp_allocator), "ना"}, context.temp_allocator),
		strings.concatenate({strings.repeat("x", E2E_W - 1, context.temp_allocator), "e\u0301"}, context.temp_allocator),
		strings.concatenate({strings.repeat("x", E2E_W - 1, context.temp_allocator), "\u0928\u093f"}, context.temp_allocator),
		strings.concatenate({strings.repeat("x", E2E_W - 1, context.temp_allocator), "\u200b"}, context.temp_allocator),
	}
	tb2.clear()
	for s, y in rows {
		spans := []MdSpan{{text = s, fg = COLOR_FG, bg = COLOR_BG}}
		md_draw_line(0, y, E2E_W, MdLine{spans = spans}, COLOR_BG)
	}
	tb2.present()
	vterm_feed(vt, tap_sync())
	for y in 0 ..< E2E_H {
		for x in 0 ..< E2E_W {
			if want, ok := back_ascii(x, y); ok {
				got := vterm_rune(screen, x, y)
				testing.expectf(t, got == want, "frame A row %d col %d: terminal shows %q, termbox has %q", y, x, got, want)
			}
		}
	}

	tb2.clear()
	tb2.print(0, 0, COLOR_FG, COLOR_BG, "plain ascii line")
	tb2.present()
	vterm_feed(vt, tap_sync())
	for y in 0 ..< E2E_H {
		for x in 0 ..< E2E_W {
			want, ok := back_ascii(x, y)
			if !ok {
				want = ' '
			}
			got := vterm_rune(screen, x, y)
			testing.expectf(t, got == want, "frame B row %d col %d: stale %q, termbox has %q", y, x, got, want)
		}
	}
}
