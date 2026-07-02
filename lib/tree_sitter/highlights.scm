; Preprocs

[
  (calling_convention)
  (tag)
] @preproc

; Includes

[
  "import"
  "package"
] @include

; Keywords

[
  "foreign"
  "using"
  "struct"
  "enum"
  "union"
  "defer"
  "cast"
  "transmute"
  "auto_cast"
  "map"
  "bit_set"
  "matrix"
  "bit_field"
] @keyword

[
  "proc"
] @keyword.function

[
  "return"
  "or_return"
] @keyword.return

[
  "distinct"
  "dynamic"
] @storageclass

; Conditionals

[
  "if"
  "else"
  "when"
  "switch"
  "case"
  "where"
  "break"
  (fallthrough_statement)
] @conditional

(ternary_expression
  [
    "?"
    ":"
    "if"
    "else"
    "when"
  ] @conditional.ternary)

; Repeats

[
  "for"
  "do"
  "continue"
] @repeat

; Variables

(identifier) @variable

; Namespaces

(package_declaration (identifier) @namespace)

(import_declaration alias: (identifier) @namespace)

(foreign_block (identifier) @namespace)

(using_statement (identifier) @namespace)

; Parameters

(parameter (identifier) @parameter ":" "="? (identifier)? @constant)

(default_parameter (identifier) @parameter ":=")

(named_type (identifier) @parameter)

(call_expression argument: (identifier) @parameter "=")

; Functions

(procedure_declaration (identifier) @function (procedure (block)))

(procedure_declaration (identifier) @function (procedure (uninitialized)))

(overloaded_procedure_declaration (identifier) @function)

(call_expression function: (identifier) @function.call)

; Types

(type (identifier) @type)

"..." @type.builtin

(struct_declaration (identifier) @type "::")

(enum_declaration (identifier) @type "::")

(union_declaration (identifier) @type "::")

(bit_field_declaration (identifier) @type "::")

(const_declaration (identifier) @type "::" [(array_type) (distinct_type) (bit_set_type) (pointer_type)])

(struct . (identifier) @type)

(field_type . (identifier) @namespace "." (identifier) @type)

(bit_set_type (identifier) @type ";")

(procedure_type (parameters (parameter (identifier) @type)))

(polymorphic_parameters (identifier) @type)

; Fields

(member_expression "." (identifier) @field)

(struct_type "{" (identifier) @field)

(struct_field (identifier) @field "="?)

(field (identifier) @field)

; Constants

(member_expression . "." (identifier) @constant)

(enum_declaration "{" (identifier) @constant)

; Attributes

(attribute (identifier) @attribute "="?)

; Labels

(label_statement (identifier) @label ":")

; Literals

(number) @number

(float) @float

(string) @string

(character) @character

(escape_sequence) @string.escape

(boolean) @boolean

[
  (uninitialized)
  (nil)
] @constant.builtin

; Operators

[
  ":="
  "="
  "+"
  "-"
  "*"
  "/"
  "%"
  "%%"
  ">"
  ">="
  "<"
  "<="
  "=="
  "!="
  "~="
  "|"
  "~"
  "&"
  "&~"
  "<<"
  ">>"
  "||"
  "&&"
  "!"
  "^"
  ".."
  "+="
  "-="
  "*="
  "/="
  "%="
  "&="
  "|="
  "^="
  "<<="
  ">>="
  "||="
  "&&="
  "&~="
  "..="
  "..<"
  "?"
] @operator

[
  "or_else"
  "in"
  "not_in"
] @keyword.operator

; Punctuation

[ "{" "}" ] @punctuation.bracket

[ "(" ")" ] @punctuation.bracket

[ "[" "]" ] @punctuation.bracket

[
  "::"
  "->"
  "."
  ","
  ":"
  ";"
] @punctuation.delimiter


[
  "@"
  "$"
] @punctuation.special

; Comments

[
  (comment)
  (block_comment)
] @comment @spell

; Errors

(ERROR) @error
