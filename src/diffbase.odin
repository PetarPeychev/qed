package main

import "core:fmt"
import "core:hash"
import "core:strings"
import "lib:tb2"

DIFF_MAX_D :: 2000

g_diff_view: bool

DiffView :: enum u8 {
	Global,
	Inline,
	Changes,
}

DiffMark :: enum u8 {
	None,
	Added,
	Modified,
	Deleted,
}

DiffHunk :: struct {
	row:    int,
	above:  bool,
	lo, hi: int,
	new_n:  int,
}

DiffChange :: struct {
	new_lo, new_hi: int,
	old_lo, old_hi: int,
}

DiffBaseSlot :: struct {
	owner, label, text: string,
	none:               bool,
}

DiffBase :: struct {
	slots:     [dynamic]DiffBaseSlot,
	base:      [dynamic]u64,
	base_text: [dynamic]string,
	computed:  bool,
	rev:       u64,
	marks:     [dynamic]DiffMark,
	above:     [dynamic]int,
	below:     [dynamic]int,
	hunks:     [dynamic]DiffHunk,
	changes:   [dynamic]DiffChange,
	shown:     [dynamic]bool,
	shown_ctx: int,
	first:     int,
}

diffbase_destroy :: proc(g: ^DiffBase) {
	for s in g.slots {
		delete(s.label)
		delete(s.text)
	}
	delete(g.slots)
	delete(g.base)
	delete(g.base_text)
	delete(g.marks)
	delete(g.above)
	delete(g.below)
	delete(g.hunks)
	delete(g.changes)
	delete(g.shown)
}

diff_hash :: proc(bytes: []u8) -> u64 {
	return hash.fnv64a(bytes)
}

diffbase_active :: proc(b: ^Buffer) -> ^DiffBaseSlot {
	#reverse for &s in b.base.slots {
		if !s.none {
			return &s
		}
	}
	return nil
}

diffbase_owner :: proc(b: ^Buffer) -> string {
	s := diffbase_active(b)
	return s.owner if s != nil else ""
}

diffbase_rebuild :: proc(b: ^Buffer) {
	g := &b.base
	g.computed = false
	clear(&g.base)
	clear(&g.base_text)
	s := diffbase_active(b)
	if s == nil || s.text == "" {
		return
	}
	for segment in strings.split(s.text, "\n", context.temp_allocator) {
		line := segment
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		append(&g.base, diff_hash(transmute([]u8)line))
		append(&g.base_text, line)
	}
}

// Each owner keeps its slot in first-set order (a cleared one stays as `none`), so a later plugin's base stays on top while an earlier one updates beneath it.
diffbase_set :: proc(b: ^Buffer, owner, text: string, label := "") {
	slot: ^DiffBaseSlot
	for &s in b.base.slots {
		if s.owner == owner {
			slot = &s
		}
	}
	if slot == nil {
		append(&b.base.slots, DiffBaseSlot{owner = owner})
		slot = &b.base.slots[len(b.base.slots) - 1]
	}
	delete(slot.label)
	delete(slot.text)
	slot.label = strings.clone(label)
	slot.text = strings.clone(text)
	slot.none = false
	diffbase_rebuild(b)
}

diffbase_clear :: proc(b: ^Buffer, owner: string) {
	for &s in b.base.slots {
		if s.owner == owner && !s.none {
			delete(s.label)
			delete(s.text)
			s.label, s.text, s.none = "", "", true
			diffbase_rebuild(b)
		}
	}
}

diffbase_invalidate :: proc(b: ^Buffer) {
	b.base.computed = false
}

diffbase_update :: proc(b: ^Buffer) {
	g := &b.base
	shown_ctx := PREVIEW_DIFF_CONTEXT if b.diff_view == .Changes else -1
	if g.computed && g.rev == b.rev && g.shown_ctx == shown_ctx {
		return
	}
	diffbase_recompute(b)
	diffbase_elide(b, shown_ctx)
	g.computed = true
	g.rev = b.rev
}

// diff view `.Changes` shows only the changed rows and shown_ctx rows around them; a diff with no change shows all
diffbase_elide :: proc(b: ^Buffer, shown_ctx: int) {
	g := &b.base
	g.shown_ctx = shown_ctx
	g.first = 0
	clear(&g.shown)
	if shown_ctx < 0 || len(g.changes) == 0 {
		return
	}
	resize(&g.shown, len(b.lines))
	for i in 0 ..< len(b.lines) {
		g.shown[i] = false
	}
	for mark, row in g.marks {
		if mark != .None {
			for i in max(0, row - shown_ctx) ..= min(len(g.shown) - 1, row + shown_ctx) {
				g.shown[i] = true
			}
		}
	}
	g.first = row_shown_next(b, 0)
}

