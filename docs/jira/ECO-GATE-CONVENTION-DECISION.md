# ECO-GATE-CONVENTION-DECISION — OFFENDER vs WITNESS gate scoring convention

Status: DECIDED (R0, delta-ERRC 2026-10-04). Supersedes the
"documented for maintainers, not decided" status in
`docs/jira/ECO-UPSTREAM-IGNITER-FIXES.md` Item 3.
Scope: all `priv/ggen/*/gates/*.rq` and `priv/ggen/*/verify/*.unbound.rq`
across the ash_pplan corpus and its vendored packs, plus the
`GgenIgniter.GateVerify` scoring in `/Users/sac/ggen_igniter`.
Companion doc (ggen_igniter side, docstring/PR text):
`/Users/sac/ggen_igniter/docs/architecture/adr/0010-gate-convention-directory-is-convention.md`.

## Decision

**Option A — directory-is-convention — adopted now.** Option B (per-gate
`"mode"` flag in cardinality.json) is deferred until DERIVED_ROWS mode
proves out. Nothing in this decision changes any scoring behavior anywhere;
the existing empirical split becomes the written convention:

- `gates/*.rq` — **witness-reporting**: the query's rows are witnesses the
  ontology must produce. **>= 1 row = PASS**, 0 rows = FAIL. This is
  `GgenIgniter.GateVerify.run/2`'s scoring, driven by the `gates/*.rq` glob
  in `GgenIgniter.Pack.discover_queries/1`.
- `verify/*.unbound.rq` — **offender-reporting**: the query's rows are
  violations it surfaces. **0 rows = PASS**, >= 1 row = FAIL. Scored by
  `mix ggen_igniter.verify` via the pack's `verify/cardinality.json`
  contract, not by GateVerify.

A gate query's scoring is determined solely by which directory it ships in.
A new gate must ship on the side matching its scoring. No per-gate type is
declared, no flag, no metadata — the directory is the only signal (which is
also exactly why the residual hole below exists).

## Rationale

