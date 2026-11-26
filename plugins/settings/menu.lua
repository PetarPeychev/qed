local menu = {}

local ui = qed.ui

local TABS = {"Options", "Keybinds"}
local COLUMNS = {{"Key", "Value"}, {"Command", "Chord"}}
local NAME_MAX = {48, 60}
local TEXT_ROWS = 4
local INFO_DEFAULT_MAX = 60
local ENABLED = {type = "bool", default = true, description = "Load the plugin"}
-- core's scoped commands are named for their pane in the palette there; the Keybinds tab lists them all, so it says which
local CORE_SCOPES = {editor = "Editor", list = "List", list_range = "List"}

local view
local tab = 1
local rows = {}

local function keybinds_config()
	local path = qed.keybinds_path()
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

local function clip(text, max)
	if (utf8.len(text) or 0) > max then
		return text:sub(1, utf8.offset(text, max) - 1) .. "…"
	end
	return text
end

-- a message line holds one line: a multi-line value shows its first, clipped
local function brief(setting)
	if type(setting) == "string" and setting:find("\n") then
		local first = clip(setting:match("^[^\n]*"), INFO_DEFAULT_MAX)
		return first:sub(-3) == "…" and first or first .. "…"
	end
	return clip(show(setting), INFO_DEFAULT_MAX)
end

local function same(left, right)
	if type(left) == "table" and type(right) == "table" then
		return qed.json.encode(left) == qed.json.encode(right)
	end
	return left == right
end

local function copy(source)
	local out = {}
	for key, item in pairs(source or {}) do
		out[key] = item
	end
	return out
end

local function choices_of(decl)
	if type(decl.choices) == "function" then
		local ok, list = pcall(decl.choices)
		return ok and type(list) == "table" and list or {}
	end
	return decl.choices or {}
end

local function is_compound(decl)
	return decl.type == "list" or decl.type == "map" or decl.type == "record"
end

