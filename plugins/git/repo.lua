local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

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

-- resolved per call so a moved branch is followed; a repo lacking the ref falls back to HEAD
function M.rev(dir, base)
	if not base.ref then
		return "HEAD"
	end
	local sha
	if base.merge then
		sha = M.out(dir, {"merge-base", base.ref, "HEAD"})
	else
		sha = M.out(dir, {"rev-parse", "-q", "--verify", base.ref .. "^0"})
	end
	return sha ~= "" and sha or "HEAD"
end

function M.blob(path, base)
	local dir = qed.path.dir(path)
	if M.git(dir, {"rev-parse", "--show-toplevel"}).code ~= 0 then
		return nil
	end
	local r = M.git(dir, {"show", M.rev(dir, base) .. ":./" .. qed.path.base(path)})
	return r.code == 0 and r.stdout or ""
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

function M.numstat(out, untracked)
	local added, deleted = 0, 0
	for line in out:gmatch("[^\n]+") do
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

-- git diff skips untracked files, so grep counts their lines (-I: binaries count 0)
function M.diffsize(top, rev)
	local tracked = M.git(top, {"-c", "core.quotePath=false", "diff", rev, "--numstat", "--find-renames"})
	local untracked = qed.spawn{cmd = "git ls-files -o --exclude-standard -z | xargs -0 -r grep -IcH -e '' -- 2>/dev/null", cwd = top}
	local a1, d1 = M.numstat(tracked.code == 0 and tracked.stdout or "", false)
	local a2 = M.numstat(untracked.stdout, true)
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
