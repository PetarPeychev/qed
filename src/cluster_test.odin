package main

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(private = "file")
CLUSTER_SAMPLES := []string {
	"",
	"plain ascii",
	"\ttab\t\tstops\t",
	"é ǟ Z̵̡ ñ",
	"漢字かな 全角ＡＢＣ wide",
	"😀👍🏽👨‍👩‍👧‍👦🇧🇬🇧🇬🏳️‍🌈 1️⃣ ❤️ x",
	"a\u200bb\u200dc\xef\xbb\xbfd",
	"cr\rlf\r\nmid\r",
	"ctl \x01\x07\x1b[31m\x7f nul\x00x",
	"bad \xff\xfe\x80 utf8 \xe2\x82",
	"ascii then mark áb́̂",
	"שלום مرحبا",
	"क्ष indic",
	"wrap at words, a\u0301 b\tcd x\u200dy longwordlongword end",
}

@(private = "file")
ref_starts :: proc(text: []u8) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		append(&out, g.byte_index)
	}
	append(&out, len(text))
	return out
}

@(private = "file")
ref_visual_col :: proc(text: []u8, col: int) -> int {
	starts := ref_starts(text)
	v := 0
	for i in 0 ..< len(starts) - 1 {
		if starts[i] < col {
			v += seg_width(text, starts[i], starts[i + 1], v)
		}
	}
	return v
}

@(private = "file")
ref_line_wrap :: proc(text: []u8, width: int) -> [dynamic]int {
	segs := make([dynamic]int, context.temp_allocator)
	append(&segs, 0)
	if width <= 0 || len(text) == 0 {
		return segs
	}
	starts := ref_starts(text)
	v, seg_start_v, last_break, last_break_v := 0, 0, -1, 0
	for i in 0 ..< len(starts) - 1 {
		cs, ce := starts[i], starts[i + 1]
		cw := seg_width(text, cs, ce, v)
		seg_start := segs[len(segs) - 1]
		if v + cw - seg_start_v > width && cs > seg_start {
			if last_break > seg_start {
				append(&segs, last_break)
				seg_start_v = last_break_v
			} else {
				append(&segs, cs)
				seg_start_v = v
			}
			last_break = -1
		}
		v += cw
		if text[cs] == ' ' || text[cs] == '\t' {
			last_break = ce
			last_break_v = v
		}
	}
	return segs
}

@(test)
test_cluster_fast_path_matches_grapheme_iterator :: proc(t: ^testing.T) {
	samples := make([dynamic]string, context.temp_allocator)
	append(&samples, ..CLUSTER_SAMPLES)
	append(&samples, strings.concatenate(CLUSTER_SAMPLES, context.temp_allocator))
	for s in samples {
		text := transmute([]u8)s
		starts := ref_starts(text)
		got := make([dynamic]int, context.temp_allocator)
		for i := 0; i < len(text); i = cluster_end(text, i) {
			append(&got, i)
		}
		append(&got, len(text))
		testing.expectf(t, len(got) == len(starts), "%q: %d clusters, want %d", s, len(got) - 1, len(starts) - 1)
		for i in 0 ..< min(len(got), len(starts)) {
			testing.expectf(t, got[i] == starts[i], "%q: boundary %d at %d, want %d", s, i, got[i], starts[i])
		}
		for col in 0 ..= len(text) {
			testing.expectf(t, visual_col(text, col) == ref_visual_col(text, col), "%q: visual_col(%d)", s, col)
			want_next := len(text)
			want_prev := 0
			for b in starts[:len(starts) - 1] {
				if b > col && want_next == len(text) {
					want_next = b
				}
				if b < col {
					want_prev = b
				}
			}
			testing.expectf(t, grapheme_next(text, col) == want_next, "%q: grapheme_next(%d) = %d, want %d", s, col, grapheme_next(text, col), want_next)
			testing.expectf(t, grapheme_prev(text, col) == want_prev, "%q: grapheme_prev(%d) = %d, want %d", s, col, grapheme_prev(text, col), want_prev)
		}
		for width in 1 ..= 12 {
			got_w, want_w := line_wrap(text, width), ref_line_wrap(text, width)
			same := len(got_w) == len(want_w)
			for k in 0 ..< min(len(got_w), len(want_w)) {
				same &&= got_w[k] == want_w[k]
			}
			testing.expectf(t, same, "%q: line_wrap(%d) = %v, want %v", s, width, got_w[:], want_w[:])
		}
		total := ref_visual_col(text, len(text))
		for target in 0 ..= total + 1 {
			c := col_at_visual(text, target)
			found := false
			for b in starts {
				found ||= b == c
			}
			testing.expectf(t, found, "%q: col_at_visual(%d) = %d is not a boundary", s, target, c)
		}
	}
}
