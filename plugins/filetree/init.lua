local TABS = {
	{label = "All", cmd = "File Tree: All"},
	{label = "Open", cmd = "File Tree: Open"},
	{label = "Changed", cmd = "File Tree: Changed"},
	{label = "Unsaved", cmd = "File Tree: Unsaved"},
}
local HINTS = {{label = "←→ tabs"}, {label = "↑↓ select"}, {label = "Shift+↑↓ extend"}, {label = "commands", cmd = "Command Palette"}}
local RANK = {added = 1, modified = 2, deleted = 3}
-- core's walk preview debounce: a held arrow on the Changed tab asks the provider once
local PREVIEW_DEBOUNCE_MS = 80
-- paths handled between yields while a status push is processed, so no slice nears the task budget
local CHUNK = 4000

local v, walk, auto
local scope = "All"
local show = {}
local clip, clip_cut = {}, false
local mode, target, wanted
local st = {provider = false, ignored = {}, status = {}, changed = {}, deleted = {}, gen = 0, paths = 0}
local built = {}
local scopes = {}
local shown = {}
local load_job, sync_job = 0, 0

local function say(text, level)
	qed.message(text, level)
end

local function parent(p)
	return p:match("^(.+)/[^/]*$") or p
end

local function exists(path)
	return qed.fs.exists(path, {follow = false})
end

local function deleted(path)
	local f = st.files and st.files[path]
	return f ~= nil and f.mark == "deleted" and not exists(path)
end

local function tick(i)
	if i % CHUNK == 0 then
		qed.sleep(0)
	end
end

-- "same", "fields" (same paths and deleted set, other fields moved) or "paths"; nil when a newer push took over
local function compare(a, b, my)
	local n, fields = 0, false
	for path, f in pairs(a.files) do
		local g = b.files[path]
		if not g or (g.mark == "deleted") ~= (f.mark == "deleted") then
			return "paths"
		end
		fields = fields or g.mark ~= f.mark or g.from ~= f.from or g.added ~= f.added or g.removed ~= f.removed
		n = n + 1
		tick(n)
		if my ~= load_job then
			return nil
		end
	end
	for _ in pairs(b.files) do
		n = n - 1
	end
	if n ~= 0 then
		return "paths"
	end
	fields = fields or #a.ignored ~= #b.ignored
	for i, p in ipairs(a.ignored) do
		fields = fields or b.ignored[i] ~= p
	end
	return fields and "fields" or "same"
end

-- a deleted file shows as modified on its ancestors
local function propagate(files, my)
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
	local n = 0
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
		n = n + 1
		tick(n)
		if my ~= load_job then
			return nil
		end
	end
	return status, changed, gone
end

-- true when the state changed, false when the push repeated it, nil when a newer push took over
local function load_state(my)
	local s = qed.filetree.state()
	local files, ignored = s.files, s.ignored or {}
	local how = "paths"
	if s.provider == st.provider and files and st.files then
		how = compare({files = files, ignored = ignored}, st, my)
		if how == nil then
			return nil
		elseif how == "same" then
			return false
		end
	end
	local status, changed, gone = propagate(files or {}, my)
	if not status then
		return nil
	end
	-- the narrowed Changed handle keys on paths: a push that only moved sizes keeps it
	local paths = st.paths + (how == "paths" and 1 or 0)
	st = {provider = s.provider, files = files, ignored = ignored, status = status, changed = changed, deleted = gone, gen = st.gen + 1, paths = paths}
	built = {}
	return true
end

local function marks(my)
	if built.marks then
		return built.marks
	end
	local m, n = {}, 0
	local icon = qed.theme.icon("tree_renamed")
	for path, mark in pairs(st.status) do
		local e = {bar = "git_" .. mark}
		if mark == "deleted" and not exists(path) then
			e.fg = "git_deleted"
		end
		local f = st.files and st.files[path]
		if f then
			if f.from then
				e.suffix = icon .. " " .. (qed.path.rel(f.from) or f.from)
			end
			if (f.added or 0) > 0 or (f.removed or 0) > 0 then
				e.added, e.removed = f.added or 0, f.removed or 0
			end
		end
		m[path] = e
		n = n + 1
		tick(n)
		if my ~= sync_job then
			return nil
		end
	end
	for _, path in ipairs(st.ignored) do
		if not m[path] then
			n = n + 1
		end
		local e = m[path] or {}
		e.dim = true
		m[path] = e
	end
	built.marks, built.count = m, n
	return m
end

local function alive(my, view)
	return my == sync_job and v ~= nil and v == view
end

-- the Changed tab's suffix and sizes come and go with the detail flag, so a tab switch pushes nothing
local function push_marks(my)
	local view, gen = v, st.gen
	local detail = scope == "Changed"
	if shown.marks == gen then
		view:marks({}, {detail = detail})
		return true
	end
	local m = marks(my)
	if not m or not alive(my, view) then
		return false
	end
	local chunk, n, first = {}, 0, true
	for path, e in pairs(m) do
		chunk[path] = e
		n = n + 1
		if n == CHUNK then
			view:marks(chunk, {replace = first, detail = detail, total = built.count})
			chunk, n, first = {}, 0, false
			qed.sleep(0)
			if not alive(my, view) or st.gen ~= gen then
				return false
			end
		end
	end
	view:marks(chunk, {replace = first, detail = detail, total = built.count})
	shown.marks = gen
	return true
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

