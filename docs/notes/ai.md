# AI / LLM assist

Design reference for the LLM features: inline completion (ghost-text,
Supermaven-style), and two instruction-driven modes (selection+prompt,
context+prompt). Read CLAUDE.md and DESIGN.md first. This is a `notes/` file
because the subsystem spans several TODO items; the one-liners in
[../TODO.md](../TODO.md) link here.

**Status:** *Selection + prompt* (`Ctrl+K`) and *inline FIM ghost-text* (`fim.odin`,
Codestral via `curl`) shipped, along with the reusable async subprocess runner they
share. Still open: context + prompt, the provider-neutral `llm` config (named HTTP
providers vs command; only Codestral's shape is wired today), a genuinely *shared*
inline virtual-text primitive (ghost-text has its own renderer; inline diagnostics still
want one), and letting an edit touch code outside the selection.

## Two backends, never one

Ghost-text and prompt-editing need different models, so they are configured
independently:

| Backend | Serves | Contract | Default / options |
|---------|--------|----------|-------------------|
| **completion** (FIM) | inline ghost-text | `prefix + suffix → continuation`; low-latency, debounced, cancellable | **Codestral** (`/v1/fim/completions`) · Ollama `qwen2.5-coder` · llama.cpp `/infill` |
| **chat** | selection+prompt, context+prompt | `instruction + context → text` | `claude -p` (subscription) · Anthropic/OpenAI HTTP · Ollama |

A FIM model emits just the continuation with near-zero latency; a chat model
follows instructions. One cannot do the other's job well, so there is no shared
"llm provider" — two slots, two providers.

## Provider contract

A provider is one of two transports, so qed needs **no native HTTP/TLS stack**:

- **command** — an argv template. qed writes the assembled prompt to stdin,
  reads the completion/answer from stdout. This is the truly model-agnostic
  escape hatch: `claude -p`, `aider`, `llm`, a local script — all just commands.
- **http** — a named provider (`codestral`, `ollama`, `anthropic`, `openai`,
  `llamacpp`) whose request/response JSON shape qed knows. Transport is a
  `curl` subprocess (ubiquitous on Linux/macOS, matches the isolate-external-
  tools rule — same as clipboard/`rg`/`git`).

So **every** provider is ultimately a subprocess. That collapses the infra need
to one thing: an **async subprocess runner with cancellation** (see below).

## Config schema

Lives under the `llm` section of the embedded `config/config.json`, materialized into
`~/.config/qed/config.json` like every other knob. Sketch:

```json
"llm": {
  "completion": {
    "enabled": true,
    "provider": "codestral",
    "endpoint": "https://codestral.mistral.ai/v1/fim/completions",
    "model": "codestral-latest",
    "api_key_env": "CODESTRAL_API_KEY",
    "max_tokens": 256,
    "debounce_ms": 150,
    "context_lines": 200
  },
  "chat": {
    "provider": "command",
    "command": ["claude", "-p"],
    "endpoint": "", "model": "", "api_key_env": ""
  }
}
```

`provider: "command"` uses `command` (+ stdin); a named http `provider` uses
`endpoint`/`model`/`api_key_env`. API keys come from the environment, never the
config file.

## Infra needed (the hard part is in qed, not the model)

1. **Async subprocess runner + cancellation.** `shell.odin` is synchronous; the
   non-blocking machinery to copy is `lsp.odin` (poll-integrated stdio). Generalize
   it into a small request client that spawns a provider subprocess, feeds stdin,
   collects stdout without blocking the main loop, and can be killed / have its
   result discarded the instant the user types. Completion is fired debounced and
   cancel-on-keystroke; chat is fire-and-await-with-spinner.
2. **Inline virtual-text primitive.** Dimmed text drawn at a `(row, col)` that is
   **not** backed by the buffer and does not affect column math; cleared on any
   edit/move. Ghost-text (multi-line, at cursor) and the already-ticketed inline
   diagnostic text (single-line, end-of-line) share this primitive — build once.

## Inline completion (ghost-text)

- Assemble `prefix` = buffer up to cursor, `suffix` = buffer after cursor, each
  clamped to `context_lines`. Send to the completion provider debounced after
  typing pauses; discard if the cursor moved or text changed before it returns.
- Render the returned continuation as dimmed virtual text at the cursor.
- **Tab arbitration:** when ghost-text is visible Tab **accepts** (insert as one
  undo group via `buffer_insert`); otherwise Tab indents as today. Word-at-a-time
  accept key TBD; `Esc` dismisses.

## Prompt modes (chat backend)

- **Selection + prompt (`Ctrl+K`):** with a selection, open a one-line prompt;
  send `selection + instruction`, replace the selection with the result as a
  single undo group.
- **Context + prompt:** no selection — floating prompt pane (reuse the `pane`/
  `linefind` shape); send `instruction + cursor context`; insert at cursor or
  replace a range. Streaming optional (chunk stdout into the buffer) — later.

## Notes

- **Cost:** Codestral FIM is cheap per-token and low-latency — the reason it, not
  a chat model, drives ghost-text. Ollama/llama.cpp are the free/local FIM path.
- **Scope caveat:** an AI subsystem is the biggest departure yet from qed's
  "single author, small, no plugins" ethos — kept honest by (a) reusing the
  external-tool + config-knob patterns already in the codebase, and (b) the
  command-provider escape hatch meaning qed hard-codes no vendor.

## Open questions

- Word-accept keybind for ghost-text; manual-trigger key vs. auto-only.
- Whether chat streaming is worth the incremental-insert complexity.
- Multi-line ghost-text rendering vs. horizontal-scroll / gutter interactions.
