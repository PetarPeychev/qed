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
DOUBLE_CLICK_MS: int
DISK_POLL_MS: int
CURSOR_ACCEL_INTERVAL_MS: int
CURSOR_ACCEL_RAMP_PRESSES: int
CURSOR_ACCEL_MAX_STEP: int
PALETTE_WIDTH: int
PALETTE_MAX_ROWS: int
PICKER_MARGIN_X: int
PICKER_MARGIN_Y: int
PROJSEARCH_MAX: int
PROJSEARCH_MIN_QUERY: int
PREVIEW_MAX_LINES: int
PREVIEW_PARSE_AHEAD: int
PREVIEW_DIFF_CONTEXT: int
ALT_ESC_TIMEOUT_MS: int
LSP_POLL_MS: int
DIAG_PANE_MARGIN_X: int
DIAG_PANE_MAX_LINES: int
COMPLETION_DEBOUNCE_MS: int
COMPLETION_MAX_ROWS: int
COMPLETION_MAX_WIDTH: int
COMPLETION_MIN_CHARS: int
JUMP_THRESHOLD: int
GIT_DIFF_MAX_D: int
GIT_STAT_POLL_MS: int
BIG_FILE_BYTES: int

config_ints := [?]Config_Int {
	{"scroll_margin", &SCROLL_MARGIN},
	{"tab_width", &TAB_WIDTH},
	{"wheel_scroll_lines", &WHEEL_SCROLL_LINES},
	{"double_click_ms", &DOUBLE_CLICK_MS},
	{"disk_poll_ms", &DISK_POLL_MS},
	{"cursor_accel_interval_ms", &CURSOR_ACCEL_INTERVAL_MS},
	{"cursor_accel_ramp_presses", &CURSOR_ACCEL_RAMP_PRESSES},
	{"cursor_accel_max_step", &CURSOR_ACCEL_MAX_STEP},
	{"palette_width", &PALETTE_WIDTH},
	{"palette_max_rows", &PALETTE_MAX_ROWS},
	{"picker_margin_x", &PICKER_MARGIN_X},
	{"picker_margin_y", &PICKER_MARGIN_Y},
	{"projsearch_max", &PROJSEARCH_MAX},
	{"projsearch_min_query", &PROJSEARCH_MIN_QUERY},
	{"preview_max_lines", &PREVIEW_MAX_LINES},
	{"preview_parse_ahead", &PREVIEW_PARSE_AHEAD},
	{"preview_diff_context", &PREVIEW_DIFF_CONTEXT},
	{"alt_esc_timeout_ms", &ALT_ESC_TIMEOUT_MS},
	{"lsp_poll_ms", &LSP_POLL_MS},
	{"diag_pane_margin_x", &DIAG_PANE_MARGIN_X},
	{"diag_pane_max_lines", &DIAG_PANE_MAX_LINES},
	{"completion_debounce_ms", &COMPLETION_DEBOUNCE_MS},
	{"completion_max_rows", &COMPLETION_MAX_ROWS},
	{"completion_max_width", &COMPLETION_MAX_WIDTH},
	{"completion_min_chars", &COMPLETION_MIN_CHARS},
	{"jump_threshold", &JUMP_THRESHOLD},
	{"git_diff_max_d", &GIT_DIFF_MAX_D},
	{"git_stat_poll_ms", &GIT_STAT_POLL_MS},
	{"big_file_bytes", &BIG_FILE_BYTES},
}

FORMAT_ON_SAVE: bool
CURSOR_ACCEL: bool
AUTO_CLOSE_PAIRS: bool
GIT_DIFF_VIEW: bool
LINE_WRAP: bool
FILETREE_SHOW_DOTFILES: bool
FILETREE_SHOW_IGNORED: bool
TERMINAL_ESCAPE_CLOSES: bool

