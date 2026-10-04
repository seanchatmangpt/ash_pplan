# ECO: semantic-gate-witness-court-pack adoption evaluation

- ERRC item 12, first-batch exception (audit: only no-identified-risk adoption
  in the broader marketplace batch).
- Subject: `/Users/sac/ggen-marketplace/packs/semantic-gate-witness-court-pack`
  @ v26.9.30 (read-only, no edits in either repo beyond this doc).
- Date: 2026-10-04.

## Verdict: ADOPT — EXECUTED (2026-10-04)

Adoption is landed. Real subject on disk (differing from the original steps 3–5
below in two ways, both correct):

- Surface: `priv/ggen/semantic-gate-witness/` (one consumer court over the two
  highest-value runtime-overlay gates, not nine pack dirs): `gate-court.toml`,
  `gates/{06-receipt,08-refusal}.rq` (sha256-pinned copies of
  `priv/ggen/ash-pplan-runtime-overlay/gates/`),
  `witnesses/{pass,fail}/{06-receipt,08-refusal}.ttl` (using the gates' real
  `rt:` runtime-overlay vocabulary), `generated/semantic_gate_witness_court.py`
  and `runners/semantic_runner.py` (byte-identical projections of the vendored
  pack templates).
- Qualification court: `test/courts/pack_gate_witness_court_test.exs` (not the
  `semantic_gate_witness_court_test.exs` name below) — ALIVE on seeded
  witnesses, typed `missing_fail`/`missing_pass`/`orphan_fail` refusals on tmp
  copies, deterministic receipts, byte-identity vs the vendored pack.
- NO manufacture recipe: `bin/manufacture-semantic-gate-witness` does not
  exist on purpose — the surface is vendored projections + hand-written
  witnesses, nothing renders from RDF rows. Instead the court RUN is wired as
  a gate step (`bin/gate`, `pack-gate-witness-court`, before ggen-replay-court)
  and observed in `bin/ggen-replay-court --dry-run-preview`.

The audit claim verifies. The pack is real machinery, not a sa2a-style husk:
a 155-line deterministic fail-closed court template, a canonical rdflib
runner, a contract test enforcing byte-identical runner projections, and 18
configured consumer courts across the marketplace. It closes a hole ash_pplan
actually has: no ash_pplan gate today is ever shown to REFUSE anything.

## What the pack generates

- `generated/semantic_gate_witness_court.py` (from
  `templates/semantic-gate-witness-court.py.tera`) — an engine-agnostic court
  that:
  - pairs `gates/<case>.rq|.sparql` with `witnesses/pass/<case>.*` and
    `witnesses/fail/<case>.*` by exact filename stem;
  - refuses (exit 1, `standing: REFUSED`) on: missing config, wrong schema,
    non-exact-stem case key, duplicate gate stems, orphan pass/fail witnesses,
    missing pass witnesses (require_pass), missing fail witnesses
    (require_fail), empty gate dir, and any runner refusal;
  - runs the optional runner shell-free with `{root} {gate} {witness}
    {expectation}` placeholders;
  - emits deterministic sorted-key JSON with sha256 identities for every gate
    and witness (replayable receipt, `R_missing_replay`-clean).
- `runners/semantic_runner.py` — consumer-local byte-identical projection of
  `templates/semantic-runner.py.tera` (rdflib adapter; judges each gate's ASK
  against witnesses under an exactly-one-gate-fires law).

## Admission-vacuity check it embeds

Structural non-vacuity is the court's own law, not delegated: missing or
orphan witnesses refuse outright, so a gate with no observable positive and
negative evidence cannot be admitted. `require_fail = true` makes a negative
witness mandatory per gate — this is the generation-time kill of
`admission_vacuous`: a gate that cannot refuse is refused.

## Map onto ash_pplan's existing surfaces

- `priv/ggen/*/gates/*.rq` — 40 gate files across 9 packs. Executed by
  `bin/ggen-verify` via `ggen verify`: a gate that returns zero rows fails
  (`gate_failed`). That is positive firing only. No gate has negative
  witnesses anywhere in the tree (`find priv/ggen -path "*witness*"` is empty).
- `bin/conform` + `bin/conform-falsify` — 13 mutations prove `ontology/
  shapes.ttl` (the SHACL profile) refuses. Crucially different subject: this
  kills vacuity for the SHACL profile over `ontology.ttl`, NOT for the per-pack
  SPARQL gates. A gate query whose ASK pattern is unsatisfiable (or tautology)
  against the pack ontology passes `ggen-verify` today iff it happens to
  return rows; nothing proves it rejects a counterexample.
