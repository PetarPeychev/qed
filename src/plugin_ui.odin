package main

import "core:c"
import "core:fmt"
import "core:strings"
import lua "lib:lua"
import "lib:tb2"

PluginUiKind :: enum {
	Pick,
	Prompt,
	Confirm,
}

PluginPickItem :: struct {
	label, detail, path: string,
	row:                 int,
}

PluginUi :: struct {
	using list: FuzzyList,
	kind:       PluginUiKind,
	id:         u64,
	owner:      string,
	title:      string,
	items:      [dynamic]PluginPickItem,
	labels:     [dynamic]string,
	details:    [dynamic]string,
	items_ref:  i32,
	change_ref: i32,
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

plugui_clear :: proc(p: ^Plugins) {
	ui := &p.ui
	if p.L != nil {
		if ui.items_ref != 0 {
			lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ui.items_ref))
		}
		if ui.change_ref != 0 {
			lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(ui.change_ref))
		}
	}
	for it in ui.items {
		delete(it.label)
		delete(it.detail)
		delete(it.path)
	}
	clear(&ui.items)
	clear(&ui.labels)
	clear(&ui.details)
	clear(&ui.result)
	delete(ui.title)
	delete(ui.text)
	fuzzy_end(&ui.fuzzy)
	preview_reset(&ui.preview)
	ui.title, ui.text, ui.owner = "", "", ""
	ui.items_ref, ui.change_ref = 0, 0
	ui.active, ui.done, ui.ok, ui.multi, ui.paths = false, false, false, false, false
	ui.anchor = nil
	ui.id = 0
}

plugpane_close :: proc(p: ^Plugins) {
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
	plugui_clear(p)
	delete(p.ui.items)
	delete(p.ui.labels)
	delete(p.ui.details)
	delete(p.ui.result)
	fuzzy_list_destroy(&p.ui.list)
	preview_destroy(&p.ui.preview)
	plugpane_close(p)
	delete(p.pane.lines)
}

plugin_ui_unload :: proc(editor: ^Editor, owner: string) {
	p := &editor.plugins
	if p.ui.id != 0 && p.ui.owner == owner {
		plugui_clear(p)
	}
	if p.pane.active && p.pane.owner == owner {
		plugpane_close(p)
	}
}

plugin_overlay_open :: proc(editor: ^Editor) -> bool {
	for ov in editor_overlays(editor) {
		if ov.active^ {
			return true
		}
	}
	return false
}

plugui_prefix :: proc(ui: ^PluginUi) -> string {
	return fmt.tprintf("%s ", ui.title) if ui.title != "" else "> "
}

plugui_rows :: proc(editor: ^Editor) -> int {
	ui := &editor.plugins.ui
	return overlay_layout(editor, .Code).body_h if ui.paths else PALETTE_MAX_ROWS
}

plugui_preview :: proc(editor: ^Editor) {
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

plugui_changed :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	if !ui.active || ui.kind != .Pick || len(ui.matches) == 0 {
		return
	}
	item := ui.matches[ui.selected]
	if item == ui.notified {
		return
	}
	ui.notified = item
	if ui.change_ref != 0 {
		plugin_task_start(editor, ui.owner, .Command, {ref = ui.change_ref, args = .Item, item_ref = ui.items_ref, item = item + 1})
	}
}

plugui_resolve :: proc(editor: ^Editor, ok: bool) {
	p := &editor.plugins
	ui := &p.ui
	if !ui.active {
		return
	}
	ui.active = false
	ui.done = true
	ui.ok = ok
	if ok {
		switch ui.kind {
		case .Pick:
			lo, hi := ui.selected, ui.selected
			if a, has := ui.anchor.?; has && ui.multi {
				lo, hi = min(a, ui.selected), max(a, ui.selected)
			}
			for pos in lo ..= hi {
				append(&ui.result, ui.matches[pos])
			}
		case .Prompt:
			ui.text = strings.clone(textfield_str(&ui.field))
		case .Confirm:
			append(&ui.result, ui.selected)
		}
	}
	fuzzy_end(&ui.fuzzy)
	preview_reset(&ui.preview)
	id := ui.id
	for w in plugin_waiters(p, .Ui, id) {
		plugin_task_resume(editor, w, 0)
	}
	if p.ui.id == id {
		plugui_clear(p)
	}
}

plugui_accept :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	if ui.kind == .Pick && len(ui.matches) == 0 {
		return
	}
	plugui_resolve(editor, true)
}

plugui_cancel :: proc(editor: ^Editor) {
	plugui_resolve(editor, false)
}