row_shown :: proc(b: ^Buffer, row: int) -> bool {
	return row < 0 || row >= len(b.base.shown) || b.base.shown[row]
}

// the first shown row at or after row; len(b.lines) when none
row_shown_next :: proc(b: ^Buffer, row: int) -> int {
	row := max(row, 0)
	for row < len(b.lines) && !row_shown(b, row) {
		row += 1
	}
	return row
}

// the last shown row at or before row; -1 when none
row_shown_prev :: proc(b: ^Buffer, row: int) -> int {
	row := min(row, len(b.lines) - 1)
	for row >= 0 && !row_shown(b, row) {
		row -= 1
	}
	return row
}

row_shown_near :: proc(b: ^Buffer, row: int) -> int {
	next := row_shown_next(b, row)
	return next if next < len(b.lines) else max(row_shown_prev(b, row), 0)
}

// count shown rows from row, clamped at either end
row_shown_step :: proc(b: ^Buffer, row, count: int) -> int {
	row := row
	for _ in 0 ..< abs(count) {
		next := row_shown_next(b, row + 1) if count > 0 else row_shown_prev(b, row - 1)
		if next < 0 || next >= len(b.lines) {
			break
		}
		row = next
	}
	return row
}

// one gap row stands for each run of hidden rows between two shown ones
diff_gap_above :: proc(b: ^Buffer, row: int) -> int {
	g := &b.base
	if row <= g.first || row >= len(g.shown) || !g.shown[row] || g.shown[row - 1] {
		return 0
	}
	return 1
}

diffbase_unload :: proc(editor: ^Editor, owner: string) {
	for &b in editor.buffers {
		for s, i in b.base.slots {
			if s.owner == owner {
				delete(s.label)
				delete(s.text)
				ordered_remove(&b.base.slots, i)
				diffbase_rebuild(&b)
				break
			}
		}
	}
}

diffbase_recompute :: proc(b: ^Buffer) {
	g := &b.base
	resize(&g.marks, len(b.lines))
	resize(&g.above, len(b.lines))
	resize(&g.below, len(b.lines))
	for i in 0 ..< len(b.lines) {
		g.marks[i] = .None
		g.above[i] = 0
		g.below[i] = 0
	}
	clear(&g.hunks)
	clear(&g.changes)
	if diffbase_active(b) == nil {
		return
	}

	cur := make([dynamic]u64, 0, len(b.lines), context.temp_allocator)
	for line in b.lines {
		append(&cur, diff_hash(line.text[:]))
	}
	diff_lines(g.base[:], cur[:], g.marks[:], &g.hunks, &g.changes)

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

diff_change_add :: proc(changes: ^[dynamic]DiffChange, new_lo, new_hi, old_lo, old_hi: int) {
	if changes != nil {
		append(changes, DiffChange{new_lo, new_hi, old_lo, old_hi})
	}
}

diff_lines :: proc(base, cur: []u64, marks: []DiffMark, hunks: ^[dynamic]DiffHunk, changes: ^[dynamic]DiffChange = nil) {
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
		diff_change_add(changes, lo, hi_cur, hi_base, hi_base)
		return
	}
	if len(new_lines) == 0 {
		diff_mark_deletion(marks, lo)
		diff_hunk_deletion(hunks, lo, len(marks), lo, hi_base)
		diff_change_add(changes, lo, lo, lo, hi_base)
		return
	}

	ops, ok := diff_myers(old_lines, new_lines)
	if !ok {
		nmod := min(len(old_lines), len(new_lines))
		for k in 0 ..< len(new_lines) {
			marks[lo + k] = .Modified if k < nmod else .Added
		}
		append(hunks, DiffHunk{row = lo, above = true, lo = lo, hi = hi_base, new_n = len(new_lines)})
		diff_change_add(changes, lo, hi_cur, lo, hi_base)
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
		diff_change_add(changes, hunk_ci, hunk_ci + adds, hunk_bi, hunk_bi + dels)
		if adds == 0 {
			diff_mark_deletion(marks, hunk_ci)
			diff_hunk_deletion(hunks, hunk_ci, len(marks), hunk_bi, hunk_bi + dels)
		} else {
			nmod := min(dels, adds)
			for k in 0 ..< adds {
				marks[hunk_ci + k] = .Modified if k < nmod else .Added
			}
			if dels > 0 {
				append(hunks, DiffHunk{row = hunk_ci, above = true, lo = hunk_bi, hi = hunk_bi + dels, new_n = adds})
			}
		}
	}
}

diff_mark_deletion :: proc(marks: []DiffMark, ci: int) {
	idx := clamp(ci - 1, 0, len(marks) - 1)
	if idx >= 0 && marks[idx] == .None {
		marks[idx] = .Deleted
	}
}

