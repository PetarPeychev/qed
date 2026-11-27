package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

// Every global in this file is user config: declared valueless, seeded from the
// embedded config/ JSON before main (config_seed_defaults), overridden by
// ~/.config/qed/. Program constants that the JSON does not set live with their
// subsystems, not here.

Config_Int :: struct {
	key: string,
	ptr: ^int,
}

Config_Bool :: struct {
	key: string,
	ptr: ^bool,
}

Config_Color :: struct {
	key: string,
	ptr: ^tb2.Color,
}

SCROLL_MARGIN: int
TAB_WIDTH: int
WHEEL_SCROLL_LINES: int
WHEEL_SCROLL_COLUMNS: int
DOUBLE_CLICK_MS: int
CURSOR_ACCEL_INTERVAL_MS: int
CURSOR_ACCEL_RAMP_PRESSES: int
CURSOR_ACCEL_MAX_STEP: int
PICKER_WIDTH: int
PICKER_MAX_ROWS: int
PANE_MAX_WIDTH: int
PREVIEW_DIFF_CONTEXT: int
ALT_ESC_TIMEOUT_MS: int
COMPLETION_MAX_ROWS: int
HOVER_MAX_WIDTH: int
COMPLETION_MIN_CHARS: int
JUMP_THRESHOLD: int
BIG_FILE_BYTES: int
SPLIT_TREE_MIN_WIDTH: int
SPLIT_TREE_MAX_WIDTH: int
SPLIT_CODE_MIN_WIDTH: int
SPLIT_CODE_MAX_WIDTH: int
SPLIT_PREVIEW_MIN_WIDTH: int
SPLIT_PREVIEW_MAX_WIDTH: int
PLUGIN_MEMORY_MB: int
PLUGIN_SLICE_MAX_MS: int
PLUGIN_COMMAND_MAX_MS: int
PLUGIN_HOOK_TIMEOUT_MS: int
IMAGE_MAX_ROWS: int

config_ints := [?]Config_Int {
	{"scroll_margin", &SCROLL_MARGIN},
	{"tab_width", &TAB_WIDTH},
	{"wheel_scroll_lines", &WHEEL_SCROLL_LINES},
	{"wheel_scroll_columns", &WHEEL_SCROLL_COLUMNS},
	{"double_click_ms", &DOUBLE_CLICK_MS},
	{"cursor_accel_interval_ms", &CURSOR_ACCEL_INTERVAL_MS},
	{"cursor_accel_ramp_presses", &CURSOR_ACCEL_RAMP_PRESSES},
	{"cursor_accel_max_step", &CURSOR_ACCEL_MAX_STEP},
	{"picker_width", &PICKER_WIDTH},
	{"picker_max_rows", &PICKER_MAX_ROWS},
	{"pane_max_width", &PANE_MAX_WIDTH},
	{"preview_diff_context", &PREVIEW_DIFF_CONTEXT},
	{"alt_esc_timeout_ms", &ALT_ESC_TIMEOUT_MS},
	{"jump_threshold", &JUMP_THRESHOLD},
	{"big_file_bytes", &BIG_FILE_BYTES},
	{"split_tree_min_width", &SPLIT_TREE_MIN_WIDTH},
	{"split_tree_max_width", &SPLIT_TREE_MAX_WIDTH},
	{"split_code_min_width", &SPLIT_CODE_MIN_WIDTH},
	{"split_code_max_width", &SPLIT_CODE_MAX_WIDTH},
	{"split_preview_min_width", &SPLIT_PREVIEW_MIN_WIDTH},
	{"split_preview_max_width", &SPLIT_PREVIEW_MAX_WIDTH},
	{"image_max_rows", &IMAGE_MAX_ROWS},
	{"plugin_memory_mb", &PLUGIN_MEMORY_MB},
	{"plugin_hook_timeout_ms", &PLUGIN_HOOK_TIMEOUT_MS},
	{"plugin_slice_max_ms", &PLUGIN_SLICE_MAX_MS},
	{"plugin_command_max_ms", &PLUGIN_COMMAND_MAX_MS},
}

CURSOR_ACCEL: bool
AUTO_CLOSE_PAIRS: bool
DIFF_VIEW: bool
LINE_WRAP: bool
LSP_ENABLED: bool

config_bools := [?]Config_Bool {
	{"cursor_accel", &CURSOR_ACCEL},
	{"auto_close_pairs", &AUTO_CLOSE_PAIRS},
	{"line_wrap", &LINE_WRAP},
	{"diff_view", &DIFF_VIEW},
}

Config_Str :: struct {
	key: string,
	ptr: ^string,
}

IMAGE_PROTOCOL: ImageSetting

Config_Section :: struct {
	name:  string,
	strs:  []Config_Str,
	ints:  []Config_Int,
	bools: []Config_Bool,
}


config_lsp_ints := [?]Config_Int {
	{"completion_max_rows", &COMPLETION_MAX_ROWS},
	{"completion_min_chars", &COMPLETION_MIN_CHARS},
	{"hover_max_width", &HOVER_MAX_WIDTH},
}

config_lsp_bools := [?]Config_Bool {
	{"enabled", &LSP_ENABLED},
}

config_lsp := Config_Section{"lsp", nil, config_lsp_ints[:], config_lsp_bools[:]}

Config_Float :: struct {
	key: string,
	ptr: ^f32,
}

COLOR_FG: tb2.Color
COLOR_BG: tb2.Color
COLOR_ERROR_FG: tb2.Color
COLOR_WARN_FG: tb2.Color
COLOR_DIAG_ERROR_FG: tb2.Color
COLOR_DIAG_WARN_FG: tb2.Color
COLOR_DIAG_INFO_FG: tb2.Color
COLOR_GUTTER_FG: tb2.Color
COLOR_GUTTER_BG: tb2.Color
COLOR_CURRENT_LINE_FG: tb2.Color
COLOR_CURRENT_LINE_BG: tb2.Color
COLOR_AI_EDIT_BG: tb2.Color
COLOR_GHOST_FG: tb2.Color
COLOR_PANE_FG: tb2.Color
COLOR_PANE_BG: tb2.Color
COLOR_PANE_BORDER: tb2.Color
COLOR_PANE_PROMPT_FG: tb2.Color
COLOR_PANE_SHORTCUT_FG: tb2.Color
COLOR_PANE_SEL_FG: tb2.Color
COLOR_PANE_SEL_BG: tb2.Color
COLOR_PANE_DIM_FG: tb2.Color
COLOR_TERM_FG: tb2.Color
COLOR_TERM_BG: tb2.Color
COLOR_TERM_ANSI: [16]tb2.Color
COLOR_SYN_KEYWORD: tb2.Color
COLOR_SYN_TYPE: tb2.Color
COLOR_SYN_STRING: tb2.Color
COLOR_SYN_COMMENT: tb2.Color
COLOR_SYN_CONSTANT: tb2.Color
COLOR_SYN_ATTRIBUTE: tb2.Color
COLOR_SYN_CODE: tb2.Color
COLOR_GIT_ADD: tb2.Color
COLOR_GIT_MOD: tb2.Color
COLOR_GIT_DEL: tb2.Color
COLOR_FIND_MATCH_BG: tb2.Color
COLOR_CONFLICT_OURS: tb2.Color
COLOR_CONFLICT_THEIRS: tb2.Color
COLOR_CONFLICT_BASE: tb2.Color

