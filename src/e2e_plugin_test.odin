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
	testing.expect(t, e2e_grid_has(&e, "fine    user     enabled"), "a healthy plugin row")
	testing.expect(t, e2e_grid_has(&e, "broken  user     errored"), "an errored plugin row")

	e2e_key(&e, .Arrow_Down)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "setup exploded"), "the selected row's last error shows in the footer")

	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.pluginview.active, "Esc closes the pane")
}
