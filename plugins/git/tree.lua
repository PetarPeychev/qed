local repo = require("repo")

local M = {}

local RANK = {added = 1, modified = 2, deleted = 3}
local BAR = {added = "git_added", modified = "git_modified", deleted = "git_deleted"}

local SPACE = {[9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true}

-- almost every path needs nothing stripped, so the gsubs run only when an end byte says so
local function clean(s)
	local a, z = s:byte(1), s:byte(-1)
	if not (SPACE[a] or SPACE[z] or a == 34 or z == 34 or z == 47) then
		return s
	end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return (s:gsub('^"', ""):gsub('"$', ""):gsub("/$", ""))
end

function M.name_status_line(line)
	local parts = {}
	for f in (line .. "\t"):gmatch("([^\t]*)\t") do
		parts[#parts + 1] = f
	end
	if #parts < 2 or parts[1] == "" then
		return nil
	end
	local code = parts[1]:sub(1, 1)
	if code == "R" then
		if #parts ~= 3 then
			return nil
		end
		return clean(parts[3]), "modified", clean(parts[2])
	end
	local mark = code == "D" and "deleted" or code == "A" and "added" or "modified"
	local path = clean(parts[2])
	if path == "" then
		return nil
	end
	return path, mark
end

function M.porcelain_line(line)
	if #line < 4 then
		return nil
	end
	local x, y, rel = line:byte(1), line:byte(2), line:sub(4)
	local from
	local arrow = rel:find(" -> ", 1, true)
	if arrow then
		from = clean(rel:sub(1, arrow - 1))
		rel = rel:sub(arrow + 4)
	end
	local path = clean(rel)
	if path == "" then
		return nil
	end
	-- status letters as bytes: ? 63, ! 33, A 65, D 68, R 82
	if x == 63 and y == 63 then
		return path, "added"
	elseif x == 33 and y == 33 then
		return path, "ignored"
	elseif x == 65 and y == 68 then
		return nil
	elseif x == 82 and y == 68 then
		return from, "deleted"
	elseif x == 68 or y == 68 then
		return path, "deleted"
	elseif x == 82 then
		return path, "modified", from
	elseif x == 65 or y == 65 then
		return path, "added"
	end
	return path, "modified"
end

-- a rename prints `old => new` or `dir/{old => new}/f`; sizes key on the new path
function M.numstat_path(s)
	if s:byte(1) ~= 34 and s:byte(-1) ~= 34 and not s:find(" => ", 1, true) then
		return s
	end
	local p = s:gsub('^"', ""):gsub('"$', "")
	local arrow = p:find(" => ", 1, true)
	if not arrow then
		return p
	end
	local before, after = p:sub(1, arrow - 1), p:sub(arrow + 4)
	local lb = before:match(".*(){")
	local rb = after:find("}", 1, true)
	if not lb or not rb then
		return after
	end
	local joined = before:sub(1, lb - 1) .. after:sub(1, rb - 1) .. after:sub(rb + 1)
	return (joined:gsub("//", "/"):gsub("^/+", ""))
end

function M.numstat_line(line, untracked)
	if untracked then
		local path, n = line:match("^(.+):(%d+)$")
		if not path then
			return nil
		end
		return path, tonumber(n), 0
	end
	local a, d, rest = line:match("^(%d+)\t(%d+)\t(.*)$")
	if not a then
		return nil
	end
	return M.numstat_path(rest), tonumber(a), tonumber(d)
end

M.MAX = 50000

local function add(st, rel, mark, from)
	local path = st.under .. rel
	if mark == "deleted" and qed.fs.exists(path) then
		mark = "modified"
	end
	local e = st.files[path]
	if not e then
		if st.count >= M.MAX then
			st.full = true
			return
		end
		st.count = st.count + 1
		e = {mark = mark}
		st.files[path] = e
		st.byrel[rel] = e
	elseif RANK[mark] > RANK[e.mark] then
		e.mark = mark
	end
	if from and not e.from then
		e.from = st.top .. "/" .. from
	end
end

local function parse_base(st, text)
	st.based = true
	for line in repo.each(text) do
		local rel, mark, from = M.name_status_line(line)
		if rel then
			add(st, rel, mark, from)
		end
	end
end

-- against a base, tracked changes come from `diff --name-status`; status adds only untracked and ignored paths
local function parse_status(st, text)
	for line in repo.each(text) do
		local rel, mark, from = M.porcelain_line(line)
		if mark == "ignored" then
			if #st.ignored < M.MAX then
				st.ignored[#st.ignored + 1] = st.top .. "/" .. rel
			end
		elseif rel and not (st.based and line:sub(1, 2) ~= "??") then
			add(st, rel, mark, from)
		end
	end
end

local function parse_sizes(st, text, untracked)
	for line in repo.each(text) do
		local rel, a, d = M.numstat_line(line, untracked)
		-- keyed by the short relative path: no absolute path is built or hashed per line
		if rel and (a > 0 or d > 0) and not st.sized[rel] then
			st.sized[rel] = true
			local e = st.byrel[rel] or st.files[st.under .. rel]
			if e then
				e.added, e.removed = a, d
			end
		end
	end
end

local function state(files, ignored, top)
	return {files = files, ignored = ignored, top = top, under = top .. "/", count = 0, sized = {}, byrel = {}, based = false, full = false}
end

function M.parse(files, ignored, top, out)
	local st = state(files, ignored, top)
	if out.base then
		parse_base(st, out.base)
	end
	parse_status(st, out.status)
	parse_sizes(st, out.numstat, false)
	parse_sizes(st, out.untracked, true)
	return st.full
end

-- runs in the background so a superseded scan can kill it; nil once cancelled
local function run(job, spec)
	if job.cancelled then
		return nil
	end
	local ok, proc = pcall(qed.spawn_bg, spec)
	if not ok then
		return ""
	end
	job.proc = proc
	local r = proc:wait()
	job.proc = nil
	if job.cancelled then
		return nil
	end
	return r.code == 0 and r.stdout or ""
end

local function git(job, top, args)
	local argv = {"git", "-C", top, "-c", "core.quotePath=false"}
	for _, a in ipairs(args) do
		argv[#argv + 1] = a
	end
	return run(job, {argv = argv, cwd = top})
end

-- pruned at each repo so an ignored node_modules is never walked
local function repos(root, job)
	local top = repo.out(root, {"rev-parse", "--show-toplevel"})
	if top ~= "" then
		return {top}
	end
	local found = run(job, {argv = {"find", root, "-type", "d", "-exec", "sh", "-c", 'test -e "$0/.git"', "{}", ";", "-prune", "-print"}})
	local out = {}
	for line in repo.each(found or "") do
		out[#out + 1] = line
	end
	return out
end

-- each output is parsed and dropped before the next spawn so only one is held at a time
function M.scan(root, base, job)
	local files, ignored, full, count = {}, {}, false, 0
	for _, top in ipairs(repos(root, job)) do
		local st = state(files, ignored, top)
		st.count = count
		local rev = repo.rev(top, base)
		local text
		if rev ~= "HEAD" then
			text = git(job, top, {"diff", "--name-status", "--find-renames", rev})
			if not text then
				return nil
			end
			parse_base(st, text)
		end
		text = git(job, top, {"status", "--porcelain", "--find-renames", "--ignored=matching", "--untracked-files=all"})
		if not text then
			return nil
		end
		parse_status(st, text)
		text = git(job, top, {"diff", rev, "--numstat", "--find-renames"})
		if not text then
			return nil
		end
		parse_sizes(st, text, false)
		text = run(job, {cmd = repo.UNTRACKED, cwd = top})
		if not text then
			return nil
		end
		parse_sizes(st, text, true)
		full, count = full or st.full, st.count
	end
	if job.cancelled then
		return nil
	end
	return files, ignored, full
end

-- paths handled between yields while a scan becomes the file tree's view
local CHUNK = 2000

local function tick(i, stop)
	if i % CHUNK == 0 then
		qed.sleep(0)
		return stop()
	end
	return false
end

local function parent(p)
	return p:match("^(.+)/[^/]*$") or p
end

function M.compare(a, b, stop)
	local n, fields = 0, false
	for path, f in pairs(a.files) do
		local g = b.files[path]
		if not g or (g.mark == "deleted") ~= (f.mark == "deleted") then
			return "paths"
		end
		fields = fields or g.mark ~= f.mark or g.from ~= f.from or g.added ~= f.added or g.removed ~= f.removed
		n = n + 1
		if tick(n, stop) then
			return nil
		end
	end
	for _ in pairs(b.files) do
		n = n - 1
	end
	if n ~= 0 then
		return "paths"
	end
	fields = fields or #a.ignored ~= #b.ignored
	for i, p in ipairs(a.ignored) do
		fields = fields or b.ignored[i] ~= p
	end
	return fields and "fields" or "same"
end

function M.view(files, ignored, stop)
	local status, changed, gone = {}, {}, {}
	local under = qed.root() .. "/"
	local function set(path, mark)
		local cur = status[path]
		if cur and RANK[cur] >= RANK[mark] then
			return true
		end
		status[path] = mark
		return false
	end
	local n = 0
	for path, f in pairs(files) do
		set(path, f.mark)
		changed[#changed + 1] = path
		if f.mark == "deleted" then
			gone[#gone + 1] = path
		end
		local up, p = f.mark == "deleted" and "modified" or f.mark, path
		-- every ancestor at least as long as under shares the prefix, so it is checked once
		local inside = p:find(under, 1, true) == 1
		while inside and #p >= #under do
			local np = parent(p)
			if np == p or set(np, up) then
				break
			end
			p = np
		end
		n = n + 1
		if tick(n, stop) then
			return nil
		end
	end
	local marks = {}
	local icon = qed.theme.icon("tree_renamed")
	for path, mark in pairs(status) do
		local e = {bar = BAR[mark]}
		if mark == "deleted" and not qed.fs.exists(path, {follow = false}) then
			e.fg = "git_deleted"
		end
		local f = files[path]
		if f then
			if f.from then
				e.suffix = icon .. " " .. (qed.path.rel(f.from) or f.from)
			end
			if (f.added or 0) > 0 or (f.removed or 0) > 0 then
				e.added, e.removed = f.added or 0, f.removed or 0
			end
		end
		marks[path] = e
		n = n + 1
		if tick(n, stop) then
			return nil
		end
	end
	for _, path in ipairs(ignored) do
		local e = marks[path] or {}
		e.dim = true
		marks[path] = e
	end
	return {marks = marks, changed = changed, deleted = gone}
end

return M
