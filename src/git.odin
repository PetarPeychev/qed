package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "lib:tb2"

g_diff_view: bool

GitMark :: enum u8 {
	None,
	Added,
	Modified,
	Deleted,
}

// One changed region: `old` lines (base_text[lo:hi]) shown as ghost text.
// `above` renders them above `row` (modification), else below it (pure deletion).
// `new_n` is the count of current rows starting at `row` paired for word diff.
GitHunk :: struct {
	row:    int,
	above:  bool,
	lo, hi: int,
	new_n:  int,
}

GitGutter :: struct {
	tried:     bool,
	enabled:   bool,
	blob:      string,
	base:      [dynamic]u64,
	base_text: [dynamic]string,
	computed:  bool,
	rev:       u64,
	marks:     [dynamic]GitMark,
	above:     [dynamic]int,
	below:     [dynamic]int,
	hunks:     [dynamic]GitHunk,
}

git_destroy :: proc(g: ^GitGutter) {
	delete(g.base)
	delete(g.base_text)
	delete(g.marks)
	delete(g.above)
	delete(g.below)
	delete(g.hunks)
	if g.blob != "" {
		delete(g.blob)
	}
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
	clear(&g.base_text)
	if g.blob != "" {
		delete(g.blob)
		g.blob = ""
	}

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
	blob, blob_ok := shell_capture(show_cmd, os.heap_allocator())
	if !blob_ok || len(blob) == 0 {
		if blob_ok {
			delete(blob)
		}
		return
	}
	g.blob = blob

	for segment in strings.split(blob, "\n", context.temp_allocator) {
		s := segment
		if len(s) > 0 && s[len(s) - 1] == '\r' {
			s = s[:len(s) - 1]
		}
		append(&g.base, git_hash(transmute([]u8)s))
		append(&g.base_text, s)
	}
}

git_recompute :: proc(b: ^Buffer) {
	g := &b.git
	resize(&g.marks, len(b.lines))
	resize(&g.above, len(b.lines))
	resize(&g.below, len(b.lines))
	for i in 0 ..< len(b.lines) {
		g.marks[i] = .None
		g.above[i] = 0
		g.below[i] = 0
	}
	clear(&g.hunks)
	if !g.enabled {
		return
	}

	cur := make([dynamic]u64, 0, len(b.lines), context.temp_allocator)
	for line in b.lines {
		append(&cur, git_hash(line.text[:]))
	}
	git_diff(g.base[:], cur[:], g.marks[:], &g.hunks)

	for h in g.hunks {
		n := h.hi - h.lo
		if h.row < 0 || h.row >= len(b.lines) {
			continue
		}
		if h.above {
			g.above[h.row] += n
		} else {
			g.below[h.row] += n
		}
	}
}

