# AI / LLM assist

Design reference for the bundled `ai` plugin (`plugins/ai`): inline completion (ghost-text,
Supermaven-style) and instruction-driven edits. Read CLAUDE.md and DESIGN.md (AI plugin) first.

**Status:** *Selection + prompt* (`Ctrl+k`) and *inline FIM ghost-text* (Codestral via `curl`)
shipped, as a Lua plugin since M7. Core keeps only generic primitives: `qed.spawn_bg`, range marks
(`qed.deco.mark`/`range`), theme tint names for `qed.deco.tint`, the inline ghost
(`qed.deco.inline`: rendering and the accept/dismiss keys) and `buf_changed`'s `typed` flag. Still
open: context + prompt, the provider-neutral config (named HTTP providers vs command; only
Codestral's shape is wired today), sharing the inline ghost with inline diagnostics, and letting an
edit touch code outside the selection.

## Two backends, never one

Ghost-text and prompt-editing need different models, so they are configured independently:

| Backend | Serves | Contract | Default / options |
|---------|--------|----------|-------------------|
| **completion** (FIM) | inline ghost-text | `prefix + suffix → continuation`; low-latency, debounced, cancellable | **Codestral** (`/v1/fim/completions`) · Ollama `qwen2.5-coder` · llama.cpp `/infill` |
| **chat** | selection+prompt, context+prompt | `instruction + context → text` | `claude -p` (subscription) · Anthropic/OpenAI HTTP · Ollama |

A FIM model emits just the continuation with near-zero latency; a chat model follows instructions.
One cannot do the other's job well, so there is no shared "llm provider": two slots, two providers.

## Provider contract

A provider is one of two transports, so qed needs **no native HTTP/TLS stack**:

- **command**: an argv template. The plugin writes the assembled prompt to stdin and reads the
  answer from stdout. The model-agnostic escape hatch: `claude -p`, `aider`, `llm`, a local script.
- **http**: a named provider (`codestral`, `ollama`, `anthropic`, `openai`, `llamacpp`) whose
  request/response JSON shape the plugin knows, sent through a `curl` subprocess.

Every provider is a `qed.spawn_bg` process, killed on cancel, unload and quit.

## Config schema

Today: flat keys under `plugins.ai` (see CONFIG.md, AI). Target sketch for the provider-neutral
redesign:

```json
"ai": {
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
`endpoint`/`model`/`api_key_env`. API keys come from the environment, never the config file.

## Inline completion (ghost-text)

- A typed change (`buf_changed` with `typed`) arms a debounce timer; the next typed change kills the
  timer and the running request. When the timer fires, a moved cursor or rev (a click) drops it; big
  buffers never arm it. `prefix`/`suffix` are clamped to `completion_context_lines` and 64 KB each.
- The key goes in an `Authorization` header that `curl` reads from a here-doc on fd 3 (`-H @/dev/fd/3`),
  so it never shows in argv; `completion_api_key_env` must be a plain variable name.
- A reply counts only for the same buffer, rev and cursor; it becomes `qed.deco.inline` text.
- Core owns everything on the keystroke path: `Tab` accepts all (one undo step), `Ctrl+Right` a
  word, `Esc` / any other key / a click / an edit dismisses.

## Prompt modes (chat backend)

- **Selection + prompt (`Ctrl+k`):** with a selection, a `qed.prompt` takes the instruction; the
  plugin sends the whole file with the selection marked, tracks the range with a mark set before the
  prompt (an edit inside, a reload touching it, or closing the buffer cancels), and replaces it with
  the reply's last fenced block as one undo step. A non-zero exit discards the reply.
- **Context + prompt:** no selection; floating prompt pane; send `instruction + cursor context`;
  insert at cursor or replace a range. Streaming optional (`spawn_bg{on_line}`), later.

## Notes

- **Cost:** Codestral FIM is cheap per token and low-latency, the reason it, not a chat model,
  drives ghost-text. Ollama/llama.cpp are the free/local FIM path. Only typing asks: paste, undo,
  accepts and plugin edits never fire a request.

## Open questions

- Manual-trigger key vs. auto-only.
- Whether chat streaming is worth the incremental-insert complexity.
