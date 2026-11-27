package main

import "core:fmt"
import "lib:tb2"


Command :: struct {
	name:        string,
	bare:        string,
	id:          string,
	bind_from:   string,
	shortcut:    string,
	key:         tb2.Key,
	alt_ch:      rune,
	ch:          rune,
	lsp:         bool,
	run:         proc(editor: ^Editor),
	// a scoped core command that does not apply lets its chord fall through to the next handler
	applies:     proc(editor: ^Editor) -> bool,
	owner:       string,
	serial:      u64,
	ref:         i32,
	when_ref:    i32,
	scope:       string,
	welcome:     bool,
	key_default: string,
}

command_effective_bind :: proc(cmd: Command) -> (key: tb2.Key, alt_ch: rune, shortcut: string) {
	if cmd.bind_from != "" {
		for g in commands {
			if g.id == cmd.bind_from {
				return g.key, g.alt_ch, g.shortcut
			}
		}
		return {}, 0, ""
	}
	return cmd.key, cmd.alt_ch, cmd.shortcut
}

cmd_undo :: proc(editor: ^Editor) {
	editor_undo(editor)
}
cmd_redo :: proc(editor: ^Editor) {
	editor_redo(editor)
}
cmd_select_all :: proc(editor: ^Editor) {
	cursor_select_all(editor_buffer(editor))
}

cmd_buffer_start :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.selection = nil
	cursor_move_buffer_start(b)
}

cmd_buffer_end :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.selection = nil
	cursor_move_buffer_end(b)
}

cmd_toggle_comment :: proc(editor: ^Editor) {
	buffer_toggle_comment(editor_buffer(editor))
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
	g_line_wrap = !g_line_wrap
	editor_log(editor, .Info, "", fmt.tprintf("Line wrap: %s", "on" if g_line_wrap else "off"))
}

cmd_inspect_tokens :: proc(editor: ^Editor) {inspect_toggle(editor)}

// Keybinds are config: defaults come from config/keybinds.json's "core" group, keyed by id.
commands := [?]Command {
	{name = "Command Palette", id = "command_palette", run = palette_open},
	{name = "Go to: Start of File", id = "go_to_start_of_file", run = cmd_buffer_start},
	{name = "Go to: End of File", id = "go_to_end_of_file", run = cmd_buffer_end},
	{name = "Jump Back", id = "jump_back", run = jump_back},
	{name = "Jump Forward", id = "jump_forward", run = jump_forward},
	{name = "Close Buffer", id = "close_buffer", run = editor_close_buffer},
	{name = "Save", id = "save", run = editor_save},
	{name = "Quit", id = "quit", run = editor_request_quit},
	{name = "Undo", id = "undo", run = cmd_undo},
	{name = "Redo", id = "redo", run = cmd_redo},
	{name = "Cut", id = "cut", run = editor_cut},
	{name = "Copy", id = "copy", run = editor_copy},
	{name = "Paste", id = "paste", run = editor_paste},
	{name = "Select All", id = "select_all", run = cmd_select_all},
	{name = "Toggle Comment", id = "toggle_comment", run = cmd_toggle_comment},
	{name = "LSP: Go to Definition", id = "lsp_go_to_definition", lsp = true, run = cmd_lsp_definition},
	{name = "LSP: Hover", id = "lsp_hover", lsp = true, run = cmd_lsp_hover},
	{name = "LSP: Rename Symbol", id = "lsp_rename_symbol", lsp = true, run = cmd_lsp_rename},
	{name = "Git: Toggle Diff View", id = "git_toggle_diff_view", run = cmd_toggle_diff_view},
	{name = "Git: Next Change", id = "git_next_change", run = cmd_diff_next},
	{name = "Git: Previous Change", id = "git_previous_change", run = cmd_diff_prev},
	{name = "Git: Revert Hunk", id = "git_revert_hunk", run = cmd_diff_revert},
	{name = "Toggle Line Wrap", id = "toggle_line_wrap", run = cmd_toggle_line_wrap},
	{name = "LSP: Next Diagnostic", id = "lsp_next_diagnostic", lsp = true, run = cmd_diag_next},
	{name = "LSP: Previous Diagnostic", id = "lsp_previous_diagnostic", lsp = true, run = cmd_diag_prev},
	{name = "LSP: Restart", id = "lsp_restart", lsp = true, run = cmd_lsp_restart},
	{name = "Debug: Inspect Tokens", id = "debug_inspect_tokens", run = cmd_inspect_tokens},
}

