package main

import "lib:tb2"

SCROLL_MARGIN := 10
TAB_WIDTH := 4
WHEEL_SCROLL_LINES := 3
DOUBLE_CLICK_MS := 400
DISK_POLL_MS := 1000

CURSOR_ACCEL := true
CURSOR_ACCEL_INTERVAL_MS := 55
CURSOR_ACCEL_RAMP_PRESSES := 20
CURSOR_ACCEL_MAX_STEP := 6

FORMAT_ON_SAVE := false
AUTO_CLOSE_PAIRS := true
GIT_DIFF_VIEW := false
LINE_WRAP := true
FILETREE_SHOW_DOTFILES := false
FILETREE_SHOW_IGNORED := false
FILETREE_PREVIEW_BYTES := 64 * 1024

LLM_CHAT_COMMAND := "claude -p"
LLM_EDIT_PROMPT :=
	"You are editing the file {path}. Its full current content is below, with the region to rewrite marked between <<<SELECT and SELECT>>>. You may read other project files for context and reason briefly first if you need to. Then give the replacement for the marked region — and nothing else — inside a single markdown fenced code block (```). Do not repeat the surrounding code or the markers, and write nothing after the closing fence.\n\nInstruction: {instruction}\n\n{file}"

LLM_COMPLETION_ENABLED := false
LLM_COMPLETION_ENDPOINT := "https://codestral.mistral.ai/v1/fim/completions"
LLM_COMPLETION_MODEL := "codestral-latest"
LLM_COMPLETION_API_KEY_ENV := "CODESTRAL_API_KEY"
LLM_COMPLETION_MAX_TOKENS := 256
LLM_COMPLETION_DEBOUNCE_MS := 350
LLM_COMPLETION_CONTEXT_LINES := 200

PALETTE_WIDTH := 60
PALETTE_MAX_ROWS := 8

STATUS_ROWS :: 2

PICKER_MARGIN_X := 8
PICKER_MARGIN_Y := 3

PROJSEARCH_MAX := 500
PROJSEARCH_MIN_QUERY := 2

ALT_ESC_TIMEOUT_MS := 25

LSP_POLL_MS := 30
// pyright/basedpyright analyze only open files by default, so cross-file rename
// and references miss unopened files; "workspace" makes them index the whole root.
LSP_DIAGNOSTIC_MODE :: "workspace"
DIAG_PANE_MARGIN_X := 2
DIAG_PANE_MAX_LINES := 8
HOVER_PANE_MAX_LINES := 40

COMPLETION_DEBOUNCE_MS := 120
COMPLETION_MAX_ROWS := 8
COMPLETION_MAX_WIDTH := 40
COMPLETION_MIN_CHARS := 1

JUMP_THRESHOLD := 10

GIT_DIFF_MAX_D := 2000

HIGHLIGHT_ASYNC_BYTES := 256 * 1024

BIG_FILE_BYTES := 2 * 1024 * 1024

COLOR_FG := tb2.Color(0xf4f4ff)
COLOR_BG := tb2.Color(0x181818)
COLOR_STATUS_FG := tb2.Color(0xf4f4ff)
COLOR_STATUS_BG := tb2.Color(0x2b2b2b)
COLOR_ERROR_FG := tb2.Color(0xd2a8a1)
COLOR_DIAG_ERROR_FG := tb2.Color(0xf43841)
COLOR_DIAG_WARN_FG := tb2.Color(0xffdd33)
COLOR_DIAG_INFO_FG := tb2.Color(0xaaaaaa)
COLOR_GUTTER_FG := tb2.Color(0x868686)
COLOR_GUTTER_BG := tb2.Color(0x1b1b1b)
COLOR_CURRENT_LINE_FG := tb2.Color(0xd8d8d8)
COLOR_CURRENT_LINE_BG := tb2.Color(0xffffff)
COLOR_AI_EDIT_BG := tb2.Color(0x5a378a)
COLOR_GHOST_FG := tb2.Color(0x9e9e9e)
COLOR_PANE_FG := tb2.Color(0xf4f4ff)
COLOR_PANE_BG := tb2.Color(0x2b2b2b)
COLOR_PANE_BORDER := tb2.Color(0x868686)
COLOR_PANE_PROMPT_FG := tb2.Color(0xffdd33)
COLOR_PANE_SHORTCUT_FG := tb2.Color(0x868686)
COLOR_PANE_SEL_FG := tb2.Color(0xf4f4ff)
COLOR_PANE_SEL_BG := tb2.Color(0x4a4a4a)
COLOR_FILETREE_IGNORED := tb2.Color(0x686868)

TERM_SCROLLBACK := 2000

COLOR_TERM_FG := tb2.Color(0xf4f4ff)
COLOR_TERM_BG := tb2.Color(0x2b2b2b)
// kitty's default palette lifted +0x20 per channel so darker entries stay legible
// on the light pane background.
COLOR_TERM_ANSI := [16]tb2.Color {
	tb2.Color(0x202020),
	tb2.Color(0xec2423),
	tb2.Color(0x39eb20),
	tb2.Color(0xeeeb20),
	tb2.Color(0x2d93ec),
	tb2.Color(0xeb3ef1),
	tb2.Color(0x2deded),
	tb2.Color(0xfdfdfd),
	tb2.Color(0x969696),
	tb2.Color(0xff403f),
	tb2.Color(0x43ff20),
	tb2.Color(0xffff20),
	tb2.Color(0x3aafff),
	tb2.Color(0xff48ff),
	tb2.Color(0x34ffff),
	tb2.Color(0xffffff),
}

COLOR_SYN_KEYWORD := tb2.Color(0xffdd33)
COLOR_SYN_TYPE := tb2.Color(0x96a6c8)
COLOR_SYN_STRING := tb2.Color(0x73c936)
COLOR_SYN_COMMENT := tb2.Color(0xcc8c3c)
COLOR_SYN_CONSTANT := tb2.Color(0x95a99f)
COLOR_SYN_ATTRIBUTE := tb2.Color(0xffdd33)
COLOR_SYN_CODE := tb2.Color(0x95a99f)

COLOR_GIT_ADD := tb2.Color(0x73c936)
COLOR_GIT_MOD := tb2.Color(0xffdd33)
COLOR_GIT_DEL := tb2.Color(0xf43841)

CURRENT_LINE_TINT :: 0.06
AI_EDIT_TINT :: 0.35
GIT_HUNK_TINT :: 0.12
GIT_DIFF_GHOST_TINT :: 0.12
GIT_DIFF_WORD_TINT :: 0.34
