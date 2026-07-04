# qed

`qed` is a personal terminal text editor written in [Odin](https://odin-lang.org),
in the spirit of micro/nano but with GUI-style (CTRL-based) keybinds. It runs on
Linux and macOS, in any truecolor terminal.

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

## Optional dependencies

`qed` works without these; each feature simply stays off if its tool is missing.

| Feature | Linux | macOS |
|---------|-------|-------|
| Clipboard | `wl-clipboard` (Wayland) or `xclip` (X11) | built in (`pbcopy`/`pbpaste`) |
| Project-wide search | `ripgrep` (`rg`) | `ripgrep` (`rg`) |
| Diff gutter | `git` | `git` (comes with the Command Line Tools) |

### Language servers (LSP diagnostics)

Install only the ones for languages you use:

| Language | Server |
|----------|--------|
| Odin | [ols](https://github.com/DanielGavin/ols) |
| Python | [pyright](https://github.com/microsoft/pyright) |
| C | [clangd](https://clangd.llvm.org) |
| JS/TS | [typescript-language-server](https://github.com/typescript-language-server/typescript-language-server) |
| Shell | [bash-language-server](https://github.com/bash-lsp/bash-language-server) |
| Lua | [lua-language-server](https://github.com/LuaLS/lua-language-server) |

Syntax highlighting is built in (tree-sitter, no external tools) for all of the
above plus JSON, SQL, and Markdown.

## Configuration

Defaults live compiled-in; `~/.config/qed/config.json` overrides them (colors,
sizes, timeouts, keybinds) and is auto-materialized with every key on first run.