// a deletion at the file top has no line before the gap, so it renders above row 0
diff_hunk_deletion :: proc(hunks: ^[dynamic]DiffHunk, ci, nrows, lo, hi: int) {
	if lo >= hi || nrows == 0 {
		return
	}
	if ci <= 0 {
		append(hunks, DiffHunk{row = 0, above = true, lo = lo, hi = hi, new_n = 0})
	} else {
		append(hunks, DiffHunk{row = clamp(ci - 1, 0, nrows - 1), above = false, lo = lo, hi = hi, new_n = 0})
	}
}

DiffOp :: enum u8 {
	Equal,
	Delete,
	Insert,
}

diff_myers :: proc(a, b: []u64, allocator := context.temp_allocator, max_d := DIFF_MAX_D) -> ([]DiffOp, bool) {
	n, m := len(a), len(b)
	if n == 0 && m == 0 {
		return {}, true
	}
	maxd := n + m
	// k stays within ±d ≤ ±cap_d, so v only needs the capped span, not n+m.
	cap_d := min(maxd, max_d)
	offset := cap_d
	v := make([]int, 2 * cap_d + 1, context.temp_allocator)
	// round d's backtrack reads only k in [-d-1, d+1], so each snapshot keeps just that window
	Snap :: struct {
		base: int,
		v:    []int,
	}
	trace := make([dynamic]Snap, context.temp_allocator)

	found_d := -1
	search: for d in 0 ..= maxd {
		if d > max_d {
			return nil, false
		}
		lo, hi := max(offset - d - 1, 0), min(offset + d + 1, 2 * cap_d)
		snapshot := make([]int, hi - lo + 1, context.temp_allocator)
		copy(snapshot, v[lo:hi + 1])
		append(&trace, Snap{lo, snapshot})

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

	ops := make([dynamic]DiffOp, allocator)
	x, y := n, m
	for d := found_d; d >= 0; d -= 1 {
		vs := trace[d].v
		at := offset - trace[d].base
		k := x - y
		prev_k: int
		if k == -d || (k != d && vs[at + k - 1] < vs[at + k + 1]) {
			prev_k = k + 1
		} else {
			prev_k = k - 1
		}
		prev_x := vs[at + prev_k]
		prev_y := prev_x - prev_k
		for x > prev_x && y > prev_y {
			append(&ops, DiffOp.Equal)
			x -= 1
			y -= 1
		}
		if d > 0 {
			if x == prev_x {
				append(&ops, DiffOp.Insert)
			} else {
				append(&ops, DiffOp.Delete)
			}
			x, y = prev_x, prev_y
		}
	}

	for l, r := 0, len(ops) - 1; l < r; l, r = l + 1, r - 1 {
		ops[l], ops[r] = ops[r], ops[l]
	}
	return ops[:], true
}

// an Equal op on differing text (a hash collision) counts as a change
diff_runs :: proc(ops: []DiffOp, a, b: []string) -> [][4]int {
	out := make([dynamic][4]int, context.temp_allocator)
	ai, bi, i := 0, 0, 0
	same :: proc(op: DiffOp, a, b: []string, ai, bi: int) -> bool {
		return op == .Equal && a[ai] == b[bi]
	}
	for i < len(ops) {
		if same(ops[i], a, b, ai, bi) {
			ai += 1
			bi += 1
			i += 1
			continue
		}
		h := [4]int{ai, 0, bi, 0}
		for i < len(ops) && !same(ops[i], a, b, ai, bi) {
			if ops[i] != .Insert {
				h[1] += 1
				ai += 1
			}
			if ops[i] != .Delete {
				h[3] += 1
				bi += 1
			}
			i += 1
		}
		append(&out, h)
	}
	return out[:]
}

diffbase_goto :: proc(editor: ^Editor, dir: int) {
	b := editor_buffer(editor)
	diffbase_update(b)
	marks := b.base.marks[:]
	any, next, prev := false, -1, -1
	for row in 0 ..< len(marks) {
		if marks[row] == .None || (row > 0 && marks[row - 1] != .None) {
			continue
		}
		any = true
		if row > b.cursor.row && next < 0 {
			next = row
		}
		if row < b.cursor.row {
			prev = row
		}
	}
	if !any {
		editor_log(editor, .Info, "Diff", "No changes")
		return
	}
	target := next if dir > 0 else prev
	if target < 0 {
		editor_log(editor, .Info, "Diff", "No next change" if dir > 0 else "No previous change")
		return
	}
	editor_goto(editor, target, 0)
}

// a pure deletion has no row of its own; its glyph sits on the line before the gap (row 0 at the top)
diff_change_touched :: proc(c: DiffChange, r0, r1: int) -> bool {
	if c.new_lo < c.new_hi {
		return c.new_lo <= r1 && c.new_hi > r0
	}
	anchor := c.new_lo - 1 if c.new_lo > 0 else 0
	return anchor >= r0 && anchor <= r1
}

diffbase_revert_change :: proc(b: ^Buffer, g: ^DiffBase, c: DiffChange) {
	lo := clamp(c.old_lo, 0, len(g.base_text))
	hi := clamp(c.old_hi, 0, len(g.base_text))
	base := g.base_text[lo:hi]
	joined := strings.join(base, "\n", context.temp_allocator)
	n := len(b.lines)

	if c.new_lo < c.new_hi {
		if c.new_hi < n {
			at := Cursor{c.new_lo, 0}
			edit_delete(b, at, {c.new_hi, 0})
			if len(base) > 0 {
				edit_insert(b, at, strings.concatenate({joined, "\n"}, context.temp_allocator))
			}
			return
		}
		// the last row has no trailing newline, so take the one before it and lead the base lines with it
		at := Cursor{0, 0}
		if c.new_lo > 0 {
			at = {c.new_lo - 1, len(b.lines[c.new_lo - 1].text)}
		}
		edit_delete(b, at, {n - 1, len(b.lines[n - 1].text)})
		if len(base) > 0 {
			text := joined
			if c.new_lo > 0 {
				text = strings.concatenate({"\n", joined}, context.temp_allocator)
			}
			edit_insert(b, at, text)
		}
		return
	}

	if len(base) == 0 {
		return
	}
	if c.new_lo < n {
		edit_insert(b, {c.new_lo, 0}, strings.concatenate({joined, "\n"}, context.temp_allocator))
	} else {
		edit_insert(b, {n - 1, len(b.lines[n - 1].text)}, strings.concatenate({"\n", joined}, context.temp_allocator))
	}
}

diffbase_revert :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if b.big {
		editor_log(editor, .Info, "Diff", "Disabled for big files")
		return
	}
	diffbase_update(b)
	g := &b.base
	if diffbase_active(b) == nil {
		editor_log(editor, .Info, "Diff", "No diff base")
		return
	}

	r0, r1 := b.cursor.row, b.cursor.row
	if from, to, ok := selection_range(b); ok {
		r0 = from.row
		r1 = selection_last_row(from, to)
	}

	count, top := 0, 0
	for c in g.changes {
		if diff_change_touched(c, r0, r1) {
			if count == 0 {
				top = c.new_lo
			}
			count += 1
		}
	}
	if count == 0 {
		editor_log(editor, .Info, "Diff", "No change under cursor")
		return
	}

	// Apply bottom-up so an earlier revert can't shift a later change's rows.
	edit_open(b, .Atomic)
	#reverse for c in g.changes {
		if diff_change_touched(c, r0, r1) {
			diffbase_revert_change(b, g, c)
		}
	}
	buffer_undo_commit(b)

	b.selection = nil
	b.cursor = {clamp(top, 0, len(b.lines) - 1), 0}
	cursor_goal_sync(b)
	editor_log(editor, .Info, "Diff", fmt.tprintf("Reverted %d hunk%s", count, "" if count == 1 else "s"))
}

