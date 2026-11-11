# Domain Evaluation Brief: Joe Armstrong
## Erlang Philosophy, Concurrency, Let-It-Crash, Level-Triggered Scheduling & Replay

- **Evaluator**: Joe Armstrong (Co-inventor of Erlang, Actor Model & Fault-Tolerance Architect)
- **Role**: Distributed Systems & Fault-Tolerance Authority
- **Milestone**: `v26.11.10`
- **Date**: 2026-11-10
- **Status**: APPROVED (Score: `19.5 / 20.0` — 97.5%)

---

## 1. Executive Profile & Lens

Joe Armstrong co-invented Erlang at the Ericsson Computer Science Laboratory, designing a language and runtime environment specifically for building fault-tolerant, highly concurrent, distributed systems that run forever without downtime. His core doctrines:
1. **Isolated Processes with Shared-Nothing Memory**: Every process is a world unto itself. If one process dies, it cannot corrupt the memory of another.
2. **Let It Crash & Error Kernels**: Do not clutter code with defensive programming against unexpected internal errors. Let the process crash, isolate the blast radius, and let a supervisor or restart mechanism restore known good state.
3. **Level-Triggered State vs Edge-Triggered Messages**: Do not build reliability on the fragile assumption that every wakeup message or timer tick will survive process death. Recovery should be computed from durable state.
4. **Idempotence & Replay**: A workflow that crashes mid-step must be safely restartable without duplicating side effects.

Evaluating `ash_pplan` through Joe Armstrong's lens means interrogating its durability engine, concurrency boundaries, crash isolation, lease monitor lifecycles, and rollback atomicity.

---

## 2. Technical Surface Area Under Review

The following primary modules and files were scrutinized during this evaluation:

| Module / Artifact | File & Line References | Architectural Function |
|---|---|---|
| `AshPPlan.Reactor.Durable.Engine` | `lib/ash_pplan/reactor/durable/engine.ex:1-691` | Durable run lifecycle, lease management, level-triggered `runnable?/4` scheduling |
| `AshPPlan.Reactor.Durable.Engine.runnable?/4` | `lib/ash_pplan/reactor/durable/engine.ex:634-678` | Level-triggered runnability evaluation derived from persistent store state |
| `AshPPlan.Reactor.Durable.LeaseMonitor` | `lib/ash_pplan/reactor/durable/lease_monitor.ex:1-153` | Sub-millisecond ephemeral lease release via BEAM `Process.monitor/1` and `:DOWN` signals |
| `AshPPlan.Reactor.Durable.Unwind` | `lib/ash_pplan/reactor/durable/unwind.ex:1-220` | Crash-atomic reverse compensation walking persistent checkpoints |
| `AshPPlan.Reactor.Durable.Store` | `lib/ash_pplan/reactor/durable/store.ex:1-109` | Behaviour separating durable run persistence from execution processes |
| `AshPPlan.Reactor.Durable.Store.Wal` | `lib/ash_pplan/reactor/durable/store/wal.ex:1-180` | Write-Ahead Log writer with sequential framing and frame acknowledgments |
| `AshPPlan.Reactor.Durable.Key` | `lib/ash_pplan/reactor/durable/key.ex:1-62` | Deterministic intent tokens (`Key.intent_id/2`) preventing duplicated actuation |

---

## 3. Architectural Analysis & Findings

### 3.1 Level-Triggered Scheduling (`Engine.runnable?/4`)
The design of `AshPPlan.Reactor.Durable.Engine` embodies the quintessential Erlang philosophy: **never depend on ephemeral messages surviving process crashes**.
In many workflow engines, scheduling is edge-triggered: a scheduler sends a `:wakeup` or `:poll` message to a process mailbox. If that process is killed or the node crashes, the message is lost forever, resulting in a zombie workflow.

`ash_pplan` rejects edge-triggered fragility in favor of level-triggered scheduling:
```elixir
# lib/ash_pplan/reactor/durable/engine.ex:10-13, 637-663
@doc "Level-triggered: should an attempt at this run do anything at `now`?"
def runnable?(store, record, now, opts \\ []) do
  mod = Run.store_module(opts)
  s = record.status

  cond do
    Status.terminal?(s) or s == :unwind_blocked -> false
    held?(record, now, opts) -> false
    Status.rolling_back?(s) -> true
    record.claimed_at != nil -> true
    s == :pending -> true
    Status.parked?(s) ->
      signal_waiting?(mod, store, record) or waiter_due?(mod, store, record, now)
    true -> false
  end
end
```
An engine attempt recomputes runnability directly from the durable record:
1. Is the status non-terminal and not held by an active lease?
2. Is a rollback pending that nobody holds?
3. Is it pending initial execution?
4. If parked, is there an unconsumed signal (`signal_waiting?`) or a due deadline (`waiter_due?`)?

Because runnability is a pure function of durable store state and current time (`now`), a node can crash at any microsecond, reboot, scan the store via `Engine.runnable/3`, and resume execution with zero lost work.

### 3.2 Monotonic Ephemeral Leases (`LeaseMonitor`)
To coordinate workers without distributed locks, `LeaseMonitor` binds claim leases to the BEAM process monitor subsystem:
```elixir
# lib/ash_pplan/reactor/durable/lease_monitor.ex:1-8
@moduledoc """
Structures execution leases as `{owner_pid, epoch, ref}` with BEAM `Process.monitor/1`.
If a worker dies, the `:DOWN` monitor signal marks the lease abandoned — no polling
window, no 30-second zombie wait on worker crash.
"""
```
- **Soak & Benchmark Evidence**: In soak tests (`test/durable/lease_monitor_soak_test.exs`), holder termination trips the `:DOWN` monitor and frees the lease in sub-millisecond time (p50 ≈ 5µs, p95 ≈ 63µs, max ≈ 214µs).
- **Table Hygiene**: 100 consecutive grant/crash cycles return the ETS table and monitor map to baseline size (0/0), demonstrating zero resource leaks.
- **Single-Node Honesty**: The documentation explicitly acknowledges BEAM reality: `Process.monitor/1` cannot span unlinked nodes, clearly stating that `LeaseMonitor` is single-node only and requires store-level clustering for multi-node deployments.

