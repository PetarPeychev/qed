package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import lua "lib:lua"
import "lib:tb2"

@(private = "file")
g_pt: ^E2E
@(private = "file")
g_pt_target: string

@(private = "file")
PtCase :: struct {
	tests: c.int,
	name:  string,
}



@(private = "file")
pt_api := [?]lua.L_Reg {
	{"key", pt_key},
	{"type", pt_type},
	{"step", pt_step},
	{"wait", pt_wait},
	{"expect_line", pt_expect_line},
	{"expect_cell", pt_expect_cell},
	{"eq", pt_eq},
	{"ok", pt_ok},
	{"fake_spawn", pt_fake_spawn},
	{"config", pt_config},
	{"open", pt_open},
	{"stub", pt_stub},
	{"message", pt_message},
	{"log_has", pt_log_has},
	{"editor", pt_editor},
	{"poll_disk", pt_poll_disk},
	{"pump", pt_pump},
	{"hook_timeout", pt_hook_timeout},
	{"lsp", pt_lsp},
	{"ui", pt_ui},
	{"config_path", pt_config_path},
	{"screen", pt_screen},
	{"click", pt_click},
	{"sh", pt_sh},
	{"marks", pt_marks},
	{"deco", pt_deco},
	{"settle", pt_settle},
	{"tick", pt_tick},
	{"procs", pt_procs},
	{"bg", pt_bg},
	{nil, nil},
}

@(private = "file")
pt_key :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	s := api_string(L, 1)
	ev := tb2.Event{type = .Key}
	switch s {
	case "Enter":
		ev.key = .Enter
	case "Esc":
		ev.key = .Esc
	case "Tab":
		ev.key = .Tab
	case "Backspace":
		ev.key = .Backspace2
	case "Up":
		ev.key = .Arrow_Up
	case "Down":
		ev.key = .Arrow_Down
	case "Shift+Up":
		ev.key = .Arrow_Up
		ev.mod = .Shift
	case "Shift+Down":
		ev.key = .Arrow_Down
		ev.mod = .Shift
	case "Left":
		ev.key = .Arrow_Left
	case "Right":
		ev.key = .Arrow_Right
	case "Ctrl+Right":
		ev.key = .Arrow_Right
		ev.mod = .Ctrl
	case "PgUp":
		ev.key = .Pgup
	case "PgDn":
		ev.key = .Pgdn
	case "Home":
		ev.key = .Home
	case "End":
		ev.key = .End
	case:
		key, alt, ok := parse_keybind(s)
		if !ok {
			return plugin_raise(L, fmt.tprintf("t.key: unknown key '%s'", s))
		}
		if alt != 0 {
			ev.mod = .Alt
			ev.ch = alt
		} else {
			ev.key = key
		}
	}
	e2e_step(g_pt, ev)
	return 0
}

@(private = "file")
pt_type :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	e2e_type(g_pt, api_string(L, 1))
	pane_stack_sync(&g_pt.ed)
	plugin_flush(&g_pt.ed)
	return 0
}

@(private = "file")
pt_step :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	term_pump(&g_pt.ed)
	plugin_pump(&g_pt.ed)
	return 0
}

@(private = "file")
pt_wait :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	if lua.type(L, 1) != .FUNCTION {
		lua.L_argerror(L, 1, "condition function expected")
	}
	max_ms := api_int(L, 2, "milliseconds expected") if lua.type(L, 2) > .NIL else 5000
	start := time.tick_now()
	for {
		lua.pushvalue(L, 1)
		lua.call(L, 0, 1)
		done := lua.toboolean(L, -1)
		lua.pop(L, 1)
		if done {
			return 0
		}
		if ms_since(start) > f64(max_ms) {
			return plugin_raise(L, fmt.tprintf("t.wait timed out after %d ms", max_ms))
		}
		term_pump(&g_pt.ed)
		plugin_pump(&g_pt.ed)
		// as the main loop: every pass draws a frame
		e2e_render(g_pt)
		time.sleep(time.Millisecond)
	}
}

@(private = "file")
pt_expect_line :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	row := api_int(L, 1, "row expected")
	want := api_string(L, 2)
	b := pt_buffer(L, entry.editor, 3)
	if row < 1 || row > len(b.lines) {
		return plugin_raise(L, fmt.tprintf("line %d: out of range 1..%d", row, len(b.lines)))
	}
	got := string(b.lines[row - 1].text[:])
	if got != want {
		return plugin_raise(L, fmt.tprintf("line %d: got %q, want %q", row, got, want))
	}
	return 0
}

@(private = "file")
pt_expect_cell :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	x := api_int(L, 1, "x expected")
	y := api_int(L, 2, "y expected")
	want, _ := utf8.decode_rune_in_string(api_string(L, 3))
	e2e_render(g_pt)
	if got := e2e_cell(g_pt, x, y); got != want {
		return plugin_raise(L, fmt.tprintf("cell (%d,%d): got %q, want %q", x, y, got, want))
	}
	return 0
}

