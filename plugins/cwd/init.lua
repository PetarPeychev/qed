local ACTIONS = {"Cancel", "Close all"}

local function under(path, root)
	if root == "/" then
		return path:sub(1, 1) == "/"
	end
	return #path > #root and path:sub(1, #root) == root and path:sub(#root + 1, #root + 1) == "/"
end

local function unsaved_question(target)
	local total, unsaved = 0, 0
	for _, b in ipairs(qed.buf.list()) do
		local path = qed.buf.path(b)
		if path ~= "" and not under(path, target) then
			total = total + 1
			if qed.buf.modified(b) then
				unsaved = unsaved + 1
			end
		end
	end
	if unsaved > 0 then
		return ("Close %d buffer%s? (%d unsaved)"):format(total, total == 1 and "" or "s", unsaved)
	end
end

local function switch(target)
	if target == qed.root() then
		return true
	end
	local question = unsaved_question(target)
	if question and qed.confirm(question, ACTIONS) ~= 2 then
		return false
	end
	qed.set_root(target)
	return true
end

local function change()
	local root = qed.root()
	local v = qed.ui.open{
		fields = {{mode = "path", text = root:sub(-1) == "/" and root or root .. "/"}},
		list = {items = qed.fs.dirs()},
	}
	if not v then
		return
	end
	while true do
		local ok, _, target = v:wait()
		if not ok then
			return
		end
		local st = qed.fs.stat(target)
		if not st or st.type ~= "dir" then
			qed.message("Not a directory: " .. target, "error")
		elseif switch(target) then
			v:close()
			return
		end
	end
end

local function set_from_tree(ctx)
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
		qed.command{name = "Change Working Directory", key = "Ctrl+o", welcome = true, run = change}
		qed.command{name = "Set as Working Directory", keybind = "Change Working Directory", scope = "filetree", run = set_from_tree}
	end,
}
