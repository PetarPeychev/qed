package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "lib:tb2"

GIT_STAT_POLL_MS :: 2000

g_diff_base: GitBase

GitBase :: struct {
	ref, label: string,
	merge:      bool,
}

git_base_set :: proc(ref, label: string, merge: bool) {
	delete(g_diff_base.ref)
	delete(g_diff_base.label)
	g_diff_base = {}
	if ref != "" {
		g_diff_base = {strings.clone(ref), strings.clone(label), merge}
	}
}

// resolved per command so a moved branch is followed; a repo lacking the ref falls back to HEAD
git_base_rev :: proc(dir: string) -> string {
	if g_diff_base.ref == "" {
		return "HEAD"
	}
	if g_diff_base.merge {
		return fmt.tprintf(`"$(git -C %s merge-base %s HEAD 2>/dev/null || echo HEAD)"`, dir, shell_quote(g_diff_base.ref))
	}
	return fmt.tprintf(`"$(git -C %s rev-parse -q --verify %s 2>/dev/null || echo HEAD)"`, dir, shell_quote(fmt.tprintf("%s^0", g_diff_base.ref)))
}

GitDiffSize :: struct {
	added, deleted: int,
}

GitStat :: struct {
	branch:        string,
	ahead, behind: int,
	diff:          GitDiffSize,
	base:          string,
	base_known:    bool,
	sub:           Subprocess,
	poll:          time.Tick,
}

git_stat_maybe_start :: proc(editor: ^Editor) {
	s := &editor.gitstat
	if s.sub.running || time.duration_milliseconds(time.tick_since(s.poll)) < f64(GIT_STAT_POLL_MS) {
		return
	}
	s.poll = time.tick_now()
	root := editor.working_root
	if root == "" || !module_enabled(.Git) {
		return
	}
	q := shell_quote(root)
	// odin fmt parses {} placeholders, hence {{u}} for a literal @{u}
	cmd := fmt.tprintf(
		"git -C %s symbolic-ref --short -q HEAD 2>/dev/null || git -C %s rev-parse --short HEAD 2>/dev/null || echo; git -C %s rev-list --left-right --count '@{{u}}...HEAD' 2>/dev/null || echo; git -C %s rev-parse -q --verify %s 2>/dev/null || echo; top=$(git -C %s rev-parse --show-toplevel 2>/dev/null) && (%s)",
		q,
		q,
		q,
		q,
		git_base_rev(q),
		q,
		git_diffsize_cmd(`"$top"`),
	)
	sub, serr, ok := subprocess_start(cmd, nil, root)
	if ok {
		s.sub = sub
	} else {
		editor_log(editor, .Debug, "Git", fmt.tprintf("stat spawn failed (%v)", serr))
	}
}

git_stat_running :: proc(editor: ^Editor) -> bool {
	return editor.gitstat.sub.running
}

git_stat_pump :: proc(editor: ^Editor) -> bool {
	s := &editor.gitstat
	if !s.sub.running || !subprocess_drain(&s.sub) {
		return false
	}
	out := subprocess_output(&s.sub)
	branch := ""
	ahead, behind := 0, 0
	lines := strings.split_lines(out, context.temp_allocator)
	if len(lines) > 0 {
		branch = strings.trim_space(lines[0])
	}
	if len(lines) > 1 {
		counts := strings.fields(lines[1], context.temp_allocator)
		if len(counts) == 2 {
			behind, _ = strconv.parse_int(counts[0])
			ahead, _ = strconv.parse_int(counts[1])
		}
	}
	base := ""
	if len(lines) > 2 {
		base = strings.trim_space(lines[2])
	}
	moved := s.base_known && base != s.base
	s.base_known = true
	if moved {
		editor_log(editor, .Debug, "Git", fmt.tprintf("diff base moved to %s", base))
		for &b in editor.buffers {
			git_invalidate(&b)
		}
		if editor.filetree.active {
			filetree_scan_start(editor)
		}
	}
	if base != s.base {
		delete(s.base)
		s.base = strings.clone(base)
	}
	diff := git_diffsize_total(lines)
	changed := moved || branch != s.branch || ahead != s.ahead || behind != s.behind || diff != s.diff
	if changed {
		editor_log(editor, .Debug, "Git", fmt.tprintf("branch %s ahead %d behind %d diff +%d -%d", branch, ahead, behind, diff.added, diff.deleted))
	}
	if branch != s.branch {
		delete(s.branch)
		s.branch = strings.clone(branch)
	}
	s.ahead = ahead
	s.behind = behind
	s.diff = diff
	subprocess_destroy(&s.sub)
	return changed
}

