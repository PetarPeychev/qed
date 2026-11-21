local repo = require("repo")
local picker = require("picker")
local tree = require("tree")

local POLL_MS = 2000

local ready = false
local base = {}
local fetched = {}
local gen = {}
local stat = {branch = "", ahead = 0, behind = 0, added = 0, deleted = 0, gen = 0, known = false, sha = ""}
local scanning, dirty, job = false, false, nil
local renames = {}
local published, ft
local inrepo = false

local function fetch(b)
	local path = qed.buf.path(b)
	gen[b] = (gen[b] or 0) + 1
	local mine = gen[b]
	fetched[b] = path
	local blob
	if path ~= "" and not qed.buf.big(b) then
		blob = repo.blob(path, base)
	end
	if qed.buf.valid(b) and gen[b] == mine then
		qed.buf.set_base(b, blob, {label = ""})
	end
end

local function fetch_all()
	for _, b in ipairs(qed.buf.list()) do
		if qed.buf.valid(b) then
			fetch(b)
		end
	end
end

local function preview(path)
	return repo.blob(renames[path] or path, base)
end

local restore_path

local function push()
	if not ft then
		return
	end
	local pub = published or {paths = {}, marks = {}, empty = "Loading git status"}
	local ignored = pub.ignored or false
	-- outside a repo the nested repo search can take minutes; the walk must not wait for it
	if not ignored and not inrepo then
		ignored = {}
	end
	local ok, err = pcall(function()
		ft.set_tab{label = "Git", cmd = "Git: Changes", paths = pub.paths, virtual = pub.virtual, detail = true, preview = preview, missing = restore_path, empty = pub.empty}
		ft.set_marks(pub.marks)
		ft.set_ignored(ignored)
	end)
	if not ok then
		qed.log("file tree: " .. tostring(err), "debug")
		ft = nil
	end
end

local function attach()
	ft = qed.plugin("filetree")
	push()
end

local function stopped()
	return dirty
end

local function publish(files, ignored, full, empty)
	if full then
		qed.message(("Over %d changed files: the Git tab lists the first %d"):format(tree.MAX, tree.MAX), "warn")
	end
	local how = published and tree.compare({files = files, ignored = ignored}, published, stopped) or "paths"
	if how == nil then
		return
	end
	if how == "same" then
		if published.empty ~= empty then
			published.empty = empty
			push()
		end
		return
	end
	local view = tree.view(files, ignored, stopped)
	if not view then
		return
	end
	renames = {}
	for path, e in pairs(files) do
		renames[path] = e.from
	end
	local paths, virtual = view.changed, view.deleted
	if how == "fields" then
		paths, virtual = published.paths, published.virtual
	end
	published = {files = files, ignored = ignored, paths = paths, virtual = virtual, marks = view.marks, empty = empty}
	push()
end

local function scan()
	if scanning then
		dirty = true
		if job then
			job.cancelled = true
			if job.proc then
				job.proc:kill()
			end
		end
		return
	end
	scanning = true
	repeat
		dirty = false
		job = {}
		local ok, files, ignored, full, found, failed = pcall(tree.scan, qed.root(), base, job)
		if not ok then
			qed.log("scan: " .. tostring(files), "error")
			files = nil
		end
		if files and not dirty then
			publish(files, ignored, full, failed and "Git status failed" or found == 0 and "Not a git repository" or "No changes")
		elseif not ok and not published then
			published = {files = {}, ignored = {}, paths = {}, marks = {}, empty = "Git status failed"}
			push()
		end
	until not dirty
	scanning, job = false, nil
end

local function show()
	local icon = qed.theme.icon
	local on = stat.branch ~= ""
	qed.status.set("branch", {text = on and (icon("status_branch") .. " " .. stat.branch) or "", drop = 9, early = true})
	local ab = ""
	if on and stat.ahead > 0 then
		ab = icon("status_ahead") .. stat.ahead
	end
	if on and stat.behind > 0 then
		ab = ab .. icon("status_behind") .. stat.behind
	end
	qed.status.set("ahead_behind", {text = ab, sep = " ", drop = 7, early = true})
	local label = on and base.ref and (icon("status_diff_base") .. base.label) or ""
	qed.status.set("base", {text = label, drop = 8, early = true})
	local diff = ""
	if on and (stat.added > 0 or stat.deleted > 0) then
		diff = {{text = "+" .. stat.added, color = "git_added"}, {text = " -" .. stat.deleted, color = "git_deleted"}}
	end
	qed.status.set("diff", {text = diff, drop = 6, early = true})
end

