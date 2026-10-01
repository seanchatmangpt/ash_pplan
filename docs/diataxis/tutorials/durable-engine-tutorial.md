# Tutorial: the durable run ledger

You will follow one narrative path: a plan that outlives the process running it. By the end
you will have learned what problem the durable run ledger solves, how the `Store` behaviour
contract makes concurrent attempts safe, why step options are data instead of closures, how
guarded status transitions absorb late arrivals, and how a rollback survives the process that
started it.

Who this is for: you have read `AGENTS.md` ("Durable store fence") and you know basic Reactor
vocabulary (steps, middleware, undo). What you need: the repository checked out at
`/Users/sac/ash_pplan`, Elixir and mix installed.

Everything below cites paths. Read each cited file as you go; the lesson is in the sources,
not in this file.

## The problem: a plan outliving its process

A Reactor run lives in one process. If that process dies mid-plan:

- finished steps are lost and would run again on retry (double-applied side effects);
- a rollback, which Reactor drives from inside a live run, has no executor left to drive it;
- two retrying attempts could interleave and corrupt the run's state.

The durable engine answers with a **ledger in a store**: a run is a row, each finished step is
a checkpoint row, and every write to the store defines what happens when two callers race.
Attempts become restartable: claim the run, replay the recorded checkpoints through their real
step implementations, map the outcome to a guarded status transition.

Design note: the engine's design is derived from mbuhot/magma (MIT per its mix.exs) and
re-implemented; there is no dependency on magma, Oban or Postgres. See `docs/NOTICE.md`.

## The map

Everything lives in `lib/ash_pplan/reactor/durable/`. This lesson uses:

| concern | module | file |
|---|---|---|
| persistence contract | `AshPPlan.Reactor.Durable.Store` | `store.ex` |
| ledger rows | `Record`, `Checkpoint`, `Signal`, `Waiter` | `records.ex` |
| lifecycle | `AshPPlan.Reactor.Durable.Engine` | `engine.ex` |
| replay | `AshPPlan.Reactor.Durable.Run` | `run.ex` |
| per-step wrapper | `AshPPlan.Reactor.Durable.Checkpointed` | `checkpointed.ex` |
| failure cause | `AshPPlan.Reactor.Durable.Middleware` | `middleware.ex` |
| status machine | `AshPPlan.Reactor.Durable.Status` | `status.ex` |
| rollback | `AshPPlan.Reactor.Durable.Unwind` | `unwind.ex` |
| wait steps | `Steps.Await`, `Steps.Poll`, `Steps.Dispatch` | `steps/` |
| plan refusal | `AshPPlan.Reactor.Durable.Verifier` | `verifier.ex` |
| backends | `Store.Ets`, `Store.Dets` | `store/ets.ex`, `store/dets.ex` |
| step identity | `AshPPlan.Reactor.Durable.Key` | `key.ex` |
| test helpers | `AshPPlan.Reactor.Durable.Testing` | `testing.ex` |

The directory also holds `policy_driver.ex`, `counterfactual.ex`, `migration.ex`,
`portable.ex`, `ledger_ocel.ex` and `testing.ex` companions; they are outside this lesson.

## Lesson 1: a run is a row, a step is a checkpoint row

`AshPPlan.Reactor.Durable.Record` (`records.ex:1`) is the run row: id, plan IRI, `model`,
`bindings`, `inputs`, `context`, `status`, `result`, `error`, claim fields, `version`, `seq`.
Its moduledoc states the rule that makes replay possible: *persists the Model + bindings
(data), never a module.*

`AshPPlan.Reactor.Durable.Checkpoint` (`records.ex:24`) is one standing step output. It
snapshots `impl` and `args` alongside `output` — remember this when you reach unwinding; the
rollback never rebuilds the reactor to take work back.

Step identity is `Key.for_name/1` (`key.ex:11`): SHA-256 of the step name encoded with
`:erlang.term_to_binary(name, [:deterministic, minor_version: 2])`. Consequence: a reordered
step replays (same name, same key), a renamed step re-runs (new key, new checkpoint). Identity
is the hash; the human-readable `label/1` is never used for identity.

