# Seal Rehearsal Manifest v2 — Lane G18 (2026-11-07)

Standing: PASS

Supersedes Y2's stale manifest. Census method: `find -newermt` per repo —
ash_pplan post-`eb4260f` (2026-11-07 12:19:45), ggen-marketplace post-`1af488694`
(2026-11-07 12:19:08), ash_a2a mtime >= 2026-11-07 00:00 (session window). No git
state commands used; filesystem census only. Generated trees (`doc/`,
`documentation/`, `_build*`, `deps/`, `.clap-noun-verb/`) excluded from census.

## Census counts (real, from find)

| repo | session-touched files | .ex/.exs swept | syntax OK | syntax FAIL |
|---|---|---|---|---|
| /Users/sac/ash_pplan | 281 | 140 | 140 | 0 |
| /Users/sac/ash_a2a | 81 | 51 | 51 | 0 |
| /Users/sac/ggen-marketplace | 113 | 31 | 31 | 0 |
| total | 475 | 222 | 222 | 0 |

Syntax sweep: `Code.string_to_quoted` over every session .ex/.exs (MIX_ENV=test
where mix project). Result 222 OK / 0 FAIL, exit 0.

## ash_pplan commit groups (baseline eb4260f)

- **P1 durability completions** — `lib/ash_pplan/reactor/durable/**` (engine,
  run, checkpointed, stores ets/dets/wal, ring_buffer, health_gate,
  lease_monitor, compensations/dispatch+poll), `test/durable/**` (chaos
  properties, WAL, lease, store conformance), `test/support/durable/**`,
  `checkpoints/research200-tla-court.txt`, `priv/tla/durable/DurableProtocol.tla`.
  Gate: `mix compile --warnings-as-errors` then `mix test test/durable`.
- **P2 POWL namespace** — `lib/ash_pplan/powl.ex`, `lib/ash_pplan/powl/**`,
  `test/powl/**`, `test/compiler_powl_seam_test.exs`,
  `examples/powl_engine_demo.exs`, `docs/how-to/powl-engine-demo.md`.
  Gate: `mix test test/powl test/compiler_powl_seam_test.exs`.
- **P3 telemetry namespace** — `lib/ash_pplan/telemetry/**`
  (emit.ex, emit/{event,buffering_emitter,noop}.ex, event.ex, broadcaster.ex),
  `lib/ash_pplan/playground/telemetry_broadcaster.ex`, `test/telemetry/**`.
  Gate: `mix test test/telemetry`.
- **P4 airbus namespace** — `lib/ash_pplan/airbus/turtle.ex`,
  `bin/airbus-oracle-gate`, `scripts/airbus_oracle_daemon.py`,
  `scripts/airbus_oracle_README.md`, `test/courts/airbus_corpus_parity_test.exs`,
  `test/courts/airbus_fond_differential_test.exs`,
  `test/support/airbus_oracle.ex`, `test/support/airbus_fond_oracle.ex`,
  `priv/courts/airbus_parity.receipt`, `bench/claims_bench.exs`,
  `bench/CLAIMS-BASELINE-2026-11-07.md`.
  Gate: `mix test test/courts/airbus_corpus_parity_test.exs test/courts/airbus_fond_differential_test.exs`
  (session receipt: `priv/courts/airbus_parity.receipt`).
- **P5 providers/workflow/capability** — `lib/ash_pplan/providers/**`,
  `lib/ash_pplan/workflow/**`, `lib/ash_pplan/catalog/projection_catalog.ex`,
  `lib/ash_pplan/{compiler,obligation}.ex`, `lib/ash_pplan/standing/receipt.ex`,
  `lib/ash_pplan/release_receipt.ex`, `lib/ash_pplan/execution_receipt.ex`,
  `lib/ash_pplan/{reactor,ash_pplan}.ex`, `test/support/examples/**`,
  `test/courts/examples/**`, `test/hardening/**`,
  `test/{execution_receipt,state_machine,ash_pplan}_test.exs`,
  `test/fond_subject_test.exs`, `test/fond/**`, `test/compiler_powl_seam_test.exs`
  (dual-homed with P2 — disclose at integration),
  `documentation/dsls-regen-2026-11-07.md` note only —
  **`/documentation/` is gitignored (regenerable via mix docs)**.
  Gate: `mix test test/courts/examples` and `mix test test/hardening`.
- **P6 docs DoD + changelog/version** — `docs/**` (diataxis tree, PRD-ARD,
  PACKAGE-BOUNDARY, POST-ARCHIVE-MAP, architecture, demonstration),
  `README.md`, `CHANGELOG.md`, `mix.exs` (version bump), `ggen.toml`,
  `ontology.ttl`, `ontology/fond_tla.ttl`,
  `priv/ggen/ash-pplan-pack/ontology.ttl`,
  `priv/ggen/ash-pplan-workflow-pack/ontology.ttl`, `planning/README.md`,
  `.gitignore` (lane-lease entries). Gate: `bin/gate`.
