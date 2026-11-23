package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import lua "lib:lua"
import "lib:tb2"

test_buffer :: proc(lines: ..string) -> Buffer {
	b: Buffer
	b.id = buffer_id_next()
	b.indent_width = TAB_WIDTH
	b.lines = make([dynamic]Line, 0, len(lines))
	for l in lines {
		line: Line
		append(&line.text, ..transmute([]u8)l)
		append(&b.lines, line)
	}
	if len(b.lines) == 0 {
		append(&b.lines, Line{})
	}
	return b
}

@(thread_local)
test_list_built: int

@(thread_local)
test_slice_on: bool

@(thread_local)
test_slice_max: map[string]f64

@(thread_local)
test_gc_max: f64

@(thread_local)
test_gc_steps, test_gc_cycles, test_gc_shrinks: int

@(thread_local)
test_alloc_frees, test_gc_step_frees_max, test_alloc_refusals, test_gc_debt_steps_max: int

FT_HELPER :: `return {setup = function()
	qed.command{name = "Eval", run = function(code)
		local chunk = assert(load(code, "ft", "t", _ENV))
		local ok, result = pcall(chunk)
		qed.message(ok and tostring(result) or ("error: " .. tostring(result)))
	end}
end}`

// runs Lua in a helper plugin and returns what it evaluates to, as a string; the message line is put back
ft_lua :: proc(ed: ^Editor, code: string) -> string {
	if plugin_find(&ed.plugins, "fthelper") == nil {
		tmp, _ := os.temp_dir(context.temp_allocator)
		path := fmt.tprintf("%s/qed_ft_helper_%d.lua", tmp, posix.getpid())
		_ = os.write_entire_file(path, transmute([]u8)string(FT_HELPER))
		defer os.remove(path)
		pl := plugins_add(&ed.plugins, Plugin{name = "fthelper", main = path}, false)
		plugin_load(ed, pl)
	}
	saved := strings.clone(ed.message, context.temp_allocator)
	saved_source := strings.clone(ed.message_source, context.temp_allocator)
	saved_level := ed.message_level
	for command in ed.plugins.commands {
		if command.owner == "fthelper" {
			plugin_task_start(ed, command.owner, .Command, {ref = command.ref, args = .Line, line = code, command = command.id, user = true})
		}
	}
	plugin_flush(ed)
	result := strings.clone(ed.message, context.temp_allocator)
	editor_message_show(ed, saved_level, saved_source, saved)
	return result
}

ft_tree_list :: proc(ed: ^Editor) -> ^UiList {
	ui_resolve(ed)
	node := ui_find(&ed.ui, "#filetree/filetree_rows")
	if node == nil {
		return nil
	}
	return ui_list_find(&ed.ui, node.list)
}

filetree_active :: proc(ed: ^Editor) -> bool {
	return ft_tree_list(ed) != nil
}

ft_run :: proc(ed: ^Editor, name: string) {
	cmd, ok := plugin_test_command(ed, name)
	assert(ok, name)
	plugin_command_run(ed, cmd)
	plugin_flush(ed)
}

filetree_open_all :: proc(ed: ^Editor) {
	ft_run(ed, "File Tree: All")
}

filetree_close :: proc(ed: ^Editor) {
	if filetree_active(ed) {
		ft_lua(ed, `qed.plugin("filetree").close()`)
	}
}

filetree_toggle_ignored :: proc(ed: ^Editor) {ft_run(ed, "File Tree: Toggle Ignored")}
filetree_toggle_dotfiles :: proc(ed: ^Editor) {ft_run(ed, "File Tree: Toggle Dotfiles")}

ft_state :: proc(ed: ^Editor, field: string) -> string {
	return ft_lua(ed, fmt.tprintf(`local state = qed.plugin("filetree").state(); return state and %s`, field))
}

ft_chip :: proc(ed: ^Editor, label: string) -> bool {
	return ft_state(ed, fmt.tprintf("state.chips[%q]", label)) == "true"
}

