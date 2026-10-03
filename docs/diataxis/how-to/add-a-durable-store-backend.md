# How to add a new durable store backend

Goal: a new persistence implementation of the `AshPPlan.Reactor.Durable.Store` behaviour (for
example Postgres), wired in and proven by the generated conformance suite before anything uses it.

The only contract a backend implements is the behaviour in
`lib/ash_pplan/reactor/durable/store.ex`. Engine, run, unwind and step code never touch ETS, DETS
or your backend directly — they resolve the module through
`AshPPlan.Reactor.Durable.Run.store_module/1` and call callbacks through it
(`lib/ash_pplan/reactor/durable/engine.ex:38`, `lib/ash_pplan/reactor/durable/run.ex:24-28`,
`lib/ash_pplan/reactor/durable/unwind.ex:38`, `lib/ash_pplan/reactor/durable/steps/await.ex:141-142`).

## Prerequisites

- The behaviour read end to end: `lib/ash_pplan/reactor/durable/store.ex` (20 callbacks).
- The record structs the callbacks return:
  `lib/ash_pplan/reactor/durable/records.ex` (`Record`, `Checkpoint`, `Signal`, `Waiter`)
  and `lib/ash_pplan/reactor/durable/status.ex` (`Status.can?/2`, `Status.terminal?/1`).
- One reference implementation studied: `lib/ash_pplan/reactor/durable/store/ets.ex` (single node,
  non-persistent) or `lib/ash_pplan/reactor/durable/store/dets.ex` (one local file on one node).
  Neither is a durability claim — copy their losing-behaviour semantics, not their limits.

## Step 1: Implement the behaviour callbacks

Create your module with `@behaviour AshPPlan.Reactor.Durable.Store`. The `store` first argument is
`pid() | atom()` (`store.ex:9`) — the handle your `start_link` returns; both reference
implementations treat it as a GenServer and serialize every operation through its mailbox with
`GenServer.call(..., :infinity)` (`store/ets.ex:70`, `store/dets.ex:82`).

Every write defines its losing behaviour so concurrent attempts cannot corrupt a run
(`store.ex` moduledoc). Concurrency laws in the suite run up to 32 simultaneous callers and require
exactly one winner, so claim/transition/record/consume/claim_undo/start_run must be
linearizable compare-and-set operations (with Postgres: one transaction per callback, row-level
locks or `INSERT ... ON CONFLICT`).

