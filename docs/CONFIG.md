# Configuration reference

Every qed tunable, in one place. Defaults are compiled into the binary from two
files, which are the canonical, always-current reference:

- [`config/config.json`](../config/config.json): knobs, keybinds,
  per-language LSP wiring, and bundled plugin config (formatters, user commands).
- [`config/themes/default.json`](../config/themes/default.json): the complete
  color, icon, and tint palette every theme overlays.

## How config works

You never copy either file. `~/.config/qed/config.json` is a sparse per-key
diff: put in only the keys you want to change; everything else keeps its
compiled-in default. qed never writes this file (except *Set Theme*, which
persists the single `theme` key when you press Enter on it, via `qed.theme.set`).

- **Hot-reloaded.** Save the file and the change applies live: colors, keybinds,
  and knobs take effect without a restart.
- **Forgiving.** An unknown key warns once and is ignored; malformed JSON falls
  back to defaults without crashing.
- **Nested keys merge per-key**, so overriding one language's `lsp` leaves
  its `patterns` intact.

A minimal override looks like:

```json
{
  "line_wrap": false,
  "plugins": { "format": { "format_on_save": true } },
  "theme": "gruvbox-dark",
  "keybinds": { "Find in Files": "Ctrl+e" }
}
```

## Editing behavior

| Key | Default | Meaning |
|-----|---------|---------|
| `tab_width` | `4` | Indent width in spaces; also the display width of a literal tab. |
| `auto_close_pairs` | `true` | Auto-insert the closing `)`/`]`/`}`/quote/backtick; type-over and paired backspace. |
| `line_wrap` | `true` | Soft-wrap long lines at word boundaries (per-buffer; *Toggle Line Wrap* flips the current one). Off means horizontal scroll. |
| `cursor_accel` | `true` | Held arrow keys accelerate the longer they repeat. |
| `cursor_accel_interval_ms` | `55` | A pause longer than this (ms) resets the acceleration ramp. |
| `cursor_accel_ramp_presses` | `20` | Repeats over which the step ramps to its max. |
| `cursor_accel_max_step` | `6` | Largest per-repeat step at full acceleration (rows/cols). |

## Save behavior and formatting

