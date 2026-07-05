package main

import "core:fmt"
import "core:hash"
import "core:strings"
import "lib:tb2"

GitMark :: enum u8 {
	None,
	Added,
	Modified,
	Deleted,
}

GitGutter :: struct {
	tried:    bool,
	enabled:  bool,
	base:     [dynamic]u64,
	computed: bool,
	rev:      u64,
	marks:    [dynamic]GitMark,
}

git_destroy :: proc(g: ^GitGutter) {
	delete(g.base)
	delete(g.marks)
}

git_hash :: proc(bytes: []u8) -> u64 {
	return hash.fnv64a(bytes)
}

git_gutter_update :: proc(b: ^Buffer) {
	g := &b.git
	if !g.tried {
		git_base_fetch(b)
	}
	if g.computed && g.rev == b.rev {
		return
	}
	git_recompute(b)
	g.computed = true
	g.rev = b.rev
}

git_invalidate :: proc(b: ^Buffer) {
	b.git.tried = false
	b.git.computed = false
}

git_base_fetch :: proc(b: ^Buffer) {
	g := &b.git
	g.tried = true
	g.enabled = false
	clear(&g.base)

	if b.path == "" || !shell_command_exists("git") {
		return
	}

	slash := strings.last_index_byte(b.path, '/')
	dir := b.path[:slash] if slash >= 0 else "."
	name := b.path[slash + 1:] if slash >= 0 else b.path

	top_cmd := fmt.ctprintf("git -C %s rev-parse --show-toplevel 2>/dev/null", shell_quote(dir))
	top, ok := shell_capture(top_cmd)
	if !ok || strings.trim_space(top) == "" {
		return
	}
	g.enabled = true

	show_cmd := fmt.ctprintf("git -C %s show HEAD:./%s 2>/dev/null", shell_quote(dir), shell_quote(name))
	blob, blob_ok := shell_capture(show_cmd)
	if !blob_ok || len(blob) == 0 {
		return
	}

	segments := strings.split(blob, "\n", context.temp_allocator)
	for segment in segments {
		s := segment
		if len(s) > 0 && s[len(s) - 1] == '\r' {
			s = s[:len(s) - 1]
		}
		append(&g.base, git_hash(transmute([]u8)s))
	}
}

git_recompute :: proc(b: ^Buffer) {
	g := &b.git
	resize(&g.marks, len(b.lines))
	for i in 0 ..< len(g.marks) {
		g.marks[i] = .None
	}
	if !g.enabled {
		return
	}

	cur := make([dynamic]u64, 0, len(b.lines), context.temp_allocator)
	for line in b.lines {
		append(&cur, git_hash(line.text[:]))
	}
	git_diff(g.base[:], cur[:], g.marks[:])
}

git_diff :: proc(base, cur: []u64, marks: []GitMark) {
	lo := 0
	for lo < len(base) && lo < len(cur) && base[lo] == cur[lo] {
		lo += 1
	}
	hi_base, hi_cur := len(base), len(cur)
	for hi_base > lo && hi_cur > lo && base[hi_base - 1] == cur[hi_cur - 1] {
		hi_base -= 1
		hi_cur -= 1
	}

	old_lines := base[lo:hi_base]
	new_lines := cur[lo:hi_cur]

	if len(old_lines) == 0 && len(new_lines) == 0 {
		return
	}
	if len(old_lines) == 0 {
		for i in lo ..< hi_cur {
			marks[i] = .Added
		}
		return
	}
	if len(new_lines) == 0 {
		git_mark_deletion(marks, lo)
		return
	}

	ops, ok := git_myers(old_lines, new_lines)
	if !ok {
		nmod := min(len(old_lines), len(new_lines))
		for k in 0 ..< len(new_lines) {
			marks[lo + k] = .Modified if k < nmod else .Added
		}
		return
	}

	ci := lo
	i := 0
	for i < len(ops) {
		if ops[i] == .Equal {
			ci += 1
			i += 1
			continue
		}
		dels, adds := 0, 0
		hunk_ci := ci
		for i < len(ops) && ops[i] != .Equal {
			switch ops[i] {
			case .Delete:
				dels += 1
			case .Insert:
				adds += 1
				ci += 1
			case .Equal:
			}
			i += 1
		}
		if adds == 0 {
			git_mark_deletion(marks, hunk_ci)
		} else {
			nmod := min(dels, adds)
			for k in 0 ..< adds {
				marks[hunk_ci + k] = .Modified if k < nmod else .Added
			}
		}
	}
}

git_mark_deletion :: proc(marks: []GitMark, ci: int) {
	idx := clamp(ci - 1, 0, len(marks) - 1)
	if idx >= 0 && marks[idx] == .None {
		marks[idx] = .Deleted
	}
}

GitOp :: enum u8 {
	Equal,
	Delete,
	Insert,
}

git_myers :: proc(a, b: []u64, allocator := context.temp_allocator) -> ([]GitOp, bool) {
	n, m := len(a), len(b)
	maxd := n + m
	offset := maxd
	v := make([]int, 2 * maxd + 1, context.temp_allocator)
	trace := make([dynamic][]int, context.temp_allocator)

	found_d := -1
	search: for d in 0 ..= maxd {
		if d > GIT_DIFF_MAX_D {
			return nil, false
		}
		snapshot := make([]int, 2 * maxd + 1, context.temp_allocator)
		copy(snapshot, v)
		append(&trace, snapshot)

		for k := -d; k <= d; k += 2 {
			x: int
			if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
				x = v[offset + k + 1]
			} else {
				x = v[offset + k - 1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x += 1
				y += 1
			}
			v[offset + k] = x
			if x >= n && y >= m {
				found_d = d
				break search
			}
		}
	}
	if found_d < 0 {
		return nil, false
	}

	ops := make([dynamic]GitOp, allocator)
	x, y := n, m
	for d := found_d; d >= 0; d -= 1 {
		vs := trace[d]
		k := x - y
		prev_k: int
		if k == -d || (k != d && vs[offset + k - 1] < vs[offset + k + 1]) {
			prev_k = k + 1
		} else {
			prev_k = k - 1
		}
		prev_x := vs[offset + prev_k]
		prev_y := prev_x - prev_k
		for x > prev_x && y > prev_y {
			append(&ops, GitOp.Equal)
			x -= 1
			y -= 1
		}
		if d > 0 {
			if x == prev_x {
				append(&ops, GitOp.Insert)
			} else {
				append(&ops, GitOp.Delete)
			}
			x, y = prev_x, prev_y
		}
	}

	for l, r := 0, len(ops) - 1; l < r; l, r = l + 1, r - 1 {
		ops[l], ops[r] = ops[r], ops[l]
	}
	return ops[:], true
}

git_mark_glyph :: proc(m: GitMark) -> (rune, tb2.Color) {
	switch m {
	case .Added:
		return '▌', COLOR_GIT_ADD
	case .Modified:
		return '▌', COLOR_GIT_MOD
	case .Deleted:
		return '▁', COLOR_GIT_DEL
	case .None:
		return ' ', COLOR_GUTTER_FG
	}
	return ' ', COLOR_GUTTER_FG
}

git_mark_at :: proc(b: ^Buffer, row: int) -> GitMark {
	if row < 0 || row >= len(b.git.marks) {
		return .None
	}
	return b.git.marks[row]
}