config_colors := [?]Config_Color {
	{"foreground", &COLOR_FG},
	{"background", &COLOR_BG},
	{"error_foreground", &COLOR_ERROR_FG},
	{"warn_foreground", &COLOR_WARN_FG},
	{"diagnostic_error_foreground", &COLOR_DIAG_ERROR_FG},
	{"diagnostic_warning_foreground", &COLOR_DIAG_WARN_FG},
	{"diagnostic_info_foreground", &COLOR_DIAG_INFO_FG},
	{"gutter_foreground", &COLOR_GUTTER_FG},
	{"gutter_background", &COLOR_GUTTER_BG},
	{"current_line_foreground", &COLOR_CURRENT_LINE_FG},
	{"current_line_background", &COLOR_CURRENT_LINE_BG},
	{"ai_edit_background", &COLOR_AI_EDIT_BG},
	{"ghost_foreground", &COLOR_GHOST_FG},
	{"pane_foreground", &COLOR_PANE_FG},
	{"pane_background", &COLOR_PANE_BG},
	{"pane_border", &COLOR_PANE_BORDER},
	{"pane_prompt_foreground", &COLOR_PANE_PROMPT_FG},
	{"pane_shortcut_foreground", &COLOR_PANE_SHORTCUT_FG},
	{"pane_selection_foreground", &COLOR_PANE_SEL_FG},
	{"pane_selection_background", &COLOR_PANE_SEL_BG},
	{"terminal_foreground", &COLOR_TERM_FG},
	{"terminal_background", &COLOR_TERM_BG},
	{"terminal_ansi_0", &COLOR_TERM_ANSI[0]},
	{"terminal_ansi_1", &COLOR_TERM_ANSI[1]},
	{"terminal_ansi_2", &COLOR_TERM_ANSI[2]},
	{"terminal_ansi_3", &COLOR_TERM_ANSI[3]},
	{"terminal_ansi_4", &COLOR_TERM_ANSI[4]},
	{"terminal_ansi_5", &COLOR_TERM_ANSI[5]},
	{"terminal_ansi_6", &COLOR_TERM_ANSI[6]},
	{"terminal_ansi_7", &COLOR_TERM_ANSI[7]},
	{"terminal_ansi_8", &COLOR_TERM_ANSI[8]},
	{"terminal_ansi_9", &COLOR_TERM_ANSI[9]},
	{"terminal_ansi_10", &COLOR_TERM_ANSI[10]},
	{"terminal_ansi_11", &COLOR_TERM_ANSI[11]},
	{"terminal_ansi_12", &COLOR_TERM_ANSI[12]},
	{"terminal_ansi_13", &COLOR_TERM_ANSI[13]},
	{"terminal_ansi_14", &COLOR_TERM_ANSI[14]},
	{"terminal_ansi_15", &COLOR_TERM_ANSI[15]},
	{"syntax_keyword", &COLOR_SYN_KEYWORD},
	{"syntax_type", &COLOR_SYN_TYPE},
	{"syntax_string", &COLOR_SYN_STRING},
	{"syntax_comment", &COLOR_SYN_COMMENT},
	{"syntax_constant", &COLOR_SYN_CONSTANT},
	{"syntax_attribute", &COLOR_SYN_ATTRIBUTE},
	{"syntax_code", &COLOR_SYN_CODE},
	{"git_added", &COLOR_GIT_ADD},
	{"git_modified", &COLOR_GIT_MOD},
	{"git_deleted", &COLOR_GIT_DEL},
	{"find_match_background", &COLOR_FIND_MATCH_BG},
	{"conflict_ours", &COLOR_CONFLICT_OURS},
	{"conflict_theirs", &COLOR_CONFLICT_THEIRS},
	{"conflict_base", &COLOR_CONFLICT_BASE},
	{"pane_dim_foreground", &COLOR_PANE_DIM_FG},
}

ICON_STATUS_FILE: string
ICON_STATUS_BRANCH: string
ICON_STATUS_AHEAD: string
ICON_STATUS_BEHIND: string
ICON_STATUS_DIFF_BASE: string
ICON_STATUS_LANG: string
ICON_STATUS_LSP: string
ICON_STATUS_INDENT: string
ICON_MODIFIED: string
ICON_TREE_EXPANDED: string
ICON_TREE_COLLAPSED: string
ICON_TREE_RENAMED: string
ICON_LSP_STARTING: string
ICON_LSP_FAILED: string
ICON_DIAG_ERROR: string
ICON_DIAG_WARN: string
ICON_DIAG_INFO: string

config_icons := [?]Config_Str {
	{"status_file", &ICON_STATUS_FILE},
	{"status_branch", &ICON_STATUS_BRANCH},
	{"status_ahead", &ICON_STATUS_AHEAD},
	{"status_behind", &ICON_STATUS_BEHIND},
	{"status_diff_base", &ICON_STATUS_DIFF_BASE},
	{"status_language", &ICON_STATUS_LANG},
	{"status_lsp", &ICON_STATUS_LSP},
	{"status_indent", &ICON_STATUS_INDENT},
	{"modified", &ICON_MODIFIED},
	{"tree_expanded", &ICON_TREE_EXPANDED},
	{"tree_collapsed", &ICON_TREE_COLLAPSED},
	{"tree_renamed", &ICON_TREE_RENAMED},
	{"lsp_starting", &ICON_LSP_STARTING},
	{"lsp_failed", &ICON_LSP_FAILED},
	{"diagnostic_error", &ICON_DIAG_ERROR},
	{"diagnostic_warning", &ICON_DIAG_WARN},
	{"diagnostic_info", &ICON_DIAG_INFO},
}

CURRENT_LINE_TINT: f32
AI_EDIT_TINT: f32
GIT_HUNK_TINT: f32
GIT_DIFF_GHOST_TINT: f32
GIT_DIFF_WORD_TINT: f32
CONFLICT_TINT: f32
CONFLICT_MARKER_TINT: f32
CONFLICT_WORD_TINT: f32
DECO_TINT: f32
MARKDOWN_CODE_TINT: f32
PANE_BACKDROP_TINT: f32

config_tints := [?]Config_Float {
	{"current_line", &CURRENT_LINE_TINT},
	{"ai_edit", &AI_EDIT_TINT},
	{"git_hunk", &GIT_HUNK_TINT},
	{"git_diff_ghost", &GIT_DIFF_GHOST_TINT},
	{"git_diff_word", &GIT_DIFF_WORD_TINT},
	{"conflict", &CONFLICT_TINT},
	{"conflict_marker", &CONFLICT_MARKER_TINT},
	{"conflict_word", &CONFLICT_WORD_TINT},
	{"decoration", &DECO_TINT},
	{"markdown_code", &MARKDOWN_CODE_TINT},
	{"pane_backdrop", &PANE_BACKDROP_TINT},
}

