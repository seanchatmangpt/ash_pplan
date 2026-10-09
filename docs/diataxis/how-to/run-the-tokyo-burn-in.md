# How to run the Tokyo depeg burn-in

Goal: you want to run the Tokyo flash-depeg scenario suite end to end — the
identity, fencing, conformance, and revocation courts — and read the receipts
and refusal classes it emits.

Every command below targets real files in this repo; the sequence is the one
the courts themselves pin: each court is an ExUnit test under
`test/tokyo_depeg/`, backed by real collaborators in
`test/support/tokyo_depeg/` (no mocks).

> Note: the burn-in runner is
> `test/support/tokyo_depeg/tokyo_burn_in_runner.exs` — there is no `bin/`
> wrapper and none is planned. Run it directly (see section 2).

## Prerequisites

- This repo, `mix compile` clean — the courts need the `AshPPlan.*` modules
  and the test support modules compiled.
- No external services: every court uses real in-process collaborators (the
  real durable `Engine` over an Ets store, the real `AshPPlan.Standing`
  surface, the real `LedgerOCEL` exporter — see the moduledoc of
  `test/support/tokyo_depeg/revocation_support.ex`).

## 1. Run the scenario suite

```console
$ mix test test/tokyo_depeg
```

That one path picks up all four test files:

| File | Court | What it pins |
|---|---|---|
| `test/tokyo_depeg/identity_fencing_test.exs` | Identity (stage 1) and Fencing (stage 2) — AshPPlan.TokyoDepeg.IdentityTest and AshPPlan.TokyoDepeg.FencingTest | JCS (RFC 8785) canonicalization and the effect-identity hash over the order payload (`AshPPlan.Test.TokyoDepeg.Canonical`), with real broken mutants detected via `AshPPlan.Test.Chicago.assert_detected!/4`; and the 200-task duplicate-order barrage where `:pass` means exactly-once execution — the same barrage must DETECT the check-then-act mutant `AshPPlan.Test.TokyoDepeg.BrokenFence` |
| `test/tokyo_depeg/conformance_alignment_test.exs` | Conformance (stage 3) — TokyoDepeg.ConformanceAlignmentTest | Van der Aalst alignment over the canonical lifecycle Petri net (`AshPplan.TokyoDepeg.Alignment`), plus anti-vacuity: the aligner refuses the empty model and the permissive model outright |
| `test/tokyo_depeg/revocation_receipt_test.exs` | Revocation + receipt (stages 5-6) — AshPPlan.TokyoDepeg.RevocationReceiptTest | the mid-burn ECB freeze (`AshPPlan.Test.TokyoDepeg.RevocationSupport.ecb_freeze/0`) flips authority; `Engine.attempt/3` refuses before the claim and nothing executes; every refusal produces a validated five-field receipt; `LedgerOCEL.digest/3` is stable under replay and moves under the `sabotage/1` tamper witness |
| `test/tokyo_depeg/actuation_boundary_test.exs` | Actuation boundary (stage 7) — AshPPlan.TokyoDepeg.ActuationBoundaryTest | `AshPPlan.SA2A.Provider.propose/2` candidates carry `authority: :none` and `standing: :candidate`; replay never admits subject drift; replay refusals use the closed code set of `AshPPlan.SA2A.Refusal.codes/0` |

Run one court at a time by file, e.g.:

```console
$ mix test test/tokyo_depeg/revocation_receipt_test.exs
```

## 2. The stress / load components

The suite's load-bearing stress is the 200-task duplicate-order barrage in
AshPPlan.TokyoDepeg.FencingTest (same file as the identity court), which
drives the real durable engine concurrently and must let exactly one
duplicate through zero times.

The full burn-in runner — N cycles x C concurrent order flows through the
real stack (`SA2A.Provider.propose/2` → durable `Engine` on `Store.Dets` →
`human_release` signal → complete → receipt), hard-killing the store between
cycles — is `test/support/tokyo_depeg/tokyo_burn_in_runner.exs`. It exits 0
only if every falsifier court fired green (exactly-once effects, seq
monotonicity across kills, zero lost runs, OCEL digest continuity, standing
composition):