ft_confirm_text :: proc(ed: ^Editor) -> string {
	if dialog, ok := test_dialog(ed); ok && dialog.kind == "confirm" {
		return dialog.question
	}
	return ""
}

ft_scope :: proc(ed: ^Editor) -> string {
	if !filetree_active(ed) {
		return ""
	}
	return ft_state(ed, "state.tab")
}

ft_tabs :: proc(ed: ^Editor) -> string {
	if !filetree_active(ed) {
		return ""
	}
	return ft_state(ed, `table.concat(state.tabs, "|")`)
}

// the rows as the next frame shows them: a changed walk refills at render or input
ft_entries :: proc(ed: ^Editor) -> []FileEntry {
	plugin_flush(ed)
	list := ft_tree_list(ed)
	if list == nil {
		return nil
	}
	ft_trees_settle(ed)
	return list.tree.source.entries[:]
}

ft_sel :: proc(ed: ^Editor) -> int {
	plugin_flush(ed)
	list := ft_tree_list(ed)
	if list == nil {
		return -1
	}
	walk_trees_settle(ed)
	state := ed.ui.states["#filetree/filetree_rows"]
	position, ok := ui_list_position(list, state.highlighted)
	return position if ok else 0
}

ft_selected :: proc(ed: ^Editor) -> (FileEntry, bool) {
	entries := ft_entries(ed)
	if len(entries) == 0 {
		return {}, false
	}
	return entries[clamp(ft_sel(ed), 0, len(entries) - 1)], true
}

ft_sel_range :: proc(ed: ^Editor) -> (lo, hi: int) {
	list := ft_tree_list(ed)
	lo, hi = ft_sel(ed), ft_sel(ed)
	state := ed.ui.states["#filetree/filetree_rows"]
	if anchor, ok := ui_list_position(list, state.extend_from); ok && state.extend_from != "" {
		lo, hi = min(anchor, lo), max(anchor, hi)
	}
	return
}

// highlights a row through the plugin, so its preview and state follow as for a key press
ft_select_path :: proc(ed: ^Editor, path: string) {
	ft_lua(ed, fmt.tprintf(`qed.plugin("filetree").reveal(%q)`, path))
}

FtMark :: struct {
	bar, fg, suffix: string,
	dim, sizes:      bool,
	added, removed:  int,
}

ft_mark :: proc(ed: ^Editor, path: string) -> FtMark {
	code := strings.concatenate({fmt.tprintf("local mark = qed.plugin(\"filetree\").mark(%q)\n", path), `if not mark then return "" end
		return table.concat({mark.bar or "", mark.fg or "", mark.suffix or "", tostring(mark.dim == true),
			tostring((mark.added or 0) > 0 or (mark.removed or 0) > 0), tostring(mark.added or 0), tostring(mark.removed or 0)}, "\t")`}, context.temp_allocator)
	text := ft_lua(ed, code)
	parts := strings.split(text, "\t", context.temp_allocator)
	if len(parts) < 7 {
		return {}
	}
	added, _ := strconv.parse_int(parts[5])
	removed, _ := strconv.parse_int(parts[6])
	return {bar = parts[0], fg = parts[1], suffix = parts[2], dim = parts[3] == "true", sizes = parts[4] == "true", added = added, removed = removed}
}

ft_sel_deleted :: proc(ed: ^Editor) -> bool {
	sel, ok := ft_selected(ed)
	return ok && ft_mark(ed, sel.path).fg == "git_deleted"
}

FtMode :: enum {
	Nav,
	New,
	Rename,
	ConfirmDelete,
	ConfirmClose,
}

