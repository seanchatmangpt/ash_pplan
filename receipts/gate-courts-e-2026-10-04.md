# Gate Receipt — gate-courts-e-2026-10-04 (closeout consolidated re-gate)

- Subject: /Users/sac/ash_pplan @ main, working tree (post residual fixes: sync.sh
  patch 2f hygiene DISTINCT, dets event-driven waits, release-contract petal,
  law baseline 1043, witness fixtures, 51 `[law].gates`)
- Build root: `MIX_BUILD_ROOT=_build-gate-ce` (deleted after run)
- Date: 2026-10-04

## Commands + exits (actual output)

1. `MIX_BUILD_ROOT=_build-gate-ce mix compile --warnings-as-errors`
   → exit **0** ("Compiling 151 files (.ex) / Generated ash_pplan app"). No retry needed.
2. `MIX_BUILD_ROOT=_build-gate-ce mix test test/courts/ test/workflow/ test/ggen_gate_hygiene_test.exs --trace`
   → exit **2**. `Finished in 667.9 seconds (7.5s async, 660.4s sync)` —
   **946 tests, 2 failures**. (Wall time ~12 min, within 35 min budget.)

## Failures (verbatim)

```
1) test ash-pplan-pack PREFIX hygiene 020_plan_steps.rq declares every namespace prefix it uses (GgenGateHygieneTest)
   test/ggen_gate_hygiene_test.exs:43
   020_plan_steps.rq: prefixes used but not declared: ["ap"]
   code: assert undeclared == [],
```

```
2) test law export determinism + BLAKE3 baseline export is deterministic and matches the pinned graph_hash (GgenVerbGatesCourtTest)
   test/courts/ggen_verb_gates_court_test.exs:83
   law export BLAKE3 state hash drifted from baseline (expected 22a708e3aa38dd4eb8c29099a13eb2c2dd902a2476259f656262637eae51a113, got 3c66d6b18797a2cfc081d6b1abc7f5dd1d30f5a2c7f34b96fea95c62067ffcc6)
   code: assert j1["graph_hash"] == ctx.baseline["graph_hash"],
```

## Classification

- **(b) pre-existing — 020_plan_steps.rq prefix hygiene**: the gate file uses `ap:` …
  no `PREFIX ap:` declaration (only `p-plan:` and `rdfs:` declared, lines 1–2).
  Not covered by sync.sh patch 2f (which addressed DISTINCT determinism, witnessed
  170/0 — all other 169 hygiene tests pass). Owner: ontology/gate-pack lane
  (ggen-manifest authorship). Fix is one line: add `PREFIX ap: <…ap#>` per the
  manifest's ap namespace.
- **(b) pre-existing — law baseline hash drift**: baseline fixture
  `test/courts/fixtures/law_export_baseline.txt` pins `graph_hash=22a708e3…` at
  1043 triples (re-pin noted "HEAD 9a89aac"), but the working-tree `ontology.ttl`
  is modified beyond that pin (git status: `M ontology.ttl`,
  `M priv/ggen/ash-pplan-pack/ontology.ttl`), so the exported BLAKE3 differs.
  Triple count still 1043 per fixture, so drift is content not count. Owner:
  whoever lands the in-flight ontology.ttl edits — re-run `ggen law export
  --format json` on the final ontology and re-pin the fixture (or land ontology,
  then re-pin).

- No new-this-session failures. Compile clean. All courts/workflow suites
  otherwise green (944/946).

## Cleanup

`_build-gate-ce` deleted after receipt. No git operations performed.
