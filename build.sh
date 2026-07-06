#!/bin/sh

set -e

# Build the vendored static lib (matches the host platform)
cc -c -w -O2 -D_XOPEN_SOURCE -D_DEFAULT_SOURCE -DTB_OPT_ATTR_W=64 -DTB_OPT_EGC \
   lib/tb2/termbox2_impl.c -o lib/tb2/termbox2_impl.o
ar rcs lib/tb2/libtermbox2.a lib/tb2/termbox2_impl.o

# Build the vendored tree-sitter runtime + Odin grammar into one static lib
TS=lib/tree_sitter
cc -c -w -O2 -I "$TS/runtime/include" -I "$TS/runtime/src" "$TS/runtime/src/lib.c" -o "$TS/runtime.o"
cc -c -w -O2 -I "$TS/odin" "$TS/odin/parser.c" -o "$TS/odin-parser.o"
cc -c -w -O2 -I "$TS/odin" "$TS/odin/scanner.c" -o "$TS/odin-scanner.o"
cc -c -w -O2 -I "$TS/json" "$TS/json/parser.c" -o "$TS/json-parser.o"
cc -c -w -O2 -I "$TS/python" "$TS/python/parser.c" -o "$TS/python-parser.o"
cc -c -w -O2 -I "$TS/python" "$TS/python/scanner.c" -o "$TS/python-scanner.o"
cc -c -w -O2 -I "$TS/c" "$TS/c/parser.c" -o "$TS/c-parser.o"
cc -c -w -O2 -I "$TS/javascript" "$TS/javascript/parser.c" -o "$TS/javascript-parser.o"
cc -c -w -O2 -I "$TS/javascript" "$TS/javascript/scanner.c" -o "$TS/javascript-scanner.o"
cc -c -w -O2 -I "$TS/typescript" "$TS/typescript/parser.c" -o "$TS/typescript-parser.o"
cc -c -w -O2 -I "$TS/typescript" "$TS/typescript/scanner.c" -o "$TS/typescript-scanner.o"
cc -c -w -O2 -I "$TS/tsx" "$TS/tsx/parser.c" -o "$TS/tsx-parser.o"
cc -c -w -O2 -I "$TS/tsx" "$TS/tsx/scanner.c" -o "$TS/tsx-scanner.o"
cc -c -w -O2 -I "$TS/markdown" "$TS/markdown/parser.c" -o "$TS/markdown-parser.o"
cc -c -w -O2 -I "$TS/markdown" "$TS/markdown/scanner.c" -o "$TS/markdown-scanner.o"
cc -c -w -O2 -I "$TS/markdown_inline" "$TS/markdown_inline/parser.c" -o "$TS/markdown_inline-parser.o"
cc -c -w -O2 -I "$TS/markdown_inline" "$TS/markdown_inline/scanner.c" -o "$TS/markdown_inline-scanner.o"
cc -c -w -O2 -I "$TS/bash" "$TS/bash/parser.c" -o "$TS/bash-parser.o"
cc -c -w -O2 -I "$TS/bash" "$TS/bash/scanner.c" -o "$TS/bash-scanner.o"
cc -c -w -O2 -I "$TS/lua" "$TS/lua/parser.c" -o "$TS/lua-parser.o"
cc -c -w -O2 -I "$TS/lua" "$TS/lua/scanner.c" -o "$TS/lua-scanner.o"
cc -c -w -O2 -I "$TS/sql" "$TS/sql/parser.c" -o "$TS/sql-parser.o"
cc -c -w -O2 -I "$TS/sql" "$TS/sql/scanner.c" -o "$TS/sql-scanner.o"
ar rcs "$TS/libtreesitter.a" "$TS/runtime.o" \
   "$TS/odin-parser.o" "$TS/odin-scanner.o" \
   "$TS/json-parser.o" \
   "$TS/python-parser.o" "$TS/python-scanner.o" \
   "$TS/c-parser.o" \
   "$TS/javascript-parser.o" "$TS/javascript-scanner.o" \
   "$TS/typescript-parser.o" "$TS/typescript-scanner.o" \
   "$TS/tsx-parser.o" "$TS/tsx-scanner.o" \
   "$TS/markdown-parser.o" "$TS/markdown-scanner.o" \
   "$TS/markdown_inline-parser.o" "$TS/markdown_inline-scanner.o" \
   "$TS/bash-parser.o" "$TS/bash-scanner.o" \
   "$TS/lua-parser.o" "$TS/lua-scanner.o" \
   "$TS/sql-parser.o" "$TS/sql-scanner.o"

# Build the vendored libvterm terminal emulator into a static lib
VT=lib/vterm
for f in "$VT"/src/*.c; do
   cc -c -w -O2 -I "$VT/include" -I "$VT/src" "$f" -o "${f%.c}.o"
done
ar rcs "$VT/libvterm.a" "$VT"/src/*.o

# Build the PTY shim (forkpty) into a static lib
cc -c -w -O2 lib/pty/pty.c -o lib/pty/pty.o
ar rcs lib/pty/libqedpty.a lib/pty/pty.o

# Build the editor, exposing vendor/ as a collection
odin build src -collection:lib=lib -out:qed
