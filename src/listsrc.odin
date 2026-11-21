package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "lib:tb2"

ListSourceKind :: enum {
	None,
	Commands,
	Dirs,
	Lines,
	Log,
	Plugins,
	Walk,
}

ListSource :: struct {
	kind:      ListSourceKind,
	scope:     string,
	path:      string,
	dotfiles:  bool,
	buf:       u64,
	cache_dir: string,
	cache:     [dynamic]string,
	ids:       [dynamic]u64,
	rows:      [dynamic]int,
	stamp:     u64,
	evicted:   int,
	walk:      ^Walk,
	wscope:    ^WalkScope,
	entries:   [dynamic]FileEntry,
	names:     vmem.Arena,
	filtering: bool,
	narrow_q:  string,
	narrow_idx: [dynamic]int,
	narrow_builds: u64,
}

ColumnSize :: enum {
	Fill,
	Fixed,
	Fit,
}

PaneColumn :: struct {
	size:     ColumnSize,
	w:        int,
	min, max: int,
	right:    bool,
	title:    string,
}

list_source_clone :: proc(s: ListSource) -> ListSource {
	if s.walk != nil {
		s.walk.refs += 1
	}
	if s.wscope != nil {
		s.wscope.refs += 1
	}
	return {kind = s.kind, scope = strings.clone(s.scope), path = strings.clone(s.path), dotfiles = s.dotfiles, buf = s.buf, walk = s.walk, wscope = s.wscope}
}

list_source_free :: proc(s: ^ListSource) {
	delete(s.scope)
	delete(s.path)
	list_source_uncache(s)
	delete(s.cache)
	delete(s.ids)
	delete(s.rows)
	walk_release(s.walk)
	walk_scope_release(s.wscope)
	delete(s.entries)
	vmem.arena_destroy(&s.names)
	delete(s.narrow_q)
	delete(s.narrow_idx)
	s^ = {}
}

list_source_uncache :: proc(s: ^ListSource) {
	for n in s.cache {
		delete(n)
	}
	clear(&s.cache)
	clear(&s.ids)
	clear(&s.rows)
	delete(s.cache_dir)
	s.cache_dir = ""
}

pane_list_load :: proc(editor: ^Editor, p: ^Pane) {
	#partial switch p.list.source.kind {
	case .Commands:
		list_commands_fill(editor, p)
	case .Dirs:
		list_dirs_fill(editor, p)
	}
	p.list.sel, p.list.scroll, p.list.anchor = 0, 0, nil
	p.notified = -1
	pane_refilter(editor, p)
	if p.list.source.kind == .Lines {
		list_lines_center(editor, p)
	}
}

list_ranked :: proc(kind: ListSourceKind) -> bool {
	return kind != .Lines
}

list_restores :: proc(kind: ListSourceKind) -> bool {
	return kind != .Lines
}

list_stamp :: proc(editor: ^Editor, p: ^Pane) -> u64 {
	src := &p.list.source
	#partial switch src.kind {
	case .Lines:
		if b, _ := api_buf_find(editor, src.buf); b != nil {
			return b.rev + 1
		}
	case .Log:
		v := &editor.logview
		stamp := editor.log_seq << 8 | u64(v.history)
		for on, level in v.filter {
			stamp |= u64(on) << (1 + uint(level))
		}
		return stamp
	case .Plugins:
		return u64(len(editor.plugins.list))
	case .Walk:
		return src.walk.gen + 1 if src.walk != nil else 0
	}
	return 0
}

list_exact :: proc(editor: ^Editor, p: ^Pane) -> (row: int, ok: bool) {
	if p.list.source.kind == .Lines {
		row, _, ok = lines_goto(editor, p)
	}
	return
}

list_count :: proc(editor: ^Editor, p: ^Pane) -> int {
	src := &p.list.source
	switch src.kind {
	case .None:
		return len(p.list.items)
	case .Commands:
		return len(src.cache)
	case .Dirs:
		return len(src.rows)
	case .Lines:
		b, _ := api_buf_find(editor, src.buf)
		return len(b.lines) if b != nil else 0
	case .Log:
		return len(list_log_rows(editor, src))
	case .Plugins:
		return len(editor.plugins.list)
	case .Walk:
		return len(src.entries)
	}
	return 0
}

