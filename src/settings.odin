package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

Config_Int :: struct {
	key: string,
	ptr: ^int,
}

Config_Color :: struct {
	key: string,
	ptr: ^tb2.Color,
}

config_ints := [?]Config_Int {
	{"scroll_margin", &SCROLL_MARGIN},
	{"tab_width", &TAB_WIDTH},
	{"wheel_scroll_lines", &WHEEL_SCROLL_LINES},
	{"double_click_ms", &DOUBLE_CLICK_MS},
	{"palette_width", &PALETTE_WIDTH},
	{"palette_max_rows", &PALETTE_MAX_ROWS},
	{"picker_margin_x", &PICKER_MARGIN_X},
	{"picker_margin_y", &PICKER_MARGIN_Y},
	{"projsearch_max", &PROJSEARCH_MAX},
	{"projsearch_min_query", &PROJSEARCH_MIN_QUERY},
	{"alt_esc_timeout_ms", &ALT_ESC_TIMEOUT_MS},
	{"lsp_poll_ms", &LSP_POLL_MS},
	{"diag_pane_margin_x", &DIAG_PANE_MARGIN_X},
	{"diag_pane_max_lines", &DIAG_PANE_MAX_LINES},
	{"jump_threshold", &JUMP_THRESHOLD},
	{"git_diff_max_d", &GIT_DIFF_MAX_D},
	{"big_file_bytes", &BIG_FILE_BYTES},
}

config_colors := [?]Config_Color {
	{"foreground", &COLOR_FG},
	{"background", &COLOR_BG},
	{"status_foreground", &COLOR_STATUS_FG},
	{"status_background", &COLOR_STATUS_BG},
	{"error_foreground", &COLOR_ERROR_FG},
	{"diagnostic_error_foreground", &COLOR_DIAG_ERROR_FG},
	{"diagnostic_warning_foreground", &COLOR_DIAG_WARN_FG},
	{"gutter_foreground", &COLOR_GUTTER_FG},
	{"gutter_background", &COLOR_GUTTER_BG},
	{"current_line_foreground", &COLOR_CURRENT_LINE_FG},
	{"current_line_background", &COLOR_CURRENT_LINE_BG},
	{"pane_foreground", &COLOR_PANE_FG},
	{"pane_background", &COLOR_PANE_BG},
	{"pane_border", &COLOR_PANE_BORDER},
	{"pane_prompt_foreground", &COLOR_PANE_PROMPT_FG},
	{"pane_shortcut_foreground", &COLOR_PANE_SHORTCUT_FG},
	{"pane_selection_foreground", &COLOR_PANE_SEL_FG},
	{"pane_selection_background", &COLOR_PANE_SEL_BG},
	{"syntax_keyword", &COLOR_SYN_KEYWORD},
	{"syntax_type", &COLOR_SYN_TYPE},
	{"syntax_string", &COLOR_SYN_STRING},
	{"syntax_comment", &COLOR_SYN_COMMENT},
	{"syntax_constant", &COLOR_SYN_CONSTANT},
	{"syntax_attribute", &COLOR_SYN_ATTRIBUTE},
	{"git_added", &COLOR_GIT_ADD},
	{"git_modified", &COLOR_GIT_MOD},
	{"git_deleted", &COLOR_GIT_DEL},
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

color_to_hex :: proc(c: tb2.Color) -> string {
	return fmt.tprintf("#%06x", u64(c))
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

config_load :: proc() -> (message: string, is_error: bool) {
	path := config_path()
	if path == "" {
		return "", false
	}
	return config_load_from(path)
}

config_load_from :: proc(path: string) -> (message: string, is_error: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		if err := config_write(path, {}); err != nil {
			return fmt.tprintf("config.json: could not create %s (%v)", path, err), true
		}
		return fmt.tprintf("Created config: %s", path), false
	}

	root_val, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil {
		return "config.json: parse error, using defaults", true
	}
	root, is_obj := root_val.(json.Object)
	if !is_obj {
		return "config.json: expected a JSON object, using defaults", true
	}

	invalid := make([dynamic]string, context.temp_allocator)
	missing := false

	for it in config_ints {
		v, present := root[it.key]
		if !present {
			missing = true
			continue
		}
		#partial switch n in v {
		case json.Integer:
			it.ptr^ = int(n)
		case json.Float:
			it.ptr^ = int(n)
		case:
			append(&invalid, it.key)
		}
	}

	if theme_val, present := root["theme"]; !present {
		missing = true
	} else if theme_obj, is_obj := theme_val.(json.Object); is_obj {
		for c in config_colors {
			v, has := theme_obj[c.key]
			if !has {
				missing = true
				continue
			}
			s, is_str := v.(json.String)
			if !is_str {
				append(&invalid, fmt.tprintf("theme/%s", c.key))
				continue
			}
			col, cok := parse_hex_color(string(s))
			if !cok {
				append(&invalid, fmt.tprintf("theme/%s", c.key))
				continue
			}
			c.ptr^ = col
		}
	} else {
		append(&invalid, "theme")
	}

	if kb_val, present := root["keybinds"]; !present {
		missing = true
	} else if kb_obj, kb_is_obj := kb_val.(json.Object); kb_is_obj {
		for &cmd in commands {
			v, has := kb_obj[cmd.name]
			if !has {
				missing = true
				continue
			}
			s, is_str := v.(json.String)
			if !is_str {
				append(&invalid, fmt.tprintf("keybinds/%s", cmd.name))
				continue
			}
			if s == "" {
				cmd.key = tb2.Key(0)
				cmd.alt_ch = 0
				cmd.shortcut = ""
				continue
			}
			key, alt_ch, pok := parse_keybind(string(s))
			if !pok {
				append(&invalid, fmt.tprintf("keybinds/%s", cmd.name))
				continue
			}
			cmd.key = key
			cmd.alt_ch = alt_ch
			cmd.shortcut = strings.clone(string(s))
		}
	} else {
		append(&invalid, "keybinds")
	}

	if missing {
		if err := config_write(path, root); err != nil {
			return fmt.tprintf("config.json: could not update %s (%v)", path, err), true
		}
	}

	if len(invalid) > 0 {
		list := strings.join(invalid[:], ", ", context.temp_allocator)
		return fmt.tprintf("config.json: invalid %s (using defaults)", list), true
	}
	if missing {
		return "config.json: wrote missing defaults", false
	}
	return "", false
}

