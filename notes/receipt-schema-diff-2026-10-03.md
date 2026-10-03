# Receipt Schema Diff — ggen family (2026-10-03)

COMBINE item: receipt/standing vocabulary re-implemented across the ggen family.
Sources inspected (read-only, exact files):

| # | Repo | File | Role |
|---|------|------|------|
| 1 | ggen | `crates/ggen-engine/src/portable_receipt.rs` | portable envelope, RFC-GPACK-001 §54/§55, per-sync, JSON |
| 1b| ggen | `.ggen-v2/receipt.json` (legacy, via `crate::sync::write_receipt`) | BLAKE3 hash-chain record (`record` + `payload`), explicitly NOT byte-equivalent to #1 (RFC §56) |
| 2 | ggen_igniter | `lib/ggen_igniter/receipt.ex` | append-only JSONL per-attempt history, per-recipe chain-of-custody |
| 3 | ggen-ecosystem | `receipts/*.json` + `docs/RECEIPT-SCHEMA.md` + `scripts/verify-receipt.sh` | flat ad-hoc per-purpose JSON receipts (release, bench, census, bootstrap) + one pinned release schema (`ecosystem-sync/v2`) |
| 4 | ash_pplan | `lib/ash_pplan/execution_receipt.ex` | PROV-O observation of one Reactor run (evidence, not standing) |
| 5 | ash_pplan | `lib/ash_pplan/standing/receipt.ex` + `standing.ex` | five-field R = receipt(A), generated from ontology |
| — | (harness) | `~/.claude/dfcm/receipt.schema.json` | DfCM v2 JSON Schema — the ontology-level R the doctrine names |

Standing vocabularies:

| Implementation | Standing set |
|---|---|
| ggen portable (§82) | `ALIVE`, `PARTIAL_ALIVE`, `REFUSED:<code>` (3, closed enum) |
| ggen legacy chain | none — `andon`, chain hash; standing is implicit ALIVE |
| ggen_igniter | `:alive, :refused, :compensated, :build_broken, :compensation_failed` (5, closed atoms, `new/1` raises otherwise) |
| ggen-ecosystem release schema | `ADMITTED` (admission.result), `standing` = `ALIVE` (case: doctor/chicago/dod each ALIVE) |
| ggen-ecosystem ad-hoc | free-form (`"ALIVE[MANUFACTURE_ARTIFACT]"`, `court_standing: "ALIVE"`) |
| ash_pplan Standing.Receipt | `ALIVE, BLOCKED, BUILD_BROKEN, PARTIAL_ALIVE, REFUSED, UNKNOWN, UNSUPPORTED` + `REFUSED(...)` with parens/colon suffix (7) |
| ash_pplan ExecutionReceipt | `:succeeded, :halted, :failed, :unknown` (execution status, not standing) |
| DfCM v2 schema | `UNKNOWN\|PARTIAL_ALIVE\|ALIVE\|BLOCKED(:...)?\|BUILD_BROKEN\|UNSUPPORTED(...)\|REFUSED(...)` regex |

## Field-by-field table

Concept → per-implementation field. `—` = absent.

