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

local function check_fields(fn, spec, allowed)
	for k in pairs(spec) do
		if not allowed[k] then
			error(("qed.%s: unknown field '%s'"):format(fn, tostring(k)), 3)
		end
	end
end

local PICK = {items = true, prompt = true, selected = true, on = true}
local PROMPT = {prompt = true, text = true}
local CONFIRM = {question = true, choices = true}

local NODE_TYPES = {"column", "row", "box", "scroll", "text", "editor", "virtual_column", "outlet"}

local node_metas = {}
for _, name in ipairs(NODE_TYPES) do
	node_metas[name] = {__node = name}
end

local BUFFER_METHODS = {"valid", "path", "language", "modified", "big", "rev", "line_count", "lines", "line",
	"find_lines", "find_trailing", "text", "insert", "delete", "replace", "set_text", "cursor", "set_cursor",
	"screen_row", "set_screen_row", "selection", "set_selection", "set_language", "set_indent", "indent", "set_base",
	"base", "line_list", "on", "find"}

local BUFFER_EVENTS = {buf_open = true, buf_enter = true, buf_close = true, buf_pre_save = true, buf_save = true,
	buf_reload = true, buf_changed = true, cursor_moved = true, language_changed = true}

local buffer_cache = setmetatable({}, {__mode = "v"})
local buffer_meta

local function buffer_object(id)
	if type(id) ~= "number" then
		return id
	end
	local buffer = buffer_cache[id]
	if not buffer then
		buffer = setmetatable({id = id}, buffer_meta)
		buffer_cache[id] = buffer
	end
	return buffer
end

local function buffer_objects(qed)
	local buf_api = qed.buf
	local methods = buf_api.__methods
	buf_api.__methods = nil
	for _, name in ipairs(BUFFER_METHODS) do
		buf_api[name] = nil
	end
	if not buffer_meta then
		local on = methods.on
		function methods:on(event, handler)
			if type(handler) ~= "function" then
				return on(self, event, handler)
			end
			return on(self, event, function(buffer, ...)
				return handler(buffer_object(buffer), ...)
			end)
		end
		buffer_meta = {
			__index = methods,
			__eq = function(left, right) return left.id == right.id end,
			__tostring = function(self) return tostring(self.id) end,
		}
	end
	buf_api.__object = buffer_object
	local object = buffer_object
	local create, current, list = buf_api.create, buf_api.current, buf_api.list
	function buf_api.create(spec)
		return object(create(spec))
	end
	function buf_api.current()
		return object(current())
	end
	function buf_api.list()
		local buffers = list()
		for i, id in ipairs(buffers) do
			buffers[i] = object(id)
		end
		return buffers
	end
	local open, new_buf = qed.open, qed.new_buf
	function qed.open(path)
		local id, err = open(path)
		return object(id), err
	end
	function qed.new_buf(spec)
		local id, err = new_buf(spec)
		return object(id), err
	end
	local set_root = qed.set_root
	function qed.set_root(path, options)
		local ok, err, info = set_root(path, options)
		if type(info) == "table" and type(info.bufs) == "table" then
			for i, id in ipairs(info.bufs) do
				info.bufs[i] = object(id)
			end
		end
		return ok, err, info
	end
	local on = qed.on
	function qed:on(event, handler)
		if BUFFER_EVENTS[event] and type(handler) == "function" then
			local wrapped = handler
			handler = function(buffer, ...)
				return wrapped(object(buffer), ...)
			end
		end
		return on(self, event, handler)
	end
	local function with_buffer(fn)
		if type(fn) ~= "function" then
			return fn
		end
		return function(ctx, ...)
			if type(ctx) == "table" and type(rawget(ctx, "buf")) == "number" then
				rawset(ctx, "buf", object(rawget(ctx, "buf")))
			end
			return fn(ctx, ...)
		end
	end
	local command = qed.command
	function qed.command(spec)
		if type(spec) == "table" then
			spec.run = with_buffer(spec.run)
			spec.when = with_buffer(spec.when)
		end
		return command(spec)
	end
end

return function(qed)
	local open = qed.ui.open

	for _, name in ipairs(NODE_TYPES) do
		local meta = node_metas[name]
		qed.ui[name] = function(props)
			if type(props) ~= "table" then
				error(("qed.ui.%s expects a table"):format(name), 2)
			end
			if getmetatable(props) ~= nil then
				error(("qed.ui.%s: the table is already a node"):format(name), 2)
			end
			return setmetatable(props, meta)
		end
	end

	buffer_objects(qed)

	function qed.pick(spec)
		if type(spec) ~= "table" then
			error("table {items, prompt?, selected?, on?} expected", 2)
		end
		check_fields("pick", spec, PICK)
		local items, selected, on = spec.items, spec.selected, spec.on
		if type(items) ~= "table" then
			error("items must be a table", 2)
		end
		if on ~= nil and (type(on) ~= "table" or on.change ~= nil and type(on.change) ~= "function") then
			error("on must be a table {change?}", 2)
		end
		for k in pairs(on or {}) do
			if k ~= "change" then
				error(("on.%s is not a pick handler (only change)"):format(tostring(k)), 2)
			end
		end
		local index, split = nil, false
		if type(selected) == "number" then
			if math.type(selected) ~= "integer" then
				error("selected must be an item index or label", 2)
			end
			index = selected >= 1 and selected <= #items and selected or nil
		elseif selected ~= nil and type(selected) ~= "string" then
			error("selected must be an item index or label", 2)
		end
		for i, it in ipairs(items) do
			split = split or type(it) == "table" and it.path ~= nil
			if index == nil and selected ~= nil and label_of(it) == selected then
				index = i
			end
		end
		local v, err = open{
			kind = "child",
			modal = true,
			place = split and "split" or "center",
			fields = {{prompt = prefix(spec.prompt), count = split}},
			list = {items = items, selected = index},
			preview = split and "auto" or nil,
			on = {change = on and on.change},
		}
		if not v then
			return nil, err
		end
		local picked = await(v)
		return picked and picked[1]
	end

	function qed.prompt(spec)
		if type(spec) ~= "table" then
			error("table {prompt, text?} expected", 2)
		end
		check_fields("prompt", spec, PROMPT)
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

	function qed.confirm(spec)
		if type(spec) ~= "table" then
			error("table {question, choices?} expected", 2)
		end
		check_fields("confirm", spec, CONFIRM)
		local question, choices = spec.question, spec.choices
		if type(question) ~= "string" then
			error("question must be a string", 2)
		end
		if choices == nil then
			choices = {"Yes", "No"}
		elseif type(choices) ~= "table" or #choices == 0 then
			error("choices must be a non-empty table of strings", 2)
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
end