config_bools := [?]Config_Bool {
	{"format_on_save", &FORMAT_ON_SAVE},
	{"cursor_accel", &CURSOR_ACCEL},
	{"auto_close_pairs", &AUTO_CLOSE_PAIRS},
	{"git_diff_view", &GIT_DIFF_VIEW},
	{"line_wrap", &LINE_WRAP},
	{"filetree_show_dotfiles", &FILETREE_SHOW_DOTFILES},
	{"filetree_show_ignored", &FILETREE_SHOW_IGNORED},
	{"terminal_escape_closes", &TERMINAL_ESCAPE_CLOSES},
}

Config_Str :: struct {
	key: string,
	ptr: ^string,
}

LLM_CHAT_COMMAND: string
LLM_EDIT_PROMPT: string
LLM_COMPLETION_ENDPOINT: string
LLM_COMPLETION_MODEL: string
LLM_COMPLETION_API_KEY_ENV: string
LLM_COMPLETION_MAX_TOKENS: int
LLM_COMPLETION_DEBOUNCE_MS: int
LLM_COMPLETION_CONTEXT_LINES: int
LLM_COMPLETION_ENABLED: bool

config_llm := [?]Config_Str {
	{"chat_command", &LLM_CHAT_COMMAND},
	{"edit_prompt", &LLM_EDIT_PROMPT},
	{"completion_endpoint", &LLM_COMPLETION_ENDPOINT},
	{"completion_model", &LLM_COMPLETION_MODEL},
	{"completion_api_key_env", &LLM_COMPLETION_API_KEY_ENV},
}

config_llm_ints := [?]Config_Int {
	{"completion_max_tokens", &LLM_COMPLETION_MAX_TOKENS},
	{"completion_debounce_ms", &LLM_COMPLETION_DEBOUNCE_MS},
	{"completion_context_lines", &LLM_COMPLETION_CONTEXT_LINES},
}

config_llm_bools := [?]Config_Bool {
	{"completion_enabled", &LLM_COMPLETION_ENABLED},
}

Config_Float :: struct {
	key: string,
	ptr: ^f32,
}

COLOR_FG: tb2.Color
COLOR_BG: tb2.Color
COLOR_ERROR_FG: tb2.Color
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
COLOR_FILETREE_IGNORED: tb2.Color
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
	{"filetree_ignored", &COLOR_FILETREE_IGNORED},
}

ICON_STATUS_FILE: string
ICON_STATUS_BRANCH: string
ICON_STATUS_AHEAD: string
ICON_STATUS_BEHIND: string
ICON_STATUS_LANG: string
ICON_STATUS_LSP: string
ICON_STATUS_INDENT: string
ICON_MODIFIED: string
ICON_TREE_EXPANDED: string
ICON_TREE_COLLAPSED: string
ICON_PREVIEW_MORE: string
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
	{"status_language", &ICON_STATUS_LANG},
	{"status_lsp", &ICON_STATUS_LSP},
	{"status_indent", &ICON_STATUS_INDENT},
	{"modified", &ICON_MODIFIED},
	{"tree_expanded", &ICON_TREE_EXPANDED},
	{"tree_collapsed", &ICON_TREE_COLLAPSED},
	{"preview_more", &ICON_PREVIEW_MORE},
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

