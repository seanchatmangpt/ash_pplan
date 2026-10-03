# Cross-repo vocabulary: OCEL, receipts, and SA2A

ash_pplan is one node in a fleet of repos that all emit OCEL events and
receipts. Three audits (2026-10-03) asked whether the fleet speaks one
vocabulary or four; this page records the verdicts and what they mean for
ash_pplan. The full inventories are the sources for every claim here:

- `notes/ocel-vocabulary-audit-2026-10-03.md` — 4-repo OCEL surface inventory
  (sha256 `3d594fb1…73ce`)
- `notes/receipt-schema-diff-2026-10-03.md` — receipt schema diff, ggen
  family vs ash_pplan vs DfCM v2 (sha256 `8fadc59a…1d47`)
- `notes/sa2a-adapter-verdict-2026-10-03.md` — sa2a adapter-vs-fork verdict
  (sha256 `5b6be557…642`)

## OCEL: four dialects, xaas owns the kernel

Four repos emit OCEL events — ash_pplan, xaas, beam4pm, wasm4pm — and the
audit found **four divergent vocabularies**, not one. The note's comparison
matrix maps every dimension (struct fields, envelope keys, qualifier
handling, event-type catalogs, time semantics, identifier schemes, gating);
the short version:

1. **Three envelope dialects.** ash_pplan and beam4pm emit spec-shaped
   `objectTypes`/`eventTypes` declarations (`[{"name":..., ...}]`); xaas
   emits bare `[string]` arrays; wasm4pm is snake_case (`object_types`).
   beam4pm's entities use `event_id`/`event_time` where spec says
   `id`/`time`, and wasm4pm folds E2O relations into unqualified `o2o` pairs
   — the per-relation qualifier is lost.
2. **Attribute envelope differs four ways**: ash_pplan flattens to
   `[{name, value}]` (all string-typed, `inspect` fallback); xaas emits a
   raw map; beam4pm is spec-shaped; wasm4pm uses a
   `BTreeMap<String, serde_json::Value>`.
3. **Four disjoint event-type catalogs.** snake_case workflow verbs
   (ash_pplan), a generated PascalCase agent-session catalog (xaas), per-log
   declaration (beam4pm), breed-lifecycle kinds (wasm4pm). Zero overlap.
4. **Intra-repo drift already exists.** wasm4pm carries four separate
   `OcelEvent` structs (cognition, `sa2a/ocel.rs`, testing, sa2a-actuator) —
   the N² drift the COMBINE map item warns about has already happened inside
   a single repo.

**Verdict: xaas's `Xaas.Ocel` domain (`lib/xaas/ocel/*`) should own the
canonical OCEL vocabulary + persistence kernel.** It is the only admitted,
transactional, persistence-backed kernel with a non-empty-relationship
admission gate (`RelateEventToObjects`) and spec-named top-level keys. The
shape: canonical envelope = OCEL 2.0 JSON with spec-shaped declarations —
fix xaas's bare-array dialect toward the ash_pplan shape, since ash_pplan's
`ProcessEvidence.export/2` (`lib/ash_pplan/process_evidence.ex`) is already
the closest-to-spec envelope in the fleet — generate each repo's event
registry from one RDF ontology (extending xaas's generated
`zcode_event_registry.ex` pattern), and keep consumers as thin
adapters/projections (`LedgerOCEL` here, beam4pm's ingest, wasm4pm's
cognition layer). wasm4pm's determinism profile (epoch + `logical_step`, no
wall clock) is a profile flag, not a fork. Before any fleet unification,
wasm4pm should collapse its four OcelEvent structs.

## Receipts: ggen portable is the canonical evidence envelope; DfCM v2 is the canonical R vocabulary

Nine receipt implementations across the ggen family and ash_pplan were
compared field-by-field; the note's table maps every concept (identity,
authority, consequence, replay, standing, time, hashing) to each
implementation's field. The headline divergences:

- **Standing vocabularies split three ways.** ggen portable's §82
  three-value enum (`ALIVE`/`PARTIAL_ALIVE`/`REFUSED:<code>`), ggen_igniter's
  incompatible five-atom set (`compensated`/`compensation_failed` have no
  equivalent anywhere else), and the seven-value open-suffix vocabulary
  shared by ash_pplan (`AshPPlan.Standing.Receipt`) and DfCM v2. `REFUSED`
  renders three ways: colon (ggen), parens (ash_pplan/DfCM), bare atom
  (ggen_igniter). Any cross-consumer court is blocked by this alone.
- **Authority is a first-class validated field in only two.** Only
  `AshPPlan.Standing.Receipt` and DfCM v2 carry
  `authority{actor, ceiling, grant}` with a typed refusal of DO
  (`R_missing_authority`). ggen's envelope explicitly disclaims authority
  yet has no authority field at all, so an envelope cannot name what
  authority a run acted under.
