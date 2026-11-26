qed-e2e snapshot 140x45 cursor hidden
-- text
   1 # qed
   2
   3 A terminal text editor written in [Odin](https://odin-lang.org), inspired by
   4 [micr┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
   5 `Ctrl│ README.md                                                                                                            │
   6 IDE-l├──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
   7 Runs │ qed                                                                                                                  ┃
   8      │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ┃
   9 <p al│                                                                                                                      ┃
  10   <im│ A terminal text editor written in Odin, inspired by micro. Ctrl-based keybinds (Ctrl+S save, Ctrl+C/Ctrl+V           ┃
  11 </p> │ copy/paste, Ctrl+F find) instead of modal editing, plus IDE-lite features: syntax highlighting, LSP, git             ┃
  12      │ integration, and LLM assist. Runs on Linux and macOS in any truecolor terminal.                                      │
  13 ## Co│                                                                                                                      │
  14      │                                   [image: qed with the file tree and preview open]                                   │
  15 - [Fe│                                                                                                                      │
  16 - [Sc│ Contents                                                                                                             │
  17 - [In│ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────── │
  18 - [Qu│                                                                                                                      │
  19 - [De│ • Features                                                                                                           │
  20 - [Co│ • Screenshots                                                                                                        │
  21      │ • Installation                                                                                                       │
  22 ## Fe│ • Quickstart                                                                                                         │
  23      │ • Dependencies                                                                                                       │
  24 - **E│ • Configuration                                                                                                      │
  25   gro│                                                                                                                      │
  26   wor│ Features                                                                                                             │
  27 - **S│ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────── │
  28   inj│                                                                                                                      │
  29 - **L│ • Editing: Unicode/grapheme-aware cursor, soft wrap, multiple buffers, grouped undo/redo, auto-indent, auto-close    │
  30   ren│   pairs, block indent, comment toggle, word/paragraph motion with held-key acceleration.                             │
  31 - **G│ • Syntax highlighting: tree-sitter for 20 languages, theme-driven, with injection (code blocks in Markdown, <script> │
  32   ahe│   /<style> in HTML).                                                                                                 │
  33 - **N│ • Language servers: diagnostics, go-to-definition, hover, workspace-wide rename, as-you-type completion, document    │
  34   pro│   formatting.                                                                                                        │
  35   (`C│ • Git: diff gutter, inline diff view, per-file diff preview, branch and ahead/behind in the status bar,              │
  36 - **E│   merge-conflict highlighting and resolve.                                                                           │
  37   wit│ • Navigation: file tree (open/copy/rename/delete/search), fuzzy line jump, project search (ripgrep), find/replace    │
  38 - **A├──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  39   inl│ ↑↓ PgUp PgDn scroll  click a link to open it  Alt+, back  Alt+. forward  Esc close                                   │
  40 - **M└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
  41   anchors, with Back/Forward.
  42 - **Lua plugins:** bundled features (file tree, git, search, format, AI) are
  43   plugins; add your own commands, panes and hooks in `~/.config/qed/plugins/`.
 ≡ root/README.md  1/184  [2/2]                                                                                      ◆ markdown  ⇥ Spaces:2

-- style
abbbbcdeeedddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
aaaaafffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
aaaaafffffffffffffffffffffffffffffffffffggggffgggggggggggggggggggggfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
aaaaafgggghhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhffffffffff
aaaaaiiiiihjjjjjjjjjjkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaafffffhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhffffffffff
aaaaafffffhklllkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkffffffffff
aaaaafffffhkjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjkkffffffffff
aaaaafmfmmhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkffffffffff
aaaaafffmmhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkknnnnkkkkkkkkkkkkkknnnnnkkkkkkkkkkkkkkkkkkkkkkkooooookkkkkkkooooookooooookkkkkkkkkkkkffffffffff
aaaaaffmffhkkkkkkkkkkkkkooooookkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkffffffffff
aaaaafffffhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfpphkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaafffffhkqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfgghkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfgghkllllllllkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfgghkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaammfgghkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfgghkjqnnnnnnnnkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfgghkjqnnnnnnnnnnnkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaafffffhkjqnnnnnnnnnnnnkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfpphkjqnnnnnnnnnnkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaafffffhkjqnnnnnnnnnnnnkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhkjqnnnnnnnnnnnnnkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfffhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfffhkllllllllkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaammfffhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhkjqsssssssskkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfffhkqqkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhkjqsssssssssssssssssssskkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkooooooookhffffffffff
aaaaammfffhkqqkoooooookkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhkjqssssssssssssssssskkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfffhkqqkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfiihkjqsssskkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhkqqkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammfffhkjqssssssssssskkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhffffffffff
aaaaammfffhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaammrrrhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhffffffffff
aaaaammfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
aaaaammrrrrrrrrrrrrrrrrfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
aaaaammfffffffffffffffffffffffffffffffffffffffffffffffffffiiiiiiiiiiiiiiiiiiiiiiiiffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk
tttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt
-- legend
a fg=#464646 bg=#1b1b1b
b fg=#676767 bg=#1b1b1b
c fg=#7d6f2b bg=#262626
d fg=#78787d bg=#262626
e fg=#7d6f2b bg=#262626 bold
f fg=#707074 bg=#181818
g fg=#4a515e bg=#181818
h fg=#868686 bg=#2b2b2b
i fg=#4a524e bg=#181818
j fg=#ffdd33 bg=#2b2b2b
k fg=#f4f4ff bg=#2b2b2b
l fg=#ffdd33 bg=#2b2b2b bold
m fg=#746723 bg=#181818
n fg=#96a6c8 bg=#2b2b2b underline
o fg=#95a99f bg=#363636
p fg=#746723 bg=#181818 bold
q fg=- bg=#2b2b2b
r fg=#707074 bg=#181818 bold
s fg=#f4f4ff bg=#2b2b2b bold
t fg=#f4f4ff bg=#181818
