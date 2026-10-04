# ECO-IGNITER-DERIVED-COUNT — DERIVED_ROWS contract mode (ggen_igniter)

2026-10-04 · lane: `errc-igniter-envelope-and-chain-fixes` @ `/Users/sac/ggen_igniter` (local branch, no push) · consumer repo: `ash_pplan`

## Problem

The R2 lane's typed refusal: `ggen_igniter.verify`'s contract modes (`ROWS`,
`VALUES`) count anchor-pattern matches over the whole graph
(`(provider, ap:supportsProperty)` edge pairs = 14), while
`gates/100_task_props.rq` emits one row per **derived** `(task, property)`
pair joined through providers = 18 rows, and 15 tasks make any subject-anchored
equality unreachable. No existing mode expresses a derived count.

## Mode design

`DERIVED_ROWS` — the expected value is a QUERY, not an anchor count.

```json
{"mode": "DERIVED_ROWS", "query": "SELECT ..."}
{"mode": "DERIVED_ROWS", "query_file": "task_props.derived.rq"}
```

- Exactly one of inline `query` / `query_file` (absolute, or relative to the
  contract file's own directory, i.e. `<pack>/verify/`). Both → `:ambiguous_query`;
  neither → `:missing_query`.
- `query_file` is resolved and read at LOAD time, so a missing file is a typed
  load refusal (`{:invalid_contract, stem, {:query_file_missing, path}}`)
  before any gate runs; `GateVerify.run/3` only ever sees a ready query string.
- Pass condition: gate row count == contract-query row count over the SAME
  graph. Either side moving breaks it. Fail-closed: a contract query that
  does not execute against the graph refuses the gate it annotates
  (`{:error, {:gate_derived_query, name, message}}`, JSON status
  `gate_derived_query`, exit 1) — never a pass with an underived count.
- Blind spot shifts from "loss of the anchor predicate" to "a deletion that
  moves the gate query and the contract query identically" — which is exactly
  what the `verify/*.unbound.rq` companions name. Contract + companion keep
  disjoint blind spots.

Implementation: `/Users/sac/ggen_igniter/lib/ggen_igniter/gate_verify.ex`
(parse/derive clauses + typed error), `lib/mix/tasks/ggen_igniter.verify.ex`
(human + JSON report arms), tests in
`test/mix/tasks/ggen_igniter_verify_task_test.exs`.

## Tests (ggen_igniter)

`test/mix/tasks/ggen_igniter_verify_task_test.exs`, real-subprocess style
(Chicago): equal counts pass; unequal fail typed (`gate_cardinality`,
expected 1 / actual 2); malformed contract query fails closed typed
(`gate_derived_query`); `query_file` resolved relative to the contract file.
`9 tests, 0 failures` (`--include integration`; two pre-existing
exit-code-2 invocation tests were failing on pristine `df6b0b9` and were
fixed forward to the branch's own documented contract). Unit suites
`gate_verify` + `verify_mutation`: 20 tests, 0 failures.

## Contract update (ash_pplan — the one owned file)

`priv/ggen/ash-pplan-workflow-pack/verify/cardinality.json`: `task_props`
moved `VALUES` (ap:supportsProperty) → `DERIVED_ROWS` with an inline query
mirroring the gate's derivation exactly (Workflow hasTask Task
requiresCapability ← Provider supportsCapability supportsProperty). Notes
record the resolution; the KNOWN STANDING refusal text is replaced by
"RESOLVED … task_props now passes at 18 == 18".

## End-to-end proof (merged ontology, per bin/ggen-verify's own recipe)

Merged graph = `ontology.ttl` + `test/support/examples/ontology/examples.ttl`
(rdflib merge, the same merge `bin/ggen-verify` performs). Ran from the
ggen_igniter branch (ash_pplan's Hex dep 26.10.2 does not contain
DERIVED_ROWS, so the task was executed by the owning repo against the
ash_pplan pack directory):

```
MIX_BUILD_ROOT=_build-igniter-dc mix ggen_igniter.verify \
  --pack priv/ggen/ash-pplan-workflow-pack \
  --ontology /tmp/workflow-merged-ontology.ttl --json
```

- Old (R2 working-tree) contract: `task_props` refuses
  `gate_cardinality` 64 vs 0 on this graph (14 vs 18 on the R2 graph) — the
  R2 refusal reproduced.
- New contract, `reactor_surface` entry temporarily removed: **exit 0, 15/15
  gates pass, `task_props` in the passed list (18 == 18).** The task_props
  refusal is gone.
- New contract as committed: halts at `reactor_surface` (expected 4, actual
  9) — a SEPARATE, PRE-EXISTING mismatch introduced by the R2 working tree's
  own `gates/123_reactor_surface.rq` (its OPTIONAL cross-product emits one
  row per (workflow, inputs, aliases) combination = 9) vs its `VALUES`
  contract on `ap:reactorInput` (= 4). Same derived-count class as task_props;
  the fix is the identical DERIVED_ROWS pattern, but the pairing belongs to
  the R2 lane — left untouched for the coordinator, not silently rewritten.

## Standing

- ggen_igniter branch `errc-igniter-envelope-and-chain-fixes`: work committed
  on the branch (no push); repo restored to `main` after.
- ash_pplan: only `verify/cardinality.json` modified (owned file); the pack
  still refuses at `reactor_surface` under the full R2 contract until the
  coordinator adopts DERIVED_ROWS there too (needs the branch published or
  path-pinned first — Hex 26.10.2 lacks the mode and would refuse it as
  `unknown_mode`).
