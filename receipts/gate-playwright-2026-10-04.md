# Receipt: Playwright Gate — demo_graph graph.spec.js

- **Date**: 2026-10-04
- **Subject**: `/Users/sac/ash_pplan/test/petal_framework/demo_graph/graph.spec.js`
- **Scope**: tooling-diagnostic fix + full suite re-run. READ-ONLY elsewhere.

## Change (spec file only, no test semantics)

Diagnostic "CommonJS module; may be converted to ES module" resolved by
converting the module import to ESM:

```diff
-const { test, expect } = require("@playwright/test");
+import { test, expect } from "@playwright/test";
```

Rationale: no eslint/tsconfig exists in the tree to add an ignore to; the
Playwright config (`playwright.config.ts`) is itself ESM and Playwright's
transpiler handles ESM in `.js` specs regardless of `"type": "commonjs"` in
package.json. All 5 tests unchanged and passing after conversion — confirmed
non-semantic.

## Verification (actual output)

```
$ cd /Users/sac/ash_pplan/test/petal_framework/demo_graph && npx playwright test

Running 5 tests using 1 worker

  ✓  1 graph.spec.js:8:5 › a. DOM isolation: id + phx-update=ignore + canvas present (787ms)
  ✓  2 graph.spec.js:19:5 › b. differential patch: mark survives add-node, no full relayout (448ms)
  ✓  3 graph.spec.js:52:5 › c. node-moved throttle persists coords across reload (972ms)
  ✓  4 graph.spec.js:72:5 › d. reconnect: missed patch recovered via request-graph-sync (873ms)
  ✓  5 graph.spec.js:102:5 › e. destroyed: cy.destroy() ran and probe flag set (372ms)

  5 passed (6.3s)
```

**Result: 5 passed / 0 failed / 0 skipped** (6.3s, 1 worker). WebServer
started cleanly; no port-4400 kill needed. No app-level failures; no
spec-artifact fixes required beyond the import line.

## Standing

ALIVE — exact subject witnessed by the run above, full suite green.
