#!/bin/sh

set -e

# Build the vendored static lib (matches the host platform)
cc -c -w -O2 -D_XOPEN_SOURCE -D_DEFAULT_SOURCE -DTB_OPT_ATTR_W=64 \
   lib/tb2/termbox2_impl.c -o lib/tb2/termbox2_impl.o
ar rcs lib/tb2/libtermbox2.a lib/tb2/termbox2_impl.o

# Build the editor, exposing vendor/ as a collection
odin build src -collection:lib=lib -out:qed
