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
ar rcs "$TS/libtreesitter.a" "$TS/runtime.o" \
   "$TS/odin-parser.o" "$TS/odin-scanner.o" \
   "$TS/json-parser.o" \
   "$TS/python-parser.o" "$TS/python-scanner.o"

# Build the editor, exposing vendor/ as a collection
odin build src -collection:lib=lib -out:qed
