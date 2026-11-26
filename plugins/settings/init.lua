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
		on = {change = function(_, name) qed.theme.set(name) end},
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
	local buffer = ctx.buf
	local choice = qed.pick{items = INDENT}
	if not choice or not buffer:valid() then
		return
	end
	if choice == "Auto-detect" then
		buffer:set_indent("auto")
	elseif choice == "Tabs" then
		buffer:set_indent("tabs")
	else
		buffer:set_indent("spaces", tonumber(choice:match("%d+")))
	end
	local style, width = buffer:indent()
	qed.message("Indentation set to " .. (style == "tabs" and "Tabs" or ("Spaces:" .. width)))
end

local function open_json(path)
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
	local buffer, err = qed.open(path)
	if not buffer then
		qed.message(err, "error")
	end
end

return {
	setup = function()
		qed.meta{description = "Settings menu, theme, language, indentation and config files"}
		menu.setup()
		qed.command{id = "theme", name = "Theme", welcome = true, run = set_theme}
		qed.command{id = "open_config_json", name = "Open Config JSON", welcome = true, run = function() open_json(qed.config_path()) end}
		qed.command{id = "open_keybinds_json", name = "Open Keybinds JSON", welcome = true, run = function() open_json(qed.keybinds_path()) end}
		qed.command{id = "language", name = "Language", when = has_buf, run = set_language}
		qed.command{id = "indentation", name = "Indentation", when = has_buf, run = change_indent}
	end,
}
