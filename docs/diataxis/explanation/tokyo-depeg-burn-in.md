# The Tokyo-Depeg burn-in, stage by stage

The Tokyo-Depeg scenario is a Chicago-style burn-in of the whole stack under a
flash-depeg event: a Tokyo fund's collateral pipeline is driven through the
real modules — durable engine, SA2A actuation seam, standing ladder, OCEL
ledger, the affidavit wasm ops — under concurrent load, hard kills, and
sabotage mutants. This page explains what each stage of the burn-in actually
runs, which module implements it, and where a stand-in or an honestly-marked
gap sits.

## Why a burn-in and not a test suite

A test suite proves each module against its neighbors. The burn-in drives the
whole pipeline — identity, fencing, conformance, revocation, receipting,
actuation — as one process over a real persistent store, then kills the store
between cycles and reopens it. The question it answers is not "does stage N
pass" but "does the chain of evidence survive the environment": does an effect
identity computed before a kill still dedup after the restart, does a refusal
receipted before the kill still verify after it, does the OCEL export digest
hold across replay.

## The pipeline at a glance

| Stage | Question | Real machinery |
|---|---|---|
| 1. Identity | Is this the committed order? | canonical payload → AshAffidavit.Host `commit` |
| 2. Fencing | Does it execute exactly once? | `Durable.Engine` claim-CAS over `Store.Dets` |
| 3. Envelope | Is the trade in capital bounds? | FOND invariant (stand-in for ZK range proof) |
| 4. Conformance | Did it follow the lifecycle? | `Ex4pmEngine.Alignment` via `AshEx4pm` |
| 5. Revocation | Is the authority still live? | `AshPPlan.Standing` ladder |
| 6. Receipt, actuation | What is the record? | assemble/`verify`, `LedgerOCEL`, `Replay` |

## Stage 1 — Identity: canonical form and commitment

Every order is canonicalized (JCS-style) and hashed into an effect identity,
then committed through the real wasm host: AshAffidavit.Host drives the wasm
ops exposed by the capability registry
(`/Users/sac/affidavit/affidavit-wasm/registry/capability-registry.json` —
ops: `commit`, assemble, `verify`, `mine`, `conform`,
`verify_signature_input`, `certify_authzen_evidence`,
`certify_spiffe_evidence`, `capabilities`), with `AshAffidavit.Pool` pooling
the wasm instances.

**Stand-in, documented:** the production identity is BLAKE3 computed inside
the wasm engine; the burn-in computes BLAKE2b-512 over the canonical form
(`test/support/tokyo_depeg/canonical.ex`) as an explicitly-marked stand-in —
same canonicalization, same commitment discipline, weaker hash. It is never
presented as real BLAKE3.

## Stage 2 — Fencing: exactly-once under concurrency

A barrage of concurrent orders hits the durable engine
(`AshPPlan.Reactor.Durable.Engine`, `lib/ash_pplan/reactor/durable/engine.ex`)
running on `AshPPlan.Reactor.Durable.Store.Dets`
(`lib/ash_pplan/reactor/durable/store/dets.ex`). The claim-CAS path dedups:
duplicates replay the prior effect's evidence instead of re-executing.
Between burn cycles the store is hard-killed and reopened; identity dedup
survives the restart because it reads the durable store, not memory.

## Stage 3 — Envelope: a stand-in for the range proof

The capital-ratio bound (a Tokyo fund may not breach its collateral envelope
under the depeg shock) is asserted as a FOND domain invariant on the policy
lifecycle. This is a **stand-in** for the real ZK range proof: the honest
check "value is within bounds" is enforced, but nothing hides the value. The
real bulletproofs path is not available in the wasm capability registry —
there is no range-proof op in the registry at all (see the gap list below) —
so the invariant is recorded as a documented stand-in, never as real crypto.

## Stage 4 — Conformance: the Van der Aalst core

