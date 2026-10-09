# Procure-to-Pay Through the Durable Ledger's Eyes

An analog study: how `ash_pplan`'s evidence machinery — standing verdicts, the
10-rung ladder, checkpointed durable runs, and the Tokyo-Depeg burn-in — maps
one-to-one onto an accounts-payable invoice-approval chain.

## Situation

A procure-to-pay (P2P) flow — purchase order → goods receipt → supplier
invoice → approval chain → payment — is an invoice-approval chain with the
same control-plane needs as any governed workflow: who approved what, on which
evidence, with replayable proof, surviving process death mid-approval. The
`ash_pplan` durable ledger gives exactly this control plane:

| AP approval-chain concept | ash_pplan analog | where |
|---|---|---|
| Invoice record surviving process crash | Checkpointed durable run (ETS or DETS store) | `lib/ash_pplan/reactor/durable/checkpointed.ex`, `lib/ash_pplan/reactor/durable/store.ex` |
| Approver's verdict per invoice | Standing = `PlanCorrect ∧ ExecutionCorrect ∧ ObservedConsequenceCorrect` (three-layer verdict) | `lib/ash_pplan/standing.ex` |
| Escalating confidence: draft → reviewed → approved → paid | 10-rung evidentiary standing ladder (`:UNKNOWN` → ... → `:VERIFIED`), single-rung promotions only, no skipped rungs | `lib/ash_pplan/standing/ladder.ex` |
| Payment release (real-world DO) | Receipt with authority ceiling (default CONSTRUCT, never DO unless leased) | `lib/ash_pplan/standing.ex` |
| Audit trail / who-did-what log | OCEL 2.0 event export + hash-chained ledger digest | `lib/ash_pplan/reactor/durable/ledger_ocel.ex`, `lib/ash_pplan/standing/chain.ex` |
| External conformance (3-way match) | ex4pm Petri-net alignment over the trade lifecycle | `test/support/tokyo_depeg/` |

## Mining evidence

Every number below is transcribed from disk artifacts in this repo; source
list at the end.

### Standing receipt cost is linear in evidence size

`Standing.receipt/2` produces the five-field receipt (identity, authority,
consequence, replay, standing) with a hash-chained ledger digest. Measured on
the standing/closure bench (2 runs, 2026-10-03):

* receipt/10 events: 327–355 µs (+8.6% run delta)
* receipt/100 events: 5,917–6,111 µs (+3.3%)
* receipt/1000 events: 419,803–448,094 µs (+6.7%) — ~linear
* cost split (probe): ledger digest ~44–46%, three-layer verdicts ~47–52%,
  OCEL+ex4pm ~2–3%

For the P2P story: an AP auditor can re-derive a full five-field receipt for
an invoice with a 1,000-event evidence chain in under half a second.

### Receipt cache turns audit lookups into lookups

`Standing.receipt_cached/2` (ETS LRU-256, content-addressed, Merkle-style
identity `ash-pplan-standing-identity-v2`, byte-identical to the raw receipt):

* hit: 1,655 ns vs 312.8 ms direct = **188.9x** (probe)
* honest end-to-end hit speedups post-chain-digest-fix: **14.6–29.1x** across
  cache sizes (supersedes stale ~2100–2200x pre-fix figures)
* exact 256/256 under storm; single-flight cold fills share one compute

In AP terms: re-pulling an already-audited invoice's standing is free.

### Ladder promotions are enforced, not narrated

`AshPPlan.Standing.Ladder` enforces a fixed 10-state ladder (`lib/ash_pplan/standing/ladder.ex`,
`states/0`); a claim outside the closed set is a typed refusal
(STL_unknown_state), and promotion requires a real evidenced single-rung
transition chain from `:UNKNOWN` — no skipped rungs, no self-certification.
The bench pins rung-stop behavior: depth 3 stops at VALIDATED (index 2), depth
6 stops at ADMITTED (index 6; the receipt rung refuses without `:run_id`),
depth 10 reaches VERIFIED (index 9). This is exactly an AP delegation-of-authority
matrix as executable law: an invoice cannot jump from draft to paid, and the
audit trail is the promotion chain itself.

### Durability: zero loss across hard kills

Two disk-grounded durability results:

1. **DETS burn-in** (`test/stress/dets_burn_in_test.exs`): 8 write/kill/reopen
   cycles x 12 runs per cycle (96 runs + 8 probe rows), with interleaved
   cancels and signal consumes; every committed row present and `:completed`
   after each reopen, seq strictly monotonic across kills. Full DETS suite
   (crash court + reopen retry + read-no-sync + burn-in): **12 tests, 0
   failures** (`receipts/dets-repair-reverify-2026-10-03.md`). The witnessed
   "DETS hang" was a missing test-loop cycle guard, not a lib defect; fixed,
   12/12 on the canonical build (CHANGELOG).
2. **Tokyo-Depeg burn-in soak** (`receipts/tokyo-burn-in-2026-10-03.md`):
   8 cycles x 32 concurrent order flows = 256 flows through the real stack
   (JCS canonical identity → dup fence → compile → ex4pm alignment → standing
   verdict → OCEL export), store hard-killed between cycles. All five
   falsifier courts GREEN: F1 exactly-once effects, F2 seq monotonic, **F3
   zero lost runs**, F4 OCEL digest continuity (pre-kill digests byte-identical
   post-reopen), F5 `Standing.verdict/3 == :alive` per flow. Verdict: ALIVE,
   EXIT=0. Memory flat (~41 MB processes, ~2.1 MB ETS; −6.1 MB net over the
   soak — no leak).

In AP terms: an approval server dying mid-payment-batch loses nothing, and the
audit ledger's digest proves the log was not rewritten across the crash.

### The wedge fix: ~70 wedges/run → 0

