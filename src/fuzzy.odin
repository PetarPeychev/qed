package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

FuzzyTool :: enum {
	Unknown,
	Fzf,
	None,
}

fuzzy_tool: FuzzyTool = .Unknown

fuzzy_detect :: proc() {
	if shell_command_exists("fzf") {
		fuzzy_tool = .Fzf
	} else {
		fuzzy_tool = .None
	}
}

Fuzzy :: struct {
	items:    []string,
	tmp_path: string,
	has_tmp:  bool,
}

fuzzy_begin :: proc(items: []string) -> Fuzzy {
	if fuzzy_tool == .Unknown {
		fuzzy_detect()
	}
	f := Fuzzy {
		items = items,
	}
	if fuzzy_tool == .Fzf {
		sb := strings.builder_make(context.temp_allocator)
		for item, i in items {
			fmt.sbprintf(&sb, "%d\t%s\n", i, item)
		}
		path := fmt.tprintf("/tmp/qed-fuzzy-%d", os.get_pid())
		if os.write_entire_file(path, strings.to_string(sb)) == nil {
			f.tmp_path = strings.clone(path)
			f.has_tmp = true
		}
	}
	return f
}

fuzzy_end :: proc(f: ^Fuzzy) {
	if f.has_tmp {
		os.remove(f.tmp_path)
		delete(f.tmp_path)
		f.has_tmp = false
	}
}

fuzzy_rank :: proc(f: ^Fuzzy, query: string, allocator := context.temp_allocator) -> [dynamic]int {
	out := make([dynamic]int, 0, len(f.items), allocator)
	if len(query) == 0 {
		for i in 0 ..< len(f.items) {
			append(&out, i)
		}
		return out
	}
	if f.has_tmp && fuzzy_rank_fzf(f, query, &out) {
		return out
	}
	fuzzy_rank_builtin(f, query, &out)
	return out
}

fuzzy_rank_fzf :: proc(f: ^Fuzzy, query: string, out: ^[dynamic]int) -> bool {
	cmd := fmt.ctprintf(
		"fzf --filter=%s --delimiter='\\t' --nth=2 <%s 2>/dev/null",
		shell_quote(query),
		shell_quote(f.tmp_path),
	)
	result, ok := shell_capture(cmd)
	if !ok {
		return false
	}
	for line in strings.split_lines_iterator(&result) {
		tab := strings.index_byte(line, '\t')
		if tab < 0 {
			continue
		}
		if idx, ok := strconv.parse_int(line[:tab], 10); ok {
			append(out, idx)
		}
	}
	return true
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
	return char_class(c) != .Word
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