Each stage of the trade lifecycle (`RiskPreflight → CollateralCheck →
SanctionsScreen → Execution`) emits OCEL events into the ledger
(`AshPPlan.Reactor.Durable.LedgerOCEL`,
`lib/ash_pplan/reactor/durable/ledger_ocel.ex`). The exported log is aligned
against the required lifecycle Petri net via `Ex4pmEngine.Alignment`, reached
through the Ash-facing seam `AshEx4pm`. The enforcement core is alignment
cost: an honest trace aligns at cost 0; the sanctions-skip mutant must produce
cost > 0 and refuse with `REFUSED_CONFORMANCE_DEVIATION`. This is the
anti-vacuity court: the mutant proves the gate is not vacuous.

## Stage 5 — Revocation: authority can die mid-burn

Mid-burn, the authority gate is flipped (the ECB freezes the fund): the next
mutation must refuse with `REFUSED_AUTHORITY_REVOKED`, through
`AshPPlan.Standing` (`lib/ash_pplan/standing.ex`) and the typed ladder in
`AshPPlan.Standing.Receipt` (`lib/ash_pplan/standing/receipt.ex`). Planning
observes; it never grants authority. The same discipline covers the lease
stage: an expired lease executes nothing — `REFUSED_LEASE_EXPIRED`.

## Stage 6 — Receipt and actuation: the durable record

Every refusal is assembled and verified through the affidavit ops
(assemble → `verify`), the OCEL export digest
(`AshPPlan.Reactor.Durable.LedgerOCEL.export/3`) must be stable under replay
and flip under tamper, and admitted policies replay through
`AshPPlan.SA2A.Replay.fond/3`
(`lib/ash_pplan/sa2a/replay.ex`) — which binds the SA2A caller to the
deterministic FOND replay bundle while keeping the planner's output evidence,
never authority. Admitted candidates carry `authority: :none`.

## What is real, what is a stand-in, what is UNSUPPORTED

**Real (ALIVE):** the durable engine and its Dets/ETS stores, the standing
ladder, LedgerOCEL export, the affidavit wasm host/pool driving the registered
ops (`commit`, assemble, `verify`, `mine`, `conform`), the ex4pm alignment
engine (`Ex4pmEngine.Alignment`, `~/ex4pm`), the SA2A replay seam
(`AshPPlan.SA2A.Replay.fond/3`), and the edge broker path
(`~/unrdf/packages/atomvm/src/process-broker.mjs`) plus the ash_surface
projection runtime (`~/ash_surface/priv/static/ash_surface_runtime.mjs`) for
the read-only dashboard.

**Stand-in, documented:** BLAKE2b-512 for BLAKE3 effect identity
(`test/support/tokyo_depeg/canonical.ex`); FOND domain invariant for the ZK
range proof (stage 3). Both are recorded as stand-ins in the receipts — same
enforcement shape, weaker or transparent machinery.

**UNSUPPORTED** — not in the wasm capability registry
(`/Users/sac/affidavit/affidavit-wasm/registry/capability-registry.json`;
registry ops are only `commit`, assemble, `verify`, `mine`, `conform`,
`verify_signature_input`, `certify_authzen_evidence`,
`certify_spiffe_evidence`, `capabilities`): FROST, SMT, bulletproofs, cuckoo
filter, and MMR. These exist in the native Rust crates only; the wasm ABI
does not expose them. The burn-in does not fake them — the stages that would
consume them run the documented stand-ins and record the gap as
`UNSUPPORTED(wasm-abi-not-exposed)`.

## The remaining seams

The scenario glue (`lib/ash_pplan/tokyo_depeg/`) and the scenario courts
(`test/tokyo_depeg/`) are manufactured by the `tokyo-depeg-burn-in-pack` via
ggen_igniter; the stage machinery above is real and verified today, the pack
wiring is the wave's remaining work. The burn-in runner itself is the real
script `test/support/tokyo_depeg/tokyo_burn_in_runner.exs` (run directly, no
`bin/` wrapper):

```console
$ MIX_BUILD_ROOT=_build-ch3 MIX_ENV=test mix run test/support/tokyo_depeg/tokyo_burn_in_runner.exs --cycles 4 --concurrency 16
```

It exits 0 only if every stage's falsifier fired (each refusal path has a
sabotage mutant that is caught) and zero unexplained deviations appear on
honest traffic. Receipt: `receipts/tokyo-burn-in-2026-10-03.md`.