local function poll()
	stat.gen = stat.gen + 1
	local mine = stat.gen
	local root = qed.root()
	local branch, ahead, behind, sha, added, deleted = "", 0, 0, "", 0, 0
	local top = repo.out(root, {"rev-parse", "--show-toplevel"})
	if top ~= "" then
		branch = repo.out(root, {"symbolic-ref", "--short", "-q", "HEAD"})
		if branch == "" then
			branch = repo.out(root, {"rev-parse", "--short", "HEAD"})
		end
		local b, a = repo.out(root, {"rev-list", "--left-right", "--count", "@{u}...HEAD"}):match("^(%d+)%s+(%d+)$")
		behind, ahead = tonumber(b) or 0, tonumber(a) or 0
		local rev = repo.rev(top, base)
		sha = repo.out(root, {"rev-parse", "-q", "--verify", rev})
		added, deleted = repo.diffsize(top, rev)
	end
	if mine ~= stat.gen then
		return
	end
	local moved = stat.known and sha ~= stat.sha
	stat.known, stat.sha = true, sha
	if moved then
		qed.log("diff base moved to " .. sha, "debug")
		fetch_all()
		scan()
	end
	if moved or branch ~= stat.branch or ahead ~= stat.ahead or behind ~= stat.behind or added ~= stat.added or deleted ~= stat.deleted then
		qed.log(("branch %s ahead %d behind %d diff +%d -%d"):format(branch, ahead, behind, added, deleted), "debug")
	end
	stat.branch, stat.ahead, stat.behind, stat.added, stat.deleted = branch, ahead, behind, added, deleted
	show()
end

local function tick()
	for _, b in ipairs(qed.buf.list()) do
		if qed.buf.valid(b) and fetched[b] ~= qed.buf.path(b) then
			fetch(b)
		end
	end
	poll()
end

local function restart(new)
	base = new
	stat.known = false
	show()
	fetch_all()
	poll()
end

local function set_base()
	local new, err = picker.pick(qed.root())
	if err then
		qed.message(err, "error")
	end
	if not new then
		return
	end
	qed.message("Diff base: " .. (new.ref and new.label or "HEAD"))
	restart(new)
	scan()
end

restore_path = function(path)
	if not path or qed.fs.exists(path) then
		qed.message("Not a deleted file")
		return
	end
	local dir, rel = repo.anchor(path)
	local rev = repo.rev(dir, base)
	if repo.out(dir, {"cat-file", "-t", rev .. ":./" .. rel}) ~= "blob" then
		qed.message("Not a deleted file")
		return
	end
	local name = qed.path.base(path)
	local choice = qed.confirm(("Restore %s from %s?"):format(name, base.ref and base.label or "HEAD"), {"Cancel", "Restore"})
	if choice ~= 2 then
		return
	end
	-- a staged deletion has no index entry; restoring the worktree alone would leave the file untracked
	local tracked = repo.git(dir, {"--literal-pathspecs", "ls-files", "--error-unmatch", "--", rel}).code == 0
	local args = {"--literal-pathspecs", "restore", "--source=" .. rev, "--worktree", "--", rel}
	if not tracked then
		table.insert(args, 4, "--staged")
	end
	if repo.git(dir, args).code ~= 0 then
		qed.message("Restore failed: " .. name, "error")
		return
	end
	qed.message("Restored " .. name)
	qed.defer(0, scan)
end

local function when()
	return ready
end

return {
	setup = function()
		qed.meta{description = "Diff base, gutter marks and status for git repos"}
		show()
		qed.command{name = "Set Diff Base", run = set_base, when = when}
		qed.command{name = "Restore File", scope = "filetree", run = function(ctx) restore_path(ctx.file) end, when = when}
		qed.command{name = "Changes", key = "Alt+g", welcome = true, when = function() return ready and ft ~= nil end, run = function()
			ft.open("Git")
		end}
		qed.on("startup", function()
			ready = repo.git(qed.root(), {"--version"}).code == 0
			if not ready then
				return
			end
			inrepo = repo.out(qed.root(), {"rev-parse", "--show-toplevel"}) ~= ""
			attach()
			fetch_all()
			poll()
			qed.every(POLL_MS, tick)
			scan()
		end)
		for _, ev in ipairs({"buf_open", "buf_save", "buf_reload"}) do
			qed.on(ev, function(b)
				if ready and qed.buf.valid(b) then
					fetch(b)
				end
			end)
		end
		qed.on("buf_close", function(b)
			fetched[b], gen[b] = nil, nil
		end)
		qed.on("root_changed", function()
			if ready then
				published, renames = nil, {}
				inrepo = repo.out(qed.root(), {"rev-parse", "--show-toplevel"}) ~= ""
				push()
				restart({})
				scan()
			end
		end)
		qed.on("theme_changed", show)
		qed.on("filetree:refresh", function()
			if ready then
				scan()
			end
		end)
		qed.on("plugin_loaded", function(id)
			if id == "filetree" and ready then
				attach()
			end
		end)
		qed.on("plugin_unloaded", function(id)
			if id == "filetree" then
				ft = nil
			end
		end)
	end,
}
