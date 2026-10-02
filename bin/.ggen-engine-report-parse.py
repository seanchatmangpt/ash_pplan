#!/usr/bin/env python3
"""Parse one engine-comparison JSON report (dep: GgenIgniter.EngineComparisonReport
to_json/1 shape) for engine disagreements.

Canonicalization: each cell is stringified before comparison because the two
engines return different value SHAPES for the same xsd:integer cell (oxigraph
"12" vs sparql 12) — a pure shape difference, not a semantic disagreement.
Raw-list equality inside the dep's report therefore already shows order_equal?
false on every numeric column; this parser restores the semantic signal:

  disagreement (BLOCKING, exit 1) iff any query has
    - a candidate whose status is not ok, or
    - row counts differing, or
    - canonical row SETS differing.

  Order-only divergence is a WARNING, not a block: the dep's own moduledoc
  (lib/ggen_igniter/query.ex) documents that the sparql hex engine reverses
  ORDER BY row order as a baseline bug, already neutralized downstream
  (templates re-sort with explicit Enum.sort_by tiebreaks, actuation runs on
  oxigraph only). tmp/adopt3-falsify/ proves this warning path fires on a
  crafted ORDER BY-sensitive ontology (row_set_equal true, order divergent).

Exit 0 agree (warnings allowed) / 1 disagree. The markdown report stays
untouched as the diffable artifact.
"""
import json
import sys


def canon_cell(v):
    if isinstance(v, bool):
        return str(v).lower()
    return str(v)


def canon_rows(rows):
    return [[(k, canon_cell(v)) for k, v in sorted(row.items())] for row in rows]


def parse(path):
    reports = json.load(open(path))
    if not isinstance(reports, list):
        reports = [reports]
    bad = 0
    warned = 0
    for rep in reports:
        cands = rep["candidates"]
        engines = [c["engine"] for c in cands]
        statuses = {c["engine"]: c["status"] for c in cands}
        base = engines[0]
        counts = {c["engine"]: c["row_count"] for c in cands}
        reasons = []
        warns = []
        if any(s != "ok" for s in statuses.values()):
            reasons.append(
                "status: " + ", ".join(f"{e}={s}" for e, s in statuses.items() if s != "ok")
            )
        if len(set(counts.values())) > 1:
            reasons.append("row_count: " + str(counts))
        if all(s == "ok" for s in statuses.values()):
            rows_by_engine = {
                e: canon_rows(next(c["rows"] for c in cands if c["engine"] == e))
                for e in engines
            }
            base_set = sorted(map(tuple, rows_by_engine[base]))
            if any(sorted(map(tuple, rows_by_engine[e])) != base_set for e in engines):
                reasons.append("row_set mismatch")
            elif any(rows_by_engine[e] != base_rows for e in engines
                     for base_rows in [rows_by_engine[base]]):
                warns.append("row_order divergent (known sparql-hex ORDER BY baseline, "
                             "see tmp/adopt3-falsify/)")
        if reasons:
            bad += 1
            print(f"  DISAGREE [{label(rep)}]: " + "; ".join(reasons))
        elif warns:
            warned += 1
            print(f"  warn     [{label(rep)}]: " + "; ".join(warns))
    print(f"  queries: {len(reports)}  blocking: {bad}  order-warnings: {warned}")
    return bad


def label(rep):
    q = rep["query"].strip().splitlines()
    return next((ln.strip() for ln in q if "SELECT" in ln.upper()), q[0] if q else "?")[:60]


if __name__ == "__main__":
    n = parse(sys.argv[1])
    sys.exit(1 if n else 0)
