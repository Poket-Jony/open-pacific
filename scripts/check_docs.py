#!/usr/bin/env python3
"""Check the documentation and the repo's text hygiene.

Three classes of rot that no other check catches, all of which happened here:

* a relative link to a file that was renamed or deleted,
* a `#section` anchor that no longer matches any heading (silent on GitHub — the
  link just lands at the top of the page),
* trailing whitespace or a missing final newline, i.e. .editorconfig violations.

Run from anywhere; paths resolve against the repo root.

Usage: check_docs.py            # check everything, non-zero exit on any finding
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# .editorconfig sets trim_trailing_whitespace=false for *.md (trailing spaces are a
# markdown line break), so whitespace is only enforced for the rest.
WS_SUFFIXES = {".sh", ".py", ".yml", ".yaml"}
TEXT_SUFFIXES = WS_SUFFIXES | {".md"}
SKIP_DIRS = {".git", "work", "tools", "downloads", "__pycache__", ".venv", "venv"}


def repo_files():
    for p in sorted(ROOT.rglob("*")):
        if not p.is_file() or p.suffix not in TEXT_SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        yield p


def anchors(path):
    """GitHub's slug for every heading in a markdown file."""
    out = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^#+\s+(.*)", line)
        if m:
            slug = re.sub(r"[^\w\s-]", "", m.group(1).lower()).strip().replace(" ", "-")
            out.add(slug)
    return out


def check_links(files, findings):
    for p in files:
        if p.suffix != ".md":
            continue
        for m in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", p.read_text(encoding="utf-8")):
            url = m.group(1)
            if url.startswith(("http://", "https://", "mailto:")):
                continue
            rel, _, frag = url.partition("#")
            target = (p.parent / rel).resolve() if rel else p.resolve()
            if rel and not target.exists():
                findings.append("dead link   %s -> %s" % (p.relative_to(ROOT), url))
                continue
            if frag and target.suffix == ".md" and frag not in anchors(target):
                findings.append("dead anchor %s -> %s" % (p.relative_to(ROOT), url))


def check_whitespace(files, findings):
    for p in files:
        raw = p.read_bytes()
        if raw and not raw.endswith(b"\n"):
            findings.append("no final newline  %s" % p.relative_to(ROOT))
        if p.suffix not in WS_SUFFIXES:
            continue
        for n, line in enumerate(raw.decode("utf-8").splitlines(), 1):
            if line != line.rstrip():
                findings.append("trailing space    %s:%d" % (p.relative_to(ROOT), n))


def main():
    files = list(repo_files())
    findings = []
    check_links(files, findings)
    check_whitespace(files, findings)
    for f in findings:
        print(f)
    print("checked %d files: %d finding(s)" % (len(files), len(findings)))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
