# Configuration reference

Every qed tunable, in one place. Defaults are compiled into the binary from two
files, which are the canonical, always-current reference:

- [`config/config.json`](../config/config.json): knobs, keybinds, and
  per-language LSP/formatter wiring.
- [`config/themes/default.json`](../config/themes/default.json): the complete
  color, icon, and tint palette every theme overlays.

## How config works

You never copy either file. `~/.config/qed/config.json` is a sparse per-key
diff: put in only the keys you want to change; everything else keeps its
compiled-in default. qed never writes this file (except the theme picker, which
persists the single `theme` key when you press Enter on it).

- **Hot-reloaded.** Save the file and the change applies live: colors, keybinds,
  and knobs take effect without a restart.
- **Forgiving.** An unknown key warns once and is ignored; malformed JSON falls
  back to defaults without crashing.
- **Nested keys merge per-key**, so overriding one language's `formatter` leaves
  its `patterns` and `lsp` intact.

A minimal override looks like:

```json
{
  "line_wrap": false,
  "format_on_save": true,
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

## Save behavior

All default off; each has a runtime *Toggle* command.

| Key | Default | Meaning |
|-----|---------|---------|
| `format_on_save` | `false` | Run the language formatter (external tool, else LSP) on every save. |
| `trim_trailing_whitespace_on_save` | `false` | Strip trailing whitespace (markdown two-space hard breaks are kept). |
| `ensure_final_newline_on_save` | `false` | Guarantee exactly one trailing newline. |

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

The `languages` section keys each language by name. Every entry has three
user-overridable fields:

- **`patterns`**: glob list matched against the filename basename
  (most-specific first), e.g. `["*.py", "*.pyw"]` or dotfiles like `.bashrc`.
- **`lsp`**: the language-server command (`""` is none), e.g. `pyright-langserver --stdio`.
- **`formatter`**: an external stdin-to-stdout filter (`""` falls back to LSP
  formatting), e.g. `ruff format -`.

Overriding one field merges over the compiled-in default, so you can swap just a
formatter or point `lsp` at a different binary. Syntax highlighting is wired into
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
| `enabled` | `true` | Master switch. Off stops every language server — no diagnostics, completion, hover, go-to-definition, or rename; formatting falls back to the external `formatter`. |
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
