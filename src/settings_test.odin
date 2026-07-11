package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "lib:tb2"

// Tests run in parallel; serialize the ones that mutate/read the global
// language-rule table (single-threaded at runtime, so no production lock).
g_lang_rules_test_mu: sync.Mutex

@(private = "file")
reparse :: proc(t: ^testing.T, path: string) -> json.Object {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "config file should exist")
	v, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, perr == nil, "config file should parse")
	obj, ok := v.(json.Object)
	testing.expect(t, ok, "config root should be an object")
	return obj
}

@(test)
test_config_hex_color :: proc(t: ^testing.T) {
	c, ok := parse_hex_color("#1b2c3d")
	testing.expect(t, ok && u64(c) == 0x1b2c3d, "valid hex parses")
	_, bad := parse_hex_color("#zzzzzz")
	testing.expect(t, !bad, "non-hex rejected")
	_, short := parse_hex_color("#123")
	testing.expect(t, !short, "short rejected")
	_, nohash := parse_hex_color("1b2c3d")
	testing.expect(t, !nohash, "missing # rejected")
}

@(test)
test_bundled_themes_complete :: proc(t: ^testing.T) {
	for bt in bundled_themes {
		root_val, err := json.parse(bt.data, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "theme %s parses", bt.name)
		root, is_obj := root_val.(json.Object)
		testing.expectf(t, is_obj, "theme %s root is an object", bt.name)
		colors, cok := root["colors"].(json.Object)
		testing.expectf(t, cok, "theme %s has colors", bt.name)
		for c in config_colors {
			s, sok := colors[c.key].(json.String)
			testing.expectf(t, sok, "theme %s colors/%s present", bt.name, c.key)
			_, hok := parse_hex_color(string(s))
			testing.expectf(t, hok, "theme %s colors/%s valid hex", bt.name, c.key)
		}
		icons, iok := root["icons"].(json.Object)
		testing.expectf(t, iok, "theme %s has icons", bt.name)
		for it in config_icons {
			_, sok := icons[it.key].(json.String)
			testing.expectf(t, sok, "theme %s icons/%s present", bt.name, it.key)
		}
		tints, tok := root["tints"].(json.Object)
		testing.expectf(t, tok, "theme %s has tints", bt.name)
		for it in config_tints {
			num_ok := false
			#partial switch _ in tints[it.key] {
			case json.Float, json.Integer:
				num_ok = true
			}
			testing.expectf(t, num_ok, "theme %s tints/%s present", bt.name, it.key)
		}
	}
}

@(test)
test_embedded_config_complete :: proc(t: ^testing.T) {
	for it in config_ints {
		num_ok := false
		#partial switch _ in g_config_defaults[it.key] {
		case json.Integer, json.Float:
			num_ok = true
		}
		testing.expectf(t, num_ok, "embedded int %s", it.key)
	}
	for it in config_bools {
		_, ok := g_config_defaults[it.key].(json.Boolean)
		testing.expectf(t, ok, "embedded bool %s", it.key)
	}
	name, name_ok := g_config_defaults["theme"].(json.String)
	testing.expect(t, name_ok, "embedded theme is a string")
	found := false
	for bt in bundled_themes {
		if bt.name == string(name) {
			found = true
		}
	}
	testing.expect(t, found, "embedded theme names a bundled theme")
	kb, kb_ok := g_config_defaults["keybinds"].(json.Object)
	testing.expect(t, kb_ok, "embedded keybinds object")
	for cmd in commands {
		s, ok := kb[cmd.name].(json.String)
		testing.expectf(t, ok, "embedded keybind %q present", cmd.name)
		if ok && s != "" {
			_, _, pok := parse_keybind(string(s))
			testing.expectf(t, pok, "embedded keybind %q parses", cmd.name)
		}
	}
	langs, langs_ok := g_config_defaults["languages"].(json.Object)
	testing.expect(t, langs_ok, "embedded languages object")
	testing.expect(t, len(langs) > 0, "embedded languages non-empty")
	for key, sub_val in langs {
		_, known := language_from_name(key)
		testing.expectf(t, known, "embedded language %s is known", key)
		sub, sub_ok := sub_val.(json.Object)
		testing.expectf(t, sub_ok, "embedded language %s is an object", key)
		_, p_ok := sub["patterns"].(json.Array)
		testing.expectf(t, p_ok, "embedded language %s has patterns", key)
		_, l_ok := sub["lsp"].(json.String)
		testing.expectf(t, l_ok, "embedded language %s has lsp", key)
		_, f_ok := sub["formatter"].(json.String)
		testing.expectf(t, f_ok, "embedded language %s has formatter", key)
	}
	llm, llm_ok := g_config_defaults["llm"].(json.Object)
	testing.expect(t, llm_ok, "embedded llm object")
	for it in config_llm {
		_, ok := llm[it.key].(json.String)
		testing.expectf(t, ok, "embedded llm %s", it.key)
	}
	for it in config_llm_ints {
		num_ok := false
		#partial switch _ in llm[it.key] {
		case json.Integer, json.Float:
			num_ok = true
		}
		testing.expectf(t, num_ok, "embedded llm %s", it.key)
	}
	for it in config_llm_bools {
		_, ok := llm[it.key].(json.Boolean)
		testing.expectf(t, ok, "embedded llm %s", it.key)
	}
}

