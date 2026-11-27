local repo = {}

local YIELD_LINES = 2000

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function repo.git(dir, args, env)
	local argv = {"git", "-C", dir}
	for _, arg in ipairs(args) do
		argv[#argv + 1] = arg
	end
	local result, err = qed.spawn{argv = argv, cwd = dir, env = env}
	return result or {code = -1, stdout = "", stderr = err}
end

function repo.out(dir, args)
	local result = repo.git(dir, args)
	return result.code == 0 and trim(result.stdout) or ""
end

function repo.resolve(dir, base)
	if base.tree then
		return repo.out(dir, {"rev-parse", "-q", "--verify", base.tree .. "^{tree}"})
	end
	if base.merge then
		return repo.out(dir, {"merge-base", base.ref, "HEAD"})
	end
	return repo.out(dir, {"rev-parse", "-q", "--verify", base.ref .. "^0"})
end

function repo.rev(dir, base)
	local sha = (base.ref or base.tree) and repo.resolve(dir, base) or ""
	return sha ~= "" and sha or "HEAD"
end

function repo.blob(path, base)
	local dir, rel = repo.anchor(path)
	local result = repo.git(dir, {"show", repo.rev(dir, base) .. ":./" .. rel})
	if result.code == 0 then
		return result.stdout
	end
	if result.code < 0 or result.code == 127 or result.stderr:find("not a git repository", 1, true) then
		return nil
	end
	return ""
end

-- a deleted or renamed path's own dir may be gone, so git runs from its nearest existing ancestor
function repo.anchor(path)
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

function repo.each(text)
	local next_line = text:gmatch("[^\n]+")
	local count = 0
	return function()
		count = count + 1
		if count % YIELD_LINES == 0 then
			qed.sleep(0)
		end
		return next_line()
	end
end

function repo.numstat(out, untracked)
	local added, deleted = 0, 0
	for line in repo.each(out) do
		if untracked then
			local count = line:match(":(%d+)$")
			added = added + (tonumber(count) or 0)
		else
			local added_text, deleted_text = line:match("^(%d+)\t(%d+)\t")
			if added_text then
				added, deleted = added + tonumber(added_text), deleted + tonumber(deleted_text)
			end
		end
	end
	return added, deleted
end

repo.UNTRACKED = "git ls-files -o --exclude-standard -z | xargs -0 -r grep -IcH -e '' -- 2>/dev/null"

function repo.untracked(top, env)
	local result = qed.spawn{cmd = repo.UNTRACKED, cwd = top, env = env}
	return result and result.stdout or ""
end

function repo.diffsize(top, rev, env)
	local tracked = repo.git(top, {"-c", "core.quotePath=false", "diff", rev, "--numstat", "--find-renames"}, env)
	local a1, d1 = repo.numstat(tracked.code == 0 and tracked.stdout or "", false)
	local a2 = repo.numstat(repo.untracked(top, env), true)
	return a1 + a2, d1
end

-- the checkpoint as an index: files untracked now but in the checkpoint diff as tracked, files new since it as untracked
function repo.env(top, base)
	if base.tree and base.top == top then
		return {GIT_INDEX_FILE = base.index}
	end
end

-- each snapshot gets a fresh index file: a scan's git status still writing the old one cannot undo it
local SNAPSHOT = [[
set -e
index=$(mktemp "${TMPDIR:-/tmp}/qed-checkpoint.XXXXXX")
tree=
trap '[ -n "$tree" ] || rm -f "$index"' EXIT
top=$(git rev-parse --show-toplevel)
if [ -n "$1" ]; then
	cp "$1" "$index"
	cd "$top"
	GIT_INDEX_FILE="$index" git --literal-pathspecs add -A -- "$2"
else
	real=$(git rev-parse --path-format=absolute --git-path index)
	if [ -f "$real" ]; then cp "$real" "$index"; else rm -f "$index"; fi
	cd "$top"
	GIT_INDEX_FILE="$index" git --literal-pathspecs add -A
fi
tree=$(GIT_INDEX_FILE="$index" git write-tree)
printf '%s\n%s\n%s\n' "$top" "$index" "$tree"
]]

function repo.snapshot(root, from, rel)
	local result, err = qed.spawn{argv = {"sh", "-c", SNAPSHOT, "sh", from and from.index or "", rel or ""}, cwd = root}
	if not result then
		return nil, err
	end
	local top, index, tree = result.stdout:match("^([^\n]+)\n([^\n]+)\n(%x+)\n$")
	if result.code ~= 0 or not tree then
		return nil, result.stderr:match("[^\n]+") or ("exit " .. result.code)
	end
	return {top = top, index = index, tree = tree}
end

function repo.entry(dir, rev, rel)
	local result = repo.git(dir, {"--literal-pathspecs", "ls-tree", rev, "--", rel})
	if result.code ~= 0 then
		return nil
	end
	return result.stdout:match("^%d+ (%a+) ") or false
end

function repo.lines(text)
	local out = {}
	for line in text:gmatch("[^\n]+") do
		line = trim(line)
		if line ~= "" then
			out[#out + 1] = line
		end
	end
	return out
end

return repo
