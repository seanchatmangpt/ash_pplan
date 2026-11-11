# ECO: Durable Obligation Subject Tracking (`d8ce2a5`)

- **Ticket Key**: `PPLAN-261110-02`
- **Milestone**: `v26.11.10`
- **Locus**: `lib/ash_pplan/obligation.ex`, `lib/ash_pplan/reactor/durable/`
- **Status**: VERIFIED

---

## 1. Problem Statement

In prior versions, durable execution run boundaries handled task checkpoints and signal queues without an explicit first-class obligation subject. This created an impedance mismatch between workflow obligations and their lifecycle state in durable stores (ETS/DETS).

## 2. Solution & Implementation

Commit `d8ce2a5` introduced the `AshPPlan.Obligation` struct and tracked obligation subjects across:
- `AshPPlan.Reactor.Durable.Run`
- `AshPPlan.Reactor.Durable.Engine`
- `AshPPlan.Reactor.Durable.Status`

Obligations are content-addressed and provenance-bound, ensuring that every transition in the durable ledger links back to an admitted obligation subject rather than an ephemeral process identifier.

## 3. Falsifier & Evidence

- Court: `test/courts/obligation_tracking_court_test.exs`
- Evidence: Attempts to commit unadmitted or subject-mismatched obligations are refused with typed `{:refused, :unadmitted_obligation_subject}`.
