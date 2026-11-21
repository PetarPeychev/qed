local MAX = 500
local MAX_COLUMNS = 300

local min_query
local running
local has_rg = false

local function rg_ready()
	if not has_rg then
		local r = qed.spawn{cmd = "command -v rg"}
		has_rg = r ~= nil and r.code == 0
	end
	return has_rg
end

local function short_hint()
	return ("Type at least %d characters to search"):format(min_query)
end

local function rg_cmd(text, args)
	-- stdin is the spawn's empty body; without </dev/null rg searches it instead of the tree
	return ("rg --vimgrep -F -S --line-buffered -M %d --max-columns-preview -e %s%s </dev/null 2>/dev/null"):format(MAX_COLUMNS, qed.shell_quote(text), args)
end

local function stop()
	if running then
		running:kill()
		running = nil
	end
end

local function query(v, text, args)
	stop()
	if #text < min_query then
		v:set({}, {hint = short_hint()})
		return
	end
	local root, n, seen = qed.root(), 0, {}
	local proc, err = qed.spawn_bg{cmd = rg_cmd(text, args), on_line = function(line)
		local file, row, col, hit = line:match("^(.-):(%d+):(%d+):(.*)$")
		if not file or file == "" then
			return
		end
		local key = file .. "\0" .. ("%09d"):format(tonumber(row))
		if seen[key] then
			return
		end
		seen[key] = true
		n = n + 1
		local item = {
			label = ("%s:%s  %s"):format(file, row, hit:gsub("\r$", ""):match("^[ \t]*(.*)")),
			key = key,
			path = qed.path.join(root, file),
			pos = {row = tonumber(row), col = tonumber(col)},
		}
		if n == 1 then
			v:set({item})
		else
			v:append({item})
		end
		if n > MAX then
			stop()
		end
	end}
	if not proc then
		v:set({}, {hint = "Search failed: " .. err})
		return
	end
	running = proc
	local r = proc:wait()
	if n == 0 and r then
		v:set({}, {hint = r.code > 1 and ("Search failed: rg exit code %d"):format(r.code) or "No matches"})
	end
end

local function search(ctx, scope)
	if not rg_ready() then
		qed.message("ripgrep (rg) not found", "error")
		return
	end
	local start
	local sel = ctx.selection_text
	if sel and not sel:find("\n") and sel:find("[^ \t]") then
		start = sel
	end
	local args = ""
	for _, path in ipairs(scope or {}) do
		args = args .. " " .. qed.shell_quote(path)
	end
	if args ~= "" then
		args = " --" .. args
	end
	qed.ui.open{
		id = "search",
		kind = "child",
		place = "split",
		fields = {{mode = "query", count = true, text = start}},
		list = {max = MAX, sort = true, empty = short_hint()},
		preview = "auto",
		on = {
			query = function(v, text) query(v, text, args) end,
			close = stop,
			activate = function(v, items)
				v:close()
				qed.jump(items[1].path, items[1].pos)
			end,
		},
	}
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
			qed.message("Deleted file: restore it first")
		else
			qed.message("Nothing to search in selection")
		end
		return
	end
	search(ctx, paths)
end

return {
	setup = function()
		qed.meta{description = "Project-wide search with ripgrep"}
		min_query = qed.options({min_query = 2}, {min_query = "Characters typed before a search runs"}).min_query
		qed.command{name = "In Files", key = "Alt+F", welcome = true, run = search}
		qed.command{name = "In Files", scope = "filetree", run = search_tree}
		qed.on("config_changed", function() min_query = qed.config().min_query end)
	end,
}
