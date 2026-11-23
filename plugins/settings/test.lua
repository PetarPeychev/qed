local T = {}

local function index_of(list, value)
	for i, v in ipairs(list) do
		if v == value then
			return i
		end
	end
end

local function expect_message(t, text)
	local msg, level, source = t.message()
	t.eq(msg, text, "message")
	t.eq(level, "info", "message level")
	t.eq(source, "Settings", "message source")
end

function T.theme_opens_on_current(t)
	local current = qed.theme.current()
	qed.run("Settings: Theme")
	local ui = t.ui()
	t.ok(ui and ui.kind == "pick", "Set Theme opens a picker")
	t.eq(ui.selected, current, "the current theme is highlighted")
	t.eq(ui.matches, #qed.theme.list(), "every theme is listed")
	t.key("Esc")
end

function T.theme_preview_and_esc_revert(t)
	local names = qed.theme.list()
	local original = qed.theme.current()
	local i = index_of(names, original)
	local step = i < #names and "Down" or "Up"
	local next_name = names[i < #names and i + 1 or i - 1]
	qed.run("Settings: Theme")
	t.key(step)
	t.eq(qed.theme.current(), next_name, "moving previews the highlighted theme")
	t.eq(qed.opt("theme"), original, "a preview does not change the configured theme")
	t.type("solarized-light")
	t.eq(qed.theme.current(), "solarized-light", "filtering previews the top match")
	t.key("Esc")
	t.ok(t.ui() == nil, "Esc closes the picker")
	t.eq(qed.theme.current(), original, "Esc reverts the preview")
	t.ok(not qed.fs.exists(t.config_path()), "Esc writes no config")
end

function T.theme_enter_persists_only_the_theme_key(t)
	local original = qed.theme.current()
	qed.fs.write(t.config_path(), '{"tab_width": 2}')
	local fired = 0
	local h = qed:on("theme_changed", function() fired = fired + 1 end)
	qed.run("Settings: Theme")
	t.type("nord")
	t.pump(20)
	t.eq(fired, 0, "previews fire no theme_changed")
	t.key("Enter")
	t.wait(function() return fired == 1 end)
	h:off()
	t.ok(t.ui() == nil, "Enter closes the picker")
	t.eq(qed.theme.current(), "nord")
	t.eq(qed.opt("theme"), "nord", "Enter makes it the configured theme")
	expect_message(t, "Theme set to nord")
	local cfg = qed.json.decode(qed.fs.read(t.config_path()))
	t.eq(cfg.theme, "nord", "the theme key is written")
	t.eq(cfg.tab_width, 2, "other keys are kept")
	qed.theme.set(original, {persist = true})
end

function T.theme_typing_previews(t)
	local original = qed.theme.current()
	qed.run("Settings: Theme")
	t.type("dracula")
	t.eq(qed.theme.current(), "dracula", "typing previews")
	t.key("Backspace")
	t.key("Esc")
	t.eq(qed.theme.current(), original, "Esc after edits still reverts")
end

function T.language_set(t)
	local b = t.open("a.txt", "x = 1")
	t.eq(b:language(), "text")
	qed.run("Settings: Language")
	local ui = t.ui()
	t.ok(ui and ui.kind == "pick", "Set Language opens a picker")
	t.eq(ui.matches, #qed.languages(), "every language is listed")
	t.type("python")
	t.eq(t.ui().selected, "python")
	t.key("Enter")
	t.eq(b:language(), "python", "Enter sets the buffer language")
	expect_message(t, "Language set to python")
end

function T.language_same_is_silent(t)
	local b = t.open("a.py", "x = 1")
	qed.run("Settings: Language")
	t.eq(t.ui().selected, "python", "the current language is preselected")
	t.type("python")
	t.key("Enter")
	t.eq(b:language(), "python")
	t.eq((t.message()), "", "picking the current language shows no message")
end

function T.language_esc_keeps(t)
	local b = t.open("a.txt", "x")
	qed.run("Settings: Language")
	t.type("python")
	t.key("Esc")
	t.ok(t.ui() == nil, "Esc closes")
	t.eq(b:language(), "text", "Esc leaves the language alone")
end

function T.indent_options(t)
	local b = t.open("a.txt", "x")
	qed.run("Settings: Indentation")
	local ui = t.ui()
	t.ok(ui and ui.kind == "pick", "Change Indentation opens a picker")
	t.eq(ui.matches, 6, "six options")
	t.eq(ui.selected, "Auto-detect", "the first option is highlighted")
	t.type("tabs")
	t.key("Enter")
	t.eq((b:indent()), "tabs")
	expect_message(t, "Indentation set to Tabs")

	qed.run("Settings: Indentation")
	t.type("spaces:2")
	t.key("Enter")
	local style, width = b:indent()
	t.eq(style, "spaces")
	t.eq(width, 2)
	expect_message(t, "Indentation set to Spaces:2")
end

function T.indent_auto_detect(t)
	local b = t.open("a.txt", "a\n\tb")
	b:set_indent("spaces", 4)
	qed.run("Settings: Indentation")
	t.key("Enter")
	t.eq((b:indent()), "tabs", "auto-detect reads the content")
	expect_message(t, "Indentation set to Tabs")
end

function T.indent_esc_keeps(t)
	local b = t.open("a.txt", "x")
	local style, width = b:indent()
	qed.run("Settings: Indentation")
	t.key("Down")
	t.key("Esc")
	local s2, w2 = b:indent()
	t.eq(s2, style)
	t.eq(w2, width)
end

function T.open_config_creates_and_opens(t)
	local path = t.config_path()
	t.ok(not qed.fs.exists(path), "no config yet")
	qed.run("Settings: Open Config")
	t.eq(qed.fs.read(path), "{}\n", "the file is created")
	local b = qed.buf.current()
	t.eq(b:path(), path, "it opens in the editor")
	t.eq(b:language(), "json")
	qed.close(b)
	qed.fs.write(path, '{"tab_width": 2}')
	qed.run("Settings: Open Config")
	t.eq(qed.buf.current():text(), '{"tab_width": 2}', "an existing file is not overwritten")
	qed.close(qed.buf.current())
	qed.fs.remove(path)
end

local function user_cfg(t)
	if not qed.fs.exists(t.config_path()) then
		return {}
	end
	return qed.json.decode(qed.fs.read(t.config_path()))
end

local function count(tbl)
	local n = 0
	for _ in pairs(tbl) do
		n = n + 1
	end
	return n
end

local function open_menu(t, tab)
	qed.run("Settings: Open")
	local ui = t.ui()
	t.ok(ui and ui.id == "settings", "the settings pane opens")
	if tab == 2 then
		t.key("Right")
		t.wait(function() return t.ui().tab == 2 and t.ui().info:find("Scope: ") ~= nil end)
	end
end

local function select(t, filter, label)
	if t.ui().query ~= "" then
		t.key("Esc")
	end
	t.type(filter)
	t.eq(t.ui().selected, label, "filtering selects " .. label)
end

local function value(t)
	return t.ui().cells[2]
end

function T.menu_lists_core_and_plugin_options(t)
	open_menu(t)
	t.eq(t.ui().tab, 1, "it opens on Options")
	select(t, "line_wrap", "line_wrap")
	local cells = t.ui().cells
	t.eq(#cells, 2, "Key and Value columns")
	t.eq(cells[1], "line_wrap")
	t.eq(cells[2], "true", "the current value")
	t.wait(function() return t.ui().info == "Soft wrap long lines in new buffers. Default: true" end)
	t.ok(t.ui().mark == nil, "a default is not marked")
	select(t, "lsp.enabled", "lsp.enabled")
	t.wait(function() return t.ui().info == "Start language servers. Default: true" end)
	select(t, "languages.python.lsp", "languages.python.lsp")
	t.eq(value(t), "pyright-langserver --stdio")
	select(t, "search.min_query", "search.min_query")
	t.eq(value(t), "2")
	t.wait(function() return t.ui().info == "Characters typed before a search runs. Default: 2" end)
	select(t, "search.enabled", "search.enabled")
	t.eq(value(t), "true")
	select(t, "format.commands.python", "format.commands.python")
	t.wait(function() return t.ui().info:find("^Formatter per language: a stdin to stdout command, {file} is the path%.") ~= nil end)
	t.type("ZZZ")
	t.eq(t.ui().matches, 0)
	t.key("Esc")
	t.key("Esc")
	t.ok(t.ui() == nil, "Esc clears the filter, then closes")
end

function T.menu_bool_toggle_writes_only_that_key(t)
	qed.fs.write(t.config_path(), '{"tab_width": 2}')
	open_menu(t)
	select(t, "line_wrap", "line_wrap")
	t.key("Enter")
	t.wait(function() return value(t) == "false" end)
	local cfg = user_cfg(t)
	t.eq(cfg.line_wrap, false, "the toggled key is written")
	t.eq(cfg.tab_width, 2, "other keys are kept")
	t.eq(count(cfg), 2, "nothing else is written")
	t.eq(t.ui().mark, "git_modified", "the override is marked")
	t.eq(t.ui().selected, "line_wrap", "the selection stays")
	t.key("Enter")
	t.wait(function() return value(t) == "true" end)
	cfg = user_cfg(t)
	t.eq(cfg.line_wrap, nil, "toggling back to the default removes the key")
	t.eq(count(cfg), 1)
	t.ok(t.ui().mark == nil, "no longer marked")
	t.key("Esc")
	t.key("Esc")
end

function T.menu_number_validation(t)
	open_menu(t)
	select(t, "tab_width", "tab_width")
	t.key("Enter")
	t.wait(function() return t.ui().input ~= nil end)
	t.eq(t.ui().input, "tab_width: ", "an inline prompt")
	t.eq(t.ui().input_text, "4", "prefilled with the current value")
	t.key("Ctrl+a")
	t.type("abc\n")
	t.wait(function() return (t.message()) == "tab_width needs a whole number" end)
	t.ok(not qed.fs.exists(t.config_path()), "garbage writes nothing")
	t.ok(t.ui().input == nil, "the prompt is gone")
	t.key("Enter")
	t.key("Ctrl+a")
	t.type("1.5\n")
	t.wait(function() return (t.message()) == "tab_width needs a whole number" end)
	t.key("Enter")
	t.key("Ctrl+a")
	t.type("0\n")
	t.wait(function() return (t.message()) == "tab_width must be at least 1" end)
	t.ok(not qed.fs.exists(t.config_path()), "out of bounds writes nothing")
	t.key("Enter")
	t.key("Ctrl+a")
	t.type("8\n")
	t.wait(function() return value(t) == "8" end)
	t.eq(user_cfg(t).tab_width, 8, "a valid number is written as a number")
	t.eq((t.message()), "tab_width set to 8")
	t.key("Enter")
	t.key("Esc")
	t.ok(t.ui().input == nil, "Esc cancels the prompt")
	t.eq(user_cfg(t).tab_width, 8)
	t.key("Esc")
	t.key("Esc")
end

function T.menu_string_and_list_values(t)
	open_menu(t)
	select(t, "languages.python.lsp", "languages.python.lsp")
	t.key("Enter")
	t.key("Ctrl+a")
	t.type("pylsp\n")
	t.wait(function() return value(t) == "pylsp" end)
	t.eq(user_cfg(t).languages.python.lsp, "pylsp")
	select(t, "languages.python.patterns", "languages.python.patterns")
	t.key("Enter")
	t.eq(t.ui().input_text, '["*.py","*.pyw"]', "a list edits as JSON")
	t.key("Ctrl+a")
	t.type('"x"\n')
	t.wait(function() return (t.message()) == "languages.python.patterns needs a JSON list" end)
	t.key("Enter")
	t.key("Ctrl+a")
	t.type('["*.py"]\n')
	t.wait(function() return value(t) == '["*.py"]' end)
	local py = user_cfg(t).languages.python
	t.eq(#py.patterns, 1)
	t.eq(py.lsp, "pylsp", "the sibling key stays")
	t.key("Esc")
	t.key("Esc")
end

function T.menu_enum_picker(t)
	open_menu(t)
	select(t, "message_log_backdrop", "message_log_backdrop")
	t.key("Enter")
	t.wait(function() return t.ui().kind == "pick" end)
	t.eq(t.ui().matches, 3, "the schema choices")
	t.eq(t.ui().selected, "none", "the current value is highlighted")
	t.type("dim\n")
	t.wait(function() return t.ui().id == "settings" and value(t) == "dim" end)
	t.eq(user_cfg(t).message_log_backdrop, "dim")
	select(t, "markdown.backdrop", "markdown.backdrop")
	t.key("Enter")
	t.wait(function() return t.ui().kind == "pick" end)
	t.eq(t.ui().selected, "dim", "a plugin's choices")
	t.key("Esc")
	t.wait(function() return t.ui().id == "settings" end)
	t.eq(user_cfg(t).plugins, nil, "Esc picks nothing")
	t.key("Esc")
	t.key("Esc")
end

function T.menu_reset_removes_the_key(t)
	qed.fs.write(t.config_path(), '{"line_wrap": false, "tab_width": 2}')
	open_menu(t)
	select(t, "line_wrap", "line_wrap")
	t.eq(t.ui().mark, "git_modified", "an override is marked")
	t.eq(value(t), "false", "the user value shows")
	t.key("Ctrl+d")
	t.wait(function() return value(t) == "true" end)
	local cfg = user_cfg(t)
	t.eq(cfg.line_wrap, nil, "reset removes the key")
	t.eq(cfg.tab_width, 2, "other keys stay")
	t.ok(t.ui().mark == nil, "no longer marked")
	t.eq((t.message()), "line_wrap reset to true")
	t.key("Ctrl+d")
	t.eq((t.message()), "line_wrap is already the default")
	t.key("Esc")
	t.key("Esc")
end

function T.menu_live_update_keeps_selection(t)
	open_menu(t)
	select(t, "tab_width", "tab_width")
	qed.fs.write(t.config_path(), '{"tab_width": 3}')
	t.config({}, {hot = true})
	t.wait(function() return value(t) == "3" end)
	t.eq(t.ui().mark, "git_modified", "the new override is marked")
	t.eq(t.ui().selected, "tab_width", "the selection stays")
	t.key("Esc")
	t.key("Esc")
end

function T.menu_chord_capture(t)
	open_menu(t, 2)
	select(t, "Toggle Line Wrap", "Toggle Line Wrap")
	t.eq(t.ui().cells[2], "", "unbound by default")
	t.wait(function() return t.ui().info == "Toggle Line Wrap. Default: none. Scope: global" end)
	t.key("Enter")
	t.wait(function() return t.ui().input ~= nil end)
	t.eq(t.ui().input, "Press a chord for Toggle Line Wrap (Esc cancels)")
	t.key("Esc")
	t.ok(t.ui().input == nil, "Esc cancels the capture")
	t.ok(not qed.fs.exists(t.config_path()), "a cancelled capture writes nothing")
	t.key("Enter")
	t.key("Alt+w")
	t.wait(function() return t.ui().cells[2] == "Alt+w" end)
	local cfg = user_cfg(t)
	t.eq(cfg.keybinds["Toggle Line Wrap"], "Alt+w", "the chord is written under keybinds")
	t.eq(count(cfg), 1)
	t.eq(t.ui().mark, "git_modified")
	select(t, "Go to: Line", "Go to: Line Ctrl+g")
	t.key("Enter")
	t.key("Ctrl+e")
	t.wait(function() return t.ui().cells[2] == "Ctrl+e" end)
	t.eq(user_cfg(t).plugins["goto"].keybinds.Line, "Ctrl+e", "a plugin bind is written under its plugin")
	t.key("Ctrl+d")
	t.wait(function() return t.ui().cells[2] == "Ctrl+g" end)
	t.eq(user_cfg(t).plugins, nil, "reset restores the default bind")
	t.key("Esc")
	t.key("Esc")
end

function T.menu_chord_conflict(t)
	open_menu(t, 2)
	select(t, "Toggle Line Wrap", "Toggle Line Wrap")
	t.key("Enter")
	t.key("Ctrl+s")
	t.wait(function() return t.ui().kind == "confirm" end)
	t.eq(t.ui().labels[1], "Cancel")
	t.eq(t.ui().labels[2], "Replace")
	t.key("Enter")
	t.wait(function() return t.ui().id == "settings" end)
	t.ok(not qed.fs.exists(t.config_path()), "Cancel writes nothing")
	t.key("Enter")
	t.key("Ctrl+s")
	t.wait(function() return t.ui().kind == "confirm" end)
	t.key("Down")
	t.key("Enter")
	t.wait(function() return t.ui().id == "settings" and t.ui().cells[2] == "Ctrl+s" end)
	local kb = user_cfg(t).keybinds
	t.eq(kb["Toggle Line Wrap"], "Ctrl+s")
	t.eq(kb.Save, "", "Replace unbinds the other command")
	t.eq((t.message()), "Toggle Line Wrap set to Ctrl+s, Save unbound")
	t.key("Enter")
	t.type("x")
	t.wait(function() return (t.message()) == "Toggle Line Wrap: a single key binds only in a pane" end)
	t.key("Esc")
	t.key("Esc")
end

local function screen_has(t, text)
	for y = 0, 23 do
		if t.screen(y):find(text, 1, true) then
			return true
		end
	end
	return false
end

function T.info_strip_wraps(t)
	local words = {}
	for i = 1, 60 do
		words[i] = "word" .. i
	end
	local v = qed.ui.open{place = "full", list = {items = {"a"}}, info = table.concat(words, " ")}
	t.ok(v, "the pane opens")
	t.ok(screen_has(t, "word1 word2") and screen_has(t, "word60"), "a long info wraps, never truncated")
	v:info("short info")
	t.ok(screen_has(t, "short info") and not screen_has(t, "word60"), "v:info replaces it")
	v:close()
end

function T.config_set_and_unset(t)
	t.ok(qed.config_set({"plugins", "x", "list"}, {}))
	t.ok(qed.config_set("tab_width", 3))
	local text = qed.fs.read(t.config_path())
	t.ok(text:find('"list": %[%]') ~= nil, "an empty table is written as a list")
	t.ok(qed.config_unset({"plugins", "x", "list"}))
	local cfg = user_cfg(t)
	t.eq(cfg.plugins, nil, "empty parents go with the key")
	t.eq(cfg.tab_width, 3)
	qed.fs.write(t.config_path(), "{broken")
	local ok, err = qed.config_set("tab_width", 4)
	t.ok(not ok and err:find("not valid JSON") ~= nil, "a broken file is never overwritten")
	t.eq(qed.fs.read(t.config_path()), "{broken")
	qed.fs.remove(t.config_path())
end

function T.open_defaults_is_an_unsaved_scratch(t)
	qed.run("Settings: Open Defaults")
	local b = qed.buf.current()
	t.eq(b:text(), qed.config_defaults(), "the embedded defaults")
	t.eq(b:path(), "", "no file behind it")
	t.eq(b:language(), "json")
	t.ok(not b:modified(), "clean")
	local ok, err = qed.save(b)
	t.ok(not ok and err == "no file name", "it cannot be saved over a file")
	qed.close(b)
end

return T
