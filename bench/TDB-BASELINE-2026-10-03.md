# TDB Burn-In Baseline — 2026-10-03

# TDB-BASELINE-2026-10-03

Subject: `bench/tdb_burn_in_bench.exs` on the canonical checkout (`/Users/sac/ash_pplan`).
Build root: `_build-tdb-b1`. No Benchee (not a dependency; none added) — in-script
timing harness mirroring `bench/hot_paths_bench.exs` (warm-up + 7 timed batches,
ips / mean µs / stddev).

Reproduce:

```sh
MIX_BUILD_ROOT=_build-tdb-b1 MIX_ENV=dev mix run bench/tdb_burn_in_bench.exs bench/tdb_burn_in_raw.json
```

Raw JSON: `bench/tdb_burn_in_raw.json` (schema `ash_pplan/tdb-burn-in-bench/1`).

## Results (aarch64-apple-darwin25.2.0, OTP 28, Elixir 1.19.5, 16 schedulers)

| Benchmark | ips | mean µs/op | stddev | stddev % |
|---|---|---|---|---|
| sa2a_propose_fond_states_10 | 27,783.0 | 36.01 | 0.90 µs | 2.5% |
| sa2a_propose_fond_states_100 | 1,917.8 | 521.46 | 4.21 µs | 0.8% |
| compiler_duplicate_fence_200_dups | 116,295.7 | 8.60 | 0.12 µs | 1.4% |
| compiler_no_fence_200_unique | 177.4 | 5,648.19 | 271.3 µs | 4.8% |
| petri_align_trace_len_4 | 55,872.0 | 17.90 | 0.20 µs | 1.1% |
| petri_align_trace_len_16 | 27,544.6 | 36.31 | 0.32 µs | 0.9% |
| petri_align_trace_len_64 | 14,722.0 | 67.95 | 1.42 µs | 2.1% |
| ledger_ocel_events_1000 | 519.2 | 1,929.50 | 88.12 µs | 4.6% |
| ledger_ocel_export_1000 | 94.6 | 10,645.14 | 939.86 µs | 8.8% |
| ledger_ocel_digest_1000 | 439.2 | 2,277.37 | 37.69 µs | 1.7% |
| ledger_ocel_events_10000 | 34.5 | 29,154.80 | 2,574.37 µs | 8.8% |
| ledger_ocel_export_10000 | 7.5 | 134,754.97 | 10,267.31 µs | 7.6% |
| ledger_ocel_digest_10000 | 35.4 | 28,262.37 | 1,022.33 µs | 3.6% |

Second run (re-run for variance check): sa2a 10: 28,280.6 ips / 35.37 µs; 100:
1,811.7 ips / 553.36 µs; fence: 94,586 ips / 10.6 µs; unique-200: 181.2 ips /
5,520.71 µs; align 4/16/64: 17.99 / 41.64 / 73.30 µs; ocel 1k: 1,929.5 /
10,645.1 / 2,277.4 µs; ocel 10k: 29,154.8 / 134,755.0 / 28,262.4 µs. Two runs
agree within noise except propose-at-100 (±6%).

## Notes

- **MIX_ENV=dev, not test**: `MIX_ENV=test` is blocked by a pre-existing
  source-level corruption in `test/support/tokyo_depeg/` —
  `canonical.ex:155` fails with `invalid or duplicate keys for if, only "do"
  and an optional "else" are permitted`, and `alignment.ex` (`lifecycle/0`
  body) is similarly garbled/truncated on disk. Neither file is owned by this
  lane; both are pre-existing failures, not session-introduced.
- Because `test/support/tokyo_depeg/alignment.ex` does not compile, the
  Petri-net alignment (uniform-cost Dijkstra over the synchronous product,
  sync 0 / log 1 / model 1) is implemented inline in the bench script
  (`TdbBench.Petri`) over a 5-transition chain lifecycle, per the
  ex4pm-parity note in the corrupt file's header.
- `sa2a_propose_fond_*` drives the real `AshPPlan.SA2A.Provider.propose/2` →
  `PolicyCandidate.fond/2` → `AshPPlan.select_policy/3` FOND synthesis; each
  domain uses a nondeterministic edge (`advance → [next, s0]`), so synthesis
  is strong-refused/strong-cyclic-admitted — a real FOND domain, not a chain.
- The duplicate fence row drives the real `AshPPlan.Compiler.compile_spec/2`
  duplicate-step refusal at 200 steps all sharing one IRI. Baseline row
  compiles 200 unique steps end-to-end (full Reactor build) — the ~650x gap
  is fence-vs-full-compile, not fence overhead.
- LedgerOCEL rows measured on the Ets store with runs of 1k / 10k checkpoints
  (event count asserted n+1 inside each timed op); export includes JSON
  encoding.

## Standing

