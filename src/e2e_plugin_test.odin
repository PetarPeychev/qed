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
				qed.command{name = "Greet: Hello", key = "Alt+j", run = function(ctx)
					qed.message("hello from lua")
				end}
				qed.command{name = "Greet: Hidden", when = function() return false end, run = function() end}
			end,
		}`)
	testing.expect_value(t, pl.state, PluginState.Enabled)

	e2e_key(&e, .Ctrl_P)
	testing.expect(t, e.ed.palette.active, "Ctrl+P opens the palette")
	e2e_type(&e, "greet: hello")
	p := &e.ed.palette
	testing.expect_value(t, palette_command(&e.ed, p.selected).name, "Greet: Hello")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Greet: Hello"), "the plugin command is listed")
	testing.expect(t, e2e_grid_has(&e, "Alt+j"), "with its shortcut")
	testing.expect(t, !e2e_grid_has(&e, "Greet: Hidden"), "a when-gated command is hidden")

	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.palette.active, "Enter runs and closes")
	testing.expect_value(t, e.ed.message, "hello from lua")
	testing.expect_value(t, e.ed.message_source, "greet")

	editor_clear_message(&e.ed)
	e2e_key(&e, tb2.Key(0), .Alt, 'j')
	testing.expect_value(t, e.ed.message, "hello from lua")
}

@(test)
e2e_plugin_pane :: proc(t: ^testing.T) {
	e := e2e_start("abc")
	defer e2e_stop(&e)

	e2e_plugin(&e, "fine", `return {}`)
	e2e_plugin(&e, "broken", `return {setup = function() error("setup exploded") end}`)

	e2e_key(&e, .Ctrl_P)
	e2e_type(&e, "debug: plugins")
	e2e_key(&e, .Enter)
	testing.expect(t, e.ed.pluginview.active, "Debug: Plugins opens the pane")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "fine     user     enabled"), "a healthy plugin row")
	testing.expect(t, e2e_grid_has(&e, "broken   user     errored"), "an errored plugin row")
	testing.expect(t, e2e_grid_has(&e, "format   bundled  enabled"), "the bundled format plugin row")
	testing.expect(t, e2e_grid_has(&e, "pickers  bundled  enabled"), "the bundled pickers plugin row")
	testing.expect(t, e2e_grid_has(&e, "tasks    bundled  enabled"), "the bundled tasks plugin row")
	testing.expect(t, e2e_grid_has(&e, "git      bundled  enabled"), "the bundled git plugin row")

	for _ in 0 ..< 6 {
		e2e_key(&e, .Arrow_Down)
	}
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "setup exploded"), "the selected row's last error shows in the footer")

	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.pluginview.active, "Esc closes the pane")
}

@(test)
e2e_plugin_edit_undo :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta")
	defer e2e_stop(&e)

	pl := e2e_plugin(&e, "wrap", `
		return {
			setup = function()
				qed.command{name = "Wrap: Lines", key = "Alt+j", run = function(ctx)
					local b = ctx.buf
					qed.edit(b, function()
						for row = 1, qed.buf.line_count(b) do
							local line = qed.buf.line(b, row)
							qed.buf.insert(b, {row = row, col = #line + 1}, "]")
							qed.buf.insert(b, {row = row, col = 1}, "[")
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
