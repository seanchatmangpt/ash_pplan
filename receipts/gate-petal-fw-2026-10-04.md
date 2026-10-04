# Gate Receipt: petal_framework clone health — 2026-10-04

- Subject: `/Users/sac/ash_pplan/test/petal_framework` @ HEAD `1d7fd4ecffa2a8ad5d741a16898b504275490213`
- Scope: read-mostly lane; only this receipt written. No edits to clone, no git commands that mutate state.

## (1) Drift check — PASS

`git status --short`:
```
 M assets/js/hooks/index.js
?? assets/js/hooks/network-graph-hook.js
?? demo_graph/
```
Exactly the expected three entries (hook file, index.js, demo_graph/). No unexpected drift.

## (2) Syntax gate — PASS

`node --check assets/js/hooks/network-graph-hook.js` → exit 0 (`SYNTAX_OK`), no output.

## (3) Hook export — PASS

`assets/js/hooks/index.js`:
- line 10: `import NetworkGraphHook from "./network-graph-hook";`
- line 23: `NetworkGraphHook,` in the default export object.

## (4) Elixir compile gate — SKIPPED

`deps/` directory absent (DEPS_MISSING) — dependencies not fetchable offline; per lane
contract, `mix compile` skipped (demo_graph app is the real compile gate; not duplicated here).

## Verdict

HEALTHY. All three executed gates pass; drift confined to the expected NetworkGraph hook
additions. Compile gate skipped with typed reason (deps missing offline).
