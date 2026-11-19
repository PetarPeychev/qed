local repo = require("repo")

local M = {}

local LOG_COUNT = 50

function M.entries(default, refs, log)
	local out = {{label = "HEAD"}}
	if default ~= "" then
		out[#out + 1] = {label = "Merge base with " .. default, ref = default, name = default .. "...", merge = true}
	end
	for _, ref in ipairs(refs) do
		if not ref:match("/HEAD$") then
			out[#out + 1] = {label = ref, ref = ref, name = ref}
		end
	end
	for _, line in ipairs(log) do
		local sha = line:match("^(%S+)")
		out[#out + 1] = {label = line, ref = sha, name = sha, commit = true}
	end
	return out
end

local function default_branch(root)
	local origin = repo.out(root, {"symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"})
	if origin ~= "" then
		return origin
	end
	for _, b in ipairs({"main", "master"}) do
		if repo.git(root, {"show-ref", "-q", "--verify", "refs/heads/" .. b}).code == 0 then
			return b
		end
	end
	return ""
end

function M.pick(root)
	if repo.git(root, {"rev-parse", "--show-toplevel"}).code ~= 0 then
		return nil, "Working directory is not a git repository"
	end
	local refs = repo.lines(repo.git(root, {"for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads", "refs/remotes"}).stdout)
	local log = repo.lines(repo.git(root, {"log", "-n", tostring(LOG_COUNT), "--format=%h %s"}).stdout)
	local items = {}
	for _, e in ipairs(M.entries(default_branch(root), refs, log)) do
		items[#items + 1] = {label = e.label, value = e}
	end
	local item = qed.pick{items = items}
	if not item then
		return nil
	end
	local e = item.value
	if not e.ref then
		return {}
	end
	local sha
	if e.merge then
		sha = repo.out(root, {"merge-base", e.ref, "HEAD"})
	else
		sha = repo.out(root, {"rev-parse", "-q", "--verify", e.ref .. "^0"})
	end
	if sha == "" then
		return nil, "Cannot resolve " .. e.label
	end
	return {ref = e.commit and sha or e.ref, label = e.name, merge = e.merge or false}
end

return M