- **P7 receipts/notes** — `receipts/v26117-{session-receipt,defect-register,
  hex-preflight}-2026-11-07.md`, `receipts/v26.11.7-release-prep-2026-11-07.md`,
  `receipts/v7-package-boundary-2026-11-07.md`,
  `notes/landing-manifest-2026-11-07.md`,
  `notes/v26117-wave-ledger-2026-11-07.md`,
  `notes/archive/reclaimed-home/**` (reclaimed-home moved under archive/ —
  `/notes/reclaimed-home/` ignore does not cover `notes/archive/reclaimed-home/`,
  so these are committable; verify intent at staging),
  `notes/{chicago-adoption,ferroplan-fond-verdict,ggen-igniter-feature-audit,
  graphlaw-engine,graphlaw-wasm-api-survey,ocel-vocabulary-audit,
  receipt-schema-diff-2026-10-03,sa2a-adapter-verdict,twin-handoff-ash-a2a}.md`.
  Gate: `grep -L '^Standing:' receipts/v26117-*.md notes/*2026-11-07*.md` → empty output.
- **P8 marketplace_sim repairs** — `test/marketplace_sim/**`,
  `test/support/marketplace_sim/web/{dashboard_live,lifecycle_live}.ex`,
  `test/support/playground/**`, `bin/playground`, `bin/playground_boot.exs`.
  Gate: `mix test test/marketplace_sim`.

## ash_a2a commit groups (session window 2026-11-07)

- **A1 twin namespace** — `lib/ash_a2a/twin.ex`,
  `lib/ash_a2a/twin/{tony,vince,operator,asset,hazard,lease,server,partner}.ex`,
  `test/twin/{twin,tony,vince}_test.exs`,
  `notes/hilt-graph-digest-census-2026-11-07.md`.
  Gate: `mix test test/twin`.
- **A2 strain** — `lib/ash_a2a/strain/{bridge,tensor}.ex`, `test/strain/**`.
  Gate: `mix test test/strain`.
- **A3 attestation + authority** — `lib/ash_a2a/attestation/{gate,key}.ex`,
  `lib/ash_a2a/authority/{graph_pin,pep,source}.ex`,
  `lib/ash_a2a/authority/source/{allow_all,deny_all}.ex`,
  `test/attestation/attestation_gate_test.exs`,
  `test/authority/{graph_pin,pep}_test.exs`.
  Gate: `mix test test/attestation test/authority`.
- **A4 copilot pipeline** — `lib/ash_a2a/copilot/pipeline.ex`,
  `test/copilot/pipeline_test.exs`, `examples/copilot_demo.exs`,
  `docs/how-to/{copilot-demo,run-the-copilot-pipeline}.md`,
  `docs/explanation/copilot-membrane.md`.
  Gate: `mix test test/copilot`.
- **A5 actuation + dispatch durability** — `lib/ash_a2a/actuation/{engine,adapter,ticket}.ex`,
  `test/actuation/engine_court_test.exs`,
  `test/execution/{pplan_dispatch_durability,task_run_binding}_test.exs`,
  `test/ash_a2a_margin_gate_e2e_test.exs`.
  Gate: `mix test test/actuation test/execution test/ash_a2a_margin_gate_e2e_test.exs`.
- **A6 negotiation + attention** — `lib/ash_a2a/negotiation/{engine,strategy,default_strategy}.ex`,
  `lib/ash_a2a/attention/broker.ex`, `test/negotiation/negotiation_engine_court_test.exs`,
  `test/attention/broker_court_test.exs`.
  Gate: `mix test test/negotiation test/attention`.
- **A7 I-wave courts + runner/toggle** —
  `test/ash_a2a/replan/ash_pplan_port_parity_court_test.exs`,
  `test/ash_a2a/replan/port_ashpplan_conformance_court_test.exs`,
  `lib/mix/tasks/ash_a2a.pplan_courts.ex` (runner+toggle),
  `test/ash_a2a_pplan_ocel_evidence_court_test.exs`.
  Gate: `mix ash_a2a.pplan_courts` (the mix task is the runner).
- **A8 docs+changelog+version + cross-namespace** — `docs/**`, `README.md`,
  `CHANGELOG.md`, `mix.exs`, `mix.lock`,
  `lib/ash_a2a/telemetry_bridge/pplan_hazard.ex`,
  `test/telemetry_bridge/pplan_hazard_bridge_test.exs`,
  `lib/ash_a2a/ingress/channel.ex`, `test/ingress/channel_test.exs`,
  `test/ash_a2a/replan/...` dual-homed with A7 (disclose),
  `receipts/pplan-courts-20261107.md`,
  `receipts/lanes/{a10-ingress-wire,z11-actuation,z18-kill-court}.md`.
  Gate: `mix test` full suite; session receipt `receipts/pplan-courts-20261107.md`.

