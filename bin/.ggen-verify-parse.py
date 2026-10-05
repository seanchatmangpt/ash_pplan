#!/usr/bin/env python3
"""Strict, fail-CLOSED parser for the `mix ggen_igniter.verify --json-envelope`
output (uniform envelope: {ok, exit_code, data, refusal, ...}).

Replaces the previous fail-open extraction (`grep '^{"' | tail -n 1` + tolerant
`env.get(...)` field access): any schema drift -- non-JSON stdout (compile noise
or a changed envelope shape), missing/renamed top-level or data keys, wrong
types -- is a TYPED ERROR with a nonzero exit, never a silent fallback.

Envelope contract (validated, not assumed):
  ok           bool
  exit_code    int
  data         object with:
    verify.status        "pass" | "fail"   (unknown value -> drift)
    verify.findings      list of {gate, subject, missing_property}
    gates.status         "pass" | "gate_failed" | "gate_cardinality"
                         (unknown value -> drift)
    gates.passed         list of str (required when verify.status/gates.status
                         == "pass"; optional on fail-shaped envelopes)
    cardinality.gates_under_contract  list of str

Usage:
  python3 bin/.ggen-verify-parse.py <envelope.json> <PASS|FAIL> [<pack>]

Exit 0 envelope parsed and detail printed
     2 schema drift / unreadable envelope (typed error on stderr)
"""
import json
import re
import sys
from typing import Any


class Drift(Exception):
    pass


# DRIFT-reason strings (typed, citable in stderr lines). See report 2026-10-04:
# the engine's FAIL envelopes omit data.gates.passed (it is only emitted on a
# passing run), so the unconditional `passed` requirement below classifies a
# LEGITIMATE offender-style gate failure as DRIFT. Wiring this constant into
# the `passed` check is now conditional (fixed 2026-10-04, consumer-side).
DRIFT_REASON_GATE_FAIL_OMITS_PASSED = (
    "data.gates: missing key 'passed' "
    "(engine emits gates.passed only on a passing run; a gate-failed envelope "
    "legitimately omits it -- this is a FAIL, not schema drift)"
)


# Known-BENIGN mix stdout prefixes (cold build), enumerated explicitly. Any
# OTHER non-JSON content is drift, not noise.
_MIX_NOISE = (
    re.compile(r"^==> [A-Za-z0-9_.-]+( \(.*\))?$"),
    re.compile(r"^Compiling \d+ file"),
    re.compile(r"^Generated \S+ app$"),
    re.compile(r"^Waiting for lock on the build directory"),
)


def strict_json_loads(raw, what):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Drift("%s is not valid UTF-8: %s" % (what, exc))
    lines = text.splitlines(keepends=True)
    kept = [ln for ln in lines if not any(p.match(ln.rstrip("\n")) for p in _MIX_NOISE)]
    stripped = "".join(kept).strip()
    if not stripped:
        raise Drift("%s contains no JSON document (only mix noise or empty)" % what)
    try:
        return json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise Drift("%s is not a single JSON document after removing known mix "
                    "compile-noise lines: %s" % (what, exc))


def need(d: Any, key: str, typ: type, where: str) -> Any:
    if not isinstance(d, dict) or key not in d:
        raise Drift("%s: missing key %r" % (where, key))
    if not isinstance(d[key], typ):
        raise Drift("%s: key %r has type %s, expected %s"
                    % (where, key, type(d[key]).__name__, typ.__name__))
    return d[key]


KNOWN_VERIFY_STATUS = {"pass", "fail", "unbound_facts"}
KNOWN_GATE_STATUS = {"pass", "gate_failed", "gate_cardinality"}


def parse(path, result):
    env = strict_json_loads(open(path, "rb").read(), "envelope")

    ok = need(env, "ok", bool, "envelope")
    exit_code = need(env, "exit_code", int, "envelope")
    data = need(env, "data", dict, "envelope")

    verify = need(data, "verify", dict, "data")
    vstatus = need(verify, "status", str, "data.verify")
    if vstatus not in KNOWN_VERIFY_STATUS:
        raise Drift("data.verify.status: unknown value %r" % vstatus)
    findings = need(verify, "findings", list, "data.verify")
    for f in findings:
        for k in ("gate", "subject", "missing_property"):
            need(f, k, str, "data.verify.findings[]")

    gates = need(data, "gates", dict, "data")
    gstatus = need(gates, "status", str, "data.gates")
    if gstatus not in KNOWN_GATE_STATUS:
        raise Drift("data.gates.status: unknown value %r" % gstatus)
    # `passed` is required ONLY on pass-shaped envelopes; the engine omits it
    # whenever any gate fails (DRIFT_REASON_GATE_FAIL_OMITS_PASSED) -- including
    # envelopes where verify.status is still "pass" (verify tracks fact
    # bindings, gates are a separate layer; witnessed in real envelopes, e.g.
    # state-transition-pack: verify.status=pass + gates.status=gate_failed).
    # So the criterion is gates.status, not verify.status. Every other key
    # stays strictly required.
    pass_shaped = gstatus == "pass"
    if pass_shaped:
        passed = need(gates, "passed", list, "data.gates")
    else:
        passed = gates.get("passed", [])
        if not isinstance(passed, list):
            raise Drift("data.gates: key 'passed' has type %s, expected list"
                        % type(passed).__name__)

    cardinality = need(data, "cardinality", dict, "data")
    contracts = need(cardinality, "gates_under_contract", list, "data.cardinality")

    # Cross-checks: the envelope must agree with itself and with the process
    # exit code the wrapper observed. Anything else is drift, not detail.
    if result == "PASS" and not ok:
        raise Drift("wrapper observed exit 0 but envelope says ok=false")
    if result == "FAIL" and exit_code == 0:
        raise Drift("wrapper observed nonzero exit but envelope exit_code=0")
    if result == "PASS" and vstatus != "pass":
        raise Drift("envelope verify.status=%r disagrees with observed result %s"
                    % (vstatus, result))
    # NOTE: result==FAIL with verify.status=="pass" is LEGITIMATE, not drift:
    # verify.status tracks fact bindings, gates are a separate layer and may
    # fail independently (witnessed: state-transition-pack,
    # workflow-corpus-pack envelopes). Only the reverse is contradictory.

    parts = []
    if result == "PASS":
        parts.append("%d gates passed, %d under contract, %d unbound facts"
                     % (len(passed), len(contracts), len(findings)))
    else:
        if gstatus == "gate_failed":
            parts.append("gate %s returned zero rows" % need(gates, "gate", str, "data.gates"))
        elif gstatus == "gate_cardinality":
            parts.append("gate %s emitted %s row(s), contract expects %s"
                         % (need(gates, "gate", str, "data.gates"),
                            need(gates, "actual", int, "data.gates"),
                            need(gates, "expected", int, "data.gates")))
        elif gstatus == "pass":
            parts.append("%d gates ok" % len(passed))
        for f in findings[:5]:
            parts.append("[%s] %s missing %s" % (f["gate"], f["subject"], f["missing_property"]))
        if len(findings) > 5:
            parts.append("... +%d more (full envelope: %s)" % (len(findings) - 5, path))
    print("; ".join(parts))


if __name__ == "__main__":
    try:
        parse(sys.argv[1], sys.argv[2])
    except Drift as exc:
        sys.stderr.write("ggen-verify: SCHEMA DRIFT [%s]: %s\n"
                         % (sys.argv[3] if len(sys.argv) > 3 else "?", exc))
        sys.exit(2)