@(private = "file")
pt_show :: proc(L: ^lua.State, idx: c.int) -> string {
	s, _ := lua.toodinstring_any(L, idx)
	s = strings.clone(s, context.temp_allocator)
	lua.pop(L, 1)
	if lua.type(L, idx) == .STRING {
		return fmt.tprintf("%q", s)
	}
	return s
}

@(private = "file")
pt_eq :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	lua.settop(L, 3)
	got, want := pt_show(L, 1), pt_show(L, 2)
	if lua.type(L, 1) != lua.type(L, 2) || got != want {
		what, _ := lua.toodinstring(L, 3)
		return plugin_raise(L, fmt.tprintf("%s: got %s, want %s", what if what != "" else "t.eq", got, want))
	}
	return 0
}

@(private = "file")
pt_ok :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	if !lua.toboolean(L, 1) {
		what, _ := lua.toodinstring(L, 2)
		return plugin_raise(L, what if what != "" else "t.ok failed")
	}
	return 0
}

@(private = "file")
pt_fake_spawn :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	pattern := strings.clone(api_string(L, 1), context.temp_allocator)
	f := PluginFake {
		pattern = pattern,
	}
	if lua.type(L, 2) == .TABLE {
		f.stdout, _ = api_field_string(L, 2, "stdout")
		f.stderr, _ = api_field_string(L, 2, "stderr")
		f.code, _ = api_field_int(L, 2, "code")
		f.delay_ms, _ = api_field_int(L, 2, "delay_ms")
	}
	e2e_spawn_fake(g_pt, f.pattern, f.stdout, f.code, f.delay_ms, f.stderr)
	return 0
}

@(private = "file")
pt_config :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "config table expected")
	}
	sb := strings.builder_make(context.temp_allocator)
	if err := api_json_write(L, 1, &sb, 0); err != "" {
		return plugin_raise(L, err)
	}
	hot := false
	if lua.type(L, 2) == .TABLE {
		lua.getfield(L, 2, "hot")
		hot = bool(lua.toboolean(L, -1))
	}
	e2e_plugin_config(g_pt, g_pt_target, strings.to_string(sb), hot)
	return 0
}

@(private = "file")
pt_pump :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	ms := api_int(L, 1, "milliseconds expected")
	start := time.tick_now()
	for ms_since(start) < f64(ms) {
		term_pump(&g_pt.ed)
		plugin_pump(&g_pt.ed)
		time.sleep(time.Millisecond)
	}
	return 0
}

@(private = "file")
pt_hook_timeout :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	PLUGIN_HOOK_TIMEOUT_MS = api_int(L, 1, "milliseconds expected")
	return 0
}

@(private = "file")
pt_lsp :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	LSP_ENABLED = bool(lua.toboolean(L, 1))
	return 0
}

@(private = "file")
pt_open :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	path, _ := filepath.join({g_pt.dir, api_string(L, 1)}, context.temp_allocator)
	content := api_string(L, 2) if lua.type(L, 2) > .NIL else ""
	path_ensure_parent_dir(path)
	_ = os.write_entire_file(path, transmute([]u8)content)
	if !editor_open_path(entry.editor, path) {
		return plugin_raise(L, fmt.tprintf("t.open: cannot open %s", path))
	}
	api_buffer_object_push(L, editor_buffer(entry.editor).id)
	return 1
}

@(private = "file")
pt_stub :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	e2e_seq += 1
	path := fmt.tprintf("%s/stub_%d.sh", g_pt.dir, e2e_seq)
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("#!/bin/sh\n%s\n", api_string(L, 1)))
	e2e_run(fmt.tprintf("chmod +x %s", shell_quote(path)))
	lua.pushodinstring(L, shell_quote(path))
	return 1
}

@(private = "file")
pt_level_name := [LogLevel]string {
	.Debug = "debug",
	.Info  = "info",
	.Warn  = "warn",
	.Error = "error",
}

@(private = "file")
pt_message :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, entry.editor.message)
	lua.pushodinstring(L, pt_level_name[entry.editor.message_level])
	lua.pushodinstring(L, entry.editor.message_source)
	return 3
}

@(private = "file")
pt_log_has :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	level := api_string(L, 1)
	source := api_string(L, 2)
	needle := api_string(L, 3)
	found := false
	for e in entry.editor.log {
		found ||= pt_level_name[e.level] == level && e.source == source && strings.contains(e.text, needle)
	}
	lua.pushboolean(L, b32(found))
	return 1
}

