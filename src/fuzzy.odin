package main

import "core:slice"

Fuzzy :: struct {
	items: []string,
}

fuzzy_begin :: proc(items: []string) -> Fuzzy {
	return Fuzzy{items = items}
}

fuzzy_end :: proc(f: ^Fuzzy) {}

fuzzy_rank :: proc(f: ^Fuzzy, query: string, allocator := context.temp_allocator) -> [dynamic]int {
	out := make([dynamic]int, 0, len(f.items), allocator)
	if len(query) == 0 {
		for i in 0 ..< len(f.items) {
			append(&out, i)
		}
		return out
	}
	fuzzy_rank_builtin(f, query, &out)
	return out
}

ScoreIdx :: struct {
	score: int,
	idx:   int,
}

fuzzy_rank_builtin :: proc(f: ^Fuzzy, query: string, out: ^[dynamic]int) {
	entries := make([dynamic]ScoreIdx, 0, len(f.items), context.temp_allocator)
	for item, i in f.items {
		if score, ok := fuzzy_match(query, item); ok {
			append(&entries, ScoreIdx{score, i})
		}
	}
	slice.sort_by(entries[:], proc(a, b: ScoreIdx) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return a.idx < b.idx
	})
	for e in entries {
		append(out, e.idx)
	}
}

ascii_lower :: proc(c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

fuzzy_separator :: proc(c: u8) -> bool {
	return char_class(rune(c)) != .Word
}

fuzzy_match :: proc(pattern, text: string) -> (score: int, ok: bool) {
	if len(pattern) == 0 {
		return 0, true
	}
	pi := 0
	prev_match := -2
	for ti := 0; ti < len(text) && pi < len(pattern); ti += 1 {
		if ascii_lower(text[ti]) != ascii_lower(pattern[pi]) {
			continue
		}
		score += 1
		if ti == prev_match + 1 {
			score += 3
		}
		if ti == 0 || fuzzy_separator(text[ti - 1]) {
			score += 5
		}
		prev_match = ti
		pi += 1
	}
	return score, pi == len(pattern)
}
