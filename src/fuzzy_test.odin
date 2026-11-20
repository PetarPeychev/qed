package main

import "core:testing"

@(test)
test_fuzzy_rank_builtin :: proc(t: ^testing.T) {
	items := []string{"Save", "Quit", "Select All", "Save As"}

	f := Fuzzy{items = items}

	ranked := fuzzy_rank(&f, "sa", context.temp_allocator)
	seen: [4]bool
	for idx in ranked {
		testing.expect(t, idx != 1, "Quit should not match 'sa'")
		seen[idx] = true
	}
	testing.expect(t, seen[0], "Save should match 'sa'")
	testing.expect(t, seen[2], "Select All should match 'sa'")
	testing.expect(t, seen[3], "Save As should match 'sa'")

	all := fuzzy_rank(&f, "", context.temp_allocator)
	testing.expect_value(t, len(all), len(items))
}

@(test)
test_fuzzy_match_scores :: proc(t: ^testing.T) {
	ref :: proc(pattern, text: string) -> (score: int, ok: bool) {
		if len(pattern) == 0 {
			return 0, true
		}
		pi, prev := 0, -2
		for ti := 0; ti < len(text) && pi < len(pattern); ti += 1 {
			if ascii_lower(text[ti]) != ascii_lower(pattern[pi]) {
				continue
			}
			score += 1
			if ti == prev + 1 {
				score += 3
			}
			if ti == 0 || fuzzy_separator(text[ti - 1]) {
				score += 5
			}
			prev = ti
			pi += 1
		}
		return score, pi == len(pattern)
	}
	texts := []string{"", "Toggle Line Wrap", "line 5000 of a million", "src/Editor.odin", "AAA", "a_b-c d"}
	patterns := []string{"", "t", "TLW", "5000", "edit", "aaaa", "a", "b c", "zz", "lw"}
	for text in texts {
		for pat in patterns {
			gs, gok := fuzzy_match(pat, text)
			ws, wok := ref(pat, text)
			testing.expectf(t, gs == ws && gok == wok, "%q in %q: (%d, %v), want (%d, %v)", pat, text, gs, gok, ws, wok)
		}
	}
}
