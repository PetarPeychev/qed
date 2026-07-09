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

	dir := "/tmp/qed-cfg-test"
	os.make_directory_all(dir)

	// No file -> create a fully materialized config.
	create_path := fmt.tprintf("%s/create.json", dir)
	os.remove(create_path)
	msg, is_err := config_load_from(create_path)
	testing.expect(t, !is_err, "fresh create is not an error")
	testing.expect(t, strings.has_prefix(msg, "Created"), "reports creation")

	obj := reparse(t, create_path)
	for it in config_ints {
		_, present := obj[it.key]
		testing.expectf(t, present, "int key %s materialized", it.key)
	}
	for it in config_bools {
		_, present := obj[it.key]
		testing.expectf(t, present, "bool key %s materialized", it.key)
	}
	theme, theme_ok := obj["theme"].(json.Object)
	testing.expect(t, theme_ok, "theme materialized as object")
	colors, colors_ok := theme["colors"].(json.Object)
	testing.expect(t, colors_ok, "theme colors materialized as object")
	for c in config_colors {
		_, present := colors[c.key]
		testing.expectf(t, present, "theme color %s materialized", c.key)
	}
	icons, icons_ok := theme["icons"].(json.Object)
	testing.expect(t, icons_ok, "theme icons materialized as object")
	for it in config_icons {
		_, present := icons[it.key]
		testing.expectf(t, present, "theme icon %s materialized", it.key)
	}
	tints, tints_ok := theme["tints"].(json.Object)
	testing.expect(t, tints_ok, "theme tints materialized as object")
	for it in config_tints {
		_, present := tints[it.key]
		testing.expectf(t, present, "theme tint %s materialized", it.key)
	}
	kb, ok := obj["keybinds"].(json.Object)
	testing.expect(t, ok, "keybinds materialized as object")
	for cmd in commands {
		_, present := kb[cmd.name]
		testing.expectf(t, present, "keybind %s materialized", cmd.name)
	}
	ti, ti_ok := kb["Change Indentation"].(json.String)
	testing.expect(t, ti_ok && ti == "", "keyless command materialized as empty string")

	langs, langs_ok := obj["languages"].(json.Object)
	testing.expect(t, langs_ok, "languages materialized as object")
	py, py_ok := langs["python"].(json.Object)
	testing.expect(t, py_ok, "python materialized as object")
	pyf, pyf_ok := py["formatter"].(json.String)
	testing.expect(t, pyf_ok && pyf == "ruff format -", "python formatter default materialized")
	pyp, pyp_ok := py["patterns"].(json.Array)
	testing.expect(t, pyp_ok && len(pyp) == 2, "python patterns default materialized")

	// Language overrides: per-key merge, patterns drive detection, invalid subkey reported.
	saved_py_lsp := LANGUAGE_DEFAULTS[.Python].lsp_server
	defer languages_reset_defaults()
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
	testing.expect(t, py2_lsp, "omitted python lsp filled on rewrite")
	py2f, py2f_ok := py2["formatter"].(json.String)
	testing.expect(t, py2f_ok && string(py2f) == "black -", "override preserved on rewrite")

	// Partial file -> present value applied, missing keys filled in.
	// jump_threshold is read only by jump.odin (no parallel test touches it).
	saved_jump := JUMP_THRESHOLD
	defer JUMP_THRESHOLD = saved_jump
	miss_path := fmt.tprintf("%s/missing.json", dir)
	_ = os.write_entire_file(miss_path, transmute([]byte)string(`{"jump_threshold": 99}`))
	JUMP_THRESHOLD = 10
	_, is_err = config_load_from(miss_path)
	testing.expect(t, !is_err, "missing keys is not an error")
	testing.expect(t, JUMP_THRESHOLD == 99, "present value applied")
	obj = reparse(t, miss_path)
	jt, jt_ok := obj["jump_threshold"].(json.Integer)
	testing.expect(t, jt_ok && jt == 99, "present value preserved on rewrite")
	_, sm_present := obj["scroll_margin"]
	testing.expect(t, sm_present, "missing key filled")

	saved_fos := FORMAT_ON_SAVE
	defer FORMAT_ON_SAVE = saved_fos
	bool_path := fmt.tprintf("%s/bool.json", dir)
	_ = os.write_entire_file(bool_path, transmute([]byte)string(`{"format_on_save": true}`))
	FORMAT_ON_SAVE = false
	_, is_err = config_load_from(bool_path)
	testing.expect(t, !is_err, "bool value load is not an error")
	testing.expect(t, FORMAT_ON_SAVE, "bool value applied")

	// Invalid value -> keep default at runtime, report it, preserve it in the file.
	bad_path := fmt.tprintf("%s/invalid.json", dir)
	_ = os.write_entire_file(bad_path, transmute([]byte)string(`{"theme": {"colors": {"foreground": "#nothex"}}}`))
	saved_fg := COLOR_FG
	defer COLOR_FG = saved_fg
	COLOR_FG = tb2.Color(0xf4f4ff)
	before := COLOR_FG
	msg, is_err = config_load_from(bad_path)
	testing.expect(t, is_err, "invalid value reports an error")
	testing.expect(t, strings.contains(msg, "foreground"), "names the invalid key")
	testing.expect(t, COLOR_FG == before, "invalid value keeps default")
	obj = reparse(t, bad_path)
	theme2, theme2_ok := obj["theme"].(json.Object)
	testing.expect(t, theme2_ok, "theme preserved as object")
	colors2, colors2_ok := theme2["colors"].(json.Object)
	testing.expect(t, colors2_ok, "theme colors preserved as object")
	fg, fg_ok := colors2["foreground"].(json.String)
	testing.expect(t, fg_ok && string(fg) == "#nothex", "invalid value preserved in file")
}
