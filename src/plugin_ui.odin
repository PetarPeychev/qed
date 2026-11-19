package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import lua "lib:lua"
import "lib:tb2"

PLUGIN_QUERY_DEBOUNCE_MS :: 120

PluginPickItem :: struct {
	label, detail, path: string,
	row:                 int,
}

PluginUi :: struct {
	using list: FuzzyList,
	id:         u64,
	owner:      string,
	title:      string,
	items:      [dynamic]PluginPickItem,
	labels:     [dynamic]string,
	details:    [dynamic]string,
	items_ref:  i32,
	change_ref: i32,
	change_task: u64,
	query_ref:  i32,
	handle_ref: i32,
	query_task: u64,
	query_due:  bool,
	query_at:   time.Tick,
	command:    u64,
	hint:       string,
	more:       bool,
	accept:     bool,
	multi:      bool,
	paths:      bool,
	anchor:     Maybe(int),
	notified:   int,
	preview:    Preview,
	done:       bool,
	ok:         bool,
	result:     [dynamic]int,
	text:       string,
}

PluginAnswer :: struct {
	handle:     u64,
	ok, prompt: bool,
	index:      int,
	text:       string,
}

PluginPaneLine :: struct {
	text, color: string,
}

PluginPane :: struct {
	active: bool,
	id:     u64,
	owner:  string,
	title:  string,
	footer: string,
	lines:  [dynamic]PluginPaneLine,
	scroll: int,
}

plugin_ui_clear :: proc(editor: ^Editor) {
	plugin_task_kill(editor, editor.plugins.ui.change_task)
	plugin_task_kill(editor, editor.plugins.ui.query_task)
	plugin_ui_release(&editor.plugins)
}

plugin_ui_release :: proc(p: ^Plugins) {
	ui := &p.ui
	if p.L != nil {
		if ui.items_ref != 0 {
			lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ui.items_ref))
		}
		for ref in ([3]i32{ui.change_ref, ui.query_ref, ui.handle_ref}) {
			if ref != 0 {
				lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ref))
			}
		}
	}
	plugin_ui_items_free(ui)
	clear(&ui.result)
	delete(ui.title)
	delete(ui.text)
	delete(ui.hint)
	fuzzy_end(&ui.fuzzy)
	preview_reset(&ui.preview)
	ui.title, ui.text, ui.owner, ui.hint = "", "", "", ""
	ui.items_ref, ui.change_ref, ui.change_task = 0, 0, 0
	ui.query_ref, ui.handle_ref, ui.query_task, ui.command = 0, 0, 0, 0
	ui.active, ui.done, ui.ok, ui.multi, ui.paths, ui.query_due, ui.more, ui.accept = false, false, false, false, false, false, false, false
	ui.anchor = nil
	ui.id = 0
}

plugin_ui_items_free :: proc(ui: ^PluginUi) {
	for it in ui.items {
		delete(it.label)
		delete(it.detail)
		delete(it.path)
	}
	clear(&ui.items)
	clear(&ui.labels)
	clear(&ui.details)
}

plugin_ui_items_set :: proc(ui: ^PluginUi, items: []PluginPickItem) {
	plugin_ui_items_free(ui)
	for it in items {
		append(&ui.items, PluginPickItem{strings.clone(it.label), strings.clone(it.detail), strings.clone(it.path), it.row})
		ui.paths ||= it.path != ""
	}
	for it in ui.items {
		append(&ui.labels, it.label)
		append(&ui.details, it.detail)
	}
}

plugin_ui_due :: proc(p: ^Plugins) -> bool {
	ui := &p.ui
	if !ui.active || ui.query_ref == 0 {
		return false
	}
	return ui.query_due || ui.accept || (len(ui.matches) > 0 && ui.matches[ui.selected] != ui.notified)
}

plugin_ui_query_touch :: proc(ui: ^PluginUi) {
	ui.accept = false
	ui.query_due = true
	ui.query_at = time.tick_add(time.tick_now(), PLUGIN_QUERY_DEBOUNCE_MS * time.Millisecond)
}

plugin_ui_pump :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	if !plugin_ui_due(&editor.plugins) {
		return
	}
	if ui.query_due && plugin_tick_due(ui.query_at, time.tick_now()) {
		ui.query_due = false
		plugin_task_kill(editor, ui.query_task)
		ui.query_task = 0
		id := ui.id
		task, finished := plugin_task_start(editor, ui.owner, .Command, {ref = ui.query_ref, args = .Query, line = strings.clone(textfield_str(&ui.field), context.temp_allocator), item_ref = ui.handle_ref})
		if ui = &editor.plugins.ui; !finished && ui.active && ui.id == id {
			ui.query_task = task
		}
	}
	plugin_ui_changed(editor)
	if ui = &editor.plugins.ui; ui.accept && !ui.query_due && !plugin_task_alive(&editor.plugins, ui.query_task) {
		ui.accept = false
		plugin_ui_accept(editor)
	}
}

