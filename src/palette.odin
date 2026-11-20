package main

import "core:fmt"
import "lib:tb2"

PALETTE_WIDTH :: 60

Command :: struct {
	name:        string,
	bare:        string,
	config_name: string,
	bind_from:   string,
	shortcut:    string,
	key:         tb2.Key,
	alt_ch:      rune,
	ch:          rune,
	module:      Module,
	lsp:         bool,
	run:         proc(editor: ^Editor),
	owner:       string,
	id:          u64,
	ref:         i32,
	when_ref:    i32,
	scope:       string,
	welcome:     bool,
	key_default: string,
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

command_config_name :: proc(cmd: Command) -> string {
	return cmd.config_name if cmd.config_name != "" else cmd.name
}

// A pane command with `bind_from` set has no config key of its own; it derives
// its key/alt/shortcut live from the named global command (one source of truth, so a
// rebind of the global one moves both). Commands without it use their own fields.
command_effective_bind :: proc(cmd: Command) -> (key: tb2.Key, alt_ch: rune, shortcut: string) {
	if cmd.bind_from != "" {
		for g in commands {
			if g.name == cmd.bind_from {
				return g.key, g.alt_ch, g.shortcut
			}
		}
		return {}, 0, ""
	}
	return cmd.key, cmd.alt_ch, cmd.shortcut
}

cmd_undo :: proc(editor: ^Editor) {
	editor_undo(editor)
	editor_scroll(editor)
}
cmd_redo :: proc(editor: ^Editor) {
	editor_redo(editor)
	editor_scroll(editor)
}
cmd_select_all :: proc(editor: ^Editor) {
	cursor_select_all(editor_buffer(editor))
	editor_scroll(editor)
}

cmd_buffer_start :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.selection = nil
	cursor_move_buffer_start(b)
	editor_scroll(editor)
}

cmd_buffer_end :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.selection = nil
	cursor_move_buffer_end(b)
	editor_scroll(editor)
}

cmd_toggle_comment :: proc(editor: ^Editor) {
	buffer_toggle_comment(editor_buffer(editor))
	editor_scroll(editor)
}
cmd_lsp_restart :: proc(editor: ^Editor) {lsp_restart(editor)}
cmd_lsp_definition :: proc(editor: ^Editor) {lsp_definition(editor)}
cmd_lsp_hover :: proc(editor: ^Editor) {lsp_hover(editor)}
cmd_lsp_rename :: proc(editor: ^Editor) {rename_open(editor)}
cmd_diag_next :: proc(editor: ^Editor) {diag_goto(editor, +1)}
cmd_diag_prev :: proc(editor: ^Editor) {diag_goto(editor, -1)}
cmd_diff_next :: proc(editor: ^Editor) {diffbase_goto(editor, +1)}
cmd_diff_prev :: proc(editor: ^Editor) {diffbase_goto(editor, -1)}
cmd_diff_revert :: proc(editor: ^Editor) {diffbase_revert(editor)}

cmd_toggle_diff_view :: proc(editor: ^Editor) {
	g_diff_view = !g_diff_view
	editor_log(editor, .Info, "", fmt.tprintf("Diff view: %s", "on" if g_diff_view else "off"))
}

cmd_toggle_line_wrap :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.wrap = !b.wrap
	editor.scroll_col = 0
	editor.scroll_sub = 0
	editor_scroll(editor)
	editor_log(editor, .Info, "", fmt.tprintf("Line wrap: %s", "on" if b.wrap else "off"))
}

cmd_toggle_inline_completion :: proc(editor: ^Editor) {
	editor.fim.enabled = !editor.fim.enabled
	editor.fim.warned = false
	if !editor.fim.enabled {
		fim_dismiss(editor)
	}
	editor_log(editor, .Info, "", fmt.tprintf("Inline completion: %s", "on" if editor.fim.enabled else "off"))
}

