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
cc -c -w -O2 -I "$TS/go" "$TS/go/parser.c" -o "$TS/go-parser.o"
cc -c -w -O2 -I "$TS/rust" "$TS/rust/parser.c" -o "$TS/rust-parser.o"
cc -c -w -O2 -I "$TS/rust" "$TS/rust/scanner.c" -o "$TS/rust-scanner.o"
cc -c -w -O2 -I "$TS/c" "$TS/c/parser.c" -o "$TS/c-parser.o"
cc -c -w -O2 -I "$TS/cpp" "$TS/cpp/parser.c" -o "$TS/cpp-parser.o"
cc -c -w -O2 -I "$TS/cpp" "$TS/cpp/scanner.c" -o "$TS/cpp-scanner.o"
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
cc -c -w -O2 -I "$TS/html" "$TS/html/parser.c" -o "$TS/html-parser.o"
cc -c -w -O2 -I "$TS/html" "$TS/html/scanner.c" -o "$TS/html-scanner.o"
cc -c -w -O2 -I "$TS/css" "$TS/css/parser.c" -o "$TS/css-parser.o"
cc -c -w -O2 -I "$TS/css" "$TS/css/scanner.c" -o "$TS/css-scanner.o"
cc -c -w -O2 -I "$TS/toml" "$TS/toml/parser.c" -o "$TS/toml-parser.o"
cc -c -w -O2 -I "$TS/toml" "$TS/toml/scanner.c" -o "$TS/toml-scanner.o"
cc -c -w -O2 -I "$TS/yaml" "$TS/yaml/parser.c" -o "$TS/yaml-parser.o"
cc -c -w -O2 -I "$TS/yaml" "$TS/yaml/scanner.c" -o "$TS/yaml-scanner.o"
cc -c -w -O2 -I "$TS/dockerfile" "$TS/dockerfile/parser.c" -o "$TS/dockerfile-parser.o"
cc -c -w -O2 -I "$TS/dockerfile" "$TS/dockerfile/scanner.c" -o "$TS/dockerfile-scanner.o"
ar rcs "$TS/libtreesitter.a" "$TS/runtime.o" \
   "$TS/odin-parser.o" "$TS/odin-scanner.o" \
   "$TS/json-parser.o" \
   "$TS/python-parser.o" "$TS/python-scanner.o" \
   "$TS/go-parser.o" \
   "$TS/rust-parser.o" "$TS/rust-scanner.o" \
   "$TS/c-parser.o" \
   "$TS/cpp-parser.o" "$TS/cpp-scanner.o" \
   "$TS/javascript-parser.o" "$TS/javascript-scanner.o" \
   "$TS/typescript-parser.o" "$TS/typescript-scanner.o" \
   "$TS/tsx-parser.o" "$TS/tsx-scanner.o" \
   "$TS/markdown-parser.o" "$TS/markdown-scanner.o" \
   "$TS/markdown_inline-parser.o" "$TS/markdown_inline-scanner.o" \
   "$TS/bash-parser.o" "$TS/bash-scanner.o" \
   "$TS/lua-parser.o" "$TS/lua-scanner.o" \
   "$TS/sql-parser.o" "$TS/sql-scanner.o" \
   "$TS/html-parser.o" "$TS/html-scanner.o" \
   "$TS/css-parser.o" "$TS/css-scanner.o" \
   "$TS/toml-parser.o" "$TS/toml-scanner.o" \
   "$TS/yaml-parser.o" "$TS/yaml-scanner.o" \
   "$TS/dockerfile-parser.o" "$TS/dockerfile-scanner.o"

# Build the vendored libvterm terminal emulator into a static lib
VT=lib/vterm
for f in "$VT"/src/*.c; do
   cc -c -w -O2 -I "$VT/include" -I "$VT/src" "$f" -o "${f%.c}.o"
done
ar rcs "$VT/libvterm.a" "$VT"/src/*.o

# Build the PTY shim (forkpty) into a static lib
cc -c -w -O2 lib/pty/pty.c -o lib/pty/pty.o
ar rcs lib/pty/libqedpty.a lib/pty/pty.o

# Build the vendored Lua 5.4 interpreter (no lua.c/luac.c) into a static lib
LUA=lib/lua
if [ ! -f "$LUA/liblua.a" ] || [ -n "$(find "$LUA/src" -newer "$LUA/liblua.a" -name '*.[ch]')" ]; then
   for f in "$LUA"/src/*.c; do
      cc -c -w -O2 -DLUA_USE_POSIX "$f" -o "${f%.c}.o"
   done
   rm -f "$LUA/liblua.a"
   ar rcs "$LUA/liblua.a" "$LUA"/src/*.o
fi

# Build the vendored cmark-gfm (markdown -> HTML) and litehtml (HTML layout) static libs
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
# Odin targets macOS 11 by default: the C/C++ objects must not ask for anything newer
MIN=""
if [ "$(uname)" = Darwin ]; then MIN="-mmacosx-version-min=11.0"; fi
CM=lib/cmark_gfm
if [ ! -f "$CM/libcmarkgfm.a" ] || [ -n "$(find "$CM" -newer "$CM/libcmarkgfm.a" -name '*.[ch]')" ]; then
   ls "$CM"/*.c | xargs -P "$JOBS" -n1 sh -c 'f=$1; cc -c -w -O2 '"$MIN"' -I '"$CM"' "$f" -o "${f%.c}.o"' _
   rm -f "$CM/libcmarkgfm.a"
   ar rcs "$CM/libcmarkgfm.a" "$CM"/*.o
fi
LH=lib/litehtml
if [ ! -f "$LH/liblitehtml.a" ] || [ -n "$(find "$LH" -newer "$LH/liblitehtml.a" \( -name '*.[ch]' -o -name '*.cpp' \))" ]; then
   { ls "$LH"/src/gumbo/src/*.c; ls "$LH"/src/*.cpp "$LH"/qlh.cpp; } | xargs -P "$JOBS" -n1 sh -c 'f=$1; case "$f" in
      *.c) cc -c -w -O2 '"$MIN"' -I '"$LH"'/src/gumbo/src "$f" -o "${f%.c}.o" ;;
      *) c++ -c -w -O2 '"$MIN"' -std=c++17 -I '"$LH"'/include -I '"$LH"'/include/litehtml -I '"$LH"'/src/gumbo/src "$f" -o "${f%.cpp}.o" ;;
   esac' _
   rm -f "$LH/liblitehtml.a"
   ar rcs "$LH/liblitehtml.a" "$LH"/src/gumbo/src/*.o "$LH"/src/*.o "$LH"/qlh.o
fi

# Link the C++ runtime statically where the toolchain ships it, so the binary needs no libstdc++ at run time
STATIC_CXX=""
if [ "$(uname)" != Darwin ]; then
   CXXLIB="$(c++ -print-file-name=libstdc++.a)"
   if [ -f "$CXXLIB" ]; then
      cmp -s "$CXXLIB" "$LH/libstdcxx.a" || cp "$CXXLIB" "$LH/libstdcxx.a"
      STATIC_CXX="-define:QED_STATIC_CXX=true"
   else
      echo "build.sh: no static libstdc++ (install libstdc++-dev); linking it dynamically" >&2
   fi
fi

# Build the editor, exposing vendor/ as a collection
odin build src -collection:lib=lib -o:speed $STATIC_CXX -define:QED_VERSION="${QED_VERSION:-dev}" -out:qed