plugin_pane_close :: proc(p: ^Plugins) {
	pn := &p.pane
	for l in pn.lines {
		delete(l.text)
		delete(l.color)
	}
	clear(&pn.lines)
	delete(pn.title)
	delete(pn.footer)
	pn.title, pn.footer, pn.owner = "", "", ""
	pn.active = false
	pn.id = 0
	pn.scroll = 0
}

plugin_ui_destroy :: proc(p: ^Plugins) {
	plugin_ui_release(p)
	delete(p.ui.items)
	delete(p.ui.labels)
	delete(p.ui.details)
	delete(p.ui.result)
	fuzzy_list_destroy(&p.ui.list)
	preview_destroy(&p.ui.preview)
	plugin_pane_close(p)
	delete(p.pane.lines)
}

plugin_ui_unload :: proc(editor: ^Editor, owner: string) {
	p := &editor.plugins
	if p.ui.id != 0 && p.ui.owner == owner {
		plugin_ui_clear(editor)
	}
	if p.pane.active && p.pane.owner == owner {
		plugin_pane_close(p)
	}
	pane_unload(editor, owner)
	if p.theme_owner == owner {
		editor_theme_restore(editor)
		p.theme_owner = ""
	}
}

plugin_overlay_open :: proc(editor: ^Editor) -> bool {
	if pane_focus(editor) != nil {
		return true
	}
	for ov in editor_overlays(editor) {
		if ov.active^ && ov.active != &editor.filetree.active {
			return true
		}
	}
	return false
}

plugin_ui_prefix :: proc(ui: ^PluginUi) -> string {
	return fmt.tprintf("%s ", ui.title) if ui.title != "" else "> "
}

plugin_ui_rows :: proc(editor: ^Editor) -> int {
	ui := &editor.plugins.ui
	return overlay_layout(editor, .Code).body_h if ui.paths else PALETTE_MAX_ROWS
}

plugin_ui_preview :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	if !ui.paths {
		return
	}
	lay := overlay_layout(editor, .Code)
	if len(ui.matches) == 0 || !lay.preview {
		preview_reset(&ui.preview)
		return
	}
	it := ui.items[ui.matches[ui.selected]]
	preview_set_file(&ui.preview, it.path, it.row, lay.body_h)
}

plugin_ui_changed :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	if !ui.active || len(ui.matches) == 0 {
		return
	}
	item := ui.matches[ui.selected]
	if item == ui.notified {
		return
	}
	ui.notified = item
	if ui.change_ref == 0 {
		return
	}
	plugin_task_kill(editor, ui.change_task)
	ui.change_task = 0
	id, finished := plugin_task_start(editor, ui.owner, .Command, {ref = ui.change_ref, args = .Item, item_ref = ui.items_ref, item = item + 1})
	if !finished && editor.plugins.ui.active {
		editor.plugins.ui.change_task = id
	}
}

plugin_ui_resolve :: proc(editor: ^Editor, ok: bool) {
	p := &editor.plugins
	ui := &p.ui
	if !ui.active {
		return
	}
	ui.active = false
	ui.done = true
	ui.ok = ok
	if ui.query_ref != 0 {
		ui.text = strings.clone(textfield_str(&ui.field))
	}
	if ok {
		lo, hi := ui.selected, ui.selected
		if a, has := ui.anchor.?; has && ui.multi {
			lo, hi = min(a, ui.selected), max(a, ui.selected)
		}
		for pos in lo ..= hi {
			append(&ui.result, ui.matches[pos])
		}
	}
	fuzzy_end(&ui.fuzzy)
	preview_reset(&ui.preview)
	plugin_task_kill(editor, ui.change_task)
	plugin_task_kill(editor, ui.query_task)
	ui.change_task, ui.query_task = 0, 0
	id := ui.id
	for w in plugin_waiters(p, .Ui, id) {
		plugin_task_resume(editor, w, 0)
	}
	if p.ui.id == id {
		plugin_ui_clear(editor)
	}
}

plugin_ui_accept :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	if ui.query_ref != 0 && (ui.query_due || plugin_task_alive(&editor.plugins, ui.query_task)) {
		ui.accept = true
		ui.query_at = time.tick_now()
		return
	}
	if len(ui.matches) == 0 {
		return
	}
	plugin_ui_resolve(editor, true)
}

plugin_ui_cancel :: proc(editor: ^Editor) {
	plugin_ui_resolve(editor, false)
}

plugin_ui_count :: proc(ui: ^PluginUi, lay: OverlayLayout) -> (count: string, prompt_w: int) {
	if n := len(ui.matches); n > 0 {
		count = fmt.tprintf("%d+" if ui.more else "%d", n)
	}
	prompt_w = lay.left_w - 1
	if count != "" {
		prompt_w = max(1, prompt_w - len(count) - 1)
	}
	return
}