- **Four hashing schemes, three chain constructions, four units of
  account.** BLAKE3 record chain (ggen legacy), per-recipe pre/post-run-hash
  continuity walk (ggen_igniter), sha256 genesis-seeded event ledger with
  pending/outcome/seal (ash_pplan `Standing.Chain`). No cross-implementation
  verifier exists for any of the three. ggen portable has no time field;
  only ggen_igniter self-hashes the receipt (`receipt_hash` over key-sorted
  JSON minus the hash key). Same word "receipt", four units of account:
  per-sync, per-attempt-per-recipe, per-Reactor-run observation
  (`AshPPlan.ExecutionReceipt`), per-work-order execution.

**Verdict.** DfCM v2 (`~/.claude/dfcm/receipt.schema.json`,
`https://chatmangpt.com/schema/receipt/v2`) is the canonical **R vocabulary**
— the only schema with all five required fields (identity, authority,
consequence, replay, standing), the ceiling enum, the `broken_term` enum, and
the §82 standing regex. **ggen's portable envelope
(`crates/ggen-engine/src/portable_receipt.rs`) is the canonical
evidence/consequence format** — bounded environment digest, toolchain
identity, dependency closure, fail-closed per-consequence re-hashing — whose
`standing` field is what to remap, not the envelope shape.
`AshPPlan.Standing.Receipt` (`lib/ash_pplan/standing/receipt.ex`) is the
closest executable projection of DfCM v2 — it validates against the same
five-field shape and standing regex, and is generated from the standing
ontology (`ggen_igniter` pack `ash-pplan-standing-pack/ontology.ttl`), not
hand-written. ash_pplan keeps the five-field `R_missing_*` validation and the
authority-ceiling check local (no ggen-family schema has them — that is the
load-bearing ontology fact; see
[Standing, receipts, and the ladder](standing-receipts-and-the-ladder.md)),
maps its standing values into the DfCM/§82 vocabulary at the boundary, and
treats the ggen portable envelope as the target shape when emitting
cross-repo evidence.

## SA2A: adapter, not fork

`lib/ash_pplan/sa2a/` is six modules, 199 LOC (verified: `capability`,
`policy_candidate`, `provider`, `refusal`, `replay`, `subject_guard`).
Verdict: **a consumer adapter, not a fork of the ash_a2a kernel.** It
re-implements none of the kernel's logic — no replan loop, attempt budget,
provider selection/exclusion, candidate normalization, or `:replan_*`
refusal vocabulary. It projects owner-side manufacture (`AshPPlan.select_policy/3`,
`AshPPlan.plan/1`, `AshPPlan.FOND.Replay`) into the shape ash_a2a's
`Replan.Provider` behaviour expects and preserves subject identity across
the boundary. Its refusal codes are owner-side by design
(`missing_subject`, `unsupported_formalism`, `planner_refused`, …) and
deliberately disjoint from ash_a2a's consumer codes (`replan_subject_drift`,
…) — same `%{code, detail, authority: :none}` shape.

Coupling is one-directional: ash_a2a's port
(`AshA2A.Replan.Port.AshPPlan`) calls INTO the adapter and delegates as its
`@owner_provider`; the adapter never calls ash_a2a (`AshA2A` appears exactly
once in `lib/` — a moduledoc line in `provider.ex`). Kernel evolution cannot
be drifted against in the loop/budget/refusal axes. `authority: :none` /
`standing: :candidate` holds in every success shape across all six modules.

One watch item, not drift: the `supports?/1` formalism list
(`[:fond, :powl]`) is duplicated — `AshPPlan.SA2A.Capability.supported/0`
and the consumer port's hardcoded `AshA2A.Replan.Port.AshPPlan.supports?/1`.
If the owner adds a formalism, the consumer's hardcoded list must move to
owner capability discovery or it silently narrows the surface. No re-point
needed: the adapter is at the correct altitude.

## Where this leaves ash_pplan

- OCEL: keep `ProcessEvidence.export/2` as the closest-to-spec envelope;
  expect the xaas kernel to converge its bare-array dialect toward it, with
  ash_pplan's `LedgerOCEL` staying a thin projection — see
  [Process evidence and OCEL](process-evidence-and-ocel.md).
- Receipts: keep `Standing.Receipt`'s five-field validation and authority
  ceiling local; treat DfCM v2 as the standing vocabulary and the ggen
  portable envelope as the evidence shape when emitting cross-repo receipts.
- SA2A: no action beyond watching the duplicated `supports?/1` formalism
  list.
