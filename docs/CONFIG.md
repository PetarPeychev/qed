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
- **Forgiving.** An unknown key warns once and is ignored (a moved or renamed key names its new home); malformed JSON falls
  back to defaults without crashing.
- **Nested keys merge per-key**, so overriding one language's `lsp` leaves
  its `patterns` intact.

A minimal override looks like:

```json
{
  "line_wrap": false,
  "plugins": { "format": { "on_save": true } },
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
| `plugins.format.on_save` | `false` | Format on every save (after the fixups below). |
| `plugins.format.trim_whitespace_on_save` | `false` | Strip trailing whitespace (markdown two-space hard breaks are kept). |
| `plugins.format.final_newline_on_save` | `false` | Guarantee exactly one trailing newline. |
| `plugins.format.commands.<language>` | see `plugins/format/init.lua` | External stdin-to-stdout formatter for that language, e.g. `"python": "ruff format --stdin-filename {file} -"`. Absent or `""` falls back to LSP formatting. |

A formatter command runs under `sh -c` in the file's directory; `{file}` is replaced
with the file's quoted absolute path, for tools that take a stdin-filename flag. A
missing tool or non-zero exit leaves the buffer untouched with a message (a save
still goes ahead, unformatted). A save waits for formatting up to
`plugin_hook_timeout_ms`.

```json
{ "plugins": { "format": { "on_save": true, "commands": { "lua": "stylua -" } } } }
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
| `preview_diff_context` | `3` | Context lines around each hunk in the file-tree Git tab's diff preview. |
| `split_tree_min_width` / `split_tree_max_width` | `30` / `60` | List column of a `split:tree` pane (the file tree). |
| `split_code_min_width` / `split_code_max_width` | `50` / `100` | List column of a `split:code` pane (the default split: line find, search). |
| `split_preview_min_width` / `split_preview_max_width` | `70` / `130` | Preview column of any split pane. |
| `message_log_backdrop` | `"none"` | What shows around *Message Log: Open*: `"dim"` fades the editor and panes below (not the status rows), `"blank"` clears them, `"none"` leaves them. |
| `plugins_pane_backdrop` | `"none"` | The same for *Plugins: Open*. |

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
| `terminal_escape_closes` | `true` | At a shell prompt, Esc closes the terminal pane (forwarded on the alt-screen regardless). |
| `diff_view` | `false` | Inline diff view (ghost rows for removed/replaced lines against the diff base). *Diff: Toggle View*. |

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

Some panes have their own scoped commands, listed in that pane's `Ctrl+p` and run
by their key while it has focus. Panes without a text field (the Message Log and
Plugins pane) also take a bare key (`"d"`); elsewhere a bare key is invalid.

| Key | Default | Pane |
|-----|---------|------|
| `Message Log: Toggle Debug` / `Info` / `Warn` / `Error` | `"d"` / `"i"` / `"w"` / `"e"` | Message Log: show or hide that level (footer chip, clickable) |
| `Message Log: Toggle History` | `"h"` | Message Log: entries from previous sessions |
| `Plugins: Enable/Disable` | `"e"` | Plugins pane: writes `plugins.<id>.enabled` |
| `Plugins: Reload` | `"r"` | Plugins pane |
| `Plugins: Show Log` | `"l"` | Plugins pane: the Message Log filtered to the plugin |

The log's *Copy* follows the global `Copy` bind.

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

## Plugins

