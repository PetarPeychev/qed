package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "lib:tb2"

ListSourceKind :: enum {
	None,
	Commands,
	Dirs,
}

ListSource :: struct {
	kind:     ListSourceKind,
	filetree: bool,
	path:     string,
}

list_source_clone :: proc(s: ListSource) -> ListSource {
	out := s
	out.path = strings.clone(s.path)
	return out
}

list_source_free :: proc(s: ^ListSource) {
	delete(s.path)
	s^ = {}
}

pane_list_load :: proc(editor: ^Editor, p: ^Pane) {
	switch p.list.source.kind {
	case .None:
	case .Commands:
		list_commands_fill(editor, p)
	case .Dirs:
		list_dirs_fill(editor, p)
	}
	p.list.sel, p.list.scroll, p.list.anchor = 0, 0, nil
	pane_refilter(p)
}

list_commands_fill :: proc(editor: ^Editor, p: ^Pane) {
	pane_items_clear(p)
	ft := p.list.source.filetree
	if ft {
		for cmd, i in filetree_commands {
			append(&p.list.items, PaneItem{label = strings.clone(cmd.name), src = i})
		}
	} else {
		for cmd, i in commands {
			if command_available(editor, cmd.name) {
				append(&p.list.items, PaneItem{label = strings.clone(cmd.name), src = i})
			}
		}
	}
	base := len(filetree_commands) if ft else len(commands)
	for cmd, i in editor.plugins.commands {
		if cmd.filetree != ft || (editor.welcome && !ft && !cmd.welcome) || !plugin_command_when(editor, cmd) {
			continue
		}
		append(&p.list.items, PaneItem{label = strings.clone(cmd.name), src = base + i})
	}
}

list_command :: proc(editor: ^Editor, s: ^ListSource, src: int) -> Command {
	base := len(filetree_commands) if s.filetree else len(commands)
	if src >= base {
		return editor.plugins.commands[src - base]
	}
	return filetree_commands[src] if s.filetree else commands[src]
}

list_item_detail :: proc(editor: ^Editor, p: ^Pane, it: PaneItem) -> string {
	if p.list.source.kind == .Commands {
		_, _, shortcut := command_effective_bind(list_command(editor, &p.list.source, it.src))
		return shortcut
	}
	return it.detail
}

list_dirs_fill :: proc(editor: ^Editor, p: ^Pane) {
	pane_items_clear(p)
	base, term := p.list.source.path, ""
	if f := pane_path(p); f != nil {
		typed: string
		typed, term = path_split(textfield_str(&f.field))
		base = path_resolve(editor.working_root, os.get_env("HOME", context.temp_allocator), typed)
	}
	infos, err := os.read_directory_by_path(base, -1, context.temp_allocator)
	if err != nil {
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if !(info.type == .Directory || (info.type == .Symlink && os.is_dir(info.fullpath))) {
			continue
		}
		if !editor.filetree.show_dotfiles && strings.has_prefix(info.name, ".") {
			continue
		}
		if path_prefix_match(info.name, term) {
			append(&names, info.name)
		}
	}
	slice.sort(names[:])
	for n in names {
		full, _ := filepath.join({base, n}, context.temp_allocator)
		append(&p.list.items, PaneItem{label = strings.clone(n), path = strings.clone(full)})
	}
}

path_split :: proc(text: string) -> (base, term: string) {
	idx := strings.last_index_byte(text, '/')
	if idx < 0 {
		return "", text
	}
	if idx == 0 {
		return "/", text[1:]
	}
	return text[:idx], text[idx + 1:]
}

path_resolve :: proc(root, home, base: string, allocator := context.temp_allocator) -> string {
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

path_back :: proc(text, home: string) -> string {
	trimmed := strings.trim_right(text, "/")
	if trimmed == "" {
		return "/"
	}
	if trimmed == "~" {
		clean, _ := filepath.clean(home, context.temp_allocator)
		parent := filepath.dir(clean)
		return "/" if parent == "/" else fmt.tprintf("%s/", parent)
	}
	seg := trimmed[strings.last_index_byte(trimmed, '/') + 1:]
	return text[:len(trimmed) - len(seg)]
}

path_prefix_match :: proc(name, term: string) -> bool {
	return len(name) >= len(term) && find_eq(name[:len(term)], term, smart_case_insensitive(term))
}

pane_path :: proc(p: ^Pane) -> ^PaneField {
	for &f in p.fields {
		if f.mode == .Path {
			return &f
		}
	}
	return nil
}

pane_field_value :: proc(editor: ^Editor, f: ^PaneField) -> string {
	text := textfield_str(&f.field)
	if f.mode == .Path {
		return path_resolve(editor.working_root, os.get_env("HOME", context.temp_allocator), text)
	}
	return text
}

pane_path_complete :: proc(editor: ^Editor, p: ^Pane, f: ^PaneField) {
	if pane_count(p) == 0 {
		return
	}
	name := p.list.items[pane_item_index(p, p.list.sel)].label
	text := textfield_str(&f.field)
	head := text[:strings.last_index_byte(text, '/') + 1]
	textfield_set(&f.field, fmt.tprintf("%s%s/", head, name))
	pane_field_changed(editor, p, f)
}

pane_path_key :: proc(editor: ^Editor, p: ^Pane, f: ^PaneField, ev: tb2.Event) -> bool {
	_, _, sel := textfield_selection(&f.field)
	at_end := !sel && f.caret == len(f.text)
	#partial switch ev.key {
	case .Tab:
		pane_path_complete(editor, p, f)
		return true
	case .Backspace, .Backspace2:
		text := textfield_str(&f.field)
		if at_end && strings.has_suffix(text, "/") {
			textfield_set(&f.field, path_back(text, os.get_env("HOME", context.temp_allocator)))
			pane_field_changed(editor, p, f)
			return true
		}
	}
	if ev.ch == '/' && !ev_alt(ev) && at_end && pane_count(p) > 0 {
		pane_path_complete(editor, p, f)
		return true
	}
	return false
}

path_under :: proc(path, root: string) -> bool {
	if root == "/" {
		return strings.has_prefix(path, "/")
	}
	return len(path) > len(root) && path[len(root)] == '/' && strings.has_prefix(path, root)
}
