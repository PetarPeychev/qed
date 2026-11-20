local TABS = {
	{label = "All", cmd = "File Tree: All"},
	{label = "Open", cmd = "File Tree: Open"},
	{label = "Changed", cmd = "File Tree: Changed"},
	{label = "Unsaved", cmd = "File Tree: Unsaved"},
}
local HINTS = {{label = "←→ tabs"}, {label = "↑↓ select"}, {label = "Shift+↑↓ extend"}, {label = "commands", cmd = "Command Palette"}}
local RANK = {added = 1, modified = 2, deleted = 3}
local MAX = 500

local v, walk, auto
local scope = "All"
local show = {}
local clip, clip_cut = {}, false
local mode, target
local wanted
local st = {provider = false, ignored = {}}
local cache = {}

local function say(text, level)
	qed.message(text, level)
end

local function parent(p)
	return p:match("^(.+)/[^/]*$") or p
end

local function deleted(path)
	local f = st.files and st.files[path]
	return f ~= nil and f.mark == "deleted" and not qed.fs.exists(path)
end

-- a deleted file shows as modified on its ancestors
local function propagate(files)
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
	for path, f in pairs(files) do
		set(path, f.mark)
		changed[#changed + 1] = path
		if f.mark == "deleted" then
			gone[#gone + 1] = path
		end
		local up, p = f.mark == "deleted" and "modified" or f.mark, path
		while p:sub(1, #under) == under do
			local np = parent(p)
			if np == p or set(np, up) then
				break
			end
			p = np
		end
	end
	return status, changed, gone
end

local function load_state()
	local s = qed.filetree.state()
	st = {provider = s.provider, files = s.files, ignored = s.ignored or {}}
	st.status, st.changed, st.deleted = propagate(s.files or {})
	cache = {}
end

local function marks(changed_tab)
	local key = changed_tab and "changed" or "all"
	if cache[key] then
		return cache[key]
	end
	local m = {}
	local icon = qed.theme.icon("tree_renamed")
	for path, mark in pairs(st.status) do
		local e = {bar = "git_" .. mark}
		if mark == "deleted" and not qed.fs.exists(path) then
			e.fg = "git_deleted"
		end
		local f = changed_tab and st.files[path]
		if f then
			if f.from then
				e.suffix = icon .. " " .. (qed.path.rel(f.from) or f.from)
			end
			if (f.added or 0) > 0 or (f.removed or 0) > 0 then
				e.added, e.removed = f.added or 0, f.removed or 0
			end
		end
		m[path] = e
	end
	for _, path in ipairs(st.ignored) do
		local e = m[path] or {}
		e.dim = true
		m[path] = e
	end
	cache[key] = m
	return m
end

local function tabs()
	local out, at = {}, 1
	for _, t in ipairs(TABS) do
		if t.label ~= "Changed" or st.provider then
			out[#out + 1] = t
			if t.label == scope then
				at = #out
			end
		end
	end
	return out, at
end

local function chips()
	if scope == "All" then
		return {{label = "ignored", cmd = "File Tree: Toggle Ignored", on = show.ignored}, {label = "dotfiles", cmd = "File Tree: Toggle Dotfiles", on = show.dotfiles}}
	elseif scope == "Changed" then
		return {{label = "diff", cmd = "File Tree: Toggle Diff", on = show.diff}}
	end
	return {}
end

local function ignore_push()
	-- a provider that has not pushed yet holds the walk back: it would descend into ignored dirs
	if st.provider and not st.files then
		walk:ignore(false)
	else
		walk:ignore(st.ignored)
	end
end

local function walk_new()
	walk = qed.fs.walk{dotfiles = show.dotfiles, ignored = show.ignored}
	ignore_push()
end

local function source()
	if scope == "All" then
		return walk
	elseif scope == "Changed" then
		local h = walk:within(st.changed)
		return #st.deleted > 0 and h:union(st.deleted) or h
	end
	local paths = {}
	for _, b in ipairs(qed.buf.list()) do
		local p = qed.buf.path(b)
		if p ~= "" and (scope == "Open" or qed.buf.modified(b)) and qed.fs.exists(p) then
			paths[#paths + 1] = p
		end
	end
	return walk:within(paths)
end

local function preview_show(path)
	local s = qed.filetree.state()
	if s.base_path ~= path then
		return false
	end
	if s.base then
		v:preview{path = path, base = s.base, diff_only = show.diff}
	else
		v:preview{path = path}
	end
	return true
end

local function preview_changed(item, blank)
	if not v or scope ~= "Changed" then
		return
	end
	if not item or item.dir or not item.path then
		wanted = nil
		v:preview(false)
		return
	end
	wanted = item.path
	if preview_show(item.path) then
		return
	end
	if blank then
		v:preview(false)
	end
	if not qed.filetree.request("preview", item.path) then
		v:preview{path = item.path}
	end
end

local function sync(blank)
	if scope == "Changed" and not st.provider then
		scope = "All"
	end
	local _, at = tabs()
	v:tab(at)
	v:set(source())
	v:marks(marks(scope == "Changed"), {replace = true})
	v:footer{chips = chips()}
	if scope ~= "Changed" then
		auto = true
		v:preview("auto")
		return
	end
	if auto then
		auto = false
		v:preview(false)
	end
	preview_changed(v:select(), blank)
end

local function refresh()
	qed.filetree.request("refresh")
end

local function reveal(path)
	refresh()
	if v then
		v:reveal(path)
	end
end

local open

local handlers = {
	activate = function(view, items)
		if #items > 1 then
			local paths = {}
			for _, it in ipairs(items) do
				if not it.dir and not deleted(it.path) then
					paths[#paths + 1] = it.path
				end
			end
			if #paths == 0 then
				return
			end
			view:close()
			for _, p in ipairs(paths) do
				qed.open(p)
			end
			return
		end
		local it = items[1]
		if not it or it.dir then
			return
		end
		if deleted(it.path) then
			if not qed.filetree.request("open_deleted") then
				say("Deleted file")
			end
			return
		end
		view:close()
		qed.open(it.path)
	end,
	tab = function(_, i)
		scope = tabs()[i].label
		sync(true)
	end,
	change = function(_, item)
		if scope == "Changed" then
			qed.sleep(80)
			preview_changed(item, true)
		end
	end,
	submit = function(_, text)
		local m, at = mode, target
		mode, target = nil, nil
		if not m or not text or not at then
			return
		end
		local name = text:gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			say("Empty name", "error")
			return
		end
		if m == "rename" then
			local full = qed.path.join(qed.path.dir(at), name)
			if full == at then
				return
			end
			local ok, err = qed.fs.rename(at, full)
			if not ok then
				say(err == "exists" and "Already exists" or "Rename failed", "error")
				return
			end
			reveal(full)
			return
		end
		local dir = name:sub(-1) == "/"
		local clean = name:gsub("/+$", "")
		if clean == "" then
			say("Empty name", "error")
			return
		end
		local full = qed.path.join(at, clean)
		if qed.fs.exists(full) then
			say("Already exists", "error")
			return
		end
		if not (dir and qed.fs.mkdir(full) or not dir and qed.fs.write(full, "")) then
			say("Create failed", "error")
			return
		end
		reveal(full)
	end,
	close = function(view)
		if v == view then
			v, mode, target, wanted = nil, nil, nil, nil
		end
	end,
}

open = function(tab)
	if qed.filetree.state().provider ~= st.provider then
		load_state()
	end
	scope = tab == "Changed" and not st.provider and "All" or tab
	mode, target, wanted = nil, nil, nil
	auto = scope ~= "Changed"
	walk_new()
	local t, at = tabs()
	local view = qed.ui.open{
		id = "filetree",
		place = "split",
		size = "split:tree",
		scope = "filetree",
		toggle = false,
		jump_closes = true,
		tabs = t,
		tab = at,
		fields = {{text = "", count = true, hint = "type to filter", esc_clears = true}},
		list = {items = source(), tree = true, multi = true, max = MAX},
		preview = "auto",
		footer = {hints = HINTS, chips = chips()},
		on = handlers,
	}
	if not view then
		return
	end
	v = view
	v:marks(marks(scope == "Changed"), {replace = true})
	refresh()
	if scope == "Changed" then
		v:preview(false)
		preview_changed(v:select(), true)
	end
end

local function reopen()
	local s = scope
	v:close()
	v = nil
	open(s)
end

local function cursor(ctx)
	for _, it in ipairs(ctx.items or {}) do
		if it.path == ctx.file then
			return it
		end
	end
end

local function target_dir(ctx)
	local it = cursor(ctx)
	if not it then
		return qed.root()
	end
	return it.dir and it.path or qed.path.dir(it.path)
end

local function gone(items)
	for _, it in ipairs(items) do
		if not qed.fs.exists(it.path) then
			say("Deleted file: restore it first")
			return true
		end
	end
	return false
end

local function capture(ctx, cut)
	local items = ctx.items or {}
	if gone(items) or #items == 0 then
		return
	end
	clip, clip_cut = {}, cut
	for _, it in ipairs(items) do
		clip[#clip + 1] = it.path
	end
	local verb = cut and "Cut" or "Copied"
	if #clip == 1 then
		say(verb .. " " .. qed.path.base(clip[1]))
	else
		say(("%s %d items"):format(verb, #clip))
	end
end

local function dest_path(dir, name)
	local full = qed.path.join(dir, name)
	if not qed.fs.exists(full) then
		return full
	end
	local stem, ext = name, ""
	local dot = name:match(".*()%.")
	if dot and dot > 1 then
		stem, ext = name:sub(1, dot - 1), name:sub(dot)
	end
	for i = 1, 999 do
		full = qed.path.join(dir, i == 1 and ("%s (copy)%s"):format(stem, ext) or ("%s (copy %d)%s"):format(stem, i, ext))
		if not qed.fs.exists(full) then
			return full
		end
	end
	return full
end

local function paste(ctx)
	if #clip == 0 then
		say("Nothing to paste")
		return
	end
	local dir = target_dir(ctx)
	local s = qed.fs.stat(dir)
	if not s or s.type ~= "dir" then
		say("Deleted directory: restore a file in it first")
		return
	end
	local cut, done, last = clip_cut, 0, nil
	for _, src in ipairs(clip) do
		if qed.fs.exists(src) then
			local dest = dest_path(dir, qed.path.base(src))
			if (cut and qed.fs.rename or qed.fs.copy)(src, dest) then
				done, last = done + 1, dest
			else
				say("Paste failed", "error")
			end
		end
	end
	if cut then
		clip = {}
	end
	if last then
		reveal(last)
	else
		refresh()
	end
	local verb = cut and "Moved" or "Pasted"
	if done == 1 then
		say(verb .. " " .. qed.path.base(last))
	elseif done > 1 then
		say(("%s %d items"):format(verb, done))
	end
end

local function delete(ctx)
	local items, view = ctx.items or {}, ctx.view
	if gone(items) or #items == 0 then
		return
	end
	local question
	if #items > 1 then
		question = ("Delete %d items?"):format(#items)
	elseif items[1].dir then
		question = ("Delete %s/ and its contents?"):format(qed.path.base(items[1].path))
	else
		question = ("Delete %s?"):format(qed.path.base(items[1].path))
	end
	if qed.confirm(question, {"Cancel", "Delete"}) ~= 2 then
		return
	end
	local failed = 0
	for _, it in ipairs(items) do
		if not qed.fs.remove(it.path) then
			failed = failed + 1
		end
	end
	local _, row, anchor = view:select()
	if row then
		view:select(math.max(1, math.min(row, anchor or row) - 1))
	end
	refresh()
	local n = #items - failed
	if failed > 0 then
		say(("Deleted %d, %d failed"):format(n, failed), "error")
	elseif n == 1 then
		say("Deleted")
	else
		say(("Deleted %d items"):format(n))
	end
end

local function buffer_of(path)
	for _, b in ipairs(qed.buf.list()) do
		if qed.buf.path(b) == path then
			return b
		end
	end
end

local function close_buffers(ctx)
	local paths, unsaved = {}, 0
	for _, it in ipairs(ctx.items or {}) do
		local b = not it.dir and buffer_of(it.path)
		if b then
			paths[#paths + 1] = it.path
			unsaved = unsaved + (qed.buf.modified(b) and 1 or 0)
		end
	end
	if #paths == 0 then
		say("No open buffers in selection")
		return
	end
	if unsaved > 0 then
		local question = ("Close %d buffer%s? (%d unsaved)"):format(#paths, #paths == 1 and "" or "s", unsaved)
		if qed.confirm(question, {"Cancel", "Close all"}) ~= 2 then
			return
		end
	end
	local closed = 0
	for _, path in ipairs(paths) do
		local b = buffer_of(path)
		if b and qed.close(b, {discard = true}) then
			closed = closed + 1
		end
	end
	if v then
		sync(false)
	end
	if closed == 1 then
		say("Closed buffer")
	elseif closed > 1 then
		say(("Closed %d buffers"):format(closed))
	end
end

local function prompt(ctx, m)
	if m == "rename" then
		if gone(ctx.items or {}) then
			return
		end
		local it = cursor(ctx)
		target = it and it.path
		ctx.view:footer{input = {prompt = "Rename: ", text = it and qed.path.base(it.path) or ""}}
	else
		target = target_dir(ctx)
		ctx.view:footer{input = {prompt = "New: ", text = ""}}
	end
	mode = m
	say("")
end

local function toggle(key)
	show[key] = not show[key]
	if v then
		walk_new()
		sync(false)
	end
end

local function toggle_diff()
	show.diff = not show.diff
	if v then
		v:footer{chips = chips()}
		preview_changed(v:select(), false)
	end
end

local function has_provider()
	return qed.filetree.state().provider
end

-- plugin commands have no bind_from: re-register when the core bind moves
local borrowed = {}

local function borrow(name, core, run)
	local b = {core = core, key = qed.shortcut(core) or ""}
	b.spec = {name = name, scope = "filetree", run = run}
	b.spec.key = b.key ~= "" and b.key or nil
	b.handle = qed.command(b.spec)
	borrowed[#borrowed + 1] = b
end

local function rebind_borrowed()
	for _, b in ipairs(borrowed) do
		local key = qed.shortcut(b.core) or ""
		if key ~= b.key then
			b.handle:remove()
			b.key = key
			b.spec.key = key ~= "" and key or nil
			b.handle = qed.command(b.spec)
		end
	end
end

return {
	setup = function()
		qed.meta{display_name = "File Tree"}
		show = {dotfiles = qed.opt("filetree_show_dotfiles"), ignored = qed.opt("filetree_show_ignored"), diff = qed.opt("filetree_diff_only")}
		for _, t in ipairs({{"All", "Alt+f"}, {"Open", "Alt+o"}, {"Changed", "Alt+g"}, {"Unsaved", "Alt+u"}}) do
			qed.command{name = t[1], key = t[2], welcome = true, when = t[1] == "Changed" and has_provider or nil, run = function()
				open(t[1])
			end}
		end
		borrow("Copy", "Copy", function(ctx) capture(ctx, false) end)
		borrow("Cut", "Cut", function(ctx) capture(ctx, true) end)
		borrow("Paste", "Paste", paste)
		borrow("Close Buffers", "Close Buffer", close_buffers)
		borrow("Select All", "Select All", function(ctx)
			local _, _, _, n = ctx.view:select()
			if n > 0 then
				ctx.view:select(n, 1)
			end
		end)
		local function cmd(name, key, run, when)
			qed.command{name = name, scope = "filetree", key = key, run = run, when = when}
		end
		cmd("Delete", "Ctrl+d", delete)
		cmd("Rename", "Ctrl+r", function(ctx) prompt(ctx, "rename") end)
		cmd("New", "Ctrl+n", function(ctx) prompt(ctx, "new") end)
		cmd("Toggle Dotfiles", "Alt+.", function() toggle("dotfiles") end)
		cmd("Toggle Ignored", "Alt+i", function() toggle("ignored") end)
		cmd("Toggle Diff", "Alt+d", toggle_diff, has_provider)
		cmd("Expand/Collapse All", "Alt+e", function(ctx)
			if not ctx.view:expand() then
				say("File status is still loading")
			end
		end)
		load_state()
		qed.filetree.listen(function(kind)
			if kind == "base" then
				if v and scope == "Changed" and wanted then
					preview_show(wanted)
				end
				return
			end
			local had = st.provider
			load_state()
			if not v then
				return
			end
			if had ~= st.provider then
				reopen()
				return
			end
			ignore_push()
			sync(false)
		end)
		qed.on("config_changed", rebind_borrowed)
		qed.on("root_changed", function()
			st.files, st.ignored, st.status, st.changed, st.deleted = nil, {}, {}, {}, {}
			cache = {}
			refresh()
			if v then
				reopen()
				-- dirs expanded under the old root mean nothing now: back to the tab's default
				if v then
					v:expand(scope ~= "All")
				end
			end
		end)
	end,
}