Owned by the bundled `format` plugin, under `plugins.format`. The three knobs
default off and seed runtime *Toggle* commands (*Toggle Format on Save*, *Toggle
Trim Whitespace on Save*, *Toggle Final Newline on Save*). *Format Document*
formats on demand.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.format.format_on_save` | `false` | Format on every save (after the fixups below). |
| `plugins.format.trim_trailing_whitespace_on_save` | `false` | Strip trailing whitespace (markdown two-space hard breaks are kept). |
| `plugins.format.ensure_final_newline_on_save` | `false` | Guarantee exactly one trailing newline. |
| `plugins.format.commands.<language>` | see `config.json` | External stdin-to-stdout formatter for that language, e.g. `"python": "ruff format --stdin-filename {file} -"`. Absent or `""` falls back to LSP formatting. |

A formatter command runs under `sh -c` in the file's directory; `{file}` is replaced
with the file's quoted absolute path, for tools that take a stdin-filename flag. A
missing tool or non-zero exit leaves the buffer untouched with a message (a save
still goes ahead, unformatted). A save waits for formatting up to
`plugin_hook_timeout_ms`.

```json
{ "plugins": { "format": { "format_on_save": true, "commands": { "lua": "stylua -" } } } }
```

## Scrolling & mouse

| Key | Default | Meaning |
|-----|---------|---------|
| `scroll_margin` | `3` | Rows kept between the cursor and the viewport edge when scrolling. |
| `wheel_scroll_lines` | `3` | Lines per mouse-wheel notch. |
| `double_click_ms` | `400` | Max gap (ms) for a double/triple click. |

## Panes & layout

| Key | Default | Meaning |
|-----|---------|---------|
| `palette_max_rows` | `8` | Max visible palette rows. |
| `preview_diff_context` | `3` | Context lines around each hunk in the file-tree Git diff preview. |

## Search & navigation

| Key | Default | Meaning |
|-----|---------|---------|
| `projsearch_min_query` | `2` | Min query length before project search runs. |
| `jump_threshold` | `10` | A cursor move farther than this many lines records a jump-list entry. |

## Timing & limits

| Key | Default | Meaning |
|-----|---------|---------|
| `alt_esc_timeout_ms` | `25` | Window after a bare Esc in which a printable key is re-tagged as `Alt+…`. |
| `big_file_bytes` | `2097152` | Files at or above this size (2 MB) open as plain text (no highlight, git gutter, or LSP). |

## Feature toggles

| Key | Default | Meaning |
|-----|---------|---------|
| `filetree_show_dotfiles` | `false` | Show dotfiles in the file tree. *Alt+.* |
| `filetree_show_ignored` | `false` | Show gitignored files in the file tree. *Alt+i* |
| `terminal_escape_closes` | `true` | At a shell prompt, Esc closes the terminal pane (forwarded on the alt-screen regardless). |

## Keybinds

`keybinds` maps a command name to a key string. Only these commands are
rebindable; primitive editing/movement is fixed. An empty string (`""`) leaves a
command unbound but still reachable from the palette. Key strings are
case-sensitive combinations of `Ctrl+`, `Alt+`, and a key (`Ctrl+f`, `Alt+F`,
`Alt+{`). The `keybinds` block in
[`config/config.json`](../config/config.json) has the full list of command names
and their defaults; every command is also listed with its current binding in the
command palette (`Ctrl+p`).

## Languages

The `languages` section keys each language by name. Every entry has two
user-overridable fields:

- **`patterns`**: glob list matched against the filename basename
  (most-specific first), e.g. `["*.py", "*.pyw"]` or dotfiles like `.bashrc`.
- **`lsp`**: the language-server command (`""` is none), e.g. `pyright-langserver --stdio`.

Formatter commands live in [`plugins.format.commands`](#save-behavior-and-formatting).
Overriding one field merges over the compiled-in default, so you can point `lsp`
at a different binary. Syntax highlighting is wired into
the binary (tree-sitter) and is not configured here. *Set Language* overrides the
detected language for the current session.

## Modules

`git`, `lsp`, and `ai` are self-contained subsystems under the `modules` section.
Each has an `enabled` flag (default `true`); setting it `false` removes that
module entirely — its commands leave the palette and their keybinds go dead, its
UI (gutter marks, diagnostics, ghost text…) stops rendering, and it never spawns
a subprocess. Git also auto-disables when the `git` binary isn't on `PATH`. All of
a module's own config lives inside its namespace, so everything about it is in one
place.

```json
{ "modules": { "ai": { "enabled": false } } }
```

### `modules.git`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Master switch. Off removes the diff gutter, the branch in the status bar, the file-tree **Git** tab, diff view, hunk nav/revert, and merge-conflict highlighting/resolve. |
| `diff_view` | `false` | Inline diff view (ghost rows for removed/replaced lines). *Git: Toggle Diff View* (`Alt+g`). |
| `filetree_diff_only` | `true` | File-tree Git preview shows only changed hunks, not the whole file. *File Tree: Toggle Diff* (`Alt+d`). |

### `modules.lsp`

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Master switch. Off stops every language server — no diagnostics, completion, hover, go-to-definition, or rename; *Format Document* works only for languages with a `plugins.format.commands` entry. |
| `completion_max_rows` | `8` | Max rows in the completion popup. |
| `completion_min_chars` | `1` | Word-char count that auto-triggers completion. |

Per-language server commands live in the [`languages`](#languages) section, not
here — a server is a property of its language.

### `modules.ai`

Configures both AI features (selection edit + inline FIM completion). See
[notes/ai.md](notes/ai.md) for the architecture.

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Master switch. Off removes *AI: Edit Selection* (`Ctrl+K`) and inline completion, and cancels anything in flight. |
| `chat_command` | `claude -p` | Shell command for the AI edit; buffer and prompt go in on stdin. |
| `edit_prompt` | *(template)* | The instruction template; `{path}`, `{instruction}`, `{file}` are substituted. |
| `completion_enabled` | `false` | Enable inline FIM ghost-text completion (an independent sub-toggle; needs the module on). *AI: Toggle Inline Completion*. |
| `completion_endpoint` | Codestral FIM URL | FIM HTTP endpoint. |
| `completion_model` | `codestral-latest` | FIM model name. |
| `completion_api_key_env` | `CODESTRAL_API_KEY` | Env var the `curl` child reads the API key from (qed never holds it). |
| `completion_max_tokens` | `256` | Max tokens per FIM suggestion. |
| `completion_debounce_ms` | `350` | Idle delay before firing a FIM request. |
| `completion_context_lines` | `200` | Lines of prefix/suffix context sent with each FIM request. |

## Plugins

Lua plugins: bundled ones ship in the binary, your own go in
`~/.config/qed/plugins/` as `name.lua` or `name/init.lua`. See
[notes/plugins.md](notes/plugins.md). *Debug: Plugins* lists them with their state
and last error.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugin_memory_mb` | `64` | Memory cap for the Lua state; a plugin that exceeds it errors instead of growing. `0` means no cap. |
| `plugin_hook_timeout_ms` | `2000` | How long a save waits for `buf_pre_save` handlers, and quit for `quit` handlers. On timeout the save (or quit) goes ahead and the slow plugin is named in a warning. |
| `plugins.<name>.enabled` | `true` | Off skips loading that plugin. |
| `plugins.<name>.<key>` | plugin's `defaults` | Per-key override of the plugin's own config; objects merge per key, arrays replace. |

A plugin command's keybind is its `key`, overridden by `keybinds["<command name>"]`
like any builtin (`""` unbinds). A key already taken by a builtin is ignored with a
warning. Keybinds and `plugin_memory_mb` hot-reload. Changes under `plugins.<name>`
reach the plugin through its `config_changed` handler (`format` and `commands` apply
them live); `enabled` and new or edited plugin files need a restart for now.
*Set Theme*, *Set Language* and *Change Indentation* come from the bundled `pickers`
plugin (no config of its own; `plugins.pickers.enabled = false` removes them).

```json
{ "plugins": { "mytool": { "enabled": false } } }
```

## User commands

Shell commands you define become palette commands, owned by the bundled
`commands` plugin. `plugins.commands.list` is a list (a user list replaces the
default empty one) and hot-reloads: commands are re-registered on save.

| Entry key | Default | Meaning |
|-----------|---------|---------|
| `name` | required | Palette name. A builtin's name is refused with a warning (builtins win), as is a duplicate. |
| `run` | required | Shell string run with `sh -c`. Placeholders below are substituted, each shell-quoted. |
| `output` | `"message"` | Where the result goes, see below. |
| `stdin` | `"none"` | `"none"`, `"selection"`, `"buffer"`, or `"selection-or-buffer"`. |
| `save` | `"current"` | Save before running: `"none"`, `"current"` (the current buffer if modified; editor commands only), or `"all"`. A failed save aborts the run. |
| `cwd` | working root | Directory to run in; placeholders allowed (unquoted), relative to the root. |
| `env` | `{}` | Extra environment, `{"NAME": "value"}`; placeholders allowed (unquoted). |
| `key` | none | Default keybind; `keybinds["<name>"]` overrides it. |
| `when` | `{}` | Conditions, all of which must hold; otherwise the command is hidden and its key does nothing. |

Placeholders: `{file}` (absolute path; in the file tree the entry under the
cursor), `{files}` (file tree: every selected path; editor: `{file}`), `{dir}`
(the file's directory, or the entry itself when it is a directory), `{root}`,
`{name}`, `{stem}`, `{ext}` (no dot), `{line}`, `{col}` (1-based; `col` is a
byte column), `{selection}`, `{word}` (word under the cursor), `{base}` (the
diff base ref, `HEAD` by default; a merge base resolves to its commit). The same
values are exported as `QED_FILE`, `QED_FILES` (newline-separated), `QED_DIR`,
`QED_ROOT`, `QED_NAME`, `QED_STEM`, `QED_EXT`, `QED_LINE`, `QED_COL`,
`QED_SELECTION`, `QED_WORD`, `QED_BASE`. Unknown `{words}` are left as is.

| `output` | Result |
|----------|--------|
| `message` | First stdout line on the message line (`done` if none). On failure: exit code and the first stderr line. |
| `log` | All output in a read-only pane (stderr in the error color), exit code in the footer. |
| `replace` | Replaces the selection, or the whole buffer without one, as one undo step. Skipped if the buffer changed while it ran; untouched on failure. A trailing newline the input lacked is dropped. |
| `insert` | Inserts stdout at the cursor (one trailing newline dropped). |
| `clipboard` | Copies stdout (one trailing newline dropped). |
| `terminal` | Types the command into the terminal pane and shows it (`stdin`/`env` do not apply; with `cwd` it runs as `(cd dir && cmd)`). |
| `locations` | Parses `file:line:col: msg` and `file:line: msg` lines (stdout and stderr) into a picker with a file preview; Enter jumps. Lines naming missing files are skipped. No locations is a success even on a non-zero exit (grep), unless stderr has output. |

| `when` key | Holds when |
|------------|------------|
| `pane` | `"editor"` (default), `"filetree"`, or a list of both. `replace`, `insert` and `stdin` need the editor. |
| `language` | The current buffer's language is one of the list (editor only). |
| `glob` | The file (in the file tree: every selected path) matches one of the globs. A glob without `/` matches the base name; with `/` it matches the root-relative path. `*` and `?` stay inside a path segment, `**` spans segments. |
| `selection` | `true`: there is a selection. `false`: there is none. |
| `git` | `true`: the root is inside a git work tree (a `.git` up the tree). `false`: it is not. |
| `exists` | Every listed path exists, relative to the root. |

Commands run in the background; *Commands: Cancel* kills the running ones, and a
running command refuses a second start. Strings and lists are interchangeable
for `pane`, `language`, `glob` and `exists`.

```json
{ "plugins": { "commands": { "list": [
  { "name": "Sort Lines", "run": "sort", "stdin": "selection-or-buffer", "output": "replace", "save": "none" },
  { "name": "Grep Word", "run": "grep -rn -- {word} .", "output": "locations", "key": "Alt+8" },
  { "name": "Test Package", "run": "go test .", "cwd": "{dir}", "output": "log", "when": { "language": "go" } },
  { "name": "npm test", "run": "npm test", "output": "terminal", "when": { "exists": "package.json" } },
  { "name": "Git Add", "run": "git add -- {files}", "when": { "pane": "filetree", "git": true } },
  { "name": "Copy Path:Line", "run": "printf '%s:%s' {file} {line}", "output": "clipboard" }
] } } }
```

## Themes & colors

Colors are not in `config.json`; they live in themes. Set the active theme with
the `theme` key (or the *Set Theme* picker, which persists it):

```json
{ "theme": "nord" }
```

Bundled themes: `default`, `atom-one-dark`, `catppuccin-mocha`,
`catppuccin-latte`, `solarized-light`, `dracula`, `gruvbox-dark`, `nord`,
`tokyo-night` (`catppuccin-latte` and `solarized-light` are light).

To customize colors, create `~/.config/qed/themes/<name>.json`, a sparse per-key
diff over the bundled theme of the same name (or over `default` for a new name).
The four sections are `colors`, `captures` (tree-sitter capture to color),
`icons`, and `tints` (line-background strengths). The complete key list is
[`config/themes/default.json`](../config/themes/default.json); qed never writes
theme files.
