package main

import "core:c"
import "core:strings"
import lua "lib:lua"

UiMessagesFeed :: struct {
	active:   bool,
	levels:   [LogLevel]bool,
	history:  bool,
	source:   string,
	last_seq: u64,
}

ui_messages_admits :: proc(feed: ^UiMessagesFeed, entry: LogEntry) -> bool {
	return feed.levels[entry.level] && (!entry.seeded || feed.history) && (feed.source == "" || entry.source == feed.source)
}

ui_message_record_push :: proc(L: ^lua.State, entry: LogEntry) {
	lua.createtable(L, 0, 6)
	lua.pushinteger(L, lua.Integer(entry.seq))
	lua.setfield(L, -2, "seq")
	lua.pushodinstring(L, log_level_names[entry.level])
	lua.setfield(L, -2, "level")
	lua.pushodinstring(L, entry.source)
	lua.setfield(L, -2, "source")
	lua.pushodinstring(L, entry.text)
	lua.setfield(L, -2, "text")
	lua.pushodinstring(L, log_clock(entry.time))
	lua.setfield(L, -2, "time")
	lua.pushboolean(L, b32(entry.seeded))
	lua.setfield(L, -2, "seeded")
}

ui_messages_append :: proc(L: ^lua.State, editor: ^Editor, list: ^UiList) {
	feed := &list.feed
	first := editor.log[0].seq if len(editor.log) > 0 else editor.log_seq + 1
	evicted := 0
	for evicted < len(list.records) {
		seq := u64(0)
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(list.records[evicted].ref))
		lua.getfield(L, -1, "seq")
		seq = u64(lua.tointeger(L, -1))
		lua.pop(L, 2)
		if seq >= first {
			break
		}
		evicted += 1
	}
	if evicted > 0 {
		for record in list.records[:evicted] {
			lua.L_unref(L, lua.REGISTRYINDEX, c.int(record.ref))
			delete(record.key)
			delete(record.sort_str)
		}
		remove_range(&list.records, 0, evicted)
		ui_list_reindex(list)
		ui_list_changed(editor, list)
	}
	for entry in editor.log {
		if entry.seq <= feed.last_seq {
			continue
		}
		feed.last_seq = entry.seq
		if !ui_messages_admits(feed, entry) {
			continue
		}
		ui_message_record_push(L, entry)
		ui_list_store(L, editor, list, -1, len(list.records))
		lua.pop(L, 1)
	}
}

ui_messages_feed_c :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	editor := entry.editor
	for list in editor.ui.lists {
		if list.feed.active && list.feed.last_seq < editor.log_seq {
			ui_messages_append(L, editor, list)
		}
	}
	return 0
}

ui_messages_feed :: proc(editor: ^Editor) {
	plugins := &editor.plugins
	if plugins.L == nil {
		return
	}
	due := false
	for list in editor.ui.lists {
		due ||= list.feed.active && list.feed.last_seq < editor.log_seq
	}
	if !due {
		return
	}
	lua.pushcfunction(plugins.L, ui_messages_feed_c)
	plugin_call(editor, 0, 0)
}

qed_messages :: proc "c" (L: ^lua.State) -> c.int {
	entry := api_enter(L)
	context = entry.ctx
	editor := entry.editor
	feed := UiMessagesFeed{active = true, levels = {.Debug = false, .Info = true, .Warn = true, .Error = true}}
	if lua.type(L, 1) == .TABLE {
		if lua.getfield(L, 1, "levels") == .TABLE {
			for name, level in log_level_names {
				lua.getfield(L, -1, strings.clone_to_cstring(name, context.temp_allocator))
				feed.levels[level] = bool(lua.toboolean(L, -1))
				lua.pop(L, 1)
			}
		}
		lua.pop(L, 1)
		lua.getfield(L, 1, "history")
		feed.history = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		if source, ok := api_field_string(L, 1, "source"); ok {
			feed.source = source
		}
	}
	plugin := api_loaded(L, editor)
	lua.settop(L, 0)
	list := api_ui_list_push(L, editor, plugin.name, false)
	list.key_field = strings.clone("seq")
	feed.source = strings.clone(feed.source)
	list.feed = feed
	ui_messages_append(L, editor, list)
	return 1
}