plugin_ui_chord :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	for cmd in editor.plugins.commands {
		if cmd.id == editor.plugins.ui.command {
			return plugin_command_matches(cmd, ev)
		}
	}
	return false
}

plugin_ui_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	ui := &editor.plugins.ui
	if plugin_ui_chord(editor, ev) {
		plugin_ui_cancel(editor)
		return
	}
	nav := ev.key == .Esc || ev.key == .Enter || ev.key == .Arrow_Up || ev.key == .Arrow_Down
	if ui.multi && ev_shift(ev) && (ev.key == .Arrow_Up || ev.key == .Arrow_Down) {
		if ui.anchor == nil {
			ui.anchor = ui.selected
		}
		fuzzy_list_move(&ui.list, -1 if ev.key == .Arrow_Up else 1, plugin_ui_rows(editor))
	} else if ui.query_ref != 0 && !nav {
		if textfield_key(&ui.field, ev) {
			plugin_ui_query_touch(ui)
		}
	} else {
		prev := ui.selected
		if fuzzy_list_key(editor, &ui.list, ev, plugin_ui_accept, plugin_ui_cancel, plugin_ui_rows(editor)) || ui.selected != prev {
			ui.anchor = nil
		}
	}
	if ui.active {
		plugin_ui_preview(editor)
		plugin_ui_changed(editor)
	}
}

plugin_ui_paste :: proc(editor: ^Editor, text: string) {
	ui := &editor.plugins.ui
	if ui.query_ref != 0 {
		if textfield_insert_flat(&ui.field, text) {
			plugin_ui_query_touch(ui)
		}
	} else if textfield_insert_flat(&ui.field, text) {
		fuzzy_list_refilter(&ui.list)
		ui.anchor = nil
		plugin_ui_preview(editor)
		plugin_ui_changed(editor)
	}
}

plugin_ui_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	ui := &editor.plugins.ui
	prev := ui.selected
	if ui.paths {
		lay := overlay_layout(editor, .Code)
		if lay.preview && preview_wheel(&ui.preview, ev, {lay.right_x, lay.inner.y, lay.right_w, lay.inner.h}, lay.inner.h) {
			return
		}
		_, prompt_w := plugin_ui_count(ui, lay)
		idx, activate := overlay_list_mouse(editor, ev, lay, len(ui.matches), &ui.scroll, &ui.field, plugin_ui_cancel, plugin_ui_prefix(ui), prompt_w)
		if idx < 0 {
			return
		}
		ui.selected = idx
		if activate {
			plugin_ui_accept(editor)
		}
	} else {
		fuzzy_list_center_mouse(editor, &ui.list, ev, plugin_ui_accept, plugin_ui_cancel, plugin_ui_prefix(ui))
	}
	if ui.active && ui.selected != prev {
		ui.anchor = nil
		plugin_ui_preview(editor)
		plugin_ui_changed(editor)
	}
}

