# Marketplace Usage Evaluation — ggen-marketplace across the local ecosystem

Date: 2026-10-01. Scope: ash_pplan, ash_ex4pm, ggen_igniter, beam4pm, ex4pm, ggen-marketplace (brief: ash_a2a, ggen-ecosystem).
All evidence from on-disk grep/ls/git of the canonical checkouts; no project files modified.

## Ground truth: pins

| repo | consumption mode | pin | vs marketplace main (`fd85ff2`, v26.10.1, 2026-10-01) |
|---|---|---|---|
| beam4pm | git submodule `vendor/ggen-marketplace` + `ggen.toml [packs]` path refs | `fd85ff2` (v26.10.1) | **current** |
| ggen-ecosystem | git submodule `vendor/ggen-marketplace` | `bf9eccb3` (v26.9.29-440) | behind ~1 tag |
| ex4pm | file-level vendor + sha256 lock (`priv/ggen/vendor/sync.sh`, `PACKS.lock.json`) | lock `source_git_sha = d467c417` | **behind (stale lock)** |
| ggen_igniter | none vendored; `fetch_pack!/2` HTTP path (lib/ggen_igniter/pack.ex) + comment "packs come from ggen-marketplace" | n/a (fetches at sync time) | UNKNOWN (runtime fetch, no pin) |
| ash_pplan | none | none | n/a |
| ash_ex4pm | none | none | n/a |

## Per-project

