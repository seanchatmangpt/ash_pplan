# Seal Manifest v3 — 2026-11-07 (Lane FA1)

Standing: PASS

Supersedes `notes/seal-rehearsal-v2-2026-11-07.md` (G18 v2) and AR9's deltas.
AR9's delta text was not on disk in any of the three repos; it was applied from
the dispatch as authoritative and every correction was re-verified against the
filesystem before inclusion. No commits, no staging. `git status --porcelain`,
`git log`, `git check-ignore` were used READ-ONLY as filesystem queries
(dispatch-permitted); no state-changing git command ran.

## Provenance table (AR9 corrections, each re-verified on disk)

| AR9 correction | Disk verification | Resolution |
|---|---|---|
| P4/P5/P6/A7/M1/M4 group revisions | existence loops + porcelain | applied in groups below |
| phantom A7 path | `test/ash_a2a/replan/port_ashpplan_conformance_court_test.exs` MISS; same filename exists at `test/replan/` | v2 path dropped; file KEPT at corrected path `test/replan/port_ashpplan_conformance_court_test.exs` |
| bench files to P1 | `bench/claims_bench.exs`, `bench/CLAIMS-BASELINE-2026-11-07.md` exist | moved P4 to P1 |
| bin/* + htn/fond/policy_supervisor + workflow courts + airbus scripts | all paths exist | grouped: bin/* to P6; htn/fond/policy_supervisor + workflow courts to P5; airbus scripts stay P4 |
| receipts/ mtime question | porcelain receipts/ + notes/ ash_pplan: 94 M, 10 untracked | RESOLVED: M files are real content edits (Standing backfills + D8 STALE-PATHS annotations, verified via `git diff receipts/INDEX-2026-10-03.md`), committable in P7 |
| .DS_Store covered | marketplace .gitignore lines 42-43, present in HEAD at baseline 1af488694 | G18 v2 "LOW gap" claim was wrong; no action |
| .ggen-v2 ignored-not-staged | marketplace .gitignore lines 51-52; zero untracked .ggen-v2 in porcelain | RESOLVED: ignored, nothing to stage; M4 stages nothing |
| notes/archive/reclaimed-home/ intent | files on disk | RESOLVED: COMMIT (D8's deliberate archive move) |

## Flags resolved (coordinator actions)

1. `scripts/__pycache__/` (ash_pplan): still unignored (porcelain
   `?? scripts/__pycache__/`); .gitignore line 38 covers only
   `bin/__pycache__/`. RESOLUTION: add one line `scripts/__pycache__/` to
   /Users/sac/ash_pplan/.gitignore BEFORE staging. REQUIRED pre-step.
2. `.DS_Store`: covered, no action.
3. `.ggen-v2/`: ignored-not-staged, M4 stages nothing.
4. `notes/archive/reclaimed-home/`: commit in P7.

## Topological order (AR9)

P1 - P3 - P2 - P5 - P8 - P4 - P6-last - P7-anytime;
all-P before A7; A1-A6 free order; A7; A8-last; M1 - M2 - M3.
(M4 absent from the order: nothing to stage.)

## ash_pplan commit groups (baseline ea21645; census 183 M / 46 untracked)

### P1 durability + claims bench
- `lib/ash_pplan/reactor/durable/**` (engine, run, checkpointed, stores
  ets/dets/wal, ring_buffer, health_gate, lease_monitor, key.ex
  [post-G18 landing], compensations/**)
- `test/durable/**` (14 untracked files: replay_fence, wal_unwind_semantics,
  store_triod, store_take_signal, store_wal_integrity,
  engine_terminal_signal, engine_wal, health_gate_wiring,
  lease_monitor_soak, obligation, d4_failed_settle_store_survival,
  f8_scratch, store_conformance_wal + rest of dir)
- `test/support/durable/**`
- `bench/claims_bench.exs`, `bench/CLAIMS-BASELINE-2026-11-07.md`
  (AR9: bench to P1)
- `checkpoints/research200-tla-court.txt`,
  `priv/tla/durable/DurableProtocol.tla`
- Gate: `mix compile --warnings-as-errors` then `mix test test/durable`.

### P3 telemetry
- `lib/ash_pplan/telemetry/**` (emit.ex, emit/{event,buffering_emitter,noop}.ex,
  event.ex, broadcaster.ex)
- v2 listed `lib/ash_pplan/playground/telemetry_broadcaster.ex` — DELETED on
  disk (git status snapshot shows D for lib playground files); the live
  surface is `test/support/playground/telemetry_broadcaster.ex` (P8).
- Gate: `mix test test/telemetry`.

### P2 POWL
- `lib/ash_pplan/powl.ex`, `lib/ash_pplan/powl/**`, `test/powl/**`,
  `examples/powl_engine_demo.exs`, `docs/how-to/powl-engine-demo.md`
- `test/compiler_powl_seam_test.exs` (dual-homed with P5 — disclose at
  staging)
- Gate: `mix test test/powl test/compiler_powl_seam_test.exs`.

### P5 planner/workflow/capability core
- `lib/ash_pplan/htn.ex`, `lib/ash_pplan/fond.ex`,
  `lib/ash_pplan/fond/policy_supervisor.ex` (AR9: planner core to P5)
- `lib/ash_pplan/providers/**`, `lib/ash_pplan/workflow/**`,
  `lib/ash_pplan/catalog/projection_catalog.ex`,
  `lib/ash_pplan/compiler.ex`, `lib/ash_pplan/obligation.ex`,
  `lib/ash_pplan/standing/receipt.ex`, `lib/ash_pplan/release_receipt.ex`,
  `lib/ash_pplan/execution_receipt.ex`, `lib/ash_pplan/reactor.ex` and
  `lib/ash_pplan/ash_pplan.ex`
- `test/support/examples/**`, `test/courts/examples/**` (workflow courts),
  `test/hardening/**`, `test/execution_receipt_test.exs`,
  `test/state_machine_test.exs`, `test/ash_pplan_test.exs`,
  `test/fond_subject_test.exs`, `test/fond/**`
- Gate: `mix test test/courts/examples` + `mix test test/hardening`.

### P8 playground / marketplace_sim repairs
- `test/marketplace_sim/**`,
  `test/support/marketplace_sim/web/{dashboard_live,lifecycle_live}.ex`,
  `test/support/playground/**` (engine_bridge, hive_simulator,
  scenario_runner, telemetry_broadcaster — the deleted lib playground
  surface lives here now), `bin/playground`, `bin/playground_boot.exs`
- Gate: `mix test test/marketplace_sim`.

### P4 airbus namespace
- `lib/ash_pplan/airbus/turtle.ex`, `bin/airbus-oracle-gate`,
  `scripts/airbus_oracle_daemon.py`, `scripts/airbus_oracle_README.md`
  (airbus scripts stay P4 per AR9 grouping)
- `test/courts/airbus_corpus_parity_test.exs`,
  `test/courts/airbus_fond_differential_test.exs`,
  `test/support/airbus_oracle.ex`, `test/support/airbus_fond_oracle.ex`,
  `priv/courts/airbus_parity.receipt`
- Gate: `mix test test/courts/airbus_corpus_parity_test.exs test/courts/airbus_fond_differential_test.exs`
  (session receipt: `priv/courts/airbus_parity.receipt`).

### P6 docs + DoD gate tooling (commit LAST of the P groups)
- `docs/**` (diataxis tree incl. new
  `docs/diataxis/explanation/durable-primitives.md`, `docs/how-to/`,
  `docs/PACKAGE-BOUNDARY.md`, PRD-ARD, architecture, demonstration),
  `README.md`, `CHANGELOG.md`, `mix.exs` (version bump), `ggen.toml`,
  `ontology.ttl`, `ontology/fond_tla.ttl`,
  `priv/ggen/ash-pplan-pack/ontology.ttl`,
  `priv/ggen/ash-pplan-workflow-pack/ontology.ttl`, `planning/README.md`,
  `.gitignore` (lane-lease entries + REQUIRED pre-step flag-1 add),
  `bin/*` (gate, conform, ggen-doctor, observe-ontology, receipt,
  fetch-tlc [new, untracked], playground + playground_boot.exs are P8's —
  keep them out of P6 to avoid double-staging)
- Gate: `bin/gate`.

### P7 receipts + notes (order-independent; after P6)
- `receipts/v26117-{session-receipt,defect-register,hex-preflight}-2026-11-07.md`,
  `receipts/v26.11.7-release-prep-2026-11-07.md`,
  `receipts/v7-package-boundary-2026-11-07.md`
- `receipts/lanes/{z1-take_signal,z6-wal-bench}.md` (Z-wave, post-G18)
- `notes/landing-manifest-2026-11-07.md`,
  `notes/v26117-wave-ledger-2026-11-07.md`,
  `notes/archive/reclaimed-home/**` (commit — flag 4)
- `notes/{chicago-adoption,ferroplan-fond-verdict-2026-10-03,` +
  `ggen-igniter-feature-audit,graphlaw-engine,graphlaw-wasm-api-survey,` +
  `ocel-vocabulary-audit-2026-10-03,receipt-schema-diff-2026-10-03,` +
  `sa2a-adapter-verdict-2026-10-03,twin-handoff-ash-a2a}.md` (all modified
  with real content edits: Standing backfills + D8 STALE-PATHS annotations)
- `receipts/**` 94 modified files (same edit classes)
- this manifest: `notes/seal-manifest-v3-2026-11-07.md`
- Gate: `grep -L '^Standing:' receipts/v26117-*.md notes/*2026-11-07*.md`
  must output nothing.

## ash_a2a commit groups (session window 2026-11-07)

### A1 twin
- `lib/ash_a2a/twin.ex`, `lib/ash_a2a/twin/**` (tony, vince, operator, asset,
  hazard, lease, server, partner), `test/twin/**`
- `notes/hilt-graph-digest-census-2026-11-07.md`
- Gate: `mix test test/twin`.

### A2 strain
- `lib/ash_a2a/strain/{bridge,tensor}.ex`, `test/strain/**`
- Gate: `mix test test/strain`.

### A3 attestation + authority
- `lib/ash_a2a/attestation/` (whole dir — directory-granularity staging,
  disclosed), `lib/ash_a2a/authority/` (whole dir — includes graph_pin, pep,
  source, source.ex, source/{allow_all,deny_all}), `test/attestation/**`,
  `test/authority/**`
- Gate: `mix test test/attestation test/authority`.

### A4 copilot pipeline
- `lib/ash_a2a/copilot/**` (pipeline.ex), `test/copilot/**`,
  `examples/copilot_demo.exs`,
  `docs/how-to/{copilot-demo,run-the-copilot-pipeline}.md`,
  `docs/explanation/copilot-membrane.md` (A4 docs)
- Gate: `mix test test/copilot`.

### A5 actuation + dispatch durability
- `lib/ash_a2a/actuation/{engine,adapter,ticket}.ex`, `test/actuation/**`,
  `test/execution/**`, `test/ash_a2a_margin_gate_e2e_test.exs`
- Gate: `mix test test/actuation test/execution test/ash_a2a_margin_gate_e2e_test.exs`.

### A6 negotiation + attention
- `lib/ash_a2a/negotiation/**`, `lib/ash_a2a/attention/**`,
  `test/negotiation/**`, `test/attention/**`
- Gate: `mix test test/negotiation test/attention`.

### A7 pplan port courts + runner (after all P groups)
- `test/ash_a2a/replan/ash_pplan_port_parity_court_test.exs`
  (the ONLY untracked file in test/ash_a2a/replan/ — 24 siblings are
  (the ONLY untracked file in test/ash_a2a/replan/ — 24 siblings are
  pre-session tracked tests, do NOT stage the dir)
- `test/replan/port_ashpplan_conformance_court_test.exs` (corrected path —
  top-level `test/replan/`; dir contains exactly 1 file, safe to stage as dir)
- `lib/mix/tasks/ash_a2a.pplan_courts.ex` (runner + toggle)
- `test/ash_a2a_pplan_ocel_evidence_court_test.exs`
- Gate: `mix ash_a2a.pplan_courts` (the mix task is the runner and executes
  both courts + the ocel evidence court).
- Gate adequacy: adequate — the mix-task run is the proving command;
  `docs/how-to/run-pplan-courts.md` documents it (assigned to A8).

### A8 docs + changelog + version + cross-namespace + receipts (LAST)
- `docs/**` incl. `docs/jira/v26.11.4/`, `docs/thesis/`,
  `docs/how-to/run-pplan-courts.md`
- `README.md`, `mix.exs`, `mix.lock`, `CHANGELOG.md`
- `lib/ash_a2a/telemetry_bridge/**` (pplan_hazard.ex),
  `test/telemetry_bridge/**`, `lib/ash_a2a/ingress/**` (channel.ex),
  `test/ingress/**`
- `test/replan/` dual-homed with A7 — disclose at staging (A8 keeps the dir
  only if A7 already landed it; A7 lands it)
- `receipts/pplan-courts-20261107.md`, `receipts/lanes/**`
- `research/erc/*.json` (48 files) — UNRESOLVED-coordinator: ERC run
  artifacts commit-or-ignore; no gitignore rule exists and G18/AR9 never
  classified them. Do NOT stage until resolved.
- X-wave check: no X-wave files visible on disk (find -newermt 16:55 over
  a2a lib/test/docs returned nothing post-16:55; docs/thesis/ and
  docs/jira/v26.11.4/ are the only post-v2 docs landings, assigned A8).
- Gate: `mix test` full suite; session receipt
  `receipts/pplan-courts-20261107.md`.

## ggen-marketplace groups (baseline 1af488694; porcelain 26 entries)

### M1 cscb pack
- `packs/challenger-sales-cscb/**` MINUS hard blocks
  `packs/challenger-sales-cscb/.ggen/keys/signing.key` (ed25519 private
  seed, HARD BLOCK) and `verifying.key`. Double coverage verified
  (pack-level `.ggen/keys/.gitignore` + root `**/.ggen/keys/` +
  `**/signing.key`; porcelain shows zero key leakage).
- Gate: `python3 packs/challenger-sales-cscb/verify.py` +
  `mix run packs/challenger-sales-cscb/qualification/verdict_court.exs`
  (receipt: `receipts/cscb-ingress-run-2026-11-07.md`).

### M2 electrical + plumbing packs
- `packs/trade-reticle-electrical/**`, `packs/trade-reticle-plumbing/**`
  (no .ggen/keys dirs in these packs — checked; nothing to hard-block)
- Gate: `python3 packs/trade-reticle-electrical/verify.py` +
  `python3 packs/trade-reticle-plumbing/verify.py`.

### M3 registration + changelog + verify scripts
- `marketplace.active.toml` (M), `docs/reference/PACK-INDEX.md` (M),
  `docs/how-to/run-a-cscb-benchmark.md` (untracked), `CHANGELOG.md` (M),
  `scripts/verify_enterprise_kudzu_profile.py` (M),
  `scripts/verify_msct_profile.py` (M)
- Gate: M1/M2 verify.py gates are the proving commands; registration is
  validated by the conformance-receipt lineage run.

### M4 .ggen-v2 receipts — NOTHING TO STAGE (resolved: ignored-not-staged)

### M5 post-G18 marketplace landings (NEW group, not in v2)
- `packs/ash-pplan-igniter-pack/**` (README, ggen.toml, pack.toml,
  ontology.ttl, gates/, templates/, `lib/mix/tasks/ash_pplan.gen.workflow.ex`;
  its .ggen-v2 receipts + .ggen/keys are hard-blocked by root rules — keys
  present on disk, porcelain shows no key leakage)
- Pack READMEs: `packs/{cargo-cicd,fastmcp,rmcp,sa2a-fastapi,` +
  `typer-azure,challenger-value-framing}/README.md`
  (challenger-value-framing also has `chicago/` dir),
  `packs/typer-azure-pack/{consumer_contract.md,gates/}`
- `packages/pm4playwright/**` + `packages/pm4vitest/**` (148 files excl.
  node_modules/test-results/dist; node_modules covered by .gitignore:78)
- `receipts/cscb-e2e-run-2026-11-07.md` (post-G18 receipt)
- STAGING GAP (NEW, FA1 finding): `packages/pm4playwright/dist/` and
  `packages/pm4playwright/test-results/` are NOT gitignored
  (check-ignore matched only `node_modules/` at .gitignore:78).
  REQUIRED pre-step: add `packages/*/dist/` + `packages/*/test-results/` to
  marketplace .gitignore, or enumerate M5 staging file-by-file.
- Gate: `npm test --prefix packages/pm4vitest`; pm4playwright via
  `npx playwright test --config packages/pm4playwright/playwright.config.ts`.
- Gate adequacy: NOT-RUN — FA1 issued the manifest (census + path
  resolution only); gates are the coordinator's staging-time obligations.

## Must-not-commit lists + gitignore coverage proof

- ash_pplan (re-read from /Users/sac/ash_pplan/.gitignore): `/_build/`,
  `/_build-*/` (covers _build-dem, _build-g17, _build-lane*),
  `/_build_playground2/` (line 48), `/doc/`, `/documentation/`,
  `/.clap-noun-verb/`, `/.ggen_igniter/`, `/erl_crash.dump`,
  `/ash_pplan-*.tar`, `/scripts/.venv/`, `bin/__pycache__/` (line 38),
  `.DS_Store` (line 43), `_build-lane*/` (line 44, unanchored), `/tmp/`
  (line 9).
  GAP (NEW, FA1 finding): `/_build_playground/` (underscore form, no 2) is
  on disk and NOT matched by `/_build-*/` or `/_build_playground2/` —
  recommend one-line add `/_build_playground/`.
  GAP (flag 1): `scripts/__pycache__/` unignored.
- ash_a2a (re-read): `/_build/`, `/_build-*/` — covers all on-disk variants
  (_build-ar8, _build-laneA10/11/15, _build-laneB4/B5/G4/G5/W3/Z*). No gap.
- ggen-marketplace: hard blocks `**/.ggen/keys/` + `**/signing.key` +
  `**/verifying.key` (root, verified in .gitignore), pack-level
  `.ggen/keys/.gitignore` in cscb + igniter packs, `node_modules/` (line 78),
  `.DS_Store` (42-43), `.ggen-v2/` (51-52), `__pycache__/` (31).
  GAP (M5 pre-step): `packages/*/dist/` + `packages/*/test-results/`.
  Hard-block proof: porcelain shows zero `??` touching any .ggen/keys path.

## Receipt

- Lane: FA1. Manifest path:
  /Users/sac/ash_pplan/notes/seal-manifest-v3-2026-11-07.md
- Group counts: ash_pplan 8 (P1-P8), ash_a2a 8 (A1-A8),
  ggen-marketplace 5 (M1-M5; M4 empty-by-resolution).
- Flags resolved: 4/4 (scripts/__pycache__ gitignore add REQUIRED pre-step;
  .DS_Store covered no-action; .ggen-v2 ignored-not-staged M4 empty;
  reclaimed-home COMMIT in P7). Plus 2 NEW flags FA1 found:
  packages/*/dist/ + test-results/ ignore gap (M5 pre-step);
  research/erc/ 48 files commit-or-ignore UNRESOLVED-coordinator.
- Commands (all read-only): `git status --porcelain` x3 repos,
  `git log --oneline -1 -- .gitignore` (marketplace),
  `git check-ignore -v` (tmp/, bench, pm4 dist/test-results/node_modules),
  `git diff` on receipts/INDEX-2026-10-03.md,
  existence loops over all grouped paths (bash for-loops), `find -newermt
  "2026-11-07 16:55"` post-G18 sweep x2. Exit codes: 0 except
  check-ignore exit 1 on dist/test-results — which IS the M5 gap finding.
- Gates: NOT-RUN by FA1 — census-only lane; gates are the coordinator's
  staging-time obligations, each group carries its gate command.
- Markdown law: H1 matches filename, Standing line present, line length
  under 100 chars, kebab-case filename.
