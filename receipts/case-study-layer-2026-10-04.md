# Case-Study Layer — Standing Receipt

**Wave**: W17 · **Written**: 2026-10-03 20:05 PDT · **Subject**: case-study layer of `/Users/sac/ash_pplan` (canonical checkout only, no git commands).
**Contract**: amended by operator — case studies must be **P-Plan-run-first**: a case-study file is `LANDED` only if it projects an **executed-run receipt under `docs/case-studies/receipts/`** (e.g. `o2c-run-*.json` from real P-Plan workflow executions). Studies citing only static baselines are `RUN-FIRST-PENDING` with reason `:not_plan_run_first`.
**Method**: every verdict below reflects what is on disk at write time. Every cited number I could reach was spot-checked against its source artifact (results in §5). No number in this receipt is inferred from an absent artifact.

## 1. What landed (per file)

### `bin/case-study` (executable, 3686 B, mtime 19:48 PDT)

- LANDED as code. Runs `canonical-court` (`mix test test/workflow/canonical_court_test.exs`) then `fleet-soak-court` (`SOAK_SECONDS=<n> mix test test/fleet/`), writes a dated receipt under `docs/case-studies/receipts/` with real exit codes, real mix test summary lines, and log sha256s. Exits non-zero on any FAIL (witnessed — see §3).
- **Execution status: the falsifier FIRED on my run.** My invocation (`SOAK_SECONDS=10 bin/case-study`, 19:49–19:58 PDT) exited **1**: canonical-court PASS (19 tests, 0 failures), fleet-soak-court **FAIL (exit 2, "1 test, 1 failure")**. Per-run receipt: `docs/case-studies/receipts/case-study-20261004T025521Z.md` (build root `_build-case-76252`, OVERALL: FAIL — 1 PASS, 1 FAIL).
- A second, concurrent run (not mine; build root `_build-case-73328`, soak 30s) wrote `case-study-20261004T025422Z.md` with **OVERALL: PASS — 2 PASS, 0 FAIL**. Both receipts are on disk; the chain is load-sensitive/soak-length-sensitive as run today.
- **Residue**: `_build-case-76252` (my run's build root) is **still on disk** — the `on_exit` cleanup did not remove it. Build roots are leases; this one is orphaned and should be deleted at integration. (`bin/case-study` already defaults to per-run `_build-case-<pid>` and deletes it on clean exit; the FAIL-path leak is a defect to fix forward.)

### `docs/case-studies/` — scaffolding

| file | verdict | note |
|---|---|---|
| `README.md` | LANDED | Honesty contract + evidence-chain spec + index (index empty, honestly marked). |
| `REPRODUCE.md` | LANDED | Reproduction instructions match the script's actual flags (`SOAK_SECONDS`, `MIX_BUILD_ROOT`) and receipt format. |
| `_template.md` | LANDED | Authoring template. |

### `docs/case-studies/` — case-study documents

| file | verdict | reason / basis |
|---|---|---|
| `roi-model.md` | **RUN-FIRST-PENDING** | `:not_plan_run_first` — cites E1–E4 static baselines only (`bench/receipt_cached_scaling_raw1.json`, `bench/receipt_cache_scaling_postfix2.json`, `bench/hot_paths_raw_w16.json`); no executed-run receipt projected. Numbers spot-checked correct (§5). |
| `finance-transformation.md` | **RUN-FIRST-PENDING** | `:not_plan_run_first` — cites `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md` (14.6–29.1x post-chain-fix hit speedups, verified at that file's line 457), CHANGELOG 26.10.3; no executed-run receipt. |
| `procure-to-pay.md` | **RUN-FIRST-PENDING** | `:not_plan_run_first` — cites bench baselines + `receipts/dets-repair-reverify-2026-10-03.md` + `receipts/tokyo-burn-in-2026-10-03.md` (both exist on disk); no executed-run receipt. |
| `comparison.md` | **RUN-FIRST-PENDING** | `:not_plan_run_first` — capability-comparison claims; code citations verified (`lib/ash_pplan/standing.ex`, `ledger_ocel.ex`, ex4pm conformance test lines 95–96 exact-matched); no executed-run receipt. |
| `corpora.md` | **RUN-FIRST-PENDING** | `:not_plan_run_first` — honestly self-labeled "PLAN (nothing downloaded; stages 1–3 unexecuted)". Fixture inventory table not re-verified by this lane. |

**No `o2c-run-*.json` (or any P-Plan executed-run receipt) exists under `docs/case-studies/receipts/` at write time.** The directory holds only the two `bin/case-study` chain receipts. Under the amended contract, zero case-study documents are LANDED; all five are RUN-FIRST-PENDING.

## 2. Honesty contract (in force for this layer)

1. Every number in a case study must cite an artifact on disk; uncitable numbers are not written (README contract §1, present in `README.md`).
2. Numbers carry their artifact path, suite row, and trust caveat.
3. Superseded figures are marked, not deleted (e.g. the ~2100–2200x pre-chain-fix figures, superseded by 14.6–29.1x).
4. SKIP and FAIL are stated, never hidden — including the fleet-soak FAIL above.
5. Citations are replayable.
6. **(Amended)** Case studies project executed P-Plan runs; static baselines alone are insufficient for LANDED.

## 3. Falsifiers (what would refute the case-study layer)

1. **A cited number not found in its source artifact** — executed as a spot-check; 6/6 sampled citations matched on this pass (see §5). Any future miss kills the layer's standing.
2. **A missing source artifact** — all sampled citation targets exist on disk; absence of a cited artifact kills the citing study.
3. **`bin/case-study` non-zero exit** — **FIRED** during this wave (exit 1; fleet-soak-court 1 failure at soak=10s). Standing of the one-command chain is BLOCKED until the fleet-soak failure is fixed and a rerun passes.
4. **(Amended) A case study not projecting an executed run** — currently true of all five case-study documents; they are RUN-FIRST-PENDING, not LANDED, on exactly this falsifier.
5. **Cleanup falsifier (new, witnessed)** — a `bin/case-study` FAIL-path run leaking its `_build-case-<pid>` build root (`_build-case-76252` on disk at write time) refutes the build-roots-are-leases clause of the layer's own contract.

## 4. Standing verdict summary

- LANDED: `bin/case-study` (code), `README.md`, `REPRODUCE.md`, `_template.md`.
- RUN-FIRST-PENDING (`:not_plan_run_first`): `roi-model.md`, `finance-transformation.md`, `procure-to-pay.md`, `comparison.md`, `corpora.md`.
- BLOCKED: the `bin/case-study` overall chain (falsifier #3 fired on 2026-10-03, soak=10s; PASS recorded by a concurrent soak=30s run — nondeterministic as run).

## 5. Spot-check log (real commands, real matches)

| citation in case study | source artifact | result |
|---|---|---|
| 39.0 s @ 10k uncached (`39,008,716` µs) | `bench/receipt_cached_scaling_raw1.json` | MATCH |
| 0.49 s / 18.5 ms / 26.3x / `standing: ALIVE` | `bench/receipt_cache_scaling_postfix2.json` | MATCH (all four values) |
| 4.66 µs (σ 3.0%), 7.83 µs, 15.8 ms (`mean_us: 15842.98`) | `bench/hot_paths_raw_w16.json` | MATCH |
| record R²=0.9998 LINEAR; export/digest NOT-LINEAR drift 40–50% | `bench/ocel_export_scaling_raw_w16.txt` lines 27–30 | MATCH (R² 0.999845; drift 49.6%/40.5%) |
| 14.6x/15.3x · 17.8x/17.9x · 27.0x/29.1x hit speedups | `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md` line 457 | MATCH |
| ex4pm conformance `fitness == 1.0` / `precision >= 0.9` at "lines 95–96" | `/Users/sac/ex4pm/test/conformance_test.exs` lines 95–96 | EXACT MATCH |

## 6. Replay

- `SOAK_SECONDS=10 bin/case-study` — my run: exit 1, receipt `docs/case-studies/receipts/case-study-20261004T025521Z.md`.
- Concurrent run (other lane): receipt `docs/case-studies/receipts/case-study-20261004T025422Z.md`, OVERALL PASS (soak 30s).
- Number spot-checks: `python3 -c "import json; ..."` comparisons against the `bench/` artifacts listed in §5.
