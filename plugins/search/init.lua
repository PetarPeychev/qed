local ui = qed.ui

local MAX = 500
local MAX_COLUMNS = 300
local DEBOUNCE_MS = 120
local PREVIEW_DEBOUNCE_MS = 60
local SELECTED = {bg = "pane_selection_background", fg = "pane_selection_foreground"}

local min_query
local has_rg = false
local view
local activate

local function rg_ready()
	if not has_rg then
		local result = qed.spawn{cmd = "command -v rg"}
		has_rg = result ~= nil and result.code == 0
	end
	return has_rg
end

local function short_hint()
	return ("Type at least %d characters to search"):format(min_query)
end

local function rg_cmd(text, args)
	-- stdin is the spawn's empty body; without </dev/null rg searches it instead of the tree
	return ("rg --vimgrep -F -S --line-buffered -M %d --max-columns-preview -e %s%s </dev/null 2>/dev/null"):format(MAX_COLUMNS, qed.shell_quote(text), args)
end

local function stop()
	if view and view.running then
		view.running:kill()
		view.running = nil
	end
end

local function close()
	if not view then
		return
	end
	stop()
	local closing = view
	view = nil
	closing.handle:unmount()
	closing.query:close()
	if closing.preview then
		closing.preview.buffer:close()
	end
end

local function highlighted()
	local state = ui.node("search_rows"):state()
	local key = state and state.highlighted
	return key and view.results:get(key) or nil
end

local function preview_show(item)
	local preview = view.preview
	if not item then
		return
	end
	if not preview or preview.path ~= item.path then
		if preview then
			preview.buffer:close()
		end
		preview = {path = item.path, buffer = qed.buf.create{internal = true, from = item.path}}
		view.preview = preview
		view.handle:update(view.build())
	end
	preview.buffer:set_cursor({row = math.min(item.pos.row, preview.buffer:line_count()), col = 1})
end

-- a held arrow key reads one file, not one per row
local function preview_soon()
	local current = view
	current.preview_due = (current.preview_due or 0) + 1
	local token = current.preview_due
	qed.defer(PREVIEW_DEBOUNCE_MS, function()
		if view == current and current.preview_due == token then
			preview_show(highlighted())
		end
	end)
end

local function highlight(key)
	ui.node("search_rows"):set_state{highlighted = key}
	preview_soon()
end

local function result_row(record)
	return ui.row{
		on = {
			double_click = function()
				activate()
				return true
			end,
		},
		ui.text{grow = 1, " ", record.label},
	}
end

local function count_text()
	local count = view.results:count()
	if count == 0 then
		return ""
	end
	return tostring(count) .. (view.capped and "+" or "")
end

local function build()
	local hint = view.results:count() == 0 and view.hint or nil
	return ui.dismissable{on_dismiss = close,
		ui.pane{id = "search", place = "full", max_width = ui.split_width("code"), scope = "list",
			ui.split{kind = "code",
				ui.column{separator = true,
					ui.row{height = 1,
						ui.text{fg = "pane_prompt_foreground", " > "},
						ui.editor{id = "search_query", buffer = view.query, height = 1, grow = 1, margin = {right = 1},
							scope = {"search", "editor"}, placeholder = "text to find"},
						ui.text{id = "search_count", fg = "pane_shortcut_foreground", count_text()},
					},
					ui.column{grow = 1,
						hint and ui.text{id = "search_hint", fg = "pane_shortcut_foreground", wrap = true, " ", hint} or false,
						ui.scroll{grow = 1,
							ui.virtual_column{id = "search_rows", data = view.results, item = result_row, highlight_style = SELECTED,
								on = {state = function() view.user_moved = true preview_soon() end}}},
					},
				},
				view.preview and ui.editor{id = "search_preview", buffer = view.preview.buffer, readonly = true, highlight_style = {bg = "pane_selection_background"},
					syntax = true, line_numbers = true} or ui.text{""},
			},
		},
	}
end

local function refresh(current)
	if view == current then
		view.handle:update(build())
	end
end

-- a burst of rg lines rebuilds the tree once
local function refresh_soon(current)
	if current.refresh_due then
		return
	end
	current.refresh_due = true
	qed.defer(0, function()
		current.refresh_due = false
		refresh(current)
	end)
end

