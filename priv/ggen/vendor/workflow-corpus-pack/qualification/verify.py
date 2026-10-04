#!/usr/bin/env python3
"""Deterministic violation-row qualification runner for workflow-corpus-pack.

Lane-scoped (lane 8, v26.9.30 wave): this runner executes only the gates this
lane owns -- shared ``f000_*`` and per-fixture ``f01_..f04_`` -- because lanes
9/10 author gates ``f05_*..f12_*`` concurrently in the same gates/ directory
and their anti-vacuity corpus is theirs. The full-corpus sweep over all twelve
fixtures and every gate is the consumer/integration court's run.

Executed courts, in order:

1. positive corpus      -- qualification/fixtures/positive.ttl over ALL owned
                           gates: every gate must return 0 rows.
2. real fixture corpus  -- fixtures/01-*/..04-*/fixture.ttl unioned with
                           ontology.ttl over ALL owned gates: the shipped
                           corpus itself must be well-formed.
3. witness pass         -- witnesses/pass/<stem>.ttl over its stem gate:
                           0 rows.
4. witness fail         -- witnesses/fail/<stem>.ttl over its stem gate:
                           >= 1 row (anti-vacuity: every gate has a witnessed
                           firing; a gate with no witnessed refusal carries no
                           bits).
5. negative corpus      -- qualification/fixtures/negative-*.ttl over the gate
                           named in NEGATIVE_EXPECTATIONS: >= 1 row.
"""
from __future__ import annotations

from pathlib import Path
import sys

try:
    from rdflib import Graph
except ImportError as exc:  # pragma: no cover
    raise SystemExit("REFUSED:VERIFIER_UNAVAILABLE:rdflib") from exc

ROOT = Path(__file__).resolve().parents[1]
GATES = ROOT / "gates"
WITNESS_PASS = ROOT / "witnesses" / "pass"
WITNESS_FAIL = ROOT / "witnesses" / "fail"
QUALIFICATION_FIXTURES = Path(__file__).resolve().parent / "fixtures"
FIXTURES = ROOT / "fixtures"

OWNED_GATE_PREFIXES = ("f000_", "f01_", "f02_", "f03_", "f04_")
OWNED_FIXTURE_NUMBERS = ("01", "02", "03", "04")

NEGATIVE_EXPECTATIONS = {
    "negative-missing-goal.ttl": {"f000_fixture_missing_goal.rq"},
    "negative-no-capability-closure.ttl": {"f000_fixture_missing_capability_closure.rq"},
    "negative-missing-expected-outcome.ttl": {"f000_fixture_missing_expected_outcome.rq"},
    "negative-no-falsifier.ttl": {"f000_fixture_missing_falsifier.rq"},
    "negative-missing-authority.ttl": {"f000_consequential_task_without_required_authority.rq"},
    "negative-forbidden-conflict.ttl": {"f000_forbidden_plus_expected_realization_conflict.rq"},
}


def owned_gates() -> list[Path]:
    gates = [
        gate
        for gate in sorted(GATES.glob("*.rq"))
        if gate.name.startswith(OWNED_GATE_PREFIXES)
    ]
    if not gates:
        raise SystemExit("REFUSED:NO_OWNED_GATES")
    return gates


def base_graph() -> Graph:
    graph = Graph()
    graph.parse(ROOT / "ontology.ttl", format="turtle")
    return graph


def evaluate(gate_paths: list[Path], extra_files: list[Path]) -> dict[str, int]:
    graph = base_graph()
    for path in extra_files:
        graph.parse(path, format="turtle")
    results: dict[str, int] = {}
    for gate in gate_paths:
        rows = graph.query(gate.read_text(encoding="utf-8"))
        results[gate.name] = len(list(rows))
    return results


def main() -> int:
    gates = owned_gates()
    gate_names = {gate.name for gate in gates}
    gate_by_name = {gate.name: gate for gate in gates}
    failures: list[str] = []

    # 1. positive corpus: fully-conforming fixture fires nothing.
    positive = evaluate(gates, [QUALIFICATION_FIXTURES / "positive.ttl"])
    if any(positive.values()):
        failures.append(f"positive:{positive}")

    # 2. real fixture corpus: fixtures 01-04 are well-formed.
    real_fixtures = sorted(
        FIXTURES.glob("[0][1-4]-*/fixture.ttl"),
        key=lambda path: path.parent.name,
    )
    found_numbers = sorted(path.parent.name[:2] for path in real_fixtures)
    if found_numbers != list(OWNED_FIXTURE_NUMBERS):
        failures.append(f"real-corpus:expected 01-04 got {found_numbers}")
    real = evaluate(gates, real_fixtures)
    if any(real.values()):
        failures.append(f"real-fixtures-01-04:{real}")

    # 3/4. witness court: each owned gate has a pass witness (0 rows) and a
    # fail witness (>= 1 row) at its exact stem.
    for gate in gates:
        pass_witness = WITNESS_PASS / (gate.stem + ".ttl")
        fail_witness = WITNESS_FAIL / (gate.stem + ".ttl")
        if not pass_witness.is_file():
            failures.append(f"{gate.name}:missing-pass-witness")
        else:
            rows = evaluate([gate], [pass_witness])[gate.name]
            if rows:
                failures.append(f"{gate.name}:pass-witness-fired:{rows}")
        if not fail_witness.is_file():
            failures.append(f"{gate.name}:missing-fail-witness")
        else:
            rows = evaluate([gate], [fail_witness])[gate.name]
            if rows < 1:
                failures.append(f"{gate.name}:fail-witness-vacuous:{rows}")

    # 5. negative corpus: each named negative fixture fires its named gate.
    for fixture_name, expected in sorted(NEGATIVE_EXPECTATIONS.items()):
        unknown = expected - gate_names
        if unknown:
            failures.append(f"{fixture_name}:unknown-gates:{sorted(unknown)}")
            continue
        result = evaluate([gate_by_name[name] for name in sorted(expected)],
                          [QUALIFICATION_FIXTURES / fixture_name])
        fired = {name for name, count in result.items() if count}
        missing = sorted(expected - fired)
        if missing:
            failures.append(f"{fixture_name}:missing={missing}:result={result}")

    if failures:
        print("REFUSED:WORKFLOW_CORPUS_COURT:" + "|".join(failures))
        return 1

    print(
        "ADMITTED:workflow-corpus semantic court "
        f"gates={len(gates)} real_fixtures={len(real_fixtures)} "
        f"negative_fixtures={len(NEGATIVE_EXPECTATIONS)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