plugin_ui_render :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	if !ui.paths {
		fuzzy_list_center_render(editor, &ui.list, ui.labels[:], ui.details[:], plugin_ui_prefix(ui), ui.anchor if ui.multi else nil)
		return
	}
	lay := overlay_layout(editor, .Code)
	inner := pane_draw_box(lay.box)
	count, prompt_w := plugin_ui_count(ui, lay)
	if count != "" {
		pane_text(lay.div_x - len(count), inner.y, len(count), count, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	overlay_prompt_render(inner.x + 1, inner.y, prompt_w, &ui.field, plugin_ui_prefix(ui))
	if len(ui.matches) == 0 && ui.hint != "" {
		pane_text(inner.x + 1, lay.body_top, lay.left_w - 1, ui.hint, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}
	end := min(ui.scroll + lay.body_h, len(ui.matches))
	for i in ui.scroll ..< end {
		item := ui.matches[i]
		y := lay.body_top + (i - ui.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if overlay_row_selected(i, ui.selected, ui.anchor if ui.multi else nil) {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, lay.left_w, fg, bg)
		}
		pane_text(inner.x + 1, y, lay.left_w - 1, ui.labels[item], fg, bg)
		if d := ui.details[item]; d != "" {
			dw := visual_width(transmute([]u8)d)
			pane_text(inner.x + lay.left_w - 1 - dw, y, dw, d, COLOR_PANE_SEL_FG if bg == COLOR_PANE_SEL_BG else COLOR_PANE_SHORTCUT_FG, bg)
		}
	}
	if lay.preview {
		preview_render(&ui.preview, lay.right_x + 1, inner.y, lay.right_w - 1, inner.h)
		bottom := lay.box.y + lay.box.h - 1
		for y in lay.box.y + 1 ..< bottom {
			tb2.set_cell(i32(lay.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
		}
		tb2.set_cell(i32(lay.div_x), i32(lay.box.y), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
		tb2.set_cell(i32(lay.div_x), i32(bottom), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.box.x), i32(lay.title_sep_y), '├', COLOR_PANE_BORDER, COLOR_PANE_BG)
	for x in inner.x ..< lay.div_x {
		tb2.set_cell(i32(x), i32(lay.title_sep_y), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.title_sep_y), '┤', COLOR_PANE_BORDER, COLOR_PANE_BG)
	pane_draw_scrollbar(lay.div_x, lay.body_top, lay.body_h, ui.scroll, len(ui.matches))
}

plugin_pane_body_h :: proc(editor: ^Editor) -> int {
	lay := logview_layout(editor)
	return max(1, lay.footer_sep_y - lay.body_top)
}

plugin_pane_scroll :: proc(editor: ^Editor, delta: int) {
	pn := &editor.plugins.pane
	overlay_scroll_by(&pn.scroll, delta, len(pn.lines), plugin_pane_body_h(editor))
}

plugin_pane_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	#partial switch ev.key {
	case .Esc:
		plugin_pane_close(&editor.plugins)
	case .Arrow_Up:
		plugin_pane_scroll(editor, -1)
	case .Arrow_Down:
		plugin_pane_scroll(editor, 1)
	}
}

plugin_pane_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		plugin_pane_scroll(editor, -WHEEL_SCROLL_LINES)
	case .Mouse_Wheel_Down:
		plugin_pane_scroll(editor, WHEEL_SCROLL_LINES)
	case .Mouse_Left:
		if !mouse_in_rect(ev, logview_layout(editor).box) && !ev_motion(ev) {
			plugin_pane_close(&editor.plugins)
		}
	}
}

plugin_pane_render :: proc(editor: ^Editor) {
	pn := &editor.plugins.pane
	lay := logview_layout(editor)
	inner := pane_draw_box(lay.box)
	pane_text(inner.x + 1, inner.y, inner.w - 2, pn.title, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_hline(lay.box, lay.title_sep_y)
	h := plugin_pane_body_h(editor)
	pn.scroll = clamp(pn.scroll, 0, max(0, len(pn.lines) - h))
	for i in pn.scroll ..< min(pn.scroll + h, len(pn.lines)) {
		l := pn.lines[i]
		fg := COLOR_PANE_FG
		if col, ok := g_theme_colors[l.color]; ok && l.color != "" {
			fg = col
		}
		pane_text(inner.x + 1, lay.body_top + i - pn.scroll, inner.w - 2, l.text, fg, COLOR_PANE_BG)
	}
	pane_draw_scrollbar(lay.box.x + lay.box.w - 1, lay.body_top, h, pn.scroll, len(pn.lines))
	pane_hline(lay.box, lay.footer_sep_y)
	footer := pn.footer if pn.footer != "" else "↑↓ scroll  Esc close"
	pane_text(inner.x + 1, lay.footer_y, inner.w - 2, footer, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	tb2.hide_cursor()
}

api_busy :: proc(L: ^lua.State) -> c.int {
	return api_fail(L, "busy")
}

plugin_ui_open :: proc(editor: ^Editor, owner, title: string) -> ^PluginUi {
	p := &editor.plugins
	plugin_ui_clear(editor)
	ui := &p.ui
	ui.owner = owner
	ui.id = plugin_next_id(p)
	ui.title = strings.clone(title)
	fuzzy_list_reset(&ui.list)
	editor_clear_message(editor)
	return ui
}

plugin_ui_wait :: proc(L: ^lua.State, p: ^Plugins, task: u64) -> c.int {
	ui := &p.ui
	ui.active = true
	p.tasks[plugin_task_index(p, task)].wait = {kind = .Ui, id = ui.id}
	return lua.yieldk(L, 0, lua.KContext(ui.id), qed_ui_k)
}

qed_ui_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_ui_k)
	}
	context = entry.ctx
	p := &entry.editor.plugins
	ui := &p.ui
	if ui.id != u64(ctx) || !ui.done {
		lua.pushnil(L)
		return 1
	}
	lua.L_checkstack(L, 4, "ui result")
	query := ui.query_ref != 0
	if !ui.ok {
		lua.pushnil(L)
		if !query {
			return 1
		}
		lua.pushnil(L)
		lua.pushodinstring(L, ui.text)
		return 3
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ui.items_ref))
	if ui.multi {
		lua.createtable(L, c.int(len(ui.result)), 0)
		for item, i in ui.result {
			lua.rawgeti(L, -2, lua.Integer(item + 1))
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	} else {
		lua.rawgeti(L, -1, lua.Integer(ui.result[0] + 1))
	}
	lua.remove(L, -2)
	if query {
		lua.pushnil(L)
		lua.pushodinstring(L, ui.text)
	}
	plugin_ui_clear(entry.editor)
	return 3 if query else 1
}

