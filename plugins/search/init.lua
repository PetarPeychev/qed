local MAX = 500
local MAX_COLUMNS = 300

local min_query
local query, selected = "", 1
local has_rg = false

local function rg_ready()
	if not has_rg then
		local r = qed.spawn{cmd = "command -v rg"}
		has_rg = r ~= nil and r.code == 0
	end
	return has_rg
end

local function parse(out)
	local hits = {}
	for line in out:gmatch("[^\n]+") do
		local file, row, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
		if file and file ~= "" then
			hits[#hits + 1] = {file = file, row = tonumber(row), col = tonumber(col), text = text:gsub("\r$", "")}
		end
	end
	table.sort(hits, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		if a.row ~= b.row then
			return a.row < b.row
		end
		return a.col < b.col
	end)
	local items, prev = {}, nil
	for _, h in ipairs(hits) do
		local key = h.file .. ":" .. h.row
		if key ~= prev then
			prev = key
			items[#items + 1] = {
				label = ("%s:%d  %s"):format(h.file, h.row, h.text:match("^[ \t]*(.*)")),
				path = qed.path.join(qed.root(), h.file),
				pos = {row = h.row, col = h.col},
				n = #items + 1,
			}
		end
	end
	return items, #hits
end

local function search(ctx, scope)
	if not rg_ready() then
		qed.message("ripgrep (rg) not found", {level = "error", source = "Find"})
		return
	end
	local start, keep = query, selected
	local sel = ctx.selection_text
	if sel and not sel:find("\n") and sel:find("[^ \t]") then
		start, keep = sel, 1
	end
	local args = ""
	for _, path in ipairs(scope or {}) do
		args = args .. " " .. qed.shell_quote(path)
	end
	if args ~= "" then
		args = " --" .. args
	end
	local first = true
	local item, _, last = qed.pick{
		query = start,
		on_change = function(it)
			selected = it.n
		end,
		on_query = function(text, picker)
			query = text
			local pick = first and text == start and keep or 1
			first = false
			if #text < min_query then
				selected = 1
				picker:set({}, {hint = ("Type at least %d characters to search"):format(min_query)})
				return
			end
			-- stdin is the spawn's empty body; without </dev/null rg searches it instead of the tree
			local cmd = ("rg --vimgrep -F -S -M %d --max-columns-preview -e %s%s </dev/null 2>/dev/null | head -n %d"):format(MAX_COLUMNS, qed.shell_quote(text), args, MAX)
			local r, err = qed.spawn{cmd = cmd}
			if not r then
				selected = 1
				picker:set({}, {hint = "Search failed: " .. err})
				return
			end
			local items, lines = parse(r.stdout)
			if #items == 0 then
				selected = 1
			end
			picker:set(items, {selected = pick, more = lines >= MAX})
		end,
	}
	if last then
		query = last
	end
	if item then
		qed.jump(item.path, item.pos)
	end
end

local function search_tree(ctx)
	local paths, gone = {}, false
	for _, file in ipairs(ctx.files or {}) do
		if not qed.fs.exists(file) then
			gone = true
		else
			paths[#paths + 1] = qed.path.rel(file)
		end
	end
	if #paths == 0 then
		if gone then
			qed.message("Deleted file: restore it first", {source = "Files"})
		else
			qed.message("Nothing to search in selection", {source = "Search"})
		end
		return
	end
	search(ctx, paths)
end

return {
	setup = function()
		min_query = qed.options{min_query = 2}.min_query
		qed.command{name = "Find in Files", welcome = true, run = search}
		qed.command{name = "Search", keybind = "Find in Files", scope = "filetree", run = search_tree}
		qed.on("config_changed", function() min_query = qed.config().min_query end)
		qed.on("root_changed", function() selected = 1 end)
	end,
}
