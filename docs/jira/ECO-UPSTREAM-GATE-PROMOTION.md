# ECO Upstream Gate Promotion (ERRC E1, upstream half)

- Date: 2026-10-04
- Repo: /Users/sac/ggen-marketplace
- Branch: `errc-promote-engine-compat-gates` (local only, no push) off `main` @ `503af6c27cef7838dcd82755ab2fe6a44f9eb6a2`
- Commit: `a1c3de3cd4115521cf9005fa5daf4679a7ba287c`
- Consumer-side lane doc: (ERRC E1 consumer-half receipt pending — this file is the upstream-half receipt)

## Root cause

`sparql.ex 0.3.12` never implemented `EXISTS`/`NOT EXISTS`: its translator
leaves a `:not_exists` atom that crashes as `:"$undefined"` in
`SPARQL.Algebra.Filter`. The vendor overlay in
`priv/ggen/vendor/{state-transition-pack,evidence-standing-pack}/gates/`
carried LOCAL ENGINE-COMPAT REWRITE provenance comments documenting the
workaround rewrites, while upstream still shipped the crashing forms.

## Changes (commit a1c3de3cd, 8 files, +13/-11)

| File (under `packs/`) | Change |
|---|---|
| state-transition-pack/gates/010_no_skipping_executed.rq | `FILTER NOT EXISTS {…}` → `MINUS {…}` |
| state-transition-pack/gates/030_reachable_states.rq | `FILTER NOT EXISTS` → `MINUS` |
| state-transition-pack/gates/040_chain_policy_supported.rq | two `FILTER NOT EXISTS` → `MINUS` (one has nested FILTER, supported inside MINUS) |
| evidence-standing-pack/gates/010_no_receipt_no_standing.rq | `FILTER NOT EXISTS` → `MINUS` |
| evidence-standing-pack/gates/040_algorithm_supported_set.rq | `FILTER NOT EXISTS` → `MINUS` |
| evidence-standing-pack/gates/060_outcome_requires_pending.rq | `FILTER NOT EXISTS { ?entry es:isSeal true }` → `OPTIONAL { ?entry es:isSeal ?seal } FILTER(!BOUND(?seal))`; `EXISTS{…}` in IF expression → `OPTIONAL { … BIND(true AS ?reqFlag) } + BOUND(?reqFlag)` |
| evidence-standing-pack/gates/065_standing_only_on_outcome.rq | `FILTER NOT EXISTS` → `MINUS` |
| evidence-standing-pack/gates/070_unpaired_pending.rq | two `FILTER NOT EXISTS` → `MINUS` |

## Validation

- rdflib 7.6.0 `prepareQuery` parse: **11/11 PASS** (all .rq in both packs'
  `gates/`, including the 8 rewritten).
- Equivalence justification (from the vendor provenance comments): the MINUS
  forms are algebraically equivalent to `FILTER NOT EXISTS` because in every
  rewritten pattern all shared variables are triple-bound, so no value is
  subtracted that the NOT EXISTS form would have kept. The 060 OPTIONAL+BOUND
  probe handles the cases MINUS cannot express (EXISTS-in-expression, negation
  over a possibly-unbound var).
- No pack gates runner/verify script exists in ggen-marketplace for these two
  packs (`packs/*/qualification/` and `packs/*/gates/` have no runner); rdflib
  parse is the strongest available read-only check here.
- No EXISTS / no LOCAL ENGINE-COMPAT comment residue in the rewritten files
  (grep verified).

## Vendor-side retirement steps (after this branch merges upstream)

1. Merge PR from `errc-promote-engine-compat-gates` into ggen-marketplace main.
2. In ash_pplan, re-pin the two packs in `priv/ggen/vendor/PACKS.lock.json` to
   the post-merge upstream SHAs.
3. Re-sync via `priv/ggen/vendor/sync.sh` (or equivalent re-vendor flow).
4. Delete the LOCAL ENGINE-COMPAT REWRITE blocks from the vendored gate files
   (the sync will overwrite them; do not re-apply).
5. Verify the vendor overlay returns to 269/269 sha256 match against
   PACKS.lock.json.
6. Run the ash_pplan gate suite (269 gates) to confirm the vendored copies
   still gate identically under sparql.ex 0.3.12 — the rewrites are now
   upstream, so gates fail closed the same way without the overlay patches.

## OPEN decision (flagged by the verify lane): offender-reporting vs witness-reporting gate convention

`GgenIgniter.GateVerify` treats a gate as PASSING at >= 1 row returned
(offender-reporting: rows = violations, 0 rows = clean). These two packs emit
0 rows when clean (witness-reporting: rows = conformant witnesses, 0 rows =
clean, and 0 rows is also indistinguishable from a broken gate). The promoted
gates are written offender-style (`SELECT ?entry ?reason` naming offending
individuals), but the 0-row convention means a trivially-empty graph passes
vacuously.

The PR should include or reference this decision before merge: pick one
convention across the ecosystem, or make `GateVerify` convention-aware. Until
resolved, the vendored gates' clean-run behavior differs from what
`GgenIgniter.GateVerify` expects.

## P2 (delta-ERRC C2, 2026-10-04): fail witnesses must ride the promotion branch

