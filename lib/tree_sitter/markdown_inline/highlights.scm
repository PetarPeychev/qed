; From nvim-treesitter/nvim-treesitter
; Inline code and its backticks render in the subtle code gray.
(code_span) @text.code
(code_span_delimiter) @text.code
(link_title) @text.literal

(emphasis_delimiter) @punctuation.delimiter

(emphasis) @text.emphasis

(strong_emphasis) @text.strong

[
  (link_destination)
  (uri_autolink)
] @text.uri

; Only real links (with a destination/label) are colored; a bare shortcut_link
; [text] is left plain so stray brackets and malformed checkboxes don't read as
; links.
(link_label) @text.reference
(inline_link (link_text) @text.reference)
(image_description) @text.reference

[
  (backslash_escape)
  (hard_line_break)
] @string.escape

(image
  [
    "!"
    "["
    "]"
    "("
    ")"
  ] @text.reference)

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @text.reference)

; NOTE: extension not enabled by default
; (wiki_link ["[" "|" "]"] @punctuation.delimiter)
