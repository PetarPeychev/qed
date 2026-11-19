package main

import "core:testing"

status_test_segs :: proc() -> (left, right: [dynamic]StatusSeg) {
	left = make([dynamic]StatusSeg, context.temp_allocator)
	right = make([dynamic]StatusSeg, context.temp_allocator)
	append(&left, StatusSeg{text = " F"})
	append(&left, StatusSeg{sep = " ", text = "src/deep/dir/filetree.odin", kind = .Path})
	append(&left, StatusSeg{sep = "  ", text = "12/300"})
	append(&left, StatusSeg{sep = "  ", text = "B master", drop = 8})
	append(&left, StatusSeg{sep = " ", text = "^1", drop = 7})
	append(&left, StatusSeg{sep = "  ", text = "+5 -2", drop = 6})
	append(&left, StatusSeg{sep = "  ", text = "[1/2]", drop = 9})
	append(&right, StatusSeg{sep = "  ", text = "AI:1", drop = 5})
	append(&right, StatusSeg{sep = "  ", text = "L Odin", drop = 4})
	append(&right, StatusSeg{sep = "  ", text = "S ols", drop = 2})
	append(&right, StatusSeg{sep = "  ", text = "I Spaces:4", drop = 1})
	return
}

@(test)
test_status_fit_wide_keeps_everything :: proc(t: ^testing.T) {
	left, right := status_test_segs()
	status_fit(left[:], right[:], 200)
	testing.expect_value(t, left[1].text, "src/deep/dir/filetree.odin")
	for s in left {
		testing.expect(t, !s.hidden)
	}
	for s in right {
		testing.expect(t, !s.hidden)
	}
}

@(test)
test_status_fit_shortens_path_first :: proc(t: ^testing.T) {
	left, right := status_test_segs()
	full := status_width(left[:]) + 1 + status_width(right[:]) + 1
	status_fit(left[:], right[:], full - 5)
	testing.expect_value(t, left[1].text, "…/dir/filetree.odin")
	testing.expect(t, status_overflow(left[:], right[:], full - 5) <= 0)
	for s in right {
		testing.expect(t, !s.hidden)
	}
}

@(test)
test_status_fit_drop_order :: proc(t: ^testing.T) {
	left, right := status_test_segs()
	status_fit(left[:], right[:], 60)
	testing.expect_value(t, left[1].text, "filetree.odin")
	testing.expect(t, status_overflow(left[:], right[:], 60) <= 0)
	testing.expect(t, right[3].hidden)
	testing.expect(t, right[2].hidden)
	testing.expect(t, !right[0].hidden)
	testing.expect(t, !left[3].hidden)

	left, right = status_test_segs()
	status_fit(left[:], right[:], 40)
	for s in right {
		testing.expect(t, s.hidden)
	}
	testing.expect(t, left[5].hidden)
	testing.expect(t, left[4].hidden)
	testing.expect(t, !left[6].hidden)
	testing.expect(t, status_overflow(left[:], right[:], 40) <= 0)
}

@(test)
test_status_fit_clips_filename_last :: proc(t: ^testing.T) {
	left, right := status_test_segs()
	status_fit(left[:], right[:], 20)
	for s in left[3:] {
		testing.expect(t, s.hidden)
	}
	testing.expect_value(t, left[1].text, "filetree…")
	testing.expect_value(t, status_width(left[:]), 20)
}

@(test)
test_status_path_shorten :: proc(t: ^testing.T) {
	p, ok := status_path_shorten("a/b/c.odin")
	testing.expect(t, ok)
	testing.expect_value(t, p, "…/b/c.odin")
	p, ok = status_path_shorten(p)
	testing.expect_value(t, p, "…/c.odin")
	p, ok = status_path_shorten(p)
	testing.expect_value(t, p, "c.odin")
	p, ok = status_path_shorten(p)
	testing.expect(t, !ok)
	p, _ = status_path_shorten("/home/petar/qed")
	testing.expect_value(t, p, "…/petar/qed")
}

split_expect :: proc(t: ^testing.T, inner_w, lmin, lmax, want_l, want_r: int, want_preview: bool, loc := #caller_location) {
	l, r, preview := overlay_split(inner_w, lmin, lmax)
	testing.expect_value(t, preview, want_preview, loc)
	testing.expect_value(t, l, want_l, loc)
	testing.expect_value(t, r, want_r, loc)
}

@(test)
test_overlay_split_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, FILETREE_LIST_MIN_WIDTH, 30)
	testing.expect_value(t, FILETREE_LIST_MAX_WIDTH, 60)
	testing.expect_value(t, CODE_LIST_MIN_WIDTH, 50)
	testing.expect_value(t, CODE_LIST_MAX_WIDTH, 100)
	testing.expect_value(t, PREVIEW_MIN_WIDTH, 70)
	testing.expect_value(t, PREVIEW_MAX_WIDTH, 130)
}

@(test)
test_overlay_split_filetree :: proc(t: ^testing.T) {
	lmin, lmax := 30, 60
	split_expect(t, 1 + 400, lmin, lmax, 60, 130, true)
	split_expect(t, 1 + 190, lmin, lmax, 60, 130, true)
	split_expect(t, 1 + 189, lmin, lmax, 60, 129, true)
	split_expect(t, 1 + 150, lmin, lmax, 40, 110, true)
	split_expect(t, 1 + 145, lmin, lmax, 38, 107, true)
	split_expect(t, 1 + 120, lmin, lmax, 30, 90, true)
	split_expect(t, 1 + 101, lmin, lmax, 30, 71, true)
	split_expect(t, 1 + 100, lmin, lmax, 30, 70, true)
	split_expect(t, 1 + 99, lmin, lmax, 100, 0, false)
	split_expect(t, 10, lmin, lmax, 10, 0, false)
}

@(test)
test_overlay_split_code :: proc(t: ^testing.T) {
	lmin, lmax := 50, 100
	split_expect(t, 1 + 400, lmin, lmax, 100, 130, true)
	split_expect(t, 1 + 230, lmin, lmax, 100, 130, true)
	split_expect(t, 1 + 229, lmin, lmax, 100, 129, true)
	split_expect(t, 1 + 228, lmin, lmax, 99, 129, true)
	split_expect(t, 1 + 175, lmin, lmax, 73, 102, true)
	split_expect(t, 1 + 130, lmin, lmax, 50, 80, true)
	split_expect(t, 1 + 120, lmin, lmax, 50, 70, true)
	split_expect(t, 1 + 119, lmin, lmax, 120, 0, false)
}

@(test)
test_status_fit_clips_undroppable_plugin_segment :: proc(t: ^testing.T) {
	left := make([dynamic]StatusSeg, context.temp_allocator)
	right := make([dynamic]StatusSeg, context.temp_allocator)
	append(&left, StatusSeg{text = " F"})
	append(&left, StatusSeg{sep = " ", text = "a.odin", kind = .Path})
	append(&left, StatusSeg{sep = "  ", text = "a very long plugin segment", kind = .Plugin})
	append(&right, StatusSeg{sep = "  ", text = "keep", kind = .Plugin})
	status_fit(left[:], right[:], 30)
	testing.expect(t, status_overflow(left[:], right[:], 30) <= 0, "fits after clipping")
	testing.expect(t, !left[2].hidden, "a long plugin segment is clipped, not hidden")
	testing.expect_value(t, left[2].text[len(left[2].text) - len("…"):], "…")
	testing.expect_value(t, right[0].text, "keep")
	status_fit(left[:], right[:], 12)
	testing.expect(t, status_overflow(left[:], right[:], 12) <= 0, "segments too narrow to clip hide")
}