config_tints := [?]Config_Float {
	{"current_line", &CURRENT_LINE_TINT},
	{"ai_edit", &AI_EDIT_TINT},
	{"git_hunk", &GIT_HUNK_TINT},
	{"git_diff_ghost", &GIT_DIFF_GHOST_TINT},
	{"git_diff_word", &GIT_DIFF_WORD_TINT},
	{"conflict", &CONFLICT_TINT},
	{"conflict_marker", &CONFLICT_MARKER_TINT},
	{"conflict_word", &CONFLICT_WORD_TINT},
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

embedded_config_data := #load("../config/config.json")

g_config_defaults: json.Object
g_theme_defaults: json.Object

// Runs before main (and before tests): the valueless globals in config.odin get
// their defaults from the embedded config/ JSON; soundness is enforced by tests.
@(init)
config_seed_defaults :: proc "contextless" () {
	context = runtime.default_context()
	root_val, err := json.parse(embedded_config_data, parse_integers = true, allocator = os.heap_allocator())
	assert(err == nil, "embedded config/config.json failed to parse")
	g_config_defaults = root_val.(json.Object)
	name := string(g_config_defaults["theme"].(json.String))
	for bt in bundled_themes {
		if bt.name != name {
			continue
		}
		theme_val, terr := json.parse(bt.data, parse_integers = true, allocator = os.heap_allocator())
		assert(terr == nil, "embedded default theme failed to parse")
		g_theme_defaults = theme_val.(json.Object)
	}
	assert(g_theme_defaults != nil, "config/config.json theme must name a bundled theme")
	config_defaults_apply()
	theme_reset_defaults()
}

// Frees the string knobs that config_apply/theme_apply clone into globals. Runs
// once at program exit (after main + all tests), mirroring config_seed_defaults.
@(fini)
settings_destroy :: proc "contextless" () {
	context = runtime.default_context()
	delete(THEME, os.heap_allocator())
	for &cmd in commands {
		delete(cmd.shortcut, os.heap_allocator())
	}
	for it in config_llm {
		delete(it.ptr^, os.heap_allocator())
	}
	for it in config_icons {
		delete(it.ptr^, os.heap_allocator())
	}
}

config_defaults_apply :: proc() {
	languages_reset_defaults()
	scratch := make([dynamic]string, context.temp_allocator)
	config_apply(g_config_defaults, &scratch)
}

config_load :: proc() -> (message: string, is_error: bool) {
	path := config_path()
	if path == "" {
		config_defaults_apply()
		return theme_load(path)
	}
	return config_load_from(path)
}

config_load_from :: proc(path: string) -> (message: string, is_error: bool) {
	config_defaults_apply()

	problems := make([dynamic]string, context.temp_allocator)
	is_error = false

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err == nil {
		root_val, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
		if perr != nil {
			message = fmt.tprintf("config.json: parse error in %s, using defaults", path)
			is_error = true
		} else if root, is_obj := root_val.(json.Object); !is_obj {
			message = fmt.tprintf("config.json: %s is not a JSON object, using defaults", path)
			is_error = true
		} else {
			config_apply(root, &problems)
			config_collect_unknown(root, &problems)
			if len(problems) > 0 {
				list := strings.join(problems[:], ", ", context.temp_allocator)
				message = fmt.tprintf("config.json: ignoring %s", list)
				is_error = true
			}
		}
	}

	theme_message, theme_error := theme_load(path)
	message = theme_msg_join(message, theme_message)
	is_error = is_error || theme_error
	return
}

config_apply :: proc(root: json.Object, invalid: ^[dynamic]string) {
	for it in config_ints {
		v, present := root[it.key]
		if !present {
			continue
		}
		#partial switch n in v {
		case json.Integer:
			it.ptr^ = int(n)
		case json.Float:
			it.ptr^ = int(n)
		case:
			append(invalid, it.key)
		}
	}

	for it in config_bools {
		v, present := root[it.key]
		if !present {
			continue
		}
		#partial switch b in v {
		case json.Boolean:
			it.ptr^ = bool(b)
		case:
			append(invalid, it.key)
		}
	}

	if theme_val, present := root["theme"]; present {
		if s, is_str := theme_val.(json.String); is_str {
			delete(THEME, os.heap_allocator())
			THEME = strings.clone(string(s), os.heap_allocator())
		} else {
			append(invalid, "theme")
		}
	}

	if kb_val, present := root["keybinds"]; present {
		if kb_obj, kb_is_obj := kb_val.(json.Object); kb_is_obj {
			for &cmd in commands {
				v, has := kb_obj[cmd.name]
				if !has {
					continue
				}
				s, is_str := v.(json.String)
				if !is_str {
					append(invalid, fmt.tprintf("keybinds/%s", cmd.name))
					continue
				}
				if s == "" {
					cmd.key = tb2.Key(0)
					cmd.alt_ch = 0
					delete(cmd.shortcut, os.heap_allocator())
					cmd.shortcut = ""
					continue
				}
				key, alt_ch, pok := parse_keybind(string(s))
				if !pok {
					append(invalid, fmt.tprintf("keybinds/%s", cmd.name))
					continue
				}
				cmd.key = key
				cmd.alt_ch = alt_ch
				delete(cmd.shortcut, os.heap_allocator())
				cmd.shortcut = strings.clone(string(s), os.heap_allocator())
			}
		} else {
			append(invalid, "keybinds")
		}
	}

	if lang_val, present := root["languages"]; present {
		if lang_obj, is_obj := lang_val.(json.Object); is_obj {
			languages_from_config(lang_obj, invalid)
		} else {
			append(invalid, "languages")
		}
	}

	if llm_val, present := root["llm"]; present {
		if llm_obj, is_obj := llm_val.(json.Object); is_obj {
			for it in config_llm {
				v, has := llm_obj[it.key]
				if !has {
					continue
				}
				s, is_str := v.(json.String)
				if !is_str {
					append(invalid, fmt.tprintf("llm/%s", it.key))
					continue
				}
				delete(it.ptr^, os.heap_allocator())
				it.ptr^ = strings.clone(string(s), os.heap_allocator())
			}
			for it in config_llm_ints {
				v, has := llm_obj[it.key]
				if !has {
					continue
				}
				#partial switch n in v {
				case json.Integer:
					it.ptr^ = int(n)
				case json.Float:
					it.ptr^ = int(n)
				case:
					append(invalid, fmt.tprintf("llm/%s", it.key))
				}
			}
			for it in config_llm_bools {
				v, has := llm_obj[it.key]
				if !has {
					continue
				}
				if b, is_bool := v.(json.Boolean); is_bool {
					it.ptr^ = bool(b)
				} else {
					append(invalid, fmt.tprintf("llm/%s", it.key))
				}
			}
		} else {
			append(invalid, "llm")
		}
	}
}

