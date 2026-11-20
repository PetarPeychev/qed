package main

import "core:c"
import "core:fmt"
import "core:strings"
import lua "lib:lua"

// TEMPORARY: carries the provider API to the filetree plugin until plugin exports (panes.md M6)
TreeShim :: struct {
	owner:     string,
	refs:      [3]i32,
	status:    i32,
	base:      i32,
	base_path: string,
	listener:  string,
	listen:    i32,
}

tree_shim_unref :: proc(editor: ^Editor, ref: ^i32) {
	if ref^ != 0 && editor.plugins.L != nil {
		lua.L_unref(editor.plugins.L, lua.REGISTRYINDEX, c.int(ref^))
	}
	ref^ = 0
}

tree_shim_destroy :: proc(s: ^TreeShim) {
	delete(s.base_path)
	s^ = {}
}

tree_shim_live :: proc(editor: ^Editor, owner: string, ref: i32) -> bool {
	s := &editor.plugins.shim
	if owner == s.listener && ref == s.listen {
		return true
	}
	return owner == s.owner && (ref == s.refs[0] || ref == s.refs[1] || ref == s.refs[2])
}

tree_shim_notify :: proc(editor: ^Editor, kind: string) {
	s := &editor.plugins.shim
	if s.listen == 0 {
		return
	}
	if kind != "base" {
		for q in editor.plugins.queue {
			if q.ref == s.listen && q.a == kind {
				return
			}
		}
	}
	plugin_queue(editor, {ref = s.listen, only = s.listener, a = kind})
}

tree_shim_base_reset :: proc(editor: ^Editor, path: string) {
	s := &editor.plugins.shim
	tree_shim_unref(editor, &s.base)
	delete(s.base_path)
	s.base_path = strings.clone(path)
}

tree_shim_provider_clear :: proc(editor: ^Editor) {
	s := &editor.plugins.shim
	if s.owner == "" {
		return
	}
	for &ref in s.refs {
		tree_shim_unref(editor, &ref)
	}
	tree_shim_unref(editor, &s.status)
	tree_shim_base_reset(editor, "")
	s.owner = ""
	tree_shim_notify(editor, "provider")
}

tree_shim_unload :: proc(editor: ^Editor, owner: string) {
	s := &editor.plugins.shim
	if owner == "" {
		return
	}
	if s.owner == owner {
		tree_shim_provider_clear(editor)
	}
	if s.listener == owner {
		tree_shim_unref(editor, &s.listen)
		s.listener = ""
	}
}

qed_filetree_provide :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	s := &editor.plugins.shim
	pl := api_loaded(L, editor)
	if lua.type(L, 1) <= .NIL {
		if s.owner == pl.name {
			tree_shim_provider_clear(editor)
		}
		lua.pushboolean(L, true)
		return 1
	}
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "table or nil expected")
	}
	lua.settop(L, 1)
	names := [3]cstring{"refresh", "preview", "open_deleted"}
	for name in names {
		if tp := lua.getfield(L, 1, name); tp != .FUNCTION && tp != .NIL {
			plugin_raise(L, fmt.tprintf("%s must be a function", name))
		}
	}
	if s.owner != "" && s.owner != pl.name {
		lua.pushnil(L)
		lua.pushodinstring(L, fmt.tprintf("taken by %s", plugin_label(&editor.plugins, s.owner)))
		return 2
	}
	fresh := s.owner == ""
	for &ref in s.refs {
		tree_shim_unref(editor, &ref)
	}
	for i := 2; i >= 0; i -= 1 {
		if lua.type(L, -1) == .FUNCTION {
			s.refs[i] = i32(lua.L_ref(L, lua.REGISTRYINDEX))
		} else {
			lua.pop(L, 1)
		}
	}
	if fresh {
		s.owner = plugin_name_intern(&editor.plugins, pl.name)
		tree_shim_notify(editor, "provider")
	}
	lua.pushboolean(L, true)
	return 1
}

tree_shim_provider_check :: proc(L: ^lua.State, editor: ^Editor) {
	pl := api_loaded(L, editor)
	if editor.plugins.shim.owner != pl.name {
		plugin_raise(L, "not the file tree status provider (call qed.filetree.provide first)")
	}
}

