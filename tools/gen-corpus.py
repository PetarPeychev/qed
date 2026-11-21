#!/usr/bin/env python3
# gen-corpus.py DIR [--force]: writes qed's perf stress corpus into DIR (see docs/notes/perf.md).
import os
import random
import shutil
import subprocess
import sys

VERSION = "2"


def write(path, data):
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())


def c_lines(n, rng):
    out = []
    i = 0
    while len(out) < n:
        out += [
            f"/* block {i}: helpers for the {i % 17}th table */",
            f"static int helper_{i}(struct state *s, const char *name, size_t len) {{",
            f"    if (s->count[{i % 64}] > {i} && strncmp(name, \"key_{i}\", len) == 0) {{",
            f"        return s->table[{i % 251}] + 0x{i:x};",
            "    }",
            f"    for (int k = 0; k < {rng.randint(1, 99)}; k++) s->acc += k * {i % 7};",
            "    // TODO: tighten the bound once the format settles",
            f"    return -{i % 3};",
            "}",
            "",
        ]
        i += 1
    return out[:n]


def py_lines(n, rng):
    out = []
    i = 0
    while len(out) < n:
        out += [
            f"class Handler{i}(Base):",
            f'    """Handles the {i}th kind of request."""',
            "",
            f"    def run(self, items: list[int], name: str = \"h{i}\") -> dict:",
            f"        total = sum(x * {i % 13} for x in items if x > {rng.randint(0, 50)})",
            f"        return {{'name': name, 'total': total, 'ok': total % 2 == 0}}  # {i}",
            "",
        ]
        i += 1
    return out[:n]


def js_lines(n, rng):
    out = []
    i = 0
    while len(out) < n:
        out += [
            f"export function render{i}(props, ctx) {{",
            f"  const items = props.items.filter((x) => x.id % {i % 9 + 1} === 0);",
            f"  const label = `item ${{props.name}} #{i}`;",
            f"  if (items.length > {rng.randint(1, 500)}) {{ ctx.warn('too many: ' + items.length); }}",
            f"  return items.map((x) => ({{ ...x, label, rank: {i} }}));",
            "}",
            "",
        ]
        i += 1
    return out[:n]


def odin_lines(n, rng):
    out = []
    i = 0
    while len(out) < n:
        out += [
            f"Thing_{i} :: struct {{",
            "\tname:  string,",
            f"\tvalue: [{i % 8 + 1}]int,",
            "}",
            "",
            f"thing_{i}_sum :: proc(t: ^Thing_{i}) -> (total: int) {{",
            "\tfor v in t.value {",
            f"\t\ttotal += v * {rng.randint(1, 99)}",
            "\t}",
            "\treturn",
            "}",
            "",
        ]
        i += 1
    return out[:n]


def md_lines(n, rng):
    out = []
    i = 0
    while len(out) < n:
        out += [
            f"## Section {i}",
            "",
            f"Some **bold** and *italic* text with `code {i}` and a [link](https://example.com/{i}).",
            f"A longer paragraph line that keeps going to exercise soft wrap in the markdown preview, item {i} of the corpus.",
            "",
            f"- bullet one {i}",
            "  - nested bullet",
            f"1. numbered {i}",
            "",
            "```python",
            f"def f{i}(x):",
            f"    return x * {i}",
            "```",
            "",
            "| col a | col b | col c |",
            "|-------|-------|-------|",
            f"| {i} | {i * 2} | {rng.randint(0, 999)} |",
            "",
            f"> quote {i}",
            "",
        ]
        i += 1
    return out[:n]


def lines_file(path, lines, nl="\n"):
    write(path, nl.join(lines) + nl)


def minified_js(size, rng):
    parts = []
    n = 0
    i = 0
    while n < size:
        s = (f"function a{i}(b,c){{var d=b+c*{i % 97};if(d>{rng.randint(1, 9999)})"
             f"{{return\"s{i}\"+d}}for(var e=0;e<{i % 13};e++){{d^=e<<2}}return d}};")
        parts.append(s)
        n += len(s)
        i += 1
    return "".join(parts)[:size] + "\n"


def json_long_line(rng):
    head = ["{", '  "name": "corpus",', '  "version": 1,']
    entries = []
    n = 0
    i = 0
    while n < 1 << 20:
        s = f'{{"id":{i},"k":"v{i}","n":{rng.randint(0, 99999)}}}'
        entries.append(s)
        n += len(s) + 1
        i += 1
    long = '  "blob": [' + ",".join(entries) + "],"
    tail = [f'  "k{i}": {{"a": {i}, "b": "text {i}"}},' for i in range(2000)]
    return "\n".join(head + tail[:1000] + [long] + tail[1000:] + ['  "end": true', "}"]) + "\n"