scoped_commands := [?]Command {
	{name = "Left", scope = "editor", id = "editor_left", run = ui_command_left},
	{name = "Right", scope = "editor", id = "editor_right", run = ui_command_right},
	{name = "Up", scope = "editor", id = "editor_up", run = ui_command_up, applies = ui_target_multiline},
	{name = "Down", scope = "editor", id = "editor_down", run = ui_command_down, applies = ui_target_multiline},
	{name = "Select Left", scope = "editor", id = "editor_select_left", run = ui_command_select_left},
	{name = "Select Right", scope = "editor", id = "editor_select_right", run = ui_command_select_right},
	{name = "Select Up", scope = "editor", id = "editor_select_up", run = ui_command_select_up, applies = ui_target_multiline},
	{name = "Select Down", scope = "editor", id = "editor_select_down", run = ui_command_select_down, applies = ui_target_multiline},
	{name = "Word Left", scope = "editor", id = "editor_word_left", run = ui_command_word_left},
	{name = "Word Right", scope = "editor", id = "editor_word_right", run = ui_command_word_right},
	{name = "Line Start", scope = "editor", id = "editor_line_start", run = ui_command_line_start},
	{name = "Line End", scope = "editor", id = "editor_line_end", run = ui_command_line_end},
	{name = "Paragraph Up", scope = "editor", id = "editor_paragraph_up", run = ui_command_paragraph_up},
	{name = "Paragraph Down", scope = "editor", id = "editor_paragraph_down", run = ui_command_paragraph_down},
	{name = "Select Word Left", scope = "editor", id = "editor_select_word_left", run = ui_command_select_word_left},
	{name = "Select Word Right", scope = "editor", id = "editor_select_word_right", run = ui_command_select_word_right},
	{name = "Select Line Start", scope = "editor", id = "editor_select_line_start", run = ui_command_select_line_start},
	{name = "Select Line End", scope = "editor", id = "editor_select_line_end", run = ui_command_select_line_end},
	{name = "Select Paragraph Up", scope = "editor", id = "editor_select_paragraph_up", run = ui_command_select_paragraph_up},
	{name = "Select Paragraph Down", scope = "editor", id = "editor_select_paragraph_down", run = ui_command_select_paragraph_down},
	{name = "Newline", scope = "editor", id = "editor_newline", run = ui_command_newline, applies = ui_target_multiline},
	{name = "Backspace", scope = "editor", id = "editor_backspace", run = ui_command_backspace},
	{name = "Field Backspace", scope = "editor", id = "editor_field_backspace", run = ui_command_backspace, applies = ui_target_one_line},
	{name = "Delete", scope = "editor", id = "editor_delete", run = ui_command_delete},
	{name = "Indent", scope = "editor", id = "editor_indent", run = ui_command_indent, applies = ui_target_multiline},
	{name = "Dedent", scope = "editor", id = "editor_dedent", run = ui_command_dedent, applies = ui_target_multiline},
	{name = "Close Inspect", scope = "editor", id = "editor_close_inspect", run = inspect_close, applies = inspect_open},
	{name = "Move Line Up", scope = "editor", id = "editor_move_line_up", run = ui_command_move_line_up, applies = ui_target_multiline},
	{name = "Move Line Down", scope = "editor", id = "editor_move_line_down", run = ui_command_move_line_down, applies = ui_target_multiline},
	{name = "Next", scope = "list", id = "list_next", run = ui_command_list_next},
	{name = "Previous", scope = "list", id = "list_previous", run = ui_command_list_previous},
	{name = "Page Down", scope = "list", id = "list_page_down", run = ui_command_list_page_down},
	{name = "Page Up", scope = "list", id = "list_page_up", run = ui_command_list_page_up},
	{name = "First", scope = "list", id = "list_first", run = ui_command_list_first},
	{name = "Last", scope = "list", id = "list_last", run = ui_command_list_last},
	{name = "Extend Down", scope = "list_range", id = "list_extend_down", run = ui_command_list_extend_down},
	{name = "Extend Up", scope = "list_range", id = "list_extend_up", run = ui_command_list_extend_up},
	{name = "Undo", scope = "editor", bind_from = "undo", run = ui_command_undo},
	{name = "Redo", scope = "editor", bind_from = "redo", run = ui_command_redo},
	{name = "Select All", scope = "editor", bind_from = "select_all", run = ui_command_select_all},
	{name = "Copy", scope = "editor", bind_from = "copy", run = ui_command_copy},
	{name = "Cut", scope = "editor", bind_from = "cut", run = ui_command_cut},
	{name = "Paste", scope = "editor", bind_from = "paste", run = ui_command_paste},
}

command_enabled :: proc(cmd: Command) -> bool {
	return !cmd.lsp || LSP_ENABLED
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
		case "Quit":
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
	case "Git: Next Change", "Git: Previous Change", "Git: Revert Hunk":
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

command_shortcut :: proc(id: string) -> string {
	for cmd in commands {
		if cmd.id == id {
			return cmd.shortcut
		}
	}
	for cmd in scoped_commands {
		if cmd.bind_from == "" && cmd.id == id {
			return cmd.shortcut
		}
	}
	return ""
}

command_matches :: proc(ev: tb2.Event, id: string) -> bool {
	if ev_alt(ev) && ev.ch != 0 {
		if cmd, ok := command_for_alt(ev.ch); ok {
			return cmd.id == id
		}
		return false
	}
	if cmd, ok := command_for_key(ev.key); ok {
		return cmd.id == id
	}
	return false
}

// the palette is the bundled palette plugin; core only forwards its chord
palette_open :: proc(editor: ^Editor) {
	for command in editor.plugins.commands {
		if command.owner == "palette" && command.id == "open" && command.scope == "" {
			plugin_command_run(editor, command)
			return
		}
	}
	editor_log(editor, .Warn, "", "The command palette is the palette plugin, which is not running")
}
