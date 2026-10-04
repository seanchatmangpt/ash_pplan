# REPRODUCE

How to reproduce the ash_pplan case-study evidence chain locally with one
command.

## What this reproduces

`bin/case-study` runs the evidence chain in order (P-Plan-run-first) and
writes a dated receipt:

1. `o2c-run` — EXECUTES the P-Plan order-to-cash workflow on the real
   durable engine: `MIX_ENV=test mix run examples/case_study_o2c.exs`.
   Its full output is kept as the run receipt
   (`docs/case-studies/receipts/o2c-run-<UTCSTAMP>.log`), and the dated
   receipt embeds that run receipt's sha256 plus the engine's own digests
   (`replay.ledger_digest`, `replay.evidence.ocel2_sha256`,
   `sha256(OCEL export)`).
2. `canonical-court` — the workflow canonical court:
   `mix test test/workflow/canonical_court_test.exs`
3. `fleet-soak-court` — the fleet soak court at a bounded soak window:
   `SOAK_SECONDS=30 bin/case-study-step-soak`. The step runs
   `mix test test/fleet/` with a bounded retry at the same window and a
   typed verdict on the last line of its output — `SOAK_VERDICT=PASS`,
   `SOAK_FLAKE_RETRIED` (exit 0; an earlier attempt hit the kill-vs-first-ack
   race inside the soak test), `SOAK_FLAKY` (exit 1, with the measured
   cycles/ms of the last attempt), or `SOAK_TOO_SHORT` (exit 3: a deadline
   below 1s cannot host one poll cycle — typed refusal, nothing runs).

## Requirements

- Elixir/Erlang per `mix.exs`. No JVM, no network beyond dependencies already
  resolved into `mix.lock` (`vendor/reactor_process` is a vendored path
  dependency).
- Nothing is run in CI for this chain; it is a local evidence run.

## Run

```bash
bin/case-study
```

Environment overrides:

- `SOAK_SECONDS` — fleet soak duration (default `30`; below `1` is a typed
  `SOAK_TOO_SHORT` refusal).
- `SOAK_MAX_ATTEMPTS` — fleet-soak-court retry budget (default `3`).
- `MIX_BUILD_ROOT` — build root (default a per-run `_build-case-<pid>`,
  deleted on exit; override to reuse a warm build).

Receipt lands at
`docs/case-studies/receipts/case-study-<UTCSTAMP>.md` with one table row per
step: command, exit code, the real mix test summary line, the last line of
real output as the evidence digest, the sha256 of the step's full log, and a
PASS/FAIL verdict. The run's final line names the receipt and the overall
verdict; the script exits non-zero on any FAIL.

## Expected output

With both courts passing, the console tail looks like:

```text
[PASS] o2c-run (exit 0): == evidence chain complete ==
[PASS] canonical-court (exit 0): N tests, 0 failures
[PASS] fleet-soak-court (exit 0): SOAK_VERDICT=PASS soak_seconds=30 attempts=1 cycles=N ms=M

Receipt written to docs/case-studies/receipts/case-study-<UTCSTAMP>.md (OVERALL: PASS)
Executed-run digest: <replay.ledger_digest from the o2c run>
```

Exact counts (`N`, `M`) are not fixed; they are whatever the current tree
produces, and the receipt carries the real summary lines.

## Honesty note

All numbers regenerate: every count, digest, timestamp, and duration in the
receipt is produced by the run that wrote it and will differ on the next run,
on another machine, or under different load. This document and the receipt are
a local evidence record, not a CI attestation; no claim here survives its
subject changing.
