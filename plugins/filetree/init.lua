local TABS = {
	{label = "All", cmd = "File Tree: All"},
	{label = "Open", cmd = "File Tree: Open"},
	{label = "Unsaved", cmd = "File Tree: Unsaved"},
}
local HINTS = {{label = "←→ tabs"}, {label = "↑↓ select"}, {label = "Shift+↑↓ extend"}, {label = "commands", cmd = "Command Palette"}}
-- core's walk preview debounce: a held arrow on a previewing tab asks its plugin once
local PREVIEW_DEBOUNCE_MS = 80
-- marks pushed between yields, so no slice nears the task budget
local CHUNK = 4000

local v, walk, auto
local scope = "All"
local show = {}
local clip, clip_cut = {}, false
local mode, target, wanted
local added = {}
local marks_of, ignored_of = {}, {}
local marks_gen, stamps = 0, 0
local built = {}
local scopes = {}
local shown = {}
local based = {}
local sync_job, ask = 0, 0
local due, ignore_moved = false, false

local function parent(p)
	return p:match("^(.+)/[^/]*$") or p
end

local function exists(path)
	return qed.fs.exists(path, {follow = false})
end

local function builtin(label)
	for _, t in ipairs(TABS) do
		if t.label == label then
			return true
		end
	end
	return false
end

local function tab_of(label)
	for _, t in ipairs(added) do
		if t.label == label then
			return t
		end
	end
end