Lua plugins: bundled ones ship in the binary, your own go in
`~/.config/qed/plugins/` as `name.lua` or `name/init.lua`. See
[notes/plugins.md](notes/plugins.md). *Plugins: Open* lists them with their state
and last error: `e` enables/disables, `r` reloads, `l` shows the plugin's log
(rebindable, see [Keybinds](#keybinds)), `Enter` opens its source (bundled ones read-only).

| Key | Default | Meaning |
|-----|---------|---------|
| `plugin_memory_mb` | `256` | Memory cap for the Lua state; a task that exceeds it fails (logged) instead of growing, and its plugin stays loaded. `0` means no cap. |
| `plugin_slice_max_ms` | `1000` | Longest a plugin event handler, timer or background task may run without yielding; past it the task is stopped with a warning (the plugin stays loaded, as it does after any Lua error outside setup). |
| `plugin_command_max_ms` | `5000` | The same limit for a plugin command. |
| `plugin_hook_timeout_ms` | `2000` | How long a save waits for `buf_pre_save` handlers, and quit for `quit` handlers. On timeout the save (or quit) goes ahead and the slow plugin is named in a warning. |
| `plugins.<id>.enabled` | `true` | Off unloads that plugin (live) and drops its commands and binds. `e` in *Plugins: Open* writes this key. |
| `plugins.<id>.keybinds` | each command's `key` | Binds for that plugin's commands, keyed by the bare command name (`"Set Diff Base"`, not `"Git: Set Diff Base"`). `""` unbinds. A name no command of the loaded plugin has warns; a disabled plugin's binds are not checked. |
| `plugins.<id>.<key>` | plugin's `qed.options` | Per-key override of the plugin's own config; objects merge per key, arrays replace. Unknown keys warn once the plugin has loaded; a disabled plugin's keys are not checked. |

The id is the plugin's file or dir name. Its display name (the id title-cased, or
what the plugin sets with `qed.meta`) prefixes its commands in the palette
(`Git: Set Diff Base`) and labels its messages. A key already taken by a builtin is
ignored with a warning. Keybinds and `plugin_memory_mb` hot-reload. Changes under
`plugins.<id>` reach the plugin through its `config_changed` handler (`format`,
`filetree`, `search` apply them live, keeping runtime state); a plugin without one
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

### File tree

The file tree is the bundled `filetree` plugin: *File Tree: All* (`Alt+f`), *Open* (`Alt+o`) and
*Unsaved* (`Alt+u`) open it on that tab, and the `git` plugin's *Git: Changes* (`Alt+g`) on its Git tab
(also on the welcome screen); over an open tree a tab's chord switches to it and on the active tab
closes it. Its commands run while it has focus and are listed in its `Ctrl+p`: *File Tree: Copy*,
*Cut*, *Paste*, *Close Buffers* and *Select All* (default: the keys of the core *Copy*, *Cut*, *Paste*,
*Close Buffer* and *Select All*, followed across a config reload), *Delete* (`Ctrl+d`), *Rename*
(`Ctrl+r`), *New* (`Ctrl+n`), *Toggle Dotfiles* (`Alt+.`), *Toggle Ignored* (`Alt+i`), *Toggle Diff*
(`Alt+d`) and *Expand/Collapse All* (`Alt+e`). Rebind them with `plugins.filetree.keybinds.<name>`
(`"All"`, `"Delete"`, ...); the Git tab's chord is `plugins.git.keybinds.Changes` (the old
`plugins.filetree.keybinds.Changed` is gone). The old top-level `keybinds."File Tree"` and `keybinds."File Tree: ..."`
warn where they moved. The list width comes from `split_tree_min_width`/`split_tree_max_width`.
Without Lua (or with the plugin disabled) there is no file tree.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.filetree.enabled` | `true` | Off removes the file tree and its commands. |
| `plugins.filetree.show_dotfiles` | `false` | Show dotfiles (also in the working-directory picker). *File Tree: Toggle Dotfiles* (`Alt+.`) flips it for the session. |
| `plugins.filetree.show_ignored` | `false` | Show gitignored files. *File Tree: Toggle Ignored* (`Alt+i`). |
| `plugins.filetree.diff_only` | `true` | A diff preview (the Git tab's) shows only changed hunks, not the whole file. *File Tree: Toggle Diff* (`Alt+d`). |

The three apply live; a config edit changes only the knobs whose value changed, so a toggle on another
knob survives it.

### Working directory

*Workspace: Open Directory* (`Ctrl+o`, also on the welcome screen) and the file tree's
*Workspace: Open Selected Directory* (same chord, the selected dir or a file's parent) come from the
bundled `workspace` plugin. The picker lists dotfiles while the file tree shows them (`plugins.filetree.show_dotfiles` or
*File Tree: Toggle Dotfiles*); without the `filetree` plugin it hides them. Rebind both
with `plugins.workspace.keybinds["Open Directory"]`; the old top-level
`keybinds."Change Working Directory"` warns where it moved.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.workspace.enabled` | `true` | Off removes both commands. |

### Go to line

*Go to: Line* (`Ctrl+g`) comes from the bundled `goto` plugin: a filter over the
buffer's lines in file order with a preview, `:N` or `:N:M` jumps to a line (and column), and a bare number lists that line first.
Rebind with `plugins.goto.keybinds["Line"]`; the old top-level `keybinds."Find Line"`
warns where it moved, and a `plugins.lines` section warns that it was renamed.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.goto.enabled` | `true` | Off removes *Go to: Line*. |

### Search

*Search: Find in Files* (`Alt+F`) and the file tree's *Search: Find in Files* (same
chord, scoped to the selection) come from the bundled `search` plugin; both need `rg`
on `PATH`. Rebind both with `plugins.search.keybinds["Find in Files"]`.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.search.enabled` | `true` | Off removes both *Find in Files* commands. |
| `plugins.search.min_query` | `2` | Min query length before a search runs (was `projsearch_min_query`). |

### Markdown

