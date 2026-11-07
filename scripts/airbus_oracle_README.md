# airbus-oracle-daemon

Reference-solver daemon for the ash_pplan airbus-parity work: a unix-socket
JSON-line service that solves PDDL problems via Unified Planning (UP) and
returns typed results, including an honest typed refusal when no installed
engine admits the problem's kind.

Standing: ALIVE (authoring session 2026-11-07; every command below was run,
outputs in the Receipt section).

## Quick start

```sh
python3 -m venv .venv-airbus
.venv-airbus/bin/pip install unified-planning up-pyperplan
.venv-airbus/bin/python scripts/airbus_oracle_daemon.py --serve
```

## Usage

```sh
.venv-airbus/bin/python scripts/airbus_oracle_daemon.py --engines
.venv-airbus/bin/python scripts/airbus_oracle_daemon.py --selftest - -
.venv-airbus/bin/python scripts/airbus_oracle_daemon.py --selftest \
    priv/courts/airbus_parity/corpus/fastener_torque.fond.pddl \
    priv/courts/airbus_parity/corpus/fastener_torque.fond.pddl
```

## Protocol

One JSON line per connection, one request per connection, on
`/tmp/airbus_oracle.sock`.

Request:

```json
{"method": "solve", "params": {"domain": "<pddl text>", "problem": "<pddl text>"}, "id": 7}
```

Response: `{"id": ..., "result": {solvable, plan, engine, error, ...}}`.

- `solvable: true` — `plan` is a list of action strings, `engine` names the
  engine, `status` is UP's status name.
- `solvable: false` — engine proved unsatisfiability (`status` carries it).
- `solvable: null` — typed error in `error`:

| error | meaning |
|---|---|
| `no_engine_for_kind` | problem kind has no installed engine (FOND/PO/HDDL/temporal) |
| `parse_error` | text did not parse as PDDL |
| `bad_request` | malformed envelope |
| `solve_failed` | engine admitted the problem but failed |

## Live engines (measured 2026-11-07; UP 26.0.8.38.post1, Python 3.14.3, macOS arm64)

`--engines` real output:

```
pyperplan,pyperplan-opt,replanner[pyperplan-opt],replanner[pyperplan]
```

pyperplan 2.1.0 via up-pyperplan 1.1.0 — propositional STRIPS only.
`sequential_plan_validator` and `sequential_simulator` are also registered
(UP built-ins) for validation, not generation.

## Non-classical problems: honest degradation

No FOND engine is pip-installable (`up-prp` and `up-fond`: no matching
distribution on PyPI, both probed). Consequence: the parity court degrades to
sequential-problem parity only. FOND corpus cases return typed
`no_engine_for_kind` with `kind=fond`. Those cells are "reference solver
unavailable" — not solves, not unsat.

Detection: requirement-line sniffing in `classify_kind` (`:non-deterministic`,
`:htn`/`:hddl`/`:method`, `:process`/`:durative`/`:time`) runs BEFORE the UP
parse, because UP's PDDLReader raises on non-classical dialects instead of
reporting the kind. Parse-failure classification is heuristic: a
strangely-formatted FOND domain that slips past the sniff surfaces as
`parse_error`; the court should read `parse_error` on a known-FOND file as the
same standing (reference unavailable for kind), never as evidence.

Per-corpus measured outcomes:

- `fastener_torque.fond.pddl` → `no_engine_for_kind` (kind=fond) — measured.
- `aog_turnaround.hddl` → `no_engine_for_kind` (kind=hddl) — see receipt.
- `avionics_bay.po.pddl` → not measured this session (left to the court lane).
- `composite_cure.stnu` → not PDDL; would surface as `parse_error` (unmeasured).

## Built-in smoke case

Every PDDL example bundled with UP (counters, tpp_metric, miconic, ...) carries
features no installed engine admits (numeric fluents, action costs, conditional
effects, durations). The `--selftest - -` fallback is therefore an inline
pure-STRIPS pair (`BUNDLED_DOMAIN` / `BUNDLED_PROBLEM` constants in the
daemon): one type, two predicates, one action, one-step plan. pyperplan
returns `(move o1 o1)`.

## Receipt (authoring session, 2026-11-07)

Standing: ALIVE. Files delivered:

- /Users/sac/ash_pplan/scripts/airbus_oracle_daemon.py (new)
- /Users/sac/ash_pplan/scripts/airbus_oracle_README.md (this file)

Commands and exits (all in /Users/sac/ash_pplan):

- `python3 -m py_compile scripts/airbus_oracle_daemon.py` → exit 0.
- `--engines` → exit 0, output above.
- `--selftest - -` → exit 0; `SELFTEST: real plan produced via Pyperplan`;
  result JSON: solvable=true, plan=["(move o1 o1)"], engine="Pyperplan",
  status=SOLVED_SATISFICING.
- `--selftest priv/courts/airbus_parity/corpus/fastener_torque.fond.pddl ...`
  → exit 0; `SELFTEST: typed no_engine_for_kind kind=fond`.
- Socket end-to-end: daemon `--serve` in background; FOND corpus request over
  the socket → `{"id": 7, "result": {"solvable": null, ..., "error":
  "no_engine_for_kind", "kind": "fond"}}`; classical request over the socket →
  `{"id": "a", "result": {"solvable": true, "plan": ["(move o1 o1)"],
  "engine": "Pyperplan", "error": null, "status": "SOLVED_SATISFICING"}}`.
  Test client cleaned up; stale pre-existing socket replaced by the daemon's
  bind (serve unlinks first); daemon processes killed after each test.

Environment facts: PEP 668 blocks system pip → dedicated venv
`.venv-airbus/` at the repo root (untracked; the court lane needs
`pip install unified-planning up-pyperplan` in whatever env it uses).
`up-prp`/`up-fond` do not exist on PyPI; PRP would need a source install —
out of lane scope.

Venv path note (lane A4, 2026-11-07): the daemon's `solve` method uses
`.venv-airbus/bin/python` (unified-planning + pyperplan). The `check_policy`
method needs no venv at all — autofde_lab's
`autofde_lab.planning.fond_policy` checker is pure stdlib, imported lazily
from `/Users/sac/autofde-lab/src` (`AUTOFDE_SRC` in the daemon). System
`python3 scripts/airbus_oracle_daemon.py --serve` serves both methods, but
`check_policy` under system python3 and `solve` under `.venv-airbus` must not
be mixed across restarts — pick one interpreter per daemon process.

Deviations from the dispatch spec: (1) used `OneshotPlanner(problem_kind=...)`
instead of `AnyEngine` — UP 26.x has no `shortcuts.AnyEngine`; (2) the
bundled-example fallback is an inline STRIPS pair because no UP-bundled PDDL
example is pyperplan-compatible; (3) venv at repo root instead of --user
install (PEP 668).