local function owners(map)
	local out = {}
	for owner in pairs(map) do
		out[#out + 1] = owner
	end
	table.sort(out)
	return out
end

local function marks(my)
	if built.marks then
		return built.marks
	end
	local ids, m, n = owners(marks_of), {}, 0
	if #ids == 1 then
		m = marks_of[ids[1]]
		for _ in pairs(m) do
			n = n + 1
		end
	else
		for _, id in ipairs(ids) do
			for path, e in pairs(marks_of[id]) do
				if not m[path] then
					n = n + 1
				end
				m[path] = e
				if n % CHUNK == 0 then
					qed.sleep(0)
					if my ~= sync_job then
						return nil
					end
				end
			end
		end
	end
	built.marks, built.count = m, n
	return m
end

local function alive(my, view)
	return my == sync_job and v ~= nil and v == view
end

local function push_marks(my)
	local view, gen = v, marks_gen
	local t = tab_of(scope)
	local detail = t ~= nil and t.detail == true
	if shown.marks == gen then
		view:marks({}, {detail = detail})
		return true
	end
	local m = marks(my)
	if not m or not alive(my, view) then
		return false
	end
	-- a big push starts in a slice of its own, not on top of the open or refill that asked for it
	if built.count > CHUNK then
		qed.sleep(0)
		if not alive(my, view) or marks_gen ~= gen then
			return false
		end
	end
	local chunk, n, first = {}, 0, true
	for path, e in pairs(m) do
		chunk[path] = e
		n = n + 1
		if n == CHUNK then
			view:marks(chunk, {replace = first, detail = detail, total = built.count})
			chunk, n, first = {}, 0, false
			qed.sleep(0)
			if not alive(my, view) or marks_gen ~= gen then
				return false
			end
		end
	end
	view:marks(chunk, {replace = first, detail = detail, total = built.count})
	shown.marks = gen
	return true
end

local function tabs()
	local out, at = {TABS[1], TABS[2]}, 1
	for _, t in ipairs(added) do
		out[#out + 1] = {label = t.label, cmd = t.cmd}
	end
	out[#out + 1] = TABS[3]
	for i, t in ipairs(out) do
		if t.label == scope then
			at = i
		end
	end
	return out, at
end

local function chips()
	local t = tab_of(scope)
	if scope == "All" then
		return {{label = "ignored", cmd = "File Tree: Toggle Ignored", on = show.ignored}, {label = "dotfiles", cmd = "File Tree: Toggle Dotfiles", on = show.dotfiles}}
	elseif t and t.preview then
		return {{label = "diff", cmd = "File Tree: Toggle Diff", on = show.diff}}
	end
	return {}
end

-- a plugin that has not sent its ignore set yet holds the walk back: it would descend into ignored dirs
local function ignore_push()
	local ids = owners(ignored_of)
	local all = {}
	for _, id in ipairs(ids) do
		local paths = ignored_of[id]
		if paths == false then
			walk:ignore(false)
			return
		end
		if #ids == 1 then
			all = paths
		else
			for _, p in ipairs(paths) do
				all[#all + 1] = p
			end
		end
	end
	walk:ignore(all)
end

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

local function source()
	if scope == "All" then
		return walk, false
	end
	local t = tab_of(scope)
	local paths = not t and buffer_paths()
	local stamp = paths and table.concat(paths, "\0") or t.stamp
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
		h = walk:within(t.paths)
		if t.virtual and #t.virtual > 0 then
			local u = h:union(t.virtual)
			h:release()
			h = u
		end
	end
	scopes[scope] = {h = h, stamp = stamp}
	return h, #(paths or t.paths) > CHUNK
end

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

local function preview_show(path, base)
	if base then
		v:preview{path = path, base = base, diff_only = show.diff}
	else
		v:preview{path = path}
	end
end

local function preview_changed(item, blank, reuse)
	local t = v and tab_of(scope)
	if not t or not t.preview then
		return
	end
	if not item or item.dir or not item.path then
		wanted = nil
		v:preview(false)
		return
	end
	wanted = item.path
	if reuse and based.path == item.path then
		preview_show(item.path, based.base)
		return
	end
	if blank then
		v:preview(false)
	end
	ask = ask + 1
	local my, view = ask, v
	local ok, base = pcall(t.preview, item.path)
	if my ~= ask or v ~= view or wanted ~= item.path then
		return
	end
	if not ok then
		qed.log("debug", "preview: " .. tostring(base))
	end
	base = ok and type(base) == "string" and base or nil
	based = {path = item.path, base = base}
	preview_show(item.path, base)
end

local function on_change(_, item)
	qed.sleep(PREVIEW_DEBOUNCE_MS)
	preview_changed(item, true)
end

local function preview_mode()
	local t = tab_of(scope)
	if not t or not t.preview then
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
	if not builtin(scope) and not tab_of(scope) then
		scope = "All"
	end
	local row, at = tabs()
	view:tab(at, row)
	view:footer{chips = chips()}
	if not show_source(my, view) then
		return
	end
	preview_mode()
	if not push_marks(my) or not alive(my, view) then
		return
	end
	preview_changed(view:selection(), blank)
end

local function refresh()
	qed.emit("filetree:refresh")
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
				if not it.dir and exists(it.path) then
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
		if not exists(it.path) then
			local t = tab_of(scope)
			if t and t.missing then
				t.missing(it.path)
			else
				qed.message("Deleted file")
			end
			return
		end
		view:close()
		qed.open(it.path)
	end,
	tab = function(view, i)
		local t = tabs()[i]
		if not t then
			-- the tab row and the added tabs disagree (one came or went meanwhile): rebuild the view
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
			qed.message("Empty name", "error")
			return
		end
		if m == "rename" then
			local full = qed.path.join(qed.path.dir(at), name)
			if full == at then
				return
			end
			local ok, err = qed.fs.rename(at, full)
			if not ok then
				qed.message(err == "exists" and "Already exists" or "Rename failed: " .. tostring(err), "error")
				return
			end
			reveal(full)
			return
		end
		local dir = name:sub(-1) == "/"
		local clean = name:gsub("/+$", "")
		if clean == "" then
			qed.message("Empty name", "error")
			return
		end
		local full = qed.path.join(at, clean)
		if exists(full) then
			qed.message("Already exists", "error")
			return
		end
		local ok, err
		if dir then
			ok, err = qed.fs.mkdir(full)
		else
			ok, err = qed.fs.write(full, "", {exclusive = true})
		end
		if not ok then
			qed.message(err == "exists" and "Already exists" or "Create failed: " .. tostring(err), "error")
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
	scope = (builtin(tab) or tab_of(tab)) and tab or "All"
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
			qed.message("Deleted file: restore it first")
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
		qed.message(verb .. " " .. qed.path.base(clip[1]))
	else
		qed.message(("%s %d items"):format(verb, #clip))
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
		qed.message("Nothing to paste")
		return
	end
	local dir = target_dir(ctx)
	local s = qed.fs.stat(dir)
	if not s or s.type ~= "dir" then
		qed.message("Deleted directory: restore a file in it first")
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
				qed.message(("Paste failed: %s: %s"):format(qed.path.base(src), tostring(err)), "error")
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
		qed.message(verb .. " " .. qed.path.base(last))
	elseif done > 1 then
		qed.message(("%s %d items"):format(verb, done))
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
		qed.message(("Deleted %d, %d failed: %s"):format(n, failed, tostring(reason)), "error")
	elseif n == 1 then
		qed.message("Deleted " .. qed.path.base(items[1].path) .. (items[1].dir and "/" or ""))
	else
		qed.message(("Deleted %d items"):format(n))
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
		qed.message("No open buffers in selection")
		return
	end
	if #approved > 0 then
		local question = ("Close %d buffer%s? (%d unsaved)"):format(#paths, #paths == 1 and "" or "s", #approved)
		if qed.confirm(question, {"Cancel", "Close All"}) ~= 2 then
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
		qed.message("Closed buffer")
	elseif closed > 1 then
		qed.message(("Closed %d buffers"):format(closed))
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
	qed.message("")
end

local function walk_changed()
	if v then
		walk_new()
		sync(false)
	end
end

local function diff_changed()
	if v then
		v:footer{chips = chips()}
		preview_changed(v:selection(), false, true)
	end
end

local function toggle(key)
	show[key] = not show[key]
	walk_changed()
end

local function toggle_diff()
	show.diff = not show.diff
	diff_changed()
end

local KNOBS = {show_dotfiles = "dotfiles", show_ignored = "ignored", diff_only = "diff"}

-- only knobs whose config value moved: a reload must not undo a live toggle
local function apply(cfg, changed)
	local moved = {}
	for key, knob in pairs(KNOBS) do
		if not changed or changed[key] then
			if show[knob] ~= cfg[key] then
				show[knob] = cfg[key]
				moved[knob] = true
			end
		end
	end
	if moved.dotfiles or moved.ignored then
		walk_changed()
	end
	if moved.diff then
		diff_changed()
	end
end

local function has_preview()
	for _, t in ipairs(added) do
		if t.preview then
			return true
		end
	end
	return false
end

local function schedule()
	if due then
		return
	end
	due = true
	qed.defer(0, function()
		due = false
		local ignore = ignore_moved
		ignore_moved = false
		if not v then
			return
		end
		if ignore then
			ignore_push()
		end
		sync(false)
	end)
end

local function release(label)
	if scopes[label] then
		scopes[label].h:release()
		scopes[label] = nil
	end
end

local function drop(id)
	for i = #added, 1, -1 do
		if added[i].owner == id then
			release(added[i].label)
			table.remove(added, i)
		end
	end
	if marks_of[id] then
		marks_of[id] = nil
		marks_gen, built = marks_gen + 1, {}
	end
	if ignored_of[id] ~= nil then
		ignored_of[id] = nil
		ignore_moved = true
	end
	schedule()
end

local function caller()
	return qed.caller() or error("call it through qed.plugin(\"filetree\")", 3)
end

local exports = {
	set_tab = function(spec)
		local id = caller()
		if type(spec) ~= "table" or type(spec.label) ~= "string" or spec.label == "" or type(spec.paths) ~= "table" then
			error("set_tab: {label, paths, ...} expected", 2)
		end
		if builtin(spec.label) then
			error(("set_tab: %q is a built-in tab"):format(spec.label), 2)
		end
		local t = tab_of(spec.label)
		if t and t.owner ~= id then
			error(("set_tab: %q belongs to %s"):format(spec.label, t.owner), 2)
		end
		if not t then
			t = {owner = id, label = spec.label}
			added[#added + 1] = t
		end
		if t.paths ~= spec.paths or t.virtual ~= spec.virtual then
			stamps = stamps + 1
			t.stamp = stamps
		end
		t.cmd, t.paths, t.virtual, t.detail, t.preview, t.missing = spec.cmd, spec.paths, spec.virtual, spec.detail, spec.preview, spec.missing
		based = {}
		schedule()
	end,
	remove_tab = function(label)
		local id = caller()
		for i, t in ipairs(added) do
			if t.label == label and t.owner == id then
				release(label)
				table.remove(added, i)
				schedule()
				return
			end
		end
	end,
	set_marks = function(m)
		local id = caller()
		if type(m) ~= "table" then
			error("set_marks: table expected", 2)
		end
		marks_of[id] = m
		marks_gen, built = marks_gen + 1, {}
		schedule()
	end,
	set_ignored = function(paths)
		local id = caller()
		if paths ~= false and type(paths) ~= "table" then
			error("set_ignored: list or false expected", 2)
		end
		ignored_of[id] = paths
		ignore_moved = true
		schedule()
	end,
	open = function(label)
		if not builtin(label) and not tab_of(label) then
			error(("open: no tab %q"):format(tostring(label)), 2)
		end
		open(label)
	end,
	dotfiles = function()
		return show.dotfiles
	end,
}

return {
	setup = function()
		qed.meta{display_name = "File Tree", description = "File browser with git status and file operations"}
		apply(qed.options{show_dotfiles = false, show_ignored = false, diff_only = true})
		for _, t in ipairs({{"All", "Alt+f"}, {"Open", "Alt+o"}, {"Unsaved", "Alt+u"}}) do
			qed.command{name = t[1], key = t[2], welcome = true, run = function()
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
		cmd{name = "Toggle Diff", key = "Alt+d", run = toggle_diff, when = has_preview}
		cmd{name = "Expand/Collapse All", key = "Alt+e", run = function(ctx)
			if not ctx.view:expand() then
				qed.message("File status is still loading")
			end
		end}
		qed.export(exports)
		qed.on("plugin_unloaded", drop)
		qed.on("config_changed", function(changed) apply(qed.config(), changed) end)
		qed.on("root_changed", function()
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