api_pick_items :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> []PluginPickItem {
	lua.L_checkstack(L, 4, "pick items")
	n := int(lua.rawlen(L, idx))
	parsed := make([]PluginPickItem, n, context.temp_allocator)
	for i in 1 ..= n {
		#partial switch lua.rawgeti(L, idx, lua.Integer(i)) {
		case .STRING:
			s, _ := lua.toodinstring(L, -1)
			parsed[i - 1].label = strings.clone(s, context.temp_allocator)
		case .TABLE:
			t := lua.gettop(L)
			it := &parsed[i - 1]
			it.label, _ = api_field_string(L, t, "label")
			it.detail, _ = api_field_string(L, t, "detail")
			it.path, _ = api_field_string(L, t, "path")
			if lua.getfield(L, t, "pos") == .TABLE {
				it.row, _ = api_field_int(L, lua.gettop(L), "row")
			}
			lua.pop(L, 1)
			if it.label == "" {
				it.label = it.path
			}
			if it.path != "" {
				it.path = api_path(editor, it.path)
			}
		case:
			plugin_raise(L, fmt.tprintf("items[%d] must be a string or a table", i))
		}
		lua.pop(L, 1)
	}
	return parsed
}

qed_pick :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table {items, prompt?, initial?, on_change?, multi?, query?, on_query?} expected")
	}
	lua.settop(L, 1)
	lua.L_checkstack(L, 6, "pick options")
	query_t := lua.getfield(L, 1, "on_query")
	lua.pop(L, 1)
	if query_t != .FUNCTION && query_t != .NIL {
		plugin_raise(L, "on_query must be a function")
	}
	parsed: []PluginPickItem
	#partial switch lua.getfield(L, 1, "items") {
	case .TABLE:
		parsed = api_pick_items(L, editor, 2)
	case .NIL:
		if query_t != .FUNCTION {
			plugin_raise(L, "items must be a table")
		}
		lua.pop(L, 1)
		lua.newtable(L)
	case:
		plugin_raise(L, "items must be a table")
	}
	text, _ := api_field_string(L, 1, "query")
	prompt, _ := api_field_string(L, 1, "prompt")
	initial := -1
	#partial switch lua.getfield(L, 1, "initial") {
	case .NIL:
	case .NUMBER:
		initial = api_int(L, -1, "initial must be an item index") - 1
	case .STRING:
		s, _ := lua.toodinstring(L, -1)
		for it, i in parsed {
			if it.label == s {
				initial = i
				break
			}
		}
	case:
		plugin_raise(L, "initial must be an item index or label")
	}
	lua.pop(L, 1)
	change_t := lua.getfield(L, 1, "on_change")
	lua.pop(L, 1)
	if change_t != .FUNCTION && change_t != .NIL {
		plugin_raise(L, "on_change must be a function")
	}
	multi_t := lua.getfield(L, 1, "multi")
	multi := bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	if multi_t != .BOOLEAN && multi_t != .NIL {
		plugin_raise(L, "multi must be a boolean")
	}
	pl := api_loaded(L, editor)
	task := api_await(L, p, "qed.pick")
	task_id, command := task.id, task.command
	if plugin_overlay_open(editor) {
		return api_busy(L)
	}

	ui := plugin_ui_open(editor, pl.name, prompt)
	ui.command = command
	plugin_ui_items_set(ui, parsed)
	ui.multi = multi
	ui.items_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	if change_t == .FUNCTION {
		lua.getfield(L, 1, "on_change")
		ui.change_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	}
	textfield_set(&ui.field, text)
	textfield_select_all(&ui.field)
	ui.fuzzy = fuzzy_begin(ui.labels[:] if query_t != .FUNCTION else nil)
	fuzzy_list_refilter(&ui.list)
	if query_t == .FUNCTION {
		lua.getfield(L, 1, "on_query")
		ui.query_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
		api_handle_push(L, ui.id, {{"set", qed_picker_set}})
		ui.handle_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
		ui.paths = true
		ui.query_due = true
		ui.query_at = time.tick_now()
	}
	for m, i in ui.matches {
		if m == initial {
			ui.selected = i
			break
		}
	}
	fuzzy_list_scroll(&ui.list, plugin_ui_rows(editor))
	ui.notified = ui.matches[ui.selected] if len(ui.matches) > 0 else -1
	plugin_ui_preview(editor)
	return plugin_ui_wait(L, p, task_id)
}

