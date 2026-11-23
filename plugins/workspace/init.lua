local ui = qed.ui

local ACTIONS = {"Cancel", "Close All"}
local WIDTH = 64
local SELECTED = {bg = "pane_selection_background", fg = "pane_selection_foreground"}

local view
local drill

local function home()
	return os.getenv("HOME") or "/"
end

-- the typed text up to its last "/" names the dir, the rest prefix-matches its subdirs
local function split(text)
	local slash = text:match("^.*()/")
	if not slash then
		return "", text
	end
	if slash == 1 then
		return "/", text:sub(2)
	end
	return text:sub(1, slash - 1), text:sub(slash + 1)
end

local function resolve(text)
	if text == "" then
		return qed.root()
	end
	if text == "~" then
		return qed.path.abs(home())
	end
	if text:sub(1, 2) == "~/" then
		return qed.path.join(home(), text:sub(3))
	end
	return qed.path.abs(text)
end

local function back(text)
	local trimmed = text:gsub("/+$", "")
	if trimmed == "" then
		return "/"
	end
	if trimmed == "~" then
		local parent = qed.path.dir(qed.path.abs(home()))
		return parent == "/" and "/" or parent .. "/"
	end
	local segment = trimmed:match("[^/]*$")
	return text:sub(1, #trimmed - #segment)
end

local function subdirs(dir)
	local names = {}
	for _, name in ipairs(qed.fs.list(dir) or {}) do
		if view.dotfiles or name:sub(1, 1) ~= "." then
			local info = qed.fs.stat(qed.path.join(dir, name))
			if info and info.type == "dir" then
				names[#names + 1] = name
			end
		end
	end
	table.sort(names)
	return names
end

local function prefix_match(name, term)
	if term:find("%u") then
		return name:sub(1, #term) == term
	end
	return name:sub(1, #term):lower() == term
end

local function close()
	if not view then
		return
	end
	local closing = view
	view = nil
	closing.handle:unmount()
	closing.query:close()
end

local function highlighted()
	local state = ui.node("workspace_rows"):state()
	local key = state and state.highlighted
	return key and view.dirs:get(key) or nil
end

local function dir_row(record)
	return ui.row{
		on = {
			click = function()
				ui.node("workspace_rows"):set_state{highlighted = record.name}
				return true
			end,
			double_click = function()
				ui.node("workspace_rows"):set_state{highlighted = record.name}
				drill()
				return true
			end,
		},
		ui.text{grow = 1, " ", record.name},
	}
end

local function build()
	return ui.dismissable{on_dismiss = close,
		ui.box{id = "workspace", float = "screen", anchor = "top", width = WIDTH, height = "fit",
			margin = {top = 3, right = 2, bottom = 2, left = 2},
			border = true, bg = "pane_background", fg = "pane_foreground",
			ui.column{
				ui.row{height = 1,
					ui.text{fg = "pane_prompt_foreground", "> "},
					ui.editor{id = "workspace_query", buffer = view.query, height = 1, grow = 1, scope = {"workspace", "editor"}},
				},
				ui.scroll{height = {"fit", max = qed.opt("palette_max_rows")},
					ui.virtual_column{id = "workspace_rows", data = view.dirs, item = dir_row, highlight_style = SELECTED}},
			},
		},
	}
end

local function query_sync()
	local text = view.query:text()
	if text:find("\n") then
		view.query:set_text((text:gsub("\r?\n", "")))
		return
	end
	if text == view.applied then
		return
	end
	view.applied = text
	local typed, term = split(text)
	local dir = resolve(typed)
	if dir ~= view.dir then
		view.dir, view.names = dir, subdirs(dir)
	end
	view.dirs:clear()
	for _, name in ipairs(view.names) do
		if prefix_match(name, term) then
			view.dirs:append{name = name, path = qed.path.join(dir, name)}
		end
	end
	local first = view.dirs:at(1)
	ui.node("workspace_rows"):set_state{highlighted = first and first.name or false}
end

local function set_query(text)
	view.query:set_text(text)
	view.query:set_cursor({row = 1, col = #text + 1})
	query_sync()
end

function drill()
	if not view then
		return
	end
	query_sync()
	local record = highlighted()
	if record then
		local text = view.query:text()
		set_query(text:sub(1, #(text:match("^.*/") or "")) .. record.name .. "/")
	end
end

local function caret_at_end()
	local cursor = view.query:cursor()
	return view.query:selection() == nil and cursor.col == #view.query:text() + 1
end

local function type_text(text)
	local from, to = view.query:selection()
	if from then
		view.query:replace(from, to, text)
	else
		view.query:insert(view.query:cursor(), text)
	end
	query_sync()
end

local function slash()
	query_sync()
	if caret_at_end() and view.dirs:count() > 0 then
		drill()
	else
		type_text("/")
	end
end

local function backspace()
	local text = view.query:text()
	if caret_at_end() and text:sub(-1) == "/" then
		set_query(back(text))
		return
	end
	local from, to = view.query:selection()
	if from then
		view.query:delete(from, to)
	else
		local cursor = view.query:cursor()
		if cursor.col > 1 then
			local before = text:sub(1, cursor.col - 1)
			local last = utf8.offset(before, -1) or cursor.col - 1
			view.query:delete({row = 1, col = last}, cursor)
		end
	end
	query_sync()
end

local function move(step)
	if not view then
		return
	end
	query_sync()
	local count = view.dirs:count()
	if count == 0 then
		return
	end
	local record = highlighted()
	local index = record and view.dirs:index_of(record.name) or 0
	ui.node("workspace_rows"):set_state{highlighted = view.dirs:at(math.max(1, math.min(count, index + step))).name}
end

local function picker(text)
	local tree = qed.plugin("filetree")
	view = {query = qed.buf.create{internal = true}, dirs = qed.list.new{key = "name"}, applied = false,
		dotfiles = tree ~= nil and tree.dotfiles()}
	view.handle = ui.mount("pane", build())
	local current = view
	view.query:on("change", function()
		if view == current then
			query_sync()
		end
	end)
	ui.node("workspace_query"):focus()
	set_query(text)
end

-- the picker (when given) stays open under the unsaved confirm and closes once the switch happens
local function switch(target)
	local opts
	while true do
		local ok, err, info = qed.set_root(target, opts)
		if ok then
			close()
			return
		end
		if err ~= "unsaved" then
			qed.message(err, "error")
			return
		end
		local question = ("Close %d buffer%s? (%d unsaved)"):format(info.total, info.total == 1 and "" or "s", info.unsaved)
		if qed.confirm{question = question, choices = ACTIONS} ~= 2 then
			return
		end
		opts = {discard = info.bufs}
	end
end

local function commit()
	if not view then
		return
	end
	local target = resolve(view.query:text())
	local info = qed.fs.stat(target)
	if not info or info.type ~= "dir" then
		qed.message("Not a directory: " .. target, "error")
		return
	end
	switch(target)
end

local function open_directory()
	if view then
		close()
		return
	end
	local root = qed.root()
	picker(root:sub(-1) == "/" and root or root .. "/")
end

local function open_selected()
	local tree = qed.plugin("filetree")
	local selection = tree and tree.selection()
	local path = selection and selection.item and selection.item.path
	if not path then
		return
	end
	local info = qed.fs.stat(path)
	if not info then
		qed.message("Deleted file: restore it first")
		return
	end
	switch(info.type == "dir" and path or qed.path.dir(path))
end

local function state()
	if not view then
		return nil
	end
	query_sync()
	local labels, paths = {}, {}
	for index = 1, view.dirs:count() do
		local record = view.dirs:at(index)
		labels[index], paths[index] = record.name, record.path
	end
	local record = highlighted()
	local from, to = view.query:selection()
	return {query = view.query:text(), labels = labels, paths = paths, selected = record and record.name or nil,
		caret = view.query:cursor().col - 1, selection = from and {from.col - 1, to.col - 1} or nil}
end

return {
	setup = function()
		qed.meta{description = "Switches the working root directory"}
		qed.command{name = "Open Directory", key = "Ctrl+o", welcome = true, run = open_directory}
		qed.command{name = "Open Selected Directory", keybind = "Open Directory", scope = "filetree", run = open_selected}
		qed.command{name = "Next", scope = "workspace", key = "Down", run = function() move(1) end}
		qed.command{name = "Previous", scope = "workspace", key = "Up", run = function() move(-1) end}
		qed.command{name = "Drill", scope = "workspace", key = "Tab", run = drill}
		qed.command{name = "Slash", scope = "workspace", key = "/", run = slash}
		qed.command{name = "Back", scope = "workspace", key = "Backspace", run = backspace}
		qed.command{name = "Switch", scope = "workspace", key = "Enter", run = commit}
		qed.command{name = "Close", scope = "workspace", key = "Esc", run = close}
		qed.export{state = state, set_query = function(text) if view then set_query(text) end end}
	end,
}