@(private = "file")
pt_editor :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	ed := entry.editor
	e2e_render(g_pt)
	lua.createtable(L, 0, 9)
	lua.pushboolean(L, b32(ed.quit))
	lua.setfield(L, -2, "quit")
	lua.pushboolean(L, b32(ed.welcome))
	lua.setfield(L, -2, "welcome")
	if name := safety_dialog(ed); name != "" {
		lua.pushodinstring(L, name)
	} else {
		lua.pushnil(L)
	}
	lua.setfield(L, -2, "dialog")
	lua.pushboolean(L, b32(!ed.welcome && editor_buffer(ed).disk_conflict))
	lua.setfield(L, -2, "disk_conflict")
	lua.pushboolean(L, b32(ed.terminal.active))
	lua.setfield(L, -2, "terminal")
	if ed.terminal.active && ed.terminal.shown != nil {
		lua.pushodinstring(L, ed.terminal.shown.name)
		lua.setfield(L, -2, "session")
	}
	lua.pushboolean(L, b32(filetree_active(ed)))
	lua.setfield(L, -2, "tree")
	ui_resolve(ed)
	lua.pushboolean(L, b32(pane_find(ed, "palette") != nil || ui_find(&ed.ui, "#palette/palette") != nil))
	lua.setfield(L, -2, "palette")
	lua.createtable(L, c.int(len(ed.plugins.status)), 0)
	for s, i in ed.plugins.status {
		lua.createtable(L, 0, 5)
		lua.pushodinstring(L, s.id)
		lua.setfield(L, -2, "id")
		lua.pushodinstring(L, s.text)
		lua.setfield(L, -2, "text")
		lua.pushodinstring(L, s.color)
		lua.setfield(L, -2, "color")
		lua.pushodinstring(L, "right" if s.right else "left")
		lua.setfield(L, -2, "side")
		lua.pushodinstring(L, s.owner)
		lua.setfield(L, -2, "owner")
		lua.pushodinstring(L, s.sep)
		lua.setfield(L, -2, "sep")
		lua.createtable(L, c.int(len(s.chunks)), 0)
		for ch, j in s.chunks {
			lua.createtable(L, 0, 2)
			lua.pushodinstring(L, ch.text)
			lua.setfield(L, -2, "text")
			lua.pushodinstring(L, ch.color)
			lua.setfield(L, -2, "color")
			lua.rawseti(L, -2, lua.Integer(j + 1))
		}
		lua.setfield(L, -2, "chunks")
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "status")
	return 1
}

@(private = "file")
pt_click :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	needle := utf8.string_to_runes(api_string(L, 1), context.temp_allocator)
	e2e_render(g_pt)
	for y in 0 ..< int(tb2.height()) {
		row := make([]rune, int(tb2.width()), context.temp_allocator)
		for x in 0 ..< len(row) {
			row[x] = e2e_cell(g_pt, x, y)
		}
		for x in 0 ..= len(row) - len(needle) {
			if slice.equal(row[x:x + len(needle)], needle) {
				e2e_mouse(g_pt, x, y)
				pane_stack_sync(&g_pt.ed)
				plugin_flush(&g_pt.ed)
				return 0
			}
		}
	}
	return plugin_raise(L, "t.click: text not on screen")
}

@(private = "file")
pt_screen :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	y := api_int(L, 1, "row expected")
	e2e_render(g_pt)
	lua.pushodinstring(L, e2e_row_text(g_pt, y))
	return 1
}

@(private = "file")
pt_sh :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	lua.pushboolean(L, b32(e2e_run(fmt.tprintf("cd %s && {{ %s; }} >/dev/null 2>&1", shell_quote(g_pt.dir), api_string(L, 1)))))
	return 1
}

@(private = "file")
pt_buffer :: proc(L: ^lua.State, editor: ^Editor, idx: c.int) -> ^Buffer {
	if lua.type(L, idx) <= .NIL {
		return editor_buffer(editor)
	}
	b, _ := api_buf(L, editor, idx)
	return b
}

@(private = "file")
pt_marks :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b := pt_buffer(L, entry.editor, 1)
	diffbase_update(b)
	names := [DiffMark]string{.None = "", .Added = "added", .Modified = "modified", .Deleted = "deleted"}
	lua.createtable(L, c.int(len(b.lines)), 0)
	for r in 0 ..< len(b.lines) {
		lua.pushodinstring(L, names[diff_mark_at(b, r)])
		lua.rawseti(L, -2, lua.Integer(r + 1))
	}
	return 1
}