list_text :: proc(editor: ^Editor, p: ^Pane, i: int) -> string {
	if i < 0 || i >= list_count(editor, p) {
		return ""
	}
	src := &p.list.source
	switch src.kind {
	case .None:
		return p.list.items[i].label
	case .Commands:
		return src.cache[i]
	case .Dirs:
		return src.cache[src.rows[i]]
	case .Lines:
		b, _ := api_buf_find(editor, src.buf)
		return string(b.lines[i].text[:])
	case .Log:
		return list_log_entry(editor, src, i).text
	case .Plugins:
		return editor.plugins.list[i].display
	case .Walk:
		return src.entries[i].path
	}
	return ""
}

list_item :: proc(editor: ^Editor, p: ^Pane, i: int) -> (it: PaneItem) {
	if i < 0 || i >= list_count(editor, p) {
		return
	}
	src := &p.list.source
	if src.kind == .None {
		return p.list.items[i]
	}
	when ODIN_TEST {
		test_list_built += 1
	}
	switch src.kind {
	case .None:
	case .Commands:
		it.label, it.id = src.cache[i], src.ids[i]
		if cmd, ok := list_command(editor, src, i); ok {
			_, _, it.detail = command_effective_bind(cmd)
		}
	case .Dirs:
		it.label = src.cache[src.rows[i]]
		it.path, _ = filepath.join({src.cache_dir, it.label}, context.temp_allocator)
	case .Lines:
		b, _ := api_buf_find(editor, src.buf)
		text := b.lines[i].text[:]
		it.label, it.row, it.buf = string(text), i + 1, src.buf
		it.col = line_indent_len(text) + 1
		if row, col, ok := lines_goto(editor, p); ok && row == i && col >= 0 {
			it.col = min(col, len(text)) + 1
		}
		it.cells = make([]string, 2, context.temp_allocator)
		it.cells[0], it.cells[1] = fmt.tprintf("%d", i + 1), it.label
	case .Log:
		e := list_log_entry(editor, src, i)
		it.label, it.key, it.color = e.text, fmt.tprintf("%d", e.seq), log_level_color(e.level)
		it.cells = make([]string, 3, context.temp_allocator)
		it.cells[0], it.cells[1], it.cells[2] = log_clock(e.time), e.source, e.text
	case .Plugins:
		pl := editor.plugins.list[i]
		it.label, it.key = pl.display, pl.name
		state := "enabled"
		switch pl.state {
		case .Enabled:
		case .Disabled:
			state, it.color = "disabled", "pane_shortcut_foreground"
		case .Errored:
			state, it.color = "errored", "error_foreground"
		}
		it.cells = make([]string, 5, context.temp_allocator)
		it.cells[0], it.cells[1], it.cells[2], it.cells[3] = pl.display, pl.description, "bundled" if pl.bundled else "user", state
		it.cells[4] = fmt.tprintf("%.2f ms", pl.load_ms) if pl.state != .Disabled else ""
	case .Walk:
		e := src.entries[i]
		it.label, it.path, it.key, it.dir, it.depth = e.name, e.path, e.path, e.is_dir, e.depth
		if idx := editor_find_buffer(editor, e.path); idx >= 0 && !e.is_dir {
			b := &editor.buffers[idx]
			it.buf, it.row = b.id, clamp(b.cursor.row, 0, max(0, len(b.lines) - 1)) + 1
		}
	}
	return
}

list_columns :: proc(editor: ^Editor, p: ^Pane) -> []PaneColumn {
	#partial switch p.list.source.kind {
	case .None:
		return p.list.columns
	case .Lines:
		return slice.clone([]PaneColumn{{size = .Fixed, w = digit_count(list_count(editor, p)), right = true}, {}}, context.temp_allocator)
	case .Log:
		return LOG_COLUMNS[:]
	case .Plugins:
		return PLUGIN_COLUMNS[:]
	}
	return nil
}

list_commands_fill :: proc(editor: ^Editor, p: ^Pane) {
	src := &p.list.source
	list_source_uncache(src)
	for cmd in (commands[:] if src.scope == "" else pane_commands[:]) {
		if cmd.scope == src.scope && command_available(editor, cmd.name, src.scope) {
			append(&src.cache, strings.clone(cmd.name))
			append(&src.ids, 0)
		}
	}
	for cmd in editor.plugins.commands {
		if cmd.scope != src.scope || (editor.welcome && src.scope == "" && !cmd.welcome) || !plugin_command_when(editor, cmd) {
			continue
		}
		append(&src.cache, strings.clone(cmd.name))
		append(&src.ids, cmd.id)
	}
}

