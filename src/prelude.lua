local function await(v)
	local ok, items, index, text = pcall(v.wait, v)
	v:close()
	if not ok then
		error(items, 0)
	end
	return items, index, text
end

local function prefix(prompt)
	if prompt ~= nil and prompt ~= "" then
		return prompt .. " "
	end
end

local function label_of(it)
	if type(it) == "table" then
		return it.label or it.path
	end
	return it
end

return function(qed)
	local open = qed.ui.open

	function qed.pick(spec)
		if type(spec) ~= "table" then
			error("table {items, prompt?, initial?, on_change?, multi?, query?, on_query?} expected", 2)
		end
		local items, on_query, on_change, initial = spec.items, spec.on_query, spec.on_change, spec.initial
		if on_query ~= nil and type(on_query) ~= "function" then
			error("on_query must be a function", 2)
		end
		if on_change ~= nil and type(on_change) ~= "function" then
			error("on_change must be a function", 2)
		end
		if spec.multi ~= nil and type(spec.multi) ~= "boolean" then
			error("multi must be a boolean", 2)
		end
		if items ~= nil and type(items) ~= "table" or items == nil and on_query == nil then
			error("items must be a table", 2)
		end
		items = items or {}
		local split, selected = on_query ~= nil, nil
		if type(initial) == "number" then
			if math.type(initial) ~= "integer" then
				error("initial must be an item index", 2)
			end
			selected = initial >= 1 and initial <= #items and initial or nil
		elseif initial ~= nil and type(initial) ~= "string" then
			error("initial must be an item index or label", 2)
		end
		for i, it in ipairs(items) do
			split = split or type(it) == "table" and it.path ~= nil
			if selected == nil and initial ~= nil and label_of(it) == initial then
				selected = i
			end
		end
		local picker
		local v, err = open{
			kind = "child",
			modal = true,
			place = split and "split" or "center",
			fields = {{prompt = prefix(spec.prompt), text = spec.query, mode = on_query and "query" or "filter", count = split}},
			list = {items = items, multi = spec.multi, selected = selected},
			preview = split and "auto" or nil,
			on = {
				change = on_change and function(_, item) on_change(item) end,
				query = on_query and function(view, q)
					picker = picker or {id = view.id, set = function(_, its, opts) return view:set(its, opts) end}
					on_query(q, picker)
				end,
			},
		}
		if not v then
			return nil, err
		end
		local picked, _, text = await(v)
		local r = picked and (spec.multi and picked or picked[1])
		if on_query then
			return r, nil, text
		end
		return r
	end

	function qed.prompt(spec)
		if type(spec) ~= "table" then
			error("table {prompt, text?} expected", 2)
		end
		local v, err = open{kind = "child", modal = true, fields = {{prompt = prefix(spec.prompt), text = spec.text, mode = "input"}}}
		if not v then
			return nil, err
		end
		local ok, _, text = await(v)
		if ok then
			return text
		end
		return nil
	end

	function qed.confirm(question, choices)
		if type(question) ~= "string" then
			error("bad argument #1 to 'confirm' (string expected)", 2)
		end
		if choices == nil then
			choices = {"Yes", "No"}
		elseif type(choices) ~= "table" then
			error("bad argument #2 to 'confirm' (choices must be a table of strings)", 2)
		elseif #choices == 0 then
			error("bad argument #2 to 'confirm' (choices must not be empty)", 2)
		end
		for _, c in ipairs(choices) do
			if type(c) ~= "string" then
				error("choices must be strings", 2)
			end
		end
		local v, err = open{kind = "child", modal = true, size = "dialog", text = {question}, list = {items = choices}}
		if not v then
			return nil, err
		end
		local picked, index = await(v)
		return picked and index or nil
	end

	function qed.pane(spec)
		if type(spec) ~= "table" then
			error("table {title, lines, footer?} expected", 2)
		end
		if type(spec.lines) ~= "table" then
			error("lines must be a table", 2)
		end
		local footer = spec.footer
		if footer == nil or footer == "" then
			footer = "↑↓ scroll  Esc close"
		end
		local v, err = open{place = "full", title = spec.title, text = spec.lines, footer = {hints = {{label = footer}}}}
		if not v then
			return nil, err
		end
		return {
			id = v.id,
			set = function(_, lines) return v:text(lines) end,
			close = function() v:close() end,
		}
	end
end
