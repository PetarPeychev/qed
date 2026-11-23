local ui = qed.ui

local WIDTH = 64
local MAX_ROWS = 12

local dialog

local function label_of(item)
	if type(item) == "table" then
		return item.label or item.path or ""
	end
	return tostring(item)
end

local function highlighted_key()
	local state = ui.node("dialog_rows"):state()
	return state and state.highlighted or nil
end

local function notify()
	if dialog.on_change then
		local key = highlighted_key()
		local record = key and dialog.matches:get(key)
		dialog.on_change(nil, record and dialog.items[record.index] or nil)
	end
end

local function highlight(key)
	local matches = dialog.matches
	if not (key and matches:get(key)) then
		local first = matches:at(1)
		key = first and first.key or false
	end
	ui.node("dialog_rows"):set_state{highlighted = key}
end

local function query_sync()
	local text = dialog.query:text()
	if text == dialog.applied then
		return
	end
	dialog.applied = text
	dialog.matches:set_query(text)
	highlight(nil)
	notify()
end

local function finish(result)
	if not dialog then
		return
	end
	local closing = dialog
	dialog = nil
	closing.handle:unmount(result)
	if closing.query then
		closing.query:close()
	end
end

local function choose()
	if not dialog then
		return
	end
	if dialog.kind == "prompt" then
		finish(dialog.query:text())
		return
	end
	if dialog.kind == "pick" then
		query_sync()
	end
	local key = highlighted_key()
	local record = key and dialog.matches:get(key)
	if not record then
		if dialog.kind == "pick" then
			finish(nil)
		end
		return
	end
	if dialog.kind == "confirm" then
		finish(record.index)
	else
		finish({dialog.items[record.index]})
	end
end

local function move(step)
	if not dialog or not dialog.matches then
		return
	end
	if dialog.kind == "pick" then
		query_sync()
	end
	local matches = dialog.matches
	local count = matches:count()
	if count == 0 then
		return
	end
	local before = matches:index_of(highlighted_key() or "") or 0
	local index = math.max(1, math.min(count, before + step))
	if index ~= before then
		ui.node("dialog_rows"):set_state{highlighted = matches:at(index).key}
		notify()
	end
end

local function item_row(record)
	local item = dialog and dialog.items[record.index]
	local detail = type(item) == "table" and (item.detail or (item.path and item.label and item.path ~= item.label and item.path)) or nil
	return ui.row{
		on = {
			click = function()
				ui.node("dialog_rows"):set_state{highlighted = record.key}
				notify()
				return true
			end,
			double_click = function()
				ui.node("dialog_rows"):set_state{highlighted = record.key}
				choose()
				return true
			end,
		},
		ui.text{grow = 1, " ", record.label},
		detail and ui.text{fg = "pane_dim_foreground", detail, " "} or false,
	}
end

local function frame(id, children)
	return ui.column{id = id, float = "screen", width = "100%", height = "100%",
		on = {click = function()
			finish(nil)
			return true
		end},
		ui.box{float = "screen", anchor = "top", width = WIDTH, height = "fit",
			margin = {top = 3, right = 2, bottom = 2, left = 2},
			border = true, bg = "pane_background", fg = "pane_foreground",
			on = {click = function() return true end},
			ui.column(children)},
	}
end

local function rows(scope)
	return ui.scroll{height = {"fit", max = MAX_ROWS},
		ui.virtual_column{id = "dialog_rows", scope = scope, data = dialog.matches, item = item_row,
			highlight_style = {bg = "pane_selection_background", fg = "pane_selection_foreground"}}}
end

local function query_row(prompt, scope)
	return ui.row{
		ui.text{fg = "pane_prompt_foreground", prompt and (prompt .. " ") or "> "},
		ui.editor{id = "dialog_query", buffer = dialog.query, height = 1, grow = 1, scope = scope},
	}
end

local function records_of(items)
	local list = qed.list.new{key = "key"}
	for index, item in ipairs(items) do
		list:append{key = tostring(index), index = index, label = label_of(item)}
	end
	return list
end

local function busy()
	if dialog and dialog.asker and not qed.plugin(dialog.asker) then
		finish(nil)
	end
	return dialog ~= nil
end

local function pick(spec)
	if busy() then
		return nil, "busy"
	end
	local items = spec.items
	dialog = {kind = "pick", asker = qed.caller(), items = items, on_change = spec.on and spec.on.change, query = qed.buf.create{internal = true}}
	dialog.records = records_of(items)
	dialog.matches = qed.fuzzy.list(dialog.records, {field = "label"})
	local selected = spec.selected
	local selected_key
	for index, item in ipairs(items) do
		if index == selected or (selected ~= nil and label_of(item) == selected) then
			selected_key = tostring(index)
			break
		end
	end
	local handle, err = ui.mount("alert", frame("dialog_pick", {
		query_row(spec.prompt, {"dialog_list", "dialog", "editor"}),
		rows(nil),
	}))
	if not handle then
		dialog.query:close()
		dialog = nil
		return nil, err
	end
	dialog.handle = handle
	local current = dialog
	dialog.applied = ""
	dialog.query:on("change", function()
		if dialog == current then
			query_sync()
		end
	end)
	ui.node("dialog_query"):focus()
	highlight(selected_key)
	local result = handle:wait()
	return result and result[1] or nil
end

local function prompt(spec)
	if busy() then
		return nil, "busy"
	end
	local query = qed.buf.create{internal = true}
	if spec.text and spec.text ~= "" then
		query:set_text(spec.text)
		query:set_cursor({row = 1, col = #spec.text + 1})
	end
	dialog = {kind = "prompt", asker = qed.caller(), query = query}
	local handle, err = ui.mount("alert", frame("dialog_prompt", {query_row(spec.prompt, {"dialog", "editor"})}))
	if not handle then
		query:close()
		dialog = nil
		return nil, err
	end
	dialog.handle = handle
	ui.node("dialog_query"):focus()
	return dialog.handle:wait()
end

local function confirm(spec)
	if busy() then
		return nil, "busy"
	end
	dialog = {kind = "confirm", asker = qed.caller(), items = spec.choices}
	dialog.records = records_of(spec.choices)
	dialog.matches = qed.fuzzy.list(dialog.records, {field = "label"})
	local handle, err = ui.mount("alert", frame("dialog_confirm", {
		ui.text{id = "dialog_question", wrap = true, " ", spec.question},
		rows({"dialog_list", "dialog"}),
	}))
	if not handle then
		dialog = nil
		return nil, err
	end
	dialog.handle = handle
	ui.node("dialog_rows"):focus()
	highlight(nil)
	return dialog.handle:wait()
end

return {
	setup = function()
		qed.meta{display_name = "Dialog", description = "Pick, prompt and confirm dialogs on qed.ui"}
		qed.command{name = "Next", scope = "dialog_list", key = "Down", run = function() move(1) end}
		qed.command{name = "Previous", scope = "dialog_list", key = "Up", run = function() move(-1) end}
		qed.command{name = "Choose", scope = "dialog", key = "Enter", run = choose}
		qed.command{name = "Cancel", scope = "dialog", key = "Esc", run = function() finish(nil) end}
		qed.export{pick = pick, prompt = prompt, confirm = confirm}
		qed:on("plugin_unloaded", function(id)
			if dialog and dialog.asker == id then
				finish(nil)
			end
		end)
	end,
}
