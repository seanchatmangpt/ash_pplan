#!/usr/bin/env python3
"""Strict, fail-CLOSED parser for `mix ggen_igniter.doctor --json` output.

Replaces the previous fail-open parse of the human checklist (grep -c on
'✘'/'⚠'/'✔' glyph lines + N/A-pattern filtering): any schema drift -- non-JSON
stdout, missing/renamed keys, an UNKNOWN check status value, an envelope whose
ok/exit_code contradict the wrapper's observation -- is a TYPED ERROR with a
nonzero exit, never a silent fallback.

Envelope contract (validated, not assumed):
  checks      list of {check_id: str, message: str,
                       status: "ok"|"warn"|"error", strict_failure: bool}
  exit_code   int
  ok          bool
  strict      bool

Known-N/A tolerance (unchanged semantics): the version_policy check cannot pass
on a consumer repo (see bin/ggen-doctor header). An 'error' check whose message
contains the N/A pattern is counted as skipped, not a failure; any OTHER error
check fails the pack.

Usage:
  python3 bin/.ggen-doctor-parse.py <doctor.json> <na-substring> <observed-exit>
                                    <pack>

Prints glyph lines (  ✔/⚠/✘ message) then a summary line:
  RESULT <ok|FAIL|NA_ONLY> pass=N warn=N na=N
Exit 0 parsed (pass, warn, or N/A-only) / 1 real failure / 2 schema drift.
"""
import json
import re
import sys
from typing import Any


class Drift(Exception):
    pass


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


KNOWN_STATUS = {"ok", "warn", "error"}


def need(check: Any, key: str, typ: type, where: str) -> Any:
    # Explicit annotations: unannotated, pyright mis-infers this function's
    # return type (observed `bool`), producing false "bool is not iterable"
    # errors on `for c in checks:`. Runtime shape is a list (validated below).
    val = check.get(key, _MISSING)
    if val is _MISSING:
        raise Drift("%s: missing key %r" % (where, key))
    good = isinstance(val, bool) if typ is bool else (
        not isinstance(val, bool) and isinstance(val, typ))
    if not good:
        raise Drift("%s: key %r has type %s, expected %s"
                    % (where, key, type(val).__name__, typ.__name__))
    return val


_MISSING = object()


def parse(path, na_pattern, observed_exit):
    env = strict_json_loads(open(path, "rb").read(), "doctor output")
    if not isinstance(env, dict):
        raise Drift("envelope top level is %s, expected object" % type(env).__name__)

    checks = need(env, "checks", list, "envelope")
    exit_code = need(env, "exit_code", int, "envelope")
    ok = need(env, "ok", bool, "envelope")
    need(env, "strict", bool, "envelope")

    passing = warning = na = 0
    real_failures = []
    for c in checks:
        if not isinstance(c, dict):
            raise Drift("checks[] element is %s, expected object"
                        % type(c).__name__)
        status = need(c, "status", str, "checks[]")
        if status not in KNOWN_STATUS:
            raise Drift("checks[].status: unknown value %r" % status)
        message = need(c, "message", str, "checks[]")
        need(c, "check_id", str, "checks[]")
        need(c, "strict_failure", bool, "checks[]")
        if status == "ok":
            passing += 1
        elif status == "warn":
            warning += 1
        elif na_pattern in message:
            na += 1
        else:
            real_failures.append(message)

    if ok != (exit_code == 0):
        raise Drift("envelope ok=%s contradicts exit_code=%s" % (ok, exit_code))
    if observed_exit != exit_code:
        raise Drift("envelope exit_code=%d contradicts wrapper-observed exit %d"
                    % (exit_code, observed_exit))
    # Note: ok=false with every error check matching the N/A pattern is the
    # documented NA_ONLY case (version_policy cannot pass on a consumer repo),
    # not drift.

    glyph = {"ok": "✔", "warn": "⚠", "error": "✘"}
    for c in checks:
        print("  %s %s" % (glyph[c["status"]], c["message"]))

    if real_failures:
        verdict = "FAIL"
    elif na:
        verdict = "NA_ONLY"
    else:
        verdict = "ok"
    print("RESULT %s pass=%d warn=%d na=%d" % (verdict, passing, warning, na))

    for msg in real_failures:
        print("  REAL FAILURE: %s" % msg)
    return 1 if real_failures else 0


if __name__ == "__main__":
    try:
        sys.exit(parse(sys.argv[1], sys.argv[2], int(sys.argv[3])))
    except Drift as exc:
        sys.stderr.write("ggen-doctor: SCHEMA DRIFT [%s]: %s\n" % (sys.argv[4], exc))
        sys.exit(2)