config_path :: proc(allocator := context.temp_allocator) -> string {
	if xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); xdg != "" {
		return fmt.aprintf("%s/qed/config.json", xdg, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return fmt.aprintf("%s/.config/qed/config.json", home, allocator = allocator)
}

parse_hex_color :: proc(s: string) -> (tb2.Color, bool) {
	if len(s) != 7 || s[0] != '#' {
		return {}, false
	}
	consumed: int
	v, ok := strconv.parse_u64_of_base(s[1:], 16, &consumed)
	if !ok || consumed != 6 {
		return {}, false
	}
	return tb2.Color(v), true
}

parse_keybind :: proc(s: string) -> (key: tb2.Key, alt_ch: rune, ok: bool) {
	if strings.has_prefix(s, "Alt+") {
		rest := s[4:]
		r, sz := utf8.decode_rune_in_string(rest)
		if sz == 0 || sz != len(rest) {
			return {}, 0, false
		}
		return tb2.Key(0), r, true
	}
	if strings.has_prefix(s, "Ctrl+") {
		rest := s[5:]
		if len(rest) == 1 {
			c := rest[0]
			switch {
			case (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'):
				return tb2.Key(c & 0x1f), 0, true
			case c == '/':
				return .Ctrl_Slash, 0, true
			case c == '~':
				return .Ctrl_Tilde, 0, true
			case c == '\\':
				return .Ctrl_Backslash, 0, true
			}
		}
	}
	return {}, 0, false
}

parse_bind :: proc(s: string) -> (key: tb2.Key, alt_ch, ch: rune, ok: bool) {
	if named, nok := ui_chord_named_key(s); nok {
		return named, 0, 0, true
	}
	if r, sz := utf8.decode_rune_in_string(s); sz > 0 && sz == len(s) && r > ' ' && r != utf8.RUNE_ERROR {
		return {}, 0, r, true
	}
	key, alt_ch, ok = parse_keybind(s)
	return
}

// a bare key would swallow typing in the editor; in a pane it fires only without a field
bind_bare_ok :: proc(scope: string) -> bool {
	return scope != ""
}

embedded_keybinds_data := #load("../config/keybinds.json")

g_config_defaults: json.Object
g_keybind_defaults: json.Object
g_theme_defaults: json.Object
g_config_user: json.Object
g_keybinds_user: json.Object
g_config_user_broken: bool

// Runs before main (and before tests): the valueless globals get their defaults from the
// declarations in config/options.lua and the binds in config/keybinds.json.
@(init)
config_seed_defaults :: proc "contextless" () {
	context = runtime.default_context()
	context.allocator = os.heap_allocator()
	core := options_core_declare()
	g_config_defaults = json.clone_value(core.default).(json.Object)
	kb_val, err := json.parse(embedded_keybinds_data, parse_integers = true)
	assert(err == nil, "embedded config/keybinds.json failed to parse")
	g_keybind_defaults = kb_val.(json.Object)
	name := string(g_config_defaults["theme"].(json.String))
	for bt in bundled_themes {
		if bt.name != name {
			continue
		}
		theme_val, terr := json.parse(bt.data, parse_integers = true)
		assert(terr == nil, "embedded default theme failed to parse")
		g_theme_defaults = theme_val.(json.Object)
	}
	assert(g_theme_defaults != nil, "config/options.lua theme must name a bundled theme")
	config_defaults_apply()
	theme_reset_defaults()
}

// Frees the string knobs that config_apply/theme_apply clone into globals. Runs
// once at program exit (after main + all tests), mirroring config_seed_defaults.
@(fini)
settings_destroy :: proc "contextless" () {
	context = runtime.default_context()
	theme_maps_clear()
	delete(g_theme_colors)
	delete(g_captures)
	delete(THEME, os.heap_allocator())
	for &cmd in commands {
		delete(cmd.shortcut, os.heap_allocator())
	}
	for &cmd in scoped_commands {
		delete(cmd.shortcut, os.heap_allocator())
	}
	for it in config_icons {
		delete(it.ptr^, os.heap_allocator())
	}
	config_user_set(nil)
	keybinds_user_set(nil)
}

config_user_set :: proc(root: json.Object) {
	json.destroy_value(g_config_user, os.heap_allocator())
	g_config_user = nil
	if root != nil {
		g_config_user = json.clone_value(root, os.heap_allocator()).(json.Object)
	}
}

keybinds_user_set :: proc(root: json.Object) {
	json.destroy_value(g_keybinds_user, os.heap_allocator())
	g_keybinds_user = nil
	if root != nil {
		g_keybinds_user = json.clone_value(root, os.heap_allocator()).(json.Object)
	}
}

keybinds_path :: proc(cfg_path: string, allocator := context.temp_allocator) -> string {
	dir := config_dir(cfg_path)
	if dir == "" {
		return ""
	}
	return fmt.aprintf("%s/keybinds.json", dir, allocator = allocator)
}

config_defaults_apply :: proc() {
	languages_reset_defaults()
	scratch := make([dynamic]string, context.temp_allocator)
	config_apply(g_config_defaults, &scratch)
	core := g_keybind_defaults["core"].(json.Object) or_else nil
	config_apply_keybinds(core, commands[:], &scratch)
	config_apply_keybinds(core, scoped_commands[:], &scratch)
}

config_load :: proc() -> (message: string, is_error: bool) {
	path := config_path()
	if path == "" {
		config_defaults_apply()
		config_user_set(nil)
		keybinds_user_set(nil)
		return theme_load(path)
	}
	return config_load_from(path)
}

config_load_from :: proc(path: string) -> (message: string, is_error: bool) {
	g_options_config_path = path
	defer g_options_config_path = ""
	config_defaults_apply()
	config_user_set(nil)
	g_config_user_broken = false

	problems := make([dynamic]string, context.temp_allocator)
	is_error = false

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err == nil {
		root_val, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
		if perr != nil {
			message = fmt.tprintf("config.json: parse error in %s, using defaults", path)
			is_error = true
			g_config_user_broken = true
		} else if root, is_obj := root_val.(json.Object); !is_obj {
			message = fmt.tprintf("config.json: %s is not a JSON object, using defaults", path)
			is_error = true
			g_config_user_broken = true
		} else {
			config_apply(config_merge(root, &problems), &problems)
			config_user_set(root)
			if len(problems) > 0 {
				slice.sort(problems[:])
				list := strings.join(problems[:], ", ", context.temp_allocator)
				message = fmt.tprintf("config.json: ignoring %s", list)
				is_error = true
			}
		}
	}

	keybinds_message := keybinds_load(keybinds_path(path))
	theme_message, theme_error := theme_load(path)
	message = theme_msg_join(theme_msg_join(message, keybinds_message), theme_message)
	is_error = is_error || theme_error || keybinds_message != ""
	return
}

// a name with a "Prefix: " may be a plugin command, checked once plugins registered theirs (keybinds_plugin_warn)
keybinds_load :: proc(path: string) -> string {
	keybinds_user_set(nil)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if path == "" || read_err != nil {
		return ""
	}
	root_val, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	root, is_obj := root_val.(json.Object)
	if perr != nil || !is_obj {
		return fmt.tprintf("keybinds.json: %s is not a JSON object, using the default binds", path)
	}
	problems := make([dynamic]string, context.temp_allocator)
	for group, v in root {
		if _, ok := v.(json.Object); !ok {
			append(&problems, fmt.tprintf("%q (expected an object of id to chord)", fmt.tprintf("keybinds.json/%s", group)))
		}
	}
	core, _ := root["core"].(json.Object)
	config_apply_keybinds(core, commands[:], &problems)
	config_apply_keybinds(core, scoped_commands[:], &problems)
	ids: for id in core {
		for table in ([?][]Command{commands[:], scoped_commands[:]}) {
			for cmd in table {
				if cmd.bind_from == "" && cmd.id == id {
					continue ids
				}
			}
		}
		append(&problems, config_unknown_msg(fmt.tprintf("keybinds.json/core/%s", id)))
	}
	keybinds_user_set(root)
	if len(problems) == 0 {
		return ""
	}
	slice.sort(problems[:])
	return fmt.tprintf("keybinds.json: ignoring %s", strings.join(problems[:], ", ", context.temp_allocator))
}

keybind_snake :: proc(name: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	gap := false
	for r in strings.to_lower(name, context.temp_allocator) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			if gap && strings.builder_len(sb) > 0 {
				strings.write_byte(&sb, '_')
			}
			strings.write_rune(&sb, r)
			gap = false
		} else {
			gap = true
		}
	}
	return strings.to_string(sb)
}

