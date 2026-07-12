# qed

A personal terminal text editor written in [Odin](https://odin-lang.org) — the
speed and footprint of a TUI editor, with the keybinds you already know. `qed`
runs on Linux and macOS in any truecolor terminal, and uses **GUI-style
CTRL-based shortcuts** (`Ctrl+S` save, `Ctrl+C`/`Ctrl+V` copy/paste, `Ctrl+F`
find) instead of modal editing — nano's approachability with a modern feature
set underneath.

<p align="center">
  <img src="docs/screenshots/file-pane.png" alt="qed editing its own source with the file tree and preview open" width="900">
</p>

## Features

- **Modern editing** — Unicode/grapheme-aware cursor, soft wrap, multi-buffer,
  grouped undo/redo, auto-indent, auto-close pairs, block indent, line comment
  toggle, smart word/paragraph motion with held-key acceleration.
- **Syntax highlighting** — tree-sitter for 20 languages (see the table below),
  theme-driven, with language injection (code in Markdown, `<script>`/`<style>`
  in HTML).
- **Language servers** — diagnostics, go-to-definition, hover (rendered
  markdown), workspace-wide rename, as-you-type completion, and document
  formatting over LSP for a dozen languages.
- **Git aware** — live diff gutter, inline diff view, per-file diff preview,
  branch + ahead/behind in the status bar, merge-conflict highlighting and
  resolve.
- **Navigation** — a modal **file tree** (open/copy/rename/delete/search),
  fuzzy line jump, project-wide search (ripgrep), find/replace (regex,
  smart-case), and a command palette (`Ctrl+P`).
- **Embedded terminal** — a persistent full-TUI-capable shell in a floating pane
  (`Alt+t`), with mouse, scrollback, and copy/paste.
- **AI assist** (optional) — selection-and-prompt edits via any chat command
  (`Ctrl+K`) and inline FIM ghost-text completion.
- **Configurable** — every knob, keybind, and color is JSON, hot-reloaded from
  `~/.config/qed/` — see the [configuration reference](docs/CONFIG.md).

## Screenshots

<table>
<tr>
<td width="50%"><img src="docs/screenshots/welcome.png" alt="Welcome screen"><br><em>Welcome screen — working root, git branch, and the keys to get started.</em></td>
<td width="50%"><img src="docs/screenshots/find-replace.png" alt="Find and replace"><br><em>Find &amp; replace — regex, smart-case, live match count, every hit highlighted.</em></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/lsp-errors.png" alt="LSP diagnostics"><br><em>LSP diagnostics — inline underline, gutter severity, error popup.</em></td>
<td width="50%"><img src="docs/screenshots/lsp-hover.png" alt="Hover documentation"><br><em>Hover — rendered-markdown docs from the language server.</em></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/diff.png" alt="Inline diff view"><br><em>Inline diff view — removed lines as ghost rows with word-level highlight.</em></td>
<td width="50%"><img src="docs/screenshots/terminal.png" alt="Embedded terminal"><br><em>Embedded terminal — a persistent full-TUI shell in a floating pane.</em></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/themes.png" alt="Theme picker"><br><em>Set Theme — instant-preview picker over the bundled themes.</em></td>
<td width="50%"><img src="docs/screenshots/ai.png" alt="AI edit"><br><em>AI edit — select a region, describe the change (<code>Ctrl+K</code>).</em></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/fim.png" alt="Inline completion"><br><em>Inline completion — dimmed FIM ghost-text, accepted with <code>Tab</code>.</em></td>
<td width="50%"><img src="docs/screenshots/inspect-syntax.png" alt="Inspect Tokens"><br><em>Inspect Tokens — live tree-sitter capture and color resolution.</em></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/debug-logs.png" alt="Message log"><br><em>Message Log — timestamped, level-filtered, cross-session.</em></td>
<td width="50%"></td>
</tr>
</table>

## Installation

### Prerequisites

- **[Odin](https://odin-lang.org/docs/install/)** — the compiler (bundles LLVM).
- **A C compiler** (`cc`) and **`ar`** — used to build the vendored termbox2 and
  tree-sitter static libraries.

### Linux

```sh
# 1. Toolchain (Debian/Ubuntu example — adjust for your distro)
sudo apt install build-essential git
#    Install Odin from https://odin-lang.org/docs/install/

# 2. Build
git clone https://github.com/PetarPeychev/qed.git && cd qed
./build.sh

# 3. Run
./qed [PATH]        # PATH is a file or directory; omit for the welcome screen
```

Put `qed` on your `PATH` (e.g. symlink it into `~/.local/bin`) to run it from
anywhere.

### macOS

```sh
# 1. Toolchain
xcode-select --install     # provides cc (clang), ar, git
brew install odin          # https://odin-lang.org/docs/install/

# 2. Build
git clone https://github.com/PetarPeychev/qed.git && cd qed
./build.sh

# 3. Run
./qed [PATH]
```

## Quickstart (60 seconds)

```sh
./qed .          # open the current directory: working root + welcome screen
```

- **`Ctrl+P`** opens the **command palette** — every command with its current
  shortcut. When in doubt, start here.
- **`Alt+f`** opens the **file tree**; `Enter` opens a file or expands a folder,
  type to fuzzy-filter, and `Ctrl+P` inside it lists tree-specific actions.
- Edit with the shortcuts you expect: `Ctrl+S` save, `Ctrl+Z`/`Ctrl+Y`
  undo/redo, `Ctrl+C`/`Ctrl+X`/`Ctrl+V`, `Ctrl+F` find, `Ctrl+H` replace,
  `Ctrl+G` jump to line, `Alt+F` search the project.
- **`Alt+t`** drops into an embedded terminal; `Alt+t` again hides it.
- `Ctrl+Q` quits (prompts if anything is unsaved).

Everything is rebindable — see [Configuration](#configuration).

## Dependencies

`qed` runs with just the build toolchain. These external tools unlock optional
features; each stays off if its tool is missing.

| Feature | Linux | macOS |
|---------|-------|-------|
| Clipboard | `wl-clipboard` (Wayland) or `xclip` (X11) | built in (`pbcopy`/`pbpaste`) |
| Project-wide search | `ripgrep` (`rg`) | `ripgrep` (`rg`) |
| Git gutter / diff / branch | `git` | `git` (comes with the Command Line Tools) |
| AI edit (`Ctrl+K`) | any chat CLI (default `claude -p`) | same |
| Inline completion | `curl` + a FIM API key | same |

### Per-language tools

Syntax highlighting is built in (tree-sitter, no external tools) for every
language below. Language servers and formatters are separate installs — grab
only the ones for languages you use. Any of these can be swapped or repointed in
config; see the [configuration reference](docs/CONFIG.md#languages).

| Language | Highlight | Language server | Formatter |
|----------|:---------:|-----------------|-----------|
| Odin | ✓ | [ols](https://github.com/DanielGavin/ols) | — |
| Python | ✓ | [pyright](https://github.com/microsoft/pyright) | [ruff](https://github.com/astral-sh/ruff) |
| C / C++ | ✓ | [clangd](https://clangd.llvm.org) | — |
| Go | ✓ | [gopls](https://pkg.go.dev/golang.org/x/tools/gopls) | `gofmt` |
| Rust | ✓ | [rust-analyzer](https://rust-analyzer.github.io) | `rustfmt` |
| JavaScript / JSX | ✓ | [typescript-language-server](https://github.com/typescript-language-server/typescript-language-server) | — |
| TypeScript / TSX | ✓ | typescript-language-server | — |
| HTML | ✓ | [vscode-langservers-extracted](https://github.com/hrsh7th/vscode-langservers-extracted) | — |
| CSS | ✓ | vscode-langservers-extracted | — |
| Shell | ✓ | [bash-language-server](https://github.com/bash-lsp/bash-language-server) | — |
| Lua | ✓ | [lua-language-server](https://github.com/LuaLS/lua-language-server) | — |
| YAML | ✓ | [yaml-language-server](https://github.com/redhat-developer/yaml-language-server) | — |
| TOML | ✓ | [taplo](https://taplo.tamasfe.dev) | `taplo fmt -` |
| Dockerfile | ✓ | [docker-langserver](https://github.com/rcjsuen/dockerfile-language-server) | — |
| JSON | ✓ | — | — |
| SQL | ✓ | — | — |
| Markdown | ✓ | — | — |

## Configuration

Defaults are compiled into the binary; `~/.config/qed/config.json` overrides them
as a **sparse per-key diff** (only the keys you set) and is hot-reloaded on save.
qed never writes it. Colors live in themes — set `"theme"` or use the *Set Theme*
picker.

The full list of knobs, keybinds, the language table, and theme keys is in the
**[configuration reference](docs/CONFIG.md)**, which links to the two canonical
default files:
[`config/config.json`](config/config.json) and
[`config/themes/default.json`](config/themes/default.json).