```console
$ MIX_BUILD_ROOT=_build-ch3 MIX_ENV=test mix run test/support/tokyo_depeg/tokyo_burn_in_runner.exs --cycles 4 --concurrency 16
```

For timing (not required by the courts) there is a companion benchmark
script, `bench/tdb_burn_in_bench.exs`:

```console
$ MIX_BUILD_ROOT=_build-tdb-b1 MIX_ENV=test mix run bench/tdb_burn_in_bench.exs [out.json]
```

It measures SA2A `Provider.propose/2` latency, the compiler duplicate-step
fence decision at 200 concurrent duplicates, Petri-net alignment cost per
trace, and `LedgerOCEL` events/export/digest at 1k/10k events. Baseline
numbers: `bench/TDB-BASELINE-2026-10-03.md`.

## 3. Read the receipts

Stage 6 asserts on real `AshPPlan.Standing.Receipt` records (five fields:
identity, authority, consequence, replay, standing). For every refused
mutation in the run, the court builds a receipt via `AshPPlan.Standing.receipt/2`
with `replay_commands:` and asserts:

- `receipt.standing.value =~ "REFUSED"` — the standing value names the refusal;
- `receipt.standing.broken_term == "R_missing_consequence"` — the broken term
  for a consequence layer that correctly observes the freeze in force and the
  refused mutation not executed.

The frozen-world verdict also flips the run's standing from `:alive` to
`{:lost, [:observed_consequence_correct]}` — the consequence layer reads real
post-state, so the judgment is grounded in what actually executed.

Longer background on why the scenario is shaped this way:
[explanation/tokyo-depeg-burn-in.md](../explanation/tokyo-depeg-burn-in.md).

## 4. What each refusal class means

Refusal classes appear at two layers. Map them with the real functions:

### Engine layer (`test/support/tokyo_depeg/revocation_support.ex`, `refusal_class/1`)

| Term | Class | Meaning |
|---|---|---|
| `{:refused, {:inadmissible_policy, {:not_a_driver, {:ecb_freeze, _, _}}}}` | REFUSED_AUTHORITY_REVOKED | the presented authority is the ECB freeze token; `Engine.attempt/3` gated it through `PolicyDriver.admit/1` and refused before the run claim — no effect executed |
| `{:error, %{reason: :no_such_run}}` | REFUSED_NO_SUCH_RUN | evidence/export was requested for an unknown run id |
| `{:refused, other}` | `REFUSED(class=...)` | any other typed refusal, carried through with its term inspected |
| anything else | nil | not a refusal — a normal outcome |

### Conformance layer (`test/support/tokyo_depeg/alignment.ex`, `@type refusal_class`)

Emitted by `AshPplan.TokyoDepeg.Alignment.judge/2` (and `align/2`, `lifecycle/0`):

| Atom | Meaning |
|---|---|
| `:empty_model` | the model has no transitions, is nil, or has dangling transitions — refused at build time |
| `:permissive_model` | the model admits every trace (the zero-constraint net) — refused as vacuous |
| `:lifecycle_sanctions_omitted` | a trace skips the mandatory SanctionsScreen transition |
| `:lifecycle_order_violation` | activities appear in an order the lifecycle net does not allow |
| `:lifecycle_unmodelled_activity` | the trace contains an activity the model does not know |

### SA2A layer (`lib/ash_pplan/sa2a/refusal.ex`, `AshPPlan.SA2A.Refusal.codes/0`)

Closed set on the actuation boundary: `:missing_subject`, `:missing_domain`,
`:missing_initial`, `:missing_plan_iri`, `:plan_not_found`,
`:unsupported_formalism`, `:planner_refused`. Every replay refusal must carry
one of these codes; a candidate always carries `authority: :none`, so a
refusal can never be mistaken for an authorization.

## See Also

[explanation/tokyo-depeg-burn-in.md](../explanation/tokyo-depeg-burn-in.md) ·
[how-to/run-a-durable-run.md](run-a-durable-run.md)
