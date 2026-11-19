# Configuration reference

Every qed tunable, in one place. Defaults are compiled into the binary from two
files, which are the canonical, always-current reference:

- [`config/config.json`](../config/config.json): knobs, keybinds,
  per-language LSP wiring, and which bundled plugins are enabled.
- Each plugin's `qed.options{...}` call in its `setup` (bundled ones in
  [`plugins/`](../plugins/)): that plugin's keys and defaults.
- [`config/themes/default.json`](../config/themes/default.json): the complete
  color, icon, and tint palette every theme overlays.

## How config works

You never copy either file. `~/.config/qed/config.json` is a sparse per-key
diff: put in only the keys you want to change; everything else keeps its
compiled-in default. qed never writes this file (except *Settings: Theme*, which
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
  "keybinds": { "Find": "Ctrl+e" }
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
default off and seed runtime toggles (*Format: Toggle on Save*, *Format: Toggle
Trim Whitespace on Save*, *Format: Toggle Final Newline on Save*). *Format: Document*
formats on demand.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.format.format_on_save` | `false` | Format on every save (after the fixups below). |
| `plugins.format.trim_trailing_whitespace_on_save` | `false` | Strip trailing whitespace (markdown two-space hard breaks are kept). |
| `plugins.format.ensure_final_newline_on_save` | `false` | Guarantee exactly one trailing newline. |
| `plugins.format.commands.<language>` | see `plugins/format/init.lua` | External stdin-to-stdout formatter for that language, e.g. `"python": "ruff format --stdin-filename {file} -"`. Absent or `""` falls back to LSP formatting. |

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
| `preview_diff_context` | `3` | Context lines around each hunk in the file-tree Changed tab's diff preview. |

## Search & navigation

| Key | Default | Meaning |
|-----|---------|---------|
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
| `diff_view` | `false` | Inline diff view (ghost rows for removed/replaced lines against the diff base). *Diff: Toggle Diff View*. |
| `filetree_diff_only` | `true` | The file-tree Changed tab's preview shows only changed hunks, not the whole file. *File Tree: Toggle Diff* (`Alt+d`). |

## Keybinds

`keybinds` maps a core command name to a key string. Only these commands are
rebindable; primitive editing/movement is fixed. Plugin commands bind under
[`plugins.<id>.keybinds`](#plugins). An empty string (`""`) leaves a
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
the binary (tree-sitter) and is not configured here. *Settings: Language* overrides the
detected language for the current session.

## LSP

| Key | Default | Meaning |
|-----|---------|---------|
| `lsp.enabled` | `true` | Master switch. Off stops every language server: no diagnostics, completion, hover, go-to-definition or rename, and the `LSP:` commands leave the palette. *Format: Document* works only for languages with a `plugins.format.commands` entry. |
| `lsp.completion_max_rows` | `8` | Max rows in the completion popup. |
| `lsp.completion_min_chars` | `1` | Word-char count that auto-triggers completion. |

Per-language server commands live in the [`languages`](#languages) section. The
old `modules.lsp` keys warn and are ignored.

## Modules

`ai` is a self-contained subsystem under the `modules` section. Its `enabled`
flag (default `true`) set to `false` removes it entirely: its commands leave the
palette and their keybinds go dead, its UI stops rendering, and it never spawns
a subprocess.

```json
{ "modules": { "ai": { "enabled": false } } }
```

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
and last error: `e` enables/disables, `r` reloads, `l` shows the plugin's log,
`Enter` opens its source (bundled ones read-only).

| Key | Default | Meaning |
|-----|---------|---------|
| `plugin_memory_mb` | `64` | Memory cap for the Lua state; a plugin that exceeds it errors instead of growing. `0` means no cap. |
| `plugin_hook_timeout_ms` | `2000` | How long a save waits for `buf_pre_save` handlers, and quit for `quit` handlers. On timeout the save (or quit) goes ahead and the slow plugin is named in a warning. |
| `plugins.<id>.enabled` | `true` | Off unloads that plugin (live) and drops its commands and binds. `e` in *Debug: Plugins* writes this key. |
| `plugins.<id>.keybinds` | each command's `key` | Binds for that plugin's commands, keyed by the bare command name (`"Set Diff Base"`, not `"Git: Set Diff Base"`). `""` unbinds. A name no command of the loaded plugin has warns; a disabled plugin's binds are not checked. |
| `plugins.<id>.<key>` | plugin's `qed.options` | Per-key override of the plugin's own config; objects merge per key, arrays replace. Unknown keys warn once the plugin has loaded; a disabled plugin's keys are not checked. |

The id is the plugin's file or dir name. Its display name (the id title-cased, or
what the plugin sets with `qed.meta`) prefixes its commands in the palette
(`Git: Set Diff Base`) and labels its messages. A key already taken by a builtin is
ignored with a warning. Keybinds and `plugin_memory_mb` hot-reload. Changes under
`plugins.<id>` reach the plugin through its `config_changed` handler (`format`,
`search` apply them live, keeping runtime state); a plugin without one
is reloaded. Adding, removing or editing a file under `plugins/` reloads just that
plugin. *Settings: Theme*, *Settings: Language* and *Settings: Indentation*
come from the bundled `settings` plugin (no config of its own;
`plugins.settings.enabled = false` removes them).

```json
{ "plugins": {
  "mytool": { "enabled": false },
  "git": { "keybinds": { "Set Diff Base": "Alt+b" } }
} }
```

### Search

*Search: Find in Files* (`Alt+F`) and the file tree's *Search: Find in Files* (same
chord, scoped to the selection) come from the bundled `search` plugin; both need `rg`
on `PATH`. Rebind both with `plugins.search.keybinds["Find in Files"]`.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.search.enabled` | `true` | Off removes both *Find in Files* commands. |
| `plugins.search.min_query` | `2` | Min query length before a search runs (was `projsearch_min_query`). |

### Git

The bundled `git` plugin fetches each buffer's diff base (the gutter, diff view,
*Diff: Next/Previous Change*, *Diff: Revert Hunk*), polls the branch, ahead/behind
and repo diff size into the status bar every 2 s, feeds the file tree's **Changed** tab
(*File Tree: Changed*, `Alt+g`), and owns *Git: Set Diff Base* and the tree's
*Git: Restore File* (also `Enter` on a deleted file). A moved branch or HEAD is followed within a poll. It
does nothing when the `git` binary isn't on `PATH`. The old `modules.git` keys warn
and are ignored: `enabled` moved here, `diff_view` and `filetree_diff_only` to the top level.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.git.enabled` | `true` | Off removes the diff base, the git status segments, the file-tree **Changed** tab and its status bars, *Git: Set Diff Base* and *Git: Restore File*. Merge-conflict highlighting stays. |

## Writing your own commands

A command is a `qed.command` call in a user plugin. `qed.spawn` runs a tool,
`qed.parse_locations` turns `file:line:col: msg` output into `qed.pick` items (list
with file preview), and `qed.jump` opens the file there. Panes with live data (a
query field, streamed results) use `qed.ui.open`; `plugins/search` is the example. A plugin's own config keys
come from `local cfg = qed.options{key = default}` in `setup`, overridden under
`plugins.<id>`. The API reference with types is `plugins/meta/qed.lua`.

Completion for `qed.*`: when the working root is `~/.config/qed` or below
(`qed ~/.config/qed/plugins`), qed tells lua-language-server about the type stub
and Lua 5.4. No file is written.

```lua
-- ~/.config/qed/plugins/my.lua
return {setup = function()
  qed.command{name = "Grep Word", key = "Alt+8", run = function(ctx) -- palette: "My: Grep Word"
    local word = ctx.selection_text or qed.prompt{prompt = "Grep:"}
    if not word or word == "" then return end
    local r = qed.spawn{argv = {"grep", "-rn", "--", word, "."}}
    local items = qed.parse_locations(r.stdout)
    if #items == 0 then return qed.message("no matches") end
    local it = qed.pick{items = items, prompt = "Grep >"}
    if it then qed.jump(it.path, it.pos) end
  end}
end}
```

## Themes & colors

Colors are not in `config.json`; they live in themes. Set the active theme with
the `theme` key (or the *Settings: Theme* picker, which persists it):

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
