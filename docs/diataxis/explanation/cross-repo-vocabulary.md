# Cross-repo vocabulary: OCEL, receipts, and SA2A

ash_pplan is one node in a fleet of repos that all emit OCEL events and
receipts. Three audits (2026-10-03) asked whether the fleet speaks one
vocabulary or four; this page records the verdicts and what they mean for
ash_pplan. Full inventories live in the notes:

- `notes/ocel-vocabulary-audit-2026-10-03.md` — 4-repo OCEL surface inventory
- `notes/receipt-schema-diff-2026-10-03.md` — receipt schema diff, ggen family
  vs ash_pplan
- `notes/sa2a-adapter-verdict-2026-10-03.md` — sa2a adapter-vs-fork verdict

## OCEL: ex4pm should own the vocabulary

Four repos emit OCEL events (ash_pplan, xaas, beam4pm, wasm4pm) plus ex4pm,
the shared Hex dependency. The audits found four dialects:

1. **Envelope namespace split.** xaas emits `ocel:`-prefixed top-level keys
   (spec-correct); ash_pplan and beam4pm emit unprefixed
   `objectTypes/eventTypes/objects/events`. ash_pplan's form matches the OCEL
   2.0 JSON *file* schema, but beam4pm's entity keys (`event_id`/`event_time`
   vs `id`/`time`) violate both dialects — three spellings of "OCEL 2.0 JSON"
   exist in the fleet.
2. **No shared internal event type.** Struct fields differ everywhere
   (`activity` vs `event_type` vs flat Rust fields). Only ex4pm's normalizer
   (`Ex4pm.OCEL.normalize_event/2`) accepts every historical alias
   (`ocel:eid`/`id`, `activity`/`type`, `timestamp`/`time`), and nothing
   consumes it as the canonical vocabulary.
3. **Time law in exactly one repo.** Only xaas enforces ISO8601 zero-offset.
   ash_pplan emits export-time stamps (the honesty note in the
   [`LedgerOCEL`](process-evidence-and-ocel.md) module doc); beam4pm and
   wasm4pm have no time field or no law.
4. **One court, four producers.** Only xaas has a strict closed-vocabulary
   conformance court (`Xaas.Ultracode.Ocel.Validator`) — and it lives in an
   application, not the shared dep. beam4pm's encoder also silently drops
   relationships that its own validator checks.

**Verdict: the OCEL vocabulary should be owned by ex4pm.** It is already the
shared Hex dep (ash_pplan's deps just moved to a Hex pin, commit `dbeddf6`),
the only module that already normalizes all aliases, and dependency-free
relative to its consumers. The shape: promote the vocabulary into ex4pm (e.g.
`Ex4pm.OCEL.Vocabulary`), upstream xaas's validator into ex4pm so the court
and the vocabulary live in the same repo, Elixir repos consume via dep +
schema pin, and wasm4pm (Rust) vendors a generated JSON Schema and validates
its serde output against it in CI. ash_pplan's part: switch
`ProcessEvidence.export/2` to the `ocel:`-prefixed envelope.

## Receipts: ggen portable envelope is canonical

Four receipt schemas were compared field-by-field: ggen's portable envelope
(Rust, RFC-GPACK-001 §54/§55), ggen's legacy BLAKE3 chain format, ggen_igniter's
JSONL run receipt, ggen-ecosystem's release receipt, and ash_pplan's
`AshPPlan.Standing.Receipt` (`lib/ash_pplan/standing/receipt.ex`) +
`AshPPlan.ExecutionReceipt` (`lib/ash_pplan/execution_receipt.ex`).

Key divergences:

- **Standing vocabulary splits three ways.** ggen-ecosystem and ash_pplan
  share the 8-value vocabulary (`UNKNOWN/PARTIAL_ALIVE/ALIVE/BLOCKED/
  BUILD_BROKEN/UNSUPPORTED/REFUSED`); ggen portable renders refusal as
  `REFUSED:<code>` (colon, not bracket); ggen_igniter uses a different,
  incompatible closed set (`compensated`/`compensation_failed` have no
  8-value equivalent).
- **Four hashing schemes.** SHA-256 per-consequence re-hash (ggen portable),
  BLAKE3 chain + signature (legacy), sha256-over-sorted-JSON `receipt_hash`
  with `parent_hash` chaining (ggen_igniter), `term_to_binary(:deterministic)`
  SHA-256 (ash_pplan ExecutionReceipt — in-build evidence only, not a
  cross-repo address). No two are compatible.
- **Authority is a first-class validated field only in ash_pplan.** The
  `authority{actor, ceiling, grant}` field with the CONSTRUCT/OBSERVE/SELECT
  vs DO check exists in no ggen-family schema.

**Verdict: ggen's portable envelope is the canonical cross-repo receipt
shape.** It has a schema URI + spec revision, binds identity at the strictest
grain (subject + dependency closure), re-hashes consequences off disk
fail-closed, uses the shared standing vocabulary, and has the only explicit
replay-promotion court. ash_pplan should **consume, not re-implement**:
adopt the §82 vocabulary with colon-form `REFUSED:<code>`, and emit portable
field names (`subject`, `composition`, `consequences`, `replay.status`) via a
`to_portable/1` projection on `Standing.Receipt`. ash_pplan should **keep
local**: the five-field `R_missing_*` validation and the authority-ceiling
check — no ggen-family schema has it, and it is the load-bearing ontology
fact (see
[Standing, receipts, and the ladder](standing-receipts-and-the-ladder.md)).
ggen_igniter's compensation standings stay real in ggen_igniter but map at the
ash_pplan boundary to `BUILD_BROKEN`/`BLOCKED[compensation_failed]` — never
collapsed inside the shared vocabulary.

## SA2A: adapter, not fork

`lib/ash_pplan/sa2a/` is six modules, 199 LOC. Verdict: **a consumer adapter,
not a fork of the ash_a2a kernel.** It re-implements none of the kernel's
logic — no replan loop, attempt budget, provider selection/exclusion,
candidate normalization, or `:replan_*` refusal vocabulary. It projects
owner-side candidates (`AshPPlan.select_policy/3`, `AshPPlan.plan/1`, the
repo's admitted primitives) into the shape ash_a2a's `Replan.Provider`
behaviour expects and preserves subject identity across the boundary.

Coupling is one-directional: ash_a2a's port (`AshA2A.Replan.Port.AshPPlan`)
calls INTO the adapter; the adapter never calls ash_a2a (`AshA2A` appears
exactly once in `lib/` — a moduledoc line in `provider.ex`). Kernel evolution
cannot be drifted against in the loop/budget/refusal axes.

Watch items, not drift: `SubjectGuard` and the kernel's `SubjectLineage` are
two subject-drift checks (owner-side pre-check + kernel-side post-check, where
the kernel always wins); and the kernel-side `legacy_propose/2` fallback
bypasses the adapter when the owner module is unloaded — ash_a2a-side debt.
No re-point needed: the adapter is at the correct altitude.

## Where this leaves ash_pplan

- Keep `Standing.Receipt`'s validation and authority ceiling local; adopt the
  shared standing rendering; add a portable-envelope projection when emitting
  durable receipts.
- Expect `ProcessEvidence.export/2` to move to the `ocel:`-prefixed envelope
  once ex4pm owns the vocabulary — see
  [Process evidence and OCEL](process-evidence-and-ocel.md) for the current
  export shape.
- The sa2a surface needs no action.