config_collect_unknown :: proc(root: json.Object, warnings: ^[dynamic]string) {
	for key in root {
		switch key {
		case "theme", "keybinds", "languages", "llm":
			continue
		}
		known := false
		for it in config_ints {
			if it.key == key {
				known = true
				break
			}
		}
		if !known {
			for it in config_bools {
				if it.key == key {
					known = true
					break
				}
			}
		}
		if !known {
			append(warnings, fmt.tprintf("unknown key %q", key))
		}
	}

	if kb_obj, ok := root["keybinds"].(json.Object); ok {
		for key in kb_obj {
			found := false
			for cmd in commands {
				if cmd.name == key {
					found = true
					break
				}
			}
			if !found {
				append(warnings, fmt.tprintf("unknown keybinds/%q", key))
			}
		}
	}

	if llm_obj, ok := root["llm"].(json.Object); ok {
		for key in llm_obj {
			found := false
			for it in config_llm {
				if it.key == key {found = true; break}
			}
			if !found {
				for it in config_llm_ints {
					if it.key == key {found = true; break}
				}
			}
			if !found {
				for it in config_llm_bools {
					if it.key == key {found = true; break}
				}
			}
			if !found {
				append(warnings, fmt.tprintf("unknown llm/%q", key))
			}
		}
	}
}

THEME: string

Bundled_Theme :: struct {
	name: string,
	data: []u8,
}

bundled_themes := [?]Bundled_Theme {
	{"gruber-darker", #load("../config/themes/gruber-darker.json")},
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

theme_persist :: proc(name: string) -> bool {
	delete(THEME, os.heap_allocator())
	THEME = strings.clone(name, os.heap_allocator())
	return config_persist_key("theme", json.String(name))
}

theme_reset_defaults :: proc() {
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

// Resolves a theme name onto the globals: gruber-darker defaults as the crash-safe
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
		list := strings.join(warnings[:], ", ", context.temp_allocator)
		return fmt.tprintf("theme %q: ignoring %s", THEME, list), true
	}
	return "", false
}

theme_apply :: proc(root: json.Object, invalid: ^[dynamic]string) {
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
		} else {
			append(invalid, "colors")
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
		case "colors", "icons", "tints":
			continue
		}
		append(warnings, fmt.tprintf("unknown key %q", key))
	}
	theme_section_unknown(root, "colors", config_colors[:], warnings)
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

