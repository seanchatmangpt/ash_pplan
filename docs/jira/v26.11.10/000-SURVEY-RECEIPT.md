# ash_pplan: v26.11.10 Release & Milestone Survey Receipt

- **Date**: 2026-11-10
- **Milestone**: v26.11.10
- **Repository**: `seanchatmangpt/ash_pplan`
- **Canonical Path**: `/Users/sac/ash_pplan`
- **Default Branch**: `main`
- **Current HEAD**: `ba9019c` (chore: update gitignore and synchronize wave artifacts)
- **Previous Release Tag**: `v26.10.8` (commit `a833f1b` / `a1f332e`)
- **Version Transition**: `26.11.7` -> `26.11.10`

---

## 1. Landed Capability Since Last Release

| Commit | Subject | Lane / Tag | Capability Witnessed |
|---|---|---|---|
| `d8ce2a5` | `feat(durable)` | `AshPPlan.Obligation` | Subject tracking on durable run boundary |
| `c2ea704` | `feat(powl)` | `IMP-T006` | Bounded reachability deadlock/orphan court + loop-choice-body refusal |
| `913ab93` | `feat(powl)` | `IMP-T005` | Gamma choice-graph operator + soundness verifier rules |
| `f496f33` | `test(mock-discipline)` | `V8-MOCKCOURT-e` | Fleet zero-mock court ported from `ash_a2a` |
| `da63bdc` | `chore(powl)` | `P2` | POWL interactive/demonstration refresh |
| `88f71da` | `test(telemetry)` | `P3` | Telemetry emission-points + emit-integration courts |
| `3d0f33e` | `feat(durable)` | `P1` | Durability engine surface + courts + claims bench |
| `fef59ff` | `feat(powl)` | `P2` | POWL projection/verifier engine + compiler seam test |
| `cc8be0e` | `feat(telemetry)` | `P3` | Buffering emitter + emit event surface |
| `eb4260f` | `feat(courts)` | `A1` | Airbus UP->p-plan transpiler + 14-case parity corpus |
| `2ed8ee5` | `feat(htn)` | `HTN-PPLAN` | Port HTN/HDDL/STRIPS planner from `ex4pm` into `AshPPlan` |

---

## 2. Active Swarm Roster (10 Specialized Review Agents)

1. `@zach-daniel` — Ash Framework, Reactor DAG, AshStateMachine, AshOban, Spark DSL alignment, RCE prevention & transaction safety (`evaluations/EVAL-01-ZACH-DANIEL.md`).
2. `@joe-armstrong` — Concurrency, OTP supervision trees, level-triggered scheduling (`Engine.runnable?/4`), LeaseMonitors & reverse unwind crash atomicity (`evaluations/EVAL-02-JOE-ARMSTRONG.md`).
3. `@jose-valim` — Idiomatic Elixir, package boundary, mix/hex compilation contracts, zero unhygienic macros, formal Store behaviours & Splode error unwrapping (`evaluations/EVAL-03-JOSE-VALIM.md`).
4. `@chris-mccord` — Observability, OCEL 2.0 process evidence, zero web runtime leakage in `lib/`, pure OTP telemetry, drop-with-counter backpressure & LiveView subscriber cleanup (`evaluations/EVAL-04-CHRIS-MCCORD.md`).
5. `@pragmatic-programmers` — Andy Hunt & Dave Thomas: Canonical `ontology.ttl` single source of truth (DRY Law), system orthogonality, executable tracer bullets & Chicago-school zero-mock discipline (`evaluations/EVAL-05-PRAGMATIC-PROGRAMMERS.md`).
6. `@francesco-cesarini` — OTP reliability, guarded status CAS transitions, TLA+ formal verification, PETRI25 Algorithm 3 POWL soundness & StreamData chaos with anti-vacuity sabotage (`evaluations/EVAL-06-FRANCESCO-CESARINI.md`).
7. `@mike-williams` — AXD301 "nine nines" industrial availability, DETS PathLock mutual heir guardian, power-loss crash recovery & resource-bounded buffers (`evaluations/EVAL-07-MIKE-WILLIAMS.md`).
8. `@robert-virding` — BEAM VM instruction set optimization, actor purity (zero process dictionary usage), homoiconic ASTs & data-only step options with closures banned (`evaluations/EVAL-08-ROBERT-VIRDING.md`).
9. `@fred-hebert` — "Erlang in Anger" 3 AM production debuggability, inspectable durable records, mailbox explosion defense & stateful property testing (`evaluations/EVAL-09-FRED-HEBERT.md`).
10. `@rich-hickey` — "Simple Made Easy" untangling of Information, Logic, and Mechanism, Epochal Time Model, values over mutable references & actuation ceilings (`evaluations/EVAL-10-RICH-HICKEY.md`).

---

## 3. Pre-flight Release Gate Checklist

- [x] Canonical checkout enforced (`/Users/sac/ash_pplan`, zero worktree copies).
- [x] `./bin/verify-package` clean from unpackaged tarball (`MIX_ENV=prod mix compile --warnings-as-errors`, exit `0`).
- [x] `mix compile --warnings-as-errors` passes cleanly (exit `0`, zero warnings).
- [x] `mix hex.build` creates byte-verifiable archive (`ash_pplan-26.11.10.tar`, `879,616` bytes, `863` packaged files; outer SHA-256 `4d2e75ccfce3996f2632d81b882a981b4e0276a45585e49d177b9b273b41cc95`; inner `CHECKSUM` `9c995189923c2ea2a70b80c9edd97cbad8548eb5ac034c5b412bceac05ae283a`).
- [x] `docs/jira/v26.11.10/` epics, ECOs, 10-persona domain evaluations (`evaluations/`), swarm review synthesis (`SWARM-REVIEW-SYNTHESIS.md` — 196.0/200, 98%), and `HEX-RELEASE-COURT-RECEIPT.md` complete.
- [x] Hex publish dry-run executed (`mix hex.publish --dry-run --yes`, exit `0`).
