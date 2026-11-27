local repo = require("repo")

local tree = {}

local RANK = {added = 1, modified = 2, deleted = 3}
local BAR = {added = "git_added", modified = "git_modified", deleted = "git_deleted"}
local BAR_RANK = {git_added = 1, git_modified = 2, git_deleted = 3}

local SPACE = {[9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true}

-- almost every path needs nothing stripped, so the gsubs run only when an end byte says so
local function clean(text)
	local first, last = text:byte(1), text:byte(-1)
	if not (SPACE[first] or SPACE[last] or first == 34 or last == 34 or last == 47) then
		return text
	end
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	return (text:gsub('^"', ""):gsub('"$', ""):gsub("/$", ""))
end

function tree.name_status_line(line)
	local parts = {}
	for field in (line .. "\t"):gmatch("([^\t]*)\t") do
		parts[#parts + 1] = field
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

function tree.porcelain_line(line)
	if #line < 4 then
		return nil
	end
	local index_status, tree_status, rel = line:byte(1), line:byte(2), line:sub(4)
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
	if index_status == 63 and tree_status == 63 then
		return path, "added"
	elseif index_status == 33 and tree_status == 33 then
		return path, "ignored"
	elseif index_status == 65 and tree_status == 68 then
		return nil
	elseif index_status == 82 and tree_status == 68 then
		return from, "deleted"
	elseif index_status == 68 or tree_status == 68 then
		return path, "deleted"
	elseif index_status == 82 then
		return path, "modified", from
	elseif index_status == 65 or tree_status == 65 then
		return path, "added"
	end
	return path, "modified"
end

-- a rename prints `old => new` or `dir/{old => new}/f`; sizes key on the new path
function tree.numstat_path(text)
	if text:byte(1) ~= 34 and text:byte(-1) ~= 34 and not text:find(" => ", 1, true) then
		return text
	end
	local unquoted = text:gsub('^"', ""):gsub('"$', "")
	local arrow = unquoted:find(" => ", 1, true)
	if not arrow then
		return unquoted
	end
	local before, after = unquoted:sub(1, arrow - 1), unquoted:sub(arrow + 4)
	local lb = before:match(".*(){")
	local rb = after:find("}", 1, true)
	if not lb or not rb then
		return after
	end
	local joined = before:sub(1, lb - 1) .. after:sub(1, rb - 1) .. after:sub(rb + 1)
	return (joined:gsub("//", "/"):gsub("^/+", ""))
end

function tree.numstat_line(line, untracked)
	if untracked then
		local path, count = line:match("^(.+):(%d+)$")
		if not path then
			return nil
		end
		return path, tonumber(count), 0
	end
	local added, deleted, rest = line:match("^(%d+)\t(%d+)\t(.*)$")
	if not added then
		return nil
	end
	return tree.numstat_path(rest), tonumber(added), tonumber(deleted)
end

tree.MAX = 50000

local function add(st, rel, mark, from)
	local path = st.under .. rel
	if mark == "deleted" and qed.fs.exists(path) then
		mark = "modified"
	end
	local entry = st.files[path]
	if not entry then
		if st.count >= tree.MAX then
			st.full = true
			return
		end
		st.count = st.count + 1
		entry = {mark = mark}
		st.files[path] = entry
		st.byrel[rel] = entry
	elseif RANK[mark] > RANK[entry.mark] then
		entry.mark = mark
	end
	if from and not entry.from then
		entry.from = st.top .. "/" .. from
	end
end

local function parse_base(st, text)
	st.based = true
	for line in repo.each(text) do
		local rel, mark, from = tree.name_status_line(line)
		if rel then
			add(st, rel, mark, from)
		end
	end
end

local function parse_status(st, text)
	for line in repo.each(text) do
		local rel, mark, from = tree.porcelain_line(line)
		if mark == "ignored" then
			if #st.ignored < tree.MAX then
				st.ignored[#st.ignored + 1] = st.top .. "/" .. rel
			end
		elseif rel and not (st.based and line:sub(1, 2) ~= "??") then
			add(st, rel, mark, from)
		end
	end
end

local function parse_sizes(st, text, untracked)
	for line in repo.each(text) do
		local rel, added, deleted = tree.numstat_line(line, untracked)
		-- keyed by the short relative path: no absolute path is built or hashed per line
		if rel and (added > 0 or deleted > 0) then
			local entry = st.byrel[rel] or st.files[st.under .. rel]
			if entry and not entry.added then
				entry.added, entry.removed = added, deleted
			end
		end
	end
end

local function state(files, ignored, top)
	return {files = files, ignored = ignored, top = top, under = top .. "/", count = 0, byrel = {}, based = false, full = false}
end

function tree.parse(files, ignored, top, out)
	local st = state(files, ignored, top)
	if out.base then
		parse_base(st, out.base)
	end
	parse_status(st, out.status)
	parse_sizes(st, out.numstat, false)
	parse_sizes(st, out.untracked, true)
	return st.full
end

local function run(job, spec, partial)
	if job.cancelled then
		return nil
	end
	local proc = qed.spawn_bg(spec)
	if not proc then
		return ""
	end
	job.proc = proc
	local result = proc:wait()
	job.proc = nil
	if job.cancelled then
		return nil
	end
	return (result.code == 0 or partial) and result.stdout or "", result.code == 0
end

local function git(job, top, args, env)
	local argv = {"git", "-C", top, "-c", "core.quotePath=false"}
	for _, arg in ipairs(args) do
		argv[#argv + 1] = arg
	end
	return run(job, {argv = argv, cwd = top, env = env})
end

-- pruned at each repo so an ignored node_modules is never walked; find fails on any unreadable dir but its hits still count
local function repos(root, job)
	local top = repo.out(root, {"rev-parse", "--show-toplevel"})
	if top ~= "" then
		return {top}
	end
	local found = run(job, {argv = {"find", root, "-type", "d", "-exec", "sh", "-c", 'test -e "$0/.git"', "{}", ";", "-prune", "-print"}}, true)
	local out = {}
	for line in repo.each(found or "") do
		out[#out + 1] = line
	end
	return out
end

function tree.scan(root, base, job)
	local files, ignored, full, count, failed = {}, {}, false, 0, false
	local tops = repos(root, job)
	for _, top in ipairs(tops) do
		local st = state(files, ignored, top)
		st.count = count
		local rev = repo.rev(top, base)
		local env = rev ~= "HEAD" and repo.env(top, base) or nil
		local text
		if rev ~= "HEAD" then
			text = git(job, top, {"diff", "--name-status", "--find-renames", rev}, env)
			if not text then
				return nil
			end
			parse_base(st, text)
		end
		local ok
		text, ok = git(job, top, {"status", "--porcelain", "--find-renames", "--ignored=matching", "--untracked-files=all"}, env)
		if not text then
			return nil
		end
		failed = failed or not ok
		parse_status(st, text)
		text = git(job, top, {"diff", rev, "--numstat", "--find-renames"}, env)
		if not text then
			return nil
		end
		parse_sizes(st, text, false)
		text = run(job, {cmd = repo.UNTRACKED, cwd = top, env = env})
		if not text then
			return nil
		end
		parse_sizes(st, text, true)
		full, count = full or st.full, st.count
	end
	if job.cancelled then
		return nil
	end
	return files, ignored, full, #tops, failed
end

local CHUNK = 2000

local function tick(i, stop)
	if i % CHUNK == 0 then
		qed.sleep(0)
		return stop()
	end
	return false
end

local function parent(path)
	return path:match("^(.+)/[^/]*$") or path
end

function tree.compare(old, new, stop)
	local count, fields = 0, false
	for path, file in pairs(old.files) do
		local other = new.files[path]
		if not other or (other.mark == "deleted") ~= (file.mark == "deleted") then
			return "paths"
		end
		fields = fields or other.mark ~= file.mark or other.from ~= file.from or other.added ~= file.added or other.removed ~= file.removed
		count = count + 1
		if tick(count, stop) then
			return nil
		end
	end
	for _ in pairs(new.files) do
		count = count - 1
	end
	if count ~= 0 then
		return "paths"
	end
	fields = fields or #old.ignored ~= #new.ignored
	for i, ignored_path in ipairs(old.ignored) do
		fields = fields or new.ignored[i] ~= ignored_path
	end
	return fields and "fields" or "same"
end

function tree.view(files, ignored, stop)
	local marks, changed, gone = {}, {}, {}
	local under = qed.root() .. "/"
	local function set(path, mark)
		local entry = marks[path]
		if not entry then
			marks[path] = {bar = BAR[mark]}
			return false
		end
		if BAR_RANK[entry.bar] >= RANK[mark] then
			return true
		end
		entry.bar = BAR[mark]
		return false
	end
	local count = 0
	for path, file in pairs(files) do
		set(path, file.mark)
		changed[#changed + 1] = path
		if file.mark == "deleted" then
			gone[#gone + 1] = path
		end
		local up, ancestor = file.mark == "deleted" and "modified" or file.mark, path
		-- every ancestor at least as long as under shares the prefix, so it is checked once
		local inside = ancestor:find(under, 1, true) == 1
		while inside and #ancestor >= #under do
			local np = parent(ancestor)
			if np == ancestor or set(np, up) then
				break
			end
			ancestor = np
		end
		count = count + 1
		if tick(count, stop) then
			return nil
		end
	end
	local icon = qed.theme.icon("tree_renamed")
	for path, file in pairs(files) do
		local entry = marks[path]
		if entry.bar == "git_deleted" and not qed.fs.exists(path, {follow = false}) then
			entry.fg = "git_deleted"
		end
		if file.from then
			entry.suffix = icon .. " " .. (qed.path.rel(file.from, qed.path.dir(path)) or file.from)
		end
		if (file.added or 0) > 0 or (file.removed or 0) > 0 then
			entry.added, entry.removed = file.added or 0, file.removed or 0
		end
		count = count + 1
		if tick(count, stop) then
			return nil
		end
	end
	for _, path in ipairs(ignored) do
		local entry = marks[path] or {}
		entry.dim = true
		marks[path] = entry
	end
	return {marks = marks, changed = changed, deleted = gone}
end

return tree