plugui_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	ui := &editor.plugins.ui
	switch ui.kind {
	case .Pick:
		if ui.multi && ev_shift(ev) && (ev.key == .Arrow_Up || ev.key == .Arrow_Down) {
			if ui.anchor == nil {
				ui.anchor = ui.selected
			}
			fuzzy_list_move(&ui.list, -1 if ev.key == .Arrow_Up else 1, plugui_rows(editor))
		} else {
			prev := ui.selected
			if fuzzy_list_key(editor, &ui.list, ev, plugui_accept, plugui_cancel, plugui_rows(editor)) || ui.selected != prev {
				ui.anchor = nil
			}
		}
		if ui.active {
			plugui_preview(editor)
			plugui_changed(editor)
		}
	case .Prompt:
		#partial switch ev.key {
		case .Esc:
			plugui_cancel(editor)
		case .Enter:
			plugui_accept(editor)
		case:
			textfield_key(&ui.field, ev)
		}
	case .Confirm:
		dialog_key(editor, ev, &ui.selected, len(ui.labels), plugui_accept, plugui_cancel)
	}
}

plugui_paste :: proc(editor: ^Editor, text: string) {
	ui := &editor.plugins.ui
	switch ui.kind {
	case .Pick:
		if textfield_insert_flat(&ui.field, text) {
			fuzzy_list_refilter(&ui.list)
			ui.anchor = nil
			plugui_preview(editor)
			plugui_changed(editor)
		}
	case .Prompt:
		textfield_insert_flat(&ui.field, text)
	case .Confirm:
	}
}

plugui_prompt_box :: proc(editor: ^Editor) -> (box: Rect, tx, tw: int) {
	ui := &editor.plugins.ui
	box = pane_center(editor, PALETTE_WIDTH, 1)
	tx = box.x + 2 + visual_width(transmute([]u8)plugui_prefix(ui))
	tw = box.x + box.w - 2 - tx
	return
}

plugui_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	ui := &editor.plugins.ui
	switch ui.kind {
	case .Pick:
		prev := ui.selected
		if ui.paths {
			lay := overlay_layout(editor, .Code)
			if lay.preview && preview_wheel(&ui.preview, ev, {lay.right_x, lay.body_top, lay.right_w, lay.body_h}, lay.body_h) {
				return
			}
			idx, activate := overlay_list_mouse(editor, ev, lay, len(ui.matches), &ui.scroll, &ui.field, plugui_cancel, plugui_prefix(ui))
			if idx < 0 {
				return
			}
			ui.selected = idx
			if activate {
				plugui_accept(editor)
			}
		} else {
			fuzzy_list_center_mouse(editor, &ui.list, ev, plugui_accept, plugui_cancel, plugui_prefix(ui))
		}
		if ui.active && ui.selected != prev {
			ui.anchor = nil
			plugui_preview(editor)
			plugui_changed(editor)
		}
	case .Prompt:
		if ev.key != .Mouse_Left {
			return
		}
		box, tx, tw := plugui_prompt_box(editor)
		if !mouse_in_rect(ev, box) {
			if !ev_motion(ev) {
				plugui_cancel(editor)
			}
			return
		}
		textfield_mouse(&ui.field, tx, box.y + 1, tw, ev)
	case .Confirm:
		dialog_mouse(editor, ev, ui.title, ui.labels[:], &ui.selected, plugui_accept, plugui_cancel)
	}
}

plugui_render :: proc(editor: ^Editor) {
	ui := &editor.plugins.ui
	switch ui.kind {
	case .Pick:
		if !ui.paths {
			fuzzy_list_center_render(editor, &ui.list, ui.labels[:], ui.details[:], plugui_prefix(ui), ui.anchor if ui.multi else nil)
			return
		}
		lay := overlay_layout(editor, .Code)
		inner := pane_draw_box(lay.box)
		overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &ui.field, plugui_prefix(ui))
		pane_hline(lay.box, lay.title_sep_y)
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
		}
		if lay.preview {
			preview_render(&ui.preview, lay.right_x + 1, lay.body_top, lay.right_w - 1, lay.body_h)
		}
		overlay_divider(lay, ui.scroll, len(ui.matches))
	case .Prompt:
		box, tx, tw := plugui_prompt_box(editor)
		inner := pane_draw_box(box)
		prefix := plugui_prefix(ui)
		pane_text(inner.x + 1, inner.y, tx - inner.x - 1, prefix, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
		textfield_render(tx, inner.y, tw, &ui.field)
	case .Confirm:
		dialog_render(editor, ui.title, ui.labels[:], ui.selected)
	}
}

plugpane_body_h :: proc(editor: ^Editor) -> int {
	lay := logview_layout(editor)
	return max(1, lay.footer_sep_y - lay.body_top)
}

plugpane_scroll :: proc(editor: ^Editor, delta: int) {
	pn := &editor.plugins.pane
	overlay_scroll_by(&pn.scroll, delta, len(pn.lines), plugpane_body_h(editor))
}

plugpane_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	#partial switch ev.key {
	case .Esc:
		plugpane_close(&editor.plugins)
	case .Arrow_Up:
		plugpane_scroll(editor, -1)
	case .Arrow_Down:
		plugpane_scroll(editor, 1)
	}
}

