package main

import "core:testing"

@(test)
test_language_of_extensions :: proc(t: ^testing.T) {
	Case :: struct {
		path: string,
		want: Language,
	}
	cases := []Case {
		{"a.js", .JavaScript},
		{"a.mjs", .JavaScript},
		{"a.cjs", .JavaScript},
		{"a.jsx", .Jsx},
		{"a.ts", .TypeScript},
		{"a.mts", .TypeScript},
		{"a.tsx", .Tsx},
		{"a.py", .Python},
		{"a.md", .Markdown},
		{"a.markdown", .Markdown},
		{"dir/x.tsx", .Tsx},
		{"noext", .Plain},
		{"a.unknown", .Plain},
	}
	for c in cases {
		testing.expectf(t, language_of(c.path) == c.want, "%s: got %v want %v", c.path, language_of(c.path), c.want)
	}
}
