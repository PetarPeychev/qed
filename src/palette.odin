package main

import "core:fmt"
import "lib:tb2"

PALETTE_WIDTH :: 60

Command :: struct {
	name:        string,
	config_name: string,
	bind_from:   string,
	shortcut:    string,
	key:         tb2.Key,
	alt_ch:      rune,
	module:      Module,
	run:         proc(editor: ^Editor),
	owner:       string,
	id:          u64,
	ref:         i32,
	when_ref:    i32,
	filetree:    bool,
	welcome:     bool,
	key_default: string,
}

command_run :: proc(editor: ^Editor, cmd: Command) {
	if cmd.owner != "" {
		plugin_command_run(editor, cmd)
		return
	}
	cmd.run(editor)
}

command_config_name :: proc(cmd: Command) -> string {
	return cmd.config_name if cmd.config_name != "" else cmd.name
}

// A file-tree command with `bind_from` set has no config key of its own; it derives
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
cmd_git_next :: proc(editor: ^Editor) {git_goto(editor, +1)}
cmd_git_prev :: proc(editor: ^Editor) {git_goto(editor, -1)}
cmd_git_revert :: proc(editor: ^Editor) {git_revert(editor)}
cmd_git_set_base :: proc(editor: ^Editor) {basepick_open(editor)}

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

// Keybinds are config: defaults come from the embedded config/config.json
// `keybinds` section, applied by config_seed_defaults before main.
commands := [?]Command {
	{name = "Command Palette", run = palette_open},
	{name = "File Tree", run = filetree_open_all},
	{name = "File Tree: Open", run = filetree_open_open},
	{name = "File Tree: Git", module = .Git, run = filetree_open_git},
	{name = "File Tree: Unsaved", run = filetree_open_unsaved},
	{name = "Terminal: Toggle", run = term_toggle},
	{name = "Find", run = find_open},
	{name = "Replace", run = find_open_replace},
	{name = "Find Line", run = linefind_open},
	{name = "Find in Files", run = projsearch_open},
	{name = "Change Working Directory", run = cwdpick_open},
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
	{name = "LSP: Go to Definition", module = .Lsp, run = cmd_lsp_definition},
	{name = "LSP: Hover", module = .Lsp, run = cmd_lsp_hover},
	{name = "LSP: Rename Symbol", module = .Lsp, run = cmd_lsp_rename},
	{name = "AI: Edit Selection", module = .Ai, run = cmd_ai_edit},
	{name = "AI: Cancel Edits", module = .Ai, run = cmd_ai_cancel},
	{name = "AI: Toggle Inline Completion", module = .Ai, run = cmd_toggle_inline_completion},
	{name = "Git: Toggle Diff View", module = .Git, run = cmd_toggle_diff_view},
	{name = "Git: Next Change", module = .Git, run = cmd_git_next},
	{name = "Git: Previous Change", module = .Git, run = cmd_git_prev},
	{name = "Git: Revert Hunk", module = .Git, run = cmd_git_revert},
	{name = "Git: Set Diff Base", module = .Git, run = cmd_git_set_base},
	{name = "Git: Resolve Conflict", module = .Git, run = cmd_merge_resolve},
	{name = "Toggle Line Wrap", run = cmd_toggle_line_wrap},
	{name = "LSP: Next Diagnostic", module = .Lsp, run = cmd_diag_next},
	{name = "LSP: Previous Diagnostic", module = .Lsp, run = cmd_diag_prev},
	{name = "LSP: Restart", module = .Lsp, run = cmd_lsp_restart},
	{name = "Debug: Inspect Tokens", run = cmd_inspect_tokens},
	{name = "Debug: Message Log", run = cmd_message_log},
	{name = "Debug: Plugins", run = cmd_plugins},
}

filetree_commands := [?]Command {
	{name = "Copy", bind_from = "Copy", run = filetree_cmd_copy},
	{name = "Cut", bind_from = "Cut", run = filetree_cmd_cut},
	{name = "Paste", bind_from = "Paste", run = filetree_clip_paste},
	{name = "Delete", config_name = "File Tree: Delete", run = filetree_cmd_delete},
	{name = "Close Buffers", bind_from = "Close Buffer", run = filetree_cmd_close},
	{name = "Rename", config_name = "File Tree: Rename", run = filetree_cmd_rename},
	{name = "New", config_name = "File Tree: New", run = filetree_cmd_new},
	{name = "Select All", bind_from = "Select All", run = filetree_select_all},
	{name = "Search", bind_from = "Find in Files", run = filetree_cmd_search},
	{name = "Set as Working Directory", bind_from = "Change Working Directory", run = filetree_cmd_set_root},
	{name = "Toggle Dotfiles", config_name = "File Tree: Toggle Dotfiles", run = filetree_toggle_dotfiles},
	{name = "Toggle Ignored", config_name = "File Tree: Toggle Ignored", run = filetree_toggle_ignored},
	{name = "Toggle Diff", config_name = "File Tree: Toggle Diff", module = .Git, run = filetree_toggle_git_diff},
	{name = "Restore File", config_name = "File Tree: Restore File", module = .Git, run = filetree_cmd_restore},
	{name = "Expand/Collapse All", config_name = "File Tree: Expand/Collapse All", run = filetree_toggle_expand_all},
}