config_write :: proc(path: string, root: json.Object) -> os.Error {
	if dir := config_dir(path); dir != "" {
		os.make_directory_all(dir)
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{\n")
	first := true

	emit_key :: proc(sb: ^strings.Builder, first: ^bool, key: string) {
		if !first^ {
			strings.write_string(sb, ",\n")
		}
		first^ = false
		fmt.sbprintf(sb, "  %s: ", lsp_json_string(key))
	}

	for it in config_ints {
		emit_key(&sb, &first, it.key)
		if v, present := root[it.key]; present {
			config_value_text(&sb, v)
		} else {
			fmt.sbprintf(&sb, "%d", it.ptr^)
		}
	}

	emit_key(&sb, &first, "theme")
	theme_raw, theme_present := root["theme"]
	if theme_obj, is_obj := theme_raw.(json.Object); theme_present && !is_obj {
		config_value_text(&sb, theme_raw)
	} else {
		strings.write_string(&sb, "{\n")
		th_first := true
		for c in config_colors {
			if !th_first {
				strings.write_string(&sb, ",\n")
			}
			th_first = false
			fmt.sbprintf(&sb, "    %s: ", lsp_json_string(c.key))
			if v, has := theme_obj[c.key]; has {
				config_value_text(&sb, v)
			} else {
				strings.write_string(&sb, lsp_json_string(color_to_hex(c.ptr^)))
			}
		}
		strings.write_string(&sb, "\n  }")
	}

	emit_key(&sb, &first, "keybinds")
	kb_raw, kb_present := root["keybinds"]
	if kb_obj, is_obj := kb_raw.(json.Object); kb_present && !is_obj {
		config_value_text(&sb, kb_raw)
	} else {
		strings.write_string(&sb, "{\n")
		kb_first := true
		for cmd in commands {
			if !kb_first {
				strings.write_string(&sb, ",\n")
			}
			kb_first = false
			fmt.sbprintf(&sb, "    %s: ", lsp_json_string(cmd.name))
			if v, has := kb_obj[cmd.name]; has {
				config_value_text(&sb, v)
			} else {
				strings.write_string(&sb, lsp_json_string(cmd.shortcut))
			}
		}
		strings.write_string(&sb, "\n  }")
	}

	strings.write_string(&sb, "\n}\n")
	return os.write_entire_file(path, transmute([]byte)strings.to_string(sb))
}

config_dir :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return ""
}

config_value_text :: proc(sb: ^strings.Builder, v: json.Value) {
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
				strings.write_byte(sb, ',')
			}
			config_value_text(sb, e)
		}
		strings.write_byte(sb, ']')
	case json.Object:
		strings.write_byte(sb, '{')
		first := true
		for k, val in t {
			if !first {
				strings.write_byte(sb, ',')
			}
			first = false
			strings.write_string(sb, lsp_json_string(k))
			strings.write_byte(sb, ':')
			config_value_text(sb, val)
		}
		strings.write_byte(sb, '}')
	}
}