list_command :: proc(editor: ^Editor, s: ^ListSource, i: int) -> (Command, bool) {
	if i < 0 || i >= len(s.cache) {
		return {}, false
	}
	if id := s.ids[i]; id != 0 {
		for cmd in editor.plugins.commands {
			if cmd.id == id {
				return cmd, true
			}
		}
		return {}, false
	}
	for cmd in (commands[:] if s.scope == "" else pane_commands[:]) {
		if cmd.scope == s.scope && cmd.name == s.cache[i] {
			return cmd, true
		}
	}
	return {}, false
}

list_dirs_fill :: proc(editor: ^Editor, p: ^Pane) {
	src := &p.list.source
	base, term := src.path, ""
	if f := pane_path(p); f != nil {
		typed: string
		typed, term = path_split(textfield_str(&f.field))
		base = path_resolve(editor.working_root, os.get_env("HOME", context.temp_allocator), typed)
	}
	if base != src.cache_dir || src.cache_dir == "" {
		list_source_uncache(src)
		src.cache_dir = strings.clone(base)
		infos, err := os.read_directory_by_path(base, -1, context.temp_allocator)
		if err == nil {
			for info in infos {
				if !(info.type == .Directory || (info.type == .Symlink && os.is_dir(info.fullpath))) {
					continue
				}
				if src.dotfiles || !strings.has_prefix(info.name, ".") {
					append(&src.cache, strings.clone(info.name))
				}
			}
			slice.sort(src.cache[:])
		}
	}
	clear(&src.rows)
	for n, i in src.cache {
		if path_prefix_match(n, term) {
			append(&src.rows, i)
		}
	}
}

list_log_rows :: proc(editor: ^Editor, src: ^ListSource) -> []int {
	v := &editor.logview
	stamp := editor.log_seq << 8 | u64(v.history)
	for on, level in v.filter {
		stamp |= u64(on) << (1 + uint(level))
	}
	if stamp != src.stamp || v.source != src.path {
		src.stamp = stamp
		delete(src.path)
		src.path = strings.clone(v.source)
		first := editor.log[0].seq if len(editor.log) > 0 else editor.log_seq + 1
		for seq in src.rows {
			if u64(seq) < first {
				src.evicted += 1
			}
		}
		clear(&src.rows)
		for e in editor.log {
			if v.filter[e.level] && (!e.seeded || v.history) && (v.source == "" || e.source == v.source) {
				append(&src.rows, int(e.seq))
			}
		}
	}
	return src.rows[:]
}

list_log_entry :: proc(editor: ^Editor, src: ^ListSource, i: int) -> LogEntry {
	seq := u64(list_log_rows(editor, src)[i])
	if len(editor.log) == 0 || seq < editor.log[0].seq || seq - editor.log[0].seq >= u64(len(editor.log)) {
		return {}
	}
	return editor.log[seq - editor.log[0].seq]
}

// col -1 means the first non-blank
lines_goto :: proc(editor: ^Editor, p: ^Pane) -> (row, col: int, ok: bool) {
	f := pane_filter(p)
	if f == nil {
		return
	}
	s := textfield_str(&f.field)
	n := list_count(editor, p)
	if len(s) < 2 || s[0] != ':' || n == 0 {
		return
	}
	rest := s[1:]
	col = -1
	if c := strings.index_byte(rest, ':'); c >= 0 {
		if cs := rest[c + 1:]; len(cs) > 0 {
			if !all_digits(cs) {
				return
			}
			v, _ := strconv.parse_int(cs, 10)
			col = max(0, v - 1)
		}
		rest = rest[:c]
	}
	if !all_digits(rest) {
		return
	}
	v, vok := strconv.parse_int(rest, 10)
	if !vok {
		return
	}
	return clamp(v - 1, 0, n - 1), col, true
}

all_digits :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

list_lines_center :: proc(editor: ^Editor, p: ^Pane) {
	b, _ := api_buf_find(editor, p.list.source.buf)
	if b == nil {
		return
	}
	pos := b.cursor.row
	if p.list.filtered {
		best := max(int)
		for m, i in p.list.matches {
			if d := abs(m - b.cursor.row); d < best {
				best, pos = d, i
			}
		}
	}
	p.list.sel = clamp(pos, 0, max(0, pane_count(editor, p) - 1))
	p.list.scroll = max(0, p.list.sel - pane_geom(editor, p).list.h / 2)
	p.list.moved = true
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
	if pane_count(editor, p) == 0 {
		return
	}
	name := list_item(editor, p, pane_item_index(p, p.list.sel)).label
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
	if ev.ch == '/' && !ev_alt(ev) && at_end && pane_count(editor, p) > 0 {
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