qed_picker_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "items table expected")
	}
	#partial switch lua.type(L, 3) {
	case .NIL, .NONE, .TABLE:
	case:
		lua.L_argerror(L, 3, "options table expected")
	}
	lua.settop(L, 3)
	items := api_pick_items(L, editor, 2)
	selected := 1
	more := false
	hint := ""
	if lua.type(L, 3) == .TABLE {
		if lua.getfield(L, 3, "selected") != .NIL {
			selected = api_int(L, -1, "selected must be an item index")
		}
		lua.pop(L, 1)
		lua.getfield(L, 3, "more")
		more = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		hint, _ = api_field_string(L, 3, "hint")
	}
	ui := &editor.plugins.ui
	live := ui.active && ui.id == api_handle_id(L)
	if !live {
		lua.pushboolean(L, false)
		return 1
	}
	plugin_ui_items_set(ui, items)
	lua.L_unref(L, lua.REGISTRYINDEX, c.int(ui.items_ref))
	lua.pushvalue(L, 2)
	ui.items_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	delete(ui.hint)
	ui.hint = strings.clone(hint)
	ui.more = more
	clear(&ui.matches)
	for i in 0 ..< len(items) {
		append(&ui.matches, i)
	}
	ui.anchor = nil
	ui.notified = -1
	ui.selected = clamp(selected - 1, 0, max(0, len(items) - 1))
	rows := plugin_ui_rows(editor)
	ui.scroll = max(0, ui.selected - rows / 2)
	fuzzy_list_scroll(&ui.list, rows)
	plugin_ui_preview(editor)
	lua.pushboolean(L, true)
	return 1
}

qed_prompt :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table {prompt, text?} expected")
	}
	lua.settop(L, 1)
	prompt, _ := api_field_string(L, 1, "prompt")
	text, _ := api_field_string(L, 1, "text")
	pl := api_loaded(L, editor)
	task := api_await(L, p, "qed.prompt").id
	if pane_safety_open(editor) {
		return api_busy(L)
	}
	prefix := fmt.tprintf("%s ", prompt) if prompt != "" else "> "
	fields := []PaneField{{prompt = prefix}}
	pn := plugin_ask_open(editor, pl.name, {size = .Palette, fields = fields})
	if pn == nil {
		return api_busy(L)
	}
	textfield_set(&pn.fields[0].field, text)
	return plugin_ask_wait(L, p, task, pn.handle)
}

qed_confirm :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	question := strings.clone(api_string(L, 1), context.temp_allocator)
	choices := make([dynamic]string, context.temp_allocator)
	#partial switch lua.type(L, 2) {
	case .NIL, .NONE:
		append(&choices, "Yes", "No")
	case .TABLE:
		lua.L_checkstack(L, 2, "confirm choices")
		for i in 1 ..= int(lua.rawlen(L, 2)) {
			if lua.rawgeti(L, 2, lua.Integer(i)) != .STRING {
				plugin_raise(L, "choices must be strings")
			}
			s, _ := lua.toodinstring(L, -1)
			append(&choices, strings.clone(s, context.temp_allocator))
			lua.pop(L, 1)
		}
		if len(choices) == 0 {
			lua.L_argerror(L, 2, "choices must not be empty")
		}
	case:
		lua.L_argerror(L, 2, "choices must be a table of strings")
	}
	pl := api_loaded(L, editor)
	task := api_await(L, p, "qed.confirm").id
	if pane_safety_open(editor) {
		return api_busy(L)
	}
	text := []string{question}
	pn := plugin_ask_open(editor, pl.name, {text = text, list = {items = choices[:]}})
	if pn == nil {
		return api_busy(L)
	}
	return plugin_ask_wait(L, p, task, pn.handle)
}

plugin_ask_open :: proc(editor: ^Editor, owner: string, spec: Pane) -> ^Pane {
	spec := spec
	spec.owner = plugin_name_intern(&editor.plugins, owner)
	spec.on = {activate = plugin_ask_activate, close = plugin_ask_close}
	if f := pane_focus(editor); f != nil {
		spec.kind, spec.parent = .Child, f.handle
	} else if ov := editor_overlay_active(editor); ov != nil {
		spec.kind, spec.over = .Child, ov
	}
	editor_clear_message(editor)
	return pane_open(editor, spec)
}

plugin_ask_wait :: proc(L: ^lua.State, p: ^Plugins, task, handle: u64) -> c.int {
	p.tasks[plugin_task_index(p, task)].wait = {kind = .Pane, id = handle}
	return lua.yieldk(L, 0, lua.KContext(handle), qed_ask_k)
}

plugin_ask_answer :: proc(editor: ^Editor, pn: ^Pane, ok: bool) {
	p := &editor.plugins
	prev := p.answer
	p.answer = {handle = pn.handle, ok = ok, index = pn.list.sel}
	if len(pn.fields) > 0 {
		p.answer.text = textfield_str(&pn.fields[0].field)
		p.answer.prompt = true
	}
	for w in plugin_waiters(p, .Pane, pn.handle) {
		plugin_task_resume(editor, w, 0)
	}
	p.answer = prev
}

plugin_ask_activate :: proc(editor: ^Editor, pn: ^Pane) {
	plugin_ask_answer(editor, pn, true)
}

plugin_ask_close :: proc(editor: ^Editor, pn: ^Pane) {
	plugin_ask_answer(editor, pn, false)
}

