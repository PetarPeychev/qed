package main

import "core:testing"
import "lib:tb2"

@(test)
e2e_plugin_command_palette :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)

	pl := e2e_plugin(&e, "greet", `
		return {
			setup = function()
				qed.command{id = "hello", name = "Hello", key = "Alt+j", run = function(ctx)
					qed.message("hello from lua")
				end}
				qed.command{id = "hidden", name = "Hidden", when = function() return false end, run = function() end}
			end,
		}`)
	testing.expect_value(t, pl.state, PluginState.Enabled)

	e2e_key(&e, .Ctrl_P)
	testing.expect(t, palette_open_now(&e), "Ctrl+P opens the palette")
	e2e_type(&e, "greet: hello")
	testing.expect_value(t, palette_selected(&e), "Greet: Hello")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Greet: Hello"), "the plugin command is listed")
	testing.expect(t, e2e_grid_has(&e, "Alt+j"), "with its shortcut")
	testing.expect(t, !e2e_grid_has(&e, "Greet: Hidden"), "a when-gated command is hidden")

	e2e_key(&e, .Enter)
	testing.expect(t, !palette_open_now(&e), "Enter runs and closes")
	testing.expect_value(t, e.ed.message, "hello from lua")
	testing.expect_value(t, e.ed.message_source, "Greet")

	editor_clear_message(&e.ed)
	e2e_key(&e, tb2.Key(0), .Alt, 'j')
	testing.expect_value(t, e.ed.message, "hello from lua")
}

@(test)
e2e_plugin_palette_rows_and_focus :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)
	pl := e2e_plugin(&e, "pal", `
		local h
		return {setup = function()
			h = qed.command{id = "gone", name = "Gone", key = "Alt+j", run = function() qed.message("ran") end}
			qed.command{id = "drop", name = "Drop", run = function() h:remove() end}
		end}`)
	testing.expect_value(t, pl.state, PluginState.Enabled)

	e2e_key(&e, .Ctrl_P)
	e2e_type(&e, "pal: gone")
	testing.expect_value(t, palette_selected(&e), "Pal: Gone")
	drop, _ := plugin_test_command(&e.ed, "Pal: Drop")
	command_run(&e.ed, drop)
	testing.expect(t, palette_open_now(&e), "removing a plugin command keeps the palette")
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, e.ed.message != "ran", "a removed command does not run")
}

@(test)
e2e_plugin_pane :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)

	e2e_plugin(&e, "fine", `return {setup = function() qed.meta{description = "Does fine things"} end}`)
	e2e_plugin(&e, "broken", `return {setup = function() error("setup exploded") end}`)

	e2e_key(&e, .Ctrl_P)
	e2e_type(&e, "plugin manager: open")
	e2e_key(&e, .Enter)
	testing.expect(t, manager_shown(&e), "Plugins: Open opens the pane")
	e2e_reload_select(&e, "fine")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has_words(&e, "Fine Does fine things user enabled"), "a healthy plugin row")
	testing.expect(t, e2e_grid_has_words(&e, "Name Description Source Status Load"), "the header row titles the columns")
	e2e_reload_select(&e, "broken")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has_words(&e, "Broken user errored"), "an errored plugin row")

	broken := -1
	for pl, i in e.ed.plugins.list {
		if pl.name == "broken" {
			broken = i
		}
	}
	testing.expect(t, broken >= 0, "the broken plugin is listed")
	testing.expect_value(t, e2e_reload_selected(&e), "broken")
	e2e_resize(&e, 400, 40)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has_words(&e, "Format Formats on save and trims whitespace bundled enabled"), "the bundled format plugin row")
	testing.expect(t, e2e_grid_has_words(&e, "Settings Settings menu, theme, language, indentation and config files bundled enabled"), "the bundled settings plugin row")
	testing.expect(t, e2e_grid_has_words(&e, "Git Diff base, gutter marks and status for git repos bundled enabled"), "the bundled git plugin row")
	testing.expect(t, e2e_grid_has_words(&e, "Workspace Switches the working root directory bundled enabled"), "the bundled workspace plugin row")
	testing.expect(t, e2e_grid_has_words(&e, "Broken user errored"), "an errored plugin row")
	testing.expect(t, e2e_grid_has(&e, "setup exploded"), "the selected row's last error shows in the footer")

	e2e_key(&e, .Esc)
	testing.expect(t, !manager_shown(&e), "Esc closes the pane")
}

@(test)
e2e_plugin_edit_undo :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)

	pl := e2e_plugin(&e, "wrap", `
		return {
			setup = function()
				qed.command{id = "lines", name = "Lines", key = "Alt+j", run = function(ctx)
					local b = ctx.buf
					qed.edit(b, function()
						for row = 1, b:line_count() do
							local line = b:line(row)
							b:insert({row = row, col = #line + 1}, "]")
							b:insert({row = row, col = 1}, "[")
						end
					end)
				end}
			end,
		}`)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	b := editor_buffer(&e.ed)
	b.cursor = {1, 2}

	e2e_key(&e, tb2.Key(0), .Alt, 'j')
	testing.expect_value(t, pl.last_error, "")
	testing.expect_value(t, string(b.lines[0].text[:]), "[alpha]")
	testing.expect_value(t, string(b.lines[1].text[:]), "[beta]")
	testing.expect_value(t, b.cursor, Cursor{1, 3})

	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "alpha")
	testing.expect_value(t, string(b.lines[1].text[:]), "beta")
	testing.expect_value(t, b.cursor, Cursor{1, 2})
	testing.expect(t, !b.modified, "one undo step reverts the whole command")

	e2e_key(&e, .Ctrl_Y)
	testing.expect_value(t, string(b.lines[1].text[:]), "[beta]")
}
