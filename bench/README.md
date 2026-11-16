# Bench

# bench

Benchmark scripts for ash_pplan. Run them through `bin/bench`, never a bare
`mix run`, so build roots and output handling stay deterministic.

## Usage

```sh
./bin/bench <script.exs> [output.json] [--force]
```

- Runs with `MIX_BUILD_ROOT=_build-bench MIX_ENV=test` (isolated from
  dev/test builds).
- `output.json` is passed to the script as `System.argv()` when the script
  accepts one (e.g. `hot_paths_bench.exs`); scripts that ignore argv
  (e.g. `store_scaling.exs`) still print to stdout.
- Refuses to overwrite an existing output file unless `--force`.

## Examples

```sh
./bin/bench bench/hot_paths_bench.exs bench/hot_paths_raw.json --force
./bin/bench bench/store_scaling.exs /tmp/store_scaling_out.json
```

## Scripts

- `store_scaling.exs` — Ets vs Dets write throughput / read latency /
  signal dispatch at 100 / 1k / 10k checkpoints.
- `hot_paths_bench.exs` — Engine attempt + park/signal/resume cycles,
  checkpoint writes, Standing.Receipt, LedgerOCEL 1k export, FOND policy
  validation; emits a JSON doc (schema `ash_pplan/hot-paths-bench/1`).
- `tdb_burn_in_bench.exs` — TDB burn-in.
- `claims_bench.exs` — measured-vs-claimed table (RingBuffer, HealthGate,
  WAL vs DETS, LeaseMonitor). Single run = one sample; use the runner below.
- `baseline_runner.exs` — runs a bench N times (fresh `mix run` child each)
  and writes per-run values plus min/median/max:

  ```sh
  elixir bench/baseline_runner.exs 5 bench/claims_bench.exs bench/claims_raw.json
  ```

  Output `bench/claims_raw.json` is the evidence cited by
  `CLAIMS-BASELINE-2026-11-07.md`. Failed runs are recorded and excluded
  from stats.
