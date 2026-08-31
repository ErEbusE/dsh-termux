#!/usr/bin/env python3
"""Check relative markdown links and heading anchors in this repository.

Docs used to be the one change class that triggered ~16 minutes of npm install
in CI and got nothing verified in return. This is the cheap check that matches
what a docs change can actually break: a link to a file that does not exist, or
an anchor that no longer matches any heading.

Usage:
    python3 .github/scripts/check-doc-links.py [FILE.md ...]

With no arguments it checks every tracked *.md file. Exits non-zero and prints
"file:line: reason" for each problem.

Deliberate limitations (keep it fast, offline and free of false positives):
  * external URLs (http/https) and mailto: are NOT fetched, only skipped;
  * reference-style links ([a][b] with a separate definition) are not resolved;
  * fenced code blocks and inline code spans are ignored, so documented
    examples never trip the checker.
"""

import os
import re
import subprocess
import sys

LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)>\s]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`]*`")
SKIP_SCHEME = ("http://", "https://", "mailto:", "tel:")


def repo_root():
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def tracked_markdown():
    out = subprocess.run(
        ["git", "ls-files", "*.md"], capture_output=True, text=True, check=True
    )
    return [p for p in out.stdout.split("\n") if p]


def slugify(text):
    """Approximate GitHub's heading -> anchor conversion.

    Lowercase, drop HTML tags and code ticks, drop punctuation, spaces to '-'.
    Python's word-character class is Unicode-aware, so CJK headings keep their
    characters -- which is what GitHub does for README.zh-CN.md.
    """
    t = re.sub(r"<[^>]+>", "", text)
    t = t.replace("`", "")
    t = t.strip().lower()
    t = re.sub(r"[^\w\s-]", "", t, flags=re.UNICODE)
    return re.sub(r"\s+", "-", t.strip())


def strip_code(lines):
    """Yield (lineno, text) with fenced blocks blanked and inline code removed."""
    in_fence = False
    for i, line in enumerate(lines, 1):
        if FENCE.match(line):
            in_fence = not in_fence
            yield i, ""
            continue
        yield i, ("" if in_fence else INLINE_CODE.sub("", line))


def anchors_of(path, cache):
    """The set of anchors GitHub would generate for a markdown file."""
    if path in cache:
        return cache[path]
    names = set()
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        cache[path] = names
        return names
    seen = {}
    for _, text in strip_code(lines):
        m = HEADING.match(text)
        if not m:
            continue
        base = slugify(m.group(2))
        if not base:
            continue
        n = seen.get(base, 0)
        seen[base] = n + 1
        names.add(base if n == 0 else "%s-%d" % (base, n))
    cache[path] = names
    return names


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__)
        return 0
    os.chdir(repo_root())
    files = argv or tracked_markdown()
    cache = {}
    problems = []
    checked = 0
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                lines = fh.read().split("\n")
        except OSError as exc:
            problems.append("%s: cannot read (%s)" % (f, exc))
            continue
        for lineno, text in strip_code(lines):
            for m in LINK.finditer(text):
                target = m.group(1)
                if target.startswith(SKIP_SCHEME):
                    continue
                checked += 1
                path, _, anchor = target.partition("#")
                where = "%s:%d" % (f, lineno)
                if path:
                    resolved = os.path.normpath(os.path.join(os.path.dirname(f), path))
                    if not os.path.exists(resolved):
                        problems.append(
                            "%s: link target does not exist: %s" % (where, target)
                        )
                        continue
                    doc = resolved if resolved.endswith(".md") else None
                else:
                    doc = f
                if anchor and doc:
                    if slugify(anchor) not in anchors_of(doc, cache):
                        problems.append(
                            "%s: no heading matches anchor '#%s' in %s"
                            % (where, anchor, doc)
                        )
    if problems:
        print("FAIL: %d broken markdown link(s)" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print(
        "OK: %d relative link(s)/anchor(s) resolve across %d markdown file(s)"
        % (checked, len(files))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
