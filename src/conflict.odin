package main

import "lib:tb2"

MergeSide :: enum u8 {
	None,
	Ours,
	Base,
	Theirs,
}

// Row spans of one merge-conflict block. `base` is -1 unless the file uses the
// diff3 style (a ||||||| section between ours and =======).
MergeConflict :: struct {
	start: int, // <<<<<<<
	base:  int, // |||||||  (-1 if absent)
	sep:   int, // =======
	end:   int, // >>>>>>>
}

MergeKeep :: enum {
	Ours,
	Theirs,
	Both,
}

merge_marker :: proc(line: []u8, ch: u8) -> bool {
	if len(line) < 7 {
		return false
	}
	for i in 0 ..< 7 {
		if line[i] != ch {
			return false
		}
	}
	return len(line) == 7 || line[7] == ' '
}

merge_scan :: proc(b: ^Buffer, allocator := context.temp_allocator) -> []MergeConflict {
	out := make([dynamic]MergeConflict, allocator)
	i := 0
	for i < len(b.lines) {
		if merge_marker(b.lines[i].text[:], '<') {
			c := MergeConflict{start = i, base = -1, sep = -1, end = -1}
			for j := i + 1; j < len(b.lines); j += 1 {
				line := b.lines[j].text[:]
				if merge_marker(line, '<') {
					break
				}
				if merge_marker(line, '>') {
					c.end = j
					break
				}
				if c.sep < 0 && c.base < 0 && merge_marker(line, '|') {
					c.base = j
				} else if c.sep < 0 && merge_marker(line, '=') {
					c.sep = j
				}
			}
			if c.sep >= 0 && c.end >= 0 && c.sep < c.end {
				append(&out, c)
				i = c.end + 1
				continue
			}
		}
		i += 1
	}
	return out[:]
}

merge_side :: proc(conflicts: []MergeConflict, row: int) -> (MergeSide, bool) {
	for c in conflicts {
		if row < c.start || row > c.end {
			continue
		}
		if row == c.start {
			return .Ours, true
		}
		if row == c.end || row == c.sep {
			return .Theirs, true
		}
		if c.base >= 0 && row == c.base {
			return .Base, true
		}
		ours_hi := c.base if c.base >= 0 else c.sep
		if row < ours_hi {
			return .Ours, false
		}
		if c.base >= 0 && row < c.sep {
			return .Base, false
		}
		return .Theirs, false
	}
	return .None, false
}

merge_side_color :: proc(side: MergeSide) -> tb2.Color {
	#partial switch side {
	case .Ours:
		return COLOR_CONFLICT_OURS
	case .Theirs:
		return COLOR_CONFLICT_THEIRS
	case .Base:
		return COLOR_CONFLICT_BASE
	}
	return COLOR_FG
}

// Row -> changed byte span [from,to) on that line, for the ours/theirs lines that
// pair up as modifications. Reuses the git line-diff + word-diff machinery.
merge_word_map :: proc(b: ^Buffer, conflicts: []MergeConflict, allocator := context.temp_allocator) -> map[int][2]int {
	m := make(map[int][2]int, allocator)
	for c in conflicts {
		ours_lo := c.start + 1
		ours_hi := c.base if c.base >= 0 else c.sep
		theirs_lo := c.sep + 1
		theirs_hi := c.end
		no := ours_hi - ours_lo
		nt := theirs_hi - theirs_lo
		if no <= 0 || nt <= 0 {
			continue
		}
		oh := make([]u64, no, context.temp_allocator)
		th := make([]u64, nt, context.temp_allocator)
		for k in 0 ..< no {
			oh[k] = git_hash(b.lines[ours_lo + k].text[:])
		}
		for k in 0 ..< nt {
			th[k] = git_hash(b.lines[theirs_lo + k].text[:])
		}
		ops, ok := git_myers(oh, th)
		if !ok {
			continue
		}
		oi, ti, i := ours_lo, theirs_lo, 0
		for i < len(ops) {
			if ops[i] == .Equal {
				oi += 1
				ti += 1
				i += 1
				continue
			}
			dels, adds, run_o, run_t := 0, 0, oi, ti
			for i < len(ops) && ops[i] != .Equal {
				#partial switch ops[i] {
				case .Delete:
					dels += 1
					oi += 1
				case .Insert:
					adds += 1
					ti += 1
				}
				i += 1
			}
			for k in 0 ..< min(dels, adds) {
				os := string(b.lines[run_o + k].text[:])
				ts := string(b.lines[run_t + k].text[:])
				osp, tsp := git_word_span(os, ts)
				if osp[0] != osp[1] {
					m[run_o + k] = osp
				}
				if tsp[0] != tsp[1] {
					m[run_t + k] = tsp
				}
			}
		}
	}
	return m
}

