package main

import "core:testing"

@(test)
cwdpick_split_query :: proc(t: ^testing.T) {
	Case :: struct {
		query, base, term: string,
	}
	cases := []Case {
		{"", "", ""},
		{"src", "", "src"},
		{"src/", "src", ""},
		{"src/ma", "src", "ma"},
		{"../..", "..", ".."},
		{"../../g", "../..", "g"},
		{"~/", "~", ""},
		{"~/dev/q", "~/dev", "q"},
		{"/", "/", ""},
		{"/us", "/", "us"},
		{"/usr/lo", "/usr", "lo"},
	}
	for c in cases {
		base, term := cwdpick_split(c.query)
		testing.expectf(t, base == c.base && term == c.term, "%q -> (%q, %q), want (%q, %q)", c.query, base, term, c.base, c.term)
	}
}

@(test)
cwdpick_resolve_base :: proc(t: ^testing.T) {
	Case :: struct {
		base, want: string,
	}
	cases := []Case {
		{"", "/r/qed"},
		{"..", "/r"},
		{"../..", "/"},
		{"../../..", "/"},
		{"sub/dir", "/r/qed/sub/dir"},
		{"sub/../x", "/r/qed/x"},
		{"~", "/home/p"},
		{"~/dev", "/home/p/dev"},
		{"~/dev/..", "/home/p"},
		{"/", "/"},
		{"/usr/../etc", "/etc"},
	}
	for c in cases {
		got := cwdpick_resolve("/r/qed", "/home/p", c.base)
		testing.expectf(t, got == c.want, "%q -> %q, want %q", c.base, got, c.want)
	}
}

@(test)
cwdpick_prefix_smart_case :: proc(t: ^testing.T) {
	testing.expect(t, cwdpick_prefix_match("Games", ""))
	testing.expect(t, cwdpick_prefix_match("Games", "ga"))
	testing.expect(t, cwdpick_prefix_match("Games", "Ga"))
	testing.expect(t, !cwdpick_prefix_match("games", "Ga"))
	testing.expect(t, !cwdpick_prefix_match("Games", "gA"))
	testing.expect(t, !cwdpick_prefix_match("ga", "gam"))
	testing.expect(t, !cwdpick_prefix_match("agames", "ga"))
}

@(test)
path_under_root :: proc(t: ^testing.T) {
	testing.expect(t, path_under("/a/b/c.txt", "/a/b"))
	testing.expect(t, !path_under("/a/bc/c.txt", "/a/b"))
	testing.expect(t, !path_under("/a/b", "/a/b"))
	testing.expect(t, path_under("/x.txt", "/"))
}

@(test)
cwdpick_query_back_segment :: proc(t: ^testing.T) {
	Case :: struct {
		query, want: string,
	}
	cases := []Case {
		{"/home/p/qed/", "/home/p/"},
		{"/usr/", "/"},
		{"/", "/"},
		{"//", "/"},
		{"~/dev/games/", "~/dev/"},
		{"~/dev/", "~/"},
		{"~/", "/home/"},
		{"../../", "../"},
		{"../", ""},
		{"src/sub/", "src/"},
		{"src/", ""},
		{"dir/~/", "dir/"},
	}
	for c in cases {
		got := cwdpick_query_back(c.query, "/home/p")
		testing.expectf(t, got == c.want, "%q -> %q, want %q", c.query, got, c.want)
	}
	testing.expect_value(t, cwdpick_query_back("~/", "/root/"), "/")
}