When you start a run with `Engine.start/3` (`engine.ex:35`), an existing run with the same
`attrs.id` is returned unchanged — start is idempotent by id.

## Lesson 2: the Store behaviour contract

`AshPPlan.Reactor.Durable.Store` (`store.ex`) is a behaviour. Read its moduledoc: *every write
defines its losing behaviour*, so concurrent attempts cannot corrupt a run. The four racing
shapes to learn:

1. **Guarded transition** — `transition(store, id, from, to, attrs)` applies only if the
   current status is in `from` (or `:any` meaning non-terminal); otherwise `{:error, :stale}`
   or `{:error, :illegal}` (`store.ex:17`).
2. **Insert-or-adopt** — `record/6` returns the standing checkpoint when one already exists
   for `(run, key)`; the first writer wins and a later writer adopts (`store.ex:28`).
3. **Consume-once** — `consume_signal/3` returns `{:ok, signal}` to the first caller and
   `:taken` to the loser (`store.ex:44`).
4. **Claim CAS with a lease** — `claim/5` succeeds if unclaimed, the lease lapsed, or the same
   claimer re-enters (`store.ex:20`). `claim_undo/3` is the same shape for undo work.

Each row write bumps `version`; `id`, `version` and `seq` are protected keys a caller cannot
overwrite (`store/ets.ex:15`).

### The two shipped backends

- `Store.Ets` (`store/ets.ex`): in-memory ETS tables owned by one GenServer; the mailbox
  serialises all reads and writes, which is what makes the compare-and-set operations above
  linearizable (`store/ets.ex:6`). **It is single node and non-persistent — a reference
  implementation, not a durability claim** (this is stated verbatim in `AGENTS.md`,
  "Durable store fence").
- `Store.Dets` (`store/dets.ex`): the same GenServer serialization over one DETS file on one
  local node. Every mutating call is followed by `:dets.sync/1` (`store/dets.ex:110`), so
  anything a caller was told succeeded survives a stopped, crashed or killed store process;
  restart on the same `:path` and runs, checkpoints, signals, waiters, leases and the sequence
  counter are intact (`store/dets.ex:5`).

The default is `Store.Ets` unless you pass `store_module:` or set the application env
`:ash_pplan, :durable_store_module` (`run.ex:24`).

### The conformance bar for a new backend

A new backend must pass the generated `AshPPlan.Test.StoreConformance` suite before it is used
(`AGENTS.md` fence; suite manufactured by `bin/manufacture-store-conformance`). See how the
shipped backends meet it: `test/durable/store_conformance_ets_test.exs` and
`test/durable/store_conformance_dets_test.exs`. Per its own moduledoc, the DETS conformance
test also runs deliberately broken stores through the same suite and requires each mutant to
fail exactly the law it violates — a suite that cannot refuse is not evidence.

## Lesson 3: step options are data, never closures

A checkpoint must survive the store. A closure cannot, so wherever a durable step needs a
computable option, the option is `{m, f, a}` data resolved at run time:

- `Steps.Await` (`steps/await.ex`): `signal` is a String or `{m, f, a}`;
  `timeout` is ms, `{m, f, a}` or nil; plus `on_timeout: :error | :return` and `block_ms`.
- `Steps.Poll` (`steps/poll.ex`): `until` is `{m, f, a}` answering `{:ok, value}` or `:not_yet`;
  `every` is milliseconds (default 30_000, clamped to at least 1).
- `Steps.Dispatch` (`steps/dispatch.ex`): `workflow` is `{m, f, a}` answering a
  `%{model:, bindings:}` child spec; `inputs` likewise; `async?` optionally.

The test fixture makes the same point from the other side: `test/durable/lane_b_fixture.exs`
keeps steps real and counting, with the `Effects` agent referenced *by registered name* in
options, "so the model and bindings survive the store as data. No mocks."
(`test/durable/lane_b_fixture.exs:4`).

