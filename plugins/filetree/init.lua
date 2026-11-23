local ui = qed.ui

local TABS = {
	{label = "All", cmd = "File Tree: All"},
	{label = "Open", cmd = "File Tree: Open"},
	{label = "Unsaved", cmd = "File Tree: Unsaved"},
}
-- core's old walk preview debounce: a held arrow asks a previewing tab's plugin once
local PREVIEW_DEBOUNCE_MS = 80

local view
local walk, walk_root
local scope = "All"
local show = {}
local clip, clip_cut = {}, false
local added = {}
local marks_of, ignored_of = {}, {}
local merged_marks = {}
local scopes = {}
local due, ignore_moved = false, false

local function parent(path)
	return path:match("^(.+)/[^/]*$") or path
end

local function exists(path)
	return qed.fs.exists(path, {follow = false})
end

local function builtin(label)
	for _, tab in ipairs(TABS) do
		if tab.label == label then
			return true
		end
	end
	return false
end

local function tab_of(label)
	for _, tab in ipairs(added) do
		if tab.label == label then
			return tab
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

local function merge_marks()
	merged_marks = {}
	for _, id in ipairs(owners(marks_of)) do
		for path, mark in pairs(marks_of[id]) do
			merged_marks[path] = mark
		end
	end
end

local function tabs()
	local out, at = {TABS[1], TABS[2]}, 1
	for _, tab in ipairs(added) do
		out[#out + 1] = {label = tab.label, cmd = tab.cmd}
	end
	out[#out + 1] = TABS[3]
	for index, tab in ipairs(out) do
		if tab.label == scope then
			at = index
		end
	end
	return out, at
end

local function chips()
	local tab = tab_of(scope)
	if scope == "All" then
		return {{label = "ignored", cmd = "File Tree: Toggle Ignored", on = show.ignored}, {label = "dotfiles", cmd = "File Tree: Toggle Dotfiles", on = show.dotfiles}}
	elseif tab and tab.preview then
		return {{label = "diff", cmd = "File Tree: Toggle Diff", on = show.diff}}
	end
	return {}
end

-- a plugin that has not sent its ignore set yet holds the walk back: it would descend into ignored dirs
local function ignore_push()
	local all = {}
	for _, id in ipairs(owners(ignored_of)) do
		local paths = ignored_of[id]
		if paths == false then
			walk:ignore(false)
			return
		end
		for _, path in ipairs(paths) do
			all[#all + 1] = path
		end
	end
	walk:ignore(all)
end

local function scope_release(cached)
	cached.tree:release()
	if cached.handle then
		cached.handle:release()
	end
end

local function walk_new()
	for _, cached in pairs(scopes) do
		scope_release(cached)
	end
	scopes = {}
	if walk then
		walk:release()
	end
	walk = qed.fs.walk{dotfiles = show.dotfiles, ignored = show.ignored}
	ignore_push()
end

local function buffer_paths()
	local paths = {}
	for _, buffer in ipairs(qed.buf.list()) do
		local path = buffer:path()
		if path ~= "" and (scope == "Open" or buffer:modified()) and qed.fs.exists(path) then
			paths[#paths + 1] = path
		end
	end
	return paths
end

-- the tree list of the current tab, kept per tab while its paths stay the same
local function source()
	if scope == "All" then
		scopes.All = scopes.All or {tree = walk:tree()}
		return scopes.All.tree
	end
	local tab = tab_of(scope)
	local paths = not tab and buffer_paths()
	local stamp = paths and table.concat(paths, "\0") or tab.stamp
	local cached = scopes[scope]
	if cached and cached.stamp == stamp then
		return cached.tree
	end
	if cached then
		scope_release(cached)
	end
	local handle = walk:within(paths or tab.paths)
	if tab and tab.virtual and #tab.virtual > 0 then
		local merged = handle:union(tab.virtual)
		handle:release()
		handle = merged
	end
	scopes[scope] = {handle = handle, stamp = stamp, tree = handle:tree()}
	return scopes[scope].tree
end

local function buffers_by_path()
	local out = {}
	for _, buffer in ipairs(qed.buf.list()) do
		local path = buffer:path()
		if path ~= "" then
			out[path] = buffer
		end
	end
	return out
end

local function dimmed(path)
	local root = qed.root()
	while path and #path >= #root do
		local mark = merged_marks[path]
		if mark and mark.dim then
			return true
		end
		local up = parent(path)
		if up == path then
			break
		end
		path = up
	end
	return false
end

-- rows that arrived after the highlight was cleared (a filter still reading) start on the first one
local function highlighted_path()
	local state = ui.node("filetree_rows"):state()
	local path = state and state.highlighted
	if not path and view and view.tree:count() > 0 then
		path = view.tree:at(1).path
	end
	return path
end

-- typed keys reach the query before its change event runs: catch up before acting on the rows
local function query_sync()
	local text = view.query:text()
	if text ~= view.applied then
		view.applied = text
		view.tree:set_query(text)
		local first = view.tree:at(1)
		ui.node("filetree_rows"):set_state{highlighted = first and first.path or false, extend_from = false}
	end
end

local function selected_range()
	local tree = view.tree
	local cursor = tree:index_of(highlighted_path() or "")
	if not cursor then
		return nil
	end
	local state = ui.node("filetree_rows"):state()
	local anchor = state and state.extend_from and tree:index_of(state.extend_from) or cursor
	return math.min(anchor, cursor), math.max(anchor, cursor)
end

local function selected_items()
	query_sync()
	local out = {}
	local low, high = selected_range()
	for index = low or 1, high or 0 do
		local row = view.tree:at(index)
		out[#out + 1] = {path = row.path, dir = row.dir}
	end
	return out
end

local function cursor_item()
	query_sync()
	local path = highlighted_path()
	local row = path and view.tree:get(path)
	return row and {path = row.path, dir = row.dir} or nil
end

local build

local function rebuild()
	if view then
		view.handle:update(build())
	end
end

local function tree_row(row)
	local mark = merged_marks[row.path]
	local tab = tab_of(scope)
	local detail = tab ~= nil and tab.detail == true
	local fg
	if mark and mark.fg then
		fg = mark.fg
	elseif not row.dir and row.path == view.current then
		fg = "pane_prompt_foreground"
	elseif dimmed(row.path) then
		fg = "pane_dim_foreground"
	end
	local buffer = not row.dir and view.buffers[row.path]
	local icon = row.dir and (row.expanded and qed.theme.icon("tree_expanded") or qed.theme.icon("tree_collapsed")) or " "
	local label = row.name
	if mark and mark.suffix and not row.dir then
		label = label .. "  " .. mark.suffix
	end
	local sizes = false
	if detail and mark and not row.dir and ((mark.added or 0) > 0 or (mark.removed or 0) > 0) then
		sizes = ui.text{{fg = "git_added", "+" .. (mark.added or 0)}, "  ", {fg = "git_deleted", "-" .. (mark.removed or 0)}}
	end
	return ui.row{
		on = {
			click = function(args)
				ui.node("filetree_rows"):set_state{highlighted = row.path, extend_from = false}
				view.changed()
				return true
			end,
			double_click = function()
				ui.node("filetree_rows"):set_state{highlighted = row.path}
				view.activate()
				return true
			end,
		},
		ui.text{width = 1, fg = mark and mark.bar or nil, mark and mark.bar and "▌" or " "},
		ui.text{grow = 1, fg = fg, string.rep("  ", row.depth), icon, " ", label,
			buffer and buffer:modified() and (" " .. qed.theme.icon("modified")) or ""},
		sizes,
	}
end

local function tab_row()
	local row, at = tabs()
	local cells = {ui.text{" "}}
	for index, tab in ipairs(row) do
		local on = index == at
		if index > 1 then
			cells[#cells + 1] = ui.text{fg = "pane_dim_foreground", " │ "}
		end
		cells[#cells + 1] = ui.text{
			on = {click = function()
				view.switch(tab.label)
				return true
			end},
			{fg = on and "pane_prompt_foreground" or "pane_dim_foreground", bold = on, tab.label}}
	end
	return ui.row{height = 1, table.unpack(cells)}
end

local function footer()
	if view.input then
		return ui.row{height = 1,
			ui.text{fg = "pane_prompt_foreground", " ", view.input.prompt},
			ui.editor{id = "filetree_input", buffer = view.input.buffer, height = 1, grow = 1, scope = {"filetree_input", "editor"}},
		}
	end
	local cells = {ui.text{grow = 1, fg = "pane_dim_foreground", " ←→ tabs  ↑↓ select  Shift+↑↓ extend  Enter open  Ctrl+P commands"}}
	for _, chip in ipairs(chips()) do
		cells[#cells + 1] = ui.text{fg = chip.on and "pane_prompt_foreground" or "pane_dim_foreground", bold = chip.on, " ", chip.label, " "}
	end
	return ui.row{height = 1, table.unpack(cells)}
end

build = function()
	local tab = tab_of(scope)
	local tree = view.tree
	local count = tree:count()
	local empty = count == 0 and tab and tab.empty or nil
	return ui.dismissable{on_dismiss = function() view.close() end,
		ui.box{id = "filetree", float = "screen", anchor = "center", width = "100%", height = "100%",
			margin = {x = 2, y = 1}, border = true, title = "File Tree", bg = "pane_background", fg = "pane_foreground",
			ui.column{
				tab_row(),
				ui.row{height = 1,
					ui.text{fg = "pane_prompt_foreground", "> "},
					ui.editor{id = "filetree_query", buffer = view.query, height = 1, grow = 1,
						scope = {"filetree", "editor"}, placeholder = "type to filter"},
					ui.text{fg = "pane_dim_foreground", tree:loading() and "… " or (count .. (tree:more() and "+" or "") .. " ")},
				},
				ui.row{grow = 1, separator = view.preview ~= nil,
					ui.column{grow = view.preview and 0 or 1,
						width = view.preview and {"40%", min = qed.opt("split_tree_min_width"), max = qed.opt("split_tree_max_width")} or nil,
						empty and ui.text{id = "filetree_hint", fg = "pane_dim_foreground", " ", empty} or false,
						ui.scroll{id = "filetree_scroll", grow = 1,
							ui.virtual_column{id = "filetree_rows", data = tree, item = tree_row,
								highlight_style = {bg = "pane_selection_background"}}},
					},
					view.preview and view.preview.buffer and ui.editor{id = "filetree_preview", buffer = view.preview.buffer,
						grow = 1, readonly = true, syntax = true, line_numbers = true}
					or view.preview and ui.image{id = "filetree_preview", path = view.preview.path, grow = 1}
					or false,
				},
				footer(),
			},
		},
	}
end

local function refresh()
	qed:emit("filetree:refresh")
end

local function preview_close()
	if view and view.preview then
		if view.preview.buffer then
			view.preview.buffer:close()
		end
		view.preview = nil
	end
end

local function split_lines(text)
	local out = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = line
	end
	if out[#out] == "" then
		out[#out] = nil
	end
	return out
end

-- set_text takes UTF-8 only: a Latin-1 or binary byte shows as U+FFFD
local function utf8_repair(text)
	if utf8.len(text) then
		return text
	end
	local out, at = {}, 1
	while at <= #text do
		local ok, bad = utf8.len(text, at)
		if ok then
			out[#out + 1] = text:sub(at)
			break
		end
		out[#out + 1] = text:sub(at, bad - 1) .. "\u{FFFD}"
		at = bad + 1
	end
	return table.concat(out)
end

-- diff-only: the changed rows of the file with a little context, runs apart marked by an ellipsis
local function changed_rows(buffer, base)
	local current = split_lines(buffer:text())
	local hunks = qed.text.diff(split_lines(base), current)
	if not hunks or #hunks == 0 then
		return nil
	end
	local keep = {}
	for _, hunk in ipairs(hunks) do
		local first = math.max(1, hunk.b - qed.opt("preview_diff_context"))
		local last = math.min(#current, hunk.b + math.max(hunk.b_count, 1) - 1 + qed.opt("preview_diff_context"))
		for row = first, last do
			keep[row] = true
		end
	end
	local out, previous = {}, 0
	for row = 1, #current do
		if keep[row] then
			if previous ~= 0 and row > previous + 1 then
				out[#out + 1] = "…"
			end
			out[#out + 1] = current[row]
			previous = row
		end
	end
	return utf8_repair(table.concat(out, "\n"))
end

-- a deleted file previews its base: what the change removed
local function preview_load(path, base)
	preview_close()
	local buffer
	local info = exists(path) and qed.fs.stat(path)
	if info and info.image then
		view.preview = {path = path}
		return
	end
	if exists(path) then
		buffer = qed.buf.create{internal = true, from = path}
		local only = base and show.diff and changed_rows(buffer, base)
		if only then
			buffer:set_text(only)
			buffer:set_cursor({row = 1, col = 1})
		elseif base then
			buffer:set_base(base)
		end
	else
		buffer = qed.buf.create{internal = true}
		buffer:set_text(base or "")
	end
	view.preview = {path = path, buffer = buffer, deleted = not exists(path)}
end

local function preview_sync()
	if not view then
		return
	end
	local item = cursor_item()
	local tab = tab_of(scope)
	if not item or item.dir or (not exists(item.path) and not (tab and tab.preview)) then
		if view.preview then
			preview_close()
			rebuild()
		end
		return
	end
	if view.preview and view.preview.path == item.path and view.preview.scope == scope and not view.preview.stale then
		return
	end
	local base, asked = nil, scope
	if tab and tab.preview then
		local ok, result = pcall(tab.preview, item.path)
		if not ok then
			qed.log("preview: " .. tostring(result), "debug")
		end
		base = ok and type(result) == "string" and result or nil
	end
	if not view or scope ~= asked or cursor_item() == nil or cursor_item().path ~= item.path then
		return
	end
	preview_load(item.path, base)
	view.preview.scope = scope
	rebuild()
end

-- the count on the query row follows a tree still reading its dirs
local function follow_loading()
	if not view or view.following then
		return
	end
	view.following = true
	local current = view
	qed.defer(30, function()
		current.following = false
		if view == current then
			rebuild()
			if current.tree:loading() then
				follow_loading()
			end
		end
	end)
end

local function changed()
	if not view then
		return
	end
	rebuild()
	if view.tree:loading() then
		follow_loading()
	end
	view.preview_due = (view.preview_due or 0) + 1
	local token, current = view.preview_due, view
	qed.defer(PREVIEW_DEBOUNCE_MS, function()
		if view == current and current.preview_due == token then
			preview_sync()
		end
	end)
end

local function close()
	if not view then
		return
	end
	local closing = view
	view = nil
	closing.handle:unmount()
	closing.query:close()
	if closing.preview then
		closing.preview.buffer:close()
	end
	if closing.input then
		closing.input.buffer:close()
	end
end

local function sync()
	if not view then
		return
	end
	if not builtin(scope) and not tab_of(scope) then
		scope = "All"
	end
	view.tree = source()
	view.applied = view.query:text()
	view.tree:set_query(view.applied)
	view.buffers = buffers_by_path()
	local first = view.tree:at(1)
	if not highlighted_path() or not view.tree:get(highlighted_path()) then
		ui.node("filetree_rows"):set_state{highlighted = first and first.path or false}
	end
	changed()
end

local function open_paths(paths)
	close()
	for _, path in ipairs(paths) do
		qed.open(path)
	end
end


local function activate()
	query_sync()
	local items = selected_items()
	if #items > 1 then
		local paths = {}
		for _, item in ipairs(items) do
			if not item.dir and exists(item.path) then
				paths[#paths + 1] = item.path
			end
		end
		if #paths > 0 then
			open_paths(paths)
		end
		return
	end
	local item = cursor_item()
	if not item then
		return
	end
	if item.dir then
		if view.query:text() ~= "" then
			view.query:set_text("")
			view.tree:set_query("")
			view.tree:reveal(item.path)
			view.tree:expand(item.path, true)
		else
			view.tree:toggle(item.path)
		end
		rebuild()
		return
	end
	if not exists(item.path) then
		local tab = tab_of(scope)
		if tab and tab.missing then
			tab.missing(item.path)
		else
			qed.message("Deleted file")
		end
		return
	end
	open_paths({item.path})
end

local function reveal(path)
	refresh()
	if view then
		view.tree:reveal(path)
		ui.node("filetree_rows"):set_state{highlighted = path, extend_from = false}
		changed()
	end
end

local function open(tab)
	if view then
		-- the chord of the tab already shown closes the tree, as a toggle
		local same = scope == tab
		close()
		if same then
			return
		end
	end
	scope = (builtin(tab) or tab_of(tab)) and tab or "All"
	-- a reopened tree keeps its walk and so its expanded dirs, until the root moves
	if not walk or walk_root ~= qed.root() then
		walk_new()
		walk_root = qed.root()
	else
		-- a fresh handle on the same walk makes it see the disk as of now
		qed.fs.walk{dotfiles = show.dotfiles, ignored = show.ignored}:release()
	end
	local current_buffer = qed.buf.current()
	view = {query = qed.buf.create{internal = true}, current = current_buffer and current_buffer:path() or "",
		changed = changed, activate = activate, close = close}
	view.switch = function(label)
		scope = label
		ui.node("filetree_rows"):set_state{extend_from = false}
		sync()
	end
	view.tree = source()
	view.tree:set_query("")
	view.applied = ""
	view.buffers = buffers_by_path()
	view.handle = ui.mount("pane", build())
	local current = view
	view.query:on("change", function()
		if view ~= current then
			return
		end
		local text = view.query:text()
		if text:find("\n") then
			view.query:set_text((text:gsub("\r?\n", " ")))
			return
		end
		query_sync()
		changed()
	end)
	ui.node("filetree_query"):focus()
	local first = view.tree:at(1)
	ui.node("filetree_rows"):set_state{highlighted = first and first.path or false, extend_from = false}
	refresh()
	changed()
end

local function move(step, extend)
	if not view then
		return
	end
	query_sync()
	local tree = view.tree
	local count = tree:count()
	if count == 0 then
		return
	end
	local path = highlighted_path()
	local state = ui.node("filetree_rows"):state()
	if extend and not (state and state.extend_from) then
		ui.node("filetree_rows"):set_state{extend_from = path}
	elseif not extend then
		ui.node("filetree_rows"):set_state{extend_from = false}
	end
	local index = tree:index_of(path or "") or 0
	index = math.max(1, math.min(count, index + step))
	ui.node("filetree_rows"):set_state{highlighted = tree:at(index).path}
	changed()
end

local function switch_tab(step)
	if not view then
		return
	end
	local row, at = tabs()
	local index = (at - 1 + step) % #row + 1
	view.switch(row[index].label)
end

local function escape()
	if not view then
		return
	end
	if view.tree:expanding() then
		view.tree:stop()
		rebuild()
		return
	end
	if view.query:text() ~= "" then
		view.query:set_text("")
		return
	end
	close()
end

local function gone(items)
	for _, item in ipairs(items) do
		if not exists(item.path) then
			qed.message("Deleted file: restore it first")
			return true
		end
	end
	return false
end

-- a range over a dir and its rows: the dir stands for them, or they would be copied or deleted twice
local function tops(items)
	local selected, out = {}, {}
	for _, item in ipairs(items) do
		selected[item.path] = true
	end
	for _, item in ipairs(items) do
		local path, nested = item.path, false
		while not nested do
			local up = parent(path)
			if up == path then
				break
			end
			path = up
			nested = selected[path] ~= nil
		end
		if not nested then
			out[#out + 1] = item
		end
	end
	return out
end

local function target_dir()
	local item = cursor_item()
	if not item then
		return qed.root()
	end
	return item.dir and item.path or qed.path.dir(item.path)
end

local function capture(cut)
	if not view then
		return
	end
	local items = selected_items()
	if gone(items) or #items == 0 then
		return
	end
	clip, clip_cut = {}, cut
	for _, item in ipairs(tops(items)) do
		clip[#clip + 1] = item.path
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
	for attempt = 1, 999 do
		full = qed.path.join(dir, attempt == 1 and ("%s (copy)%s"):format(stem, ext) or ("%s (copy %d)%s"):format(stem, attempt, ext))
		if not exists(full) then
			return full
		end
	end
	return full
end

local function paste()
	if not view then
		return
	end
	if #clip == 0 then
		qed.message("Nothing to paste")
		return
	end
	local dir = target_dir()
	local info = qed.fs.stat(dir)
	if not info or info.type ~= "dir" then
		qed.message("Deleted directory: restore a file in it first")
		return
	end
	local cut, done, failed, last = clip_cut, 0, 0, nil
	for _, source_path in ipairs(clip) do
		if exists(source_path) then
			local dest = dest_path(dir, qed.path.base(source_path))
			local ok, err = (cut and qed.fs.rename or qed.fs.copy)(source_path, dest)
			if ok then
				done, last = done + 1, dest
			else
				failed = failed + 1
				qed.message(("Paste failed: %s: %s"):format(qed.path.base(source_path), tostring(err)), "error")
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

local function delete()
	if not view then
		return
	end
	local items = tops(selected_items())
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
	if qed.confirm{question = question, choices = {"Cancel", "Delete"}} ~= 2 or not view then
		return
	end
	local low = selected_range()
	local failed, reason = 0, nil
	for _, item in ipairs(items) do
		local ok, err = qed.fs.remove(item.path)
		if not ok then
			failed, reason = failed + 1, err
		end
	end
	refresh()
	ui.node("filetree_rows"):set_state{extend_from = false}
	local above = low and view.tree:at(math.max(1, low - 1))
	if above then
		ui.node("filetree_rows"):set_state{highlighted = above.path}
	end
	changed()
	local deleted = #items - failed
	if failed > 0 then
		qed.message(("Deleted %d, %d failed: %s"):format(deleted, failed, tostring(reason)), "error")
	elseif deleted == 1 then
		qed.message("Deleted " .. qed.path.base(items[1].path) .. (items[1].dir and "/" or ""))
	else
		qed.message(("Deleted %d items"):format(deleted))
	end
end

local function buffer_of(path)
	for _, buffer in ipairs(qed.buf.list()) do
		if buffer:path() == path then
			return buffer
		end
	end
end

local function close_buffers()
	if not view then
		return
	end
	local paths, approved = {}, {}
	for _, item in ipairs(selected_items()) do
		local buffer = not item.dir and buffer_of(item.path)
		if buffer then
			paths[#paths + 1] = item.path
			if buffer:modified() then
				approved[#approved + 1] = buffer
			end
		end
	end
	if #paths == 0 then
		qed.message("No open buffers in selection")
		return
	end
	if #approved > 0 then
		local question = ("Close %d buffer%s? (%d unsaved)"):format(#paths, #paths == 1 and "" or "s", #approved)
		if qed.confirm{question = question, choices = {"Cancel", "Close All"}} ~= 2 then
			return
		end
	end
	if not view then
		return
	end
	local closed = 0
	view.closing = true
	for _, path in ipairs(paths) do
		local buffer = buffer_of(path)
		if buffer and qed.close(buffer, {discard = approved}) then
			closed = closed + 1
		end
	end
	if view then
		view.closing = nil
		local current = qed.buf.current()
		view.current = current and current:path() or nil
		sync()
	end
	if closed == 1 then
		qed.message("Closed buffer")
	elseif closed > 1 then
		qed.message(("Closed %d buffers"):format(closed))
	end
end

local function input_close()
	if view and view.input then
		view.input.buffer:close()
		view.input = nil
		rebuild()
		ui.node("filetree_query"):focus()
	end
end

local function prompt(kind)
	if not view then
		return
	end
	local target, text
	if kind == "rename" then
		if gone(selected_items()) then
			return
		end
		local item = cursor_item()
		target = item and item.path
		text = item and qed.path.base(item.path) or ""
	else
		target = target_dir()
		text = ""
	end
	if not target then
		return
	end
	local buffer = qed.buf.create{internal = true}
	buffer:set_text(text)
	buffer:set_cursor({row = 1, col = #text + 1})
	view.input = {kind = kind, target = target, buffer = buffer, prompt = kind == "rename" and "Rename: " or "New: "}
	rebuild()
	ui.node("filetree_input"):focus()
	qed.message("")
end

local function submit()
	if not view or not view.input then
		return
	end
	local kind, at, text = view.input.kind, view.input.target, view.input.buffer:text()
	input_close()
	local name = text:gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		qed.message("Empty name", "error")
		return
	end
	if kind == "rename" then
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
end

local function walk_changed()
	if view then
		local keep = highlighted_path()
		walk_new()
		sync()
		if keep then
			ui.node("filetree_rows"):set_state{highlighted = keep}
		end
	end
end

local function toggle(key)
	show[key] = not show[key]
	walk_changed()
end

local function toggle_diff()
	show.diff = not show.diff
	if view and view.preview then
		view.preview.stale = true
		preview_sync()
	end
end

local KNOBS = {show_dotfiles = "dotfiles", show_ignored = "ignored", diff_only = "diff"}

-- only knobs whose config value moved: a reload must not undo a live toggle
local function apply(cfg, changed_keys)
	local moved = {}
	for key, knob in pairs(KNOBS) do
		if not changed_keys or changed_keys[key] then
			if show[knob] ~= cfg[key] then
				show[knob] = cfg[key]
				moved[knob] = true
			end
		end
	end
	if moved.dotfiles or moved.ignored then
		walk_changed()
	end
end

local function has_preview()
	for _, tab in ipairs(added) do
		if tab.preview then
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
		if not view then
			return
		end
		if ignore then
			ignore_push()
		end
		sync()
	end)
end

local function release(label)
	if scopes[label] then
		scope_release(scopes[label])
		scopes[label] = nil
	end
end

local function drop(id)
	for index = #added, 1, -1 do
		if added[index].owner == id then
			release(added[index].label)
			table.remove(added, index)
		end
	end
	if marks_of[id] then
		marks_of[id] = nil
		merge_marks()
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

local stamps = 0

local exports = {
	set_tab = function(spec)
		local id = caller()
		if type(spec) ~= "table" or type(spec.label) ~= "string" or spec.label == "" or type(spec.paths) ~= "table" then
			error("set_tab: {label, paths, ...} expected", 2)
		end
		if builtin(spec.label) then
			error(("set_tab: %q is a built-in tab"):format(spec.label), 2)
		end
		local tab = tab_of(spec.label)
		if tab and tab.owner ~= id then
			error(("set_tab: %q belongs to %s"):format(spec.label, tab.owner), 2)
		end
		if not tab then
			tab = {owner = id, label = spec.label}
			added[#added + 1] = tab
		end
		if tab.paths ~= spec.paths or tab.virtual ~= spec.virtual or tab.empty ~= spec.empty then
			stamps = stamps + 1
			tab.stamp = stamps
		end
		tab.cmd, tab.paths, tab.virtual, tab.detail, tab.preview, tab.missing, tab.empty = spec.cmd, spec.paths, spec.virtual, spec.detail, spec.preview, spec.missing, spec.empty
		schedule()
	end,
	remove_tab = function(label)
		local id = caller()
		for index, tab in ipairs(added) do
			if tab.label == label and tab.owner == id then
				release(label)
				table.remove(added, index)
				schedule()
				return
			end
		end
	end,
	set_marks = function(marks_map)
		local id = caller()
		if type(marks_map) ~= "table" then
			error("set_marks: table expected", 2)
		end
		marks_of[id] = marks_map
		merge_marks()
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
	reveal = function(path)
		if view then
			reveal(path)
		end
	end,
	mark = function(path)
		return merged_marks[path]
	end,
	close = function()
		close()
	end,
	state = function()
		if not view then
			return nil
		end
		local row, at = tabs()
		local labels = {}
		for _, tab in ipairs(row) do
			labels[#labels + 1] = tab.label
		end
		local chip_state = {}
		for _, chip in ipairs(chips()) do
			chip_state[chip.label] = chip.on == true
		end
		local tab = tab_of(scope)
		return {tab = row[at].label, tabs = labels, chips = chip_state, query = view.query:text(),
			hint = view.tree:count() == 0 and tab and tab.empty or nil,
			input = view.input and view.input.kind or nil, preview = view.preview and view.preview.path or nil,
			walk = {dotfiles = show.dotfiles == true, ignored = show.ignored == true}}
	end,
	selection = function()
		if not view then
			return nil
		end
		local items = selected_items()
		local files = {}
		for _, item in ipairs(items) do
			files[#files + 1] = item.path
		end
		return {items = items, item = cursor_item(), files = files}
	end,
}

return {
	setup = function()
		qed.meta{display_name = "File Tree", description = "File browser with git status and file operations"}
		apply(qed.options({show_dotfiles = false, show_ignored = false, diff_only = true}, {
			show_dotfiles = "Show dotfiles when the tree opens",
			show_ignored = "Show ignored files when the tree opens",
			diff_only = "Diff previews show only the changed hunks",
		}))
		for _, tab in ipairs({{"All", "Alt+f"}, {"Open", "Alt+o"}, {"Unsaved", "Alt+u"}}) do
			qed.command{name = tab[1], key = tab[2], welcome = true, run = function()
				open(tab[1])
			end}
		end
		local function cmd(spec)
			spec.scope = "filetree"
			qed.command(spec)
		end
		cmd{name = "Next", key = "Down", run = function() move(1, false) end}
		cmd{name = "Previous", key = "Up", run = function() move(-1, false) end}
		cmd{name = "Extend Down", key = "Shift+Down", run = function() move(1, true) end}
		cmd{name = "Extend Up", key = "Shift+Up", run = function() move(-1, true) end}
		cmd{name = "Next Tab", key = "Right", run = function() switch_tab(1) end}
		cmd{name = "Previous Tab", key = "Left", run = function() switch_tab(-1) end}
		cmd{name = "Activate", key = "Enter", run = activate}
		cmd{name = "Close", key = "Esc", run = escape}
		cmd{name = "Copy", bind_from = "Copy", run = function() capture(false) end}
		cmd{name = "Cut", bind_from = "Cut", run = function() capture(true) end}
		cmd{name = "Paste", bind_from = "Paste", run = paste}
		cmd{name = "Close Buffers", bind_from = "Close Buffer", run = close_buffers}
		cmd{name = "Select All", bind_from = "Select All", run = function()
			if view and view.tree:count() > 0 then
				ui.node("filetree_rows"):set_state{extend_from = view.tree:at(1).path, highlighted = view.tree:at(view.tree:count()).path}
				changed()
			end
		end}
		cmd{name = "Delete", key = "Ctrl+d", run = delete}
		cmd{name = "Rename", key = "Ctrl+r", run = function() prompt("rename") end}
		cmd{name = "New", key = "Ctrl+n", run = function() prompt("new") end}
		cmd{name = "Toggle Dotfiles", key = "Alt+.", run = function() toggle("dotfiles") end}
		cmd{name = "Toggle Ignored", key = "Alt+i", run = function() toggle("ignored") end}
		cmd{name = "Toggle Diff", key = "Alt+d", run = toggle_diff, when = has_preview}
		cmd{name = "Expand/Collapse All", key = "Alt+e", run = function()
			if not view then
				return
			end
			if not view.tree:expand_all() then
				qed.message("File status is still loading")
			end
			rebuild()
		end}
		qed.command{name = "Submit", scope = "filetree_input", key = "Enter", run = submit}
		qed.command{name = "Cancel", scope = "filetree_input", key = "Esc", run = input_close}
		qed.export(exports)
		qed:on("plugin_unloaded", drop)
		qed:on("config_changed", function(changed_keys) apply(qed.config(), changed_keys) end)
		-- a jump elsewhere (a picked location, a buffer switch) closes the tree
		for _, event in ipairs({"buf_open", "buf_close", "buf_save"}) do
			qed:on(event, function()
				if view and scope ~= "All" then
					schedule()
				end
			end)
		end
		qed:on("buf_enter", function(buffer)
			if view and not view.closing and buffer:path() ~= view.current then
				close()
			end
		end)
		qed:on("root_changed", function()
			walk_root = nil
			if view then
				local label = scope
				close()
				open(label)
			end
		end)
	end,
}