plugpane_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	#partial switch ev.key {
	case .Mouse_Wheel_Up:
		plugpane_scroll(editor, -WHEEL_SCROLL_LINES)
	case .Mouse_Wheel_Down:
		plugpane_scroll(editor, WHEEL_SCROLL_LINES)
	case .Mouse_Left:
		if !mouse_in_rect(ev, logview_layout(editor).box) && !ev_motion(ev) {
			plugpane_close(&editor.plugins)
		}
	}
}

plugpane_render :: proc(editor: ^Editor) {
	pn := &editor.plugins.pane
	lay := logview_layout(editor)
	inner := pane_draw_box(lay.box)
	pane_text(inner.x + 1, inner.y, inner.w - 2, pn.title, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_hline(lay.box, lay.title_sep_y)
	h := plugpane_body_h(editor)
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

api_ui_open :: proc(editor: ^Editor, kind: PluginUiKind, owner, title: string) -> ^PluginUi {
	p := &editor.plugins
	plugui_clear(p)
	ui := &p.ui
	ui.kind = kind
	ui.owner = owner
	ui.id = plugin_next_id(p)
	ui.title = strings.clone(title)
	fuzzy_list_reset(&ui.list)
	editor_clear_message(editor)
	return ui
}

api_ui_wait :: proc(L: ^lua.State, p: ^Plugins, task: u64) -> c.int {
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
	if ui.id != u64(ctx) || !ui.done || !ui.ok {
		lua.pushnil(L)
		return 1
	}
	lua.L_checkstack(L, 4, "ui result")
	switch ui.kind {
	case .Pick:
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
	case .Prompt:
		lua.pushodinstring(L, ui.text)
	case .Confirm:
		lua.pushinteger(L, lua.Integer(ui.result[0] + 1))
	}
	plugui_clear(p)
	return 1
}

qed_pick :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	p := &editor.plugins
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table {items, prompt?, initial?, on_change?, multi?} expected")
	}
	lua.settop(L, 1)
	lua.L_checkstack(L, 6, "pick options")
	if lua.getfield(L, 1, "items") != .TABLE {
		plugin_raise(L, "items must be a table")
	}
	n := int(lua.rawlen(L, 2))
	parsed := make([]PluginPickItem, n, context.temp_allocator)
	for i in 1 ..= n {
		#partial switch lua.rawgeti(L, 2, lua.Integer(i)) {
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
	task := api_await(L, p, "qed.pick").id
	if plugin_overlay_open(editor) {
		return api_busy(L)
	}

	ui := api_ui_open(editor, .Pick, pl.name, prompt)
	for it in parsed {
		append(&ui.items, PluginPickItem{strings.clone(it.label), strings.clone(it.detail), strings.clone(it.path), it.row})
		ui.paths ||= it.path != ""
	}
	for it in ui.items {
		append(&ui.labels, it.label)
		append(&ui.details, it.detail)
	}
	ui.multi = multi
	ui.items_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	if change_t == .FUNCTION {
		lua.getfield(L, 1, "on_change")
		ui.change_ref = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	}
	ui.fuzzy = fuzzy_begin(ui.labels[:])
	fuzzy_list_refilter(&ui.list)
	for m, i in ui.matches {
		if m == initial {
			ui.selected = i
			break
		}
	}
	fuzzy_list_scroll(&ui.list, plugui_rows(editor))
	ui.notified = ui.matches[ui.selected] if len(ui.matches) > 0 else -1
	plugui_preview(editor)
	return api_ui_wait(L, p, task)
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
	if plugin_overlay_open(editor) {
		return api_busy(L)
	}
	ui := api_ui_open(editor, .Prompt, pl.name, prompt)
	textfield_set(&ui.field, text)
	return api_ui_wait(L, p, task)
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
	if plugin_overlay_open(editor) {
		return api_busy(L)
	}
	ui := api_ui_open(editor, .Confirm, pl.name, question)
	for ch in choices {
		append(&ui.items, PluginPickItem{label = strings.clone(ch)})
	}
	for it in ui.items {
		append(&ui.labels, it.label)
	}
	return api_ui_wait(L, p, task)
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

plugpane_set :: proc(pn: ^PluginPane, lines: []PluginPaneLine) {
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
	plugpane_close(p)
	pn := &p.pane
	pn.id = plugin_next_id(p)
	pn.owner = pl.name
	pn.title = strings.clone(title)
	pn.footer = strings.clone(footer)
	plugpane_set(pn, lines)
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
		plugpane_set(pn, lines)
	}
	lua.pushboolean(L, b32(live))
	return 1
}

qed_pane_close :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	p := &entry.editor.plugins
	if p.pane.active && p.pane.id == api_handle_id(L) {
		plugpane_close(p)
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
	if !editor_theme_set(entry.editor, name, persist) {
		return api_fail(L, fmt.tprintf("unknown theme '%s'", name))
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