command_module :: proc(name: string) -> Module {
	for cmd in commands {
		if cmd.name == name {
			return cmd.module
		}
	}
	for cmd in filetree_commands {
		if cmd.name == name {
			return cmd.module
		}
	}
	return .None
}

command_available :: proc(editor: ^Editor, name: string) -> bool {
	if name == "Command Palette" {
		return false
	}
	if !module_enabled(command_module(name)) {
		return false
	}
	if editor.welcome {
		switch name {
		case "File Tree", "File Tree: Open", "File Tree: Git", "File Tree: Unsaved",
		     "Terminal: Toggle", "Find in Files",
		     "Debug: Plugins", "Debug: Message Log", "Change Working Directory", "Quit":
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
	return true
}

table_command_for_key :: proc(table: []Command, key: tb2.Key) -> (Command, bool) {
	for cmd in table {
		if cmd.alt_ch == 0 && cmd.shortcut != "" && cmd.key == key {
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

filetree_command_for_event :: proc(ev: tb2.Event) -> (Command, bool) {
	alt := ev_alt(ev) && ev.ch != 0
	for cmd in filetree_commands {
		key, alt_ch, shortcut := command_effective_bind(cmd)
		if alt {
			if alt_ch != 0 && alt_ch == ev.ch {
				return cmd, true
			}
		} else if alt_ch == 0 && shortcut != "" && key == ev.key {
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
	for cmd in filetree_commands {
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

Palette :: struct {
	using list: FuzzyList,
	names:      [dynamic]string,
	indices:    [dynamic]int,
	filetree:   bool,
}

palette_destroy :: proc(p: ^Palette) {
	fuzzy_list_destroy(&p.list)
	delete(p.names)
	delete(p.indices)
}

palette_open :: proc(editor: ^Editor) {
	p := &editor.palette
	p.active = true
	p.filetree = editor.filetree.active
	fuzzy_list_reset(&p.list)
	editor_clear_message(editor)
	clear(&p.names)
	clear(&p.indices)
	if p.filetree {
		for cmd, i in filetree_commands {
			append(&p.names, cmd.name)
			append(&p.indices, i)
		}
	} else {
		for cmd, i in commands {
			if !command_available(editor, cmd.name) {
				continue
			}
			append(&p.names, cmd.name)
			append(&p.indices, i)
		}
	}
	base := len(filetree_commands) if p.filetree else len(commands)
	for cmd, i in editor.plugins.commands {
		if cmd.filetree != p.filetree || (editor.welcome && !p.filetree && !cmd.welcome) || !plugin_command_when(editor, cmd) {
			continue
		}
		append(&p.names, cmd.name)
		append(&p.indices, base + i)
	}
	p.fuzzy = fuzzy_begin(p.names[:])
	fuzzy_list_refilter(&p.list)
}

palette_command :: proc(editor: ^Editor, match: int) -> Command {
	return palette_command_at(editor, editor.palette.matches[match])
}

palette_command_at :: proc(editor: ^Editor, item: int) -> Command {
	p := &editor.palette
	idx := p.indices[item]
	base := len(filetree_commands) if p.filetree else len(commands)
	if idx >= base {
		return editor.plugins.commands[idx - base]
	}
	if p.filetree {
		return filetree_commands[idx]
	}
	return commands[idx]
}

palette_close :: proc(editor: ^Editor) {
	editor.palette.active = false
	fuzzy_end(&editor.palette.fuzzy)
}

palette_execute :: proc(editor: ^Editor) {
	p := &editor.palette
	if len(p.matches) == 0 {
		return
	}
	cmd := palette_command(editor, p.selected)
	palette_close(editor)
	command_run(editor, cmd)
}

palette_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	if command_matches(ev, "Command Palette") {
		palette_close(editor)
		return
	}
	fuzzy_list_key(editor, &editor.palette.list, ev, palette_execute, palette_close)
}

palette_paste :: proc(editor: ^Editor, text: string) {
	if textfield_insert_flat(&editor.palette.field, text) {
		fuzzy_list_refilter(&editor.palette.list)
	}
}

palette_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	fuzzy_list_center_mouse(editor, &editor.palette.list, ev, palette_execute, palette_close)
}

palette_render :: proc(editor: ^Editor) {
	p := &editor.palette
	shortcuts := make([]string, len(p.names), context.temp_allocator)
	for &sc, i in shortcuts {
		_, _, sc = command_effective_bind(palette_command_at(editor, i))
	}
	fuzzy_list_center_render(editor, &p.list, p.names[:], shortcuts)
}