@(private = "file")
pt_deco :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	b := pt_buffer(L, entry.editor, 1)
	colors := entry.editor.plugins.colors[:]
	key :: proc(colors: []string, id: u16) -> string {
		return colors[id - 1] if id > 0 else "-"
	}
	lua.createtable(L, c.int(len(b.deco.items)), 0)
	for d, i in b.deco.items {
		alpha := config_tints[d.tint - 1].key if d.tint > 0 else fmt.tprintf("%.2f", d.alpha)
		line: string
		#partial switch d.kind {
		case .Tint:
			line = fmt.tprintf("tint %d-%d %s %s", d.from.row + 1, d.to.row + 1, key(colors, d.color), alpha)
		case .Span:
			line = fmt.tprintf("span %d:%d-%d:%d fg=%s bg=%s", d.from.row + 1, d.from.col + 1, d.to.row + 1, d.to.col + 1, key(colors, d.color), key(colors, d.bg))
			if d.blend {
				line = fmt.tprintf("%s %s", line, alpha)
			}
		case:
			line = fmt.tprintf("%v %d", d.kind, d.from.row + 1)
		}
		lua.pushodinstring(L, line)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

@(private = "file")
pt_bg :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	e2e_render(g_pt)
	lua.pushinteger(L, lua.Integer(e2e_rgb(e2e_cell_bg(g_pt, api_int(L, 1, "x expected"), api_int(L, 2, "y expected")))))
	return 1
}

@(private = "file")
pt_procs :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	n := 0
	for pr in entry.editor.plugins.procs {
		n += int(pr.owner == g_pt_target && !pr.done)
	}
	lua.pushinteger(L, lua.Integer(n))
	return 1
}

@(private = "file")
pt_tick :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	now := time.tick_now()
	for &tm in g_pt.ed.plugins.timers {
		if tm.every_ms > 0 && tm.owner == g_pt_target {
			tm.due = now
		}
	}
	plugin_pump(&g_pt.ed)
	return 0
}

@(private = "file")
pt_settle :: proc "c" (L: ^lua.State) -> c.int {
	context = api_enter(L).ctx
	e2e_git_settle(g_pt)
	e2e_pump_while(g_pt, proc(e: ^E2E) -> bool {
		if pane_stack_pending(&e.ed) {
			pane_stack_pump(&e.ed, true)
		}
		return plugin_busy(&e.ed) || e2e_plugin_yielding(e)
	})
	return 0
}

@(private = "file")
pt_poll_disk :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor_poll_disk(entry.editor)
	return 0
}

@(private = "file")
pt_ui :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	if _, ok := test_dialog(entry.editor); ok {
		return pt_ui_dialog(L, entry.editor)
	}
	pn := test_view(entry.editor)
	if pn == nil {
		if filetree_active(entry.editor) {
			return pt_ui_tree(L, entry.editor)
		}
		lua.pushnil(L)
		return 1
	}
	kind := "pane"
	switch {
	case pn.has_list && len(pn.fields) > 0:
		kind = "pick"
	case len(pn.fields) > 0:
		kind = "prompt"
	case pn.has_list:
		kind = "confirm"
	}
	n := pane_count(entry.editor, pn)
	lua.createtable(L, 0, 6)
	lua.pushodinstring(L, kind)
	lua.setfield(L, -2, "kind")
	lua.pushodinstring(L, pn.id)
	lua.setfield(L, -2, "id")
	lua.pushodinstring(L, textfield_str(&pn.fields[0].field) if len(pn.fields) > 0 else "")
	lua.setfield(L, -2, "query")
	lua.pushinteger(L, lua.Integer(n))
	lua.setfield(L, -2, "matches")
	lua.createtable(L, c.int(n), 0)
	for i in 0 ..< n {
		lua.pushodinstring(L, test_pane_label(entry.editor, pn, i))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "labels")
	lua.pushodinstring(L, pane_hint(pn) if n == 0 else "")
	lua.setfield(L, -2, "hint")
	g := pane_geom(entry.editor, pn)
	lua.pushinteger(L, lua.Integer(g.box.w))
	lua.setfield(L, -2, "width")
	lua.pushinteger(L, lua.Integer(pane_body_rows(pn, g)))
	lua.setfield(L, -2, "rows")
	lua.pushinteger(L, lua.Integer(pn.scroll))
	lua.setfield(L, -2, "scroll")
	lua.pushinteger(L, lua.Integer(g.text.y))
	lua.setfield(L, -2, "body_y")
	lua.pushinteger(L, lua.Integer(g.text.h))
	lua.setfield(L, -2, "body_h")
	if n > 0 {
		lua.pushodinstring(L, test_view_selected(entry.editor))
		lua.setfield(L, -2, "selected")
		it := list_item(entry.editor, pn, pane_item_index(pn, pn.list.sel))
		lua.createtable(L, c.int(len(it.cells)), 0)
		for cell, i in it.cells {
			lua.pushodinstring(L, cell)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		lua.setfield(L, -2, "cells")
		if m, ok := pn.marks[pane_item_key(it)]; ok {
			lua.pushodinstring(L, m.bar)
			lua.setfield(L, -2, "mark")
		}
	}
	if pn.footer_input {
		lua.pushodinstring(L, pn.footer_field.prompt)
		lua.setfield(L, -2, "input")
		lua.pushodinstring(L, textfield_str(&pn.footer_field.field))
		lua.setfield(L, -2, "input_text")
	}
	lua.pushinteger(L, lua.Integer(pn.tab + 1))
	lua.setfield(L, -2, "tab")
	lua.pushodinstring(L, pn.info)
	lua.setfield(L, -2, "info")
	return 1
}

