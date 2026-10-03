# How to run a durable run on Store.Dets

Goal: you want a workflow that survives the process that started it — start a
run on the DETS-backed store, park it on a signal, resume it from a new store
process on the same file, and export the standing ledger as OCEL 2.0 evidence.

Every function shown below is a real signature from `lib/` and every sequence
is one the test suite already courts: the restart pattern is
`test/durable/store_dets_test.exs`, the engine-level await pattern is
`test/durable/extra_await_test.exs`, and the export pattern is
`test/durable/ledger_ocel_test.exs`.

## Prerequisites

- This repo, `mix compile` clean.
- A DETS file path (binary). The store creates it on open; give it a unique
  per-session path so concurrent sessions do not share state:
  `Path.join(System.tmp_dir!(), "ash_pplan_dets_#{System.unique_integer([:positive])}.dets")`
  (the pattern `test/durable/store_dets_test.exs` uses, with an `on_exit`
  `File.rm/1`).
- A plan (model + realizations). The courts use the test fixtures
  (`AshPPlan.Test.DurableFx` / `ExtraFx` with `Effects.start_link/1`); the
  call shapes are identical for a production model.

## 1. Start a run on Store.Dets

```elixir
alias AshPPlan.Reactor.Durable.{Engine, Store.Dets}

{:ok, store} = Dets.start_link(path: path)

{:ok, _record} =
  Engine.start(store, %{
    id: "order-7",
    model: model,                      # Plan Model struct
    bindings: bindings,                # task => %Realization{}
    inputs: %{input: %{order: "order-7"}},
    context: %{
      ash_pplan_workflow: %{subject: "sha256:" <> String.duplicate("ab", 32),
                            task: "order-7"}
    },
    parent: nil
  })

{:completed, _} = Engine.attempt(store, "order-7", store_module: Dets)
```

`Engine.start/3` is idempotent by `attrs.id`. `Engine.attempt/3` claims the
run (claimer + lease), drives steps to the next parking point or terminal
state, and releases the claim; outcomes are `:ended`, `{:completed, _}`,
`{:parked, :waiting}`, `{:parked, :polling}`, `:taken`, `:not_found`,
`{:failed, _}`, `{:rolled_back, _}`, `{:refused, _}` (see the `t:outcome/0`
type in `lib/ash_pplan/reactor/durable/engine.ex`).

Note the `store_module: Dets` option on every engine call. Without it the
engine and the ledger default to `AshPPlan.Reactor.Durable.Store.Ets`
(`Run.store_module/1`), and the DETS store would never be read.

## 2. Park on an await and signal it

A step with `kind: :await` parks the run; the run's status becomes `:waiting`
and a waiter is recorded per signal name.

```elixir
assert {:parked, :waiting} = Engine.attempt(store, "order-7", store_module: Dets)
assert ["go"] = Testing.waiting_on(store, "order-7")

# Deliver the signal (consume-once, FIFO per name):
{:ok, _signal} = Engine.signal(store, "order-7", "go", %{released: true})
```

Delivery alone does not run steps — scheduling is level-triggered. Either
attempt again, or let the installed dispatch machinery drain it
(`Testing.drain/2` in the courts). Both appear in
`test/durable/extra_await_test.exs`:

```elixir
assert {:completed, _} = Engine.attempt(store, "order-7", store_module: Dets)
assert Enum.any?(Engine.steps(store, "order-7", store_module: Dets),
                &(&1.output == %{released: true}))
```

## 3. Resume after a restart

Every mutating DETS call syncs the file, so a stopped, crashed or killed store
process loses nothing a caller was told succeeded. Restarting is: stop the
GenServer, start a new one on the same `:path`, keep passing
`store_module: Dets`.

```elixir
ref = Process.monitor(store)
GenServer.stop(store)
assert_receive {:DOWN, ^ref, :process, ^store, _}

{:ok, store2} = Dets.start_link(path: path)   # same file = same state

# runs, standing checkpoints, signals, waiters, leases, seq counter: intact
assert %{status: :waiting} = Engine.fetch(store2, "order-7", store_module: Dets)
```

This is the pattern of `test/durable/store_dets_test.exs` ("state survives
stopping the store process and starting a new one on the same file"); that
court also proves the sequence counter continues after restart, so new rows
sort after old ones.

## 4. Replay after restart

A new store process on the same file is the same run: attempt it and the
engine re-enters with the standing checkpoints replayed — completed steps are
not re-executed, the run resumes from where it parked.

```elixir
{:ok, _signal} = Engine.signal(store2, "order-7", "go", %{released: true})
assert {:completed, _} = Engine.attempt(store2, "order-7", store_module: Dets)
assert Enum.map(Engine.steps(store2, "order-7", store_module: Dets), & &1.label)
       == labels_before_restart   # same checkpoints, same order
```

## 5. Export the ledger as OCEL 2.0 evidence

`LedgerOCEL.export/3` exports the standing checkpoint ledger as OCEL 2.0 JSON:
one `run_started` event, one `task_succeeded` per standing checkpoint ordered
by `seq`, and `run_ended` when the status is terminal. Events carry the
workflow subject id from `context.ash_pplan_workflow.subject` — set it at
start (step 1) or the export is subject-less and the subject-binding
assertions in the court would fail.

```elixir
alias AshPPlan.Reactor.Durable.LedgerOCEL

{:ok, events} =
  LedgerOCEL.events(store2, "order-7", store_module: Dets)
assert {:ok, json} = LedgerOCEL.export(store2, "order-7", store_module: Dets)
assert json =~ "\"events\""

# content digest over the exported evidence; changes if any standing output changes
{:ok, digest} = LedgerOCEL.digest(store2, "order-7", store_module: Dets)
```

`LedgerOCEL.events/3` returns `{:error, %{reason: :no_such_run}}` for an
unknown run (typed refusal). This section mirrors
`test/durable/ledger_ocel_test.exs`.