qed_ask_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	entry := plugin_entry(L)
	if entry == nil || entry.editor.plugins.current != L {
		return lua.yieldk(L, 0, ctx, qed_ask_k)
	}
	context = entry.ctx
	a := entry.editor.plugins.answer
	if a.handle != u64(ctx) || !a.ok {
		lua.pushnil(L)
	} else if a.prompt {
		lua.pushodinstring(L, a.text)
	} else {
		lua.pushinteger(L, lua.Integer(a.index + 1))
	}
	return 1
}

api_pane_lines :: proc(L: ^lua.State, idx: c.int) -> []PluginPaneLine {
	if lua.type(L, idx) != .TABLE {
		plugin_raise(L, "lines must be a table")
	}
	lua.L_checkstack(L, 4, "pane lines")
	n := int(lua.rawlen(L, idx))
	out := make([]PluginPaneLine, n, context.temp_allocator)
	for i in 1 ..= n {
		#partial switch lua.rawgeti(L, idx, lua.Integer(i)) {
		case .STRING:
			s, _ := lua.toodinstring(L, -1)
			out[i - 1].text = strings.clone(s, context.temp_allocator)
		case .TABLE:
			t := lua.gettop(L)
			out[i - 1].text, _ = api_field_string(L, t, "text")
			out[i - 1].color, _ = api_field_string(L, t, "color")
		case:
			plugin_raise(L, fmt.tprintf("lines[%d] must be a string or {text, color}", i))
		}
		lua.pop(L, 1)
	}
	return out
}

plugin_pane_set :: proc(pn: ^PluginPane, lines: []PluginPaneLine) {
	for l in pn.lines {
		delete(l.text)
		delete(l.color)
	}
	clear(&pn.lines)
	for l in lines {
		append(&pn.lines, PluginPaneLine{strings.clone(l.text), strings.clone(l.color)})
	}
}

qed_pane :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table {title, lines, footer?} expected")
	}
	lua.settop(L, 1)
	title, _ := api_field_string(L, 1, "title")
	footer, _ := api_field_string(L, 1, "footer")
	lua.getfield(L, 1, "lines")
	lines := api_pane_lines(L, 2)
	lua.settop(L, 1)
	pl := api_loaded(L, editor)
	if plugin_overlay_open(editor) {
		return api_busy(L)
	}
	plugin_pane_close(p)
	pn := &p.pane
	pn.id = plugin_next_id(p)
	pn.owner = pl.name
	pn.title = strings.clone(title)
	pn.footer = strings.clone(footer)
	plugin_pane_set(pn, lines)
	pn.active = true
	editor_clear_message(editor)
	api_handle_push(L, pn.id, {{"set", qed_pane_set}, {"close", qed_pane_close}})
	return 1
}

qed_pane_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	pn := &entry.editor.plugins.pane
	lines := api_pane_lines(L, 2)
	live := pn.active && pn.id == api_handle_id(L)
	if live {
		plugin_pane_set(pn, lines)
	}
	lua.pushboolean(L, b32(live))
	return 1
}

qed_pane_close :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	if p.pane.active && p.pane.id == api_handle_id(L) {
		plugin_pane_close(p)
	}
	return 0
}

qed_theme_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	name := strings.clone(api_string(L, 1), context.temp_allocator)
	persist := false
	#partial switch lua.type(L, 2) {
	case .NIL, .NONE:
	case .TABLE:
		lua.getfield(L, 2, "persist")
		persist = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	case:
		lua.L_argerror(L, 2, "options table expected")
	}
	ok, err := editor_theme_set(entry.editor, name, persist)
	if pl := plugin_owner(L, entry.editor); pl != nil && !persist && entry.editor.theme_shown != "" {
		entry.editor.plugins.theme_owner = pl.name
	}
	if !ok {
		return api_fail(L, err)
	}
	lua.pushboolean(L, true)
	return 1
}

qed_theme_list :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	names := theme_names(config_path())
	lua.createtable(L, c.int(len(names)), 0)
	for n, i in names {
		lua.pushodinstring(L, n)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

qed_theme_current :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, editor_theme_current(entry.editor))
	return 1
}

qed_languages :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.createtable(L, len(Language), 0)
	n := 0
	for info, lang in LANGUAGES {
		if lang == .MarkdownInline {
			continue
		}
		n += 1
		lua.pushodinstring(L, info.name)
		lua.rawseti(L, -2, lua.Integer(n))
	}
	return 1
}

PluginStatus :: struct {
	owner, id, text, color, sep: string,
	chunks:                      [dynamic]PluginPaneLine,
	right, early:                bool,
	drop:                        int,
}

plugin_status_free :: proc(s: PluginStatus) {
	delete(s.id)
	delete(s.text)
	delete(s.color)
	delete(s.sep)
	for c in s.chunks {
		delete(c.text)
		delete(c.color)
	}
	delete(s.chunks)
}