- `test/courts/` — hand-written ExUnit courts, per-feature, no per-gate
  witness correspondence law.
- Landing spot: `priv/ggen/<pack>/gate-court.toml` +
  `priv/ggen/<pack>/witnesses/{pass,fail}/<stem>.*` per pack; court receipt
  emitted to the same surface as `bin/ggen-verify` output; wired into
  `bin/gate` after the ggen-verify step.

## What it ADDS over conform-falsify's 13 counterexamples

1. Different subject. conform-falsify falsifies the SHACL profile; the pack
   falsifies each `gates/*.rq` file. Disjoint surfaces, both needed.
2. Negative witnesses per gate. conform-fail handles the ontology once; the
   pack requires, per gate, a witness that must be refused. Today zero of the
   40 gates carry a negative witness.
3. Coverage completeness fail-closed: missing/orphan witnesses refuse, so the
   court cannot pass while a gate silently has no evidence. conform-falsify
   has no coverage law — it proves the 13 named mutations refuse, nothing
   about gates added later.
4. Deterministic sha256 receipts per gate/witness — replayable qualification
   receipts, which conform-falsify does not emit.

## Vocabulary reconciliation

Minimal. `sgwc:` is self-contained and the court is file-walking, not
graph-merging: no graph-level prefix mapping is required. Needed only:
- `gate-court.toml` per pack declaring schema `ggen.semantic-gate-witness-court/1`,
  `case_key = "exact-stem"`, dirs, `require_fail = true`.
- Gate files keep their existing `PREFIX` blocks; the canonical runner
  executes gates as-is against witness graphs (witness TTLs must use the
  gates' real runtime-overlay vocabulary — `rt:`
  `https://ggen.dev/ontology/runtime-integration#` — because the gates ASK
  over `rt:` terms; `ap:` witnesses would make every gate vacuously return
  zero rows, so a "fail" witness would refuse for the wrong reason and a
  "pass" witness would not exercise the gate at all).
- One decision: gate stems across the 9 packs must be unique per pack (they
  are; duplicates are refused within a pack by the court).

## Adoption steps (ADOPT)

1. Vendor: add the pack to `priv/ggen/vendor/sync.sh` pack list at the pinned
   marketplace sha (same lane as ash-pplan-protocol-court-pack, precedent in
   `priv/ggen/vendor/PACKS.lock.json` + `provenance.ttl`).
2. `ggen.toml`: add
   `[packs.semantic-gate-witness]` path = "priv/ggen/vendor/semantic-gate-witness-court-pack"
3. Manufacture: run sync.sh, then
   `bin/manufacture-semantic-gate-witness` (mirror of
   `bin/manufacture-protocol-court`) rendering the court + canonical runner
   into the nine `priv/ggen/ash-pplan-*-pack/` dirs (runner as byte-identical
   projection; contract test guards it).
4. Seed evidence: start with the highest-value gate,
   `priv/ggen/ash-pplan-runtime-overlay/gates/06-receipt.rq`, plus
   `08-refusal.rq`: write one pass and one fail witness each (TTL using
   `ap:`/`p-plan:`), `require_fail = true`.
5. Court to prove it (falsifier, Chicago-style, real state):
   `test/courts/semantic_gate_witness_court_test.exs`:
   - court passes on the seeded witnesses (exit 0, ALIVE receipt);
   - mutate a fail witness into the pass dir (orphan fail) → court refuses
     (exit 1);
   - delete a fail witness → missing_fail refuses;
   - runner given a pass witness with expectation "fail" → runner_refusal.
   Wire the court into `bin/gate` after ggen-verify.

## Falsifier that would have killed it (had it fired)

Rendering the court and pointing it at an ash_pplan pack produced court_error
on ash_pplan's gate layout (e.g. numeric-prefix stems colliding with witness
stems, or the runner failing to load `ap:` witnesses) — it did not fire: the
court is layout-agnostic (exact-stem over any dirs the toml names) and the
runner is engine-side (rdflib parses any TTL). Confirmed by reading
`_group_by_stem`/`qualify` in the template: no ash_pplan-specific assumption
is violated by the layout.

## Evidence files

- Pack: pack.toml, ggen.toml, ontology.ttl, README.md, gates/01-court-contract.rq,
  queries/10-court.rq, templates/semantic-gate-witness-court.py.tera,
  templates/semantic-runner.py.tera, tests/test_contract.py
- ash_pplan: bin/conform, bin/conform-falsify (13 mutations), bin/gate,
  bin/ggen-verify, priv/ggen/*/gates/ (40 files, 9 packs), priv/ggen/vendor/sync.sh,
  ggen.toml [packs] table (protocol-court precedent)