// where a bind left in config.json (an old name) would live in keybinds.json, for the warning
keybind_legacy_dest :: proc(group, name: string) -> string {
	old := fmt.tprintf("keybinds/%s", name) if group == "core" else fmt.tprintf("plugins/%s/keybinds/%s", group, name)
	if dest, moved := config_moved(old); moved {
		return dest
	}
	return fmt.tprintf("keybinds.json/%s/%s", group, keybind_snake(name))
}

config_apply_keybinds :: proc(kb_obj: json.Object, table: []Command, invalid: ^[dynamic]string) {
	set := make([]bool, len(table), context.temp_allocator)
	for &cmd, i in table {
		if cmd.bind_from != "" {
			continue
		}
		name := cmd.id
		v, has := kb_obj[name]
		if !has {
			continue
		}
		s, is_str := v.(json.String)
		if !is_str {
			append(invalid, fmt.tprintf("\"keybinds.json/core/%s\"", name))
			continue
		}
		if s == "" {
			cmd.key = tb2.Key(0)
			cmd.alt_ch = 0
			cmd.ch = 0
			delete(cmd.shortcut, os.heap_allocator())
			cmd.shortcut = ""
			continue
		}
		key, alt_ch, ch, pok := parse_bind(string(s))
		if !pok || (ch != 0 && !bind_bare_ok(cmd.scope)) {
			append(invalid, fmt.tprintf("\"keybinds.json/core/%s\"", name))
			continue
		}
		cmd.key = key
		cmd.alt_ch = alt_ch
		cmd.ch = ch
		delete(cmd.shortcut, os.heap_allocator())
		cmd.shortcut = strings.clone(string(s), os.heap_allocator())
		set[i] = true
	}
	// checked after every bind is set, so swapping two binds works
	for &cmd, i in table {
		if !set[i] || cmd.scope == "" || cmd.shortcut == "" {
			continue
		}
		for other, j in table {
			if j == i || other.scope != cmd.scope || (set[j] && j > i) {
				continue
			}
			_, _, sc := command_effective_bind(other)
			if sc == "" || ui_chord_normalize(sc) != ui_chord_normalize(cmd.shortcut) {
				continue
			}
			append(invalid, fmt.tprintf("\"keybinds.json/core/%s\" (%s is %q)", cmd.id, cmd.shortcut, other.name))
			delete(cmd.shortcut, os.heap_allocator())
			cmd.key, cmd.alt_ch, cmd.ch, cmd.shortcut = {}, 0, 0, ""
			break
		}
	}
}

config_apply_ints :: proc(obj: json.Object, tbl: []Config_Int) {
	for it in tbl {
		#partial switch n in obj[it.key] {
		case json.Integer:
			it.ptr^ = int(n)
		case json.Float:
			it.ptr^ = int(n)
		}
	}
}

config_apply_bools :: proc(obj: json.Object, tbl: []Config_Bool) {
	for it in tbl {
		if b, ok := obj[it.key].(json.Boolean); ok {
			it.ptr^ = bool(b)
		}
	}
}

// keybinds, plugins and modules have their own checks
config_merge :: proc(root: json.Object, problems: ^[dynamic]string) -> json.Object {
	user := make(json.Object, context.temp_allocator)
	for k, v in root {
		switch k {
		case "keybinds", "plugins", "modules":
			continue
		}
		user[k] = v
	}
	option_resolve(nil, g_core_options, "", problems)
	merged := option_merge(g_core_options, g_core_options.default, user, "", problems).(json.Object)
	if kb, has := root["keybinds"]; has {
		kb_obj, is_obj := kb.(json.Object)
		if !is_obj {
			append(problems, "\"keybinds\" (expected an object, and binds live in keybinds.json)")
		}
		for name in kb_obj {
			append(problems, fmt.tprintf("%q moved to %q", fmt.tprintf("keybinds/%s", name), keybind_legacy_dest("core", name)))
		}
	}
	if plugins_val, present := root["plugins"]; present {
		if plugins_obj, is_obj := plugins_val.(json.Object); is_obj {
			for name, v in plugins_obj {
				if _, ok := v.(json.Object); !ok {
					append(problems, fmt.tprintf("plugins/%s", name))
				}
			}
		} else {
			append(problems, "plugins")
		}
	}
	if mods_obj, ok := root["modules"].(json.Object); ok {
		for mod_key, mod_val in mods_obj {
			sub, is_obj := mod_val.(json.Object)
			if !is_obj {
				append(problems, config_unknown_msg(fmt.tprintf("modules/%s", mod_key)))
				continue
			}
			for key in sub {
				append(problems, config_unknown_msg(fmt.tprintf("modules/%s/%s", mod_key, key)))
			}
		}
	} else if _, has := root["modules"]; has {
		append(problems, config_unknown_msg("modules"))
	}
	return merged
}

// root is complete and checked: the defaults, or config_merge's result
config_apply :: proc(root: json.Object, invalid: ^[dynamic]string) {
	config_apply_ints(root, config_ints[:])
	config_apply_bools(root, config_bools[:])
	if s, ok := image_setting_parse(string(root["image_protocol"].(json.String) or_else "")); ok {
		IMAGE_PROTOCOL = s
	}
	if s, ok := root["theme"].(json.String); ok {
		delete(THEME, os.heap_allocator())
		THEME = strings.clone(string(s), os.heap_allocator())
	}
	if lang_obj, ok := root["languages"].(json.Object); ok {
		languages_from_config(lang_obj)
	}

	if lsp_obj, ok := root["lsp"].(json.Object); ok {
		config_apply_ints(lsp_obj, config_lsp.ints)
		config_apply_bools(lsp_obj, config_lsp.bools)
	}
}

