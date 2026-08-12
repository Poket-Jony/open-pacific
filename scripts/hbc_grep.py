#!/usr/bin/env python3
"""Search a disassembled Hermes bundle by string content and locate the
functions that reference a string id.

Usage:
    hbc_grep.py <disasm_dir> strings <keyword> [keyword...]
    hbc_grep.py <disasm_dir> refs <string_id>
    hbc_grep.py <disasm_dir> func <line_number>
"""
import json, sys, re
from pathlib import Path


def load_strings(d):
    return {e["id"]: e["value"] for e in json.load(open(Path(d) / "string.json"))}


def cmd_strings(d, kws):
    strs = load_strings(d)
    kws = [k.lower() for k in kws]
    for sid, val in strs.items():
        if not isinstance(val, str):
            continue
        low = val.lower()
        if all(k in low for k in kws):
            v = val if len(val) < 90 else val[:90] + "…"
            print(f"{sid:6}  {v!r}")


def cmd_refs(d, sid):
    hasm = Path(d) / "instruction.hasm"
    pat = re.compile(rf"String\({sid}\)")
    cur = "?"
    with open(hasm) as f:
        for n, line in enumerate(f, 1):
            if line.startswith("Function<"):
                cur = line.strip()
            if pat.search(line):
                print(f"{n:>9}  {cur}")


def cmd_func(d, line):
    hasm = Path(d) / "instruction.hasm"
    lines = open(hasm).read().splitlines()
    # `refs` prints 1-based line numbers; convert to a 0-based index and clamp.
    i = max(0, min(int(line) - 1, len(lines) - 1))
    start = i
    while start > 0 and not lines[start].startswith("Function<"):
        start -= 1
    end = i
    while end < len(lines) and not lines[end].startswith("EndFunction"):
        end += 1
    print("\n".join(lines[start:end + 1]))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    d, cmd, *rest = sys.argv[1:]
    cmds = {"strings": lambda: cmd_strings(d, rest),
            "refs": lambda: cmd_refs(d, rest[0]),
            "func": lambda: cmd_func(d, rest[0])}
    if cmd not in cmds:
        sys.exit(__doc__)
    cmds[cmd]()
