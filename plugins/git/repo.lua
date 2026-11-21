local M = {}

local YIELD_LINES = 2000

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.git(dir, args)
	local argv = {"git", "-C", dir}
	for _, a in ipairs(args) do
		argv[#argv + 1] = a
	end
	local ok, r = pcall(qed.spawn, {argv = argv, cwd = dir})
	if not ok then
		return {code = -1, stdout = "", stderr = tostring(r)}
	end
	return r
end

function M.out(dir, args)
	local r = M.git(dir, args)
	return r.code == 0 and trim(r.stdout) or ""
end

function M.resolve(dir, base)
	if base.merge then
		return M.out(dir, {"merge-base", base.ref, "HEAD"})
	end
	return M.out(dir, {"rev-parse", "-q", "--verify", base.ref .. "^0"})
end

function M.rev(dir, base)
	local sha = base.ref and M.resolve(dir, base) or ""
	return sha ~= "" and sha or "HEAD"
end

function M.blob(path, base)
	local dir, rel = M.anchor(path)
	local r = M.git(dir, {"show", M.rev(dir, base) .. ":./" .. rel})
	if r.code == 0 then
		return r.stdout
	end
	if r.code < 0 or r.code == 127 or r.stderr:find("not a git repository", 1, true) then
		return nil
	end
	return ""
end

-- a deleted or renamed path's own dir may be gone, so git runs from its nearest existing ancestor
function M.anchor(path)
	local dir = qed.path.dir(path)
	while true do
		local st = qed.fs.stat(dir)
		if st and st.type == "dir" then
			break
		end
		local up = qed.path.dir(dir)
		if up == dir then
			break
		end
		dir = up
	end
	return dir, path:sub(#dir + 2)
end

function M.each(s)
	local next_line = s:gmatch("[^\n]+")
	local n = 0
	return function()
		n = n + 1
		if n % YIELD_LINES == 0 then
			qed.sleep(0)
		end
		return next_line()
	end
end

function M.numstat(out, untracked)
	local added, deleted = 0, 0
	for line in M.each(out) do
		if untracked then
			local n = line:match(":(%d+)$")
			added = added + (tonumber(n) or 0)
		else
			local a, d = line:match("^(%d+)\t(%d+)\t")
			if a then
				added, deleted = added + tonumber(a), deleted + tonumber(d)
			end
		end
	end
	return added, deleted
end

M.UNTRACKED = "git ls-files -o --exclude-standard -z | xargs -0 -r grep -IcH -e '' -- 2>/dev/null"

function M.untracked(top)
	local ok, r = pcall(qed.spawn, {cmd = M.UNTRACKED, cwd = top})
	return ok and r.stdout or ""
end

function M.diffsize(top, rev)
	local tracked = M.git(top, {"-c", "core.quotePath=false", "diff", rev, "--numstat", "--find-renames"})
	local a1, d1 = M.numstat(tracked.code == 0 and tracked.stdout or "", false)
	local a2 = M.numstat(M.untracked(top), true)
	return a1 + a2, d1
end

function M.lines(s)
	local out = {}
	for line in s:gmatch("[^\n]+") do
		line = trim(line)
		if line ~= "" then
			out[#out + 1] = line
		end
	end
	return out
end

return M
