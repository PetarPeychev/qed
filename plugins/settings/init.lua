local menu = require("menu")

local INDENT = {"Auto-detect", "Tabs", "Spaces:4", "Spaces:3", "Spaces:2", "Spaces:1"}

local function has_buf(ctx)
	return ctx.buf ~= nil
end

local function set_theme()
	local original = qed.theme.current()
	local name, busy = qed.pick{
		items = qed.theme.list(),
		selected = original,
		on = {change = function(_, n) qed.theme.set(n) end},
	}
	if busy then
		return
	end
	if not name then
		qed.theme.set(qed.opt("theme"))
		return
	end
	local ok, err = qed.theme.set(name, {persist = true})
	if not ok then
		qed.message(err, "error")
		return
	end
	qed.message("Theme set to " .. name)
end

local function set_language(ctx)
	local name = qed.pick{items = qed.languages(), selected = ctx.buf:language()}
	if name and ctx.buf:valid() and name ~= ctx.buf:language() and ctx.buf:set_language(name) then
		qed.message("Language set to " .. name)
	end
end

local function change_indent(ctx)
	local b = ctx.buf
	local choice = qed.pick{items = INDENT}
	if not choice or not b:valid() then
		return
	end
	if choice == "Auto-detect" then
		b:set_indent("auto")
	elseif choice == "Tabs" then
		b:set_indent("tabs")
	else
		b:set_indent("spaces", tonumber(choice:match("%d+")))
	end
	local style, width = b:indent()
	qed.message("Indentation set to " .. (style == "tabs" and "Tabs" or ("Spaces:" .. width)))
end

local function open_config()
	local path = qed.config_path()
	if path == "" then
		qed.message("No config directory", "error")
		return
	end
	if not qed.fs.exists(path) then
		local ok, err = qed.fs.write(path, "{}\n", {exclusive = true})
		if not ok and err ~= "exists" then
			qed.message("Cannot create " .. path .. ": " .. tostring(err), "error")
			return
		end
	end
	local b, err = qed.open(path)
	if not b then
		qed.message(err, "error")
	end
end

local function open_defaults()
	qed.new_buf{text = qed.config_defaults(), language = "json"}
end

return {
	setup = function()
		qed.meta{description = "Settings menu, theme, language, indentation and config files"}
		menu.setup()
		qed.command{name = "Theme", welcome = true, run = set_theme}
		qed.command{name = "Open Config", welcome = true, run = open_config}
		qed.command{name = "Open Defaults", welcome = true, run = open_defaults}
		qed.command{name = "Language", when = has_buf, run = set_language}
		qed.command{name = "Indentation", when = has_buf, run = change_indent}
	end,
}
