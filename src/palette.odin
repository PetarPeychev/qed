package main

import "core:fmt"
import "lib:tb2"

Command :: struct {
	name:     string,
	shortcut: string,
	key:      tb2.Key,
	alt_ch:   rune,
	run:      proc(editor: ^Editor),
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
cmd_set_language :: proc(editor: ^Editor) {langpick_open(editor)}
cmd_set_theme :: proc(editor: ^Editor) {themepick_open(editor)}
cmd_lsp_restart :: proc(editor: ^Editor) {lsp_restart(editor)}
cmd_lsp_definition :: proc(editor: ^Editor) {lsp_definition(editor)}
cmd_lsp_hover :: proc(editor: ^Editor) {lsp_hover(editor)}
cmd_lsp_rename :: proc(editor: ^Editor) {rename_open(editor)}
cmd_format :: proc(editor: ^Editor) {format_document(editor)}
cmd_diag_next :: proc(editor: ^Editor) {diag_goto(editor, +1)}
cmd_diag_prev :: proc(editor: ^Editor) {diag_goto(editor, -1)}

cmd_toggle_format_on_save :: proc(editor: ^Editor) {
	editor.format_on_save = !editor.format_on_save
	editor_set_message(editor, fmt.tprintf("Format on save: %s", "on" if editor.format_on_save else "off"))
}

cmd_toggle_diff_view :: proc(editor: ^Editor) {
	g_diff_view = !g_diff_view
	editor_set_message(editor, fmt.tprintf("Diff view: %s", "on" if g_diff_view else "off"))
}

cmd_toggle_line_wrap :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	b.wrap = !b.wrap
	editor.scroll_col = 0
	editor.scroll_sub = 0
	editor_scroll(editor)
	editor_set_message(editor, fmt.tprintf("Line wrap: %s", "on" if b.wrap else "off"))
}

cmd_toggle_inline_completion :: proc(editor: ^Editor) {
	editor.fim.enabled = !editor.fim.enabled
	editor.fim.warned = false
	if !editor.fim.enabled {
		fim_dismiss(editor)
	}
	editor_set_message(editor, fmt.tprintf("Inline completion: %s", "on" if editor.fim.enabled else "off"))
}

cmd_change_indent :: proc(editor: ^Editor) {indentpick_open(editor)}
cmd_ai_edit :: proc(editor: ^Editor) {aiedit_open(editor)}
cmd_ai_cancel :: proc(editor: ^Editor) {llm_cancel_all(editor)}

// Keybinds are config: defaults come from the embedded config/config.json
// `keybinds` section, applied by config_seed_defaults before main.
commands := [?]Command {
	{name = "Open File", run = picker_open},
	{name = "File Tree", run = filetree_open},
	{name = "Terminal: Toggle", run = term_toggle},
	{name = "Find", run = find_open},
	{name = "Replace", run = find_open_replace},
	{name = "Find Line", run = linefind_open},
	{name = "Find in Files", run = projsearch_open},
	{name = "Go to Start of File", run = cmd_buffer_start},
	{name = "Go to End of File", run = cmd_buffer_end},
	{name = "Jump Back", run = jump_back},
	{name = "Jump Forward", run = jump_forward},
	{name = "Switch Buffer", run = bufswitch_open},
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
	{name = "Change Indentation", run = cmd_change_indent},
	{name = "Set Language", run = cmd_set_language},
	{name = "Set Theme", run = cmd_set_theme},
	{name = "LSP: Go to Definition", run = cmd_lsp_definition},
	{name = "LSP: Hover", run = cmd_lsp_hover},
	{name = "LSP: Rename Symbol", run = cmd_lsp_rename},
	{name = "AI: Edit Selection", run = cmd_ai_edit},
	{name = "AI: Cancel Edits", run = cmd_ai_cancel},
	{name = "AI: Toggle Inline Completion", run = cmd_toggle_inline_completion},
	{name = "Format Document", run = cmd_format},
	{name = "Toggle Format on Save", run = cmd_toggle_format_on_save},
	{name = "Git: Toggle Diff View", run = cmd_toggle_diff_view},
	{name = "Git: Resolve Conflict", run = cmd_merge_resolve},
	{name = "Toggle Line Wrap", run = cmd_toggle_line_wrap},
	{name = "LSP: Next Diagnostic", run = cmd_diag_next},
	{name = "LSP: Previous Diagnostic", run = cmd_diag_prev},
	{name = "LSP: Restart", run = cmd_lsp_restart},
}

command_for_key :: proc(key: tb2.Key) -> (Command, bool) {
	for cmd in commands {
		if cmd.alt_ch == 0 && cmd.shortcut != "" && cmd.key == key {
			return cmd, true
		}
	}
	return {}, false
}

command_for_alt :: proc(ch: rune) -> (Command, bool) {
	for cmd in commands {
		if cmd.alt_ch != 0 && cmd.alt_ch == ch {
			return cmd, true
		}
	}
	return {}, false
}

Palette :: struct {
	using list: FuzzyList,
	names:      [dynamic]string,
}

palette_destroy :: proc(p: ^Palette) {
	fuzzy_list_destroy(&p.list)
	delete(p.names)
}

palette_open :: proc(editor: ^Editor) {
	p := &editor.palette
	p.active = true
	fuzzy_list_reset(&p.list)
	editor_set_message(editor, "")
	clear(&p.names)
	for cmd in commands {
		append(&p.names, cmd.name)
	}
	p.fuzzy = fuzzy_begin(p.names[:])
	fuzzy_list_refilter(&p.list)
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
	cmd := commands[p.matches[p.selected]]
	palette_close(editor)
	cmd.run(editor)
}

palette_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.palette
	#partial switch ev.key {
	case .Esc, .Ctrl_P:
		palette_close(editor)
	case .Enter:
		palette_execute(editor)
	case .Arrow_Down:
		fuzzy_list_move(&p.list, 1, PALETTE_MAX_ROWS)
	case .Arrow_Up:
		fuzzy_list_move(&p.list, -1, PALETTE_MAX_ROWS)
	case:
		if textfield_key(&p.field, ev) {
			fuzzy_list_refilter(&p.list)
		}
	}
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
	rows := min(len(p.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &p.field)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := p.scroll + i
		cmd := commands[p.matches[idx]]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		sc_fg := COLOR_PANE_SHORTCUT_FG
		if idx == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			sc_fg = COLOR_PANE_SEL_FG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, cmd.name, fg, bg)
		sx := inner.x + inner.w - 1 - len(cmd.shortcut)
		pane_text(sx, y, len(cmd.shortcut), cmd.shortcut, sc_fg, bg)
	}
}