pt_ui_tree :: proc(L: ^lua.State, editor: ^Editor) -> c.int {
	entries := ft_entries(editor)
	selected, has := ft_selected(editor)
	lua.createtable(L, 0, 6)
	lua.pushodinstring(L, "tree")
	lua.setfield(L, -2, "kind")
	lua.pushodinstring(L, "filetree")
	lua.setfield(L, -2, "id")
	lua.pushodinstring(L, ft_query(editor))
	lua.setfield(L, -2, "query")
	lua.pushinteger(L, lua.Integer(len(entries)))
	lua.setfield(L, -2, "matches")
	lua.createtable(L, c.int(len(entries)), 0)
	for entry, i in entries {
		lua.pushodinstring(L, entry.name)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "labels")
	if has {
		lua.pushodinstring(L, selected.name)
		lua.setfield(L, -2, "selected")
	}
	hint := ""
	editor_render(editor)
	if node := ui_find(&editor.ui, "#filetree/filetree_hint"); node != nil {
		sb := strings.builder_make(context.temp_allocator)
		for span in node.spans {
			strings.write_string(&sb, span.text)
		}
		hint = strings.trim_space(strings.to_string(sb))
	}
	lua.pushodinstring(L, hint)
	lua.setfield(L, -2, "hint")
	return 1
}

pt_ui_dialog :: proc(L: ^lua.State, editor: ^Editor) -> c.int {
	dialog, ok := test_dialog(editor)
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua.createtable(L, 0, 6)
	lua.pushodinstring(L, dialog.kind)
	lua.setfield(L, -2, "kind")
	lua.pushodinstring(L, "dialog")
	lua.setfield(L, -2, "id")
	lua.pushodinstring(L, dialog.query)
	lua.setfield(L, -2, "query")
	lua.pushodinstring(L, dialog.question)
	lua.setfield(L, -2, "question")
	lua.pushinteger(L, lua.Integer(len(dialog.labels)))
	lua.setfield(L, -2, "matches")
	lua.createtable(L, c.int(len(dialog.labels)), 0)
	for label, i in dialog.labels {
		lua.pushodinstring(L, label)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "labels")
	if dialog.selected != "" {
		lua.pushodinstring(L, dialog.selected)
		lua.setfield(L, -2, "selected")
	}
	return 1
}

@(private = "file")
pt_config_path :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	lua.pushodinstring(L, entry.editor.plugins.persist_path)
	return 1
}

@(private = "file")
pt_load_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	args := (^PluginLoad)(lua.touserdata(L, 1))
	plugin_env_create(L, args.pl)
	if lua.L_loadbuffer(L, raw_data(args.src), c.size_t(len(args.src)), plugin_chunkname(args.pl, args.pl.main), "t") != .OK {
		return lua.error(L)
	}
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(args.pl.env))
	lua.setupvalue(L, -2, 1)
	lua.call(L, 0, 1)
	if lua.type(L, -1) != .TABLE {
		return plugin_raise(L, fmt.tprintf("%s must return a table of test functions", args.pl.main))
	}
	return 1
}

@(private = "file")
pt_case_c :: proc "c" (L: ^lua.State) -> c.int {
	context = plugin_entry(L).ctx
	tc := (^PtCase)(lua.touserdata(L, 1))
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(tc.tests))
	lua.pushodinstring(L, tc.name)
	lua.rawget(L, -2)
	lua.newtable(L)
	lua.L_setfuncs(L, raw_data(pt_api[:]), 0)
	lua.call(L, 1, 0)
	return 0
}

