# Third-Party Licenses

qed ships as a single statically linked binary that embeds the vendored
components listed below. Their copyright notices and license terms are
reproduced here as those licenses require. qed's own source is under the MIT
License (see `LICENSE`).

## Components

| Component | Upstream | Version / pin | License |
|-----------|----------|---------------|---------|
| termbox2 | github.com/termbox/termbox2 | vendored, patched (`lib/tb2/PATCHES.md`) | MIT |
| libvterm | www.leonerd.org.uk/code/libvterm | vendored, patched (`lib/vterm/PATCHES.md`) | MIT |
| tree-sitter (runtime) | github.com/tree-sitter/tree-sitter | v0.26.10 | MIT |
| tree-sitter-odin | github.com/tree-sitter-grammars/tree-sitter-odin | v1.3.0 | MIT |
| tree-sitter-json | github.com/tree-sitter/tree-sitter-json | v0.24.8 | MIT |
| tree-sitter-python | github.com/tree-sitter/tree-sitter-python | v0.25.0 | MIT |
| tree-sitter-c | github.com/tree-sitter/tree-sitter-c | v0.24.1 | MIT |
| tree-sitter-javascript | github.com/tree-sitter/tree-sitter-javascript | v0.25.0 | MIT |
| tree-sitter-typescript (typescript + tsx) | github.com/tree-sitter/tree-sitter-typescript | v0.23.2 | MIT |
| tree-sitter-markdown (block + inline) | github.com/tree-sitter-grammars/tree-sitter-markdown | v0.5.3 | MIT |
| tree-sitter-bash | github.com/tree-sitter/tree-sitter-bash | v0.25.0 | MIT |
| tree-sitter-lua | github.com/tree-sitter-grammars/tree-sitter-lua | v0.5.0 | MIT |
| tree-sitter-sql | github.com/DerekStride/tree-sitter-sql | v0.3.11 | MIT |
| Unicode character data (bundled inside the tree-sitter runtime) | ICU / Unicode, Inc. | ICU 58+ | Unicode-DFS |

## MIT License

Every MIT component above is covered by the following terms. Copyright is held
by the respective upstream authors of each project:

- termbox2 — Copyright (c) 2015-2026 Adam Saponara <as@php.net>
- libvterm — Copyright (c) 2008 Paul Evans <leonerd@leonerd.org.uk>
- tree-sitter and the `tree-sitter/*` grammars (json, python, c, javascript,
  typescript, bash) — Copyright (c) 2018 Max Brunsfeld and the tree-sitter authors
- the `tree-sitter-grammars/*` grammars (odin, lua, markdown) — Copyright (c) the
  tree-sitter-grammars authors
- tree-sitter-sql — Copyright (c) Derek Stride and contributors

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Unicode / ICU Character Data

The vendored tree-sitter runtime includes Unicode character-property tables
derived from ICU, under the Unicode data license (ICU 58 and later):

```
COPYRIGHT AND PERMISSION NOTICE (ICU 58 and later)

Copyright © 1991-2019 Unicode, Inc. All rights reserved.
Distributed under the Terms of Use in https://www.unicode.org/copyright.html.

Permission is hereby granted, free of charge, to any person obtaining
a copy of the Unicode data files and any associated documentation
(the "Data Files") or Unicode software and any associated documentation
(the "Software") to deal in the Data Files or Software
without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, and/or sell copies of
the Data Files or Software, and to permit persons to whom the Data Files
or Software are furnished to do so, provided that either
(a) this copyright and permission notice appear with all copies
of the Data Files or Software, or
(b) this copyright and permission notice appear in associated
Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT OF THIRD PARTY RIGHTS.
IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS
NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL
DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder
shall not be used in advertising or otherwise to promote the sale,
use or other dealings in these Data Files or Software without prior
written authorization of the copyright holder.
```

The complete notice — including ICU's own bundled third-party data licenses — is
retained verbatim in the source tree at
`lib/tree_sitter/runtime/src/unicode/LICENSE`.