Neither vendored pack shipped a `witnesses/` dir, so a renamed predicate
passes every gate forever with 0 rows — the vacuous-pass channel this file's
OPEN decision describes. Both packs now carry per-gate fail (>= 1 row) and
clean pass (0 rows) witnesses under the exact-stem pairing convention from
`priv/ggen/semantic-gate-witness/gate-court.toml`
(`witnesses/pass/<gate-stem>.ttl`, `witnesses/fail/<gate-stem>.ttl`). All 11
`.rq` gates validated both ways via `GgenIgniter.Query.Oxigraph`:
pass -> 0 rows, fail -> 1 row, per gate, on 2026-10-04.

Copy these exact files into the promotion branch (same relative paths under
the pack roots upstream):

```
state-transition-pack/witnesses/pass/010_no_skipping_executed.ttl
state-transition-pack/witnesses/fail/010_no_skipping_executed.ttl
state-transition-pack/witnesses/pass/020_no_skipped_transitions.ttl
state-transition-pack/witnesses/fail/020_no_skipped_transitions.ttl
state-transition-pack/witnesses/pass/030_reachable_states.ttl
state-transition-pack/witnesses/fail/030_reachable_states.ttl
state-transition-pack/witnesses/pass/040_chain_policy_supported.ttl
state-transition-pack/witnesses/fail/040_chain_policy_supported.ttl
evidence-standing-pack/witnesses/pass/010_no_receipt_no_standing.ttl
evidence-standing-pack/witnesses/fail/010_no_receipt_no_standing.ttl
evidence-standing-pack/witnesses/pass/020_seal_once.ttl
evidence-standing-pack/witnesses/fail/020_seal_once.ttl
evidence-standing-pack/witnesses/pass/030_parent_hash_closure.ttl
evidence-standing-pack/witnesses/fail/030_parent_hash_closure.ttl
evidence-standing-pack/witnesses/pass/040_algorithm_supported_set.ttl
evidence-standing-pack/witnesses/fail/040_algorithm_supported_set.ttl
evidence-standing-pack/witnesses/pass/060_outcome_requires_pending.ttl
evidence-standing-pack/witnesses/fail/060_outcome_requires_pending.ttl
evidence-standing-pack/witnesses/pass/065_standing_only_on_outcome.ttl
evidence-standing-pack/witnesses/fail/065_standing_only_on_outcome.ttl
evidence-standing-pack/witnesses/pass/070_unpaired_pending.ttl
evidence-standing-pack/witnesses/fail/070_unpaired_pending.ttl
```

(Paths above are relative to the pack root; locally they live under
`priv/ggen/vendor/<pack>/witnesses/{pass,fail}/<gate-stem>.ttl`.) No gate or
verify query was modified; witnesses are additive-only. Upstream CI should
run each `gates/*.rq` against its paired pass witness (expect 0 rows) and
fail witness (expect >= 1 row) — the `.py` literal-scan gates (050) have no
witness pairing by convention.

## R0 re-home mirrored upstream (2026-10-04)

- Branch: `errc-promote-engine-compat-gates` @ `c76220c2a` (local only, no push;
  parent `a1c3de3cd`)
- Mirrors the in-tree R0 re-home (directory-is-convention, ADR 0010): offender
  gates move `gates/` -> `verify/*.unbound.rq` in both upstream packs, so the
  branch merge cannot revert the convention that the vendor overlay now ships.

| Pack | Move | Stays in `gates/` |
|---|---|---|
| state-transition-pack | `010_no_skipping_executed.rq`, `020_no_skipped_transitions.rq` -> `verify/*.unbound.rq`; `050_template_literal_scan.py` -> `verify/` | `030_reachable_states.rq`, `040_chain_policy_supported.rq` |
| evidence-standing-pack | all 8 `gates/*.rq` -> `verify/*.unbound.rq`; `050_literal_scan.py` -> `verify/` (pack ships no witness gates; `gates/` empty) | — |

- `verify/cardinality.json` added to both packs, copied verbatim from the
  in-tree vendor copies (empty `gates` map + full decision note, including the
  state-transition DRIFT row for 030/040's legitimately-empty witness sets).
- `witnesses/{pass,fail}/` trees ported from the vendor overlay: 22 files
  (state 4+4, evidence 7+7), exact-stem pairing per `gate-court.toml`.
- Query bodies untouched in this commit — 100% renames; the MINUS/OPTIONAL
  engine-compat rewrites from `a1c3de3cd` carry through unchanged.

Validation (rdflib 7.x, this lane, upstream tree):

- `prepareQuery` parse: 11/11 `.rq` PASS (9 re-homed `verify/*.unbound.rq` +
  the 2 remaining `gates/` witness gates).
- Both-way witness runs: 22/22 PASS — every gate against its pass witness
  returns 0 rows and against its fail witness returns 1 row, including gates
  030/040 (which the shipped-graph DRIFT row describes, but whose witness
  pairs are well-formed).
- Remaining gap unchanged: ggen-marketplace has no GateVerify/verify_unbound
  runner for these packs, so rdflib remains the strongest available upstream
  check; the Elixir-side court enforcement lives in ash_pplan
  (`pack_state_transition_court_test.exs`, `standing_parity_court_test.exs`).

Post-merge, the vendor-side retirement steps above apply unchanged: re-pin
`PACKS.lock.json`, re-sync, and the vendored overlays should then match
upstream layout (verify/ + witnesses/) with no local rewrites to strip.