def odd_bytes(rng):
    pieces = [
        "plain ascii line\t\twith tabs\tand\ttrailing tab\t",
        "wide: 漢字かなカナ한국어 全角ＡＢＣ",
        "emoji: 😀👍🏽👨‍👩‍👧‍👦🇧🇬🏳️‍🌈 1️⃣ ❤️",
        "combining: é ǟ Z̵̡̛̰ ñ̃̃",
        "rtl: שלום עולם مرحبا بالعالم",
        "devanagari: नेपाली भाषामा अनुवाद गरिएको सन्देश क्षेत्र श्रीमान् ज्ञान क़ क्\u200dष क्\u200cष",
        "zero width: a​b‌c‍d﻿e",
        "control: \x01\x02\x07\x08\x0b\x0c\x1b[31mnot color\x1b[0m\x7f",
        "nul: before\x00after",
    ]
    out = bytearray()
    for i in range(20000):
        line = pieces[i % len(pieces)].encode()
        if i % 11 == 0:
            line += bytes(rng.randrange(0x80, 0x100) for _ in range(16))
        out += line + (b"\r\n" if i % 3 else b"\n")
    out += ("😀" * 50000).encode() + b"\r\n"
    out += ("é" * 50000).encode() + b"\r\n"
    out += ("\t" * 2000 + "x").encode() + b"\r\n"
    return bytes(out)


def conflicts(n):
    out = []
    for i in range(n):
        out += [f"local before_{i} = {i}", "<<<<<<< HEAD", f"local v{i} = {i}", "shared",
                "=======", f"local v{i} = {i} + 1", "shared", f">>>>>>> branch-{i % 7}", ""]
    return out


def git(repo, *args, **kw):
    subprocess.run(["git", "-C", repo, *args], check=True, stdout=subprocess.DEVNULL, **kw)


def repo_tree(root, files, changed):
    os.makedirs(root)
    per = 100
    for i in range(files):
        d = os.path.join(root, f"pkg{i // 10000:02d}", f"mod{i // per:04d}")
        if i % per == 0:
            os.makedirs(d, exist_ok=True)
        write(os.path.join(d, f"file{i:06d}.txt"), f"file {i}\nline two\n")
    write(os.path.join(root, "README.md"), "# corpus repo\n")
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.email", "corpus@example.invalid")
    git(root, "config", "user.name", "corpus")
    git(root, "config", "commit.gpgsign", "false")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "seed")
    for i in range(0, files, files // changed):
        d = os.path.join(root, f"pkg{i // 10000:02d}", f"mod{i // per:04d}")
        with open(os.path.join(d, f"file{i:06d}.txt"), "a") as f:
            f.write("changed\n")


def main():
    if len(sys.argv) < 2:
        print("usage: gen-corpus.py DIR [--force]", file=sys.stderr)
        sys.exit(2)
    out = os.path.abspath(sys.argv[1])
    stamp = os.path.join(out, ".corpus-version")
    if "--force" not in sys.argv and os.path.exists(stamp) and open(stamp).read() == VERSION:
        print(f"corpus up to date: {out}")
        return
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)
    rng = random.Random(42)
    N = 100_000
    lines_file(f"{out}/lines100k.c", c_lines(N, rng))
    lines_file(f"{out}/lines100k.py", py_lines(N, rng))
    lines_file(f"{out}/lines100k.js", js_lines(N, rng))
    lines_file(f"{out}/lines100k.odin", odin_lines(N, rng))
    mixed = []
    while sum(len(x) + 1 for x in mixed) < 10 << 20:
        mixed += c_lines(1000, rng) + js_lines(1000, rng) + py_lines(1000, rng)
    lines_file(f"{out}/mixed10mb.c", mixed)
    write(f"{out}/minified5mb.js", minified_js(5 << 20, rng))
    write(f"{out}/longline1mb.json", json_long_line(rng))
    write(f"{out}/odd.txt", odd_bytes(rng))
    lines_file(f"{out}/huge.md", md_lines(N, rng))
    lines_file(f"{out}/conflicts.lua", conflicts(2000))
    lines_file(f"{out}/lines1m.txt", [f"line {i} of a million" for i in range(1_000_000)])
    repo_tree(f"{out}/repo", 100_000, 50_000)
    write(stamp, VERSION)
    print(f"corpus written: {out}")


main()