## ggen-marketplace commit groups (baseline 1af488694)

- **M1 cscb pack** — `packs/challenger-sales-cscb/**` MINUS
  `packs/challenger-sales-cscb/.ggen/keys/signing.key` (ed25519 private seed,
  hard block) and `verifying.key`. Double gitignore coverage verified
  (pack-level `.ggen/keys/.gitignore` + root `**/.ggen/keys/` and
  `**/signing.key`). Includes ontology.ttl, shapes.ttl, gates/, queries/,
  templates/ (+ rust/), generated/arc_verdict.ex, lib/cscb_*.ex (10 modules),
  qualification/ courts+fixtures, verify.py, BINDING_CONTRACT.md, README.md,
  pack.toml, ggen.toml, priv/domains/ingress_settlement.ttl.
  Gate: `python3 packs/challenger-sales-cscb/verify.py` and
  `mix run packs/challenger-sales-cscb/qualification/verdict_court.exs`
  (session receipt: `receipts/cscb-ingress-run-2026-11-07.md`).
- **M2 electrical + plumbing packs** — `packs/trade-reticle-electrical/**`,
  `packs/trade-reticle-plumbing/**`, same keys hard block and same coverage.
  Gate: `python3 packs/trade-reticle-electrical/verify.py` and
  `python3 packs/trade-reticle-plumbing/verify.py`.
- **M3 registration + changelog + receipts** — `marketplace.active.toml`,
  `docs/reference/PACK-INDEX.md`, `docs/how-to/run-a-cscb-benchmark.md`,
  `CHANGELOG.md`, `receipts/cscb-{ingress-run,registration}-2026-11-07.md`,
  `receipts/trade-reticle-validation-2026-11-07.md`,
  `scripts/verify_enterprise_kudzu_profile.py`,
  `scripts/verify_msct_profile.py`. Gate: pack verify.py gates in M1/M2 are
  the proving commands; registration file validated by the same
  `_CDBR_V1_MULTIPACK_CONFORMANCE_RECEIPT.md`-lineage conformance run.
- **M4 `.ggen-v2/` receipts** — `packs/*/.ggen-v2/{receipt.json,receipt-log.jsonl}`.
  Root .gitignore has no `.ggen-v2` rule. DECISION REQUIRED at staging:
  commit as receipts (recommended — receipt-standing-law: receipts are
  evidence) or add ignore rule. Flagged, not staged.

## Must-not-commit lists + gitignore coverage proof

- **ash_pplan**: `_build*/`, `doc/`, `documentation/`, `deps/`,
  `.clap-noun-verb/`, `.ggen_igniter/`, `erl_crash.dump`,
  `ash_pplan-26.11.7.tar`, `scripts/.venv/`, `bin/__pycache__/`,
  `.claude/settings.local.json`, all `_build-lane*/` roots.
  Proof (re-read from /Users/sac/ash_pplan/.gitignore): `/_build/`, `/_build-*/`,
  `/doc/`, `/documentation/`, `/.clap-noun-verb/`, `/.ggen_igniter/`,
  `/erl_crash.dump`, `/ash_pplan-*.tar`, `/scripts/.venv/`,
  `bin/__pycache__/` all present. **GAP**: `scripts/__pycache__/` is on disk
  (airbus_oracle_daemon bytecode) and NOT ignored — one-line gitignore add
  before staging.
- **ash_a2a**: `_build*/`, `deps/`, `doc/`, `erl_crash.dump`,
  `_build-lane*/`. Proof (re-read from /Users/sac/ash_a2a/.gitignore):
  `/_build/`, `/_build-*/`, `/doc/`, `erl_crash.dump` (unanchored), lane roots
  covered. No gap.
- **ggen-marketplace**: hard block `packs/*/.ggen/keys/signing.key` +
  `verifying.key` — verified at both pack level and root level
  (`**/.ggen/keys/`, `**/signing.key`). No gap. **LOW gap**: `.DS_Store` has no
  rule in marketplace root .gitignore — one-line add before staging.

## Receipt

- Lane: G18 seal rehearsal v2. No commits, no staging, no git state commands.
- Manifest path: /Users/sac/ash_pplan/notes/seal-rehearsal-v2-2026-11-07.md
- Census commands: `find -newermt` x3, exit 0 (bfs warned on a dangling
  `_build/test/lib/ash_pplan/consolidated` symlink — census unaffected).
- Gates: syntax sweep `elixir /tmp/g18_syntax.exs` x3 → 222 OK / 0 FAIL,
  exit 0; gitignore coverage re-read from 4 .gitignore files on disk.
- Group counts: ash_pplan 8 groups (P1-P8); ash_a2a 8 groups (A1-A8);
  ggen-marketplace 4 groups (M1-M4). 2 flagged decisions for the coordinator:
  `.ggen-v2/` receipts commit-or-ignore; `notes/archive/reclaimed-home/`
  committability intent.
