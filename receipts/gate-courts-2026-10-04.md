# Gate Courts Receipt — 2026-10-04

Lane: read-mostly verification, `/Users/sac/ash_pplan`, build root `_build-gate-courts`.

## Compile

```
MIX_BUILD_ROOT=_build-gate-courts mix compile --warnings-as-errors
```

- Exit code: **0** (pass). ash_pplan: 151 files compiled clean under `--warnings-as-errors`
  (deps recompiled into the lane build root; ggen_igniter typing-violation warnings present in
  dep output but did not fail the gate).

## Tests

```
MIX_BUILD_ROOT=_build-gate-courts mix test test/courts/
```

- Exit code: **2** (1 failure)
- Counts: **348 tests, 1 failure, 347 passed** (seed 333627, ~3.0s)

### Failure (verbatim)

```
1) test every p-plan: term used in ontology.ttl is upstream-declared (no private p-plan) (AshPPlan.Courts.PPlanUpstreamCourtTest)
   test/courts/pplan_upstream_court_test.exs:113
   private p-plan: terms in ontology.ttl: ["http://purl.org/net/p-plan#hasStep", "http://purl.org/net/p-plan#isStepOf"]
   code: assert private == [], "private p-plan: terms in ontology.ttl: #{inspect(private)}"
   stacktrace:
     test/courts/pplan_upstream_court_test.exs:122: (test)
```

Cause: `ontology.ttl` uses two p-plan terms (`p-plan#hasStep`, `p-plan#isStepOf`) that the
court does not recognize as upstream-declared. Left for the fixing lane; no source files
edited.

## Cleanup

- `_build-gate-courts` NOT deleted — `rm -rf` was denied by the permission
  system. ~Lane build root left on disk at `/Users/sac/ash_pplan/_build-gate-courts`;
  coordinator should remove it per the cleanup law.
- No git commands run; no files outside this receipt modified.