@(private = "file")
pt_session :: proc(e: ^E2E, name: string, test: PluginFile) -> (tests: c.int, names: []string, err: string) {
	e2e_enter()
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.aprintf("%s/qed_e2e_plug %d_%d", tmp, posix.getpid(), e2e_seq)
	os.make_directory(dir)
	file := fmt.aprintf("%s/start.txt", dir)
	_ = os.write_entire_file(file, nil)
	e^ = E2E{ed = editor_init(file, headless = true), path = file, dir = dir}
	e2e_old_ui(&e.ed)
	e.ed.plugins.persist_path = fmt.aprintf("%s/config.json", dir)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(dir)
	g_pt = e
	g_pt_target = name
	p := &e.ed.plugins
	pl := plugins_add(p, Plugin{name = fmt.tprintf("%s_test", name), dir = name, main = test.path}, true)
	args := PluginLoad{pl, test.data}
	lua.pushcfunction(p.L, pt_load_c)
	lua.pushlightuserdata(p.L, &args)
	ok, msg, tb := plugin_call(&e.ed, 1, 1)
	if !ok {
		return 0, nil, fmt.tprintf("%s\n%s", msg, tb)
	}
	list := make([dynamic]string, context.temp_allocator)
	lua.pushnil(p.L)
	for lua.next(p.L, -2) != 0 {
		if lua.type(p.L, -2) == .STRING && lua.type(p.L, -1) == .FUNCTION {
			k, _ := lua.toodinstring(p.L, -2)
			append(&list, strings.clone(k, context.temp_allocator))
		}
		lua.pop(p.L, 1)
	}
	slice.sort(list[:])
	return lua.L_ref(p.L, lua.REGISTRYINDEX), list[:], ""
}

PT_PLUGINS :: #directory + "/../plugins"

@(private = "file")
pt_plugin_dirs :: proc() -> []string {
	infos, _ := os.read_directory_by_path(PT_PLUGINS, -1, context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if info.type == .Directory && os.exists(fmt.tprintf("%s/%s/init.lua", PT_PLUGINS, info.name)) {
			append(&dirs, strings.clone(info.name, context.temp_allocator))
		}
	}
	slice.sort(dirs[:])
	return dirs[:]
}

@(test)
plugins_test_lua_runners :: proc(t: ^testing.T) {
	src := #load("e2e_plugins_test.odin", string)
	for name in pt_plugin_dirs() {
		if os.exists(fmt.tprintf("%s/%s/test.lua", PT_PLUGINS, name)) {
			testing.expectf(t, strings.contains(src, fmt.tprintf("pt_run_dir(t, %q)", name)), "plugins/%s/test.lua: add an e2e_plugin_%s_lua test", name, name)
		}
	}
}

@(private = "file")
pt_run_dir :: proc(t: ^testing.T, name: string) {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s/test.lua", PT_PLUGINS, name), context.temp_allocator)
	if !testing.expectf(t, err == nil, "plugins/%s/test.lua: %v", name, err) {
		return
	}
	pt_run(t, name, PluginFile{fmt.tprintf("%s/test.lua", name), string(data)})
}

@(test)
e2e_plugin_ai_lua :: proc(t: ^testing.T) {pt_run_dir(t, "ai")}
@(test)
e2e_plugin_conflict_lua :: proc(t: ^testing.T) {pt_run_dir(t, "conflict")}
@(test)
e2e_plugin_filetree_lua :: proc(t: ^testing.T) {pt_run_dir(t, "filetree")}
@(test)
e2e_plugin_format_lua :: proc(t: ^testing.T) {pt_run_dir(t, "format")}
@(test)
e2e_plugin_git_lua :: proc(t: ^testing.T) {pt_run_dir(t, "git")}
@(test)
e2e_plugin_goto_lua :: proc(t: ^testing.T) {pt_run_dir(t, "goto")}
@(test)
e2e_plugin_markdown_lua :: proc(t: ^testing.T) {pt_run_dir(t, "markdown")}
@(test)
e2e_plugin_search_lua :: proc(t: ^testing.T) {pt_run_dir(t, "search")}
@(test)
e2e_plugin_settings_lua :: proc(t: ^testing.T) {pt_run_dir(t, "settings")}
@(test)
e2e_plugin_workspace_lua :: proc(t: ^testing.T) {pt_run_dir(t, "workspace")}

