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

local PANE_MARGIN_X, PANE_MARGIN_Y = 8, 3
-- the layout plugin's status bar and message line
local PANE_STATUS_ROWS = 2

local NODE_TYPES = {"column", "row", "box", "scroll", "text", "editor", "virtual_column", "outlet", "image", "terminal", "status"}

local node_metas = {markdown = {__node = "markdown"}}
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

local function dialogs(qed)
	local exports = qed.plugin("dialog")
	if not exports then
		error("the dialog plugin is not loaded", 3)
	end
	return exports
end

return function(qed)

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
	-- the rendered document is one core node (width-dependent layout, theme-resolved colors); place it in a scroll
	qed.markdown = {}
	function qed.markdown.parse(text, opts)
		if type(text) ~= "string" then
			error("qed.markdown.parse expects the markdown text", 2)
		end
		local props = {}
		for key, value in pairs(opts or {}) do
			props[key] = value
		end
		props.text = text
		return setmetatable(props, node_metas.markdown)
	end

	-- a full-screen float under a pane: a click outside the pane dismisses it, a click on it stays with it
	function qed.ui.dismissable(props)
		local on_dismiss = props.on_dismiss
		if type(on_dismiss) ~= "function" or type(props[1]) ~= "table" then
			error("qed.ui.dismissable expects {on_dismiss = fn, pane, ...}", 2)
		end
		local catcher = {id = props.id, float = "screen", width = "100%", height = "100%",
			on = {click = function()
				on_dismiss()
				return true
			end}}
		-- a click on a pane stays with it, after the pane's own click handler had its say
		for index, pane in ipairs(props) do
			if type(pane) == "table" then
				pane.on = pane.on or {}
				local own = pane.on.click
				pane.on.click = function(event)
					if own then
						own(event)
					end
					return true
				end
			end
			catcher[index] = pane
		end
		-- dim: the screen fades behind the panes, all but the status bar and message line
		if props.dim then
			local status = #qed.buf.list() > 0 and PANE_STATUS_ROWS or 0
			catcher[#catcher + 1] = qed.ui.column{dim = true, grow = 1, margin = {bottom = status}}
		end
		return qed.ui.column(catcher)
	end

	-- a bordered pane over the editor area, its sections (a title first) split by rules: "center" sized to fit and
	-- centred, "full" inset by PANE_MARGIN from the screen; the status bar and message line stay visible below either
	function qed.ui.pane(props)
		local box = {float = "screen", anchor = "center", border = true, bg = "pane_background"}
		local sections = {separator = true, fg = "pane_foreground"}
		local first = props.title and 1 or 0
		if props.title then
			sections[1] = qed.ui.text{fg = "pane_prompt_foreground", " ", props.title}
		end
		for key, value in pairs(props) do
			if type(key) == "number" then
				sections[key + first] = value
			elseif key ~= "place" and key ~= "max_width" and key ~= "title" then
				box[key] = value
			end
		end
		local status = #qed.buf.list() > 0 and PANE_STATUS_ROWS or 0
		if props.place == "center" then
			box.width = box.width or qed.opt("picker_width")
			box.height = box.height or "fit"
			box.margin = {bottom = status}
		elseif props.place == "full" then
			box.width = box.width or (props.max_width and {"100%", max = props.max_width} or "100%")
			box.height = box.height or "100%"
			box.margin = {left = PANE_MARGIN_X, right = PANE_MARGIN_X, top = PANE_MARGIN_Y, bottom = PANE_MARGIN_Y + status}
		else
			error("qed.ui.pane: place must be \"center\" or \"full\"", 2)
		end
		box[1] = qed.ui.column(sections)
		return qed.ui.box(box)
	end

	-- a list column beside its preview: the preview grows twice as fast up to its max, the list takes the rest;
	-- narrower than both minimums the preview hides and the list fills the pane
	function qed.ui.split(props)
		local kind, list, preview = props.kind, props[1], props[2]
		if (kind ~= "tree" and kind ~= "code") or type(list) ~= "table" then
			error("qed.ui.split expects {kind = \"tree\" or \"code\", list, preview?}", 2)
		end
		list.grow = 1
		list.width = {min = qed.opt("split_" .. kind .. "_min_width")}
		if preview then
			preview.grow, preview.drop = 2, 1
			preview.width = {min = qed.opt("split_preview_min_width"), max = qed.opt("split_preview_max_width")}
		end
		return qed.ui.row{separator = true, grow = 1, list, preview or false}
	end

	-- the widest pane a split fills: both columns at their max, the rule and the borders
	function qed.ui.split_width(kind)
		return qed.opt("split_" .. kind .. "_max_width") + qed.opt("split_preview_max_width") + 3
	end

	-- a pane's hint row: hints on the left (when narrow the last ones go first, never cut mid-word), toggle chips on
	-- the right; an entry with a cmd shows that command's key
	function qed.ui.footer(props)
		local keys
		local function text_of(entry)
			if not entry.cmd then
				return entry.label
			end
			if not keys then
				keys = {}
				for _, command in ipairs(qed.commands()) do
					keys[command.name] = command.shortcut
				end
			end
			local key = keys[entry.cmd]
			return key and key ~= "" and (key .. " " .. entry.label) or entry.label
		end
		local cells = {height = 1}
		for index, hint in ipairs(props.hints or {}) do
			cells[#cells + 1] = qed.ui.text{fg = "pane_shortcut_foreground", drop = index > 1 and index or nil,
				(index == 1 and " " or "  ") .. text_of(hint)}
		end
		cells[#cells + 1] = qed.ui.text{grow = 1, ""}
		for _, chip in ipairs(props.chips or {}) do
			cells[#cells + 1] = qed.ui.text{fg = chip.on and "pane_prompt_foreground" or "pane_shortcut_foreground",
				on = chip.on_click and {click = chip.on_click} or nil, "  " .. text_of(chip)}
		end
		cells[#cells + 1] = qed.ui.text{" "}
		return qed.ui.row(cells)
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
		local index = nil
		if type(selected) == "number" then
			if math.type(selected) ~= "integer" then
				error("selected must be an item index or label", 2)
			end
			index = selected >= 1 and selected <= #items and selected or nil
		elseif selected ~= nil and type(selected) ~= "string" then
			error("selected must be an item index or label", 2)
		end
		for i, it in ipairs(items) do
			if index == nil and selected ~= nil and label_of(it) == selected then
				index = i
			end
		end
		return dialogs(qed).pick{items = items, prompt = spec.prompt, selected = index or selected, on = on}
	end

	function qed.prompt(spec)
		if type(spec) ~= "table" then
			error("table {prompt, text?} expected", 2)
		end
		check_fields("prompt", spec, PROMPT)
		return dialogs(qed).prompt{prompt = spec.prompt, text = spec.text}
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
		return dialogs(qed).confirm{question = question, choices = choices}
	end
end
