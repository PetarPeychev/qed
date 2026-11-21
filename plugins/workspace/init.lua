local ACTIONS = {"Cancel", "Close All"}

local function picker(text)
	local tree = qed.plugin("filetree")
	return qed.ui.open{
		id = "workspace",
		fields = {{mode = "path", text = text}},
		list = {items = qed.fs.dirs{dotfiles = tree ~= nil and tree.dotfiles()}},
	}
end

-- reopen brings the picker back (text and selection restored by id) to host the confirm or a retry
local function switch(target, reopen)
	local opts
	while true do
		local ok, err, info = qed.set_root(target, opts)
		if ok then
			return nil
		end
		local v = reopen and reopen()
		if err ~= "unsaved" then
			qed.message(err, "error")
			return v
		end
		local question = ("Close %d buffer%s? (%d unsaved)"):format(info.total, info.total == 1 and "" or "s", info.unsaved)
		if qed.confirm(question, ACTIONS) ~= 2 then
			return v
		end
		if v then
			v:close()
		end
		opts = {discard = info.bufs}
	end
end

local function open_directory()
	local root = qed.root()
	local v = picker(root:sub(-1) == "/" and root or root .. "/")
	while v do
		local ok, _, target = v:wait()
		if not ok then
			return
		end
		local st = qed.fs.stat(target)
		if not st or st.type ~= "dir" then
			qed.message("Not a directory: " .. target, "error")
		else
			-- closed before the switch: restarting the servers can outlast the command's slice
			v:close()
			v = switch(target, picker)
		end
	end
end

local function open_selected(ctx)
	if not ctx.file then
		return
	end
	local st = qed.fs.stat(ctx.file)
	if not st then
		qed.message("Deleted file: restore it first")
		return
	end
	switch(st.type == "dir" and ctx.file or qed.path.dir(ctx.file))
end

return {
	setup = function()
		qed.meta{description = "Switches the working root directory"}
		qed.command{name = "Open Directory", key = "Ctrl+o", welcome = true, run = open_directory}
		qed.command{name = "Open Selected Directory", keybind = "Open Directory", scope = "filetree", run = open_selected}
	end,
}