## Lesson 4: guarded status transitions

`Status` (`status.ex`) defines nine statuses. Learn three families:

- **terminal, absorbing**: `completed`, `failed`, `cancelled` — empty `to` lists, no
  transition may overwrite them (`status.ex:30`).
- **parked**: `waiting`, `polling` — the run is a row holding no process.
- **rolling back**: `unwinding`, `cancelling` — a late attempt must not roll a rollback
  forward again; from `:unwinding` only `failed`/`unwind_blocked` is legal, from `:cancelling`
  only `cancelled`/`unwind_blocked` (`status.ex:27`).

`Engine` maps each attempt outcome through these guards (`engine.ex:157`):
`{:ok, result}` → `:completed`; a halt with waiters → `:waiting` or `:polling`; `{:error, e}`
→ `:failed`. The claim is released only *after* the outcome is written, so a delivery landing
in between sees a held run (`engine.ex:5`).

Two subtleties worth learning now:

- `pending -> pending` is a legal self-transition: it lets a same-status guarded write bump
  `version`/attrs without stranding a run in an intermediate status (`status.ex:47`).
- Cancel is only legal from `pending|waiting|polling` (`Status.cancellable?/1`,
  `status.ex:50`). `Engine.cancel/3` (`engine.ex:427`) claims the run under a `cancel-`
  claimer first, so it serializes against a `migration-` claim through the store's claim CAS;
  an in-flight *attempt* claim does not block a cancel — the cancel wins and the attempt's
  forward transitions then fail on the status guard.

Scheduling is level-triggered: `Engine.runnable?/4` (`engine.ex:510`) reads state only —
non-terminal, not held, and pending, or parked with an unconsumed signal or a due waiter, or a
rollback nobody holds, or a lapsed claim. No wake-up message has to survive a crash;
`Engine.runnable/3` lists runnable ids ordered by `seq`.

## Lesson 5: replay and unwind

**Replay.** `Run.run/3` (`run.ex:43`) rebuilds the reactor from the record's stored
`model` + `bindings` via `Project.Reactor.project/2`, then `decorate/2` (`run.ex:97`) wraps
*every* step in `Checkpointed`, neutralises guards, and merges
`context.durable = %{store, store_module, run_id, checkpoints}`. On the second attempt a
finished step's recorded output comes back from `Checkpointed.run/3` (`checkpointed.ex:20`) —
deliberately from the step implementation, not from a guard: Reactor keeps a guard-skipped
step off its undo stack, so a replayed value returned that way could never be taken back
(`checkpointed.ex:4`). A recorded step keeps the answer its guards gave the first time
(`run.ex:123`).

**Failure cause.** `Middleware` (`middleware.ex:17`) writes an uncompensable step failure to
the run row *before* the rollback begins (first error wins — the guarded `:unwinding`
transition is refused once the run is already rolling back), so a later attempt still finds
the cause.

**Unwind.** `Unwind.run/3` (`unwind.ex:35`) walks the store's *standing* checkpoints
newest-first (`unwind.ex:81`) and calls each snapshot's `undo` directly — no reactor rebuild,
because the checkpoint snapshotted `impl` and `args` in Lesson 1. It claims each checkpoint
with `claim_undo/3` before undoing (`unwind.ex:156`), so two racing rollbacks cannot both take
the same work; the `undone_at` mark is the progress log, and a crash mid-rollback leaves the
rest standing for the next call. A failed undo is released back to standing and reported
(`unwind.ex:197`); a checkpoint with no resolvable implementation is reported unresolved and
also left standing. The run then ends through a guarded transition to `:cancelled` or
`:failed` (`engine.ex:206`).

Because delivery is at-least-once, an undo may already have partially happened when it runs
again — external effects need idempotency keys (`AGENTS.md`, "Durable store fence").

## The worked example

The engine courts use one fixture: a linear five-task workflow whose steps count their calls.
Read `test/durable/lane_b_fixture.exs` (`model/1`, `bindings/3`, `attrs/3`) and
`test/durable/engine_test.exs`, which runs the lifecycle over the real `Store.Ets` and real
Reactor.