ft_mode :: proc(ed: ^Editor) -> FtMode {
	if !filetree_active(ed) {
		return .Nav
	}
	if dialog, ok := test_dialog(ed); ok && dialog.kind == "confirm" {
		switch {
		case strings.has_prefix(dialog.question, "Delete"):
			return .ConfirmDelete
		case strings.has_prefix(dialog.question, "Close"):
			return .ConfirmClose
		}
	}
	switch ft_state(ed, "state.input") {
	case "new":
		return .New
	case "rename":
		return .Rename
	}
	return .Nav
}

FtLayout :: struct {
	box, inner:                               Rect,
	body_top, body_h, filter_y, filter_sep_y: int,
	footer_y, tab_y, title_sep_y:             int,
	div_x, left_w, right_x, right_w:          int,
	bar_x:        int,
	preview:                                  bool,
}

ft_layout :: proc(ed: ^Editor) -> FtLayout {
	if !filetree_active(ed) {
		return {}
	}
	editor_render(ed)
	rect_of :: proc(ed: ^Editor, id: string) -> Rect {
		if node := ui_find(&ed.ui, fmt.tprintf("#filetree/%s", id)); node != nil {
			return node.rect
		}
		return {}
	}
	box := rect_of(ed, "filetree")
	rows := rect_of(ed, "filetree_rows")
	query := rect_of(ed, "filetree_query")
	preview := rect_of(ed, "filetree_preview")
	scroll := rect_of(ed, "filetree_scroll")
	inner := Rect{box.x + 1, box.y + 1, box.w - 2, box.h - 2}
	return {
		box = box,
		inner = inner,
		body_top = scroll.y,
		body_h = scroll.h,
		filter_y = query.y,
		filter_sep_y = query.y,
		footer_y = inner.y + inner.h - 1,
		tab_y = inner.y,
		title_sep_y = box.y,
		div_x = scroll.x + scroll.w,
		bar_x = scroll.x + scroll.w - 1,
		left_w = scroll.w,
		right_x = preview.x,
		right_w = preview.w,
		preview = preview.w > 0,
	}
}

ft_walk :: proc(ed: ^Editor) -> ^Walk {
	if list := ft_tree_list(ed); list != nil {
		return list.tree.source.walk
	}
	return nil
}

ft_set_sel :: proc(ed: ^Editor, index: int) {
	entries := ft_entries(ed)
	if index >= 0 && index < len(entries) {
		ft_select_path(ed, entries[index].path)
	}
}

ft_scroll :: proc(ed: ^Editor) -> int {
	editor_render(ed)
	return ed.ui.states["#filetree/filetree_scroll"].offset
}

ft_query :: proc(ed: ^Editor) -> string {
	ui_resolve(ed)
	if node := ui_find(&ed.ui, "#filetree/filetree_query"); node != nil {
		if buffer := ui_buffer(ed, node.buffer); buffer != nil {
			return string(buffer.lines[0].text[:])
		}
	}
	return ""
}

ft_preview :: proc(ed: ^Editor) -> ^Buffer {
	ui_resolve(ed)
	if node := ui_find(&ed.ui, "#filetree/filetree_preview"); node != nil {
		return ui_buffer(ed, node.buffer)
	}
	return nil
}

// the preview loads on a debounced timer after a move
ft_preview_settle :: proc(ed: ^Editor) {
	start := time.tick_now()
	for ms_since(start) < 3000 {
		plugin_flush(ed)
		plugin_pump(ed)
		pending := plugin_busy(ed)
		for timer in ed.plugins.timers {
			pending ||= timer.owner == "filetree"
		}
		for task in ed.plugins.tasks {
			pending ||= task.owner == "filetree"
		}
		if !pending {
			break
		}
		time.sleep(time.Millisecond * 5)
	}
	editor_render(ed)
}

ft_preview_line :: proc(ed: ^Editor, row: int) -> string {
	buffer := ft_preview(ed)
	if buffer == nil || row >= len(buffer.lines) {
		return ""
	}
	return string(buffer.lines[row].text[:])
}

ft_expand_all :: proc(ed: ^Editor, on: bool) -> bool {
	list := ft_tree_list(ed)
	if list == nil || !walk_tree_expand_all(list.tree, on) {
		return false
	}
	ft_trees_settle(ed)
	return true
}

