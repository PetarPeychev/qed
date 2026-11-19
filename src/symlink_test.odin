package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

symlink_is_link :: proc(path: string) -> bool {
	fi, err := os.lstat(path, context.temp_allocator)
	return err == nil && fi.type == .Symlink
}

symlink_read :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

@(test)
symlink_writes_keep_the_link :: proc(t: ^testing.T) {
	dir := reload_dir()
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
	os.make_directory(fmt.tprintf("%s/dots", dir))
	os.make_directory(fmt.tprintf("%s/links", dir))
	ln :: proc(target, link: string) {
		e2e_run(fmt.tprintf("ln -s %s %s", shell_quote(target), shell_quote(link)))
	}

	real := fmt.tprintf("%s/dots/buf.txt", dir)
	_ = os.write_entire_file(real, transmute([]u8)string("old"))
	ln("../dots/buf.txt", fmt.tprintf("%s/links/hop", dir))
	link := fmt.tprintf("%s/links/buf.txt", dir)
	ln("hop", link)
	b := buffer_new()
	defer buffer_destroy(&b)
	testing.expect_value(t, buffer_open(&b, link), BufferOpenError.None)
	buffer_insert(&b, {0, 0}, "new ")
	testing.expect_value(t, buffer_save(&b), BufferSaveError.None)
	testing.expect(t, symlink_is_link(link), "buffer_save keeps a relative symlink chain")
	testing.expect_value(t, symlink_read(real), "new old")
	testing.expect(t, !os.exists(fmt.tprintf("%s/links/buf.txt.qed-tmp", dir)), "no temp file is left beside the link")

	cfg_real := fmt.tprintf("%s/dots/config.json", dir)
	_ = os.write_entire_file(cfg_real, transmute([]u8)string(`{"tab_width": 2}`))
	cfg_link := fmt.tprintf("%s/links/config.json", dir)
	ln(cfg_real, cfg_link)
	testing.expect(t, config_persist_path_to(cfg_link, {"plugins", "p", "enabled"}, json.Boolean(false)), "persist through a symlink")
	testing.expect(t, symlink_is_link(cfg_link), "config persist keeps the link")
	testing.expect(t, strings.contains(symlink_read(cfg_real), `"tab_width": 2`) && strings.contains(symlink_read(cfg_real), `"enabled": false`), "the target gets the update")

	lua_real := fmt.tprintf("%s/dots/data.txt", dir)
	_ = os.write_entire_file(lua_real, transmute([]u8)string("x"))
	lua_link := fmt.tprintf("%s/links/data.txt", dir)
	ln(lua_real, lua_link)
	dangling := fmt.tprintf("%s/links/dangling.txt", dir)
	dangling_target := fmt.tprintf("%s/dots/created.txt", dir)
	ln(dangling_target, dangling)
	ed := plugin_test_editor({{"w.lua", fmt.tprintf(`
		assert(qed.fs.write(%q, "from lua"))
		assert(qed.fs.write(%q, "made"))
		return {{}}`, lua_link, dangling)}})
	defer plugin_test_destroy(ed)
	testing.expect_value(t, plugin_find(&ed.plugins, "w").state, PluginState.Enabled)
	testing.expect(t, symlink_is_link(lua_link), "qed.fs.write keeps the link")
	testing.expect_value(t, symlink_read(lua_real), "from lua")
	testing.expect(t, symlink_is_link(dangling), "a dangling link stays a link")
	testing.expect_value(t, symlink_read(dangling_target), "made")
}