CONFIG_MOVED :: [?][2]string {
	{"keybinds/Go to: Line", "keybinds.json/goto/line"},
	{"keybinds/Diff: Next Change", "keybinds.json/core/git_next_change"},
	{"keybinds/Diff: Previous Change", "keybinds.json/core/git_previous_change"},
	{"keybinds/Diff: Revert Hunk", "keybinds.json/core/git_revert_hunk"},
	{"keybinds/Diff: Toggle Diff View", "keybinds.json/core/git_toggle_diff_view"},
	{"keybinds/Diff: Toggle View", "keybinds.json/core/git_toggle_diff_view"},
	{"keybinds/File Tree: Changes", "keybinds.json/git/changes"},
	{"keybinds/Restore File", "keybinds.json/git/restore_file"},
	{"keybinds/Terminal: Toggle", "keybinds.json/terminal/toggle"},
	{"keybinds/Message Log: Open", "keybinds.json/log/open"},
	{"keybinds/Message Log: Toggle Debug", "keybinds.json/log/toggle_debug"},
	{"keybinds/Message Log: Toggle Info", "keybinds.json/log/toggle_info"},
	{"keybinds/Message Log: Toggle Warn", "keybinds.json/log/toggle_warn"},
	{"keybinds/Message Log: Toggle Error", "keybinds.json/log/toggle_error"},
	{"keybinds/Message Log: Toggle History", "keybinds.json/log/toggle_history"},
	{"keybinds/Git: Set Diff Base", "keybinds.json/git/set_diff_base"},
	{"keybinds/AI: Cancel Edits", "keybinds.json/ai/cancel_edits"},
	{"keybinds/AI: Edit Selection", "keybinds.json/ai/edit_selection"},
	{"keybinds/AI: Toggle Inline Completion", "keybinds.json/ai/toggle_inline_completion"},
	{"keybinds/File Tree: Delete", "keybinds.json/filetree/delete"},
	{"keybinds/File Tree: Expand/Collapse All", "keybinds.json/filetree/expand_collapse_all"},
	{"keybinds/File Tree: New", "keybinds.json/filetree/new"},
	{"keybinds/File Tree: Open", "keybinds.json/filetree/open"},
	{"keybinds/File Tree: Rename", "keybinds.json/filetree/rename"},
	{"keybinds/File Tree: Toggle Diff", "keybinds.json/filetree/toggle_diff"},
	{"keybinds/File Tree: Toggle Dotfiles", "keybinds.json/filetree/toggle_dotfiles"},
	{"keybinds/File Tree: Toggle Ignored", "keybinds.json/filetree/toggle_ignored"},
	{"keybinds/File Tree: Unsaved", "keybinds.json/filetree/unsaved"},
	{"plugins/settings/keybinds/Open", "keybinds.json/settings/open_config_ui"},
	{"plugins/settings/keybinds/Open Config", "keybinds.json/settings/open_config_json"},
	{"plugins/*/keybinds/Next", "keybinds.json/core/list_next"},
	{"plugins/*/keybinds/Previous", "keybinds.json/core/list_previous"},
	{"plugins/*/keybinds/Extend Down", "keybinds.json/core/list_extend_down"},
	{"plugins/*/keybinds/Extend Up", "keybinds.json/core/list_extend_up"},
	{"plugins_pane_max_width", "pane_max_width"},
	{"palette_max_rows", "picker_max_rows"},
	{"plugins/palette/width", "picker_width"},
	{"plugins/manager/max_width", "pane_max_width"},
	{"plugins/log/max_width", "pane_max_width"},
	{"plugins/settings/max_width", "pane_max_width"},
	{"plugins/markdown/max_width", "pane_max_width"},
	{"keybinds/Plugins: Open", "keybinds.json/manager/open"},
	{"keybinds/Plugins: Enable/Disable", "keybinds.json/manager/enable_disable"},
	{"keybinds/Plugins: Reload", "keybinds.json/manager/reload"},
	{"keybinds/Plugins: Show Log", "keybinds.json/manager/show_log"},
	{"terminal_escape_closes", "plugins/terminal/escape_closes"},
	{"message_log_max_width", "pane_max_width"},
	{"keybinds/Find", "keybinds.json/find/in_buffer"},
	{"keybinds/Replace", "keybinds.json/find/replace"},
	{"format_on_save", "plugins/format/on_save"},
	{"trim_trailing_whitespace_on_save", "plugins/format/trim_whitespace_on_save"},
	{"ensure_final_newline_on_save", "plugins/format/final_newline_on_save"},
	{"filetree_show_dotfiles", "plugins/filetree/show_dotfiles"},
	{"filetree_show_ignored", "plugins/filetree/show_ignored"},
	{"filetree_diff_only", "plugins/filetree/diff_only"},
	{"filetree_list_min_width", "split_tree_min_width"},
	{"filetree_list_max_width", "split_tree_max_width"},
	{"code_list_min_width", "split_code_min_width"},
	{"code_list_max_width", "split_code_max_width"},
	{"preview_min_width", "split_preview_min_width"},
	{"preview_max_width", "split_preview_max_width"},
	{"modules/lsp", "lsp"},
	{"modules/ai", "plugins/ai"},
	{"modules/ai/chat_command", "plugins/ai/edit_command"},
	{"modules/git", "plugins/git"},
	{"modules/git/diff_view", "diff_view"},
	{"modules/git/filetree_diff_only", "plugins/filetree/diff_only"},
	{"languages/*/formatter", "plugins/format/commands/*"},
	{"plugins/lines", "plugins/goto"},
	{"plugins/ai/chat_command", "plugins/ai/edit_command"},
	{"plugins/format/format_on_save", "plugins/format/on_save"},
	{"plugins/format/trim_trailing_whitespace_on_save", "plugins/format/trim_whitespace_on_save"},
	{"plugins/format/ensure_final_newline_on_save", "plugins/format/final_newline_on_save"},
	{"projsearch_min_query", "plugins/search/min_query"},
	{"plugins/pickers", "plugins/settings"},
	{"keybinds/Go to Start of File", "keybinds.json/core/go_to_start_of_file"},
	{"keybinds/Go to End of File", "keybinds.json/core/go_to_end_of_file"},
	{"keybinds/File Tree: Git", "keybinds.json/git/changes"},
	{"keybinds/Debug: Message Log", "keybinds.json/log/open"},
	{"keybinds/Debug: Plugins", "keybinds.json/manager/open"},
	{"keybinds/Find in Files", "keybinds.json/search/in_files"},
	{"keybinds/Set Theme", "keybinds.json/settings/theme"},
	{"keybinds/Set Language", "keybinds.json/settings/language"},
	{"keybinds/Change Indentation", "keybinds.json/settings/indentation"},
	{"keybinds/Format Document", "keybinds.json/format/document"},
	{"keybinds/Toggle Format on Save", "keybinds.json/format/toggle_on_save"},
	{"keybinds/Toggle Trim Whitespace on Save", "keybinds.json/format/toggle_trim_whitespace_on_save"},
	{"keybinds/Toggle Final Newline on Save", "keybinds.json/format/toggle_final_newline_on_save"},
	{"keybinds/Git: Resolve Conflict", "keybinds.json/conflict/resolve"},
	{"keybinds/File Tree: Restore File", "keybinds.json/git/restore_file"},
	{"keybinds/Change Working Directory", "keybinds.json/workspace/open_directory"},
	{"keybinds/Find Line", "keybinds.json/goto/line"},
	{"keybinds/File Tree", "keybinds.json/filetree/all"},
	{"keybinds/File Tree: Changed", "keybinds.json/git/changes"},
}