merge_at :: proc(conflicts: []MergeConflict, row: int) -> (MergeConflict, bool) {
	for c in conflicts {
		if row >= c.start && row <= c.end {
			return c, true
		}
	}
	return {}, false
}

merge_next :: proc(conflicts: []MergeConflict, row: int) -> (int, bool) {
	if len(conflicts) == 0 {
		return 0, false
	}
	for c in conflicts {
		if c.start > row {
			return c.start, true
		}
	}
	return conflicts[0].start, true
}

// Deletes whole rows [lo,hi] inclusive inside an already-open undo group. When
// the range runs to the last line, it splices from the previous line's end so no
// stray empty line survives.
merge_delete_rows :: proc(b: ^Buffer, lo, hi: int) {
	from := Cursor{lo, 0}
	to: Cursor
	if hi + 1 < len(b.lines) {
		to = Cursor{hi + 1, 0}
	} else if lo > 0 {
		from = Cursor{lo - 1, len(b.lines[lo - 1].text)}
		to = Cursor{hi, len(b.lines[hi].text)}
	} else {
		to = Cursor{hi, len(b.lines[hi].text)}
	}
	edit_delete(b, from, to)
}

merge_resolve :: proc(b: ^Buffer, c: MergeConflict, keep: MergeKeep) {
	edit_open(b, .Atomic)
	switch keep {
	case .Ours:
		merge_delete_rows(b, c.base if c.base >= 0 else c.sep, c.end)
		merge_delete_rows(b, c.start, c.start)
	case .Theirs:
		merge_delete_rows(b, c.end, c.end)
		merge_delete_rows(b, c.start, c.sep)
	case .Both:
		merge_delete_rows(b, c.end, c.end)
		if c.base >= 0 {
			merge_delete_rows(b, c.base, c.sep)
		} else {
			merge_delete_rows(b, c.sep, c.sep)
		}
		merge_delete_rows(b, c.start, c.start)
	}
	buffer_undo_commit(b)

	b.selection = nil
	b.cursor = Cursor{clamp(c.start, 0, len(b.lines) - 1), 0}
	cursor_goal_sync(b)
}

cmd_merge_resolve :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	conflicts := merge_scan(b)
	if len(conflicts) == 0 {
		editor_log(editor, .Info, "Git", "No merge conflicts")
		return
	}
	if _, ok := merge_at(conflicts, b.cursor.row); ok {
		merge_dialog_open(editor)
		return
	}
	if target, ok := merge_next(conflicts, b.cursor.row); ok {
		b.selection = nil
		b.cursor = Cursor{target, 0}
		cursor_goal_sync(b)
		editor_scroll(editor)
	}
}

merge_actions := [?]string{"Keep Ours", "Keep Theirs", "Keep Both"}

MergeDialog :: struct {
	active:   bool,
	selected: int,
}

merge_dialog_open :: proc(editor: ^Editor) {
	editor.merge_dialog.active = true
	editor.merge_dialog.selected = 0
	editor_clear_message(editor)
}

merge_dialog_close :: proc(editor: ^Editor) {
	editor.merge_dialog.active = false
}

merge_dialog_execute :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	sel := editor.merge_dialog.selected
	merge_dialog_close(editor)
	c, ok := merge_at(merge_scan(b), b.cursor.row)
	if !ok {
		return
	}
	keep := MergeKeep.Ours
	switch sel {
	case 1:
		keep = .Theirs
	case 2:
		keep = .Both
	}
	merge_resolve(b, c, keep)
	editor_scroll(editor)
}

merge_dialog_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	dialog_key(editor, ev, &editor.merge_dialog.selected, len(merge_actions), merge_dialog_execute, merge_dialog_close)
}

merge_dialog_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	dialog_mouse(editor, ev, merge_dialog_question(), merge_actions[:], &editor.merge_dialog.selected, merge_dialog_execute, merge_dialog_close)
}

merge_dialog_question :: proc() -> string {
	return "Resolve merge conflict:"
}

merge_dialog_render :: proc(editor: ^Editor) {
	dialog_render(editor, merge_dialog_question(), merge_actions[:], editor.merge_dialog.selected)
}
