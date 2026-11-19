package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "lib:tb2"

CwdPick :: struct {
	using list:       FuzzyList,
	names:            [dynamic]string,
	base:             string,
	confirm:          bool,
	confirm_selected: int,
	target:           string,
}

cwdpick_destroy :: proc(cp: ^CwdPick) {
	fuzzy_list_destroy(&cp.list)
	cwdpick_clear_names(cp)
	delete(cp.names)
	delete(cp.base)
	delete(cp.target)
}

cwdpick_clear_names :: proc(cp: ^CwdPick) {
	for n in cp.names {
		delete(n)
	}
	clear(&cp.names)
}

cwdpick_split :: proc(query: string) -> (base, term: string) {
	idx := strings.last_index_byte(query, '/')
	if idx < 0 {
		return "", query
	}
	if idx == 0 {
		return "/", query[1:]
	}
	return query[:idx], query[idx + 1:]
}

cwdpick_resolve :: proc(root, home, base: string, allocator := context.temp_allocator) -> string {
	switch {
	case base == "":
		p, _ := filepath.clean(root, allocator)
		return p
	case base == "~":
		p, _ := filepath.clean(home, allocator)
		return p
	case strings.has_prefix(base, "~/"):
		p, _ := filepath.join({home, base[2:]}, allocator)
		return p
	case strings.has_prefix(base, "/"):
		p, _ := filepath.clean(base, allocator)
		return p
	}
	p, _ := filepath.join({root, base}, allocator)
	return p
}

cwdpick_query_back :: proc(query, home: string) -> string {
	trimmed := strings.trim_right(query, "/")
	if trimmed == "" {
		return "/"
	}
	if trimmed == "~" {
		clean, _ := filepath.clean(home, context.temp_allocator)
		parent := filepath.dir(clean)
		return "/" if parent == "/" else fmt.tprintf("%s/", parent)
	}
	seg := trimmed[strings.last_index_byte(trimmed, '/') + 1:]
	return query[:len(trimmed) - len(seg)]
}

cwdpick_prefix_match :: proc(name, term: string) -> bool {
	return len(name) >= len(term) && find_eq(name[:len(term)], term, smart_case_insensitive(term))
}

path_under :: proc(path, root: string) -> bool {
	if root == "/" {
		return strings.has_prefix(path, "/")
	}
	return len(path) > len(root) && path[len(root)] == '/' && strings.has_prefix(path, root)
}

cwdpick_open :: proc(editor: ^Editor) {
	cp := &editor.cwdpick
	cp.active = true
	cp.confirm = false
	fuzzy_list_reset(&cp.list)
	root := editor.working_root
	textfield_set(&cp.field, root if strings.has_suffix(root, "/") else fmt.tprintf("%s/", root))
	editor_clear_message(editor)
	cwdpick_refilter(editor)
}

cwdpick_close :: proc(editor: ^Editor) {
	cp := &editor.cwdpick
	cp.active = false
	cp.confirm = false
	cwdpick_clear_names(cp)
	clear(&cp.matches)
}

cwdpick_refilter :: proc(editor: ^Editor) {
	cp := &editor.cwdpick
	cwdpick_clear_names(cp)
	clear(&cp.matches)
	cp.selected = 0
	cp.scroll = 0
	base_typed, term := cwdpick_split(textfield_str(&cp.field))
	delete(cp.base)
	cp.base = cwdpick_resolve(editor.working_root, os.get_env("HOME", context.temp_allocator), base_typed, context.allocator)
	infos, err := os.read_directory_by_path(cp.base, -1, context.temp_allocator)
	if err != nil {
		return
	}
	dirs := make([dynamic]string, context.temp_allocator)
	for info in infos {
		is_dir := info.type == .Directory || (info.type == .Symlink && os.is_dir(info.fullpath))
		if !is_dir {
			continue
		}
		if !editor.filetree.show_dotfiles && strings.has_prefix(info.name, ".") {
			continue
		}
		if cwdpick_prefix_match(info.name, term) {
			append(&dirs, info.name)
		}
	}
	slice.sort(dirs[:])
	for d in dirs {
		append(&cp.names, strings.clone(d))
	}
	for i in 0 ..< len(cp.names) {
		append(&cp.matches, i)
	}
}

cwdpick_selected_name :: proc(cp: ^CwdPick) -> (string, bool) {
	if cp.selected < 0 || cp.selected >= len(cp.matches) {
		return "", false
	}
	return cp.names[cp.matches[cp.selected]], true
}

cwdpick_complete :: proc(editor: ^Editor) {
	cp := &editor.cwdpick
	name, ok := cwdpick_selected_name(cp)
	if !ok {
		return
	}
	query := textfield_str(&cp.field)
	head := query[:strings.last_index_byte(query, '/') + 1]
	textfield_set(&cp.field, fmt.tprintf("%s%s/", head, name))
	cwdpick_refilter(editor)
}