local function sorted_fields(fields)
	local names = {}
	for name in pairs(fields) do
		names[#names + 1] = name
	end
	table.sort(names, function(left, right)
		if is_compound(fields[left]) ~= is_compound(fields[right]) then
			return is_compound(fields[right])
		end
		return left < right
	end)
	return names
end

local function summary(row)
	if row.kind == "removed" then
		return "(removed)"
	elseif row.kind == "add" then
		return row.parent.decl.type == "list" and "+ add item" or "+ add entry"
	elseif row.kind == "list" then
		local count = #(row.value or {})
		return count == 1 and "1 item" or count .. " items"
	elseif row.kind == "map" then
		local count = 0
		for _ in pairs(row.value or {}) do
			count = count + 1
		end
		return count == 1 and "1 entry" or count .. " entries"
	elseif row.kind == "record" then
		return ""
	end
	return show(row.value)
end

-- a record that is neither an item nor an entry has no row of its own
local function add_node(out, set, node)
	local decl = node.decl
	node.kind = decl.type
	node.key = "opt\t" .. table.concat(node.path, "\t")
	node.description = decl.description ~= "" and decl.description or (node.parent and node.parent.description) or ""
	node.via_parent = node.parent ~= nil and (node.parent.kind == "list" or node.parent.via_parent)
	if node.via_parent then
		node.user = node.parent.user
	else
		node.user = set[table.concat(node.path, "/")] == true
	end
	local item = node.parent and (node.parent.kind == "list" or node.parent.kind == "map")
	if decl.type ~= "record" or item then
		out[#out + 1] = node
	end
	local function child(name, slot, child_decl, setting, default)
		local path = {table.unpack(node.path)}
		path[#path + 1] = slot
		add_node(out, set, {source = node.source, name = name, path = path, decl = child_decl, value = setting,
			default = default, parent = node, slot = slot})
	end
	if decl.type == "record" then
		for _, field in ipairs(sorted_fields(decl.fields)) do
			local name = node.name == "" and field or node.name .. "." .. field
			child(name, field, decl.fields[field], (node.value or {})[field], node.default and node.default[field])
		end
	elseif decl.type == "list" then
		for index, setting in ipairs(node.value or {}) do
			child(("%s[%d]"):format(node.name, index), index, decl.of, setting, node.default and node.default[index])
		end
	elseif decl.type == "map" then
		local keys = {}
		for key in pairs(node.value or {}) do
			keys[#keys + 1] = key
		end
		table.sort(keys)
		for _, key in ipairs(keys) do
			child(node.name .. "." .. key, key, decl.value, node.value[key], node.default and node.default[key])
		end
		local dropped = {}
		for key in pairs(node.default or {}) do
			if (node.value or {})[key] == nil and set[table.concat(node.path, "/") .. "/" .. key] then
				dropped[#dropped + 1] = key
			end
		end
		table.sort(dropped)
		for _, key in ipairs(dropped) do
			local path = {table.unpack(node.path)}
			path[#path + 1] = key
			out[#out + 1] = {source = node.source, name = node.name .. "." .. key, path = path, decl = decl.value, kind = "removed",
				key = "opt\t" .. table.concat(path, "\t"), parent = node, slot = key, user = true, default = node.default[key],
				description = node.description}
		end
	end
	if decl.type == "list" or decl.type == "map" then
		out[#out + 1] = {source = node.source, name = node.name, path = node.path, decl = decl, kind = "add",
			key = node.key .. "\t+", parent = node, user = node.user, description = node.description}
	end
end

local function option_rows()
	local out = {}
	local values = qed.config_values()
	local core = {type = "record", description = "", fields = qed.config_schema()}
	local defaults = {}
	for name, field in pairs(core.fields) do
		defaults[name] = field.default
	end
	add_node(out, values.set, {source = "core", name = "", path = {}, decl = core, value = values.core, default = defaults})
	for _, plugin in ipairs(qed.plugins()) do
		local fields = copy(plugin.options)
		fields.enabled = ENABLED
		local plugin_defaults = {}
		for name, field in pairs(fields) do
			plugin_defaults[name] = field.default
		end
		add_node(out, values.set, {source = plugin.id, name = plugin.id, path = {"plugins", plugin.id},
			decl = {type = "record", description = "", fields = fields}, value = values.plugins[plugin.id], default = plugin_defaults})
	end
	return out
end

local function keybind_rows(user)
	local out, groups = {}, {}
	for _, cmd in ipairs(qed.commands()) do
		if cmd.id then
			local source = cmd.owner
			local id = source .. "/" .. cmd.id
			local row = groups[id]
			if not row then
				local set = type(user[source]) == "table" and user[source][cmd.id] or nil
				local label = cmd.name
				if source == "core" and CORE_SCOPES[cmd.scope] then
					label = CORE_SCOPES[cmd.scope] .. ": " .. cmd.name
				end
				row = {
					key = "kb\t" .. id,
					source = source,
					name = label,
					keybind = cmd.id,
					scope = cmd.scope,
					path = {source, cmd.id},
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
	return table.concat({row.name, chord, row.source .. "/" .. row.keybind}, " ")
end

local function value_text(row)
	if tab == 2 then
		return type(row.value) == "string" and row.value or show(row.value)
	end
	return summary(row)
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
		if row.kind == "add" then
			return text .. "Enter adds " .. (row.parent.kind == "list" and "an item" or "an entry")
		end
		if row.default == nil then
			return text .. "Default: none"
		elseif row.kind == "list" or row.kind == "map" then
			return text .. "Default: " .. summary({kind = row.kind, value = row.default})
		end
		return text .. "Default: " .. clip(show(row.default), INFO_DEFAULT_MAX)
	end
	local default = row.default ~= "" and row.default or "none"
	local scopes = {}
	for scope in pairs(row.scopes) do
		scopes[#scopes + 1] = scope
	end
	table.sort(scopes)
	return ("%s. Default: %s. Scope: %s. Id: %s/%s"):format(row.name, default, table.concat(scopes, ", "), row.source, row.keybind)
end

local HINTS = {{label = "tabs", cmd = "Settings: Next Tab"}, {label = "Enter edit"}, {label = "reset", cmd = "Settings: Reset"}}
local TEXT_HINTS = {{label = "save", cmd = "Settings: Save Text"}, {label = "cancel", cmd = "Settings: Cancel Text"}}

local function highlighted()
	local state = ui.node("settings_rows"):state()
	return state and state.highlighted or nil
end

local function setting_row(record)
	return ui.row{
		ui.text{width = 1, fg = "git_modified", record.user and "▎" or " "},
		ui.text{width = view.name_width, record.name},
		ui.text{grow = 1, "  ", record.value},
	}
end

local function tab_row()
	local cells = {ui.text{" "}}
	for index, title in ipairs(TABS) do
		local on = index == tab
		if index > 1 then
			cells[#cells + 1] = ui.text{fg = "pane_shortcut_foreground", " │ "}
		end
		cells[#cells + 1] = ui.text{
			on = {click = function() menu.switch_tab(index) return true end},
			{fg = on and "pane_prompt_foreground" or "pane_shortcut_foreground", title}}
	end
	return ui.row{height = 1, table.unpack(cells)}
end

local function footer()
	local footer_state = view.footer
	if footer_state and footer_state.kind == "input" then
		return ui.row{height = 1,
			ui.text{fg = "pane_prompt_foreground", " ", footer_state.prompt},
			ui.editor{id = "settings_input", buffer = footer_state.buffer, height = 1, grow = 1, scope = {"settings_input", "editor"}},
		}
	elseif footer_state and footer_state.kind == "text" then
		return ui.column{height = TEXT_ROWS + 2,
			ui.text{height = 1, fg = "pane_prompt_foreground", " ", footer_state.prompt},
			ui.editor{id = "settings_text", buffer = footer_state.buffer, height = TEXT_ROWS, wrap = true, margin = {left = 1, right = 1},
				scope = {"settings_text", "editor"}},
			ui.footer{hints = TEXT_HINTS},
		}
	elseif footer_state then
		return ui.text{id = "settings_chord", height = 1, fg = "pane_prompt_foreground", " ", footer_state.prompt,
			on = {key = function(args)
				menu.capture(args.chord)
				return true
			end}}
	end
	return ui.footer{hints = HINTS}
end

local function build()
	local columns = COLUMNS[tab]
	return ui.dismissable{on_dismiss = function() menu.dismiss() end,
		ui.pane{place = "full", max_width = qed.opt("pane_max_width"), scope = "list",
			tab_row(),
			ui.row{height = 1,
				ui.text{fg = "pane_prompt_foreground", " > "},
				ui.editor{id = "settings_query", buffer = view.query, height = 1, grow = 1, margin = {right = 1},
					scope = {"settings", "editor"}, placeholder = "type to filter"},
			},
			ui.row{bold = true, ui.text{width = 1, " "}, ui.text{width = view.name_width, columns[1]}, ui.text{grow = 1, "  ", columns[2]}},
			ui.scroll{id = "settings_scroll", grow = 1,
				ui.virtual_column{id = "settings_rows", data = view.matches, item = setting_row, on = {state = function() menu.rebuild() end},
					highlight_style = {bg = "pane_selection_background", fg = "pane_selection_foreground"}}},
			ui.text{wrap = true, margin = {left = 1, right = 1}, height = view.footer and view.footer.kind == "text" and 0 or nil,
				info_of(rows[highlighted() or ""])},
			footer(),
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
	local list = tab == 1 and option_rows() or keybind_rows(keybinds_config())
	local by_key, width = {}, #COLUMNS[tab][1]
	for _, row in ipairs(list) do
		by_key[row.key] = row
		width = math.max(width, utf8.len(row.name) or #row.name)
	end
	return list, by_key, math.min(width, NAME_MAX[tab])
end

local function refresh(reorder, select)
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
	local keep = select or highlighted()
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

local function prompt_input(prompt, text, submit, kind)
	local buffer = qed.buf.create{internal = true}
	buffer:set_text(text)
	if kind == "text" then
		buffer:set_cursor({row = buffer:line_count(), col = #buffer:line(buffer:line_count()) + 1})
	else
		buffer:set_cursor({row = 1, col = #text + 1})
	end
	view.footer = {kind = kind or "input", buffer = buffer, prompt = prompt .. ": ", submit = submit}
	menu.rebuild()
	ui.node(kind == "text" and "settings_text" or "settings_input"):focus()
end

local function write(row, setting)
	local ok, err
	if row.keybind then
		if same(setting, row.default) then
			ok, err = qed.keybind_unset(row.source, row.keybind)
		else
			ok, err = qed.keybind_set(row.source, row.keybind, setting)
		end
	elseif row.default ~= nil and same(setting, row.default) then
		ok, err = qed.config_unset(row.path)
	else
		ok, err = qed.config_set(row.path, setting)
	end
	if not ok then
		qed.message(err, "error")
	end
	return ok
end

-- an item, or anything inside one, is written as the whole list it belongs to
local function commit(row, setting)
	if row.via_parent then
		local container = copy(row.parent.value)
		container[row.slot] = setting
		return commit(row.parent, container)
	end
	return write(row, setting)
end

local function parse(decl, name, text)
	if decl.type == "text" then
		return text
	elseif decl.type == "string" then
		if text:find("\n") then
			return nil, name .. " is a single line"
		end
		return text
	end
	local number = tonumber(text)
	if not number or math.type(number) ~= "integer" then
		return nil, name .. " needs a whole number"
	end
	if decl.min and number < decl.min then
		return nil, ("%s must be at least %d"):format(name, decl.min)
	end
	if decl.max and number > decl.max then
		return nil, ("%s must be at most %d"):format(name, decl.max)
	end
	return number
end

local function set_row(row, setting, select)
	if commit(row, setting) then
		qed.message(row.name .. " set to " .. brief(setting))
		refresh(false, select)
	end
end

local function ask(decl, name, current, done)
	if decl.type == "bool" then
		if current == nil then
			done(decl.default)
		else
			done(not current)
		end
	elseif decl.type == "choice" then
		local choice = qed.pick{items = choices_of(decl), prompt = name .. " >", selected = type(current) == "string" and current or nil}
		if choice then
			done(choice)
		end
	elseif decl.type == "int" or decl.type == "string" or decl.type == "text" then
		prompt_input(name, current == nil and "" or tostring(current), function(input)
			local setting, err = parse(decl, name, input)
			if err then
				qed.message(err, "error")
			else
				done(setting)
			end
		end, decl.type == "text" and "text" or nil)
	else
		done(copy(decl.default))
	end
end

local function add_item(container)
	local decl = container.decl
	if decl.type == "list" then
		local index = #(container.value or {}) + 1
		ask(decl.of, ("%s[%d]"):format(container.name, index), nil, function(setting)
			local items = copy(container.value)
			items[index] = setting
			if commit(container, items) then
				qed.message(("%s[%d] added"):format(container.name, index))
				refresh(false, container.key .. "\t" .. index)
			end
		end)
		return
	end
	local taken = container.value or {}
	local function with_key(key)
		if key == nil or key == "" then
			return
		elseif taken[key] ~= nil then
			qed.message(container.name .. "." .. key .. " already exists", "error")
			return
		end
		ask(decl.value, container.name .. "." .. key, nil, function(setting)
			local path = {table.unpack(container.path)}
			path[#path + 1] = key
			local entry = {path = path, default = container.default and container.default[key], via_parent = container.via_parent,
				parent = container, slot = key}
			if commit(entry, setting) then
				qed.message(container.name .. "." .. key .. " added")
				refresh(false, container.key .. "\t" .. key)
			end
		end)
	end
	if decl.key.type == "choice" then
		local free = {}
		for _, choice in ipairs(choices_of(decl.key)) do
			if taken[choice] == nil then
				free[#free + 1] = choice
			end
		end
		if #free == 0 then
			qed.message(container.name .. " has an entry for every choice")
			return
		end
		with_key(qed.pick{items = free, prompt = container.name .. " >"})
	else
		prompt_input(container.name .. " key", "", with_key)
	end
end

local function edit_option(row)
	if row.kind == "add" then
		add_item(row.parent)
	elseif row.kind == "list" or row.kind == "map" then
		add_item(row)
	elseif row.kind == "record" then
		qed.message(row.name .. ": edit its fields")
	elseif row.kind == "removed" then
		qed.message(row.name .. " is removed: Ctrl+d restores it")
	else
		ask(row.decl, row.name, row.value, function(setting)
			if not same(setting, row.value) then
				set_row(row, setting)
			end
		end)
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

local function normalize(chord)
	return chord:match("^Ctrl%+") and chord:lower():gsub("^ctrl", "Ctrl") or chord
end

local function conflict(row, chord)
	local want = normalize(chord)
	for _, cmd in ipairs(qed.commands()) do
		local mine = cmd.owner == row.source and cmd.id == row.keybind
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
		local ok, err
		if other.id then
			if other.key == "" then
				ok, err = qed.keybind_unset(other.owner, other.id)
			else
				ok, err = qed.keybind_set(other.owner, other.id, "")
			end
		end
		if not ok then
			qed.message(err or (other.name .. " borrows its bind and cannot be unbound here"), "error")
			return
		end
	end
	if write(row, chord) then
		qed.message(other and ("%s set to %s, %s unbound"):format(row.name, chord, other.name) or row.name .. " set to " .. chord)
		refresh()
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
	if not footer_state or not footer_state.submit then
		return
	end
	local text = footer_state.buffer:text()
	cancel_input()
	footer_state.submit(text)
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
	tab = index
	cancel_input()
	refresh(true)
end

function menu.dismiss()
	if not view then
		return
	end
	local closing = view
	view = nil
	if closing.footer and closing.footer.buffer then
		closing.footer.buffer:close()
	end
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

local function next_key(row)
	local found = false
	for index = 1, view.matches:count() do
		local record = view.matches:at(index)
		if found then
			return record.key
		end
		found = record.key == row.key
	end
end

local function remove_entry(row)
	local container = row.parent
	if container.kind == "list" then
		local items = {}
		for index, item in ipairs(container.value) do
			if index ~= row.slot then
				items[#items + 1] = item
			end
		end
		if commit(container, items) then
			qed.message(row.name .. " removed")
			refresh(false, row.slot <= #items and row.key or container.key .. "\t+")
		end
		return
	end
	if container.via_parent then
		local entries = copy(container.value)
		entries[row.slot] = nil
		if commit(container, entries) then
			qed.message(row.name .. " removed")
			refresh(false, next_key(row))
		end
	elseif row.kind == "removed" then
		if qed.config_unset(row.path) then
			qed.message(row.name .. " restored")
			refresh(false, row.key)
		end
	elseif row.default ~= nil and not row.user then
		if qed.config_set(row.path, qed.json.null) then
			qed.message(row.name .. " removed")
			refresh(false, row.key)
		end
	elseif row.default ~= nil then
		if qed.config_unset(row.path) then
			qed.message(row.name .. " reset to the default")
			refresh()
		end
	elseif qed.config_unset(row.path) then
		qed.message(row.name .. " removed")
		refresh(false, next_key(row))
	end
end

function menu.reset()
	local row = view and rows[highlighted() or ""]
	if not row then
		return
	end
	if tab == 1 and row.parent and (row.parent.kind == "list" or row.parent.kind == "map") and row.kind ~= "add" then
		remove_entry(row)
		return
	end
	if row.kind == "add" then
		row = row.parent
	end
	if row.via_parent then
		local default = row.decl.default
		if type(default) == "table" then
			default = copy(default)
		end
		if same(default, row.value) then
			qed.message(row.name .. " is already the default")
		else
			set_row(row, default)
		end
		return
	end
	if not row.user then
		qed.message(row.name .. " is already the default")
		return
	end
	local ok, err
	if row.keybind then
		ok, err = qed.keybind_unset(row.source, row.keybind)
	else
		ok, err = qed.config_unset(row.path)
	end
	if not ok then
		qed.message(err, "error")
		return
	end
	local default = brief(row.default)
	if row.kind == "list" or row.kind == "map" then
		default = summary({kind = row.kind, value = row.default})
	end
	qed.message(row.name .. " reset to " .. default)
	refresh()
end

function menu.open(index)
	if view and tab == index then
		menu.dismiss()
		return
	elseif view then
		menu.switch_tab(index)
		return
	end
	tab = index
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
	qed:on("config_changed", function()
		refresh()
	end)
	for _, event in ipairs({"theme_changed", "plugin_loaded", "plugin_unloaded"}) do
		qed:on(event, function()
			refresh()
		end)
	end
	qed.command{id = "open_config_ui", name = "Open Config UI", welcome = true, run = function() menu.open(1) end}
	qed.command{id = "open_keybinds_ui", name = "Open Keybinds UI", welcome = true, run = function() menu.open(2) end}
	qed.command{id = "reset", name = "Reset", scope = "settings", key = "Ctrl+d", run = menu.reset}
	qed.command{id = "edit", name = "Edit", scope = "settings", key = "Enter", run = activate}
	qed.command{id = "next_tab", name = "Next Tab", scope = "settings", key = "Tab", run = function() menu.switch_tab(tab % #TABS + 1) end}
	qed.command{id = "previous_tab", name = "Previous Tab", scope = "settings", key = "Shift+Tab", run = function() menu.switch_tab((tab - 2) % #TABS + 1) end}
	qed.command{id = "close", name = "Close", scope = "settings", key = "Esc", run = close}
	qed.command{id = "submit", name = "Submit", scope = "settings_input", key = "Enter", run = submit}
	qed.command{id = "cancel", name = "Cancel", scope = "settings_input", key = "Esc", run = cancel_input}
	qed.command{id = "save_text", name = "Save Text", scope = "settings_text", key = "Ctrl+s", run = submit}
	qed.command{id = "cancel_text", name = "Cancel Text", scope = "settings_text", key = "Esc", run = cancel_input}
end

return menu