theme_section_unknown :: proc(
	root: json.Object,
	section: string,
	keys: []Config_Color,
	warnings: ^[dynamic]string,
) {
	obj, ok := root[section].(json.Object)
	if !ok {
		return
	}
	for key in obj {
		found := false
		for c in keys {
			if c.key == key {
				found = true
				break
			}
		}
		if !found {
			append(warnings, fmt.tprintf("unknown %s/%q", section, key))
		}
	}
}

languages_from_config :: proc(obj: json.Object, invalid: ^[dynamic]string) {
	rules := make([dynamic]LangRule, context.temp_allocator)
	for lang in default_pattern_languages() {
		name := LANGUAGES[lang].name
		sub_val, has := obj[name]
		if !has {
			append_default_patterns(&rules, lang)
			continue
		}
		sub, is_obj := sub_val.(json.Object)
		if !is_obj {
			append(invalid, fmt.tprintf("languages/%s", name))
			append_default_patterns(&rules, lang)
			continue
		}
		if pv, phas := sub["patterns"]; phas {
			if !languages_patterns_apply(pv, lang, &rules) {
				append(invalid, fmt.tprintf("languages/%s/patterns", name))
				append_default_patterns(&rules, lang)
			}
		} else {
			append_default_patterns(&rules, lang)
		}
		if lv, lhas := sub["lsp"]; lhas {
			if s, is := lv.(json.String); is {
				LANGUAGES[lang].lsp_server = strings.clone(string(s), os.heap_allocator())
			} else {
				append(invalid, fmt.tprintf("languages/%s/lsp", name))
			}
		}
		if fv, fhas := sub["formatter"]; fhas {
			if s, is := fv.(json.String); is {
				LANGUAGES[lang].formatter = strings.clone(string(s), os.heap_allocator())
			} else {
				append(invalid, fmt.tprintf("languages/%s/formatter", name))
			}
		}
	}
	for key in obj {
		if _, ok := language_from_name(key); !ok {
			append(invalid, fmt.tprintf("languages/%s", key))
		}
	}
	language_rules_set(rules[:])
}

languages_patterns_apply :: proc(v: json.Value, lang: Language, rules: ^[dynamic]LangRule) -> bool {
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return false
	}
	for e in arr {
		if _, is := e.(json.String); !is {
			return false
		}
	}
	for e in arr {
		s := e.(json.String)
		append(rules, LangRule{strings.clone(string(s), os.heap_allocator()), lang})
	}
	return true
}

// Sparse single-key persist: the only write qed makes to the user config. Reads
// the existing user file, sets exactly `key`, writes it back — every other user
// key is preserved, no defaults are ever emitted.
config_persist_key :: proc(key: string, value: json.Value) -> bool {
	path := config_path()
	if path == "" {
		return false
	}
	return config_persist_key_to(path, key, value)
}

config_persist_key_to :: proc(path: string, key: string, value: json.Value) -> bool {
	root: json.Object
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
		if v, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator);
		   perr == nil {
			if o, ok := v.(json.Object); ok {
				root = o
			}
		}
	}
	if root == nil {
		root = make(json.Object, context.temp_allocator)
	}
	root[key] = value

	if dir := config_dir(path); dir != "" {
		os.make_directory_all(dir)
	}
	sb := strings.builder_make(context.temp_allocator)
	json_write_value(&sb, root, 0)
	strings.write_byte(&sb, '\n')
	return os.write_entire_file(path, transmute([]byte)strings.to_string(sb)) == nil
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