| Callback | Returns | Semantics |
|---|---|---|
| `start_run(store, attrs)` | `{:ok, Record.t()}` \| `{:error, :exists}` | Exclusive per `attrs.id`. `:id`, `:version`, `:seq` are protected (caller values dropped); `version` starts at 1; `attrs[:parent]` `{parent_id, parent_signal}` is split into `parent_id`/`parent_signal` (`store/ets.ex:95-118`). |
| `get_run(store, id)` | `Record.t()` \| `nil` | Plain read. |
| `list_runs(store)` | `[Record.t()]` | All runs in insertion (`seq`) order. |
| `transition(store, id, from, to, attrs)` | `{:ok, Record.t()}` \| `{:error, :stale \| :not_found \| :illegal}` | Guarded: applies only if current status is in `from` (`:any` = any non-terminal), else `:stale`. Legality must come from `Status.can?(status, to)`, else `:illegal`. Success bumps `version`. Never hand-roll transition legality (`store/ets.ex:127-139`). |
| `claim(store, id, claimer, lease_ms, now)` | `{:ok, Record.t()}` \| `:taken` | Claimable when unclaimed, lease lapsed (`now >= claimed_at + lease`), or the same non-nil claimer re-enters. A `nil` claimer never re-enters. Unknown run → `:taken` (`store/ets.ex:141-154, 323-330`). |
| `release_claim(store, id, claimer)` | `:ok` | Clears only the holder's claim; idempotent, no-op for others and unknown runs. |
| `checkpoints(store, id)` | `%{step_key => Checkpoint.t()}` | Map keyed by `step_key`, scoped to the run. |
| `standing(store, id)` | `[Checkpoint.t()]` | Checkpoints with `undone_at == nil`, ascending `seq`. |
| `record(store, id, step_key, label, output, meta)` | `{:ok, Checkpoint.t()}` \| `{:error, :terminal}` | Insert-or-adopt: if a row for `(run, step_key)` exists return the standing one unchanged (adopters see the first output, never the caller's). A terminal run refuses new checkpoints but still adopts (`store/ets.ex:173-189`). `meta` supplies `name`/`impl`/`args` snapshot fields. |
| `claim_undo(store, id, step_key, now)` | `{:ok, Checkpoint.t()}` \| `:taken` | Consume-once per checkpoint: sets `undone_at`; second claim and missing key → `:taken`. |
| `release_undo(store, id, step_key)` | `:ok` | Reopens the checkpoint (`undone_at = nil`); idempotent. |
| `deliver_signal(store, id, name, payload)` | `{:ok, Signal.t()}` | Appends with a unique monotonic `id`/`seq`; FIFO per name. |
| `pending_signal(store, id, name)` | `Signal.t()` \| `nil` | Earliest unconsumed signal for the name. |
| `consume_signal(store, signal_id, now)` | `{:ok, Signal.t()}` \| `:taken` | Consume-once: sets `consumed_at`; second consume and unknown id → `:taken`. |
| `park(store, id, name, kind, deadline, opts)` | `{:ok, Waiter.t()}` | Insert when absent; an existing waiter is returned unchanged unless `overwrite: true` — the first deadline wins, measured once. |
| `get_waiter(store, id, name)` | `Waiter.t()` \| `nil` | Plain read. |
| `waiters(store, id)` | `[Waiter.t()]` | Run-scoped, by name. |
| `release(store, id, name)` / `release_all(store, id)` | `:ok` | Idempotent, strictly run-scoped — never touch other runs. |
| `signals(store, id)` | `[Signal.t()]` | Run-scoped, ascending `seq`. |

Persistence shape: `Checkpoint` snapshots `impl` and `args` so unwind needs no rebuild
(`records.ex:25`); `output` is an arbitrary `term()` (`store.ex:33`). Both reference stores persist
raw Erlang terms; a backend that cannot (e.g. row storage) must round-trip these values losslessly.

## Step 2: Wire configuration

Resolution order in `Run.store_module/1` (`lib/ash_pplan/reactor/durable/run.ex:24-28`):

1. `store_module:` option on the call (`Engine.attempt/3`, `Engine.start/3`, `Unwind.run/3`, ...);
2. application env: `Application.get_env(:ash_pplan, :durable_store_module)`;
3. default `AshPPlan.Reactor.Durable.Store.Ets`.

To make your backend the application-wide default:

```elixir
# config/config.exs (or runtime.exs)
config :ash_pplan, durable_store_module: MyApp.DurableStore.Postgres
```

The store handle itself is passed separately as the first argument of every engine function;
start it in your application supervision tree under whatever name your module expects.

## Step 3: Prove conformance before use

The suite `AshPPlan.Test.StoreConformance` is generated — never edit
`test/support/durable/store_conformance.ex`. It is manufactured from the store-conformance
ontology (`priv/ggen/ash-pplan-store-conformance-pack/ontology.ttl`: one `sc:Callback` per
callback, one executable `sc:Law` per behavioural law, `sc:covers` links; the template refuses a
callback covered by no law) by `bin/manufacture-store-conformance`, which runs
`mix ggen_igniter.sync` and writes `test/support/durable/store_conformance.ex`
(`priv/ggen/ash-pplan-store-conformance-pack/bin/manufacture-store-conformance`).

A new backend adds no ontology and regenerates nothing. Add one test file that binds the suite to
your module, mirroring `test/durable/store_conformance_ets_test.exs` and
`test/durable/store_conformance_dets_test.exs`:

```elixir
defmodule MyApp.DurableStorePostgresConformanceTest do
  use AshPPlan.Test.StoreConformance,
    store: MyApp.DurableStore.Postgres,
    start: fn -> MyApp.DurableStore.Postgres.start_link([]) end
end
```

`start/0` must return `{:ok, store}` for a FRESH store; the suite's `boot/2` then pre-inserts run
`"r1"` with `model: :m, bindings: %{a: 1}` (`test/support/durable/store_conformance.ex:141-145`).
The Dets wrapper shows the pattern for per-test temp state plus `on_exit` cleanup
(`test/durable/store_conformance_dets_test.exs`). The suite generates one ExUnit test per law
(14 laws: run exclusivity, guarded transitions, claim leases, concurrent claim/record/consume
winners, insert-or-adopt, seq ordering, terminal refusal, undo-once, signal FIFO/consume-once,
park deadlines, idempotent release).

Run the ladder, narrow first:

```sh
mix compile --warnings-as-errors
mix test test/durable/store_conformance_<name>_test.exs
mix test test/durable/
```

The suite is anti-vacuous by construction: `StoreConformanceAntiVacuityTest`
(`test/durable/store_conformance_dets_test.exs`) runs deliberately broken stores through the same
laws, requires each mutant to fail exactly the law it violates, and pins the ontology's callback
list to `Store.behaviour_info(:callbacks)` — so a backend that satisfies the suite has not gamed a
weak gate. Per `AGENTS.md` (Durable store fence): the backend must pass this suite
**before it is used**.

## Fence notes

- **Behaviour is the only seam.** Engine, run, unwind and step code must not touch ETS or any
  backend directly; all persistence goes through the `Store` behaviour (`AGENTS.md`, Durable
  store fence). `Store.Ets` is single node and non-persistent; `Store.Dets` persists to one local
  file on one node — a reference implementation, not a durability claim.
- **No definition versioning exists.** There is no schema-migration story for stored runs; a
  backend stores today's struct shapes and that is the whole contract.
- **Delivery is at-least-once.** Reactor/Oban outcomes may re-deliver, so any external effect your
  steps perform needs an idempotency key; the store's insert-or-adopt/consume-once semantics are
  what makes replay safe on the stored side.
- **Step options are data** (ints, atoms, `{m, f, args}`), never closures — your backend must
  persist only data, matching `Record` "Persists the Model + bindings (data), never a module"
  (`records.ex:2`) and the `Checkpoint` `impl`/`args` snapshot.
- **Do not repair generated code.** If a law or callback list must change, change the pack
  ontology and regenerate with `bin/manufacture-store-conformance`; `lib/ash_pplan/catalog/`, `lib/ash_pplan/workflow/`, and
  `lib/ash_pplan/providers/` plus `test/support/durable/store_conformance.ex` are projections (`AGENTS.md`, Manufacture).