cmd_ai_edit :: proc(editor: ^Editor) {aiedit_open(editor)}
cmd_ai_cancel :: proc(editor: ^Editor) {llm_cancel_all(editor)}
cmd_inspect_tokens :: proc(editor: ^Editor) {inspect_toggle(editor)}
cmd_message_log :: proc(editor: ^Editor) {logview_open(editor)}
cmd_plugins :: proc(editor: ^Editor) {pluginview_open(editor)}
cmd_log_debug :: proc(editor: ^Editor) {logview_toggle(editor, .Debug)}
cmd_log_info :: proc(editor: ^Editor) {logview_toggle(editor, .Info)}
cmd_log_warn :: proc(editor: ^Editor) {logview_toggle(editor, .Warn)}
cmd_log_error :: proc(editor: ^Editor) {logview_toggle(editor, .Error)}

// Keybinds are config: defaults come from the embedded config/config.json
// `keybinds` section, applied by config_seed_defaults before main.
commands := [?]Command {
	{name = "Command Palette", run = palette_open},
	{name = "Terminal: Toggle", run = term_toggle},
	{name = "Find", run = find_open},
	{name = "Replace", run = find_open_replace},
	{name = "Go to Start of File", run = cmd_buffer_start},
	{name = "Go to End of File", run = cmd_buffer_end},
	{name = "Jump Back", run = jump_back},
	{name = "Jump Forward", run = jump_forward},
	{name = "Close Buffer", run = editor_close_buffer},
	{name = "Save", run = editor_save},
	{name = "Quit", run = editor_request_quit},
	{name = "Undo", run = cmd_undo},
	{name = "Redo", run = cmd_redo},
	{name = "Cut", run = editor_cut},
	{name = "Copy", run = editor_copy},
	{name = "Paste", run = editor_paste},
	{name = "Select All", run = cmd_select_all},
	{name = "Toggle Comment", run = cmd_toggle_comment},
	{name = "LSP: Go to Definition", lsp = true, run = cmd_lsp_definition},
	{name = "LSP: Hover", lsp = true, run = cmd_lsp_hover},
	{name = "LSP: Rename Symbol", lsp = true, run = cmd_lsp_rename},
	{name = "AI: Edit Selection", module = .Ai, run = cmd_ai_edit},
	{name = "AI: Cancel Edits", module = .Ai, run = cmd_ai_cancel},
	{name = "AI: Toggle Inline Completion", module = .Ai, run = cmd_toggle_inline_completion},
	{name = "Diff: Toggle Diff View", run = cmd_toggle_diff_view},
	{name = "Diff: Next Change", run = cmd_diff_next},
	{name = "Diff: Previous Change", run = cmd_diff_prev},
	{name = "Diff: Revert Hunk", run = cmd_diff_revert},
	{name = "Git: Resolve Conflict", run = cmd_merge_resolve},
	{name = "Toggle Line Wrap", run = cmd_toggle_line_wrap},
	{name = "LSP: Next Diagnostic", lsp = true, run = cmd_diag_next},
	{name = "LSP: Previous Diagnostic", lsp = true, run = cmd_diag_prev},
	{name = "LSP: Restart", lsp = true, run = cmd_lsp_restart},
	{name = "Debug: Inspect Tokens", run = cmd_inspect_tokens},
	{name = "Debug: Message Log", run = cmd_message_log},
	{name = "Debug: Plugins", run = cmd_plugins},
}

pane_commands := [?]Command {
	{name = "Copy", scope = "log", bind_from = "Copy", run = logview_copy},
	{name = "Toggle Debug", scope = "log", config_name = "Message Log: Toggle Debug", run = cmd_log_debug},
	{name = "Toggle Info", scope = "log", config_name = "Message Log: Toggle Info", run = cmd_log_info},
	{name = "Toggle Warn", scope = "log", config_name = "Message Log: Toggle Warn", run = cmd_log_warn},
	{name = "Toggle Error", scope = "log", config_name = "Message Log: Toggle Error", run = cmd_log_error},
	{name = "Toggle History", scope = "log", config_name = "Message Log: Toggle History", run = logview_toggle_history},
	{name = "Enable/Disable", scope = "plugins", config_name = "Plugins: Enable/Disable", run = pluginview_toggle},
	{name = "Reload", scope = "plugins", config_name = "Plugins: Reload", run = pluginview_reload},
	{name = "Show Log", scope = "plugins", config_name = "Plugins: Show Log", run = pluginview_log},
}

command_enabled :: proc(cmd: Command) -> bool {
	return module_enabled(cmd.module) && (!cmd.lsp || LSP_ENABLED)
}

