local repo = require("repo")

local picker = {}

local LOG_COUNT = 50

function picker.entries(default, refs, log, checkpoint)
	local out = {{label = "HEAD"}}
	if checkpoint then
		out[#out + 1] = {label = "Checkpoint " .. checkpoint.tree:sub(1, 7), checkpoint = true}
	end
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
	for _, branch in ipairs({"main", "master"}) do
		if repo.git(root, {"show-ref", "-q", "--verify", "refs/heads/" .. branch}).code == 0 then
			return branch
		end
	end
	return ""
end

function picker.pick(root, checkpoint)
	if repo.git(root, {"rev-parse", "--show-toplevel"}).code ~= 0 then
		return nil, "Working directory is not a git repository"
	end
	local refs = repo.lines(repo.git(root, {"for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads", "refs/remotes"}).stdout)
	local log = repo.lines(repo.git(root, {"log", "-n", tostring(LOG_COUNT), "--format=%h %s"}).stdout)
	local items = {}
	for _, entry in ipairs(picker.entries(default_branch(root), refs, log, checkpoint)) do
		items[#items + 1] = {label = entry.label, value = entry}
	end
	local item = qed.pick{items = items}
	if not item then
		return nil
	end
	local entry = item.value
	if entry.checkpoint then
		return checkpoint
	end
	if not entry.ref then
		return {}
	end
	local sha = repo.resolve(root, entry)
	if sha == "" then
		return nil, "Cannot resolve " .. entry.label
	end
	return {ref = entry.commit and sha or entry.ref, label = entry.name, merge = entry.merge or false}
end

return picker
