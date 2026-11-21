local INDENT = {"Auto-detect", "Tabs", "Spaces:4", "Spaces:3", "Spaces:2", "Spaces:1"}

local function has_buf(ctx)
	return ctx.buf ~= nil
end

local function set_theme()
	local original = qed.theme.current()
	local name, busy = qed.pick{
		items = qed.theme.list(),
		initial = original,
		on_change = function(n) qed.theme.set(n) end,
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
	local name = qed.pick{items = qed.languages(), initial = qed.buf.language(ctx.buf)}
	if name and qed.buf.valid(ctx.buf) and qed.buf.set_language(ctx.buf, name) then
		qed.message("Language set to " .. name)
	end
end

local function change_indent(ctx)
	local b = ctx.buf
	local choice = qed.pick{items = INDENT}
	if not choice or not qed.buf.valid(b) then
		return
	end
	if choice == "Auto-detect" then
		qed.buf.set_indent(b, "auto")
	elseif choice == "Tabs" then
		qed.buf.set_indent(b, "tabs")
	else
		qed.buf.set_indent(b, "spaces", tonumber(choice:match("%d+")))
	end
	local style, width = qed.buf.indent(b)
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
		qed.meta{description = "Theme, language, indentation and config files"}
		qed.command{name = "Theme", welcome = true, run = set_theme}
		qed.command{name = "Open Config", welcome = true, run = open_config}
		qed.command{name = "Open Defaults", welcome = true, run = open_defaults}
		qed.command{name = "Language", when = has_buf, run = set_language}
		qed.command{name = "Indentation", when = has_buf, run = change_indent}
	end,
}
