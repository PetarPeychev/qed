; JSX for .tsx (qed deviation-by-append). The tsx grammar has JSX nodes the
; shared typescript grammar lacks, so these captures are concatenated onto the
; typescript query only for .tsx — putting them in typescript/highlights.scm
; would fail to compile against the plain typescript grammar.
(jsx_opening_element (identifier) @tag)
(jsx_closing_element (identifier) @tag)
(jsx_self_closing_element (identifier) @tag)
(jsx_attribute (property_identifier) @tag.attribute)
