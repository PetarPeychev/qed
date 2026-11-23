package main

import "core:fmt"
import "lib:tb2"


Command :: struct {
	name:        string,
	bare:        string,
	config_name: string,
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
	id:          u64,
	ref:         i32,
	when_ref:    i32,
	scope:       string,
	welcome:     bool,
	key_default: string,
}

command_config_name :: proc(cmd: Command) -> string {
	return cmd.config_name if cmd.config_name != "" else cmd.name
}

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
	b := editor_buffer(editor)
	b.wrap = !b.wrap
	editor_log(editor, .Info, "", fmt.tprintf("Line wrap: %s", "on" if b.wrap else "off"))
}

cmd_inspect_tokens :: proc(editor: ^Editor) {inspect_toggle(editor)}

// Keybinds are config: defaults come from the embedded config/config.json
// `keybinds` section, applied by config_seed_defaults before main.
commands := [?]Command {
	{name = "Command Palette", run = palette_open},
	{name = "Go to: Start of File", run = cmd_buffer_start},
	{name = "Go to: End of File", run = cmd_buffer_end},
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
	{name = "Git: Toggle Diff View", run = cmd_toggle_diff_view},
	{name = "Git: Next Change", run = cmd_diff_next},
	{name = "Git: Previous Change", run = cmd_diff_prev},
	{name = "Git: Revert Hunk", run = cmd_diff_revert},
	{name = "Toggle Line Wrap", run = cmd_toggle_line_wrap},
	{name = "LSP: Next Diagnostic", lsp = true, run = cmd_diag_next},
	{name = "LSP: Previous Diagnostic", lsp = true, run = cmd_diag_prev},
	{name = "LSP: Restart", lsp = true, run = cmd_lsp_restart},
	{name = "Debug: Inspect Tokens", run = cmd_inspect_tokens},
}

scoped_commands := [?]Command {
	{name = "Left", scope = "editor", config_name = "Editor: Left", run = ui_command_left},
	{name = "Right", scope = "editor", config_name = "Editor: Right", run = ui_command_right},
	{name = "Up", scope = "editor", config_name = "Editor: Up", run = ui_command_up, applies = ui_target_multiline},
	{name = "Down", scope = "editor", config_name = "Editor: Down", run = ui_command_down, applies = ui_target_multiline},
	{name = "Select Left", scope = "editor", config_name = "Editor: Select Left", run = ui_command_select_left},
	{name = "Select Right", scope = "editor", config_name = "Editor: Select Right", run = ui_command_select_right},
	{name = "Select Up", scope = "editor", config_name = "Editor: Select Up", run = ui_command_select_up, applies = ui_target_multiline},
	{name = "Select Down", scope = "editor", config_name = "Editor: Select Down", run = ui_command_select_down, applies = ui_target_multiline},
	{name = "Word Left", scope = "editor", config_name = "Editor: Word Left", run = ui_command_word_left},
	{name = "Word Right", scope = "editor", config_name = "Editor: Word Right", run = ui_command_word_right},
	{name = "Line Start", scope = "editor", config_name = "Editor: Line Start", run = ui_command_line_start},
	{name = "Line End", scope = "editor", config_name = "Editor: Line End", run = ui_command_line_end},
	{name = "Paragraph Up", scope = "editor", config_name = "Editor: Paragraph Up", run = ui_command_paragraph_up},
	{name = "Paragraph Down", scope = "editor", config_name = "Editor: Paragraph Down", run = ui_command_paragraph_down},
	{name = "Select Word Left", scope = "editor", config_name = "Editor: Select Word Left", run = ui_command_select_word_left},
	{name = "Select Word Right", scope = "editor", config_name = "Editor: Select Word Right", run = ui_command_select_word_right},
	{name = "Select Line Start", scope = "editor", config_name = "Editor: Select Line Start", run = ui_command_select_line_start},
	{name = "Select Line End", scope = "editor", config_name = "Editor: Select Line End", run = ui_command_select_line_end},
	{name = "Select Paragraph Up", scope = "editor", config_name = "Editor: Select Paragraph Up", run = ui_command_select_paragraph_up},
	{name = "Select Paragraph Down", scope = "editor", config_name = "Editor: Select Paragraph Down", run = ui_command_select_paragraph_down},
	{name = "Newline", scope = "editor", config_name = "Editor: Newline", run = ui_command_newline, applies = ui_target_multiline},
	{name = "Backspace", scope = "editor", config_name = "Editor: Backspace", run = ui_command_backspace},
	{name = "Field Backspace", scope = "editor", config_name = "Editor: Field Backspace", run = ui_command_backspace, applies = ui_target_one_line},
	{name = "Delete", scope = "editor", config_name = "Editor: Delete", run = ui_command_delete},
	{name = "Indent", scope = "editor", config_name = "Editor: Indent", run = ui_command_indent, applies = ui_target_multiline},
	{name = "Dedent", scope = "editor", config_name = "Editor: Dedent", run = ui_command_dedent, applies = ui_target_multiline},
	{name = "Close Inspect", scope = "editor", config_name = "Editor: Close Inspect", run = inspect_close, applies = inspect_open},
	{name = "Move Line Up", scope = "editor", config_name = "Editor: Move Line Up", run = ui_command_move_line_up, applies = ui_target_multiline},
	{name = "Move Line Down", scope = "editor", config_name = "Editor: Move Line Down", run = ui_command_move_line_down, applies = ui_target_multiline},
	{name = "Next", scope = "list", config_name = "List: Next", run = ui_command_list_next},
	{name = "Previous", scope = "list", config_name = "List: Previous", run = ui_command_list_previous},
	{name = "Page Down", scope = "list", config_name = "List: Page Down", run = ui_command_list_page_down},
	{name = "Page Up", scope = "list", config_name = "List: Page Up", run = ui_command_list_page_up},
	{name = "First", scope = "list", config_name = "List: First", run = ui_command_list_first},
	{name = "Last", scope = "list", config_name = "List: Last", run = ui_command_list_last},
	{name = "Extend Down", scope = "list_range", config_name = "List: Extend Down", run = ui_command_list_extend_down},
	{name = "Extend Up", scope = "list_range", config_name = "List: Extend Up", run = ui_command_list_extend_up},
	{name = "Undo", scope = "editor", bind_from = "Undo", run = ui_command_undo},
	{name = "Redo", scope = "editor", bind_from = "Redo", run = ui_command_redo},
	{name = "Select All", scope = "editor", bind_from = "Select All", run = ui_command_select_all},
	{name = "Copy", scope = "editor", bind_from = "Copy", run = ui_command_copy},
	{name = "Cut", scope = "editor", bind_from = "Cut", run = ui_command_cut},
	{name = "Paste", scope = "editor", bind_from = "Paste", run = ui_command_paste},
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

command_shortcut :: proc(name: string) -> string {
	for cmd in commands {
		if command_config_name(cmd) == name {
			return cmd.shortcut
		}
	}
	for cmd in scoped_commands {
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

// the palette is the bundled palette plugin; core only forwards its chord
palette_open :: proc(editor: ^Editor) {
	for command in editor.plugins.commands {
		if command.owner == "palette" && command.bare == "Open" && command.scope == "" {
			plugin_command_run(editor, command)
			return
		}
	}
	editor_log(editor, .Warn, "", "The command palette is the palette plugin, which is not running")
}
