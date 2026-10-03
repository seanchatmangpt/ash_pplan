# Receipt Schema Diff — ggen family vs ash_pplan (2026-10-03)

Inventory of the four receipt/standing schemas re-implemented across the ggen family,
compared field-by-field against ash_pplan's two receipt modules. No code was changed.

## Subjects compared

| repo | file(s) | role |
|---|---|---|
| ggen (Rust) | `/Users/sac/ggen/crates/ggen-engine/src/portable_receipt.rs` (+ legacy `.ggen-v2/receipt.json` BLAKE3 chain format, schema `ggen-receipt/v2`) | per-sync portable envelope, RFC-GPACK-001 §54/§55, written to `.ggen-v2/receipt-portable.json` |
| ggen_igniter | `/Users/sac/ggen_igniter/lib/ggen_igniter/receipt.ex` | per-attempt run receipt, append-only date-partitioned JSONL under `.ggen_igniter/receipts/` |
| ggen-ecosystem | `/Users/sac/ggen-ecosystem/docs/RECEIPT-SCHEMA.md` + `scripts/verify-receipt.sh` + `contracts/bootstrap-receipt/*` + committed `receipts/*.json` | release/bootstrap-level evidence receipts (single JSON doc) |
| ash_pplan | `/Users/sac/ash_pplan/lib/ash_pplan/standing/receipt.ex` (generated), `/Users/sac/ash_pplan/lib/ash_pplan/execution_receipt.ex` | five-field R=receipt(A) envelope; PROV-O observation of one Reactor execution |

## Field-by-field table

| concept | ggen portable (Rust) | ggen legacy chain (`ggen-receipt/v2`) | ggen_igniter Receipt | ggen-ecosystem release receipt | ash_pplan Standing.Receipt | ash_pplan ExecutionReceipt |
|---|---|---|---|---|---|---|
| schema/version tag | `schema` URI + `spec` | `schema: "ggen-receipt/v2"`, `record.version` | `schema_version: "1"` | `schema` (optional) | none (ontology is the source) | none (IRI namespace) |
| identity / subject | `subject{pack,version,pack_digest}` + `composition.resolved_packs[]` + `dependencies[]` | `object_ids`, `activity` | `id`, `recipe_key` | `subject{repository,commit}` + `ecosystem{version,ggen_commit,marketplace_commit,container_digest}` | `identity{run_id, subject}` (required) | `plan_iri`, `run_id` |
| authority | implicit (engine+toolchain+environment identity) | `standing_ceiling` | none | `admission.result` (ADMITTED/REFUSED) | `authority{actor, ceiling, grant}` (required; DO refused, only CONSTRUCT/OBSERVE/SELECT safe) | none (explicitly grants no authority) |
| consequence | `consequences[]{target, operation, sha256}` re-hashed off disk, fail-closed `[FM-CHAIN-015]` | per-evidence `decision`+`reason` | `files[]` (canonical identities), `outputs`, `skipped_outputs`, `commands[]` | `consequence.digest` | `consequence{commits, files_changed, remote_effects}` (required) | `outcome_digest` (observed outcome, not writes) |
| replay | `replay.status` (UNKNOWN normally, PASS only by replay court) | chain re-walk | `pre_run_hash`/`post_run_hash` chain walk (`reconstruct_standing/2`) | `execution{command, exit_code}` | `replay{commands, ledger_digest}` (required, ≥1 command) | none (digest is content-address of outcome) |
| standing | `standing`: `ALIVE` / `PARTIAL_ALIVE` / `REFUSED:<code>` | `andon` (Green/...) | closed atom set: `alive, refused, compensated, build_broken, compensation_failed` | vocabulary of 8 + bracketed reason: `ALIVE, PARTIAL_ALIVE, BLOCKED[r], BUILD_BROKEN, UNSUPPORTED, REFUSED[r], UNKNOWN` | same 8 + `REFUSED(code)` tolerated by splitting on `(`/`:` | `status`: `succeeded/halted/failed/unknown` |
| hashing | SHA-256 (`sha256:<hex>`), pack digest, env digest, consequence re-hash | BLAKE3 chain (`payload_hash_hex`/`prev_chain_hash_hex`/`chain_hash_hex`, ed25519 `signature_hex`) | SHA-256 over sorted path:digest lines; `receipt_hash` = sha256 over key-sorted JSON minus itself; `parent_hash` chain | sha256 hex format validation (40-hex git SHA, 64-hex digests) | none (validation only, no digest) | SHA-256 over `term_to_binary(:deterministic)` of canonicalized outcome |
| validation | construction fail-closed; UNKNOWN, never omit | chain continuity | `new/1` raises on invented standing; chain-walk returns `chain_broken` map | `verify-receipt.sh` (mandatory fields, format regexes, no placeholders under ALIVE) | `validate/1` → `R_missing_<field>` broken terms | `@enforce_keys`; canonicalization of refs/pids/stacktraces |
| persistence | one JSON per sync, overwritten | one JSON, chain-linked | append-only JSONL, locked, torn-line tolerant | committed single JSON files | in-memory / caller's choice | in-memory + PROV-O N-Triples projection |

## Key divergences

1. **Standing vocabulary splits three ways.** ggen-ecosystem and ash_pplan Standing.Receipt
   share the same 8-value vocabulary (`UNKNOWN/PARTIAL_ALIVE/ALIVE/BLOCKED/BUILD_BROKEN/
   UNSUPPORTED/REFUSED`, with bracketed or parenthesized reason). ggen portable renders
   refusal as `REFUSED:<code>` (colon, not bracket). ggen_igniter uses a **different,
   incompatible closed set** (`alive/refused/compensated/build_broken/compensation_failed`,
   lowercase atoms) that has no mapping to the 8-value vocabulary — `compensated` and
   `compensation_failed` have no 8-value equivalent (nearest is `BUILD_BROKEN`/`BLOCKED`,
   a lossy collapse §82 explicitly forbids).
