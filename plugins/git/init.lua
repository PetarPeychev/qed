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
local checkpoint

local function fetch(buffer)
	local path = buffer:path()
	gen[buffer] = (gen[buffer] or 0) + 1
	local mine = gen[buffer]
	fetched[buffer] = path
	local blob
	if path ~= "" and not buffer:big() then
		blob = repo.blob(path, base)
	end
	if buffer:valid() and gen[buffer] == mine then
		buffer:set_base(blob, {label = ""})
	end
end

local function fetch_all()
	for _, buffer in ipairs(qed.buf.list()) do
		if buffer:valid() then
			fetch(buffer)
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
	for path, entry in pairs(files) do
		renames[path] = entry.from
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
	local label = on and base.label and (icon("status_diff_base") .. base.label) or ""
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
		local behind_text, ahead_text = repo.out(root, {"rev-list", "--left-right", "--count", "@{u}...HEAD"}):match("^(%d+)%s+(%d+)$")
		behind, ahead = tonumber(behind_text) or 0, tonumber(ahead_text) or 0
		local rev = repo.rev(top, base)
		sha = repo.out(root, {"rev-parse", "-q", "--verify", rev})
		added, deleted = repo.diffsize(top, rev, rev ~= "HEAD" and repo.env(top, base) or nil)
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
	for _, buffer in ipairs(qed.buf.list()) do
		if buffer:valid() and fetched[buffer] ~= buffer:path() then
			fetch(buffer)
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
	local new, err = picker.pick(qed.root(), checkpoint)
	if err then
		qed.message(err, "error")
	end
	if not new then
		return
	end
	qed.message("Diff base: " .. (new.label or "HEAD"))
	restart(new)
	scan()
end

local function drop_checkpoint()
	if checkpoint then
		qed.fs.remove(checkpoint.index)
		checkpoint = nil
	end
end

local function adopt(snap)
	local stale = checkpoint and checkpoint.index
	checkpoint = checkpoint or {label = "checkpoint"}
	checkpoint.top, checkpoint.index, checkpoint.tree = snap.top, snap.index, snap.tree
	if stale then
		qed.fs.remove(stale)
	end
	restart(checkpoint)
	scan()
end

local function take_checkpoint()
	local root = qed.root()
	if repo.out(root, {"rev-parse", "--show-toplevel"}) == "" then
		qed.message("Working directory is not a git repository", "error")
		return
	end
	local snap, err = repo.snapshot(root)
	if not snap then
		qed.message("Checkpoint failed: " .. tostring(err), "error")
		return
	end
	if root ~= qed.root() then
		qed.fs.remove(snap.index)
		return
	end
	adopt(snap)
	qed.message("Checkpoint " .. snap.tree:sub(1, 7))
end

