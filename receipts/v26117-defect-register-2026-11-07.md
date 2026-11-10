# v26.11.7 Cross-Repo Defect Register — 2026-11-07 (Lane B9; refreshed by Lane G10; final flip by Lane F15)

Standing: PASS

Consolidates every defect found this session across `/Users/sac/ash_pplan`,
`/Users/sac/ash_a2a`, `/Users/sac/ggen-marketplace` (plus ggen_igniter rows
inherited from the session receipt). Sources: wave ledger
(`notes/v26117-wave-ledger-2026-11-07.md` incl. B1 refresh), Y3 session
receipt (`receipts/v26117-session-receipt-2026-11-07.md`), Y4 dispositions
(SR — no disk receipt), V1/V2/V3/V5/V8/V10 (no disk receipts — UNVERIFIED
rows with reason), V7 (`receipts/v7-package-boundary-2026-11-07.md`),
V9 (`/Users/sac/ash_a2a/receipts/pplan-courts-20261107.md`), A5/A15 (no disk
receipts — SR), F-lane (no disk receipts; F1 witnessed via G7 note), Z-lane
findings (Z12 census, A10 lane receipt), B6 hex preflight
(`receipts/v26117-hex-preflight-2026-11-07.md`), A14 release prep
(`receipts/v26.11.7-release-prep-2026-11-07.md`), Y2 landing manifest
(`notes/landing-manifest-2026-11-07.md`), A12
(`/Users/sac/ggen-marketplace/receipts/trade-reticle-validation-2026-11-07.md`),
G7 (`/Users/sac/ggen-marketplace/notes/fm-pack-008-relock-blocked.md`),
G8 (`/Users/sac/ggen_igniter/notes/inflight-triage-2026-11-07.md`), g3
(`/Users/sac/ggen-marketplace/WAVE-RECEIPT-g3.md`), plus session-record (SR)
rows marked stale-by-default.

Status vocabulary: FIXED (disk-proved) · FIXED-SR (closed in session record
only — stale-by-default, re-verify before citing) · IN-REPAIR (lane active) ·
OPEN (documented, owner named) · BLOCKED (operator-gated) · WONTFIX
(documented boundary, upstream or citation-class) · UNVERIFIED (no receipt
either way).

## FIXED (disk-proved)

