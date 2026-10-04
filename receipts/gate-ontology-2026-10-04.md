# Gate Receipt — ontology mirror + verification gates — 2026-10-04

Lane: READ-MOSTLY verification (no source edits, no git commands run).
Subject: /Users/sac/ash_pplan, working tree (branch main, uncommitted state as-is).

## 1. Header-stripped SHA-256: ontology.ttl vs priv/ggen mirrors

Canonical: `ontology.ttl` — full-file SHA-256
`257b0cecef19c3292a5f55857ad0ac9f40c8c0e97241aba3f5d577f3a2d7d8a6`
(canonical has NO GENERATED-PROVENANCE header; stripped == full).

Header conventions observed:
- `priv/ggen/ash-pplan-dsl-pack/ontology.ttl` — 3-line `# GENERATED-PROVENANCE` header,
  line 4 is content directly (`@prefix ap: ...`), NO blank 4th line.
- `priv/ggen/ash-pplan-pack/ontology.ttl` — 3-line header, then a blank line 4,
  content starts line 5.
- `priv/ggen/ash-pplan-workflow-pack/ontology.ttl` — same as ash-pplan-pack:
  3-line header + blank line 4.

Method: `tail -n +4 <mirror>` then squeeze leading blank lines (`sed '/./,$!d'`),
SHA-256 of remainder.

```
== priv/ggen/ash-pplan-dsl-pack/ontology.ttl
257b0cecef19c3292a5f55857ad0ac9f40c8c0e97241aba3f5d577f3a2d7d8a6  -
== priv/ggen/ash-pplan-pack/ontology.ttl
257b0cecef19c3292a5f55857ad0ac9f40c8c0e97241aba3f5d577f3a2d7d8a6  -
== priv/ggen/ash-pplan-workflow-pack/ontology.ttl
257b0cecef19c3292a5f55857ad0ac9f40c8c0e97241aba3f5d577f3a2d7d8a6  -
```

**MATCH: YES — all three mirrors byte-identical to canonical after header strip.**
(Other priv/ggen/*/ontology.ttl packs are independent ontologies, not mirrors of the
root file; excluded by design.)

## 2. ./bin/conform

```
ONTOLOGY_TRIPLES=812
SHAPES=ontology/shapes.ttl
CONFORMS=True
EXIT=0
```

Expected CONFORMS: met. Triple count: **812**.

## 3. ./bin/conform-falsify

```
refused: unadmitted projection standing
refused: duplicate projection order
refused: duplicate projection source term
refused: step preceded by a step of another plan
refused: step preceded by itself
refused: step preceded by something that is not a step
refused: plan without a label
refused: plan with no steps
refused: step with two labels
refused: projection source term that is a literal
refused: step using a variable from another plan
refused: step outside any plan
refused: variable outside any plan

13 counterexamples refused by ontology/shapes.ttl
EXIT=0
```

Expected 13 refusals / exit 0: met exactly.

## 4. bash priv/ggen/vendor/verify_lock.sh

```
verify_lock: OK (3 packs, lock 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2)
EXIT=0
```

## 5. ./bin/ggen-verify (stdin </dev/null, non-interactive)

```
PACK                                     RESULT     DETAIL
---------------------------------------- ---------- ------------------------------
ash-pplan-pack                           PASS       3 gates passed, 2 under contract, 0 unbound facts
ash-pplan-workflow-pack                  FAIL       gate task_props returned zero rows
ash-pplan-standing-pack                  PASS       7 gates passed, 7 under contract, 0 unbound facts
ash-pplan-durable-tla-pack               PASS       5 gates passed, 5 under contract, 0 unbound facts
ash-pplan-store-conformance-pack         PASS       3 gates passed, 3 under contract, 0 unbound facts
ash-pplan-durable-chaos-pack             PASS       2 gates passed, 2 under contract, 0 unbound facts
vendor/ash-pplan-protocol-court-pack     PASS       7 gates passed, 7 under contract, 0 unbound facts

ggen-verify: FAILURES above; full envelopes in tmp/ggen-verify/
EXIT=0
```

**Finding (pre-existing, not introduced this session): `ash-pplan-workflow-pack`
FAILS — `gate task_props returned zero rows`.** 6/7 packs PASS. Full envelopes in
`tmp/ggen-verify/`.

## Summary

| Gate | Expected | Observed | Status |
|---|---|---|---|
| mirror hashes (x3, header-stripped) | match canonical | all = 257b0cec…d8a6 | MATCH |
| bin/conform | CONFORMS | CONFORMS=True, 812 triples, exit 0 | PASS |
| bin/conform-falsify | 13 refusals, exit 0 | 13 refusals, exit 0 | PASS |
| verify_lock.sh | OK | OK (3 packs, lock 503af6c2…) | PASS |
| bin/ggen-verify | — | 6 PASS, 1 FAIL (workflow-pack: task_props zero rows), exit 0 | FAIL on workflow-pack |

Standing: 4/5 gates conform; ggen-verify BLOCKED for ash-pplan-workflow-pack
(pre-existing). Falsifier for any future "mirrors in sync" claim: re-run the
header-stripped hash loop above; any digest != 257b0cecef19c3292a5f55857ad0ac9f40c8c0e97241aba3f5d577f3a2d7d8a6
refutes it.
