# The durable ledger, the stores, and the standing ladder

This page explains *why* the durable run ledger is shaped the way it is: what
the Engine/Run/Checkpointed model buys you, why every store write defines its
losing behaviour, where each shipped store backend honestly stops, and how a
run's evidence is promoted through a fixed 10-rung standing ladder. The
*how-to* recipes and the *what* of the module APIs live elsewhere; everything
here cites the sources, and the lesson is in the sources.

## The Engine / Run / Checkpointed model

A durable run is a ledger of rows, not a process. `AshPPlan.Reactor.Durable.Record`
(`lib/ash_pplan/reactor/durable/records.ex`) is the run row: id, plan IRI,
`model`, `bindings`, `inputs`, `context`, `status`, `result`, `error`, claim
fields, `version`, `seq`. Its moduledoc states the rule that makes replay
possible: *persists the Model + bindings (data), never a module.* Each finished
step is an `AshPPlan.Reactor.Durable.Checkpoint` row that snapshots `impl` and
`args` alongside `output`, so undo needs no reactor rebuild.

Three modules share the work:

- `AshPPlan.Reactor.Durable.Engine` (`lib/ash_pplan/reactor/durable/engine.ex`)
  is the lifecycle: `start/3` is idempotent by run id, `attempt/3` claims the
  run under a lease, `signal/5` delivers to parked runs, `cancel/3` claims under
  a `cancel-` claimer, and `settle/4` maps every attempt outcome through a
  guarded transition. Scheduling is level-triggered: `runnable?/4` reads state
  only, so no wake-up message has to survive a crash; `runnable/3` lists
  runnable ids ordered by `seq`.
- `AshPPlan.Reactor.Durable.Run` (`lib/ash_pplan/reactor/durable/run.ex`) is the
  replay layer. `run/3` rebuilds the reactor from the record's stored
  `model` + `bindings` via `Project.Reactor.project/2`, and `decorate/2` wraps
  *every* step in `Checkpointed`, neutralises guards, and merges
  `context.durable = %{store, store_module, run_id, checkpoints}`. A recorded
  step keeps the answer its guards gave the first time.
- `AshPPlan.Reactor.Durable.Checkpointed` (`lib/ash_pplan/reactor/durable/checkpointed.ex`)
  is the per-step wrapper. Its moduledoc states the reason a recorded output
  returns from `run/3` and not from a guard: Reactor keeps a guard-skipped step
  off its undo stack, so a replayed value returned that way could never be
  taken back. Replaying through the impl makes it an ordinary success that
  lands on the undo stack.

## Guarded status transitions

`AshPPlan.Reactor.Durable.Status` (`lib/ash_pplan/reactor/durable/status.ex`)
defines nine statuses in three families:

- **terminal, absorbing**: `completed`, `failed`, `cancelled` — empty `to`
  lists; no transition may overwrite them.
- **parked**: `waiting`, `polling` — the run is a row holding no process.
- **rolling back**: `unwinding`, `cancelling`, `unwind_blocked` — a late
  attempt must not roll a rollback forward again. From `:unwinding` only
  `failed`/`unwind_blocked` is legal; from `:cancelling` only
  `cancelled`/`unwind_blocked` (`status.ex:27-28`).

`pending -> pending` is a legal self-transition: it lets a same-status guarded
write bump `version`/attrs without stranding a run in an intermediate status
(`status.ex:47`). Cancel is only legal from `pending|waiting|polling`
(`Status.cancellable?/1`, `status.ex:52`); `Engine.cancel/3` claims the run
under a `cancel-` claimer so it serializes against a `migration-` claim through
the store's claim CAS, and an in-flight *attempt* claim does not block a cancel
— the attempt's forward transitions then fail on the status guard. The claim is
released only *after* the outcome is written, so a delivery landing in between
sees a held run.

## The store behaviour, and the two shipped backends

All persistence goes through the `AshPPlan.Reactor.Durable.Store` behaviour
(`lib/ash_pplan/reactor/durable/store.ex`). Its moduledoc states the law: every
write defines its losing behaviour, so concurrent attempts cannot corrupt a
run. Four racing shapes:

1. **Guarded transition** — `transition/5` applies only if the run's status is
   in `from` (or `:any` meaning non-terminal); otherwise `{:error, :stale}` or
   `{:error, :illegal}`.
2. **Insert-or-adopt** — `record/6` returns the standing checkpoint when one
   already exists for `(run, key)`; the first writer wins and a later writer
   adopts.
3. **Consume-once** — `consume_signal/3` returns `{:ok, signal}` to the first
   caller and `:taken` to the loser.
4. **Claim CAS with a lease** — `claim/5` succeeds if unclaimed, the lease
   lapsed, or the same claimer re-enters. `claim_undo/4` is the same shape for
   undo work.

Each row write bumps `version`; `id`, `version` and `seq` are protected keys a
caller cannot overwrite (`store/ets.ex:15`).

### Ets vs Dets: the tradeoffs from the modules