command_gated :: proc(name: string) -> bool {
	for cmd in commands {
		if cmd.name == name {
			return !command_enabled(cmd)
		}
	}
	return false
}

command_available :: proc(editor: ^Editor, name: string, scope := "") -> bool {
	if name == "Command Palette" {
		return false
	}
	if scope != "" {
		return true
	}
	if command_gated(name) {
		return false
	}
	if editor.welcome {
		switch name {
		case "Terminal: Toggle", "Debug: Plugins", "Debug: Message Log", "Quit":
			return true
		}
		return false
	}
	if editor_buffer(editor).big {
		switch name {
		case "LSP: Go to Definition", "LSP: Hover", "LSP: Rename Symbol",
		     "LSP: Next Diagnostic", "LSP: Previous Diagnostic", "LSP: Restart",
		     "Debug: Inspect Tokens":
			return false
		}
	}
	switch name {
	case "Diff: Next Change", "Diff: Previous Change", "Diff: Revert Hunk":
		return diffbase_active(editor_buffer(editor)) != nil
	}
	return true
}

table_command_for_key :: proc(table: []Command, key: tb2.Key) -> (Command, bool) {
	for cmd in table {
		if cmd.alt_ch == 0 && cmd.ch == 0 && cmd.shortcut != "" && cmd.key == key {
			return cmd, true
		}
	}
	return {}, false
}

table_command_for_alt :: proc(table: []Command, ch: rune) -> (Command, bool) {
	for cmd in table {
		if cmd.alt_ch != 0 && cmd.alt_ch == ch {
			return cmd, true
		}
	}
	return {}, false
}

command_for_key :: proc(key: tb2.Key) -> (Command, bool) {
	return table_command_for_key(commands[:], key)
}

command_for_alt :: proc(ch: rune) -> (Command, bool) {
	return table_command_for_alt(commands[:], ch)
}

command_bind_matches :: proc(key: tb2.Key, alt_ch, ch: rune, shortcut: string, ev: tb2.Event, bare: bool) -> bool {
	if shortcut == "" {
		return false
	}
	if ev_alt(ev) && ev.ch != 0 {
		return alt_ch != 0 && alt_ch == ev.ch
	}
	if ev.ch != 0 {
		return bare && ch != 0 && ch == ev.ch
	}
	return alt_ch == 0 && ch == 0 && key == ev.key
}

pane_command_for_event :: proc(scope: string, ev: tb2.Event, bare: bool) -> (Command, bool) {
	for cmd in pane_commands {
		if cmd.scope != scope {
			continue
		}
		key, alt_ch, shortcut := command_effective_bind(cmd)
		if command_bind_matches(key, alt_ch, cmd.ch, shortcut, ev, bare) {
			return cmd, true
		}
	}
	return {}, false
}

command_shortcut :: proc(name: string) -> string {
	for cmd in commands {
		if command_config_name(cmd) == name {
			return cmd.shortcut
		}
	}
	for cmd in pane_commands {
		if cmd.bind_from == "" && command_config_name(cmd) == name {
			return cmd.shortcut
		}
	}
	return ""
}

command_matches :: proc(ev: tb2.Event, name: string) -> bool {
	if ev_alt(ev) && ev.ch != 0 {
		if cmd, ok := command_for_alt(ev.ch); ok {
			return cmd.name == name
		}
		return false
	}
	if cmd, ok := command_for_key(ev.key); ok {
		return cmd.name == name
	}
	return false
}

palette_open :: proc(editor: ^Editor) {
	editor_clear_message(editor)
	spec := Pane {
		id = "palette",
		place = .Center,
		size = .Palette,
		chord = "Command Palette",
		fields = []PaneField{{mode = .Filter}},
		modal = true,
		has_list = true,
		list = {source = {kind = .Commands}},
		on = {activate = palette_activate},
	}
	if f := pane_focus(editor); f != nil && f.scope != "" {
		spec.kind, spec.parent, spec.list.source.scope = .Child, f.handle, f.scope
	}
	if p := pane_open(editor, spec); p != nil {
		pane_list_load(editor, p)
	}
}

palette_activate :: proc(editor: ^Editor, p: ^Pane) {
	if cmd, ok := list_command(editor, &p.list.source, pane_item_index(p, p.list.sel)); ok {
		command_run(editor, cmd)
	}
}
