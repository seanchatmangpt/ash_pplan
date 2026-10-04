#!/usr/bin/env python3
"""Deterministic semantic gate↔witness qualification court.

The court is engine-agnostic. It proves structural coverage itself and can delegate
semantic execution to a caller-supplied runner whose zero exit status means the
specified expectation was observed. The runner is invoked without a shell.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shlex
import subprocess
import sys
import tomllib
from pathlib import Path

SCHEMA = "ggen.semantic-gate-witness-court/1"
DEFAULT_GATE_EXTENSIONS = (".rq", ".sparql")
DEFAULT_WITNESS_EXTENSIONS = (".ttl", ".json", ".toml", ".yaml", ".yml", ".jsonld")


def _load_config(root: Path, config_name: str) -> dict:
    path = root / config_name
    if not path.is_file():
        raise ValueError(f"missing config: {config_name}")
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    court = data.get("court")
    if not isinstance(court, dict):
        raise ValueError("missing [court] table")
    if court.get("schema") != SCHEMA:
        raise ValueError(f"court.schema must equal {SCHEMA}")
    if court.get("case_key", "exact-stem") != "exact-stem":
        raise ValueError("only case_key=exact-stem is admitted")
    return court


def _extensions(value, default):
    raw = value if value is not None else list(default)
    if not isinstance(raw, list) or not raw:
        raise ValueError("extension lists must be non-empty arrays")
    normalized = []
    for item in raw:
        if not isinstance(item, str) or not item.startswith("."):
            raise ValueError(f"invalid extension: {item!r}")
        normalized.append(item)
    if len(normalized) != len(set(normalized)):
        raise ValueError("duplicate extensions are refused")
    return tuple(sorted(normalized))


def _files(directory: Path, extensions: tuple[str, ...]) -> list[Path]:
    if not directory.is_dir():
        return []
    return sorted((p for p in directory.iterdir() if p.is_file() and p.suffix in extensions), key=lambda p: p.name)


def _group_by_stem(paths: list[Path]) -> dict[str, list[Path]]:
    grouped: dict[str, list[Path]] = {}
    for path in paths:
        grouped.setdefault(path.stem, []).append(path)
    return grouped


def _digest(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def _relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def _run_case(runner: str, *, root: Path, gate: Path, witness: Path, expectation: str) -> dict:
    argv = [token.format(root=str(root), gate=str(gate), witness=str(witness), expectation=expectation) for token in shlex.split(runner)]
    if not argv:
        raise ValueError("runner command is empty")
    proc = subprocess.run(argv, cwd=root, text=True, capture_output=True, check=False)
    return {"argv": argv, "exit_code": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "qualified": proc.returncode == 0}


def qualify(root: Path, config_name: str, runner: str | None) -> dict:
    root = root.resolve()
    court = _load_config(root, config_name)
    gate_exts = _extensions(court.get("gate_extensions"), DEFAULT_GATE_EXTENSIONS)
    witness_exts = _extensions(court.get("witness_extensions"), DEFAULT_WITNESS_EXTENSIONS)
    gate_dir = root / court.get("gate_dir", "gates")
    pass_dir = root / court.get("pass_dir", "witnesses/pass")
    fail_dir = root / court.get("fail_dir", "witnesses/fail")
    require_pass = court.get("require_pass", True)
    require_fail = court.get("require_fail", False)
    if not isinstance(require_pass, bool) or not isinstance(require_fail, bool):
        raise ValueError("require_pass and require_fail must be booleans")

    gates = _files(gate_dir, gate_exts)
    if not gates:
        raise ValueError("no admitted gate files found")
    gate_by_key = {p.stem: p for p in gates}
    if len(gate_by_key) != len(gates):
        raise ValueError("duplicate gate stems are refused")

    pass_by_key = _group_by_stem(_files(pass_dir, witness_exts))
    fail_by_key = _group_by_stem(_files(fail_dir, witness_exts))
    gate_keys = set(gate_by_key)
    orphan_pass = sorted(set(pass_by_key) - gate_keys)
    orphan_fail = sorted(set(fail_by_key) - gate_keys)
    missing_pass = sorted(gate_keys - set(pass_by_key)) if require_pass else []
    missing_fail = sorted(gate_keys - set(fail_by_key)) if require_fail else []
    errors = []
    if orphan_pass:
        errors.append({"kind": "orphan_pass", "keys": orphan_pass})
    if orphan_fail:
        errors.append({"kind": "orphan_fail", "keys": orphan_fail})
    if missing_pass:
        errors.append({"kind": "missing_pass", "keys": missing_pass})
    if missing_fail:
        errors.append({"kind": "missing_fail", "keys": missing_fail})

    cases = []
    for key in sorted(gate_by_key):
        gate = gate_by_key[key]
        entry = {"key": key, "gate": _relative(root, gate), "gate_digest": _digest(gate), "pass": [_relative(root, p) for p in pass_by_key.get(key, [])], "fail": [_relative(root, p) for p in fail_by_key.get(key, [])], "executions": []}
        if runner and not errors:
            for expectation, paths in (("pass", pass_by_key.get(key, [])), ("fail", fail_by_key.get(key, []))):
                for witness in paths:
                    execution = _run_case(runner, root=root, gate=gate, witness=witness, expectation=expectation)
                    execution.update({"expectation": expectation, "witness": _relative(root, witness), "witness_digest": _digest(witness)})
                    entry["executions"].append(execution)
                    if not execution["qualified"]:
                        errors.append({"kind": "runner_refusal", "key": key, "expectation": expectation, "witness": _relative(root, witness), "exit_code": execution["exit_code"]})
        cases.append(entry)

    return {"schema": SCHEMA, "standing": "ALIVE" if not errors else "REFUSED", "root": str(root), "config": config_name, "gate_count": len(gates), "pass_witness_count": sum(map(len, pass_by_key.values())), "fail_witness_count": sum(map(len, fail_by_key.values())), "runner_executed": bool(runner), "cases": cases, "errors": errors}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--config", default="gate-court.toml")
    parser.add_argument("--runner", help="command template; placeholders: {root} {gate} {witness} {expectation}; invoked without shell")
    parser.add_argument("--receipt", help="optional JSON receipt path")
    args = parser.parse_args()
    try:
        receipt = qualify(Path(args.root), args.config, args.runner)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        receipt = {"schema": SCHEMA, "standing": "REFUSED", "errors": [{"kind": "court_error", "message": str(exc)}]}
    payload = json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
    if args.receipt:
        Path(args.receipt).write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0 if receipt.get("standing") == "ALIVE" else 1


if __name__ == "__main__":
    raise SystemExit(main())
