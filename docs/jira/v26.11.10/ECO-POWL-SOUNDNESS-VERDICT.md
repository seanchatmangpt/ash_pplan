# ECO: Partially Ordered Workflow Language (POWL) Soundness & Reachability Courts

- **Ticket Key**: `PPLAN-261110-03`
- **Milestone**: `v26.11.10`
- **Locus**: `lib/ash_pplan/powl.ex`, `lib/ash_pplan/powl/reachability.ex`, `lib/ash_pplan/powl/verifier.ex`
- **Status**: VERIFIED

---

## 1. Description & Theoretical Foundation

Partially Ordered Workflow Language (POWL) extends workflow trees with partial order relationships and choice/loop semantics.
In `v26.11.10`, the POWL implementation achieves complete verification soundness:

- **Gamma Choice-Graph Operator (`913ab93`, IMP-T005)**:
  Sound projection and reduction of choice graphs with mutually exclusive branches and partial ordering constraints.
- **Deadlock and Orphan Detection (`c2ea704`, IMP-T006)**:
  Bounded reachability analysis over workflow state graphs proving absence of deadlocks, unreachable transitions (orphans), and terminal starvation.
- **Loop-Choice Body Refusal**:
  Refusal of ill-formed cyclic graphs where loop exit conditions are unreachable or create unbounded state explosion.

---

## 2. Verification Courts

- `test/powl_reachability_court_test.exs`
- `test/powl_soundness_court_test.exs`
- `docs/how-to/powl-engine-demo.md`