1. **The convention is named, not imposed.** It is what the corpus already
   does. Every contract-bearing pack ships mirrored witness gates +
   offender companions (`verify/100_task_props.unbound.rq` states "ZERO
   ROWS IS THE PASS CONDITION" in its own header). The split is already
   load-bearing across 9 packs; this decision writes it down.
2. **Zero behavioral blast radius.** Option B touches
   `GateVerify.load_cardinality/1`, `GateVerify.run/2` (per-flag
   inversion), every shipped `verify/cardinality.json`, the verify task's
   envelope (per-gate mode echo), and every ecosystem pack authored against
   the >= 1-row default. Option A touches zero code and zero pack files.
3. **Option A promotes cleanly to Option B.** Nothing here blocks the
   per-gate `"mode"` flag. When DERIVED_ROWS proves out, the flag becomes
   the mechanism with the directory as the default and witness as the
   flag-default — preserving the >= 1-row default for packs that ship no
   contract file, the exact guard the upstream analysis required of B.

## Blast radius comparison

| Dimension | Option A (adopted) | Option B (deferred) |
|---|---|---|
| Code | none | `GateVerify.load_cardinality/1`, `GateVerify.run/2` inversion, verify-task envelope |
| Pack files | none | cardinality.json in all 9 contract-bearing packs, `test/fixtures/ash_manufacture_pack/verify/cardinality.json`, every ecosystem pack using the >= 1-row default |
| Behavior change | none | per-gate inversion; envelope gains per-gate `mode` echo |
| Closes "offender query in gates/ fails open" | no (mitigated, below) | yes |
| Promotable to B later | yes | n/a |

## Inventory (real counts, 2026-10-04)

Counted from `priv/ggen/` and `priv/ggen/vendor/`:

| pack | gates/ | verify/ unbound | cardinality.json |
|---|---|---|---|
| ash-pplan-dsl-pack | 4 | 4 | yes |
| ash-pplan-durable-chaos-pack | 2 | 2 | yes |
| ash-pplan-durable-tla-pack | 5 | 5 | yes |
| ash-pplan-igniter-pack | 2 | 0 | no |
| ash-pplan-pack | 3 | 3 | yes |
| ash-pplan-reactor-mw-pack | 1 | 0 | no |
| ash-pplan-runtime-overlay | 10 | 0 | no |
| ash-pplan-standing-pack | 7 | 14 | yes |
| ash-pplan-store-conformance-pack | 3 | 3 | yes |
| ash-pplan-workflow-pack | 15 | 15 | yes |
| semantic-gate-witness | 2 | 0 | no |
| vendor/ash-extension-core-pack | 5 | 0 | no |
| vendor/ash-pplan-chaos-pack | 3 | 3 | yes |
| vendor/ash-pplan-protocol-court-pack | 7 | 7 | yes |
| vendor/evidence-standing-pack | 8 | 0 | no |
| vendor/semantic-gate-witness-court-pack | 1 | 0 | no |
| vendor/state-transition-pack | 5 | 0 | no |
| vendor/tokyo-depeg-burn-in-pack | 10 | 10 | yes |
| vendor/workflow-corpus-pack | 18 | 0 | no |

Totals: 111 `gates/` entries, 66 `verify/*.unbound.rq` companions,
10 contract-bearing packs (dsl, durable-chaos, durable-tla, ash-pplan,
standing, store-conformance, workflow, vendor/chaos, vendor/protocol-court,
vendor/tokyo).

## What Option A does NOT fix

**The fail-open hole stays open.** An offender-reporting query shipped under
`gates/` scores `:pass` exactly when the ontology is broken (row found =
"pass" for a violation-surfacer) and `:fail` when the ontology is clean.
The directory split is enforced only by the `Pack.discover_queries/1` glob;
nothing types a gate, so misfiling is silent. This is not hypothetical —
several `gates/` queries are offender-shaped today:

- `vendor/evidence-standing-pack/gates/` — all 8 entries are
  offender-shaped ("Each row names the offending standing claim..." per
  their own headers): 010_no_receipt_no_standing, 020_seal_once,
  030_parent_hash_closure, 040_algorithm_supported_set, 050_literal_scan.py,
  060_outcome_requires_pending, 065_standing_only_on_outcome,
  070_unpaired_pending.
- `vendor/state-transition-pack/gates/010_no_skipping_executed.rq`,
  `020_no_skipped_transitions.rq` — offender-shaped by name and semantics.

Under the adopted convention these score inverted under GateVerify. They
survive today only because of the mitigations below.

**Mitigations (cited):**

- **Mutation courts** — `priv/ggen/vendor/workflow-corpus-pack`
  (f-series acceptance queries + `qualification/verify.py`): every
  acceptance query must fail on the `witnesses/fail/` fixture, so an
  offender query scoring inverted kills the court run, not the violation,
  and the court kills the query.
- **G1 pack courts** — the 10 contract-bearing packs' cardinality.json +
  `verify/*.unbound.rq` scored 0-rows-pass by `mix ggen_igniter.verify`
  (see `lib/mix/tasks/ggen_igniter.verify.ex` moduledoc for the measured
  Book/BookResource and amp:evidence fail-open examples). The v26.10.3
  court fixes in `bin/case-study` / `bin/gate` (commit `b1d84f3`: fence-aware
  courts, template skip, receipts-citation) closed court defects found in
  that cycle.

## Migration table (witness- vs offender-shaped today)

Classification is by query semantics (rows = evidence → witness; rows =
violations surfaced → offender), not by directory. The risky class is
offender-shaped queries in `gates/` (fail-open under GateVerify).

### Offender-shaped queries currently in `gates/` (fail open today)

| location | count | examples |
|---|---|---|
| `vendor/evidence-standing-pack/gates/` | 8 | 010_no_receipt_no_standing, 020_seal_once, 030_parent_hash_closure, 040_algorithm_supported_set, 050_literal_scan.py, 060_outcome_requires_pending, 065_standing_only_on_outcome, 070_unpaired_pending |
| `vendor/state-transition-pack/gates/` | 3 | 010_no_skipping_executed, 020_no_skipped_transitions, 050_template_literal_scan.py — offender-shaped by name/semantics; 030_reachable_states and 040_chain_policy_supported are witness-shaped |

### Witness-shaped in `gates/` (correct per convention)

The mirrored `gates/*.rq` of the 10 contract-bearing packs (dsl 4,
durable-chaos 2, durable-tla 5, ash-pplan 3, standing 7, store-conformance 3,
workflow 15, vendor chaos 3, vendor protocol-court 7, vendor tokyo 10) plus
the gates-only witness packs: igniter 2, reactor-mw 1, runtime-overlay 10,
semantic-gate-witness 2, vendor ash-extension-core 5, vendor
semantic-gate-witness-court 1, vendor workflow-corpus 18.

### Correctly filed offenders in `verify/` (scored inverted by the verify task)

The 66 `verify/*.unbound.rq` companions across the 10 contract-bearing packs.

## Migration (P1, not this lane)

Re-homing the misfiled offenders is behavior-preserving only if scoring
flips at the same commit. Flipping the directory alone would change the
verdict: an offender query in `gates/` scored witness-style is currently
inverted; moving it to `verify/` without a contract wiring leaves it
unscored. Safe sequence per pack, one commit:

1. Write the `verify/cardinality.json` contract entries.
2. Re-home the query to `verify/*.unbound.rq` in the same commit.

Alternative: leave files where they are and let Option B's
`"mode": "offender"` flag adopt them without file moves. Both paths are open after this decision; Option B is deferred until
DERIVED_ROWS mode proves out.

## Reproduction

```sh
cd /Users/sac/ash_pplan/priv/ggen && for d in */ vendor/*/; do
  g=$(ls "$d/gates" 2>/dev/null | wc -l | tr -d ' ')
  v=$(ls "$d/verify" 2>/dev/null | grep -c 'unbound.rq')
  c=$(test -f "$d/verify/cardinality.json" && echo yes || echo no)
  [ "$g" != "0" -o "$v" != "0" ] && echo "$d gates=$g verify_unbound=$v cardinality=$c"
done
```