@(test)
test_config_keybind :: proc(t: ^testing.T) {
	k, a, ok := parse_keybind("Ctrl+S")
	testing.expect(t, ok && k == .Ctrl_S && a == 0, "Ctrl+S")
	k, a, ok = parse_keybind("Alt+f")
	testing.expect(t, ok && a == 'f', "Alt+f lowercase")
	_, a2, ok2 := parse_keybind("Alt+F")
	testing.expect(t, ok2 && a2 == 'F', "Alt+F uppercase distinct")
	k, _, ok = parse_keybind("Ctrl+/")
	testing.expect(t, ok && k == .Ctrl_Slash, "Ctrl+/")
	_, _, bad := parse_keybind("Ctrl+Enter")
	testing.expect(t, !bad, "multi-char Ctrl rejected")
	_, _, bad2 := parse_keybind("F5")
	testing.expect(t, !bad2, "unprefixed rejected")
}

// One sequential test: the file scenarios mutate shared config globals, so they
// must not run concurrently with each other (the rest of the suite is parallel).
// The lock also fences off test_language_of_extensions, which reads the same
// global language-rule table this test rebuilds via config_load_from.
@(test)
test_config_files :: proc(t: ^testing.T) {
	sync.lock(&g_lang_rules_test_mu)
	defer sync.unlock(&g_lang_rules_test_mu)
	// Restore every touched global to embedded defaults for the rest of the suite.
	defer {
		config_defaults_apply()
		theme_reset_defaults()
	}

	dir := "/tmp/qed-cfg-test"
	os.make_directory_all(dir)
	themes_dir := fmt.tprintf("%s/themes", dir)
	os.make_directory_all(themes_dir)

	// No user file -> pure embedded defaults, no message, and NOTHING is written:
	// no config file, no materialized themes.
	create_path := fmt.tprintf("%s/create.json", dir)
	os.remove(create_path)
	for bt in bundled_themes {
		os.remove(fmt.tprintf("%s/themes/%s.json", dir, bt.name))
	}
	msg, is_err := config_load_from(create_path)
	testing.expect(t, !is_err, "no file is not an error")
	testing.expect(t, msg == "", "no file yields no message")
	_, cstat := os.stat(create_path, context.temp_allocator)
	testing.expect(t, cstat != nil, "config file is not materialized")
	for bt in bundled_themes {
		_, bstat := os.stat(fmt.tprintf("%s/themes/%s.json", dir, bt.name), context.temp_allocator)
		testing.expectf(t, bstat != nil, "bundled theme %s is not materialized", bt.name)
	}

	// Per-key overlay: present value applied, missing keys keep defaults, file untouched.
	// jump_threshold is read only by jump.odin (no parallel test touches it).
	miss_path := fmt.tprintf("%s/missing.json", dir)
	_ = os.write_entire_file(miss_path, transmute([]byte)string(`{"jump_threshold": 99}`))
	JUMP_THRESHOLD = 10
	SCROLL_MARGIN = 0
	_, is_err = config_load_from(miss_path)
	testing.expect(t, !is_err, "partial file is not an error")
	testing.expect(t, JUMP_THRESHOLD == 99, "present value applied")
	testing.expect(t, SCROLL_MARGIN == 10, "missing key keeps embedded default")
	obj := reparse(t, miss_path)
	testing.expect(t, len(obj) == 1, "partial file not rewritten with defaults")
	jt, jt_ok := obj["jump_threshold"].(json.Integer)
	testing.expect(t, jt_ok && jt == 99, "present value preserved in file")

	bool_path := fmt.tprintf("%s/bool.json", dir)
	_ = os.write_entire_file(bool_path, transmute([]byte)string(`{"format_on_save": true}`))
	FORMAT_ON_SAVE = false
	_, is_err = config_load_from(bool_path)
	testing.expect(t, !is_err, "bool value load is not an error")
	testing.expect(t, FORMAT_ON_SAVE, "bool value applied")

	// Language overrides: per-key merge, patterns drive detection, invalid subkey
	// reported, unknown key untouched in file.
	saved_py_lsp := LANGUAGES[.Python].lsp_server
	lang_path := fmt.tprintf("%s/languages.json", dir)
	_ = os.write_entire_file(
		lang_path,
		transmute([]byte)string(
			`{"languages": {"python": {"patterns": ["*.py", "*.myext"], "formatter": "black -"}, "lua": {"lsp": 5}}}`,
		),
	)
	msg, is_err = config_load_from(lang_path)
	testing.expect(t, is_err, "invalid lsp type reports an error")
	testing.expect(t, strings.contains(msg, "languages/lua/lsp"), "names the invalid subkey")
	testing.expect(t, LANGUAGES[.Python].formatter == "black -", "python formatter override applied")
	testing.expect(t, LANGUAGES[.Python].lsp_server == saved_py_lsp, "omitted lsp keeps default")
	testing.expect(t, language_of("x.myext") == .Python, "custom pattern drives detection")
	testing.expect(t, language_of("x.py") == .Python, "listed pattern still detected")
	obj = reparse(t, lang_path)
	langs2, _ := obj["languages"].(json.Object)
	py2, _ := langs2["python"].(json.Object)
	_, py2_lsp := py2["lsp"]
	testing.expect(t, !py2_lsp, "omitted python lsp is NOT filled into user file")

	// Unknown top-level key: warned, file untouched.
	unknown_path := fmt.tprintf("%s/unknown.json", dir)
	_ = os.write_entire_file(unknown_path, transmute([]byte)string(`{"totally_bogus": 5}`))
	msg, is_err = config_load_from(unknown_path)
	testing.expect(t, is_err, "unknown key reports a warning")
	testing.expect(t, strings.contains(msg, "totally_bogus"), "names the unknown key")
	obj = reparse(t, unknown_path)
	testing.expect(t, len(obj) == 1, "unknown key not stripped from file")
	_, bogus_present := obj["totally_bogus"]
	testing.expect(t, bogus_present, "unknown key still present in file")

	// Malformed JSON: clear error naming the file, defaults applied, file untouched.
	SCROLL_MARGIN = 0
	malformed_path := fmt.tprintf("%s/malformed.json", dir)
	_ = os.write_entire_file(malformed_path, transmute([]byte)string(`{ not valid json`))
	msg, is_err = config_load_from(malformed_path)
	testing.expect(t, is_err, "malformed config reports an error")
	testing.expect(t, strings.contains(msg, "parse error"), "reports a parse error")
	testing.expect(t, SCROLL_MARGIN == 10, "malformed config falls back to defaults")
	mdata, _ := os.read_entire_file(malformed_path, context.temp_allocator)
	testing.expect(t, strings.contains(string(mdata), "not valid"), "malformed file left untouched")

	// Hot-reload revert: a present override, then deleting the file, reverts to defaults.
	reload_path := fmt.tprintf("%s/reload.json", dir)
	_ = os.write_entire_file(reload_path, transmute([]byte)string(`{"jump_threshold": 77}`))
	_, _ = config_load_from(reload_path)
	testing.expect(t, JUMP_THRESHOLD == 77, "override applied before deletion")
	os.remove(reload_path)
	_, _ = config_load_from(reload_path)
	testing.expect(t, JUMP_THRESHOLD == 10, "deleting user file reverts to embedded default")

	// Same-name theme: user themes/gruber-darker.json overrides one color, the rest
	// come from the bundled gruber-darker (default theme).
	gruber_over := fmt.tprintf("%s/themes/gruber-darker.json", dir)
	_ = os.write_entire_file(gruber_over, transmute([]byte)string(`{"colors": {"foreground": "#010203"}}`))
	msg, is_err = config_load_from(create_path)
	testing.expect(t, !is_err, "same-name theme overlay is not an error")
	testing.expect(t, COLOR_FG == tb2.Color(0x010203), "same-name theme override applied")
	testing.expect(t, COLOR_BG == tb2.Color(0x181818), "unset key comes from the bundled theme")
	os.remove(gruber_over)

	// New-name theme (no bundled match): partial user file, missing keys fall back to
	// the DEFAULT theme (gruber-darker) so a partial file never crashes.
	newname_cfg := fmt.tprintf("%s/newname.json", dir)
	newname_theme := fmt.tprintf("%s/themes/mytheme.json", dir)
	_ = os.write_entire_file(newname_cfg, transmute([]byte)string(`{"theme": "mytheme"}`))
	_ = os.write_entire_file(newname_theme, transmute([]byte)string(`{"colors": {"foreground": "#040506"}}`))
	msg, is_err = config_load_from(newname_cfg)
	testing.expect(t, !is_err, "partial new-name theme is not an error")
	testing.expect(t, COLOR_FG == tb2.Color(0x040506), "new-name theme override applied")
	testing.expect(t, COLOR_BG == tb2.Color(0x181818), "missing key falls back to default theme")
	os.remove(newname_theme)
	os.remove(newname_cfg)

	// Missing non-default theme -> error, no file created.
	nf_path := fmt.tprintf("%s/notheme.json", dir)
	_ = os.write_entire_file(nf_path, transmute([]byte)string(`{"theme": "nope"}`))
	msg, is_err = config_load_from(nf_path)
	testing.expect(t, is_err, "missing named theme reports an error")
	testing.expect(t, strings.contains(msg, "nope"), "names the missing theme")
	_, nope_err := os.stat(fmt.tprintf("%s/themes/nope.json", dir), context.temp_allocator)
	testing.expect(t, nope_err != nil, "non-default theme is not materialized")

	// Malformed theme file -> error naming the theme, falls back to bundled/default, no crash.
	badtheme_cfg := fmt.tprintf("%s/badtheme.json", dir)
	bad_theme_file := fmt.tprintf("%s/themes/bad.json", dir)
	_ = os.write_entire_file(badtheme_cfg, transmute([]byte)string(`{"theme": "bad"}`))
	_ = os.write_entire_file(bad_theme_file, transmute([]byte)string(`{ not json`))
	msg, is_err = config_load_from(badtheme_cfg)
	testing.expect(t, is_err, "malformed theme reports an error")
	testing.expect(t, strings.contains(msg, "parse error"), "reports a theme parse error")
	testing.expect(t, COLOR_BG == tb2.Color(0x181818), "malformed theme falls back to default theme")
	bt_data, _ := os.read_entire_file(bad_theme_file, context.temp_allocator)
	testing.expect(t, strings.contains(string(bt_data), "not json"), "malformed theme left untouched")

	// Invalid color value -> reported, kept at default, file preserved (never rewritten).
	inv_cfg := fmt.tprintf("%s/invalidtheme.json", dir)
	inv_theme := fmt.tprintf("%s/themes/inv.json", dir)
	_ = os.write_entire_file(inv_cfg, transmute([]byte)string(`{"theme": "inv"}`))
	_ = os.write_entire_file(inv_theme, transmute([]byte)string(`{"colors": {"foreground": "#nothex"}, "extra": 1}`))
	msg, is_err = config_load_from(inv_cfg)
	testing.expect(t, is_err, "invalid color reports an error")
	testing.expect(t, strings.contains(msg, "foreground"), "names the invalid color key")
	testing.expect(t, COLOR_FG == tb2.Color(0xf4f4ff), "invalid color keeps default-theme value")
	tobj := reparse(t, inv_theme)
	testing.expect(t, len(tobj) == 2, "invalid theme file not rewritten")
	fgv, _ := tobj["colors"].(json.Object)
	fg, fg_ok := fgv["foreground"].(json.String)
	testing.expect(t, fg_ok && string(fg) == "#nothex", "invalid value preserved in file")

	// Single-key persist preserves unrelated user content; creates a file if none.
	persist_path := fmt.tprintf("%s/persist.json", dir)
	_ = os.write_entire_file(persist_path, transmute([]byte)string(`{"jump_threshold": 42, "theme": "old"}`))
	ok := config_persist_key_to(persist_path, "theme", json.String("newtheme"))
	testing.expect(t, ok, "persist succeeds")
	obj = reparse(t, persist_path)
	testing.expect(t, len(obj) == 2, "persist keeps unrelated keys, adds none")
	pt, pt_ok := obj["theme"].(json.String)
	testing.expect(t, pt_ok && string(pt) == "newtheme", "persisted key replaced")
	pj, pj_ok := obj["jump_threshold"].(json.Integer)
	testing.expect(t, pj_ok && pj == 42, "unrelated key preserved verbatim")

	fresh_path := fmt.tprintf("%s/fresh.json", dir)
	os.remove(fresh_path)
	ok = config_persist_key_to(fresh_path, "theme", json.String("solo"))
	testing.expect(t, ok, "persist creates a missing file")
	obj = reparse(t, fresh_path)
	testing.expect(t, len(obj) == 1, "fresh file holds only the persisted key")
	st, st_ok := obj["theme"].(json.String)
	testing.expect(t, st_ok && string(st) == "solo", "fresh file holds the persisted value")
}
