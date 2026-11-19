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
	local h = qed.on("theme_changed", function() fired = fired + 1 end)
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
	t.eq(qed.buf.language(b), "text")
	qed.run("Settings: Language")
	local ui = t.ui()
	t.ok(ui and ui.kind == "pick", "Set Language opens a picker")
	t.eq(ui.matches, #qed.languages(), "every language is listed")
	t.type("python")
	t.eq(t.ui().selected, "python")
	t.key("Enter")
	t.eq(qed.buf.language(b), "python", "Enter sets the buffer language")
	expect_message(t, "Language set to python")
end

function T.language_same_is_silent(t)
	local b = t.open("a.py", "x = 1")
	qed.run("Settings: Language")
	t.type("python")
	t.key("Enter")
	t.eq(qed.buf.language(b), "python")
	t.eq((t.message()), "", "picking the current language shows no message")
end

function T.language_esc_keeps(t)
	local b = t.open("a.txt", "x")
	qed.run("Settings: Language")
	t.type("python")
	t.key("Esc")
	t.ok(t.ui() == nil, "Esc closes")
	t.eq(qed.buf.language(b), "text", "Esc leaves the language alone")
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
	t.eq((qed.buf.indent(b)), "tabs")
	expect_message(t, "Indentation set to Tabs")

	qed.run("Settings: Indentation")
	t.type("spaces:2")
	t.key("Enter")
	local style, width = qed.buf.indent(b)
	t.eq(style, "spaces")
	t.eq(width, 2)
	expect_message(t, "Indentation set to Spaces:2")
end

function T.indent_auto_detect(t)
	local b = t.open("a.txt", "a\n\tb")
	qed.buf.set_indent(b, "spaces", 4)
	qed.run("Settings: Indentation")
	t.key("Enter")
	t.eq((qed.buf.indent(b)), "tabs", "auto-detect reads the content")
	expect_message(t, "Indentation set to Tabs")
end

function T.indent_esc_keeps(t)
	local b = t.open("a.txt", "x")
	local style, width = qed.buf.indent(b)
	qed.run("Settings: Indentation")
	t.key("Down")
	t.key("Esc")
	local s2, w2 = qed.buf.indent(b)
	t.eq(s2, style)
	t.eq(w2, width)
end

return T