*Markdown: Preview* (`Alt+p`, only in a markdown buffer) opens the buffer rendered in a
full pane capped at `max_width`: markers hidden, headings colored with a rule under H1/H2, code
blocks on a tinted band with syntax colors, lists, task boxes, quotes, box-drawn tables, link URLs
as numbered footnotes. The pane has focus, so it follows changes made outside it (disk reload,
formatters, plugins) and keeps its scroll; the same chord closes it. The preview follows the cursor:
it opens with the block holding the cursor's line on the cursor's screen row (as far as the document
ends allow), and closing it after scrolling moves the cursor to the line shown on that row (first
non-blank column) and scrolls the editor to match; closing without scrolling leaves the cursor. Clicking a link follows it: `#anchor` scrolls to the heading; a link to
another markdown file switches the preview to it (and the editor underneath, at the heading for
`file.md#anchor`, recorded in the jump list); a link to any other file closes the preview and opens
it; a URL opens in the platform browser (macOS `open`; WSL `wslview`, else `explorer.exe`; Linux
`xdg-open`). Anchor jumps and markdown file links are remembered: *Markdown: Back* and *Forward* step
through them while the preview has focus (default: the keys of *Jump Back* / *Jump Forward*, followed across a config reload;
rebind with `plugins.markdown.keybinds.Back` / `Forward`); file switches land in the
jump list too. LSP hover uses the same renderer (plaintext hovers render verbatim).

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.markdown.enabled` | `true` | Off removes *Markdown: Preview*. |
| `plugins.markdown.max_width` | `120` | Widest the preview pane gets, borders included (at least 20). Applies to an open preview. |
| `plugins.markdown.backdrop` | `"dim"` | What shows around the preview: `"dim"` fades the editor and panes below (not the status rows), `"blank"` clears them, `"none"` leaves them. |

### Git

The bundled `git` plugin fetches each buffer's diff base (the gutter, diff view,
*Diff: Next/Previous Change*, *Diff: Revert Hunk*), polls the branch, ahead/behind
and repo diff size into the status bar every 2 s, adds the file tree's **Git** tab
(*Git: Changes*, `Alt+g`, shown only while the `filetree` plugin is loaded), and owns *Git: Set Diff Base* and the tree's
*Git: Restore File* (also `Enter` on a deleted file). A moved branch or HEAD is followed within a poll. It
does nothing when the `git` binary isn't on `PATH`. The old `modules.git` keys warn
and are ignored: `enabled` moved here, `diff_view` to the top level, `filetree_diff_only` to `plugins.filetree.diff_only`.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.git.enabled` | `true` | Off removes the diff base, the git status segments, the file-tree **Git** tab, its status bars and ignored set, *Git: Changes*, *Git: Set Diff Base* and *Git: Restore File*. Merge-conflict highlighting is the `conflict` plugin's. |

### Merge conflicts

The bundled `conflict` plugin highlights `<<<<<<<`/`|||||||`/`=======`/`>>>>>>>` blocks (theme colors
`conflict_ours`/`conflict_theirs`/`conflict_base`, tints `conflict`/`conflict_marker`/`conflict_word`)
with or without git. *Conflict: Resolve* (`Alt+m`) asks Keep Ours / Theirs / Both inside a block and
jumps to the next block outside one. Edits rehighlight live in a buffer that had conflicts when opened,
reloaded or saved; a conflict typed or pasted into another buffer highlights on its next save. Rebind with `plugins.conflict.keybinds.Resolve`; the old top-level
`keybinds."Git: Resolve Conflict"` warns where it moved.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.conflict.enabled` | `true` | Off removes the highlighting and *Conflict: Resolve*. |

### AI

The bundled `ai` plugin: *AI: Edit Selection* (`Ctrl+k`, `plugins.ai.keybinds."Edit Selection"`) sends the
selection plus an instruction to a chat command, *AI: Cancel Edits* kills the running ones, and inline
completion shows FIM ghost-text while you type (`Tab` accepts, `Ctrl+Right` one word). See
[notes/ai.md](notes/ai.md). The old `modules.ai` keys warn and are ignored; each moved here under the same
name (`chat_command` is now `edit_command`), and the old `keybinds` entries (`AI: Edit Selection`, ...) moved to `plugins.ai.keybinds`.

| Key | Default | Meaning |
|-----|---------|---------|
| `plugins.ai.enabled` | `true` | Off removes the AI commands and inline completion and kills anything in flight. |
| `plugins.ai.edit_command` | `claude -p` | Shell command for the AI edit; the prompt goes in on stdin. |
| `plugins.ai.edit_prompt` | *(template)* | The instruction template; `{path}`, `{instruction}`, `{file}`, `{selection}` are substituted. |
| `plugins.ai.completion_enabled` | `false` | Inline FIM completion. *AI: Toggle Inline Completion* flips it for the session. |
| `plugins.ai.completion_endpoint` | Codestral FIM URL | FIM HTTP endpoint. |
| `plugins.ai.completion_model` | `codestral-latest` | FIM model name. |
| `plugins.ai.completion_api_key_env` | `CODESTRAL_API_KEY` | Env var holding the API key; it must be a variable name. The shell expands it into a here-doc that `curl` reads its header from, so it never appears in a process's argv. |
| `plugins.ai.completion_max_tokens` | `256` | Max tokens per FIM suggestion. |
| `plugins.ai.completion_debounce_ms` | `350` | Idle delay after typing before a FIM request. |
| `plugins.ai.completion_context_lines` | `200` | Lines of prefix/suffix context sent with each FIM request (each side capped at 64 KB; none on big files). |

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
`icons`, and `tints` (line-background strengths; `pane_backdrop` is how far a `"dim"` backdrop fades text; `markdown_code` is the code band in
rendered markdown, the pane selection color over the pane background). The complete key list is
[`config/themes/default.json`](../config/themes/default.json); qed never writes
theme files.