qed_filetree_set_status :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	tree_shim_provider_check(L, editor)
	if lua.type(L, 1) != .TABLE {
		lua.L_argerror(L, 1, "files table expected")
	}
	ignored_t := lua.type(L, 2)
	if ignored_t != .TABLE && ignored_t > .NIL {
		lua.L_argerror(L, 2, "ignored list expected")
	}
	lua.settop(L, 2)
	lua.L_checkstack(L, 8, "file tree status")
	lua.createtable(L, 0, 2)
	lua.createtable(L, 0, 0)
	files := lua.gettop(L)
	lua.pushnil(L)
	for lua.next(L, 1) != 0 {
		if lua.type(L, -2) != .STRING || lua.type(L, -1) != .TABLE {
			plugin_raise(L, "files: path = {mark, from?, added?, removed?} expected")
		}
		key, _ := lua.toodinstring(L, -2)
		v := lua.absindex(L, -1)
		mark, _ := api_field_string(L, v, "mark")
		if mark != "added" && mark != "modified" && mark != "deleted" {
			plugin_raise(L, fmt.tprintf("files[%q].mark must be \"added\", \"modified\" or \"deleted\"", key))
		}
		added, aok := api_field_int(L, v, "added")
		removed, rok := api_field_int(L, v, "removed")
		if added < 0 || removed < 0 {
			plugin_raise(L, fmt.tprintf("files[%q]: added and removed must not be negative", key))
		}
		lua.pushodinstring(L, api_path(editor, key))
		lua.createtable(L, 0, 4)
		lua.pushodinstring(L, mark)
		lua.setfield(L, -2, "mark")
		if from, ok := api_field_string(L, v, "from"); ok && from != "" {
			lua.pushodinstring(L, api_path(editor, from))
			lua.setfield(L, -2, "from")
		}
		if aok || rok {
			lua.pushinteger(L, lua.Integer(added))
			lua.setfield(L, -2, "added")
			lua.pushinteger(L, lua.Integer(removed))
			lua.setfield(L, -2, "removed")
		}
		lua.rawset(L, files)
		lua.pop(L, 1)
	}
	lua.setfield(L, files - 1, "files")
	if ignored_t == .TABLE {
		n := int(lua.rawlen(L, 2))
		lua.createtable(L, c.int(n), 0)
		for i in 1 ..= n {
			if lua.rawgeti(L, 2, lua.Integer(i)) != .STRING {
				plugin_raise(L, "ignored must be a list of paths")
			}
			sv, _ := lua.toodinstring(L, -1)
			lua.pushodinstring(L, api_path(editor, sv))
			lua.rawseti(L, -3, lua.Integer(i))
			lua.pop(L, 1)
		}
		lua.setfield(L, -2, "ignored")
	}
	s := &editor.plugins.shim
	tree_shim_unref(editor, &s.status)
	s.status = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	tree_shim_unref(editor, &s.base)
	tree_shim_notify(editor, "status")
	editor_log(editor, .Debug, "Files", fmt.tprintf("file tree status from %s", s.owner))
	return 0
}

qed_filetree_set_base :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	tree_shim_provider_check(L, editor)
	s := &editor.plugins.shim
	path := api_path(editor, api_string(L, 1))
	if path != s.base_path {
		return 0
	}
	lua.settop(L, 2)
	if lua.type(L, 2) > .NIL {
		lua.pushodinstring(L, api_bytes_arg(L, 2))
	} else {
		lua.pushboolean(L, false)
	}
	tree_shim_unref(editor, &s.base)
	s.base = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	tree_shim_notify(editor, "base")
	return 0
}

qed_filetree_listen :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	s := &editor.plugins.shim
	pl := api_loaded(L, editor)
	if lua.type(L, 1) != .FUNCTION {
		lua.L_argerror(L, 1, "function expected")
	}
	if s.listener != "" && s.listener != pl.name {
		lua.pushnil(L)
		lua.pushodinstring(L, fmt.tprintf("taken by %s", plugin_label(&editor.plugins, s.listener)))
		return 2
	}
	tree_shim_unref(editor, &s.listen)
	lua.settop(L, 1)
	s.listen = i32(lua.L_ref(L, lua.REGISTRYINDEX))
	s.listener = plugin_name_intern(&editor.plugins, pl.name)
	lua.pushboolean(L, true)
	return 1
}

qed_filetree_state :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	s := &entry.editor.plugins.shim
	lua.createtable(L, 0, 5)
	lua.pushboolean(L, b32(s.owner != ""))
	lua.setfield(L, -2, "provider")
	if s.status != 0 {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(s.status))
		lua.getfield(L, -1, "files")
		lua.setfield(L, -3, "files")
		lua.getfield(L, -1, "ignored")
		lua.setfield(L, -3, "ignored")
		lua.pop(L, 1)
	}
	if s.base != 0 {
		lua.pushodinstring(L, s.base_path)
		lua.setfield(L, -2, "base_path")
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(s.base))
		if lua.type(L, -1) == .STRING {
			lua.setfield(L, -2, "base")
		} else {
			lua.pop(L, 1)
		}
	}
	return 1
}

qed_filetree_request :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	s := &editor.plugins.shim
	kind := api_string(L, 1)
	ok := false
	switch kind {
	case "refresh":
		if ok = s.refs[0] != 0; ok {
			for q in editor.plugins.queue {
				if q.ref == s.refs[0] {
					lua.pushboolean(L, true)
					return 1
				}
			}
			plugin_queue(editor, {ref = s.refs[0], only = s.owner})
		}
	case "preview":
		path := api_path(editor, api_string(L, 2))
		if ok = s.refs[1] != 0; ok {
			tree_shim_base_reset(editor, path)
			plugin_queue(editor, {ref = s.refs[1], a = path, only = s.owner})
		}
	case "open_deleted":
		if ok = s.refs[2] != 0; ok {
			plugin_task_start(editor, s.owner, .Command, {ref = s.refs[2], args = .Ctx, user = true})
		}
	case:
		lua.L_argerror(L, 1, `"refresh", "preview" or "open_deleted" expected`)
	}
	lua.pushboolean(L, b32(ok))
	return 1
}
