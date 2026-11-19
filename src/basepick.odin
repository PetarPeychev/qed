package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "lib:tb2"

BASEPICK_LOG_COUNT :: 50

BasePickEntry :: struct {
	name, ref, label: string,
	merge, commit:    bool,
}

BasePick :: struct {
	using list: FuzzyList,
	entries:    [dynamic]BasePickEntry,
	names:      [dynamic]string,
}

basepick_destroy :: proc(bp: ^BasePick) {
	fuzzy_list_destroy(&bp.list)
	basepick_clear_entries(bp)
	delete(bp.entries)
	delete(bp.names)
}

basepick_clear_entries :: proc(bp: ^BasePick) {
	for e in bp.entries {
		delete(e.name)
		delete(e.ref)
		delete(e.label)
	}
	clear(&bp.entries)
	clear(&bp.names)
}

basepick_cmd :: proc(root: string) -> cstring {
	q := shell_quote(root)
	return fmt.ctprintf(
		"git -C %s rev-parse --show-toplevel >/dev/null 2>&1 || exit 0; echo @@DEFAULT@@; git -C %s symbolic-ref --short -q refs/remotes/origin/HEAD || (git -C %s show-ref -q --verify refs/heads/main && echo main) || (git -C %s show-ref -q --verify refs/heads/master && echo master); echo @@REFS@@; git -C %s for-each-ref --format=%s refs/heads refs/remotes; echo @@LOG@@; git -C %s log -n %d --format=%s 2>/dev/null",
		q,
		q,
		q,
		q,
		q,
		shell_quote("%(refname:lstrip=2)"),
		q,
		BASEPICK_LOG_COUNT,
		shell_quote("%h %s"),
	)
}

basepick_parse :: proc(out: string, allocator := context.allocator) -> (entries: [dynamic]BasePickEntry, ok: bool) {
	entries = make([dynamic]BasePickEntry, allocator)
	add :: proc(entries: ^[dynamic]BasePickEntry, name, ref, label: string, merge, commit: bool, allocator: runtime.Allocator) {
		append(
			entries,
			BasePickEntry {
				strings.clone(name, allocator),
				strings.clone(ref, allocator),
				strings.clone(label, allocator),
				merge,
				commit,
			},
		)
	}
	section := ""
	rest := out
	for line in strings.split_lines_iterator(&rest) {
		if line == "@@DEFAULT@@" || line == "@@REFS@@" || line == "@@LOG@@" {
			if line == "@@DEFAULT@@" {
				ok = true
				add(&entries, "HEAD", "", "", false, false, allocator)
			}
			section = line
			continue
		}
		l := strings.trim_space(line)
		if l == "" {
			continue
		}
		switch section {
		case "@@DEFAULT@@":
			add(&entries, fmt.tprintf("Merge base with %s", l), l, fmt.tprintf("%s...", l), true, false, allocator)
		case "@@REFS@@":
			if !strings.has_suffix(l, "/HEAD") {
				add(&entries, l, l, l, false, false, allocator)
			}
		case "@@LOG@@":
			sha := l
			if i := strings.index_byte(l, ' '); i >= 0 {
				sha = l[:i]
			}
			add(&entries, l, sha, sha, false, true, allocator)
		}
	}
	return
}

basepick_open :: proc(editor: ^Editor) {
	bp := &editor.basepick
	editor_clear_message(editor)
	out, _ := shell_capture(basepick_cmd(editor.working_root))
	entries, ok := basepick_parse(out)
	if !ok {
		delete(entries)
		editor_log(editor, .Error, "Git", "Working directory is not a git repository")
		return
	}
	basepick_clear_entries(bp)
	delete(bp.entries)
	bp.entries = entries
	for e in bp.entries {
		append(&bp.names, e.name)
	}
	bp.active = true
	fuzzy_list_reset(&bp.list)
	bp.fuzzy = fuzzy_begin(bp.names[:])
	fuzzy_list_refilter(&bp.list)
}

basepick_close :: proc(editor: ^Editor) {
	editor.basepick.active = false
	fuzzy_end(&editor.basepick.fuzzy)
}

basepick_execute :: proc(editor: ^Editor) {
	bp := &editor.basepick
	if len(bp.matches) == 0 {
		return
	}
	e := bp.entries[bp.matches[bp.selected]]
	basepick_close(editor)
	ref := e.ref
	if ref != "" {
		q := shell_quote(editor.working_root)
		cmd :=
			fmt.ctprintf("git -C %s merge-base %s HEAD 2>/dev/null", q, shell_quote(e.ref)) if e.merge else fmt.ctprintf("git -C %s rev-parse -q --verify %s 2>/dev/null", q, shell_quote(fmt.tprintf("%s^0", e.ref)))
		out, _ := shell_capture(cmd)
		sha := strings.trim_space(out)
		if sha == "" {
			editor_log(editor, .Error, "Git", fmt.tprintf("Cannot resolve %s", e.name))
			return
		}
		if e.commit {
			ref = sha
		}
	}
	git_base_change(editor, ref, e.label, e.merge)
	editor_log(editor, .Info, "Git", fmt.tprintf("Diff base: %s", e.label if ref != "" else "HEAD"))
}

basepick_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	fuzzy_list_key(editor, &editor.basepick.list, ev, basepick_execute, basepick_close)
}

basepick_paste :: proc(editor: ^Editor, text: string) {
	if textfield_insert_flat(&editor.basepick.field, text) {
		fuzzy_list_refilter(&editor.basepick.list)
	}
}

basepick_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	fuzzy_list_center_mouse(editor, &editor.basepick.list, ev, basepick_execute, basepick_close)
}

basepick_render :: proc(editor: ^Editor) {
	bp := &editor.basepick
	fuzzy_list_center_render(editor, &bp.list, bp.names[:], nil)
}
