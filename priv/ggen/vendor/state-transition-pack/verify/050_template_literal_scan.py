#!/usr/bin/env python3
"""Refuse banned domain literals in this pack's templates/.

Templates must be driven by ontology individuals only; a repo, product or
tool name inside a template means a consumer's domain leaked into shared
projection code. Exit 0 = clean, exit 1 = REFUSED with one JSON line per hit.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

BANNED = ("zcode", "xaas", "ggen", "autofde", "ex4pm", "wasm4pm", "affidavit", "praxis", "turbo-fieldfare")
# The ggen runtime's own freeze-slot directory key is required frontmatter
# syntax, not domain vocabulary, so only that exact key is exempt.
NAMESPACE = "https://ggen.dev/ontology/state-transition#"  # the pack's own vocabulary IRI
ALLOWED_LINES = (re.compile(r"^freeze_slots_dir: \.ggen/freeze/[a-z0-9-]+$"),)


def scan(templates: Path) -> list[dict[str, object]]:
    hits: list[dict[str, object]] = []
    for path in sorted(templates.rglob("*")):
        if not path.is_file():
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if any(rx.match(line) for rx in ALLOWED_LINES):
                continue
            low = line.replace(NAMESPACE, "").lower()
            for word in BANNED:
                if word in low:
                    hits.append({"file": path.name, "line": number, "literal": word})
    return hits


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "templates"
    hits = scan(root)
    for hit in hits:
        print(json.dumps(hit))
    if hits:
        print(json.dumps({"standing": "REFUSED", "reason": "banned domain literal in templates"}))
        return 1
    print(json.dumps({"standing": "ALIVE", "templates_scanned": len(list(root.rglob("*")))}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
