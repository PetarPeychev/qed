local tests = {}

local function index_of(list, value)
	for i, view in ipairs(list) do
		if view == value then
			return i
		end
	end
end

local function expect_message(test, text)
	local msg, level, source = test.message()
	test.eq(msg, text, "message")
	test.eq(level, "info", "message level")
	test.eq(source, "Settings", "message source")
end

function tests.theme_opens_on_current(test)
	local current = qed.theme.current()
	qed.run("Settings: Theme")
	local ui = test.ui()
	test.ok(ui and ui.kind == "pick", "Set Theme opens a picker")
	test.eq(ui.selected, current, "the current theme is highlighted")
	test.eq(ui.matches, #qed.theme.list(), "every theme is listed")
	test.key("Esc")
end

function tests.theme_preview_and_esc_revert(test)
	local names = qed.theme.list()
	local original = qed.theme.current()
	local i = index_of(names, original)
	local step = i < #names and "Down" or "Up"
	local next_name = names[i < #names and i + 1 or i - 1]
	qed.run("Settings: Theme")
	test.key(step)
	test.eq(qed.theme.current(), next_name, "moving previews the highlighted theme")
	test.eq(qed.opt("theme"), original, "a preview does not change the configured theme")
	test.type("solarized-light")
	test.eq(qed.theme.current(), "solarized-light", "filtering previews the top match")
	test.key("Esc")
	test.ok(test.ui() == nil, "Esc closes the picker")
	test.eq(qed.theme.current(), original, "Esc reverts the preview")
	test.ok(not qed.fs.exists(test.config_path()), "Esc writes no config")
end

function tests.theme_enter_persists_only_the_theme_key(test)
	local original = qed.theme.current()
	qed.fs.write(test.config_path(), '{"tab_width": 2}')
	local fired = 0
	local handler = qed:on("theme_changed", function() fired = fired + 1 end)
	qed.run("Settings: Theme")
	test.type("nord")
	test.pump(20)
	test.eq(fired, 0, "previews fire no theme_changed")
	test.key("Enter")
	test.wait(function() return fired == 1 end)
	handler:off()
	test.ok(test.ui() == nil, "Enter closes the picker")
	test.eq(qed.theme.current(), "nord")
	test.eq(qed.opt("theme"), "nord", "Enter makes it the configured theme")
	expect_message(test, "Theme set to nord")
	local cfg = qed.json.decode(qed.fs.read(test.config_path()))
	test.eq(cfg.theme, "nord", "the theme key is written")
	test.eq(cfg.tab_width, 2, "other keys are kept")
	qed.theme.set(original, {persist = true})
end

function tests.theme_typing_previews(test)
	local original = qed.theme.current()
	qed.run("Settings: Theme")
	test.type("dracula")
	test.eq(qed.theme.current(), "dracula", "typing previews")
	test.key("Backspace")
	test.key("Esc")
	test.eq(qed.theme.current(), original, "Esc after edits still reverts")
end

function tests.language_set(test)
	local buffer = test.open("a.txt", "x = 1")
	test.eq(buffer:language(), "text")
	qed.run("Settings: Language")
	local ui = test.ui()
	test.ok(ui and ui.kind == "pick", "Set Language opens a picker")
	test.eq(ui.matches, #qed.languages(), "every language is listed")
	test.type("python")
	test.eq(test.ui().selected, "python")
	test.key("Enter")
	test.eq(buffer:language(), "python", "Enter sets the buffer language")
	expect_message(test, "Language set to python")
end

function tests.language_same_is_silent(test)
	local buffer = test.open("a.py", "x = 1")
	qed.run("Settings: Language")
	test.eq(test.ui().selected, "python", "the current language is preselected")
	test.type("python")
	test.key("Enter")
	test.eq(buffer:language(), "python")
	test.eq((test.message()), "", "picking the current language shows no message")
end

function tests.language_esc_keeps(test)
	local buffer = test.open("a.txt", "x")
	qed.run("Settings: Language")
	test.type("python")
	test.key("Esc")
	test.ok(test.ui() == nil, "Esc closes")
	test.eq(buffer:language(), "text", "Esc leaves the language alone")
end

function tests.indent_options(test)
	local buffer = test.open("a.txt", "x")
	qed.run("Settings: Indentation")
	local ui = test.ui()
	test.ok(ui and ui.kind == "pick", "Change Indentation opens a picker")
	test.eq(ui.matches, 6, "six options")
	test.eq(ui.selected, "Auto-detect", "the first option is highlighted")
	test.type("tabs")
	test.key("Enter")
	test.eq((buffer:indent()), "tabs")
	expect_message(test, "Indentation set to Tabs")

	qed.run("Settings: Indentation")
	test.type("spaces:2")
	test.key("Enter")
	local style, width = buffer:indent()
	test.eq(style, "spaces")
	test.eq(width, 2)
	expect_message(test, "Indentation set to Spaces:2")
end

function tests.indent_auto_detect(test)
	local buffer = test.open("a.txt", "a\n\tb")
	buffer:set_indent("spaces", 4)
	qed.run("Settings: Indentation")
	test.key("Enter")
	test.eq((buffer:indent()), "tabs", "auto-detect reads the content")
	expect_message(test, "Indentation set to Tabs")
end

function tests.indent_esc_keeps(test)
	local buffer = test.open("a.txt", "x")
	local style, width = buffer:indent()
	qed.run("Settings: Indentation")
	test.key("Down")
	test.key("Esc")
	local s2, w2 = buffer:indent()
	test.eq(s2, style)
	test.eq(w2, width)
end

function tests.open_config_creates_and_opens(test)
	local path = test.config_path()
	test.ok(not qed.fs.exists(path), "no config yet")
	qed.run("Settings: Open Config")
	test.eq(qed.fs.read(path), "{}\n", "the file is created")
	local buffer = qed.buf.current()
	test.eq(buffer:path(), path, "it opens in the editor")
	test.eq(buffer:language(), "json")
	qed.close(buffer)
	qed.fs.write(path, '{"tab_width": 2}')
	qed.run("Settings: Open Config")
	test.eq(qed.buf.current():text(), '{"tab_width": 2}', "an existing file is not overwritten")
	qed.close(qed.buf.current())
	qed.fs.remove(path)
end

local function user_cfg(test)
	if not qed.fs.exists(test.config_path()) then
		return {}
	end
	return qed.json.decode(qed.fs.read(test.config_path()))
end

local function count(tbl)
	local total = 0
	for _ in pairs(tbl) do
		total = total + 1
	end
	return total
end

local function screen_has(test, text)
	for screen_row = 0, 23 do
		if test.screen(screen_row):find(text, 1, true) then
			return true
		end
	end
	return false
end

local function settings_open(test)
	return screen_has(test, "─ Settings ─")
end

local function first_is(test, name)
	for screen_row = 0, 22 do
		local line = test.screen(screen_row)
		if line:find("│ Key ", 1, true) or line:find("│ Command ", 1, true) then
			local row = test.screen(screen_row + 1)
			return (row:find("│ " .. name .. " ", 1, true) or row:find("│▎" .. name .. " ", 1, true)) ~= nil
		end
	end
	return false
end

local function row_line(test, name)
	local escaped = name:gsub("%p", "%%%0")
	for screen_row = 0, 23 do
		local line = test.screen(screen_row)
		local before, value = line:match("^(.-)" .. escaped .. " +(.-)%s*\226\148[\130\131]%s*$")
		if before and (before:sub(-4) == "│ " or before:sub(-6) == "│▎") then
			return line, (value:gsub("%s*\226\148\131$", "")), before:sub(-6) == "│▎"
		end
	end
end

local selected_name

local function value(test)
	local _, text = row_line(test, selected_name)
	return text
end

local function marked(test)
	local _, _, mark = row_line(test, selected_name)
	return mark
end

local function open_menu(test, tab)
	qed.run("Settings: Open")
	test.wait(function() return settings_open(test) end)
	test.ok(screen_has(test, "Settings"), "the settings pane opens")
	if tab == 2 then
		test.key("Tab")
		test.wait(function() return screen_has(test, "Command") and screen_has(test, "Scope: ") end)
	end
end

local function select(test, filter)
	test.key("Ctrl+a")
	test.type(filter)
	selected_name = filter
	test.ok(first_is(test, filter), "filtering selects " .. filter)
end

function tests.menu_lists_core_and_plugin_options(test)
	open_menu(test)
	test.ok(screen_has(test, "Key") and screen_has(test, "Value"), "it opens on Options with Key and Value columns")
	select(test, "line_wrap")
	test.eq(value(test), "true", "the current value")
	test.ok(screen_has(test, "Soft wrap long lines in new buffers. Default: true"), "the info line")
	test.ok(not marked(test), "a default is not marked")
	select(test, "lsp.enabled")
	test.ok(screen_has(test, "Start language servers. Default: true"))
	select(test, "languages.python.lsp")
	test.eq(value(test), "pyright-langserver --stdio")
	select(test, "search.min_query")
	test.eq(value(test), "2")
	test.ok(screen_has(test, "Characters typed before a search runs. Default: 2"))
	select(test, "search.enabled")
	test.eq(value(test), "true")
	select(test, "format.commands.python")
	test.ok(screen_has(test, "Formatter per language: a stdin to stdout command, {file} is the path."))
	test.type("ZZZ")
	test.ok(not first_is(test, "ZZZ") and not screen_has(test, "line_wrap"), "nothing matches")
	test.key("Esc")
	test.ok(settings_open(test), "Esc clears the filter")
	test.key("Esc")
	test.ok(not settings_open(test), "then closes")
end

function tests.menu_bool_toggle_writes_only_that_key(test)
	qed.fs.write(test.config_path(), '{"tab_width": 2}')
	open_menu(test)
	select(test, "line_wrap")
	test.key("Enter")
	test.wait(function() return value(test) == "false" end)
	local cfg = user_cfg(test)
	test.eq(cfg.line_wrap, false, "the toggled key is written")
	test.eq(cfg.tab_width, 2, "other keys are kept")
	test.eq(count(cfg), 2, "nothing else is written")
	test.ok(marked(test), "the override is marked")
	test.ok(first_is(test, "line_wrap"), "the selection stays")
	test.key("Enter")
	test.wait(function() return value(test) == "true" end)
	cfg = user_cfg(test)
	test.eq(cfg.line_wrap, nil, "toggling back to the default removes the key")
	test.eq(count(cfg), 1)
	test.ok(not marked(test), "no longer marked")
	test.key("Esc")
	test.key("Esc")
end

function tests.menu_number_validation(test)
	open_menu(test)
	select(test, "tab_width")
	test.key("Enter")
	test.wait(function() return screen_has(test, "tab_width: 4") end)
	test.key("Ctrl+a")
	test.type("abc\n")
	test.wait(function() return (test.message()) == "tab_width needs a whole number" end)
	test.ok(not qed.fs.exists(test.config_path()), "garbage writes nothing")
	test.ok(not screen_has(test, "tab_width: "), "the prompt is gone")
	test.key("Enter")
	test.key("Ctrl+a")
	test.type("1.5\n")
	test.wait(function() return (test.message()) == "tab_width needs a whole number" end)
	test.key("Enter")
	test.key("Ctrl+a")
	test.type("0\n")
	test.wait(function() return (test.message()) == "tab_width must be at least 1" end)
	test.ok(not qed.fs.exists(test.config_path()), "out of bounds writes nothing")
	test.key("Enter")
	test.key("Ctrl+a")
	test.type("8\n")
	test.wait(function() return value(test) == "8" end)
	test.eq(user_cfg(test).tab_width, 8, "a valid number is written as a number")
	test.eq((test.message()), "tab_width set to 8")
	test.key("Enter")
	test.key("Esc")
	test.ok(not screen_has(test, "tab_width: "), "Esc cancels the prompt")
	test.eq(user_cfg(test).tab_width, 8)
	test.key("Esc")
	test.key("Esc")
end

function tests.menu_string_and_list_values(test)
	open_menu(test)
	select(test, "languages.python.lsp")
	test.key("Enter")
	test.key("Ctrl+a")
	test.type("pylsp\n")
	test.wait(function() return value(test) == "pylsp" end)
	test.eq(user_cfg(test).languages.python.lsp, "pylsp")
	select(test, "languages.python.patterns")
	test.key("Enter")
	test.ok(screen_has(test, 'languages.python.patterns: ["*.py","*.pyw"]'), "a list edits as JSON")
	test.key("Ctrl+a")
	test.type('"x"\n')
	test.wait(function() return (test.message()) == "languages.python.patterns needs a JSON list" end)
	test.key("Enter")
	test.key("Ctrl+a")
	test.type('["*.py"]\n')
	test.wait(function() return value(test) == '["*.py"]' end)
	local py = user_cfg(test).languages.python
	test.eq(#py.patterns, 1)
	test.eq(py.lsp, "pylsp", "the sibling key stays")
	test.key("Esc")
	test.key("Esc")
end

function tests.menu_enum_picker(test)
	open_menu(test)
	select(test, "image_protocol")
	test.key("Enter")
	test.wait(function() return test.ui() and test.ui().kind == "pick" end)
	test.eq(test.ui().matches, 3, "the schema choices")
	test.eq(test.ui().selected, "auto", "the current value is highlighted")
	test.type("none\n")
	test.wait(function() return test.ui() == nil and value(test) == "none" end)
	test.eq(user_cfg(test).image_protocol, "none")
	select(test, "image_protocol")
	test.key("Enter")
	test.wait(function() return test.ui() and test.ui().kind == "pick" end)
	test.key("Esc")
	test.wait(function() return test.ui() == nil end)
	test.eq(user_cfg(test).image_protocol, "none", "Esc picks nothing")
	test.key("Esc")
	test.key("Esc")
end

function tests.menu_reset_removes_the_key(test)
	qed.fs.write(test.config_path(), '{"line_wrap": false, "tab_width": 2}')
	open_menu(test)
	select(test, "line_wrap")
	test.ok(marked(test), "an override is marked")
	test.eq(value(test), "false", "the user value shows")
	test.key("Ctrl+d")
	test.wait(function() return value(test) == "true" end)
	local cfg = user_cfg(test)
	test.eq(cfg.line_wrap, nil, "reset removes the key")
	test.eq(cfg.tab_width, 2, "other keys stay")
	test.ok(not marked(test), "no longer marked")
	test.eq((test.message()), "line_wrap reset to true")
	test.key("Ctrl+d")
	test.eq((test.message()), "line_wrap is already the default")
	test.key("Esc")
	test.key("Esc")
end

function tests.menu_live_update_keeps_selection(test)
	open_menu(test)
	select(test, "tab_width")
	qed.fs.write(test.config_path(), '{"tab_width": 3}')
	test.config({}, {hot = true})
	test.wait(function() return value(test) == "3" end)
	test.ok(marked(test), "the new override is marked")
	test.ok(first_is(test, "tab_width"), "the selection stays")
	test.key("Esc")
	test.key("Esc")
end

function tests.menu_chord_capture(test)
	open_menu(test, 2)
	select(test, "Toggle Line Wrap")
	test.eq(value(test), "", "unbound by default")
	test.ok(screen_has(test, "Toggle Line Wrap. Default: none. Scope: global"))
	test.key("Enter")
	test.wait(function() return screen_has(test, "Press a chord for Toggle Line Wrap (Esc cancels)") end)
	test.key("Esc")
	test.ok(not screen_has(test, "Press a chord"), "Esc cancels the capture")
	test.ok(settings_open(test), "the menu stays")
	test.ok(not qed.fs.exists(test.config_path()), "a cancelled capture writes nothing")
	test.key("Enter")
	test.key("Alt+w")
	test.wait(function() return value(test) == "Alt+w" end)
	local cfg = user_cfg(test)
	test.eq(cfg.keybinds["Toggle Line Wrap"], "Alt+w", "the chord is written under keybinds")
	test.eq(count(cfg), 1)
	test.ok(marked(test))
	select(test, "Go to: Line")
	test.key("Enter")
	test.key("Ctrl+e")
	test.wait(function() return value(test) == "Ctrl+e" end)
	test.eq(user_cfg(test).plugins["goto"].keybinds.Line, "Ctrl+e", "a plugin bind is written under its plugin")
	test.key("Ctrl+d")
	test.wait(function() return value(test) == "Ctrl+g" end)
	test.eq(user_cfg(test).plugins, nil, "reset restores the default bind")
	test.key("Esc")
	test.key("Esc")
end

function tests.menu_chord_conflict(test)
	open_menu(test, 2)
	select(test, "Toggle Line Wrap")
	test.key("Enter")
	test.key("Ctrl+s")
	test.wait(function() return test.ui() and test.ui().kind == "confirm" end)
	test.eq(test.ui().labels[1], "Cancel")
	test.eq(test.ui().labels[2], "Replace")
	test.key("Enter")
	test.wait(function() return test.ui() == nil end)
	test.ok(not qed.fs.exists(test.config_path()), "Cancel writes nothing")
	test.key("Enter")
	test.key("Ctrl+s")
	test.wait(function() return test.ui() and test.ui().kind == "confirm" end)
	test.key("Down")
	test.key("Enter")
	test.wait(function() return test.ui() == nil and value(test) == "Ctrl+s" end)
	local kb = user_cfg(test).keybinds
	test.eq(kb["Toggle Line Wrap"], "Ctrl+s")
	test.eq(kb.Save, "", "Replace unbinds the other command")
	test.eq((test.message()), "Toggle Line Wrap set to Ctrl+s, Save unbound")
	test.key("Enter")
	test.type("x")
	test.wait(function() return (test.message()) == "Toggle Line Wrap: a single key binds only in a pane" end)
	test.key("Esc")
	test.key("Esc")
end

function tests.info_strip_wraps(test)
	local words = {}
	for i = 1, 60 do
		words[i] = "word" .. i
	end
	local view = qed.ui.open{place = "full", list = {items = {"a"}}, info = table.concat(words, " ")}
	test.ok(view, "the pane opens")
	test.ok(screen_has(test, "word1 word2") and screen_has(test, "word60"), "a long info wraps, never truncated")
	view:info("short info")
	test.ok(screen_has(test, "short info") and not screen_has(test, "word60"), "v:info replaces it")
	view:close()
end

function tests.config_set_and_unset(test)
	test.ok(qed.config_set({"plugins", "x", "list"}, {}))
	test.ok(qed.config_set("tab_width", 3))
	local text = qed.fs.read(test.config_path())
	test.ok(text:find('"list": %[%]') ~= nil, "an empty table is written as a list")
	test.ok(qed.config_unset({"plugins", "x", "list"}))
	local cfg = user_cfg(test)
	test.eq(cfg.plugins, nil, "empty parents go with the key")
	test.eq(cfg.tab_width, 3)
	qed.fs.write(test.config_path(), "{broken")
	local ok, err = qed.config_set("tab_width", 4)
	test.ok(not ok and err:find("not valid JSON") ~= nil, "a broken file is never overwritten")
	test.eq(qed.fs.read(test.config_path()), "{broken")
	qed.fs.remove(test.config_path())
end

function tests.open_defaults_is_an_unsaved_scratch(test)
	qed.run("Settings: Open Defaults")
	local buffer = qed.buf.current()
	test.eq(buffer:text(), qed.config_defaults(), "the embedded defaults")
	test.eq(buffer:path(), "", "no file behind it")
	test.eq(buffer:language(), "json")
	test.ok(not buffer:modified(), "clean")
	local ok, err = qed.save(buffer)
	test.ok(not ok and err == "no file name", "it cannot be saved over a file")
	qed.close(buffer)
end

return tests