git_stat_reset :: proc(editor: ^Editor) {
	s := &editor.gitstat
	subprocess_kill(&s.sub)
	delete(s.branch)
	s.branch = ""
	s.ahead = 0
	s.behind = 0
	s.diff = {}
	git_stat_base_clear(s)
	s.poll = {}
	git_stat_maybe_start(editor)
}

git_stat_base_clear :: proc(s: ^GitStat) {
	delete(s.base)
	s.base = ""
	s.base_known = false
}

git_base_change :: proc(editor: ^Editor, ref, label: string, merge: bool) {
	git_base_set(ref, label, merge)
	for &b in editor.buffers {
		git_invalidate(&b)
	}
	s := &editor.gitstat
	subprocess_kill(&s.sub)
	git_stat_base_clear(s)
	s.poll = {}
	git_stat_maybe_start(editor)
	filetree_scan_start(editor)
	if editor.filetree.active {
		filetree_preview_touch(editor)
	}
}

// git diff skips untracked files, so grep counts their lines (-I: binaries count 0)
git_diffsize_cmd :: proc(dir: string) -> string {
	return fmt.tprintf(
		"echo @@NUMSTAT@@; git -c core.quotePath=false -C %s diff %s --numstat --find-renames 2>/dev/null; echo @@UNTRACKED@@; (cd %s && git ls-files -o --exclude-standard -z | xargs -0 -r grep -IcH -e '' --) 2>/dev/null",
		dir,
		git_base_rev(dir),
		dir,
	)
}

git_numstat_line :: proc(line: string, untracked: bool) -> (path: string, size: GitDiffSize, ok: bool) {
	if untracked {
		i := strings.last_index_byte(line, ':')
		if i <= 0 {
			return
		}
		n, nok := strconv.parse_int(line[i + 1:])
		if !nok {
			return
		}
		return line[:i], {n, 0}, true
	}
	parts := strings.split_n(line, "\t", 3, context.temp_allocator)
	if len(parts) != 3 {
		return
	}
	a, aok := strconv.parse_int(parts[0])
	d, dok := strconv.parse_int(parts[1])
	if !aok || !dok {
		return
	}
	return git_numstat_path(parts[2]), {a, d}, true
}

// a rename prints `old => new` or `dir/{old => new}/f`; sizes key on the new path
git_numstat_path :: proc(s: string) -> string {
	p := strings.trim(s, "\"")
	arrow := strings.index(p, " => ")
	if arrow < 0 {
		return p
	}
	lb := strings.last_index_byte(p[:arrow], '{')
	rb := strings.index_byte(p[arrow:], '}')
	if lb < 0 || rb < 0 {
		return p[arrow + 4:]
	}
	rb += arrow
	joined := strings.concatenate({p[:lb], p[arrow + 4:rb], p[rb + 1:]}, context.temp_allocator)
	out, _ := strings.replace_all(joined, "//", "/", context.temp_allocator)
	return strings.trim_left(out, "/")
}

git_path_clean :: proc(s: string) -> string {
	return strings.trim_right(strings.trim(strings.trim_space(s), "\""), "/")
}

git_name_status_line :: proc(line: string) -> (path, old: string, mark: GitMark, ok: bool) {
	parts := strings.split(line, "\t", context.temp_allocator)
	if len(parts) < 2 || len(parts[0]) == 0 {
		return
	}
	switch parts[0][0] {
	case 'R':
		if len(parts) != 3 {
			return
		}
		return git_path_clean(parts[2]), git_path_clean(parts[1]), .Modified, true
	case 'D':
		mark = .Deleted
	case 'A':
		mark = .Added
	case:
		mark = .Modified
	}
	path = git_path_clean(parts[1])
	return path, "", mark, path != ""
}

git_porcelain_line :: proc(line: string) -> (path, old: string, mark: GitMark, ok: bool) {
	if len(line) < 4 {
		return
	}
	code := line[:2]
	rel := line[3:]
	if idx := strings.index(rel, " -> "); idx >= 0 {
		old = git_path_clean(rel[:idx])
		rel = rel[idx + 4:]
	}
	path = git_path_clean(rel)
	if path == "" {
		return
	}
	x, y := code[0], code[1]
	switch {
	case code == "??":
		mark = .Added
	case code == "!!":
		mark = .None
	case x == 'A' && y == 'D':
		return
	case x == 'R' && y == 'D':
		path, mark = old, .Deleted
	case x == 'D' || y == 'D':
		mark = .Deleted
	case x == 'R':
		return path, old, .Modified, true
	case x == 'A' || y == 'A':
		mark = .Added
	case:
		mark = .Modified
	}
	return path, "", mark, path != ""
}