git_diff :: proc(base, cur: []u64, marks: []GitMark, hunks: ^[dynamic]GitHunk) {
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
		git_hunk_deletion(hunks, lo, len(marks), lo, hi_base)
		return
	}

	ops, ok := git_myers(old_lines, new_lines)
	if !ok {
		nmod := min(len(old_lines), len(new_lines))
		for k in 0 ..< len(new_lines) {
			marks[lo + k] = .Modified if k < nmod else .Added
		}
		append(hunks, GitHunk{row = lo, above = true, lo = lo, hi = hi_base, new_n = len(new_lines)})
		return
	}

	ci, bi := lo, lo
	i := 0
	for i < len(ops) {
		if ops[i] == .Equal {
			ci += 1
			bi += 1
			i += 1
			continue
		}
		dels, adds := 0, 0
		hunk_ci, hunk_bi := ci, bi
		for i < len(ops) && ops[i] != .Equal {
			switch ops[i] {
			case .Delete:
				dels += 1
				bi += 1
			case .Insert:
				adds += 1
				ci += 1
			case .Equal:
			}
			i += 1
		}
		if adds == 0 {
			git_mark_deletion(marks, hunk_ci)
			git_hunk_deletion(hunks, hunk_ci, len(marks), hunk_bi, hunk_bi + dels)
		} else {
			nmod := min(dels, adds)
			for k in 0 ..< adds {
				marks[hunk_ci + k] = .Modified if k < nmod else .Added
			}
			if dels > 0 {
				append(hunks, GitHunk{row = hunk_ci, above = true, lo = hunk_bi, hi = hunk_bi + dels, new_n = adds})
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

// Deleted old lines render below the line before the gap; if the gap is at the
// file top (ci == 0), there is no such line, so render them above row 0 instead.
git_hunk_deletion :: proc(hunks: ^[dynamic]GitHunk, ci, nrows, lo, hi: int) {
	if lo >= hi || nrows == 0 {
		return
	}
	if ci <= 0 {
		append(hunks, GitHunk{row = 0, above = true, lo = lo, hi = hi, new_n = 0})
	} else {
		append(hunks, GitHunk{row = clamp(ci - 1, 0, nrows - 1), above = false, lo = lo, hi = hi, new_n = 0})
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

git_above :: proc(b: ^Buffer, row: int) -> int {
	if !g_diff_view || row < 0 || row >= len(b.git.above) {
		return 0
	}
	return b.git.above[row]
}

git_below :: proc(b: ^Buffer, row: int) -> int {
	if !g_diff_view || row < 0 || row >= len(b.git.below) {
		return 0
	}
	return b.git.below[row]
}

// The hunk whose old lines render above/below `row` (nil if none).
git_hunk_at :: proc(b: ^Buffer, row: int, above: bool) -> (GitHunk, bool) {
	if !g_diff_view {
		return {}, false
	}
	for h in b.git.hunks {
		if h.row == row && h.above == above {
			return h, true
		}
	}
	return {}, false
}

// For a live (current-buffer) row inside a modification, the base line it is
// paired with for word-level diffing.
git_pair_old :: proc(b: ^Buffer, row: int) -> (string, bool) {
	if !g_diff_view {
		return "", false
	}
	for h in b.git.hunks {
		if !h.above || h.new_n == 0 {
			continue
		}
		off := row - h.row
		if off >= 0 && off < h.new_n && h.lo + off < h.hi {
			return b.git.base_text[h.lo + off], true
		}
	}
	return "", false
}

// Changed byte span [from,to) in each of `old` and `new` after trimming the
// common prefix and suffix (rune-boundary safe). from==to means no change.
git_word_span :: proc(old, new: string) -> (old_span, new_span: [2]int) {
	p := 0
	for p < len(old) && p < len(new) && old[p] == new[p] {
		p += 1
	}
	for p > 0 && p < len(old) && p < len(new) && (is_utf8_cont(old[p]) || is_utf8_cont(new[p])) {
		p -= 1
	}
	so, sn := len(old), len(new)
	for so > p && sn > p && old[so - 1] == new[sn - 1] {
		so -= 1
		sn -= 1
	}
	for so < len(old) && is_utf8_cont(old[so]) {
		so += 1
	}
	for sn < len(new) && is_utf8_cont(new[sn]) {
		sn += 1
	}
	return {p, so}, {p, sn}
}

is_utf8_cont :: proc(c: u8) -> bool {
	return c & 0xc0 == 0x80
}

git_split_lines :: proc(s: string, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	if len(s) == 0 {
		return out
	}
	for seg in strings.split(s, "\n", allocator) {
		t := seg
		if len(t) > 0 && t[len(t) - 1] == '\r' {
			t = t[:len(t) - 1]
		}
		append(&out, t)
	}
	if len(out) > 0 && out[len(out) - 1] == "" {
		pop(&out)
	}
	return out
}

// HEAD-vs-worktree diff for an arbitrary file (not an open buffer). Reuses the
// gutter's line-hash diff so a preview renders identically to the inline diff view.
git_diff_file :: proc(
	path: string,
) -> (
	base_text: []string,
	cur: []string,
	marks: []GitMark,
	hunks: []GitHunk,
	ok: bool,
) {
	if path == "" || !shell_command_exists("git") {
		return
	}
	data, derr := os.read_entire_file(path, context.temp_allocator)
	if derr != nil || len(data) > BIG_FILE_BYTES {
		return
	}

	slash := strings.last_index_byte(path, '/')
	dir := path[:slash] if slash >= 0 else "."
	name := path[slash + 1:] if slash >= 0 else path
	show_cmd := fmt.ctprintf("git -C %s show HEAD:./%s 2>/dev/null", shell_quote(dir), shell_quote(name))
	blob, _ := shell_capture(show_cmd)

	bt := git_split_lines(blob)
	cl := git_split_lines(string(data))
	if len(cl) > PREVIEW_MAX_LINES {
		resize(&cl, PREVIEW_MAX_LINES)
	}

	bh := make([dynamic]u64, 0, len(bt), context.temp_allocator)
	for s in bt {
		append(&bh, git_hash(transmute([]u8)s))
	}
	ch := make([dynamic]u64, 0, len(cl), context.temp_allocator)
	for s in cl {
		append(&ch, git_hash(transmute([]u8)s))
	}

	m := make([]GitMark, len(cl), context.temp_allocator)
	hk := make([dynamic]GitHunk, context.temp_allocator)
	git_diff(bh[:], ch[:], m, &hk)
	return bt[:], cl[:], m, hk[:], true
}
