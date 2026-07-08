package main

import "core:strings"
import "core:testing"

@(private = "file")
join :: proc(b: ^Buffer) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for line, i in b.lines {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_bytes(&sb, line.text[:])
	}
	return strings.to_string(sb)
}

@(test)
test_merge_scan_two_way :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch", "tail")
	defer buffer_destroy(&b)
	c := merge_scan(&b)
	testing.expect_value(t, len(c), 1)
	testing.expect_value(t, c[0].start, 0)
	testing.expect_value(t, c[0].base, -1)
	testing.expect_value(t, c[0].sep, 2)
	testing.expect_value(t, c[0].end, 4)
}

@(test)
test_merge_scan_diff3 :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "||||||| base", "orig", "=======", "theirs", ">>>>>>> branch")
	defer buffer_destroy(&b)
	c := merge_scan(&b)
	testing.expect_value(t, len(c), 1)
	testing.expect_value(t, c[0].base, 2)
	testing.expect_value(t, c[0].sep, 4)
	testing.expect_value(t, c[0].end, 6)
}

@(test)
test_merge_scan_incomplete :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "no closing marker")
	defer buffer_destroy(&b)
	c := merge_scan(&b)
	testing.expect_value(t, len(c), 0)
}

@(test)
test_merge_side :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch")
	defer buffer_destroy(&b)
	c := merge_scan(&b)
	s0, m0 := merge_side(c, 0)
	testing.expect(t, s0 == .Ours && m0)
	s1, m1 := merge_side(c, 1)
	testing.expect(t, s1 == .Ours && !m1)
	s3, m3 := merge_side(c, 3)
	testing.expect(t, s3 == .Theirs && !m3)
	s4, m4 := merge_side(c, 4)
	testing.expect(t, s4 == .Theirs && m4)
}

@(test)
test_merge_resolve_ours :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch", "tail")
	defer buffer_destroy(&b)
	merge_resolve(&b, merge_scan(&b)[0], .Ours)
	testing.expect_value(t, join(&b), "ours\ntail")
}

@(test)
test_merge_resolve_theirs :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch", "tail")
	defer buffer_destroy(&b)
	merge_resolve(&b, merge_scan(&b)[0], .Theirs)
	testing.expect_value(t, join(&b), "theirs\ntail")
}

@(test)
test_merge_resolve_both :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch", "tail")
	defer buffer_destroy(&b)
	merge_resolve(&b, merge_scan(&b)[0], .Both)
	testing.expect_value(t, join(&b), "ours\ntheirs\ntail")
}

@(test)
test_merge_resolve_diff3_both :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "||||||| base", "orig", "=======", "theirs", ">>>>>>> branch")
	defer buffer_destroy(&b)
	merge_resolve(&b, merge_scan(&b)[0], .Both)
	testing.expect_value(t, join(&b), "ours\ntheirs")
}

@(test)
test_merge_resolve_last_line :: proc(t: ^testing.T) {
	b := test_buffer("<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch")
	defer buffer_destroy(&b)
	merge_resolve(&b, merge_scan(&b)[0], .Theirs)
	testing.expect_value(t, join(&b), "theirs")
}