// reads every pending dir: a tree list fills one slice per frame
ft_trees_settle :: proc(ed: ^Editor) {
	start := time.tick_now()
	for (walk_trees_busy(ed) || walk_busy(ed)) && ms_since(start) < 3000 {
		walk_pump(ed)
		walk_trees_settle(ed)
	}
	editor_render(ed)
}

ft_expanded_count :: proc(ed: ^Editor) -> int {
	if list := ft_tree_list(ed); list != nil {
		count := 0
		for _, on in list.tree.expanded {
			count += int(on)
		}
		return count
	}
	return 0
}

buffer_snapshot_tmp :: proc(b: ^Buffer) -> string {
	s := buffer_snapshot(b)
	out := strings.clone(s, context.temp_allocator)
	delete(s)
	return out
}

test_rss_mb :: proc(field: string) -> f64 {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil {
		return 0
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if strings.has_prefix(line, field) {
			kb, _ := strconv.parse_f64(strings.fields(line[len(field) + 1:], context.temp_allocator)[0])
			return kb / 1024
		}
	}
	return 0
}

TestDialog :: struct {
	kind, query, question, selected: string,
	labels:                          [dynamic]string,
}

lua_quote :: proc(text: string) -> string {
	return strings.concatenate({"[==[", text, "]==]"}, context.temp_allocator)
}

GotoState :: struct {
	open:     bool,
	count:    int,
	query:    string,
	labels:   []string,
	selected: string,
}

goto_state :: proc(ed: ^Editor) -> GotoState {
	out := ft_lua(ed, `local s = qed.plugin("goto").state()
		if not s then return "" end
		return table.concat({s.query, s.selected or "", table.concat(s.labels, "\1"), #s.labels}, "\2")`)
	if out == "" {
		return {}
	}
	parts := strings.split(out, "\x02", context.temp_allocator)
	labels := strings.split(parts[2], "\x01", context.temp_allocator) if parts[2] != "" else nil
	count, _ := strconv.parse_int(parts[3])
	return {open = true, query = parts[0], selected = parts[1], labels = labels, count = count}
}

node_rect :: proc(ed: ^Editor, id: string) -> Rect {
	editor_render(ed)
	for &mount in ed.ui.mounts {
		if node := ui_find(&ed.ui, fmt.tprintf("#%s/%s", mount.owner, id)); node != nil {
			return node.rect
		}
	}
	return {}
}

test_dialog :: proc(ed: ^Editor) -> (dialog: TestDialog, ok: bool) {
	ui := &ed.ui
	#reverse for mount in ui.mounts {
		if mount.owner == "dialog" && strings.has_prefix(mount.root.id, "dialog_") {
			dialog.kind = mount.root.id[len("dialog_"):]
			ok = true
			break
		}
	}
	if !ok {
		return
	}
	ui_resolve(ed)
	if node := ui_find(ui, "#dialog/dialog_query"); node != nil {
		if buffer := ui_buffer(ed, node.buffer); buffer != nil {
			dialog.query = string(buffer.lines[0].text[:])
		}
	}
	if node := ui_find(ui, "#dialog/dialog_question"); node != nil {
		sb := strings.builder_make(context.temp_allocator)
		for span in node.spans {
			strings.write_string(&sb, span.text)
		}
		dialog.question = strings.trim_space(strings.to_string(sb))
	}
	dialog.labels = make([dynamic]string, context.temp_allocator)
	rows := ui_find(ui, "#dialog/dialog_rows")
	if list := ui_list_find(ui, rows.list) if rows != nil else nil; list != nil {
		for match in list.matches {
			append(&dialog.labels, list.texts[match.key])
		}
		if state, has := ui.states["#dialog/dialog_rows"]; has && state.highlighted != "" {
			dialog.selected = list.texts[state.highlighted]
		}
	}
	return
}