@(test)
e2e_term_api_lua :: proc(t: ^testing.T) {
	pt_run(t, "term", PluginFile{"term_test.lua", #load("term_test.lua", string)})
}

@(private = "file")
pt_run :: proc(t: ^testing.T, name: string, f: PluginFile) {
	count := 1
	for i := 0; i < count; i += 1 {
		e: E2E
		tests, names, serr := pt_session(&e, name, f)
		if serr != "" {
			testing.expectf(t, false, "plugins/%s: %s", f.path, serr)
			e2e_stop(&e)
			break
		}
		count = len(names)
		if count == 0 {
			testing.expectf(t, false, "plugins/%s defines no tests", f.path)
			e2e_stop(&e)
			break
		}
		saved_timeout, saved_lsp := PLUGIN_HOOK_TIMEOUT_MS, LSP_ENABLED
		saved_theme := strings.clone(THEME, context.temp_allocator)
		saved_reg := clipboard_register
		clipboard_register = ""
		tc := PtCase{tests, names[i]}
		lua.pushcfunction(e.ed.plugins.L, pt_case_c)
		lua.pushlightuserdata(e.ed.plugins.L, &tc)
		e.ed.plugins.entry_owner = plugin_find(&e.ed.plugins, fmt.tprintf("%s_test", name)).name
		ok, msg, tb := plugin_call(&e.ed, 1, 0)
		e.ed.plugins.entry_owner = ""
		if !ok {
			testing.expectf(t, false, "plugins/%s %s: %s\n%s", f.path, names[i], msg, tb)
		} else if pl := plugin_find(&e.ed.plugins, name); pl != nil && pl.last_error != "" {
			testing.expectf(t, false, "plugins/%s %s: plugin error: %s", f.path, names[i], pl.last_error)
		}
		PLUGIN_HOOK_TIMEOUT_MS, LSP_ENABLED = saved_timeout, saved_lsp
		delete(clipboard_register)
		clipboard_register = saved_reg
		if THEME != saved_theme || e.ed.theme_shown != "" {
			delete(THEME, os.heap_allocator())
			THEME = strings.clone(saved_theme, os.heap_allocator())
			editor_theme_set(&e.ed, saved_theme, false)
		}
		e2e_stop(&e)
	}
}

@(test)
plugins_bundled_dirs_complete :: proc(t: ^testing.T) {
	for dir in pt_plugin_dirs() {
		files, _ := os.read_directory_by_path(fmt.tprintf("%s/%s", PT_PLUGINS, dir), -1, context.temp_allocator)
		for f in files {
			if !strings.has_suffix(f.name, ".lua") || f.name == "test.lua" {
				continue
			}
			path := fmt.tprintf("%s/%s", dir, f.name)
			listed := false
			for b in bundled_plugin_dir_files {
				listed ||= b.path == path
			}
			testing.expectf(t, listed, "plugins/%s is not embedded: add it to bundled_plugin_dir_files in plugin.odin", path)
		}
	}
	for b in g_bundled_plugins {
		testing.expectf(t, !strings.has_suffix(b.path, "/test.lua"), "%s must not be embedded", b.path)
	}
}

@(test)
e2e_plugin_stub_methods :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_spawn_fake(&e, "stub-probe", "")
	e2e_plugin(&e, "probe", `local handle
return {setup = function()
	handle = qed.command{name = "Probe", run = function()
		local out = {}
		local function add(cls, obj)
			for k, v in pairs(obj) do
				if type(v) == "function" then out[#out + 1] = cls .. ":" .. k end
			end
		end
		add("CommandHandle", handle)
		local h = qed:on("startup", function() end)
		add("Handle", h)
		h:off()
		local tm = qed.defer(100000, function() end)
		add("Timer", tm)
		tm:stop()
		local pr = qed.spawn_bg{cmd = "stub-probe"}
		add("Proc", pr)
		pr:kill()
		local l = qed.fs.walk{}
		add("PaneSource", l)
		local tree = l:tree()
		for _, name in ipairs{"get", "at", "index_of", "count", "set_query", "expand", "toggle", "expanded", "reveal", "expand_all", "loading", "more", "release", "expanding", "stop"} do
			if type(tree[name]) == "function" then out[#out + 1] = "TreeList:" .. name end
		end
		l:release()
		local lines = qed.buf.current():line_list()
		for _, name in ipairs{"get", "at", "index_of", "count", "set_query"} do
			if type(lines[name]) == "function" then out[#out + 1] = "LinesList:" .. name end
		end
		local v = qed.ui.open{list = {items = {"a"}}}
		add("View", v)
		v:close()
		local mounted = qed.ui.mount("notification", qed.ui.text{id = "probe_text", "probe"})
		add("MountHandle", mounted)
		add("NodeRef", qed.ui.node("probe_text"))
		mounted:unmount()
		local records = qed.list.new{key = "name"}
		for _, name in ipairs{"append", "insert", "set", "remove", "clear", "get", "at", "index_of", "count", "sort", "set_query", "positions"} do
			if type(records[name]) == "function" then out[#out + 1] = "List:" .. name end
		end
		local buffer = qed.buf.create{internal = true}
		for _, name in ipairs{"valid", "path", "language", "modified", "big", "rev", "line_count", "lines", "line", "find_lines", "find_trailing", "text", "insert", "delete", "replace", "set_text", "cursor", "set_cursor", "screen_row", "set_screen_row", "selection", "set_selection", "set_language", "set_indent", "indent", "set_base", "base", "line_list", "on", "close", "find"} do
			if type(buffer[name]) == "function" then out[#out + 1] = "BufferObject:" .. name end
		end
		local search = qed.buf.current():find("x")
		add("Search", search)
		search:close()
		buffer:close()
		local matches = qed.fuzzy.list(records, {field = "name"})
		for _, name in ipairs{"append", "insert", "set", "remove", "clear", "get", "at", "index_of", "count", "sort", "set_query", "positions"} do
			if type(matches[name]) == "function" then out[#out + 1] = "FuzzyList:" .. name end
		end
		table.sort(out)
		qed.message(table.concat(out, " "))
	end}
end}`)
	run_ok := false
	for cmd in e.ed.plugins.commands {
		if cmd.name == "Probe: Probe" {
			plugin_command_run(&e.ed, cmd)
			run_ok = true
		}
	}
	testing.expect(t, run_ok, "the probe command registered")
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return plugin_busy(&e.ed) || plugin_views_due(&e.ed)}, 500)
	plugin_flush(&e.ed)
	e2e_pump_while(&e, proc(e: ^E2E) -> bool {return len(e.ed.plugins.tasks) > 0})
	methods := strings.split(e.ed.message, " ", context.temp_allocator)
	testing.expect(t, len(methods) > 30, "probed the method tables")
	for m in methods {
		testing.expectf(t, strings.contains(QED_STUB, fmt.tprintf("\nfunction %s(", m)), "plugins/meta/qed.lua is missing method `%s`", m)
	}
	for line in strings.split_lines(QED_STUB, context.temp_allocator) {
		if !strings.has_prefix(line, "function ") || !strings.contains(line, ":") || strings.has_prefix(line, "function qed:") {
			continue
		}
		decl := line[len("function "):strings.index_byte(line, '(')]
		testing.expectf(t, slice.contains(methods, decl), "the stub declares method `%s` but no qed object has it", decl)
	}
}