local function run_query(current, text)
	stop()
	current.results:clear()
	current.capped = false
	current.user_moved, current.top_key = false, nil
	if #text < min_query then
		current.hint = short_hint()
		refresh(current)
		return
	end
	current.hint = nil
	refresh(current)
	local root, total, seen = qed.root(), 0, {}
	local proc, err = qed.spawn_bg{cmd = rg_cmd(text, current.args), on_line = function(line)
		if view ~= current or current.applied ~= text then
			return
		end
		local file, row, col, hit = line:match("^(.-):(%d+):(%d+):(.*)$")
		if not file or file == "" then
			return
		end
		local key = file .. "\0" .. ("%09d"):format(tonumber(row))
		if seen[key] then
			return
		end
		seen[key] = true
		total = total + 1
		if total > MAX then
			current.capped = true
			stop()
			refresh(current)
			return
		end
		current.results:append{
			key = key,
			label = ("%s:%s  %s"):format(file, row, hit:gsub("\r$", ""):match("^[ \t]*(.*)")),
			path = qed.path.join(root, file),
			pos = {row = tonumber(row), col = tonumber(col)},
		}
		-- the top row stays highlighted while hits stream in and sort, until the user moves
		local top = current.results:at(1)
		if not current.user_moved and top and top.key ~= current.top_key then
			current.top_key = top.key
			highlight(top.key)
		end
		refresh_soon(current)
	end}
	if not proc then
		current.hint = "Search failed: " .. err
		refresh(current)
		return
	end
	current.running = proc
	local result = proc:wait()
	if current.running == proc then
		current.running = nil
	end
	if view == current and current.applied == text and total == 0 and result then
		current.hint = result.code > 1 and ("Search failed: rg exit code %d"):format(result.code) or "No matches"
		refresh(current)
	end
end

-- typed keys run one search once typing pauses
local function query_changed(current)
	local text = current.query:text()
	if text == current.applied then
		return
	end
	current.applied = text
	current.due = (current.due or 0) + 1
	local token = current.due
	qed.defer(DEBOUNCE_MS, function()
		if view == current and current.due == token then
			run_query(current, text)
		end
	end)
end

function activate()
	if not view then
		return
	end
	local record = highlighted() or view.results:at(1)
	close()
	if record then
		qed.jump(record.path, record.pos)
	end
end

local function search(ctx, scope)
	if view then
		close()
		return
	end
	if not rg_ready() then
		qed.message("ripgrep (rg) not found", "error")
		return
	end
	local args = ""
	for _, path in ipairs(scope or {}) do
		args = args .. " " .. qed.shell_quote(path)
	end
	if args ~= "" then
		args = " --" .. args
	end
	local results = qed.list.new{key = "key"}
	results:sort("key")
	view = {results = results, query = qed.buf.create{internal = true}, args = args, applied = "", hint = short_hint(), build = build}
	view.handle = ui.mount("pane", build())
	local current = view
	view.query:on("change", function()
		if view == current then
			query_changed(current)
		end
	end)
	ui.node("search_query"):focus()
	local selection = ctx.selection_text
	if selection and not selection:find("\n") and selection:find("[^ \t]") then
		view.query:set_text(selection)
		view.query:set_selection({row = 1, col = 1}, {row = 1, col = #selection + 1})
		query_changed(current)
	end
end

local function search_tree(ctx)
	local tree = qed.plugin("filetree")
	local selection = tree and tree.selection()
	local paths, gone = {}, false
	for _, file in ipairs(selection and selection.files or {}) do
		if not qed.fs.exists(file) then
			gone = true
		else
			paths[#paths + 1] = qed.path.rel(file)
		end
	end
	if #paths == 0 then
		if gone then
			qed.message("Deleted file: restore it first")
		else
			qed.message("Nothing to search in selection")
		end
		return
	end
	search(ctx, paths)
end

local function state()
	if not view then
		return nil
	end
	local labels = {}
	for index = 1, view.results:count() do
		labels[index] = view.results:at(index).label
	end
	local record = highlighted()
	return {id = "search", query = view.query:text(), labels = labels, matches = #labels,
		selected = record and record.label or nil, hint = view.results:count() == 0 and view.hint or ""}
end

return {
	setup = function()
		qed.meta{description = "Project-wide search with ripgrep"}
		min_query = qed.options({min_query = 2}, {min_query = "Characters typed before a search runs"}).min_query
		qed.command{name = "In Files", key = "Alt+F", welcome = true, run = search}
		qed.command{name = "In Files", scope = "filetree", run = search_tree}
		qed.command{name = "Open", scope = "search", key = "Enter", run = activate}
		qed.command{name = "Close", scope = "search", key = "Esc", run = close}
		qed:on("config_changed", function() min_query = qed.config().min_query end)
		qed.export{state = state}
	end,
}