### /Users/sac/ash_pplan
- Consumes marketplace: **YES (file-level, 2026-10-04)** — `ash-runtime-integration-contract-pack` vendored into `priv/ggen/ash-pplan-runtime-overlay/` by `priv/ggen/vendor/sync.sh`, sha256-locked at marketplace `503af6c2` in `priv/ggen/vendor/PACKS.lock.json` (initial pin `5214eb0e`; re-pinned when the marketplace moved mid-adoption — the pack's vendored surfaces were byte-identical across the move). The pack previously appeared under beam4pm's missed-adoption list (line 47); ash_pplan is now the adopting consumer (beam4pm's own record is unchanged).
- Local packs: 6 under `priv/ggen/` (ash-pplan-pack, -workflow, -standing, -store-conformance, -durable-tla, -durable-chaos), ~1,442 ttl lines total (36–132 KB each). All wired via ggen.toml and synced by `bin/manufacture*` via `mix ggen_igniter.sync --pack-dir`.
- Duplication vs marketplace: `ash-pplan-standing-pack` overlaps `evidence-standing-pack` (mkt v26.9.14, gates: no_receipt_no_standing, seal_once, parent_hash_closure, outcome_requires_pending, standing_only_on_outcome) and `standing-ladder-pack` (10-state ladder, v0.1.1). Both sides grew independently — ash_pplan side is newer (26.10.1 receipts) but evidence-standing-pack's gate set (seal-once, parent-hash closure) is not obviously covered by ash-pplan-standing-pack. Estimate: ~1,400 lines / 2 packs duplicated in intent, not byte-identical. UNKNOWN how much gate logic is semantically identical.
- Missed adoptions (top 3):
  1. `standing-ladder-pack` → replaces/complements `lib/ash_pplan/standing.ex` ladder semantics (ash_pplan's standing pack re-derives a ladder locally).
  2. `evidence-standing-pack` → its gates encode canonical receipt invariants (seal-once, parent-hash closure) that could gate ash_pplan's ExecutionReceipt/Standing directly.
  3. `capability-closure-pack` → UNKNOWN fit against `lib/ash_pplan/policy_closure/`; not read in detail.

### /Users/sac/ash_ex4pm
- Consumes marketplace: **NO**. `priv/ggen/manifest.json` is literally `[]`. Only indirect link: dep on `ggen_igniter` (which fetches marketplace packs).
- Local packs: none.
- Duplication: none (empty manifest). But `ash-ex4pm-evidence-pack` exists in the marketplace, named for this project, and is unconsumed by it.
- Missed adoptions (top 3):
  1. **`ash-ex4pm-evidence-pack`** (gates + qualification + targets.toml present) — named consumer fit: evidence flows in lib/ash_ex4pm (receipt_store, call_log_bridge, engine_run domain).
  2. `evidence-capital-*` family (7 packs) — UNKNOWN fit, plausibly overlaps ash_ex4pm's receipt_store/evidence intent.
  3. `capability-closure-pack` → capability.ex/capability_projection.ex.

### /Users/sac/ggen_igniter
- Consumes marketplace: **client-side only** — `lib/ggen_igniter/pack.ex` (Tesla) `fetch_pack!/2` HTTP marketplace path; mix.exs:152 comment: "packs come from ggen-marketplace, not from this package."
- Local packs: 26 under priv/ggen/ (semantic-jira, gall_work, state-machine, receipted-extension, chicago-fault-injection, etc.). **Zero name overlaps** with mkt packs (verified per-directory). ggen_igniter ships `priv/ggen/*` excluding "ash" packs — because "Ash packs come from ggen-marketplace".
- Duplication: UNKNOWN beyond naming; no byte-level comparison run. Local packs appear complementary, not duplicated.
- Missed adoptions: none obvious; it is the sync engine, not a pack consumer of record. Optionally `pack-compatibility-pack`/`pack-maturity-pack` for its sync/doctor surface — UNKNOWN fit.

### /Users/sac/beam4pm
- Consumes: **YES, deepest consumer**. Submodule `vendor/ggen-marketplace` @ fd85ff2 (current, v26.10.1); ggen.toml wires 10 packs (beam4pm-* ×5, github-actions, frontier-release-beam, fortune5-architecture, fortune5-deployment-blocks) + 5 public ontologies (prov-o, org, owl-time, sosa, ssn) from the vendored repo. Doc comment cites a 2026-09-18 audit of all 299 packs in the vendored universe; 2 packs investigated and declined with recorded reasons (gh-terraform-pack).
- Local packs: none under priv/ggen (packs live in the marketplace: beam4pm-process-model-pack etc. — correct direction of travel: project-specific packs live in mkt, consumed via submodule).
- Duplication: essentially none (its packs live in mkt).
- Missed adoptions (top 3): `ash-runtime-integration-contract-pack` (beam4pm bridges/runtime contracts — UNKNOWN whether already covered by beam4pm-mcp-contracts/ai-contracts packs); `process-intelligence-pack`/`process-mining-proof-pack` (fits OCEL/process model core); `wasi-json-abi-pack` (wasm engine pack exists; UNKNOWN fit).

### /Users/sac/ex4pm
- Vendor lock: `PACKS.lock.json` source_git_sha `d467c417` is behind mkt main (fd85ff2) — actionable refresh: re-run `priv/ggen/vendor/sync.sh`.
- Consumes: **YES (file-level vendoring)** — ex4pm-wasm4pm-bindings-pack + standing-ladder-pack (ontology.ttl + gates .rq, sha256-locked, deterministic re-vendor via sync.sh; determinism verifier refuses on hash mismatch).
- Local packs: own ggen surface (`priv/ggen/{gates,queries,templates}`) plus the vendor dir.
- Duplication: none found (vendored, not re-implemented).
- ex4pm also has CI consumers: .github/workflows/r58-independent-consumer.yml and r79-tcps-ready-set-consumer.yml checkout ggen-marketplace directly — the only true independent-consumer proof in the ecosystem.
- Missed adoptions: `process-intelligence-pack` (ex4pm is a process-mining lib); `chicago-tdd-tools-pack`; UNKNOWN how much of its own priv/ggen gates duplicate mkt gate conventions.

### /Users/sac/ash_a2a (brief)
- Zero marketplace references found in mix.exs/config/ggen.toml/scripts/.github. UNKNOWN deeper usage; not scanned at lib level.

### /Users/sac/ggen-ecosystem (brief)
- Submodule @ bf9eccb3 (v26.9.29-440) — behind mkt main by ~1 tag. Wires only `github-actions-pack` via ggen.toml; a test asserts the ggen.toml comment SHA matches the lock (`test_ggen_toml_packs_comment_marketplace_sha_matches_lock`). Also hosts marketplace_candidate_sha validation in scripts/qme_crown.py — governance-side consumer.
- Missed adoptions: `marketplace-governance-pack`, `governance-gate-pack` — UNKNOWN fit vs its own qme_crown.py law.

## Ecosystem-wide

### Duplication map
| duplication | size est. | newer side |
|---|---|---|
| ash_pplan standing/tla/chaos packs vs mkt `evidence-standing-pack` + `standing-ladder-pack` | ~1,400 ttl lines / 2 intents | ash_pplan newer; mkt packs carry seal-once/parent-hash gates ash_pplan lacks |
| ggen_igniter's 26 local packs vs mkt | 0 name overlaps; semantic overlap UNKNOWN | n/a |
| ex4pm's own priv/ggen gates vs mkt gate conventions | UNKNOWN (not read) | n/a |

### Top-5 generalization candidates (publish as packs)
1. **ash-pplan standing ladder implementation** → but first reconcile with existing `evidence-standing-pack`/`standing-ladder-pack` before publishing a third standing pack — consolidation, not publication, is the win.
2. **ash-pplan-store-conformance-pack** (durable Store + ontology-generated conformance suite; exists locally only) → generalize + publish to mkt, dedupe against `process-intelligence-pack` gate conventions.
3. ash_pplan `state_machine/` + Stateright/TLA+ protocol courts (durable-tla-pack / durable-chaos-pack exist locally; generalize beyond ash_pplan naming).
4. ash_ex4pm broadcaster/notifier evidence bridge (lib/ash_ex4pm/notifier.ex, call_log_bridge.ex) — small focused modules, publishable as small packs.
5. ggen_igniter's `chicago-fault-injection-pack` — not in mkt, natural mkt candidate. Honorable mention: beam4pm's 299-pack consumption-audit artifact with recorded declines → publish as `pack-compatibility-pack` content or its own pack.

### Top-5 adoption candidates (pack → project → replaces)
1. **`ash-ex4pm-evidence-pack` → ash_ex4pm** — replaces empty manifest `[]`; gates+qualification already target this project by name.
2. `evidence-standing-pack` gates → ash_pplan ExecutionReceipt/Standing — replaces hand-rolled receipt invariants; consolidates the standing duplication.
3. `standing-ladder-pack` → ash_pplan lib/ash_pplan/standing.ex — replaces locally re-derived ladder semantics (already consumed by ex4pm, proving the pattern).
4. `chicago-tdd-tools-pack` → ash_pplan + ash_ex4pm test surfaces (neither references it; Chicago-style discipline is already doctrine but the pack's tools are unused).
5. `process-intelligence-pack` → ex4pm and beam4pm — ex4pm consumes only 2 packs today; the process-mining packs plausibly replace local gate/query surfaces. UNKNOWN fit verified.

### Key findings (summary)
1. beam4pm is the only current consumer (submodule pin == mkt HEAD fd85ff2, 10 packs + 5 ontologies, 299-pack audit artifact).
2. ash_pplan and ash_ex4pm consume nothing; ash_pplan carries 6 local packs that partially duplicate marketplace standing/evidence capability (~1,400 ttl lines intent-duplicated); ash_ex4pm's namesake pack sits unconsumed next to a literal `[]` manifest.
3. ex4pm's vendor lock is stale (d467c417 vs main fd85ff2).
4. ggen-ecosystem submodule is one tag behind; ggen_igniter consumes via HTTP fetch with no pin — UNKNOWN if pinned anywhere.
5. Zero byte-level pack name overlaps between ggen_igniter's 26 local packs and mkt; duplication risk is semantic, not nominal.
6. The strongest generalization moves are consolidation (three standing packs → one) and promoting ash_pplan's 6 local packs into mkt following the beam4pm pattern (project-specific packs live in mkt, consumed via submodule), not adding more local surface.

## Honest UNKNOWNs
- Semantic equivalence of ash_pplan standing gates vs evidence-standing-pack gates — not diffed gate-by-gate.
- ggen_igniter fetch_pack!/2 pin state — no pin found; runtime fetch unverified end-to-end.
- ash_a2a deep usage — surface scan only.
- beam4pm bounded-ingest-buffer pattern location — claimed in task, not located in code.
- Fits for capability-closure-pack / process-intelligence-pack / evidence-capital-* family — capability names matched to module names, not gate-level verified.
- ex4pm priv/ggen gates vs mkt gate conventions duplication — not read.