THEME_MOVED :: [?][2]string {
	{"filetree_ignored", "pane_dim_foreground"},
}

config_moved :: proc(path: string) -> (string, bool) {
	segs := strings.split(path, "/", context.temp_allocator)
	best, best_n := "", 0
	entries: for m in CONFIG_MOVED {
		old := strings.split(m[0], "/", context.temp_allocator)
		if len(old) > len(segs) || len(old) <= best_n {
			continue
		}
		star := ""
		for o, i in old {
			if o == "*" {
				star = segs[i]
			} else if o != segs[i] {
				continue entries
			}
		}
		dest, _ := strings.replace_all(m[1], "*", star, context.temp_allocator)
		rest := strings.join(segs[len(old):], "/", context.temp_allocator)
		best, best_n = dest if rest == "" else fmt.tprintf("%s/%s", dest, rest), len(old)
	}
	return best, best_n > 0
}

config_unknown_msg :: proc(path: string) -> string {
	if dest, ok := config_moved(path); ok {
		return fmt.tprintf("%q moved to %q", path, dest)
	}
	return fmt.tprintf("unknown %q", path)
}

THEME: string

// Syntax capture -> color mapping, theme-configurable. `g_theme_colors` is the
// theme's `colors` section resolved to values (known keys plus any user-defined
// extras); `g_captures` maps a capture name — or a `lang/capture` composite for a
// per-language override — to a color key + display attrs. Both accumulate through
// the same overlay chain as the rest of a theme (cleared once per resolve in
// theme_reset_defaults, then each theme_apply overlays per key). Heap-backed so
// they outlive any per-test allocator, like g_language_rules.
CaptureStyle :: struct {
	color_key: string,
	attrs:     u64,
}

g_theme_colors: map[string]tb2.Color
g_captures:     map[string]CaptureStyle

theme_maps_init :: proc() {
	if g_theme_colors == nil {
		g_theme_colors = make(map[string]tb2.Color, 64, os.heap_allocator())
	}
	if g_captures == nil {
		g_captures = make(map[string]CaptureStyle, 128, os.heap_allocator())
	}
}

theme_maps_clear :: proc() {
	theme_maps_init()
	for k in g_theme_colors {
		delete(k, os.heap_allocator())
	}
	clear(&g_theme_colors)
	for k, v in g_captures {
		delete(k, os.heap_allocator())
		delete(v.color_key, os.heap_allocator())
	}
	clear(&g_captures)
}

theme_color_set :: proc(key: string, col: tb2.Color) {
	if _, has := g_theme_colors[key]; has {
		g_theme_colors[key] = col
		return
	}
	g_theme_colors[strings.clone(key, os.heap_allocator())] = col
}

capture_set :: proc(comp_key: string, style: CaptureStyle) {
	if old, has := g_captures[comp_key]; has {
		delete(old.color_key, os.heap_allocator())
		g_captures[comp_key] = style
		return
	}
	g_captures[strings.clone(comp_key, os.heap_allocator())] = style
}

parse_capture_style :: proc(v: string) -> CaptureStyle {
	fields := strings.fields(v, context.temp_allocator)
	style: CaptureStyle
	if len(fields) == 0 {
		style.color_key = strings.clone("", os.heap_allocator())
		return style
	}
	style.color_key = strings.clone(fields[0], os.heap_allocator())
	for f in fields[1:] {
		switch f {
		case "bold":
			style.attrs |= u64(tb2.Color.Bold)
		case "italic":
			style.attrs |= u64(tb2.Color.Italic)
		case "underline":
			style.attrs |= u64(tb2.Color.Underline)
		case "reverse":
			style.attrs |= u64(tb2.Color.Reverse)
		}
	}
	return style
}

theme_captures_apply :: proc(obj: json.Object, invalid: ^[dynamic]string) {
	for key, v in obj {
		#partial switch t in v {
		case json.String:
			capture_set(key, parse_capture_style(string(t)))
		case json.Object:
			if _, ok := language_from_name(key); !ok {
				continue
			}
			for sub, sv in t {
				if s, is_str := sv.(json.String); is_str {
					capture_set(fmt.tprintf("%s/%s", key, sub), parse_capture_style(string(s)))
				}
			}
		}
	}
}

// Language-qualified first, then global, at each prefix-fallback step (strip a
// trailing `.segment` each round). Query-build path only; never per-node paint.
capture_style_find :: proc(
	caps: map[string]CaptureStyle,
	lang_name, name: string,
) -> (
	CaptureStyle,
	bool,
) {
	p := name
	for {
		if lang_name != "" {
			if v, ok := caps[fmt.tprintf("%s/%s", lang_name, p)]; ok {
				return v, true
			}
		}
		if v, ok := caps[p]; ok {
			return v, true
		}
		dot := strings.last_index_byte(p, '.')
		if dot < 0 {
			break
		}
		p = p[:dot]
	}
	return {}, false
}

capture_resolve :: proc(
	caps: map[string]CaptureStyle,
	colors: map[string]tb2.Color,
	lang_name, name: string,
) -> (
	tb2.Color,
	bool,
) {
	style, ok := capture_style_find(caps, lang_name, name)
	if !ok {
		return COLOR_FG, false
	}
	base, cok := colors[style.color_key]
	if !cok {
		return COLOR_FG, false
	}
	return tb2.Color(u64(base) | style.attrs), true
}

// Verbose sibling of capture_resolve for the token inspector: appends every
// composite key tried (in order, up to the hit) to `tried` and reports the color
// key and final color. `mapped` is whether the capture had a style entry;
// `resolved` is whether that style's color key also resolved. Not on the paint path.
capture_resolve_verbose :: proc(
	caps: map[string]CaptureStyle,
	colors: map[string]tb2.Color,
	lang_name, name: string,
	tried: ^[dynamic]string,
) -> (
	color_key: string,
	color: tb2.Color,
	attrs: u64,
	mapped: bool,
	resolved: bool,
) {
	p := name
	style: CaptureStyle
	find: for {
		if lang_name != "" {
			k := fmt.tprintf("%s/%s", lang_name, p)
			append(tried, k)
			if v, ok := caps[k]; ok {
				style = v
				mapped = true
				break find
			}
		}
		append(tried, p)
		if v, ok := caps[p]; ok {
			style = v
			mapped = true
			break find
		}
		dot := strings.last_index_byte(p, '.')
		if dot < 0 {
			break
		}
		p = p[:dot]
	}
	if !mapped {
		return "", COLOR_FG, 0, false, false
	}
	base, cok := colors[style.color_key]
	if !cok {
		return style.color_key, COLOR_FG, style.attrs, true, false
	}
	return style.color_key, tb2.Color(u64(base) | style.attrs), style.attrs, true, true
}