-- handles with equal options share one core walk, so narrowed handles over it survive a new handle
local function walk_new()
	local opts = tostring(show.dotfiles) .. tostring(show.ignored)
	if scopes.opts ~= opts then
		for _, c in pairs(scopes) do
			if type(c) == "table" then
				c.h:release()
			end
		end
		scopes = {opts = opts}
	end
	if walk then
		walk:release()
	end
	walk = qed.fs.walk{dotfiles = show.dotfiles, ignored = show.ignored}
	ignore_push()
end

local function buffer_paths()
	local paths = {}
	for _, b in ipairs(qed.buf.list()) do
		local p = qed.buf.path(b)
		if p ~= "" and (scope == "Open" or qed.buf.modified(b)) and qed.fs.exists(p) then
			paths[#paths + 1] = p
		end
	end
	return paths
end

-- a narrowed handle is rebuilt only when its path set moved; fresh is true for a large rebuild
local function source()
	if scope == "All" then
		return walk, false
	end
	local paths = scope ~= "Changed" and buffer_paths()
	local stamp = paths and table.concat(paths, "\0") or st.paths
	local c = scopes[scope]
	if c and c.stamp == stamp then
		return c.h, false
	end
	if c then
		c.h:release()
	end
	local h
	if paths then
		h = walk:within(paths)
	else
		h = walk:within(st.changed)
		if #st.deleted > 0 then
			local u = h:union(st.deleted)
			h:release()
			h = u
		end
	end
	scopes[scope] = {h = h, stamp = stamp}
	return h, #(paths or st.changed) > CHUNK
end

-- narrowing and refilling are each one core call: a yield between keeps them in separate slices
local function show_source(my, view)
	local h, fresh = source()
	if shown.h == h then
		return true
	end
	if fresh then
		qed.sleep(0)
		if not alive(my, view) then
			return false
		end
	end
	view:set(h)
	shown.h = h
	return true
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

local function on_change(_, item)
	qed.sleep(PREVIEW_DEBOUNCE_MS)
	preview_changed(item, true)
end

-- only the Changed tab does work per highlighted item
local function preview_mode()
	if scope ~= "Changed" then
		v:on("change", false)
		if not auto then
			auto = true
			v:preview("auto")
		end
		return
	end
	v:on("change", on_change)
	if auto then
		auto = false
		v:preview(false)
	end
end

local function sync(blank)
	sync_job = sync_job + 1
	local my, view = sync_job, v
	if scope == "Changed" and not st.provider then
		scope = "All"
	end
	local _, at = tabs()
	view:tab(at)
	view:footer{chips = chips()}
	if not show_source(my, view) then
		return
	end
	preview_mode()
	if not push_marks(my) or not alive(my, view) then
		return
	end
	if scope == "Changed" then
		preview_changed(view:selection(), blank)
	end
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
	tab = function(view, i)
		local t = tabs()[i]
		if not t then
			-- the tab row and the provider disagree (it came or went meanwhile): rebuild the view
			view:close()
			open(scope)
			return
		end
		scope = t.label
		sync(true)
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
				say(err == "exists" and "Already exists" or "Rename failed: " .. tostring(err), "error")
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
		if exists(full) then
			say("Already exists", "error")
			return
		end
		local ok, err
		if dir then
			ok, err = qed.fs.mkdir(full)
		else
			ok, err = qed.fs.write(full, "", {exclusive = true})
		end
		if not ok then
			say(err == "exists" and "Already exists" or "Create failed: " .. tostring(err), "error")
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

local function provider_check()
	local s = qed.filetree.state()
	if s.provider ~= st.provider then
		load_job = load_job + 1
		load_state(load_job)
	end
end

open = function(tab)
	provider_check()
	scope = tab == "Changed" and not st.provider and "All" or tab
	mode, target, wanted = nil, nil, nil
	auto = true
	walk_new()
	local t, at = tabs()
	local items, fresh = source()
	if fresh then
		qed.sleep(0)
	end
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
		list = {items = items, tree = true, multi = true},
		preview = "auto",
		footer = {hints = HINTS, chips = chips()},
		on = handlers,
	}
	if not view then
		return
	end
	v, shown = view, {h = items}
	refresh()
	sync(true)
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
		if not exists(it.path) then
			say("Deleted file: restore it first")
			return true
		end
	end
	return false
end

