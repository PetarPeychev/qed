local repo = require("repo")

local M = {}

local RANK = {added = 1, modified = 2, deleted = 3}

local function clean(s)
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
	local x, y, rel = line:sub(1, 1), line:sub(2, 2), line:sub(4)
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
	local code = x .. y
	if code == "??" then
		return path, "added"
	elseif code == "!!" then
		return path, "ignored"
	elseif code == "AD" then
		return nil
	elseif code == "RD" then
		return from, "deleted"
	elseif x == "D" or y == "D" then
		return path, "deleted"
	elseif x == "R" then
		return path, "modified", from
	elseif x == "A" or y == "A" then
		return path, "added"
	end
	return path, "modified"
end

-- a rename prints `old => new` or `dir/{old => new}/f`; sizes key on the new path
function M.numstat_path(s)
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

local function add(files, top, rel, mark, from)
	local path = qed.path.join(top, rel)
	if mark == "deleted" and qed.fs.exists(path) then
		mark = "modified"
	end
	local e = files[path]
	if not e then
		e = {mark = mark}
		files[path] = e
	elseif RANK[mark] > RANK[e.mark] then
		e.mark = mark
	end
	if from and not e.from then
		e.from = qed.path.join(top, from)
	end
end

local function lines(s)
	return s:gmatch("[^\n]+")
end

-- against a base, tracked changes come from `diff --name-status`; status adds only untracked and ignored paths
function M.parse(files, ignored, top, out)
	local based = out.base ~= nil
	for line in lines(out.base or "") do
		local rel, mark, from = M.name_status_line(line)
		if rel then
			add(files, top, rel, mark, from)
		end
	end
	for line in lines(out.status) do
		local rel, mark, from = M.porcelain_line(line)
		if mark == "ignored" then
			ignored[#ignored + 1] = qed.path.join(top, rel)
		elseif rel and not (based and line:sub(1, 2) ~= "??") then
			add(files, top, rel, mark, from)
		end
	end
	local sized = {}
	for _, section in ipairs({{out.numstat, false}, {out.untracked, true}}) do
		for line in lines(section[1]) do
			local rel, a, d = M.numstat_line(line, section[2])
			local path = rel and qed.path.join(top, rel)
			if path and (a > 0 or d > 0) and not sized[path] then
				sized[path] = true
				local e = files[path]
				if e then
					e.added, e.removed = a, d
				end
			end
		end
	end
end

-- pruned at each repo so an ignored node_modules is never walked
local function repos(root)
	local top = repo.out(root, {"rev-parse", "--show-toplevel"})
	if top ~= "" then
		return {top}
	end
	local ok, r = pcall(qed.spawn, {argv = {"find", root, "-type", "d", "-exec", "sh", "-c", 'test -e "$0/.git"', "{}", ";", "-prune", "-print"}})
	local out = {}
	for line in lines(ok and r.stdout or "") do
		out[#out + 1] = line
	end
	return out
end

local function stdout(r)
	return r.code == 0 and r.stdout or ""
end

function M.scan(root, base)
	local files, ignored = {}, {}
	for _, top in ipairs(repos(root)) do
		local rev = repo.rev(top, base)
		local out = {}
		if rev ~= "HEAD" then
			out.base = stdout(repo.git(top, {"-c", "core.quotePath=false", "diff", "--name-status", "--find-renames", rev}))
		end
		out.status = stdout(repo.git(top, {"-c", "core.quotePath=false", "status", "--porcelain", "--find-renames", "--ignored=matching", "--untracked-files=all"}))
		out.numstat = stdout(repo.git(top, {"-c", "core.quotePath=false", "diff", rev, "--numstat", "--find-renames"}))
		out.untracked = repo.untracked(top)
		M.parse(files, ignored, top, out)
	end
	return files, ignored
end

return M