Bundled_Theme :: struct {
	name: string,
	data: []u8,
}

bundled_themes := [?]Bundled_Theme {
	{"default", #load("../config/themes/default.json")},
	{"atom-one-dark", #load("../config/themes/atom-one-dark.json")},
	{"dracula", #load("../config/themes/dracula.json")},
	{"nord", #load("../config/themes/nord.json")},
	{"gruvbox-dark", #load("../config/themes/gruvbox-dark.json")},
	{"tokyo-night", #load("../config/themes/tokyo-night.json")},
	{"catppuccin-mocha", #load("../config/themes/catppuccin-mocha.json")},
	{"catppuccin-latte", #load("../config/themes/catppuccin-latte.json")},
	{"solarized-light", #load("../config/themes/solarized-light.json")},
}

theme_path :: proc(cfg_path: string, name: string, allocator := context.temp_allocator) -> string {
	dir := config_dir(cfg_path)
	if dir == "" {
		return fmt.aprintf("themes/%s.json", name, allocator = allocator)
	}
	return fmt.aprintf("%s/themes/%s.json", dir, name, allocator = allocator)
}

theme_names :: proc(cfg_path: string, allocator := context.temp_allocator) -> []string {
	seen := make(map[string]bool, 16, context.temp_allocator)
	names := make([dynamic]string, allocator)
	if dir := config_dir(cfg_path); dir != "" {
		tdir := fmt.tprintf("%s/themes", dir)
		if infos, err := os.read_directory_by_path(tdir, -1, context.temp_allocator); err == nil {
			for info in infos {
				if info.type == .Directory || !strings.has_suffix(info.name, ".json") {
					continue
				}
				name := info.name[:len(info.name) - 5]
				if name in seen {
					continue
				}
				seen[name] = true
				append(&names, strings.clone(name, allocator))
			}
		}
	}
	for bt in bundled_themes {
		if bt.name in seen {
			continue
		}
		seen[bt.name] = true
		append(&names, strings.clone(bt.name, allocator))
	}
	slice.sort(names[:])
	return names[:]
}

theme_preview :: proc(cfg_path: string, name: string) -> bool {
	scratch := make([dynamic]string, context.temp_allocator)
	found, _, _ := theme_resolve(cfg_path, name, &scratch)
	return found
}

theme_persist :: proc(path, name: string) -> bool {
	delete(THEME, os.heap_allocator())
	THEME = strings.clone(name, os.heap_allocator())
	return path != "" && config_persist_key_to(path, "theme", json.String(name))
}

theme_reset_defaults :: proc() {
	theme_maps_clear()
	scratch := make([dynamic]string, context.temp_allocator)
	theme_apply(g_theme_defaults, &scratch)
}

theme_msg_join :: proc(a, b: string) -> string {
	if a == "" {
		return b
	}
	if b == "" {
		return a
	}
	return fmt.tprintf("%s; %s", a, b)
}

// Resolves a theme name onto the globals: the default theme as the crash-safe
// base, then the matching bundled theme (if any), then the user file overlaid
// per-key. `found` is false only when the name matches no bundled theme AND has no
// user file; `parse_err` flags an unreadable/malformed user file (base still applied).
theme_resolve :: proc(
	cfg_path, name: string,
	warnings: ^[dynamic]string,
) -> (
	found: bool,
	parse_err: bool,
	path: string,
) {
	theme_reset_defaults()

	is_bundled := false
	for bt in bundled_themes {
		if bt.name != name {
			continue
		}
		if v, e := json.parse(bt.data, parse_integers = true, allocator = context.temp_allocator);
		   e == nil {
			if obj, ok := v.(json.Object); ok {
				scratch := make([dynamic]string, context.temp_allocator)
				theme_apply(obj, &scratch)
				is_bundled = true
			}
		}
		break
	}

	path = theme_path(cfg_path, name)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return is_bundled, false, path
	}

	root_val, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil {
		return is_bundled, true, path
	}
	root, is_obj := root_val.(json.Object)
	if !is_obj {
		return is_bundled, true, path
	}

	theme_apply(root, warnings)
	theme_collect_unknown(root, warnings)
	return true, false, path
}

theme_load :: proc(cfg_path: string) -> (message: string, is_error: bool) {
	warnings := make([dynamic]string, context.temp_allocator)
	found, parse_err, path := theme_resolve(cfg_path, THEME, &warnings)

	if parse_err {
		return fmt.tprintf("theme %q: parse error in %s, using defaults", THEME, path), true
	}
	if !found {
		return fmt.tprintf("theme %q: no file %s, using defaults", THEME, path), true
	}
	if len(warnings) > 0 {
		slice.sort(warnings[:])
		list := strings.join(warnings[:], ", ", context.temp_allocator)
		return fmt.tprintf("theme %q: ignoring %s", THEME, list), true
	}
	return "", false
}

theme_apply :: proc(root: json.Object, invalid: ^[dynamic]string) {
	theme_maps_init()
	if col_val, has := root["colors"]; has {
		if col_obj, col_is_obj := col_val.(json.Object); col_is_obj {
			for c in config_colors {
				v, chas := col_obj[c.key]
				if !chas {
					continue
				}
				s, is_str := v.(json.String)
				if !is_str {
					append(invalid, fmt.tprintf("colors/%s", c.key))
					continue
				}
				col, cok := parse_hex_color(string(s))
				if !cok {
					append(invalid, fmt.tprintf("colors/%s", c.key))
					continue
				}
				c.ptr^ = col
			}
			// The colors section is open: any hex-valued key (known or user-defined)
			// is resolvable by a capture mapping.
			for key, v in col_obj {
				if s, is_str := v.(json.String); is_str {
					if col, cok := parse_hex_color(string(s)); cok {
						theme_color_set(key, col)
					}
				}
			}
		} else {
			append(invalid, "colors")
		}
	}

	if cap_val, has := root["captures"]; has {
		if cap_obj, cap_is_obj := cap_val.(json.Object); cap_is_obj {
			theme_captures_apply(cap_obj, invalid)
		} else {
			append(invalid, "captures")
		}
	}

	if ic_val, has := root["icons"]; has {
		if ic_obj, ic_is_obj := ic_val.(json.Object); ic_is_obj {
			for it in config_icons {
				v, ihas := ic_obj[it.key]
				if !ihas {
					continue
				}
				if s, is_str := v.(json.String); is_str {
					delete(it.ptr^, os.heap_allocator())
					it.ptr^ = strings.clone(string(s), os.heap_allocator())
				} else {
					append(invalid, fmt.tprintf("icons/%s", it.key))
				}
			}
		} else {
			append(invalid, "icons")
		}
	}

	if tn_val, has := root["tints"]; has {
		if tn_obj, tn_is_obj := tn_val.(json.Object); tn_is_obj {
			for it in config_tints {
				v, thas := tn_obj[it.key]
				if !thas {
					continue
				}
				#partial switch n in v {
				case json.Float:
					it.ptr^ = f32(n)
				case json.Integer:
					it.ptr^ = f32(n)
				case:
					append(invalid, fmt.tprintf("tints/%s", it.key))
				}
			}
		} else {
			append(invalid, "tints")
		}
	}
}

theme_collect_unknown :: proc(root: json.Object, warnings: ^[dynamic]string) {
	for key in root {
		switch key {
		case "colors", "icons", "tints", "captures":
			continue
		}
		append(warnings, fmt.tprintf("unknown key %q", key))
	}
	// The colors section is deliberately open (captures may reference user-defined
	// keys), so no per-key unknown check for it.
	if col_obj, ok := root["colors"].(json.Object); ok {
		for m in THEME_MOVED {
			if m[0] in col_obj {
				append(warnings, fmt.tprintf("%q moved to %q", fmt.tprintf("colors/%s", m[0]), fmt.tprintf("colors/%s", m[1])))
			}
		}
	}
	theme_captures_unknown(root, warnings)
	if ic_obj, ok := root["icons"].(json.Object); ok {
		for key in ic_obj {
			found := false
			for it in config_icons {
				if it.key == key {
					found = true
					break
				}
			}
			if !found {
				append(warnings, fmt.tprintf("unknown icons/%q", key))
			}
		}
	}
	if tn_obj, ok := root["tints"].(json.Object); ok {
		for key in tn_obj {
			found := false
			for it in config_tints {
				if it.key == key {
					found = true
					break
				}
			}
			if !found {
				append(warnings, fmt.tprintf("unknown tints/%q", key))
			}
		}
	}
}

// A captures value referencing a color key that doesn't resolve in the theme, or
// a language-override object keyed by an unknown language name, is reported once
// (and ignored, never rewritten) — same treatment as any unknown theme key.
theme_captures_unknown :: proc(root: json.Object, warnings: ^[dynamic]string) {
	cap_obj, ok := root["captures"].(json.Object)
	if !ok {
		return
	}
	for key, v in cap_obj {
		#partial switch t in v {
		case json.String:
			if !theme_color_key_ok(string(t)) {
				append(warnings, fmt.tprintf("captures/%s", key))
			}
		case json.Object:
			if _, lok := language_from_name(key); !lok {
				append(warnings, fmt.tprintf("captures/%q (unknown language)", key))
				continue
			}
			for sub, sv in t {
				s, is_str := sv.(json.String)
				if !is_str || !theme_color_key_ok(string(s)) {
					append(warnings, fmt.tprintf("captures/%s/%s", key, sub))
				}
			}
		case:
			append(warnings, fmt.tprintf("captures/%s", key))
		}
	}
}

theme_color_key_ok :: proc(v: string) -> bool {
	fields := strings.fields(v, context.temp_allocator)
	if len(fields) == 0 {
		return false
	}
	_, ok := g_theme_colors[fields[0]]
	return ok
}

languages_from_config :: proc(obj: json.Object) {
	rules := make([dynamic]LangRule, context.temp_allocator)
	for info, lang in LANGUAGES {
		entry, has := obj[info.name]
		if !has || lang == .MarkdownInline {
			continue
		}
		sub := entry.(json.Object) or_else nil
		for e in sub["patterns"].(json.Array) or_else nil {
			append(&rules, LangRule{strings.clone(string(e.(json.String) or_else ""), os.heap_allocator()), lang})
		}
		if s, is := sub["lsp"].(json.String); is {
			LANGUAGES[lang].lsp_server = strings.clone(string(s), os.heap_allocator())
		}
	}
	language_rules_set(rules[:])
}

config_persist_key_to :: proc(path: string, key: string, value: json.Value) -> bool {
	return config_persist_path_to(path, {key}, value)
}

config_persist_path_to :: proc(path: string, keys: []string, value: json.Value, remove := false) -> bool {
	root: json.Object
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil && strings.trim_space(string(data)) != "" {
		v, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
		o, ok := v.(json.Object)
		if perr != nil || !ok {
			return false
		}
		root = o
	}
	root = json_object_remove(root, keys) if remove else json_object_set(root, keys, value)

	if dir := config_dir(path); dir != "" {
		os.make_directory_all(dir)
	}
	sb := strings.builder_make(context.temp_allocator)
	json_write_value(&sb, root, 0)
	strings.write_byte(&sb, '\n')
	stamp := buffer_disk_stamp(path)
	mode := stamp.mode if stamp.ok else os.perm(0o644)
	return file_write_atomic(path, transmute([]byte)strings.to_string(sb), mode) == .None
}

json_object_set :: proc(obj: json.Object, keys: []string, value: json.Value) -> json.Object {
	obj := obj
	if obj == nil {
		obj = make(json.Object, context.temp_allocator)
	}
	if len(keys) == 1 {
		obj[keys[0]] = value
		return obj
	}
	sub, _ := obj[keys[0]].(json.Object)
	obj[keys[0]] = json_object_set(sub, keys[1:], value)
	return obj
}

json_object_remove :: proc(obj: json.Object, keys: []string) -> json.Object {
	obj := obj
	if obj == nil {
		return obj
	}
	if len(keys) == 1 {
		delete_key(&obj, keys[0])
		return obj
	}
	sub, ok := obj[keys[0]].(json.Object)
	if !ok {
		return obj
	}
	sub = json_object_remove(sub, keys[1:])
	if len(sub) == 0 {
		delete_key(&obj, keys[0])
	} else {
		obj[keys[0]] = sub
	}
	return obj
}

config_dir :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return ""
}

json_write_indent :: proc(sb: ^strings.Builder, n: int) {
	for _ in 0 ..< n {
		strings.write_byte(sb, ' ')
	}
}

// Pretty-prints a json.Value with sorted object keys so a rewritten user file is
// stable and diffable. Scalar arrays (e.g. language patterns) stay on one line.
json_write_value :: proc(sb: ^strings.Builder, v: json.Value, indent: int) {
	switch t in v {
	case json.Null:
		strings.write_string(sb, "null")
	case json.Integer:
		fmt.sbprintf(sb, "%d", t)
	case json.Float:
		fmt.sbprintf(sb, "%v", t)
	case json.Boolean:
		strings.write_string(sb, "true" if t else "false")
	case json.String:
		strings.write_string(sb, lsp_json_string(string(t)))
	case json.Array:
		strings.write_byte(sb, '[')
		for e, i in t {
			if i > 0 {
				strings.write_string(sb, ", ")
			}
			json_write_value(sb, e, indent)
		}
		strings.write_byte(sb, ']')
	case json.Object:
		if len(t) == 0 {
			strings.write_string(sb, "{}")
			return
		}
		keys := make([dynamic]string, 0, len(t), context.temp_allocator)
		for k in t {
			append(&keys, k)
		}
		slice.sort(keys[:])
		strings.write_string(sb, "{\n")
		for k, i in keys {
			json_write_indent(sb, indent + 2)
			strings.write_string(sb, lsp_json_string(k))
			strings.write_string(sb, ": ")
			json_write_value(sb, t[k], indent + 2)
			if i < len(keys) - 1 {
				strings.write_byte(sb, ',')
			}
			strings.write_byte(sb, '\n')
		}
		json_write_indent(sb, indent)
		strings.write_byte(sb, '}')
	}
}