cwdpick_execute :: proc(editor: ^Editor) {
	cp := &editor.cwdpick
	target := cwdpick_resolve(editor.working_root, os.get_env("HOME", context.temp_allocator), textfield_str(&cp.field))
	if !os.is_dir(target) {
		editor_log(editor, .Error, "", fmt.tprintf("Not a directory: %s", target))
		return
	}
	if target == editor.working_root {
		cwdpick_close(editor)
		return
	}
	_, unsaved := editor_outside_buffers(editor, target)
	if unsaved > 0 {
		delete(cp.target)
		cp.target = strings.clone(target)
		cp.confirm = true
		cp.confirm_selected = 0
		return
	}
	cwdpick_close(editor)
	editor_change_root(editor, target)
}

editor_outside_buffers :: proc(editor: ^Editor, root: string) -> (total, unsaved: int) {
	for &b in editor.buffers {
		if b.path != "" && !path_under(b.path, root) {
			total += 1
			if b.modified {
				unsaved += 1
			}
		}
	}
	return
}

cwdpick_confirm_question :: proc(editor: ^Editor) -> string {
	return close_question(editor_outside_buffers(editor, editor.cwdpick.target))
}

cwdpick_confirm_execute :: proc(editor: ^Editor) {
	cp := &editor.cwdpick
	if cp.confirm_selected != 1 {
		cwdpick_confirm_cancel(editor)
		return
	}
	cwdpick_close(editor)
	editor_change_root(editor, cp.target)
}

cwdpick_confirm_cancel :: proc(editor: ^Editor) {
	editor.cwdpick.confirm = false
}

editor_change_root :: proc(editor: ^Editor, root: string) {
	for i := len(editor.buffers) - 1; i >= 0; i -= 1 {
		b := &editor.buffers[i]
		if b.path != "" && !path_under(b.path, root) {
			editor_close_index(editor, i)
		}
	}
	root := strings.clone(root)
	plugin_queue(editor, {event = .Root_Changed, a = editor.working_root, b = root})
	delete(editor.working_root)
	editor.working_root = root
	editor.hover_active = false
	if g_diff_base.ref != "" {
		git_base_set("", "", false)
		for &b in editor.buffers {
			git_invalidate(&b)
		}
	}
	lsp_restart_all(editor)
	filetree_root_reset(editor)
	projsearch_root_reset(&editor.projsearch)
	git_stat_reset(editor)
	editor_log(editor, .Info, "", fmt.tprintf("Working directory: %s", root))
}

cwdpick_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	cp := &editor.cwdpick
	if cp.confirm {
		dialog_key(editor, ev, &cp.confirm_selected, len(filetree_close_actions), cwdpick_confirm_execute, cwdpick_confirm_cancel)
		return
	}
	if command_matches(ev, "Change Working Directory") {
		cwdpick_close(editor)
		return
	}
	#partial switch ev.key {
	case .Esc:
		cwdpick_close(editor)
	case .Enter:
		cwdpick_execute(editor)
	case .Tab:
		cwdpick_complete(editor)
	case .Backspace, .Backspace2:
		if cwdpick_at_end(cp) && strings.has_suffix(textfield_str(&cp.field), "/") {
			textfield_set(&cp.field, cwdpick_query_back(textfield_str(&cp.field), os.get_env("HOME", context.temp_allocator)))
			cwdpick_refilter(editor)
		} else if textfield_key(&cp.field, ev) {
			cwdpick_refilter(editor)
		}
	case .Arrow_Down:
		fuzzy_list_move(&cp.list, 1, PALETTE_MAX_ROWS)
	case .Arrow_Up:
		fuzzy_list_move(&cp.list, -1, PALETTE_MAX_ROWS)
	case:
		if ev.ch == '/' && !ev_alt(ev) && cwdpick_at_end(cp) && len(cp.matches) > 0 {
			cwdpick_complete(editor)
		} else if textfield_key(&cp.field, ev) {
			cwdpick_refilter(editor)
		}
	}
}

cwdpick_at_end :: proc(cp: ^CwdPick) -> bool {
	_, _, sel := textfield_selection(&cp.field)
	return !sel && cp.field.caret == len(cp.field.text)
}

cwdpick_paste :: proc(editor: ^Editor, text: string) {
	cp := &editor.cwdpick
	if !cp.confirm && textfield_insert_flat(&cp.field, text) {
		cwdpick_refilter(editor)
	}
}

cwdpick_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	cp := &editor.cwdpick
	if cp.confirm {
		dialog_mouse(editor, ev, cwdpick_confirm_question(editor), filetree_close_actions[:], &cp.confirm_selected, cwdpick_confirm_execute, cwdpick_confirm_cancel)
		return
	}
	fuzzy_list_center_mouse(editor, &cp.list, ev, cwdpick_complete, cwdpick_close)
}

cwdpick_render :: proc(editor: ^Editor) {
	cp := &editor.cwdpick
	rows := min(len(cp.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &cp.field)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := cp.scroll + i
		name := cp.names[cp.matches[idx]]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if idx == cp.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, name, fg, bg)
	}

	fuzzy_list_center_scrollbar(&cp.list, box, rows)
	if cp.confirm {
		dialog_render(editor, cwdpick_confirm_question(editor), filetree_close_actions[:], cp.confirm_selected)
	}
}
