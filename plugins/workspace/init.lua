local ACTIONS = {"Cancel", "Close All"}

local function picker(text)
	local tree = qed.plugin("filetree")
	return qed.ui.open{
		id = "workspace",
		fields = {{mode = "path", text = text}},
		list = {items = qed.fs.dirs{dotfiles = tree ~= nil and tree.dotfiles()}},
	}
end

-- reopen brings the picker back on the typed path to host the confirm or a retry
local function switch(target, reopen)
	local opts
	while true do
		local ok, err, info = qed.set_root(target, opts)
		if ok then
			return nil
		end
		local view = reopen and reopen()
		if err ~= "unsaved" then
			qed.message(err, "error")
			return view
		end
		local question = ("Close %d buffer%s? (%d unsaved)"):format(info.total, info.total == 1 and "" or "s", info.unsaved)
		if qed.confirm{question = question, choices = ACTIONS} ~= 2 then
			return view
		end
		if view then
			view:close()
		end
		opts = {discard = info.bufs}
	end
end

local function open_directory()
	local root = qed.root()
	local view = picker(root:sub(-1) == "/" and root or root .. "/")
	while view do
		local ok, _, target = view:wait()
		if not ok then
			return
		end
		local st = qed.fs.stat(target)
		if not st or st.type ~= "dir" then
			qed.message("Not a directory: " .. target, "error")
		else
			-- closed before the switch: restarting the servers can outlast the command's slice
			view:close()
			view = switch(target, function() return picker(target) end)
		end
	end
end

local function open_selected(ctx)
	local path = ctx.item and ctx.item.path
	if not path then
		return
	end
	local st = qed.fs.stat(path)
	if not st then
		qed.message("Deleted file: restore it first")
		return
	end
	switch(st.type == "dir" and path or qed.path.dir(path))
end

return {
	setup = function()
		qed.meta{description = "Switches the working root directory"}
		qed.command{name = "Open Directory", key = "Ctrl+o", welcome = true, run = open_directory}
		qed.command{name = "Open Selected Directory", keybind = "Open Directory", scope = "filetree", run = open_selected}
	end,
}