@(private = "file")
mk_core_bind :: proc(name: string) -> bool {
	for cmd in commands {
		if command_config_name(cmd) == name {
			return true
		}
	}
	for cmd in pane_commands {
		if cmd.bind_from == "" && command_config_name(cmd) == name {
			return true
		}
	}
	return false
}

@(private = "file")
mk_default :: proc(root: json.Object, path: string) -> bool {
	v: json.Value = root
	for seg in strings.split(path, "/", context.temp_allocator) {
		obj, ok := v.(json.Object)
		if !ok {
			return false
		}
		v, ok = obj[seg]
		if !ok {
			return false
		}
	}
	return true
}

@(private = "file")
mk_exists :: proc(e: ^E2E, root: json.Object, path: string) -> bool {
	segs := strings.split(path, "/", context.temp_allocator)
	if segs[0] == "keybinds" && len(segs) >= 2 {
		return mk_core_bind(strings.join(segs[1:], "/", context.temp_allocator))
	}
	if segs[0] != "plugins" || len(segs) < 2 {
		return mk_default(root, path)
	}
	pl := plugin_find(&e.ed.plugins, segs[1])
	if pl == nil || len(segs) == 2 {
		return pl != nil
	}
	if segs[2] == "enabled" {
		return len(segs) == 3
	}
	if segs[2] == "keybinds" && len(segs) >= 4 {
		name := strings.join(segs[3:], "/", context.temp_allocator)
		for cmd in e.ed.plugins.commands {
			if cmd.owner == pl.name && cmd.config_name == name {
				return true
			}
		}
		return false
	}
	L := e.ed.plugins.L
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(pl.cfg))
	for seg in segs[2:] {
		if lua.type(L, -1) != .TABLE {
			lua.pop(L, 1)
			return false
		}
		lua.pushstring(L, strings.clone_to_cstring(seg, context.temp_allocator))
		lua.rawget(L, -2)
		lua.remove(L, -2)
	}
	found := lua.type(L, -1) != .NIL
	lua.pop(L, 1)
	return found
}

@(test)
e2e_config_master_keys_moved :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	v, err := json.parse(embedded_config_data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the embedded config parses")
	root := v.(json.Object)
	paths: for path in MASTER_CONFIG_PATHS {
		if mk_exists(&e, root, path) {
			continue
		}
		for other in MASTER_CONFIG_PATHS {
			if strings.has_prefix(other, path) && strings.has_prefix(other[len(path):], "/") {
				continue paths
			}
		}
		dest, moved := config_moved(path)
		if !testing.expectf(t, moved, "%q existed on master: it must still exist or have a CONFIG_MOVED entry", path) {
			continue
		}
		if strings.has_prefix(path, "languages/") {
			continue
		}
		testing.expectf(t, mk_exists(&e, root, dest), "%q moved to %q, which does not exist", path, dest)
	}
	moved_colors: [len(THEME_MOVED)]string
	for m, i in THEME_MOVED {
		moved_colors[i] = m[0]
	}
	for key in MASTER_THEME_COLORS {
		found := slice.contains(moved_colors[:], key)
		for c in config_colors {
			found ||= c.key == key
		}
		testing.expectf(t, found, "theme color %q existed on master: it must still exist or be in THEME_MOVED", key)
	}
}