`Store.Dets` previously paid a full-table `:dets.sync` on reads; a wedged
server hung callers with `:infinity` timeout. The fix (sync-on-write-only, 60s
bounded-call timeout → typed refusal, signal lookups pushed into DETS match
specs): kill-storm soak went from **~70 wedges/run on the pre-fix baseline to
0 wedges across 4 runs** (`test/stress/checkpoint_burst_kill_test.exs`;
wedge regression court `test/hardening/dets_read_no_sync_test.exs` pins the
8-msg read AST set, 11 tests). Repair-aware reopen: a kill mid-sync leaves the
DETS header mid-repair, so opens retry with bounded backoff (≤ 750 ms, inside
the burn-in's 10 s reopen window) instead of surfacing transient failure.

For AP: the invoice store cannot hang the approval chain; worst case is a
typed, bounded refusal.

### Per-stage costs of the approval pipeline

Tokyo pipeline per-stage medians (`bench/BASELINES-CANONICAL.md` §7a, r1/r2
2026-10-03): canonical identity (JCS+BLAKE2b) 23.2 µs; dup fence (200 dups)
10.1 µs; compile 200 unique invoices 6,636 µs; alignment (lifecycle
conformance) 10.4 / 119.8 / 550.7 µs at trace lengths 4/16/64;
`Standing.verdict/3` 0.29 µs (O(1)); `Standing.verdicts/1` 2.58 µs; receipt
assembly 212.8 µs (r2); OCEL export+sha256 ~11 µs/event; sha256 47 kB: 269 µs.

Reading: identity-dedup and the standing verdict — the two operations run per
approval decision — are effectively free; conformance alignment and OCEL
export scale with trace length and are the honest costs of real auditability.

## Actions

1. Mapped the AP invoice-approval chain onto the durable-ledger control plane
   (checkpointed runs, three-layer standing, 10-rung ladder, authority
   ceiling, OCEL audit, ex4pm conformance) — table above.
2. Grounded every quantitative claim in recorded disk artifacts; no number in
   this document was measured afresh or estimated.
3. Identified the mapping's stress evidence: the Tokyo-Depeg burn-in as the
   P2P end-of-quarter payment-batch fire drill (kills, dup floods, growing
   ledger), and the DETS wedge/reopen fixes as the store's own hardening
   receipts.

## Quantified outcome

* Invoice standing receipt: 327 µs (10 events) → ~420 ms (1,000 events),
  linear; cached hit 1,655 ns (188.9x probe, 14.6–29.1x honest end-to-end).
* Ladder: 10 rungs, single-rung promotions only, typed refusal on any
  out-of-set state; rung stops verified at depth 3/6/10.
* Durability: 96-run DETS burn-in zero loss across 8 hard kills (12/12 tests);
  256-flow Tokyo soak zero lost runs, all five courts GREEN, no leak.
* Store hardening: ~70 wedges/run → 0 (4-run kill-storm soak); bounded reopen
  retry ≤ 750 ms.

## Reproduction

```sh
# Standing / closure bench (receipt + ladder rung stops)
MIX_BUILD_ROOT=_build-errc8 MIX_ENV=test mix run bench/standing_closure_bench.exs out.json

# Receipt cache probe
MIX_BUILD_ROOT=_build-ch15 MIX_ENV=test mix run bench/standing_receipt_cache_probe.exs

# DETS durability burn-in
MIX_BUILD_ROOT=_build-p89 mix test test/stress/dets_burn_in_test.exs --include stress

# Full DETS hardening court
MIX_BUILD_ROOT=_build-p89 mix test \
  test/hardening/dets_crash_court_test.exs \
  test/hardening/dets_reopen_retry_test.exs \
  test/hardening/dets_read_no_sync_test.exs \
  test/stress/dets_burn_in_test.exs --include stress

# Tokyo-Depeg burn-in runner (bounded / soak)
MIX_BUILD_ROOT=_build-ch3 MIX_ENV=test mix run \
  test/support/tokyo_depeg/tokyo_burn_in_runner.exs --cycles 4 --concurrency 16
MIX_BUILD_ROOT=_build-ch3 MIX_ENV=test mix run \
  test/support/tokyo_depeg/tokyo_burn_in_runner.exs --cycles 8 --concurrency 32

# Tokyo per-stage costs
MIX_BUILD_ROOT=_build-tdb-b2 MIX_ENV=dev mix run bench/tokyo_stage_costs.exs out.json
```

## Limitations

* **No real AP customer data.** The P2P mapping is an analog over synthetic
  trade-lifecycle corpora (`test/support/tokyo_depeg/`); no real invoices,
  suppliers, or amounts were processed. The mapping demonstrates control-plane
  properties (durability, evidence, authority), not AP business correctness
  (tax, currency, ERP integration).
* The "30-cycle zero-loss burn-in" phrasing does not match disk: the recorded
  artifacts are the 8-cycle DETS burn-in and the 8-cycle Tokyo soak. Numbers
  here use the recorded values.
* Ladder absolute latencies in the bench are flagged load-noisy (run deltas up
  to 43%); only the rung-stop behavior, not the µs figures, is treated as
  reliable.
* The Tokyo ZK range-proof stage is an honest stand-in, not real ZK
  (`docs/diataxis/explanation/tokyo-depeg-burn-in.md`).
* All figures are single-machine (aarch64, OTP 28, Elixir 1.19.5), same-day
  2026-10-03; no multi-node replication evidence.

## Number sources

| claim | disk source |
|---|---|
| receipt 327–355 / 5,917–6,111 / 419,803–448,094 µs; digest ~44–46%, verdicts ~47–52% | `bench/BASELINES-CANONICAL.md` §5 (`bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`) |
| receipt cache 188.9x / 1,655 ns; 14.6–29.1x; 256/256 storm; 28 tests | `bench/BASELINES-CANONICAL.md` §5a; CHANGELOG 26.10.3 |
| ladder 10 rungs, rung stops depth 3/6/10, STL_unknown_state | `lib/ash_pplan/standing/ladder.ex`; `bench/BASELINES-CANONICAL.md` §5 |
| DETS burn-in 8 cycles x 12 runs, zero loss; 12 tests 0 failures | `test/stress/dets_burn_in_test.exs` (`@restarts 8`, `@runs_per_cycle 12`); `receipts/dets-repair-reverify-2026-10-03.md` |
| Tokyo soak 8 cycles x 32 = 256 flows, F1–F5 GREEN, zero lost runs, memory flat | `receipts/tokyo-burn-in-2026-10-03.md` |
| ~70 wedges/run → 0; ≤750 ms reopen retry | `CHANGELOG.md` 26.10.3; `test/stress/checkpoint_burst_kill_test.exs`; `test/hardening/dets_read_no_sync_test.exs` |
| per-stage costs (23.2 µs … 269 µs) | `bench/BASELINES-CANONICAL.md` §7a (`bench/TDB-BASELINE-2026-10-03.md` appendix) |