git_diffsize_total :: proc(lines: []string) -> (total: GitDiffSize) {
	section := ""
	for line in lines {
		if line == "@@NUMSTAT@@" || line == "@@UNTRACKED@@" {
			section = line
			continue
		}
		if section == "" {
			continue
		}
		if _, size, ok := git_numstat_line(line, section == "@@UNTRACKED@@"); ok {
			total.added += size.added
			total.deleted += size.deleted
		}
	}
	return
}

git_diffsize_label :: proc(s: GitDiffSize) -> string {
	if s.added == 0 && s.deleted == 0 {
		return ""
	}
	return fmt.tprintf("+%d -%d", s.added, s.deleted)
}

git_diffsize_paint :: proc(x, y, max_x: int, label: string, bg: tb2.Color) {
	fg := COLOR_GIT_ADD
	for i in 0 ..< len(label) {
		if x + i >= max_x {
			return
		}
		if label[i] == '-' {
			fg = COLOR_GIT_DEL
		}
		tb2.set_cell(i32(x + i), i32(y), rune(label[i]), fg, bg)
	}
}

git_stat_destroy :: proc(s: ^GitStat) {
	subprocess_kill(&s.sub)
	delete(s.branch)
	delete(s.base)
}

git_module_sync :: proc(editor: ^Editor) {
	if module_enabled(.Git) {
		return
	}
	for &b in editor.buffers {
		if b.base.source == .Plugin {
			continue
		}
		g := &b.base
		clear(&g.marks)
		clear(&g.above)
		clear(&g.below)
		clear(&g.hunks)
		clear(&g.changes)
		git_invalidate(&b)
	}
	s := &editor.gitstat
	if s.branch != "" {
		delete(s.branch)
		s.branch = ""
	}
	s.ahead = 0
	s.behind = 0
	if editor.filetree.scope == .Git {
		editor.filetree.scope = .All
		if editor.filetree.active {
			filetree_rebuild(editor)
		}
	}
}

git_invalidate :: proc(b: ^Buffer) {
	if b.base.source != .Plugin {
		b.base.tried = false
	}
	b.base.computed = false
}

git_base_fetch :: proc(b: ^Buffer) {
	diffbase_clear(b)
	b.base.tried = true
	if b.path == "" || !module_enabled(.Git) {
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
	qdir := shell_quote(dir)
	show_cmd := fmt.ctprintf("git -C %s show %s:./%s 2>/dev/null", qdir, git_base_rev(qdir), shell_quote(name))
	blob, _ := shell_capture(show_cmd)
	diffbase_set(b, blob, .Git)
}

git_diff_file :: proc(
	path: string,
	old_path := "",
) -> (
	base_text: []string,
	cur: []string,
	marks: []GitMark,
	hunks: []GitHunk,
	ok: bool,
) {
	if path == "" || !module_enabled(.Git) {
		return
	}
	data: []u8
	if os.exists(path) {
		d, derr := os.read_entire_file(path, context.temp_allocator)
		if derr != nil || len(d) > BIG_FILE_BYTES {
			return
		}
		data = d
	}

	dir, rel := git_path_anchor(old_path if old_path != "" else path)
	qdir := shell_quote(dir)
	show_cmd := fmt.ctprintf("git -C %s show %s:./%s 2>/dev/null", qdir, git_base_rev(qdir), shell_quote(rel))
	blob, _ := shell_capture(show_cmd)

	bt := git_split_lines(blob)
	cl := git_split_lines(string(data))

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

// a deleted or renamed path's own dir may be gone, so git runs from its nearest existing ancestor
git_path_anchor :: proc(path: string) -> (dir, rel: string) {
	dir = filetree_parent_dir(path)
	for !os.is_dir(dir) {
		np := filetree_parent_dir(dir)
		if np == dir {
			break
		}
		dir = np
	}
	if len(path) > len(dir) + 1 {
		rel = path[len(dir) + 1:]
	}
	return
}

// a staged deletion has no index entry; restoring the worktree alone would leave the file untracked
git_restore :: proc(path: string) -> bool {
	if !module_enabled(.Git) {
		return false
	}
	dir, rel := git_path_anchor(path)
	qdir := shell_quote(dir)
	qrel := shell_quote(rel)
	rev := git_base_rev(qdir)
	cmd := fmt.ctprintf(
		"cd %s && if git --literal-pathspecs ls-files --error-unmatch -- %s >/dev/null 2>&1; then git --literal-pathspecs restore --source=%s --worktree -- %s; else git --literal-pathspecs restore --source=%s --staged --worktree -- %s; fi >/dev/null 2>&1 && echo ok",
		qdir,
		qrel,
		rev,
		qrel,
		rev,
		qrel,
	)
	out, _ := shell_capture(cmd)
	return strings.trim_space(out) == "ok"
}
