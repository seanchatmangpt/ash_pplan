# Final Confirmation Receipt — 2026-10-04

Subject: /Users/sac/ash_pplan, branch main @ 37bc291
Lane: READ-MOSTLY confirmation (only this file written; `_build-finalconf` created and deleted).
Quiesce: two `git status --porcelain | shasum` samples 60s apart — identical (`997c2b99…` at 08:13:55 and 08:15:00 PDT). Tree stable.

## 5-check table

| # | Check | Expected | Observed | Verdict |
|---|-------|----------|----------|---------|
| 1 | `./bin/conform` | CONFORMS=True | `ONTOLOGY_TRIPLES=1272` / `SHAPES=ontology/shapes.ttl` / `CONFORMS=True` | PASS |
| 2 | `./bin/conform-falsify` | 13 refusals | `13 counterexamples refused by the ggen.toml [law] profile` (all 13 lines recorded below) | PASS |
| 3 | `bash priv/ggen/vendor/verify_lock.sh` | OK | `verify_lock: OK (9 packs, lock 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2)` | PASS |
| 4 | extracted `bin/gate` provenance-verify step | GREEN (9 digests) | `provenance-verify: FAIL: 1/9 entr(ies) disagree with priv/ggen/vendor/provenance.ttl:` — `priv/ggen/ash-pplan-runtime-overlay/ontology.ttl: sha256 4ebc042f413067a8baa5a09b97ca5e0cae059ef77f889c93353d9d096d4a48bb != provenance f068abbb434d0f4ac4ae89534c74890f97da44aadfa4e61f58810b5c4de6434b` | **FAIL** |
| 5 | `MIX_BUILD_ROOT=_build-finalconf mix test test/courts/pack_gate_witness_court_test.exs test/courts/pack_gate_mutation_court_test.exs` | 0 failures | `11 tests, 0 failures` | PASS |

## Verbatim outputs

### Check 1 — ./bin/conform

```
ONTOLOGY_TRIPLES=1272
SHAPES=ontology/shapes.ttl
CONFORMS=True
```

### Check 2 — ./bin/conform-falsify

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

13 counterexamples refused by the ggen.toml [law] profile
```

### Check 3 — verify_lock.sh

```
verify_lock: OK (9 packs, lock 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2)
```

### Check 4 — provenance-verify (extracted from bin/gate)

```
verify_lock: OK (9 packs, lock 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2)
provenance-verify: FAIL: 1/9 entr(ies) disagree with priv/ggen/vendor/provenance.ttl:
  priv/ggen/ash-pplan-runtime-overlay/ontology.ttl: sha256 4ebc042f413067a8baa5a09b97ca5e0cae059ef77f889c93353d9d096d4a48bb != provenance f068abbb434d0f4ac4ae89534c74890f97da44aadfa4e61f58810b5c4de6434b
```

Corroborating evidence (check 4 is a real drift, not a lane artifact):

```
$ shasum -a 256 priv/ggen/ash-pplan-runtime-overlay/ontology.ttl
4ebc042f413067a8baa5a09b97ca5e0cae059ef77f889c93353d9d096d4a48bb  priv/ggen/ash-pplan-runtime-overlay/ontology.ttl
$ git status --porcelain priv/ggen/ash-pplan-runtime-overlay/ontology.ttl priv/ggen/vendor/provenance.ttl
 M priv/ggen/vendor/provenance.ttl
?? priv/ggen/ash-pplan-runtime-overlay/ontology.ttl
```

The overlay `ontology.ttl` is a new/untracked file introduced by the placeholder wave; the
modified `provenance.ttl` still records the pre-wave digest. Both of the other 8 entries
verified; the step correctly refused. Fix (out of scope for this read-only lane): update the
`packOntologySha256` for the runtime-overlay entry in `priv/ggen/vendor/provenance.ttl` to
`4ebc042f413067a8baa5a09b97ca5e0cae059ef77f889c93353d9d096d4a48bb`, then re-run.

### Check 5 — court tests

```
Running ExUnit with seed: 222391, max_cases: 32

...........
Finished in 4.6 seconds (0.1s async, 4.4s sync)
11 tests, 0 failures
```

## Standing

4/5 PASS, 1 FAIL. Checks 1, 2, 3, 5 are ALIVE on this exact tree (main @ 37bc291, quiesced).
Check 4 is REFUSED by the court itself: stale provenance digest for the new
`ash-pplan-runtime-overlay` ontology — the placeholder wave shipped a new file without
rolling `provenance.ttl`. No caveat on quiesce (tree was stable). `_build-finalconf`
deleted after the run.
