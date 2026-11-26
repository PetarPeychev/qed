qed-e2e snapshot 140x45 cursor hidden
-- text
   1 # qed
   2
   3 A terminal text editor written in [Odin](https://odin-lang.org), inspired by
   4 [micr┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
   5 `Ctrl│ README.md                                                                                                            │
   6 IDE-l├──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
   7 Runs │ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────── │
   8      │                                                                                                                      │
   9 <p al│ ┌─────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────┐ │
  10   <im│ │ [image: Welcome screen]                                 │ [image: Find and replace]                              │ │
  11 </p> │ │ Welcome screen: working root, git branch, startup       │ Find & replace: regex, smart-case, live match count,   │ │
  12      │ │ keys.                                                   │ all hits highlighted.                                  │ │
  13 ## Co│ ├─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────┤ ┃
  14      │ │ [image: LSP diagnostics]                                │ [image: Hover documentation]                           │ ┃
  15 - [Fe│ │ LSP diagnostics: inline underline, gutter severity,     │ Hover: rendered-markdown docs from the language        │ ┃
  16 - [Sc│ │ error popup.                                            │ server.                                                │ ┃
  17 - [In│ ├─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────┤ ┃
  18 - [Qu│ │ [image: Inline diff view]                               │ [image: Embedded terminal]                             │ │
  19 - [De│ │ Inline diff view: removed lines as ghost rows with      │ Embedded terminal: persistent full-TUI shell in a      │ │
  20 - [Co│ │ word-level highlight.                                   │ floating pane.                                         │ │
  21      │ ├─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────┤ │
  22 ## Fe│ │ [image: Theme picker]                                   │ [image: Light theme]                                   │ │
  23      │ │ Settings: Theme: instant-preview picker over the        │ Light theme (catppuccin-latte) with the theme picker   │ │
  24 - **E│ │ bundled themes.                                         │ open.                                                  │ │
  25   gro│ ├─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────┤ │
  26   wor│ │ [image: AI edit]                                        │ [image: Inline completion]                             │ │
  27 - **S│ │ AI edit: select a region, describe the change (Ctrl+K   │ Inline completion: dimmed FIM ghost-text, accepted     │ │
  28   inj│ │ ).                                                      │ with Tab.                                              │ │
  29 - **L│ ├─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────┤ │
  30   ren│ │ [image: Inspect Tokens]                                 │ [image: Message log]                                   │ │
  31 - **G│ │ Inspect Tokens: live tree-sitter capture and color      │ Message Log: timestamped, level-filtered,              │ │
  32   ahe│ │ resolution.                                             │ cross-session.                                         │ │
  33 - **N│ └─────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────┘ │
  34   pro│                                                                                                                      │
  35   (`C│ Installation                                                                                                         │
  36 - **E│ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────── │
  37   wit│                                                                                                                      │
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
aaaaafffffhkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaafffffhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaaflfllhkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaafffllhkhmhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmhhhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaafflffhkhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmmmhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmhkhffffffffff
aaaaafffffhkhmnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmnnnnnnnnnnnnnnnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaallfoohkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkkffffffffff
aaaaafffffhkhmhhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmhhhhhhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmhkkffffffffff
aaaaallfgghkhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmmmmhkkffffffffff
aaaaallfgghkhmnnnnnnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkkffffffffff
aaaaallfgghkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkkffffffffff
aaaaallfgghkhmhhhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmhhhhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaallfgghkhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmmhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmmhkhffffffffff
aaaaallfgghkhmnnnnnnnnnnnnnnnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmnnnnnnnnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaafffffhkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaallfoohkhmhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaafffffhkhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmmmmhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmhkhffffffffff
aaaaallppphkhmnnnnnnnnnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaallfffhkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaallfffhkhmhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmhhhhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaallppphkhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnqqqqqqmmmhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmhkhffffffffff
aaaaallfffhkhmnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmnnnnnqqqnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaallppphkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaallfffhkhmhhhhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmhhhhhhhhhhhhhhhhhhhhmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaallppphkhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmmhmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnmmmmmmmmmmmmmmhkhffffffffff
aaaaallfffhkhmnnnnnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhmnnnnnnnnnnnnnnmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmhkhffffffffff
aaaaallppphkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaallfffhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaallfiihkrrrrrrrrrrrrkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaallppphkhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkhffffffffff
aaaaallfffhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaallppphhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhffffffffff
aaaaallfffhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkhffffffffff
aaaaallppphhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhffffffffff
aaaaallfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
aaaaallppppppppppppppppfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
aaaaallfffffffffffffffffffffffffffffffffffffffffffffffffffiiiiiiiiiiiiiiiiiiiiiiiiffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk
ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss
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
l fg=#746723 bg=#181818
m fg=- bg=#2b2b2b
n fg=#f4f4ff bg=#2b2b2b italic
o fg=#746723 bg=#181818 bold
p fg=#707074 bg=#181818 bold
q fg=#95a99f bg=#363636 italic
r fg=#ffdd33 bg=#2b2b2b bold
s fg=#f4f4ff bg=#181818
