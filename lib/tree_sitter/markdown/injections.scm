; Curated for qed's structural injection pass (highlight.odin). Upstream uses
; `(#set! injection.language "…")` predicates the tree-sitter C core does not
; evaluate, so qed cannot read the target language from them. Instead the target
; is encoded by CAPTURE NAME convention:
;   @inline              -> inject the markdown_inline grammar
;   @language + @content -> inject the language named by @language's text
;
; Only paragraph inlines are injected (not atx_heading inlines), so headings keep
; their solid @text.title color instead of being overwritten by the inline pass.
; The html/yaml/toml metadata injections are dropped (no grammar for them).

(paragraph
  (inline) @inline)

(fenced_code_block
  (info_string
    (language) @language)
  (code_fence_content) @content)