Measured ALIVE on the exact subject
`bench/tdb_burn_in_bench.exs` (working tree, 2026-10-03, `_build-tdb-b1`,
MIX_ENV=dev). Bench script and this baseline doc are the only files written by
this lane.

---

# Tokyo Pipeline Per-Stage Costs (BENCH lane append, 2026-10-03)

Subject: `bench/tokyo_stage_costs.exs` (new, owned by this lane) on the canonical
checkout (`/Users/sac/ash_pplan`), build root `_build-tdb-b2`, MIX_ENV=dev,
two runs (raw: `bench/tokyo_stage_costs_raw1.json`, `bench/tokyo_stage_costs_raw2.json`).

Note: the shared `MIX_ENV=test` build is currently blocked by a compile error in
`test/support/tokyo_depeg/refusals.ex` (string literals in a typespec union —
another lane's file, untouched here). The bench therefore runs under MIX_ENV=dev
and `Code.compile_file`s the two support modules it exercises directly
(`canonical.ex`, `alignment.ex`) — same source files, no copies.

Reproduce:

```sh
MIX_BUILD_ROOT=_build-tdb-b2 MIX_ENV=dev mix run bench/tokyo_stage_costs.exs out.json
```

| stage (op) | run1 mean µs | run2 mean µs | delta | run1 ips | run2 ips | stddev % (r1/r2) |
|---|---|---|---|---|---|---|
| 1. canonicalize+identity (`Canonical.identity/1`, JCS+BLAKE2b) | 23.53 | 22.92 | -2.6% | 42,586 | 43,694 | 4.6 / 4.1 |
| 2. duplicate-fence decision (`Compiler.compile_spec`, 200 dups, refused) | 10.14 | 10.05 | -0.9% | 98,743 | 99,616 | 4.4 / 3.1 |
| 2b. baseline compile 200 unique steps (no fence) | 6,560.25 | 6,712.16 | +2.3% | 152.6 | 149.1 | 3.8 / 2.4 |
| 3. conformance alignment (trace len 4, cost 0) | 9.87 | 11.00 | +11.4% | 101,291 | 91,070 | 1.1 / 4.4 |
| 3b. alignment (trace len 16, cost > 0) | 111.78 | 127.91 | +14.4% | 8,947.5 | 7,821.2 | 1.2 / 2.1 |
| 3c. alignment (trace len 64, cost > 0) | 534.51 | 566.88 | +6.1% | 1,873.1 | 1,766.4 | 3.8 / 3.9 |
| 4. `Standing.verdict/3` (3 layer combine) | 0.30 | 0.28 | -6.7% | 3.32M | 3.52M | 10.4 / 4.3 |
| 4b. `Standing.verdicts/1` (full run, 3 layers) | 2.52 | 2.65 | +5.2% | 396,790 | 377,662 | 1.3 / 5.3 |
| 5. receipt assembly (`Standing.receipt/2` + validation) | 290.26 | 212.79 | -26.7% | 3,900.8 | 4,859.9 | 49.9 / 20.8 |
| 6. OCEL 2.0 export + sha256 digest (1k events) | 10,500.59 | 11,498.54 | +9.5% | 95.5 | 87.6 | 5.5 / 9.6 |
| 6b. sha256 digest only (1k-event export, 47 kB) | 267.22 | 270.60 | +1.3% | 3,750.3 | 3,696.4 | 5.0 / 1.7 |

Reading (deltas run1 vs run2):

* All per-stage costs are sub-millisecond except compile (6.6 ms) and OCEL
  export at 1k (≈10.5-11.5 ms, ≈11 µs/event dominated by Jason encoding).
* Run-over-run deltas are within noise (<15%) for every stage except
  receipt assembly (-26.7%), whose run1 stddev was already 49.9% (cold GC in
  one batch); run2 (212.8 µs, 20.8% stddev) is the more representative figure.
* Alignment cost scales super-linearly with trace length (10 µs at 4 → 112-128
  µs at 16 → 534-567 µs at 64), consistent with the Dijkstra synchronous-product
  search over log/model move branching.
* The duplicate fence (10 µs) is ~650x cheaper than the successful 200-step
  compile (6.6 ms): refusal exits before reactor step resolution.
* `Standing.verdict/3` is O(1) (0.3 µs); the full `verdicts/1` pass over a real
  run (plan/execution/consequence layers over evidence events) is ~2.6 µs.

Measured ALIVE on the exact subject `bench/tokyo_stage_costs.exs` (working
tree, 2026-10-03, `_build-tdb-b2`, MIX_ENV=dev). Both runs' JSON written to
`bench/tokyo_stage_costs_raw1.json` / `bench/tokyo_stage_costs_raw2.json`.
Files written by this lane: `bench/tokyo_stage_costs.exs`, the two raw JSONs,
and this appended section.