2. **Four hashing schemes.** SHA-256 per-consequence re-hash off disk (ggen portable);
   BLAKE3 hash chain + signature (ggen legacy); sha256-over-sorted-JSON receipt_hash with
   parent_hash chaining per recipe_key (ggen_igniter); `term_to_binary(:deterministic)`
   SHA-256 (ash_pplan ExecutionReceipt — explicitly NOT a cross-OTP-version address).
   No two are byte- or semantics-compatible.
3. **Identity granularity differs.** ggen portable binds full dependency closure +
   composition; ggen-ecosystem binds repo/commit/container; ggen_igniter binds one recipe's
   touched-file set; ash_pplan Standing.Receipt's `identity` is free-form `{run_id, subject}`;
   ExecutionReceipt binds a plan IRI + run term.
4. **Authority is a first-class validated field only in ash_pplan** (`ceiling` ∈
   {CONSTRUCT, OBSERVE, SELECT}, DO refused as `R_missing_authority`). ggen legacy has
   `standing_ceiling`; ggen portable/igniter/ecosystem have none.
5. **Replay is the weakest field everywhere it exists**: ggen portable writes `UNKNOWN`
   by design; ash_pplan requires ≥1 command but never verifies it ran; only ggen_igniter
   has an actual verified chain walk, and only the ggen portable court promotes to PASS.
6. **Schema URIs disagree**: `https://ggen.dev/receipt/pack/v1` (ggen portable) vs
   `ggen-receipt/v2` (legacy) vs `schema_version: "1"` (igniter) vs
   `https://ggen.dev/receipts/ecosystem-sync/v2` (ecosystem, optional) vs none (ash_pplan).

## Recommendation — canonical schema

**ggen's portable envelope (RFC-GPACK-001 §54/§55) is the canonical cross-repo receipt
shape.** Reasons: it has a schema URI + spec revision, binds identity at the strictest
grain (subject + composition + transitive dependency closure with per-surface scope),
re-hashes consequences off disk fail-closed, uses the §82 standing vocabulary, and is the
only one with an explicit replay-promotion court. It subsumes the ecosystem release
receipt (whose fields map: `subject.commit`→composition, `consequence.digest`→
consequences, `verification.*`→admission.gates_attempted) and the legacy chain (which
remains as the internal BLAKE3 chain, per RFC §56's explicit "not byte-equivalent" split).

**ash_pplan should consume, not re-implement:**

- The §82 standing vocabulary with `REFUSED:<code>` rendering — Standing.Receipt already
  matches it (keep the `(`/`:` split, add `:`); do not fork it further.
- The portable envelope's field names (`subject`, `composition`, `consequences`,
  `admission.gates_attempted`/`refusals`, `replay.status`, `schema`, `spec`) when emitting
  durable receipts, so ggen-family verifiers can read ash_pplan receipts without a
  translation layer.

**ash_pplan should keep local:**

- `Standing.Receipt`'s five-field `R_missing_*` validation and the authority-ceiling
  check (CONSTRUCT/OBSERVE/SELECT vs DO) — no ggen-family schema has this and it is the
  load-bearing ontology fact (`priv/ggen/ash-pplan-standing-pack/ontology.ttl`).
- `ExecutionReceipt` as-is: it is deliberately a PROV-O observation of an outcome, not a
  portable manufacture envelope; its `term_to_binary` digest is in-build evidence only
  and should not be promoted to cross-repo identity.
- ggen_igniter's compensation standings (`compensated`, `compensation_failed`) are a real
  distinction worth keeping in ggen_igniter, but ash_pplan should map them at its
  boundary to `BUILD_BROKEN`/`BLOCKED[compensation_failed]` with the detail in metadata —
  never collapse them inside the shared vocabulary.

## Migration sketch (ash_pplan, no code changes yet)

1. **Add a projection, not a rewrite**: a `to_portable/1` on `Standing.Receipt` (or a new
   generated module from the standing pack) mapping:
   - `identity{run_id, subject}` → `subject{name, version, digest}` + `engine{name:"ash_pplan", version}` + `spec: "RFC-GPACK-001-v26.9.17"`.
   - `consequence{files_changed, commits, remote_effects}` → `consequences[]{target, operation, sha256}` (re-hash files off disk, fail-closed).
   - `replay{commands, ledger_digest}` → `replay.status` (`UNKNOWN` until a court promotes it; keep `commands` in an ash_pplan extension field).
   - `authority{actor, ceiling, grant}` → keep in an ash_pplan extension field; propose it upstream as a portable-envelope extension (it is a gap in RFC-GPACK-001).
   - standing → §82 string (`REFUSED:<code>` colon form).
2. **Unify the schema URI**: adopt `https://ggen.dev/receipt/pack/v1` for portable-shaped
   receipts ash_pplan emits; register the ash_pplan extension fields in the spec rather
   than inventing a fourth URI.
3. **Receipt chaining**: adopt ggen_igniter's `receipt_hash`-over-sorted-JSON-minus-self +
   `parent_hash` discipline for ash_pplan durable receipts (Standing.Receipt currently has
   no tamper-evidence at all).
4. **Sequence**: (a) emit the projection alongside current receipts in `receipts/`;
   (b) point ggen-family court/verifier tooling at it; (c) only then deprecate any
   ash_pplan-local receipt JSON shape. Do not collapse ggen_igniter's five standings in
   ggen_igniter itself.
