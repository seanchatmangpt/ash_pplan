# Gate Receipt: Playwright Verification Lane B — 2026-10-04

## Subject
`/Users/sac/ash_pplan/test/petal_framework/demo_graph` regression check after parent
repo `mix.exs` swapped `petal_framework` path dep for hex `petal_components 2.9.3`.

## Dependency isolation finding
`demo_graph/mix.exs` declares its OWN deps (phoenix ~> 1.7.21, phoenix_html ~> 4.1,
phoenix_live_view ~> 1.0, bandit ~> 1.5, jason ~> 1.4, telemetry ~> 1.2). It does NOT
depend on the parent's `petal_framework` path dep or `petal_components`. The parent
dep swap is orthogonal to the demo's dependency closure — no regression channel through
deps. Lane is read-only on demo source; nothing modified.

## Commands and results

### 1. Compile (isolated build root)
```
cd /Users/sac/ash_pplan/test/petal_framework/demo_graph
MIX_BUILD_ROOT=_build-pfw-demo-b mix compile --warnings-as-errors
```
Exit: 0. `Compiling 8 files (.ex)` / `Generated demo_graph app`. (Hex dep typing-violation
warnings printed for `phoenix`/`plug` internals did not fail `--warnings-as-errors`;
they live in vendored dep sources, not demo code.) Port 4400 was free (no stale listener).

### 2. Playwright
```
npx playwright test
```
Exit: 0.

```
Running 5 tests using 1 worker
  ✓  1 graph.spec.js:8:5 › a. DOM isolation: id + phx-update=ignore + canvas present (1.0s)
  ✓  2 graph.spec.js:19:5 › b. differential patch: mark survives add-node, no full relayout (414ms)
  ✓  3 graph.spec.js:52:5 › c. node-moved throttle persists coords across reload (862ms)
  ✓  4 graph.spec.js:72:5 › d. reconnect: missed patch recovered via request-graph-sync (1.1s)
  ✓  5 graph.spec.js:102:5 › e. destroyed: cy.destroy() ran and probe flag set (319ms)
  5 passed (5.4s)
```

## Verdict
ALIVE — 5/5 Playwright tests passed, compile clean (exit 0), webServer booted the app.
No regressions from the petal_components 2.9.3 swap.

## Cleanup
Build root `_build-pfw-demo-b` deleted after run. No git operations performed.
