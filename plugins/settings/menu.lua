local menu = {}

local ui = qed.ui

local TABS = {"Options", "Keybinds"}
local COLUMNS = {{"Key", "Value"}, {"Command", "Chord"}}
local NAME_MAX = {48, 60}

local opts
local schema
local view
local tab = 1
local rows = {}

local function split(dotted_name)
	local out = {}
	for part in dotted_name:gmatch("[^.]+") do
		out[#out + 1] = part
	end
	return out
end

local function lookup(node, path)
	for _, segment in ipairs(path) do
		if type(node) ~= "table" then
			return nil
		end
		node = node[segment]
	end
	return node
end

local function is_object(setting)
	return type(setting) == "table" and next(setting) ~= nil and #setting == 0
end

local function user_config()
	local path = qed.config_path()
	if path == "" or not qed.fs.exists(path) then
		return {}
	end
	local text = qed.fs.read(path) or ""
	if text:match("^%s*$") then
		return {}
	end
	local cfg = qed.json.decode(text)
	return type(cfg) == "table" and cfg or {}
end

local function schema_entry(dotted)
	if schema[dotted] then
		return schema[dotted]
	end
	local parts = split(dotted)
	for pattern, entry in pairs(schema) do
		local ps = split(pattern)
		local ok = #ps == #parts
		for i = 1, ok and #ps or 0 do
			ok = ok and (ps[i] == "*" or ps[i] == parts[i])
		end
		if ok then
			return entry
		end
	end
	return {}
end

local function kind_of(setting, choices)
	if choices then
		return "choice"
	elseif type(setting) == "boolean" then
		return "bool"
	elseif math.type(setting) == "integer" then
		return "int"
	elseif type(setting) == "number" then
		return "number"
	elseif type(setting) == "table" then
		return "list"
	end
	return "string"
end

local function show(setting)
	if setting == nil then
		return ""
	elseif type(setting) == "table" then
		return qed.json.encode(setting)
	elseif setting == "" then
		return '""'
	end
	return (tostring(setting):gsub("\n", "\\n"))
end

local function same(left, right)
	if type(left) == "table" and type(right) == "table" then
		return qed.json.encode(left) == qed.json.encode(right)
	end
	return left == right
end

local function option_row(out, user, source, name, path, default, info)
	local row = {
		key = "opt\t" .. table.concat(path, "\t"),
		source = source,
		name = source == "core" and name or source .. "." .. name,
		path = path,
		default = default,
		description = info.description or "",
		choices = info.choices,
		min = info.min,
	}
	local set = lookup(user, path)
	row.user = set ~= nil
	row.value = set
	if set == nil then
		row.value = default
	end
	local basis = default
	if basis == nil then
		basis = row.value
	end
	row.kind = kind_of(basis, row.choices)
	out[#out + 1] = row
end

local function option_leaves(out, user, source, prefix, path, def, maps, info_of)
	local keys = {}
	for segment in pairs(def) do
		keys[#keys + 1] = segment
	end
	local usr = lookup(user, path)
	if not is_object(usr) then
		usr = {}
	elseif maps and prefix ~= "" then
		for segment in pairs(usr) do
			if def[segment] == nil then
				keys[#keys + 1] = segment
			end
		end
	end
	local function nested(segment)
		return is_object(def[segment]) or is_object(usr[segment])
	end
	table.sort(keys, function(left, right)
		if nested(left) ~= nested(right) then
			return nested(right)
		end
		return left < right
	end)
	for _, segment in ipairs(keys) do
		local child_path = {table.unpack(path)}
		child_path[#child_path + 1] = segment
		local name = prefix == "" and segment or prefix .. "." .. segment
		local setting = def[segment]
		if is_object(setting) or (setting == nil and is_object(usr[segment])) then
			option_leaves(out, user, source, name, child_path, setting or {}, maps, info_of)
		else
			option_row(out, user, source, name, child_path, setting, info_of(name))
		end
	end
end

local function option_rows(user)
	local out = {}
	local defaults = qed.json.decode(qed.config_defaults())
	local core = {}
	for segment, setting in pairs(defaults) do
		if segment ~= "keybinds" and segment ~= "plugins" and segment ~= "lsp" then
			core[segment] = setting
		end
	end
	option_leaves(out, user, "core", "", {}, core, false, function(name)
		local entry = schema_entry(name)
		if name == "theme" then
			entry = {description = entry.description, choices = qed.theme.list()}
		end
		return entry
	end)
	option_leaves(out, user, "lsp", "", {"lsp"}, defaults.lsp, false, function(name)
		return schema_entry("lsp." .. name)
	end)
	for _, plugin in ipairs(qed.plugins()) do
		local on = lookup(defaults, {"plugins", plugin.id, "enabled"})
		if on == nil then
			on = true
		end
		option_row(out, user, plugin.id, "enabled", {"plugins", plugin.id, "enabled"}, on, schema_entry("plugins.*.enabled"))
		local info = plugin.info or {}
		option_leaves(out, user, plugin.id, "", {"plugins", plugin.id}, plugin.options or {}, true, function(name)
			local i = info[name:match("^[^.]+")]
			return type(i) == "string" and {description = i} or i or {}
		end)
	end
	return out
end

local function keybind_rows(user)
	local out, groups = {}, {}
	for _, cmd in ipairs(qed.commands()) do
		if cmd.keybind then
			local source = cmd.owner or "core"
			local id = source .. "\t" .. cmd.keybind
			local row = groups[id]
			if not row then
				local path = cmd.owner and {"plugins", cmd.owner, "keybinds", cmd.keybind} or {"keybinds", cmd.keybind}
				local set = lookup(user, path)
				row = {
					key = "kb\t" .. id,
					source = source,
					name = cmd.owner and cmd.name or cmd.keybind,
					scope = cmd.scope,
					path = path,
					default = cmd.key,
					user = set ~= nil,
					value = set == nil and cmd.key or set,
					scopes = {},
				}
				groups[id] = row
				out[#out + 1] = row
			end
			row.scopes[cmd.scope] = true
		end
	end
	table.sort(out, function(left, right)
		if (left.source == "core") ~= (right.source == "core") then
			return left.source == "core"
		end
		if left.source ~= right.source then
			return left.source < right.source
		end
		return left.name < right.name
	end)
	return out
end

local function label_of(row)
	if tab == 1 then
		return row.name
	end
	local chord = type(row.value) == "string" and row.value or show(row.value)
	return chord == "" and row.name or row.name .. " " .. chord
end

local function value_text(row)
	if tab == 2 and type(row.value) == "string" then
		return row.value
	end
	return show(row.value)
end

local function record_of(row)
	return {key = row.key, label = label_of(row), name = row.name, value = value_text(row), user = row.user}
end

local function info_of(row)
	if not row then
		return ""
	end
	if tab == 1 then
		local text = row.description ~= "" and row.description .. ". " or ""
		return text .. "Default: " .. (row.default == nil and "none" or show(row.default))
	end
	local default = row.default ~= "" and row.default or "none"
	return ("%s. Default: %s. Scope: %s"):format(row.name, default, row.scope)
end

local function shortcut(name)
	for _, command in ipairs(qed.commands()) do
		if command.name == "Settings: " .. name then
			return command.shortcut
		end
	end
	return ""
end

local function highlighted()
	local state = ui.node("settings_rows"):state()
	return state and state.highlighted or nil
end

local function setting_row(record)
	return ui.row{
		on = {click = function()
			ui.node("settings_rows"):set_state{highlighted = record.key}
			menu.rebuild()
			return true
		end},
		ui.text{width = 1, fg = "git_modified", record.user and "▎" or " "},
		ui.text{width = view.name_width, record.name},
		ui.text{grow = 1, " ", record.value},
	}
end

local function tab_row()
	local chips = {}
	for index, title in ipairs(TABS) do
		local on = index == tab
		chips[#chips + 1] = ui.text{
			on = {click = function() menu.switch_tab(index) return true end},
			" ", {fg = on and "pane_prompt_foreground" or "pane_dim_foreground", bold = on, title}, " "}
	end
	chips[#chips + 1] = ui.text{grow = 1, fg = "pane_dim_foreground", "  ", shortcut("Next Tab"), " switches"}
	return ui.row{height = 1, table.unpack(chips)}
end

local function footer()
	local footer_state = view.footer
	if footer_state and footer_state.kind == "input" then
		return ui.row{height = 1,
			ui.text{fg = "pane_prompt_foreground", " ", footer_state.prompt},
			ui.editor{id = "settings_input", buffer = footer_state.buffer, height = 1, grow = 1, scope = {"settings_input", "editor"}},
		}
	elseif footer_state then
		return ui.text{id = "settings_chord", height = 1, fg = "pane_prompt_foreground", " ", footer_state.prompt,
			on = {key = function(args)
				menu.capture(args.chord)
				return true
			end}}
	end
	return ui.text{height = 1, fg = "pane_dim_foreground", " Enter edit  ", {fg = "pane_shortcut_foreground", shortcut("Reset")}, " reset"}
end

local function build()
	local columns = COLUMNS[tab]
	return ui.dismissable{on_dismiss = function() menu.dismiss() end,
		ui.box{float = "screen", anchor = "center", width = {"100%", max = opts.max_width}, height = "100%",
		margin = {x = 2, y = 1}, border = true, title = "Settings", bg = "pane_background", fg = "pane_foreground",
		ui.column{
			tab_row(),
			ui.row{height = 1,
				ui.text{fg = "pane_prompt_foreground", "> "},
				ui.editor{id = "settings_query", buffer = view.query, height = 1, grow = 1,
					scope = {"settings", "editor"}, placeholder = "type to filter"},
			},
			ui.scroll{id = "settings_scroll", grow = 1,
				header = ui.row{bold = true, ui.text{width = 1, " "}, ui.text{width = view.name_width, columns[1]}, ui.text{grow = 1, " ", columns[2]}},
				ui.virtual_column{id = "settings_rows", data = view.matches, item = setting_row,
					highlight_style = {bg = "pane_selection_background", fg = "pane_selection_foreground"}}},
			ui.row{ui.text{width = 1, " "}, ui.text{grow = 1, wrap = true, fg = "pane_dim_foreground", info_of(rows[highlighted() or ""])}},
			footer(),
		},
	}}
end

function menu.rebuild()
	if view then
		view.handle:update(build())
	end
end

local function highlight(key)
	if not (key and view.matches:get(key)) then
		local first = view.matches:at(1)
		key = first and first.key or false
	end
	ui.node("settings_rows"):set_state{highlighted = key}
end

local function load_rows()
	local user = user_config()
	local list = tab == 1 and option_rows(user) or keybind_rows(user)
	local by_key, width = {}, #COLUMNS[tab][1]
	for _, row in ipairs(list) do
		by_key[row.key] = row
		width = math.max(width, utf8.len(row.name) or #row.name)
	end
	return list, by_key, math.min(width, NAME_MAX[tab])
end

local function refresh(reorder)
	if not view then
		return
	end
	local list, by_key, width = load_rows()
	local same_rows = not reorder and view.records:count() == #list
	for index = 1, same_rows and #list or 0 do
		same_rows = view.records:at(index).key == list[index].key
		if not same_rows then
			break
		end
	end
	local keep = highlighted()
	if same_rows then
		for _, row in ipairs(list) do
			local old = rows[row.key]
			if value_text(old) ~= value_text(row) or old.user ~= row.user then
				view.records:set(row.key, {label = label_of(row), value = value_text(row), user = row.user})
			end
		end
	else
		view.records:clear()
		for _, row in ipairs(list) do
			view.records:append(record_of(row))
		end
		view.matches:set_query(view.query:text())
	end
	rows, view.name_width = by_key, width
	highlight(keep)
	menu.rebuild()
end

local function focus_query()
	view.footer = nil
	menu.rebuild()
	ui.node("settings_query"):focus()
end

local function prompt_input(row, text)
	local buffer = qed.buf.create{internal = true}
	buffer:set_text(text)
	buffer:set_cursor({row = 1, col = #text + 1})
	view.footer = {kind = "input", row = row, buffer = buffer, prompt = row.name .. ": "}
	menu.rebuild()
	ui.node("settings_input"):focus()
end

local function write(row, value)
	local ok, err
	if same(value, row.default) then
		ok, err = qed.config_unset(row.path)
	else
		ok, err = qed.config_set(row.path, value)
	end
	if not ok then
		qed.message(err, "error")
		return false
	end
	qed.message(row.name .. " set to " .. show(value))
	refresh()
	return true
end

local function parse(row, text)
	if row.kind == "string" then
		return text
	elseif row.kind == "list" then
		local setting = qed.json.decode(text)
		if type(setting) ~= "table" or is_object(setting) then
			return nil, row.name .. " needs a JSON list"
		end
		for _, entry in ipairs(setting) do
			if type(entry) ~= "string" then
				return nil, row.name .. " needs a JSON list of strings"
			end
		end
		return setting
	end
	local number = tonumber(text)
	if not number or (row.kind == "int" and math.type(number) ~= "integer") then
		return nil, row.name .. (row.kind == "int" and " needs a whole number" or " needs a number")
	end
	if row.min and number < row.min then
		return nil, ("%s must be at least %d"):format(row.name, row.min)
	end
	return number
end

local function normalize(chord)
	return chord:match("^Ctrl%+") and chord:lower():gsub("^ctrl", "Ctrl") or chord
end

local function conflict(row, chord)
	local want = normalize(chord)
	for _, cmd in ipairs(qed.commands()) do
		local mine = cmd.keybind and (cmd.owner or "core") == row.source and cmd.keybind == row.path[#row.path]
		if not mine and row.scopes[cmd.scope] and cmd.shortcut ~= "" and normalize(cmd.shortcut) == want then
			return cmd
		end
	end
end

local function bind(row, chord)
	if #chord == 1 and (row.scopes.global or row.scopes.editor or row.scopes.filetree) then
		qed.message(row.name .. ": a single key binds only in a pane", "error")
		return
	end
	if type(row.value) == "string" and normalize(row.value) == normalize(chord) then
		qed.message(row.name .. " is already " .. chord)
		return
	end
	local other = conflict(row, chord)
	if other then
		local choice = qed.confirm{question = chord .. " is bound to " .. other.name, choices = {"Cancel", "Replace"}}
		if choice ~= 2 then
			return
		end
		local path = other.owner and {"plugins", other.owner, "keybinds", other.keybind} or {"keybinds", other.keybind}
		local ok, err
		if other.keybind then
			ok, err = (other.key == "" and qed.config_unset or qed.config_set)(path, "")
		end
		if not ok then
			qed.message(err or (other.name .. " borrows its bind and cannot be unbound here"), "error")
			return
		end
	end
	if write(row, chord) and other then
		qed.message(("%s set to %s, %s unbound"):format(row.name, chord, other.name))
	end
end

local function edit_option(row)
	if row.kind == "bool" then
		write(row, not row.value)
	elseif row.kind == "choice" then
		local choice = qed.pick{items = row.choices, selected = type(row.value) == "string" and row.value or nil}
		if choice and choice ~= row.value then
			write(row, choice)
		end
	elseif type(row.value) == "string" and row.value:find("\n") then
		qed.message(row.name .. " spans lines: edit it in config.json", "error")
	else
		prompt_input(row, type(row.value) == "table" and qed.json.encode(row.value) or tostring(row.value))
	end
end

local function activate()
	local row = view and rows[highlighted() or ""]
	if not row then
		return
	end
	if tab == 1 then
		edit_option(row)
	else
		view.footer = {kind = "chord", row = row, prompt = "Press a chord for " .. row.name .. " (Esc cancels)"}
		menu.rebuild()
		ui.node("settings_chord"):focus()
	end
end

local function cancel_input()
	if view and view.footer then
		if view.footer.buffer then
			view.footer.buffer:close()
		end
		focus_query()
	end
end

local function submit()
	local footer_state = view and view.footer
	if not footer_state or footer_state.kind ~= "input" then
		return
	end
	local row, text = footer_state.row, footer_state.buffer:text()
	cancel_input()
	local value, err = parse(row, text)
	if err then
		qed.message(err, "error")
		return
	end
	if not same(value, row.value) then
		write(row, value)
	end
end

function menu.capture(chord)
	local footer_state = view and view.footer
	if not footer_state or not chord or chord == "" then
		return
	end
	cancel_input()
	if chord ~= "Esc" then
		qed.defer(0, function() bind(footer_state.row, chord) end)
	end
end

function menu.switch_tab(index)
	if not view then
		return
	end
	tab = index or (tab % #TABS + 1)
	cancel_input()
	refresh(true)
end

local function move(step)
	if not view then
		return
	end
	local matches = view.matches
	local count = matches:count()
	if count == 0 then
		return
	end
	local index = matches:index_of(highlighted() or "") or 0
	index = math.max(1, math.min(count, index + step))
	ui.node("settings_rows"):set_state{highlighted = matches:at(index).key}
	menu.rebuild()
end

function menu.dismiss()
	if not view then
		return
	end
	local closing = view
	view = nil
	closing.handle:unmount()
	closing.query:close()
end

local function close()
	if not view then
		return
	end
	if view.query:text() ~= "" then
		view.query:set_text("")
		return
	end
	menu.dismiss()
end

function menu.reset()
	local row = view and rows[highlighted() or ""]
	if not row then
		return
	end
	if not row.user then
		qed.message(row.name .. " is already the default")
		return
	end
	local ok, err = qed.config_unset(row.path)
	if not ok then
		qed.message(err, "error")
		return
	end
	qed.message(row.name .. " reset to " .. show(row.default))
	refresh()
end

function menu.open()
	if view then
		ui.node("settings_query"):focus()
		return
	end
	schema = schema or qed.json.decode(qed.config_schema())
	local list, by_key, width = load_rows()
	rows = by_key
	local records = qed.list.new{key = "key"}
	for _, row in ipairs(list) do
		records:append(record_of(row))
	end
	view = {records = records, matches = qed.fuzzy.list(records, {field = "label"}), query = qed.buf.create{internal = true}, name_width = width}
	view.handle = ui.mount("pane", build())
	view.query:on("change", function()
		if view then
			view.matches:set_query(view.query:text())
			highlight(nil)
			menu.rebuild()
		end
	end)
	highlight(nil)
	menu.rebuild()
	ui.node("settings_query"):focus()
end

function menu.setup()
	opts = qed.options({max_width = 120}, {max_width = "Max width of the settings pane"})
	qed:on("config_changed", function()
		opts = qed.config()
		refresh()
	end)
	for _, event in ipairs({"theme_changed", "plugin_loaded", "plugin_unloaded"}) do
		qed:on(event, function()
			refresh()
		end)
	end
	qed.command{name = "Open", welcome = true, run = menu.open}
	qed.command{name = "Reset", scope = "settings", key = "Ctrl+d", run = menu.reset}
	qed.command{name = "Edit", scope = "settings", key = "Enter", run = activate}
	qed.command{name = "Next", scope = "settings", key = "Down", run = function() move(1) end}
	qed.command{name = "Previous", scope = "settings", key = "Up", run = function() move(-1) end}
	qed.command{name = "Next Tab", scope = "settings", key = "Tab", run = function() menu.switch_tab() end}
	qed.command{name = "Close", scope = "settings", key = "Esc", run = close}
	qed.command{name = "Submit", scope = "settings_input", key = "Enter", run = submit}
	qed.command{name = "Cancel", scope = "settings_input", key = "Esc", run = cancel_input}
end

return menu