diff_mark_glyph :: proc(m: DiffMark) -> (rune, tb2.Color) {
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

diff_mark_at :: proc(b: ^Buffer, row: int) -> DiffMark {
	if row < 0 || row >= len(b.base.marks) {
		return .None
	}
	return b.base.marks[row]
}

diff_view_on :: proc(b: ^Buffer) -> bool {
	return g_diff_view || b.diff_view != .Global
}

diff_above :: proc(b: ^Buffer, row: int) -> int {
	if !diff_view_on(b) || row < 0 || row >= len(b.base.above) {
		return 0
	}
	return b.base.above[row]
}

diff_below :: proc(b: ^Buffer, row: int) -> int {
	if !diff_view_on(b) || row < 0 || row >= len(b.base.below) {
		return 0
	}
	return b.base.below[row]
}

diff_hunk_at :: proc(b: ^Buffer, row: int, above: bool) -> (DiffHunk, bool) {
	if !diff_view_on(b) {
		return {}, false
	}
	for h in b.base.hunks {
		if h.row == row && h.above == above {
			return h, true
		}
	}
	return {}, false
}

diff_pair_old :: proc(b: ^Buffer, row: int) -> (string, bool) {
	if !diff_view_on(b) {
		return "", false
	}
	for h in b.base.hunks {
		if !h.above || h.new_n == 0 {
			continue
		}
		off := row - h.row
		if off >= 0 && off < h.new_n && h.lo + off < h.hi {
			return b.base.base_text[h.lo + off], true
		}
	}
	return "", false
}

diff_word_span :: proc(old, new: string) -> (old_span, new_span: [2]int) {
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
