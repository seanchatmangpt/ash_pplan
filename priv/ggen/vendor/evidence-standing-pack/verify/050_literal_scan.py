#!/usr/bin/env python3
"""Literal-scan gate: templates/ must be ontology-driven, carrying no domain literals.

Usage: 050_literal_scan.py [pack_dir]   (default: the pack this file lives in)
Exit 0 ALIVE; exit 2 REFUSED[BANNED_LITERAL] naming every file:line:literal.
"""
import pathlib
import re
import sys

BANNED = (
    "zcode", "xaas", "ggen", "autofde", "ex4pm", "wasm4pm", "affidavit",
    "otel-weaver", "praxis", "turbo-fieldfare", "gdmcp", "chatman",
)


# The pack's own ontology namespace IRI is the one lawful occurrence: it is the
# key templates use to query individuals, not a domain literal.
NAMESPACE = "https://ggen.dev/ontology/evidence-standing#"


def scan(pack_dir: pathlib.Path) -> list[str]:
    hits: list[str] = []
    pattern = re.compile("|".join(re.escape(b) for b in BANNED), re.IGNORECASE)
    for path in sorted((pack_dir / "templates").rglob("*")):
        if not path.is_file():
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
            for match in pattern.finditer(line.replace(NAMESPACE, "")):
                hits.append(f"{path.name}:{number}:{match.group(0).lower()}")
    return hits


def main(argv: list[str]) -> int:
    pack_dir = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
    hits = scan(pack_dir)
    if hits:
        print("REFUSED[BANNED_LITERAL]: " + "; ".join(hits))
        return 2
    print("ALIVE: no banned domain literals in templates/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