| Concept | ggen portable | ggen legacy chain | ggen_igniter Receipt | ggen-ecosystem release | ash_pplan ExecutionReceipt | ash_pplan Standing.Receipt | DfCM v2 |
|---|---|---|---|---|---|---|---|
| **Identity** | `subject{pack,version,pack_digest}`, `composition.resolved_packs[]`, `engine{}`, `work_order{}` | `record.instruction_id`, `record.object_ids` | `id`, `recipe_key` | `subject{repository,commit}`, `run_id`, `run_attempt` | `plan_iri`, `run_id` | `identity{run_id, subject}` (requires both non-nil) | `identity{subject, repo, subject_sha, base_sha}`, `work_order_id`, `provider_execution_id` |
| **Authority** | — (envelope REPORTS standing, confers none) | — | — | `authority: "NONE"` (ad-hoc only) | — (explicitly "grants no actuation authority") | `authority{actor, ceiling, grant}`; `DO` refused as `R_missing_authority` | `authority{ceiling, grant, actor}` + `origin_authority` |
| **Consequence** | `consequences[]{target, operation, sha256}` re-hashed off disk, fail-closed `[FM-CHAIN-015]` | `payload.outputs`, `payload.decisions` | `files[]`, `outputs`, `skipped_outputs`, `commands[]`, `metadata` | `consequence.digest` | `outcome_digest` (term-level, not file-level) | `consequence{commits, files_changed, remote_effects, observed}` | `consequence{commits, files_changed, remote_effects}` |
| **Replay** | `replay.status` (always UNKNOWN from manufacture; court-only PASS) | `record.chain_hash_hex`, `prev_chain_hash_hex` | `pre_run_hash`/`post_run_hash` per recipe + `reconstruct_standing/2` chain walk | `execution{command, exit_code}`, `patch_sha256` | — (no replay field; digest is content address of outcome) | `replay{commands, ledger_digest, ledger_algorithm, evidence{ocel2_sha256, ex4pm}}`; no `commands` ⇒ refuse `R_missing_replay` | `replay{commands[cmd,cwd,exit], ...}` minItems 1 |
| **Standing** | `standing` string, §82 enum | — | `standing` atom (5-value closed set) | `standing` + `verification{doctor,chicago,dod}` | `status` (succeeded/halted/failed/unknown) | `standing{value, derived_from, broken_term?}` | `standing{value, derived_from, broken_term?}` |
| **Time** | — (no timestamp field!) | `record.ts_ns` | `started_at`, `finished_at`, `completed_at` | — | `started_at`, `finished_at`, `duration_us` | — | — |
| **Hashing** | per-file SHA-256 + pack `sha256:` prefix; graph canonical digest | BLAKE3 chain over record+payload | SHA-256 over sorted `path:digest` lines; `receipt_hash` = SHA-256 over key-sorted JSON minus `receipt_hash` | sha256 of artifact/patch; subject 40-hex commit SHAs | SHA-256 over `term_to_binary(deterministic)` of canonicalized outcome term | SHA-256 chain (`AshPPlan.Standing.Chain`, genesis-seeded, per-event pending+outcome+seal) | regex-validated sha256/blake3 patterns only |

## Divergences

1. **Standing vocabulary, three incompatible sets.** §82 three-value enum (ggen) vs five
   outcome atoms (ggen_igniter) vs seven-value open-suffix vocabulary (ash_pplan / DfCM).
   `compensated`/`compensation_failed` (ggen_igniter) have NO equivalent anywhere else —
   a compensation story cannot be represented in §82 terms without collapsing to
   PARTIAL_ALIVE/REFUSED and losing the distinction. Conversely `UNKNOWN`/`UNSUPPORTED`
   don't exist in ggen_igniter or ggen's enum.
   `REFUSED` renders three ways: `REFUSED:<code>` (ggen colon), `REFUSED(...)` (ash_pplan/DfCM
   parens), bare `:refused` atom (ggen_igniter). Any cross-consumer court (e.g. C14
   one-admission-kernel) is blocked by this alone.
2. **Authority field missing from most.** Only ash_pplan Standing.Receipt and DfCM v2 carry
   `{actor, ceiling, grant}` with typed refusal of `DO`. ggen's envelope explicitly disclaims
   authority ("REPORTS standing, does not confer it") yet has no authority field at all, so an
   envelope cannot name what authority the run acted under.
3. **Timestamps absent from the "portable" envelope.** ggen portable has no time field;
   ggen_igniter and ExecutionReceipt carry full time; DfCM v2 has none (time lives in the OCEL
   chain via `provider_execution_id`).
4. **Hash algorithms inconsistent:** BLAKE3 (ggen legacy chain, marketplace pack digests),
   SHA-256 (everything else); sha256-`prefix` conventions differ (`sha256:<hex>` vs bare hex).
5. **Chain construction three ways:** BLAKE3 record chain (ggen legacy), per-recipe
   pre/post-run-hash continuity walk (ggen_igniter), sha256 genesis-seeded event ledger with
   pending/outcome/seal (ash_pplan Chain). No cross-implementation verifier exists for any of
   the three.
6. **Receipt self-hash:** only ggen_igniter hashes the receipt record itself
   (`receipt_hash` over key-sorted JSON minus the hash field). DfCM v2 has no receipt-level
   digest; ggen portable/legacy do not self-hash the envelope.
7. **Refusal typing:** ggen carries typed refusal identities (`refusals[]`, Appendix C
   vocabulary) in `admission`; ash_pplan carries `broken_term` enum in `standing`; DfCM v2
   carries `broken_term` enum. ggen_igniter's `:refused` carries only free-text `reason` —
   no typed refusal identity.
8. **Schema self-description:** ggen portable has `schema`+`spec` URIs; ggen-ecosystem
   ad-hoc receipts carry `schema` URIs but no pinned validator for most; ash_pplan/DfCM use
   the five-field shape with no URI at all.