-- a range over a dir and its rows: the dir stands for them, or they would be copied or deleted twice
local function tops(items)
	local sel, out = {}, {}
	for _, it in ipairs(items) do
		sel[it.path] = true
	end
	for _, it in ipairs(items) do
		local p, nested = it.path, false
		while not nested do
			local np = parent(p)
			if np == p then
				break
			end
			p = np
			nested = sel[p] ~= nil
		end
		if not nested then
			out[#out + 1] = it
		end
	end
	return out
end

local function capture(ctx, cut)
	local items = ctx.items or {}
	if gone(items) or #items == 0 then
		return
	end
	clip, clip_cut = {}, cut
	for _, it in ipairs(tops(items)) do
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
	if not exists(full) then
		return full
	end
	local stem, ext = name, ""
	local dot = name:match(".*()%.")
	if dot and dot > 1 then
		stem, ext = name:sub(1, dot - 1), name:sub(dot)
	end
	for i = 1, 999 do
		full = qed.path.join(dir, i == 1 and ("%s (copy)%s"):format(stem, ext) or ("%s (copy %d)%s"):format(stem, i, ext))
		if not exists(full) then
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
	local cut, done, failed, last = clip_cut, 0, 0, nil
	for _, src in ipairs(clip) do
		if exists(src) then
			local dest = dest_path(dir, qed.path.base(src))
			local ok, err = (cut and qed.fs.rename or qed.fs.copy)(src, dest)
			if ok then
				done, last = done + 1, dest
			else
				failed = failed + 1
				say(("Paste failed: %s: %s"):format(qed.path.base(src), tostring(err)), "error")
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
	if failed > 0 then
		return
	end
	local verb = cut and "Moved" or "Pasted"
	if done == 1 then
		say(verb .. " " .. qed.path.base(last))
	elseif done > 1 then
		say(("%s %d items"):format(verb, done))
	end
end

local function delete(ctx)
	local items, view = tops(ctx.items or {}), ctx.view
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
	local failed, reason = 0, nil
	for _, it in ipairs(items) do
		local ok, err = qed.fs.remove(it.path)
		if not ok then
			failed, reason = failed + 1, err
		end
	end
	local _, row, anchor = view:selection()
	if row then
		view:select(math.max(1, math.min(row, anchor or row) - 1))
	end
	refresh()
	local n = #items - failed
	if failed > 0 then
		say(("Deleted %d, %d failed: %s"):format(n, failed, tostring(reason)), "error")
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
	local paths, approved = {}, {}
	for _, it in ipairs(ctx.items or {}) do
		local b = not it.dir and buffer_of(it.path)
		if b then
			paths[#paths + 1] = it.path
			if qed.buf.modified(b) then
				approved[#approved + 1] = b
			end
		end
	end
	if #paths == 0 then
		say("No open buffers in selection")
		return
	end
	if #approved > 0 then
		local question = ("Close %d buffer%s? (%d unsaved)"):format(#paths, #paths == 1 and "" or "s", #approved)
		if qed.confirm(question, {"Cancel", "Close all"}) ~= 2 then
			return
		end
	end
	local closed = 0
	for _, path in ipairs(paths) do
		local b = buffer_of(path)
		if b and qed.close(b, {discard = approved}) then
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
		preview_changed(v:selection(), false)
	end
end

local function has_provider()
	return qed.filetree.state().provider
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
		local function cmd(spec)
			spec.scope = "filetree"
			qed.command(spec)
		end
		cmd{name = "Copy", bind_from = "Copy", run = function(ctx) capture(ctx, false) end}
		cmd{name = "Cut", bind_from = "Cut", run = function(ctx) capture(ctx, true) end}
		cmd{name = "Paste", bind_from = "Paste", run = paste}
		cmd{name = "Close Buffers", bind_from = "Close Buffer", run = close_buffers}
		cmd{name = "Select All", bind_from = "Select All", run = function(ctx)
			local _, _, _, n = ctx.view:selection()
			if n > 0 then
				ctx.view:select(n, 1)
			end
		end}
		cmd{name = "Delete", key = "Ctrl+d", run = delete}
		cmd{name = "Rename", key = "Ctrl+r", run = function(ctx) prompt(ctx, "rename") end}
		cmd{name = "New", key = "Ctrl+n", run = function(ctx) prompt(ctx, "new") end}
		cmd{name = "Toggle Dotfiles", key = "Alt+.", run = function() toggle("dotfiles") end}
		cmd{name = "Toggle Ignored", key = "Alt+i", run = function() toggle("ignored") end}
		cmd{name = "Toggle Diff", key = "Alt+d", run = toggle_diff, when = has_provider}
		cmd{name = "Expand/Collapse All", key = "Alt+e", run = function(ctx)
			if not ctx.view:expand() then
				say("File status is still loading")
			end
		end}
		st.provider = qed.filetree.state().provider
		qed.filetree.listen(function(kind)
			if kind == "base" then
				if v and scope == "Changed" and wanted then
					preview_show(wanted)
				end
				return
			end
			load_job = load_job + 1
			local had = st.provider
			local changed = load_state(load_job)
			if changed == nil or not v then
				return
			end
			if had ~= st.provider then
				reopen()
			elseif changed then
				ignore_push()
				sync(false)
			end
		end)
		qed.on("root_changed", function()
			load_job = load_job + 1
			st = {provider = st.provider, ignored = {}, status = {}, changed = {}, deleted = {}, gen = st.gen + 1, paths = st.paths + 1}
			built = {}
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