local function accept_path(path)
	local from = checkpoint
	if not path or not from or base ~= from or path:sub(1, #from.top + 1) ~= from.top .. "/" then
		return
	end
	local tree_before = from.tree
	local snap, err = repo.snapshot(qed.root(), from, path:sub(#from.top + 2))
	if not snap then
		qed.message("Accept failed: " .. tostring(err), "error")
		return
	end
	if checkpoint ~= from or from.tree ~= tree_before then
		qed.fs.remove(snap.index)
		return
	end
	adopt(snap)
	qed.message("Accepted " .. qed.path.base(path))
end

local function buffers_at(path)
	local out = {}
	for _, buffer in ipairs(qed.buf.list()) do
		if buffer:valid() and buffer:path() == path then
			out[#out + 1] = buffer
		end
	end
	return out
end

local function unsaved(path)
	for _, buffer in ipairs(buffers_at(path)) do
		if buffer:modified() then
			return true
		end
	end
	return false
end

restore_path = function(path)
	if not path then
		return
	end
	local name = qed.path.base(path)
	local label = base.label or "HEAD"
	local head = not (base.ref or base.tree)
	local dir, rel = repo.anchor(path)
	local rev = head and "HEAD" or repo.resolve(dir, base)
	if rev == "" then
		qed.message("Cannot resolve " .. label, "error")
		return
	end
	local kind = repo.entry(dir, rev, rel)
	if kind == nil then
		qed.message("Restore failed: cannot read " .. label, "error")
		return
	end
	local st = qed.fs.stat(path)
	local present = qed.fs.exists(path, {follow = false})
	if (kind and kind ~= "blob") or (st and st.type == "dir") then
		qed.message("Not a file: " .. name)
		return
	end
	if not kind and not present then
		qed.message("Nothing to restore: " .. name)
		return
	end
	if unsaved(path) then
		qed.message("Unsaved edits in " .. name, "warn")
		return
	end
	local question, verb
	if not kind then
		question, verb = ("Delete %s? It is not in %s"):format(name, label), "Delete"
	elseif present then
		question, verb = ("Restore %s to %s?"):format(name, label), "Restore"
	else
		question, verb = ("Restore %s from %s?"):format(name, label), "Restore"
	end
	if qed.confirm{question = question, choices = {"Cancel", verb}} ~= 2 then
		return
	end
	if unsaved(path) then
		qed.message("Unsaved edits in " .. name, "warn")
		return
	end
	-- against HEAD the index is reset too, or a staged change keeps the file listed
	local tracked = head and repo.git(dir, {"--literal-pathspecs", "ls-files", "--error-unmatch", "--", rel}).code == 0
	if kind or tracked then
		local args = {"--literal-pathspecs", "restore", "--source=" .. rev, "--worktree", "--", rel}
		if head then
			table.insert(args, 4, "--staged")
		end
		if repo.git(dir, args).code ~= 0 then
			qed.message("Restore failed: " .. name, "error")
			return
		end
	else
		local ok, err = qed.fs.remove(path)
		if not ok then
			qed.message(("Delete failed: %s: %s"):format(name, tostring(err)), "error")
			return
		end
	end
	if not kind then
		for _, buffer in ipairs(buffers_at(path)) do
			qed.close(buffer)
		end
	end
	qed.message((kind and "Restored " or "Deleted ") .. name)
	qed.defer(0, scan)
end

local function when()
	return ready
end

local function on_git_tab()
	if not (ready and ft) then
		return false
	end
	local ok, state = pcall(ft.state)
	return ok and state ~= nil and state.tab == "Git"
end

local function git_tab_path()
	if not on_git_tab() then
		return nil
	end
	local selection = ft.selection()
	return selection and selection.item and selection.item.path
end

local function on_checkpoint()
	return checkpoint ~= nil and base == checkpoint
end

return {
	setup = function()
		qed.meta{description = "Diff base, gutter marks and status for git repos"}
		show()
		qed.command{id = "set_diff_base", name = "Set Diff Base", run = set_base, when = when}
		qed.command{id = "checkpoint", name = "Checkpoint", welcome = true, run = take_checkpoint, when = when}
		qed.command{id = "restore_file", name = "Restore File", scope = "filetree", run = function()
			restore_path(git_tab_path())
		end, when = function() return git_tab_path() ~= nil end}
		qed.command{id = "accept_file", name = "Accept File", scope = "filetree", run = function()
			accept_path(git_tab_path())
		end, when = function() return on_checkpoint() and git_tab_path() ~= nil end}
		qed.command{id = "accept_all", name = "Accept All", scope = "filetree", run = function()
			if on_checkpoint() then
				take_checkpoint()
			end
		end, when = function() return on_checkpoint() and on_git_tab() end}
		qed.command{id = "changes", name = "Changes", key = "Alt+g", welcome = true, when = function() return ready and ft ~= nil end, run = function()
			ft.open("Git")
		end}
		qed:on("startup", function()
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
			qed:on(ev, function(buffer)
				if ready and buffer:valid() then
					fetch(buffer)
				end
			end)
		end
		qed:on("buf_close", function(buffer)
			fetched[buffer], gen[buffer] = nil, nil
		end)
		qed:on("root_changed", function()
			if ready then
				published, renames = nil, {}
				inrepo = repo.out(qed.root(), {"rev-parse", "--show-toplevel"}) ~= ""
				push()
				drop_checkpoint()
				restart({})
				scan()
			end
		end)
		qed:on("quit", drop_checkpoint)
		qed:on("theme_changed", show)
		qed:on("filetree:refresh", function()
			if ready then
				scan()
			end
		end)
		qed:on("plugin_loaded", function(id)
			if id == "filetree" and ready then
				attach()
			end
		end)
		qed:on("plugin_unloaded", function(id)
			if id == "filetree" then
				ft = nil
			end
		end)
	end,
}
