;From nvim-treesitter/nvim-treesitter
(atx_heading
  (inline) @text.title)

(setext_heading
  (paragraph) @text.title)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @keyword

[
  (link_title)
  (indented_code_block)
  (fenced_code_block)
] @text.literal

; The ``` fences and their info string (```ts) render in the subtle code gray.
(fenced_code_block_delimiter) @text.code
(info_string) @text.code

(code_fence_content) @none

(link_destination) @text.uri

(link_label) @text.reference

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
  (thematic_break)
] @keyword

[
  (block_continuation)
  (block_quote_marker)
] @keyword

; GFM task-list checkboxes: unchecked yellow (@keyword), checked green (@string).
(task_list_marker_unchecked) @keyword
(task_list_marker_checked) @string

(backslash_escape) @string.escape