- `AshPPlan.Reactor.Durable.Store.Ets` (`lib/ash_pplan/reactor/durable/store/ets.ex`):
  in-memory ETS tables owned by one GenServer. Every operation is a
  `GenServer.call`, so the mailbox serialises all reads and writes and the
  compare-and-set operations above are linearizable (`store/ets.ex:6`). It is
  **single node and non-persistent — a reference implementation, not a
  durability claim**; a node restart loses every run. It takes no required
  configuration and is the fastest path to a working engine in tests and
  examples — that speed is precisely what makes it a reference implementation,
  not a durability claim. The default backend unless you pass `store_module:`
  or set the application env `:ash_pplan, :durable_store_module` (`run.ex:24`).
- `AshPPlan.Reactor.Durable.Store.Dets` (`lib/ash_pplan/reactor/durable/store/dets.ex`):
  the same GenServer serialization over one DETS file on one local node.
  `start_link/1` requires `:path`; every mutating call is followed by
  `:dets.sync/1` (`store/dets.ex:110`), so anything a caller was told succeeded
  survives a stopped, crashed or killed store process; restart on the same
  `:path` and runs, checkpoints, signals, waiters, leases and the sequence
  counter are intact (`store/dets.ex:5`). The cost is symmetric: still single
  node, and every mutation pays a synchronous file sync — the durability claim
  is exactly as strong as the one DETS file on one host, and no stronger.

### The conformance bar for a new backend

A new backend must pass the generated `AshPPlan.Test.StoreConformance` suite
before it is used. See how the shipped backends meet it:
`test/durable/store_conformance_ets_test.exs` and
`test/durable/store_conformance_dets_test.exs`. Per its own moduledoc, the
DETS conformance test also runs deliberately broken stores through the same
suite and requires each mutant to fail exactly the law it violates — a suite
that cannot refuse is not evidence.

## The standing ladder: run states to evidence rungs

`AshPPlan.Standing.Ladder` (`lib/ash_pplan/standing/ladder.ex`) is the fixed
10-state evidentiary ladder, adopted from `ggen-marketplace/packs/standing-ladder-pack`
(`stl:` ontology, proven in ex4pm):

```
UNKNOWN(0) -> OBSERVED(1) -> VALIDATED(2) -> DERIVED(3) -> CANDIDATE(4)
-> EXPERIMENTALLY_SUPPORTED(5) -> ADMITTED(6) -> MANUFACTURED(7) -> ACTUATED(8)
-> VERIFIED(9)
```

The law (`gates/010_no_skipped_states.rq` in the pack): a claim's current
standing is not self-certifying. It is admissible only through a real,
evidenced, single-rung transition chain reaching it from `:UNKNOWN` — no
skipped rungs, no empty evidence references.

`Ladder.admit/1` enforces that law on a supplied claim — a map with `:fact`,
`:state` and `:transitions` (one `%{from:, to:, evidence:}` per rung). It
refuses a dangling `:fact` (`STL_dangling_fact`), an unknown rung
(`STL_unknown_state`), a chain with a missing rung (`STL_missing_rung`, with
the 1-based `missing_rung_index`), and a malformed claim
(`STL_malformed_claim`). Each transition must be exactly one rung
(`index(to) == index(from) + 1`) with non-empty, specific `:evidence`, and the
chain must start from `:UNKNOWN`. `Ladder.index/1` refuses an unknown state
with the same `STL_unknown_state` term — outside the closed set of 10 this is a
refusal, not a fallback.

`Standing.ladder/1` (`lib/ash_pplan/standing.ex`) is the derivation side: it
maps a run's real inputs to the highest rung it actually reaches, stopping at
the first rung not derivable — no decorative states.

| Rung | Derivable when |
|---|---|
| `UNKNOWN` | the run itself (always) |
| `OBSERVED` | process-evidence events are present |
| `VALIDATED` | the plan layer passes (`plan_correct/1` = `:ok`) |
| `DERIVED` | the execution layer passes (observed == wanted) |
| `CANDIDATE` | named consequence checks are present |
| `EXPERIMENTALLY_SUPPORTED` | the consequence layer passes |
| `ADMITTED` | `standing/1` = `:alive` |
| `MANUFACTURED` | `receipt/2` forms and validates |
| `ACTUATED` | a non-empty observed post-state is recorded (`run[:observation]`) |
| `VERIFIED` | the validated receipt carries the OCEL 2.0 evidence digest |

Each promotion in the returned `trail` is a `%{from:, to:, evidence:, order:}`
map whose `:evidence` is derived from the input that justified the rung, so the
audit trail itself satisfies `Ladder.admit/1`'s no-skipped-rungs law.

## What this is not — the honest edges

- Nothing in `Ladder` grants DO authority; the ladder reads evidence, it never
  manufactures it. There is no automatic promotion authority — deliberately, as
  in the pack.
- `Standing.ladder/1` stops at the first non-derivable rung: the returned
  `state`/`index` is the highest rung the run's real inputs support, not the
  ceiling you wish it reached.
- `Store.Ets` gives no durability; `Store.Dets` gives one-file, one-node
  durability. Neither claims multi-node durability.

Where to go next: the durable-engine tutorial
(`docs/diataxis/tutorials/durable-engine-tutorial.md`) for the lifecycle
narrative; `docs/diataxis/explanation/standing-receipts-and-the-ladder.md` for
the three standing layers and the layer-to-broken-term mapping;
`test/durable/` for the courts.
