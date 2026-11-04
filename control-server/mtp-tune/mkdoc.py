#!/usr/bin/env python3
"""Build the clean text corpus the measurements should have used from the start.

Why: `harness.build_doc` put `strata`'s own engine executable first in its file list and
read it in text mode, so `doc.json`'s doc_160000 / doc_32000 are mostly ELF bytes (38.8%
printable) with long periodic runs. Real repository text tokenizes at ~3.6 chars/token
against that fixture's ~1.1, and the periodic runs are what a lookup/suffix draft matches,
so every decode number measured on it carries that caveat.

This writes:
  corpus.txt              - ~4.4M chars of the repository's own text, no repeats, no binary
  doc.json["clean_155k"]  - corpus[0:DOC_CHARS]                    (the long-document fixture)
  prefill-pool.txt        - corpus[POOL_START:]                    (disjoint from the fixture)

usage: python3 mkdoc.py
"""
import glob
import json
import os
from pathlib import Path

MTP = Path("/home/kareem/Documents/strata-start-stop-server/mtp-tune")
ROOT = "/home/kareem/Documents/Strata-v02x"
DOC_CHARS = 558_000          # ~155k tokens at 3.6 chars/token
POOL_START = 700_000         # leave the fixture's text out of the pool
POOL_MIN = 3_000_000
GROUPS = ["docs/*.md", "docs/**/*.md", "*.md", "src/*.py", "src/**/*.cpp", "src/**/*.h",
          "include/**/*.h", "serve/*.py", "serve/**/*.py", "tools/*.py", "tools/**/*.py",
          "tests/**/*.py", "metal/*.h", "metal/*.cpp", "metal/*.mm", "sycl/**/*.hpp",
          "apps/host/**/*.js", "apps/host/**/*.html", "apps/desktop/src/**/*.ts",
          "packaging/*.md", "packaging/**/*.py"]


def readable(path):
    if os.path.getsize(path) > 2_000_000:
        return None
    try:
        t = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return None
    head = t[:4096]
    if not head or sum(1 for c in head if c.isprintable() or c in "\n\t") / len(head) < 0.95:
        return None
    return t


def main():
    parts, total, files, skipped = [], 0, 0, 0
    for g in GROUPS:
        for f in sorted(glob.glob(os.path.join(ROOT, g), recursive=True)):
            if "/node_modules/" in f or "/third_party/" in f or not os.path.isfile(f):
                continue
            t = readable(f)
            if t is None:
                skipped += 1
                continue
            parts.append(f"## {os.path.relpath(f, ROOT)}\n\n{t}")
            total += len(t)
            files += 1
    corpus = "\n\n".join(parts)
    need = POOL_START + POOL_MIN
    print(f"{files} files kept, {skipped} skipped, {len(corpus)} chars (need {need})")
    if len(corpus) < need:
        raise SystemExit("not enough repository text - widen GROUPS or lower POOL_MIN")
    (MTP / "corpus.txt").write_text(corpus)
    d = json.load(open(MTP / "doc.json"))
    d["clean_155k"] = corpus[:DOC_CHARS]
    json.dump(d, open(MTP / "doc.json", "w"))
    (MTP / "prefill-pool.txt").write_text(corpus[POOL_START:])
    print(f"doc.json clean_155k: {DOC_CHARS} chars; pool: {len(corpus) - POOL_START} chars")


if __name__ == "__main__":
    main()