| ID | Surface | Defect | Discovered by | Status | Evidence |
|---|---|---|---|---|---|
| DR-01 | ash_pplan mix.exs `package_files/0` | Hex packer recursed directory entries wholesale, dragging playground/telemetry receipts into the tar (D-08 + root cause of D-07) | A14 | FIXED — `File.dir?` reject clauses added to lib/priv/docs branches; census ABSENT 0 hits per probed path; consumer compile gate exit 0 (171 files, prod, warnings-as-errors) | `/Users/sac/ash_pplan/receipts/v26.11.7-release-prep-2026-11-07.md` |
| DR-02 | ash_pplan hex package | Unpacked prod compile exit 1: `Playground.TelemetryBroadcaster` needs Phoenix.PubSub; phoenix is dev/test-only (mix.exs:113) (D-07) | V7 | FIXED in packaged artifact — playground ABSENT from tar after DR-01 fix; repo-tree `:pg.start/0` warning at `playground/telemetry_broadcaster.ex:113` remains OPEN (DR-14) | V7 receipt check 3 (REAL exit 1, ×2) + A14 receipt consumer compile gate |
| DR-03 | ggen-marketplace trade-reticle-plumbing pack, ClaimShape | tr:claim-drain-001 minCount violation in pack | A12 | FIXED in-pack — gates re-green: ggen sync 0, verify.py 0, marketplace validate 0 (353 packs), SHACL conforms true | `/Users/sac/ggen-marketplace/receipts/trade-reticle-validation-2026-11-07.md` |
| DR-04 | ash_a2a `AshA2A.Authority.GraphPin.assert_fresh/3` | Malformed digest `"sha256:ZZ"` returned `:stale_graph_identity` instead of `:invalid_digest` | Z12 court | FIXED pre-landing — format check now precedes comparison; court 4/0 | `/Users/sac/ash_a2a/notes/hilt-graph-digest-census-2026-11-07.md` |
| DR-05 | ash_a2a `lib/ash_a2a/ingress/channel.ex` court (4 session-introduced: `now:` not forwarded; nil `max_staleness_sec` defeated freshness via `3600 <= nil`; teleport test 90s gap above 60s jump window; helper ignored camera_make override) | Ingress gate defects found by its own court | A10 | FIXED in-court — 11 tests, 0 failures, exit 0 | `/Users/sac/ash_a2a/receipts/lanes/a10-ingress-wire.md` |
| DR-06 | ash_pplan `lib/ash_pplan/reactor/durable/store/wal.ex` | Delimiter syntax error mid-flight (witnessed ~14:25 during Y2 census) | Y2 | FIXED — repaired by owning lane (mtime 14:21:50); re-scan passes (101/101 ok) | `/Users/sac/ash_pplan/notes/landing-manifest-2026-11-07.md` |
| DR-07 | ash_a2a `lib/ash_a2a/strain/bridge.ex` `fatigued?/1` | Called nonexistent `error_drift_rising?/1`; broke shared compile | A10 (SLA unblock) | FIXED — A10 applied minimal unblock; owning lane landed `drift_rising_on_window?/1` superseding it (net zero diff of A10's) | `/Users/sac/ash_a2a/receipts/lanes/a10-ingress-wire.md` (SLA disclosure) |
| DR-30 | ash_a2a full compile | Pre-existing compile blockers: `lib/ash_a2a/copilot/pipeline.ex` (`record/3` undefined, :121/:126) and `lib/ash_a2a/authority/source/allow_all.ex:8` | Z12 | FIXED (G10 refresh: `mix compile` exit 0, warnings only, 2026-11-07) | `/Users/sac/ash_a2a/notes/hilt-graph-digest-census-2026-11-07.md` + G10 compile run |

## FIXED-SR (closed in session record only — stale-by-default)

| ID | Surface | Defect | Discovered by | Status | Evidence |
|---|---|---|---|---|---|
| DR-08 | ash_pplan OCEL/binding digest | Cross-confirmed digest defect (D-02) | V-wave cross-confirm | FIXED (SR) — no disk receipt; re-verify before citing | wave ledger defect table + session receipt |
| DR-09 | ash_pplan subject sort (D-03) | Cross-confirmed sort defect | V-wave cross-confirm | FIXED (G10 refresh: dispatch-directed; durable-test census spot-check) | same + G10 dispatch |
| DR-10 | ash_pplan terminal-signal orphan (D-05) | Cross-confirmed orphan | V-wave cross-confirm | FIXED by A5 — disk-proved by G10: `test/durable/engine_terminal_signal_test.exs` exists, 2 tests 0 failures exit 0 | same + G10 disk check |
| DR-11 | ash_pplan V5 WAL defect set (D-06) | WAL defect set filed by V5, closed by A5 | V5 (no disk receipt) → closed by A5 | FIXED (G10 refresh: `test/durable/store_conformance_wal_test.exs` 19 tests 0 failures, exit 0 — observed 19/0, not the dispatch's 13/14) | same + G10 test run |
| DR-12 | docs wave doc diverges | Doc diverges from authored content | Y4 | FIXED by Y4 (SR) — Y4 receipt never materialized | wave ledger refresh NEW row |
| DR-13 | ash_pplan lease-vs-caller (D-04) + Elixir cross-version stale-beam class | Lease/caller confusion; stale-beam environment class | V-wave; R1/R2 | FIXED — hardened per dispatch (G10 spot-check: `test/durable/d4_failed_settle_store_survival_test.exs` on disk); R1/R2 receipts absent from disk | wave ledger footnote 2 + G10 disk check |

## FIXED (disk-proved), F15 flips

| ID | Surface | Defect | Discovered by | Status | Evidence |
|---|---|---|---|---|---|
| DR-34 | ggen-marketplace `packs/challenger-sales-cscb/verify.py` (was: "ash_pplan signal registration race" — repo/path confusion in G10's check) | Registration-race window in signal claim path | G10 dispatch (post-register) | FIXED (F15 flip from FIXED-SR) — verify.py EXISTS at `/Users/sac/ggen-marketplace/packs/challenger-sales-cscb/verify.py` (ls hit, this lane); G10's not-found was a repo/path confusion | G10 dispatch; F15 disk check positive 2026-11-07 |
| DR-31 | ash_pplan B10-D1 resolver seam (alias: B10-D1) | Namespaced annotation property (curie binary containing ":") was not distinguishable from an execution-property claim in resolver qualification | G10 dispatch | FIXED (F15 flip from IN-REPAIR) — seam landed on disk: `lib/ash_pplan/providers/resolver.ex:75-90` "Property qualification law (B10-D1)": strict static intersection preserved; namespaced annotations qualify by construction and carry through realization; `missing_properties` refusal path unchanged (read on disk by F15) | `lib/ash_pplan/providers/resolver.ex:75-90` + F15 read 2026-11-07 |
| DR-38 | ggen-marketplace cscb pack emission path | AR6 P0 label-injection RCE: hostile ArcStage label broke out of the emitted Rust string literal and compiled attacker bytes; P1 rogue stage (typed, never arc-bound) silently excluded from emission; P2 10MB label reached emission | AR6 | FIXED by R15 — hardening receipt on disk: gate 040 charset law (sync-refusing, FM-LAW-018), gate 050 orphan-stage refusal, SHACL label pattern + query-layer Rust escaping as defense-in-depth; attack replay matrix 4/4 REFUSED/inert after R15 | `/Users/sac/ggen-marketplace/packs/challenger-sales-cscb/receipts/cscb-emission-hardening-2026-11-07.md` + `gates/040_label_safety.rq`, `gates/050_orphan_stage.rq` on disk (F15 verified) |
| DR-39 | ggen-marketplace cscb pack `lib/cscb_receipt.ex` `render_markdown/1` | AR7 markdown injection: unescaped `\|` in measured data could break the metric table in rendered receipts | AR7 | FIXED by X3 — `esc_md/1` escapes every interpolated value (lib/cscb_receipt.ex:200-215, 361-370; read on disk by F15); README:69 documents the law | `lib/cscb_receipt.ex` + README.md:69 |
| DR-40 | ggen-marketplace cscb pack `CscbReceipt.mint/2` verdict slot | AR7 verdict-slot vocabulary: out-of-vocabulary verdict atoms (e.g. `:pass`) minted unvalidated | AR7 | FIXED — verdict slot validates against the closed set (`:status_quo_refused`, `:adopted`, `:inconclusive`) at mint, out-of-vocabulary refused `{:error, {:invalid_verdict, value}}` (README.md:66-73, read on disk by F15) | README.md:66-73 + `qualification/verdict_court.exs` on disk |
| DR-43 | ggen-marketplace cscb pack adversarial surface | AR1's 7 exploited attack vectors (fabricated economics feeds, self-forged stamps, unattested inputs) | AR1 | FIXED by AR1 — adversarial court re-run by F15 this lane: `elixir qualification/ar1_adversarial_court.exs` → **8 defended / 0 exploited, exit 0** (real run, 2026-11-07) | `qualification/ar1_adversarial_court.exs` + F15 run exit 0 |
| DR-37 | ggen-marketplace cscb pack arc admission (`lib/cscb_arc.ex`) | AR4's 2 exploited arc vectors: non-admitted metrics laundered into the receipt bundle alongside admitted ones; payload tampering paths | AR4 | FIXED by AR4's admitted-only storage fix — `lib/cscb_arc.ex:93,112-123` filters metrics through `CscbMetricAdmission.admit/1` + `impact_mapped?/1` before storage (read on disk by F15); arc court re-run by F15: **19/19 passed, exit 0** (real run, 2026-11-07) | `lib/cscb_arc.ex` + `qualification/arc_court.exs` + F15 run exit 0 |

## IN-REPAIR

(empty — DR-31 flipped FIXED by F15; no lanes in repair at pre-seal)

| ID | Surface | Defect | Discovered by | Status | Evidence |
|---|---|---|---|---|---|

## OPEN (documented, owner named)

| ID | Surface | Defect | Discovered by | Status | Evidence |
|---|---|---|---|---|---|
| DR-14 | ash_pplan `lib/ash_pplan/playground/telemetry_broadcaster.ex:113` | `:pg.start/0 is undefined or private` warning; `mix compile --warnings-as-errors` fails in repo tree (file does not ship) | A14 | OPEN — playground lane owner to fix | A14 receipt, cross-lane finding |
| DR-15 | ash_pplan durable engine | Durable-engine unwind window (D-01) | V-wave cross-confirm | OPEN — no closure seen | session receipt defect ledger |
| DR-16 | ggen_igniter FM-LAW-015 | Premise rot: EA gate added post-tests | G8 | OPEN — adjudicated substrate-class, on-pin re-run required | `/Users/sac/ggen_igniter/notes/inflight-triage-2026-11-07.md` |
| DR-17 | ggen_igniter gall-ticket test | 300s timeout, load-sensitive flake | G8 | OPEN (flaky) | same |
| DR-18 | ggen_igniter env | OTP 28.3.1 vs pin 27.2.4; receipt.schema.json external drift | G8 | OPEN (environment drift) | same |
| DR-19 | ash_pplan hex package `bin/receipt` | Zero-arity git-bound repo-tool shipped in package (LOW) | V7 check 5 | OPEN-documented — no packaging impact today | V7 receipt check 5 |
| DR-20 | ash_pplan tarball checksum | Checksum UNSTABLE across builds — concurrent lane edits during builds; final checksum must be re-minted on quiescent tree at seal | A14 | OPEN — coordinator action at seal | A14 receipt, caveat section |
| DR-21 | ash_pplan `_build_playground2/` | Untracked build dir NOT gitignored — seal-commit hygiene | A14 | OPEN — coordinator: gitignore or delete before seal | A14 receipt, stray flag |
| DR-22 | ash_pplan lane build roots ~8.7 GB + ash_a2a ~7.6 GB + /tmp scratch + bin/__pycache__ | Lease build roots pending deletion at integration (fan-out cleanup law) | Y2 | OPEN — coordinator deletes after final gates, before seal commit | `/Users/sac/ash_pplan/notes/landing-manifest-2026-11-07.md` leftovers section |
| DR-23 | ash_pplan per-lane receipts | Receipts for E/P/G/D/I/V/R/X/F/Z waves never materialized on disk (session-context IDs law) | Y3 ledger open item 1 | OPEN — process defect: future waves write receipts as a gate | wave ledger open items |
| DR-24 | ash_pplan release gates | Hex publishing key not configured (`api_key: nil`) — publish will fail auth | B6 | BLOCKED — operator must auth before publish | `/Users/sac/ash_pplan/receipts/v26117-hex-preflight-2026-11-07.md` |
| DR-25 | ggen-marketplace strata-ledger + qri-consumer-binding packs | FM-PACK-008 lock drift; re-lock BLOCKED: installed ggen 26.11.4 ≠ frozen-court pin v26.8.11 (D-09) | audit M16/F1 via G7 | BLOCKED — operator remediation steps written | `/Users/sac/ggen-marketplace/notes/fm-pack-008-relock-blocked.md` |
| DR-26 | ggen_igniter full suite | 1763 tests, 9–10 failures all adjudicated substrate-class (rows DR-16/17/18) | G8 | OPEN (aggregate) — full suite exit 2 until on-pin re-run | G8 triage receipt |
| DR-32 | Apple Silicon timing | CNTVCT counter resolution on Apple Silicon — timing baseline skew | R7 | OPEN-ticketed — no receipt/ticket file found on disk by G10 | G10 dispatch |
| DR-33 | BEAM comparator vs Rust runner | Low-alloc measured not-zero — comparator/runner allocation asymmetry, documented boundary | R11 | OPEN-documented | G10 dispatch |
| DR-35 | ash_pplan WAL `mark_undone` | Re-mark divergence in `mark_undone` path | F8 | OPEN-documented per F8 | G10 dispatch |
| DR-36 | ash_pplan durable ring buffer | Ring latency budget vs <10µs claim — S2 re-measure landed a real receipt (supersedes G10's UNVERIFIED and the 54µs figure) | G10 dispatch; re-measured by S2 | OPEN-documented (F15 reclass from UNVERIFIED) — `bench/CLAIMS-BASELINE-2026-11-07.md` post-Z5 + S2 sections on disk: solo p99 4-9µs MET; 8-writer p95/p99 UNMET vs <10µs (32/66µs per S2, 4.6ms/12ms per pre-S2 run — load-dependent); concurrent UNMET finding stands | `bench/CLAIMS-BASELINE-2026-11-07.md` + S2 bench run exit 0 |
| DR-41 | ggen-marketplace cscb pack arc admission | AR4's third exploited vector: cross-bind proposal (metric-to-impact binding across arcs) — proposal documented, no fix landed | AR4 | OPEN — proposal only; no disk receipt or fix found by F15 (searched pack lib/, receipts/, notes/) | coordinator dispatch (AR4 addendum) |
| DR-42 | ggen-marketplace cscb pack `CscbAttest` | AR7 nonce-binding proposal: run-to-machine stamps use nonce + profile digest; binding nonces to run identity proposed, not landed | AR7 | OPEN — proposal only; no fix on disk found by F15 | coordinator dispatch (AR7 addendum) + README.md:52-53 |
| DR-44 | ggen-marketplace cscb pack metric units | AR1 typed-unit-field finding — report-only (no exploit path) | AR1 | OPEN-documented (report-only per AR1); court is green (see DR-43) | coordinator dispatch (AR1 addendum) + court run |

## WONTFIX (documented boundary)

| ID | Surface | Defect | Discovered by | Status | Evidence |
|---|---|---|---|---|---|
| DR-27 | Reactor 1.0.7 upstream | Guard-skip executor: guard-skipped steps stay off the undo stack, so a replayed value returned from a guard could never be undone — executor-crash class; worked around by replaying through the step impl (`Checkpointed`) instead | D-docs / durability lane | WONTFIX-documented-boundary (upstream; documented design constraint) | `docs/diataxis/explanation/durable-ledger-and-stores.md` (~:39), `docs/diataxis/tutorials/durable-engine-tutorial.md` (~:191) |
| DR-28 | ggen-marketplace g3 ticket | `docs/jira/v26.9.18/g3-port-bridge-pack.md` path UNRESOLVABLE — never materialized in any repo (D-14) | M9/G2 | WONTFIX-documented — treat as session-context reference, no file to fix | `/Users/sac/ggen-marketplace/WAVE-RECEIPT-g3.md` citation note |

## UNVERIFIED (with reason)

| ID | Surface | Defect | Discovered by | Status | Evidence |
|---|---|---|---|---|---|
| DR-29 | erlmcp gen_statem | gen_statem registration drop — environment-class | Dispatch (SR) | UNVERIFIED — no disk receipt or doc found in any of the three repos (searched receipts/, notes/, docs/); dispatch named it environment-class only; G10: skipped per dispatch | coordinator dispatch |

## Count summary (re-read from this file at write time)

- FIXED (disk-proved): 19 (DR-01..07, DR-09..11, DR-13, DR-30, DR-31, DR-34,
  DR-37, DR-38, DR-39, DR-40, DR-43)
- FIXED-SR: 2 (DR-08, DR-12)
- IN-REPAIR: 0
- OPEN: 18 (DR-14..23, DR-26 aggregate; + DR-32, DR-33, DR-35, DR-36,
  DR-41, DR-42, DR-44)
- BLOCKED: 2 (DR-24, DR-25)
- WONTFIX: 2 (DR-27, DR-28)
- UNVERIFIED: 1 (DR-29)

Total 41 rows (DR-01..DR-44; DR-36 in OPEN, DR-41/42/44 in OPEN, DR-37/38/
39/40/43 in FIXED). OPEN enumeration: DR-14..23 (10), DR-26, DR-32, DR-33,
DR-35, DR-36, DR-41, DR-42, DR-44 = 18.

## Coverage standing

PASS — every disk receipt/notes file found this session in the three subject
repos is represented (Y3, V7, V9, A14, B6, Y2, A12, G7, G8, g3, Z12, A10,
twin-handoff, airbus-oracle README, cscb-emission-hardening receipt).
UNVERIFIED row (DR-29) carries an explicit reason per the standing law.

## Gate

Every evidence pointer above resolves to a file on disk (read by this lane
during consolidation) or names its SR provenance explicitly. No git commands
run.

## Addendum — Lane F15 final flip (2026-11-07, pre-seal)

Standing: PASS

Flips applied against CURRENT disk, every one spot-verified this lane:

1. **DR-34 FIXED-SR → FIXED**: verify.py exists at
   `/Users/sac/ggen-marketplace/packs/challenger-sales-cscb/verify.py`
   (ls hit). G10's not-found was a repo/path confusion; surface corrected.
2. **DR-31 IN-REPAIR → FIXED (B10-D1 alias)**: seam code landed at
   `lib/ash_pplan/providers/resolver.ex:75-90` (read on disk; strict
   static intersection preserved, namespaced annotation properties
   qualify by construction).
3. **DR-36 UNVERIFIED → OPEN-documented**: S2's re-measure receipt landed
   in `bench/CLAIMS-BASELINE-2026-11-07.md` (post-Z5 + S2 sections, read
   on disk); verification gap closed, budget itself UNMET at p95/p99
   under 8 writers, so OPEN not FIXED.
4. **New rows**: DR-37 (AR4 two arc vectors, FIXED — cscb_arc.ex
   admitted-only filter + arc court 19/19 exit 0 re-run), DR-38 (AR6 RCE,
   FIXED — R15 hardening receipt + gates 040/050 verified on disk),
   DR-39 (AR7 markdown injection, FIXED — esc_md), DR-40 (AR7 verdict-slot
   vocabulary, FIXED), DR-41 (AR4 cross-bind proposal, OPEN), DR-42 (AR7
   nonce-binding proposal, OPEN), DR-43 (AR1 7-exploits, FIXED — court
   re-run 8/0 exit 0), DR-44 (AR1 typed-unit-field, OPEN report-only).

Cheap probes run this lane: `elixir qualification/ar1_adversarial_court.exs`
→ 8 defended / 0 exploited, exit 0; `elixir qualification/arc_court.exs`
→ 19/19 passed, exit 0. All other flips are disk reads (ls/grep/sed)
documented per row. Note: lane S2 edited DR-36 in place during this lane's
work (mid-flight collision, detected by file-mtime guard; S2's content
absorbed into the OPEN row). No git commands run.
## Addendum — lane X5, ash_a2a-side closures (2026-11-07)

Standing: PASS

Two ash_a2a CHANGELOG Known Issues entries moved to "Resolved upstream"
(`/Users/sac/ash_a2a/CHANGELOG.md`, synced this session):

1. Terminal-signal refusal (disjunctive I7) — LANDED upstream in ash_pplan.
   Ran for real: `MIX_BUILD_ROOT=_build-x5 mix test
   test/durable/engine_terminal_signal_test.exs` — 2 tests, 0 failures,
   exit 0. Terminal-run signals now refuse `{:run_terminal, status}`;
   cancelling/unwinding runs still accept signals.
2. `marketplace_sim` dashboard repairs — LANDED upstream
   (`test/support/marketplace_sim/web/dashboard_live.ex`; real-state
   surfaces + telemetry-watcher leak fix via `:DOWN` monitor, lines
   61-80, read on disk).

DR-30 (ash_a2a full compile) already FIXED in this register — unchanged;
this addendum adds no new row for it.

Kill-court residual boundary (per Z18/W3, receipts/lanes/z18-kill-court.md
in ash_a2a): precisely pinned at kill between a step's EFFECT execution and
its `record` checkpoint — NOT the take_signal replay window (atomic
consume-once upstream). X1 intent-before-effect HAS LANDED upstream since
the pin: `lib/ash_pplan/reactor/durable/checkpointed.ex:97-112` writes the
`$intent` checkpoint (`Run.record_intent`) before the effect and hands
`context.durable_intent_token` to the step; steps deriving external
idempotency keys from the token dedupe, steps ignoring it stay
at-least-once (documented boundary in the code comment). Not re-classified
to FIXED — the kill court itself has not been re-run against the landed
intent seam this session; status remains OPEN-documented with the landed
intent seam cited.