plugin_status_find :: proc(p: ^Plugins, owner, id: string) -> int {
	for s, i in p.status {
		if s.owner == owner && s.id == id {
			return i
		}
	}
	return -1
}

plugin_status_unload :: proc(p: ^Plugins, owner: string) {
	for i := len(p.status) - 1; i >= 0; i -= 1 {
		if p.status[i].owner == owner {
			plugin_status_free(p.status[i])
			ordered_remove(&p.status, i)
		}
	}
}

plugin_status_segs :: proc(p: ^Plugins, left, right: ^[dynamic]StatusSeg, early: bool) {
	at := 0
	for s in p.status {
		if s.text == "" || (s.right ? early : s.early != early) {
			continue
		}
		fg := COLOR_PANE_FG
		if s.color != "" {
			fg = g_theme_colors[s.color] or_else COLOR_PANE_FG
		}
		seg := StatusSeg{sep = s.sep, text = s.text, fg = fg, kind = .Plugin, drop = s.drop}
		if len(s.chunks) > 0 {
			chunks := make([]StatusChunk, len(s.chunks), context.temp_allocator)
			for c, i in s.chunks {
				chunks[i] = {c.text, g_theme_colors[c.color] or_else fg}
			}
			seg.chunks = chunks
		}
		if s.right {
			inject_at(right, at, seg)
			at += 1
		} else {
			append(left, seg)
		}
	}
}

api_theme_color :: proc(L: ^lua.State, key: string) {
	if key not_in g_theme_colors {
		plugin_raise(L, fmt.tprintf("unknown theme color '%s'", key))
	}
}

api_one_line :: proc(s: string) -> string {
	if !strings.contains_any(s, "\t\r\n") {
		return s
	}
	out, _ := strings.replace_all(s, "\r\n", " ", context.temp_allocator)
	for ch in ([3]string{"\t", "\r", "\n"}) {
		out, _ = strings.replace_all(out, ch, " ", context.temp_allocator)
	}
	return out
}

qed_status_set :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	id := api_string(L, 1)
	if lua.type(L, 2) != .TABLE {
		lua.L_argerror(L, 2, "table {text, color?, side?, drop?} expected")
	}
	lua.settop(L, 2)
	lua.L_checkstack(L, 4, "status options")
	text := ""
	chunks: []PluginPaneLine
	lua.getfield(L, 2, "text")
	#partial switch lua.type(L, -1) {
	case .STRING:
		text, _ = lua.toodinstring(L, -1)
		text = api_one_line(strings.clone(text, context.temp_allocator))
	case .TABLE:
		chunks = api_pane_lines(L, lua.gettop(L))
		parts := make([]string, len(chunks), context.temp_allocator)
		for &c, i in chunks {
			c.text = api_one_line(c.text)
			if c.color != "" {
				api_theme_color(L, c.color)
			}
			parts[i] = c.text
		}
		text = strings.concatenate(parts, context.temp_allocator)
	case:
		return plugin_raise(L, "text must be a string or a list of {text, color}")
	}
	lua.pop(L, 1)
	sep := "  "
	if v, ok := api_field_string(L, 2, "sep"); ok {
		sep = api_one_line(v)
	}
	lua.getfield(L, 2, "early")
	early := bool(lua.toboolean(L, -1))
	lua.pop(L, 1)
	color, _ := api_field_string(L, 2, "color")
	if color != "" {
		api_theme_color(L, color)
	}
	side, _ := api_field_string(L, 2, "side")
	if side != "" && side != "left" && side != "right" {
		return plugin_raise(L, `side must be "left" or "right"`)
	}
	drop := 1
	if lua.getfield(L, 2, "drop") != .NIL {
		drop = api_int(L, -1, "drop must be an integer")
		if drop < 0 {
			return plugin_raise(L, "drop must be >= 0")
		}
	}
	lua.pop(L, 1)
	pl := api_loaded(L, editor)
	owner := plugin_name_intern(p, pl.name)
	s := PluginStatus{owner = owner, text = strings.clone(text), color = strings.clone(color), sep = strings.clone(sep), right = side == "right", early = early, drop = drop}
	for c in chunks {
		append(&s.chunks, PluginPaneLine{strings.clone(c.text), strings.clone(c.color)})
	}
	if i := plugin_status_find(p, owner, id); i >= 0 {
		s.id = p.status[i].id
		p.status[i].id = ""
		plugin_status_free(p.status[i])
		p.status[i] = s
	} else {
		s.id = strings.clone(id)
		append(&p.status, s)
	}
	return 0
}

qed_status_clear :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	id := api_string(L, 1)
	pl := api_loaded(L, entry.editor)
	if i := plugin_status_find(p, pl.name, id); i >= 0 {
		plugin_status_free(p.status[i])
		ordered_remove(&p.status, i)
	}
	return 0
}