The attributes a run takes (`lane_b_fixture.exs:166`) are exactly the record's fields:
`%{id:, model:, bindings:, inputs:, context:, parent:}`.

**Park, signal, complete without repeating steps.** In
`test/durable/engine_test.exs:66`, the fixture starts a run whose `integrate` task is bound to
an `Await` step (`kinds: %{integrate: :await}`), then:

```elixir
{:parked, :waiting} = Engine.attempt(store, "p1")   # observe/select/execute ran once
{:ok, _} = Engine.signal(store, "p1", "go", :now)   # deliver; runnable? flips true
[{"p1", {:completed, _}}] = Testing.drain(store)    # attempt until quiescent
assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, verify: 1}
```

The last assertion is the lesson: the three earlier checkpoints replayed, so the counted
effects did not run twice — only `verify` is new. `Testing.drain/2` (`testing.ex:29`) is the
whole scheduler in test form: attempt everything `Engine.runnable/3` reports, repeat until
quiescent, optionally `advance: :next_deadline` to cross a deadline by arithmetic instead of
sleeping. `Testing.tape/2` shows the standing ledger as labels; `Testing.recorded/3` reads one
step's output.

**Failure rolls back exactly once, newest first.** `test/durable/engine_test.exs:89` binds
two steps with undo, fails the last step, and asserts the run ends `:failed` with each undone
effect counted exactly 1 — a later `Engine.attempt/3` returns `:ended` because a terminal run
is never re-run.

**Your exercise.** Run the court yourself and read every assertion before it:

```sh
mix test test/durable/engine_test.exs
```

Then re-read `engine.ex` top to bottom with `status.ex` beside it; the outcome mapping you
just watched is the `settle/4` clauses. The kill-phase properties in `test/durable/chaos/`
(`kill_after_claim_test.exs`, `kill_after_record_test.exs`, `kill_after_park_test.exs`, ...)
are the same lesson with the process killed at each phase boundary.

## What this is not — the honest edges

- **No durability from `Store.Ets`.** Single node, in memory, reference implementation
  (`AGENTS.md`). `Store.Dets` persists to one local file on one node; neither claims
  multi-node durability.
- **No definition versioning.** Stated in `AGENTS.md` and in `Record`'s moduledoc: the ledger
  stores the model as data; if the workflow's *definition* changes shape, there is no
  migration of recorded checkpoints. Re-keying is by step name only (`Key.for_name/1`).
- **Durable wait steps are refused inside nesting composites.** `Verifier.verify/1`
  (`verifier.ex`) walks the plan before it runs and refuses with
  `%{reason: :durable_step_in_nesting_composite, ...}`: `group`/`around`/`recurse`/`compose`
  run steps in a private reactor that holds no checkpoint and cannot halt to park.
- **At-least-once, not exactly-once.** Signals are consume-once in the store, but step
  delivery and undo can repeat across crashes; idempotency of external effects is your job.

## What you learned

- A durable run is a ledger: run row, checkpoint rows, signals, waiters — all data
  (`records.ex`).
- The `Store` behaviour defines each write's losing behaviour: guarded transitions,
  insert-or-adopt, consume-once, claim CAS (`store.ex`).
- Replay returns recorded outputs through the real step implementations; step options are
  `{m, f, a}` data so nothing in the ledger is a closure (`checkpointed.ex:20`, `steps/`).
- Terminal statuses absorb; `:cancelling`/`:unwinding` cannot be overwritten by a late
  attempt; scheduling is level-triggered (`status.ex`, `engine.ex:510`).
- Unwind replays *undo* from snapshot checkpoints newest-first with per-checkpoint claims, so
  rollback survives the process that started it (`unwind.ex`).

Where to go next: `docs/AGENTS.md` ("Durable store fence") for the law; `test/durable/` for
the courts; `bin/manufacture-store-conformance` for what a new backend must survive;
`bin/manufacture-durable-chaos` and `bin/durable-stateright` for the model-level checks.
