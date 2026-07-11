package main

import "core:sync"
import "core:testing"

@(test)
test_language_of_extensions :: proc(t: ^testing.T) {
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)

	languages_reset_defaults()
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
		{"a.toml", .Toml},
		{"a.yaml", .Yaml},
		{"a.yml", .Yaml},
		{"Dockerfile", .Dockerfile},
		{"dir/Dockerfile", .Dockerfile},
		{"app.dockerfile", .Dockerfile},
		{"Dockerfile.prod", .Dockerfile},
		{"dir/x.tsx", .Tsx},
		{"/home/u/.bashrc", .Shell},
		{".zprofile", .Shell},
		{"dir/PKGBUILD", .Shell},
		{"noext", .Plain},
		{"a.unknown", .Plain},
	}
	for c in cases {
		testing.expectf(t, language_of(c.path) == c.want, "%s: got %v want %v", c.path, language_of(c.path), c.want)
	}
}

@(test)
test_glob_match :: proc(t: ^testing.T) {
	testing.expect(t, glob_match("*.c", "foo.c"))
	testing.expect(t, glob_match(".bashrc", ".bashrc"))
	testing.expect(t, glob_match("*", "anything"))
	testing.expect(t, !glob_match("*.c", "foo.h"))
	testing.expect(t, !glob_match(".bashrc", "bashrc"))
	testing.expect(t, glob_match("a*b*c", "axxbyyc"))
	testing.expect(t, !glob_match("a*b*c", "axxbyy"))
}