palette_ui_labels :: proc(e: ^E2E) -> string {
	ui_resolve(&e.ed)
	node := ui_find(&e.ed.ui, "#palette/palette_results")
	if node == nil {
		return ""
	}
	list := ui_list_find(&e.ed.ui, node.list)
	if list == nil {
		return ""
	}
	ui_list_settle_all(&e.ed, list)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '|')
	for match in list.matches {
		strings.write_string(&sb, list.texts[match.key])
		strings.write_byte(&sb, '|')
	}
	return strings.to_string(sb)
}

// the layout's main editor view state (its scroll), after a frame
main_view :: proc(e: ^E2E) -> ^UiState {
	e2e_render(e)
	node := ui_find(&e.ed.ui, "#layout/main_editor")
	if node == nil {
		@(static) empty: UiState
		empty = {}
		return &empty
	}
	return ui_node_state(&e.ed.ui, node)
}

bind_format :: proc(ev: tb2.Event, allocator := context.temp_allocator) -> (string, bool) {
	if ev.type != .Key {
		return "", false
	}
	if ev.ch != 0 {
		if ev_alt(ev) {
			return fmt.aprintf("Alt+%c", ev.ch, allocator = allocator), true
		}
		if ev.ch > ' ' && ev.ch != utf8.RUNE_ERROR {
			return fmt.aprintf("%c", ev.ch, allocator = allocator), true
		}
		return "", false
	}
	if ev_alt(ev) {
		return "", false
	}
	#partial switch ev.key {
	case .Ctrl_Tilde:
		return "Ctrl+~", true
	case .Ctrl_Slash:
		return "Ctrl+/", true
	case .Ctrl_Backslash:
		return "Ctrl+\\", true
	case .Tab, .Enter:
		return "", false
	}
	if ev.key >= .Ctrl_A && ev.key <= .Ctrl_Z {
		return fmt.aprintf("Ctrl+%c", 'a' + rune(ev.key) - 1, allocator = allocator), true
	}
	return "", false
}

// rendered lines run in source order: find the block holding src, then its first line from the closest row at or above src
md_line_of_src :: proc(lines: []MdLine, src: int) -> int {
	block := -1
	for line in lines {
		if line.block > src {
			break
		}
		block = line.block
	}
	first, at, best := -1, 0, -1
	for line, i in lines {
		if line.block > block {
			break
		}
		if line.block != block {
			continue
		}
		if first < 0 {
			first = i
		}
		if line.src <= src && line.src > best {
			at, best = i, line.src
		}
	}
	return at if best >= 0 else max(first, 0)
}

command_run :: proc(editor: ^Editor, cmd: Command) {
	if cmd.owner != "" {
		plugin_command_run(editor, cmd)
		return
	}
	if command_enabled(cmd) {
		cmd.run(editor)
	}
}

safety_dialog :: proc(editor: ^Editor) -> string {
	switch editor.safety.kind {
	case .None:
		return ""
	case .Quit:
		return "quit"
	case .Close:
		return "close"
	case .Conflict:
		return "conflict"
	}
	return ""
}

api_buffer_object_push :: proc(L: ^lua.State, id: u64) {
	if lua.getfield(L, lua.REGISTRYINDEX, QED_BUFFER_OBJECT) != .FUNCTION {
		lua.pop(L, 1)
		lua.pushinteger(L, lua.Integer(id))
		return
	}
	lua.pushinteger(L, lua.Integer(id))
	lua.call(L, 1, 1)
}

editor_viewport :: proc(editor: ^Editor) -> (w, h: int) {
	w = max(0, int(tb2.width()) - editor_gutter_width(editor))
	h = max(0, int(tb2.height()) - STATUS_ROWS)
	return
}

plugin_command_chord :: proc(editor: ^Editor, cmd: Command) {
	if plugin_command_when(editor, cmd) {
		plugin_command_run(editor, cmd)
	}
}