9. **Granularity mismatch:** ggen receipts are per-sync/per-run; ggen_igniter receipts are
   per-attempt-per-recipe (many per run); ExecutionReceipt is per-Reactor-run observation;
   DfCM v2 is per-work-order execution. Same word "receipt", four units of account.

## Which schema is canonical

**DfCM v2 (`~/.claude/dfcm/receipt.schema.json`, `https://chatmangpt.com/schema/receipt/v2`)
is the canonical R vocabulary** — it is the only one with the five required fields
(identity/authority/consequence/replay/standing), the ceiling enum, the broken_term enum,
and the §82 standing regex. Ash_pplan's Standing.Receipt is its closest executable
projection (it validates against the same five-field shape and the same standing regex,
and is **generated from the standing ontology**, not hand-written — consistent with
ontology-first law). ggen's portable envelope is the strongest *evidence* format (bounded
environment digest, toolchain identity, dependency closure, fail-closed consequence
re-hashing) but is deliberately an evidence envelope, not an R.

For pack/evidence identity, ggen's portable envelope is the strongest evidence envelope and
should be treated as the canonical **evidence/consequence** projection; its `standing` field
is the one to remap, not the envelope shape.

## Migration sketch

1. **Vocabulary first (no code change needed to read):** define one mapping to the DfCM/§82
   seven-value vocabulary:
   - ggen portable: ALIVE→ALIVE, PARTIAL_ALIVE→PARTIAL_ALIVE, `REFUSED:<code>`→`REFUSED(<code>)`
   - ggen_igniter: alive→ALIVE, refused→REFUSED(pre_actuation) — new code; compensated→PARTIAL_ALIVE
     + `broken_term: R_missing_consequence`... (better: extend DfCM standing regex with
     `COMPENSATED` and `COMPENSATION_FAILED` as typed refusals rather than collapsing) —
     recommend extending the canonical regex with `COMPENSATED`, `BUILD_BROKEN` already present;
     only `COMPENSATED`/`COMPENSATION_FAILED` need adding; compensation_failed keeps its
     broken_term `mu_unlawful` + metadata paths.
   - ecosystem ad-hoc: `ALIVE[...]` bracket qualifiers → move into `derived_from`, keep value
     in the seven-value set.
2. **Make ash_pplan Standing.Receipt the family projection target.** It is generated
   (ggen_igniter pack `ash-pplan-standing-pack/ontology.ttl`) — extend that ontology with the
   COMPENSATED values and the ggen portable evidence block (`toolchain`, `environment`,
   `composition`) as optional maps on the receipt struct, then regenerate. One ontology, N
   bindings, instead of O(N²) drift (C14's law).
3. **Add `receipt_hash` (self-hash) to DfCM v2 as optional** field, defined exactly as
   ggen_igniter's: SHA-256 over key-sorted JSON minus the hash key. This makes every receipt
   tamper-evident in one step and lets `reconstruct_standing`-style chain walks verify
   receipts not keyed by git SHAs.
4. **Add `identity.subject_sha` anchoring to ggen_igniter and ash_pplan ExecutionReceipt.**
   ggen_igniter keys chains by `recipe_key` only; ExecutionReceipt has no repo/SHA identity at
   all. DfCM identity requires `repo` + 40-hex `subject_sha`/`base_sha`; adopting it makes
   receipts replayable across repos (C21 out-of-subject receipts precondition).
5. **Unify hashing policy:** all digests `sha256:<hex>` prefixed; BLAKE3 stays only inside
   ggen's legacy chain (RFC §56 keeps it) and marketplace pack digests, flagged by algorithm
   field (DfCM `subject_digest.algorithm` already supports `blake3`).
6. **Typed refusals everywhere:** map ggen's Appendix C refusal ids and ggen_igniter's free
   `reason` into the `broken_term` enum + a `refusal_code` string, so courts can match on the
   vocabulary (C23 pruner reads typed refusals, not prose).
7. **Sequencing:** (a) standing regex extension + mapping table (doc-only, no runtime risk);
   (b) ontology extension + regenerate ash_pplan Standing.Receipt; (c) add `receipt_hash` +
   `subject_sha` to consumers (ggen_igniter `to_json_map/1` already additive-by-default);
   (d) conformance corpus: extend `ggen-ecosystem/tests/receipt-conformance` (48 invalid
   cases today) with one valid/invalid pair per migrated consumer.