### 3.3 Reverse Compensation Crash Atomicity (`Unwind`)
The compensation mechanism in `AshPPlan.Reactor.Durable.Unwind` is a masterclass in crash resilience:
```elixir
# lib/ash_pplan/reactor/durable/unwind.ex:6-10
"""
A rollback that must survive the process it started in has no executor entry point,
so this walks the store's standing checkpoints directly. The `undone_at` marks written
by `Store.claim_undo/4` are the progress log: a crash mid-rollback leaves the remaining
checkpoints standing and the next call carries on from exactly there.
"""
```
Key architectural guarantees:
1. **Newest-First Traversal**: Checkpoints are rolled back in strict reverse chronological order.
2. **Volatile Undo Claims**: Before rolling back a step, `Store.claim_undo/4` marks the checkpoint. If the rollback process is killed violently (`kill -9` or `:kill`), the uncompleted checkpoint remains standing. The next invocation picks up at the exact checkpoint that crashed, achieving true crash atomicity.
3. **No Dynamic Reactor Rebuilding**: Checkpoints store the serialized step implementation module (`impl`) and arguments (`args`). Rollback does not require re-instantiating the original DAG; it invokes the step's `undo/4` callback directly with stored arguments.

### 3.4 Side-Effect Deduplication via Intent Tokens
External side effects cannot be rolled back with simple memory resets. In `AshPPlan.Reactor.Durable.Key`, intent tokens (`Key.intent_id/2`) are derived and written to the durable store prior to triggering external actions. On restart, steps inspect `Run.recorded/2` and skip execution if the intent token was already fulfilled, providing at-least-once safety with deterministic deduplication.

---

## 4. Probing Inquiries & Falsifiers

### Inquiry 1: What happens if an Engine worker process crashes while holding a run?
**Analysis**: `Engine.attempt/3` claims the run via `Store.claim/5` with a default lease of `@lease_ms 30_000`. If `LeaseMonitor` is attached, the `:DOWN` signal releases the claim immediately. If only the wall-clock lease is used, `held?/3` evaluates to `false` once `now > lease_until`, allowing another worker to safely reclaim the run.
**Falsifier**: If an attempt dies, does the record remain locked forever? Proven `false` by `pack_durable_chaos_court_test.exs:kill_after_claim`, which demonstrates that after `@lease_ms` expires, `runnable?/4` evaluates to `true` and recovery succeeds.

### Inquiry 2: Does message passing in WAL writers cause caller mailbox accumulation?
**Analysis**: In `AshPPlan.Reactor.Durable.Store.Wal.Writer`, synchronous frames are cast or called. In early prototypes, asynchronous acks returned double replies. The current implementation uses explicit `GenServer.reply/2` callers, preventing mailbox leakage.

### Inquiry 3: Can competing nodes concurrently claim the same runnable step?
**Analysis**: Under `Store.Ets`, atomic `:ets.insert_new/2` guarantees that exactly one process wins a claim. Under `Store.Dets`, single-process serialization guarantees claim uniqueness.

---

## 5. Scored Evaluation Rubric

| Dimension | Weight | Score | Evaluation Justification |
|---|:---:|:---:|---|
| **1. Process Isolation & Shared-Nothing Semantics** | 25% | `5.0 / 5.0` | Workflows execute in isolated BEAM processes. Context and state are passed immutably; zero shared mutable state or process dictionary contamination. |
| **2. Level-Triggered Crash Tolerance** | 25% | `5.0 / 5.0` | `Engine.runnable?/4` computes runnability directly from durable state. Zero dependence on ephemeral messages or timer survival across crashes. |
| **3. Lease & Monitor Dynamics** | 25% | `4.5 / 5.0` | `LeaseMonitor` achieves sub-millisecond `:DOWN` reclamation. Minor recommendation to wire `LeaseMonitor` directly into the default `Engine.attempt/3` path. |
| **4. Rollback & Compensation Resilience** | 25% | `5.0 / 5.0` | `Unwind` walks standing checkpoints in reverse order with volatile undo claims, ensuring crash-atomic rollback progress. |
| **TOTAL** | **100%** | **`19.5 / 20.0`** | **Superb manifestation of Erlang's core principles: isolation, level-triggered recovery, and crash-atomic rollback.** |

---

## 6. Verdict & Operational Recommendations

### Verdict: **APPROVED**
`ash_pplan` v26.11.10 honors the Erlang philosophy of building resilient software. By grounding its execution engine in level-triggered state inspection, process-isolated workers, and crash-atomic compensation, it ensures that systems can let processes crash without losing state or corrupting workflows.

### Operational Recommendations
1. **Direct `LeaseMonitor` Integration in `Engine`**: Currently, `Engine.attempt/3` defaults to a 30-second wall-clock lease (`@lease_ms 30_000`). Wire `LeaseMonitor.claim/3` directly into the default attempt loop so that process termination immediately frees the claim, dropping recovery time from 30 seconds to microseconds in single-node environments.
2. **ETS Table Heir Protection**: For transient ETS tables used during execution, ensure they are initialized with an `:heir` option (pointing to a dedicated table-owner supervisor) so that crashes in worker processes do not trigger unintended table destruction.
