# Serve a run to a remote A2A agent with `AshPPlan.A2A.Facade`

`AshPPlan.A2A.Facade` (`lib/ash_pplan/a2a/facade.ex`) is the A2A-provider
surface over the durable engine: the seams a remote-agent consumer binds,
exposed natively so no consumer re-derives them. The in-tree consumer is
`AshA2A.Providers.PPlan`, which binds exactly these primitives and maps
run lifecycle onto A2A task states; the facade owns that mapping on the
ash_pplan side (`lib/ash_pplan/a2a/facade.ex:6-11`).

Every entry point returns `{:ok, a2a_state, detail}` or a typed
`{:error, reason}`, with `a2a_state` one of `:submitted`, `:working`,
`:input_required`, `:completed`, `:failed`, `:canceled`
(`facade.ex:26-31`).

## Start or adopt a run

`start_or_adopt/5` (`facade.ex:157-172`) starts a durable run keyed by the
consumer's external task id and attempts it once:

```elixir
{:ok, state, detail} =
  AshPPlan.A2A.Facade.start_or_adopt(store, "ext-task-42", model, bindings,
    inputs: %{"query" => q},
    store_module: MyStore
  )
```

* `key` doubles as the durable run id and is **idempotent**: an existing run
  is adopted unchanged (the store returns `{:error, :exists}` and the engine
  hands back the existing record) — `facade.ex:157-161`. Re-dispatch never
  duplicates an execution.
* `model` is an `AshPPlan.Workflow.Model`; the facade does not invent plans.
  `bindings` must realize every model task or the projector refuses.
* `:inputs` are wrapped as `%{input: inputs}` (`facade.ex:338-339`); optional
  `:context`, `:plan_iri`, `:intent`, `:claimer`, `:lease_ms` are passed
  through (`facade.ex:159-168`).
* Because adoption returns the run unchanged, a follow-up payload reaches a
  plan **only** via `resume/4` — never by re-dispatch with new inputs
  (`facade.ex:40-43`).

## Resume a parked run with a signal

`resume/4` (`facade.ex:213-228`) delivers a follow-up payload as a
consume-once signal and attempts once:

```elixir
{:ok, :completed, result} = AshPPlan.A2A.Facade.resume(store, "ext-task-42", payload)
```

* The signal name is the `:signal` opt or, unset, the name of the run's
  parked signal waiter — the payload lands on the Await step that actually
  parked (`facade.ex:203-209`).
* A terminal run accepts no signal; its sealed state is returned unchanged.
* Typed refusals: `{:error, :no_signal_waiter}` when nothing is parked,
  `{:error, {:ambiguous_waiters, names}}` when more than one signal waiter is
  parked — never a guessed broadcast (`facade.ex:319-334`).
* `signal/5` delivers by explicit name without attempting (`facade.ex:275-276`).

## Read the nine-status mapping

ash_pplan's closed run-status set (`AshPPlan.Reactor.Durable.Status.all/0`)
maps to A2A task states via `to_state/1` (`facade.ex:107-117`):

| ash_pplan run status     | A2A task state     |
|--------------------------|--------------------|
| `:pending`               | `:submitted`       |
| `:waiting`               | `:input_required`  |
| `:polling`               | `:working`         |
| `:unwinding`             | `:working`         |
| `:cancelling`            | `:working`         |
| `:unwind_blocked`        | `:working`         |
| `:completed`             | `:completed`       |
| `:failed`                | `:failed`          |
| `:cancelled`             | `:canceled`        |

`to_state/1` is total over `Status.all/0`; anything outside the closed set
refuses typed as `{:error, {:unmapped_status, atom}}` — never a silent
default (`facade.ex:82-84, 117`).

Named gaps (`facade.ex:33-46`):

* `:input_required` is the parked status `:waiting` (a signal waiter);
  ash_pplan has no first-class input-required status and the facade maps
  rather than adds one. A plan without an Await step can never park that way.
* A deadline-parked run (`:polling`) reports `:working`, not
  `:input_required` — the facade would otherwise lie about who must act next.
* A2A `:auth_required` / `:rejected` have no counterpart and are never
  produced; read `status/3`'s detail map for the underlying run status.

## The rest of the surface

* `attempt/3` — one claimed attempt mapped to an A2A state; `:taken` yields
  `{:ok, :working, :claim_held}` (`facade.ex:185-198`).
* `status/3` — read-only state plus detail (run status, result, error,
  version, parked waiter names) (`facade.ex:236-252`).
* `cancel/3` — claim-CAS cancel from `:pending`/`:waiting`/`:polling`,
  propagating to non-terminal children; a non-cancellable run returns its
  current state instead of an error (`facade.ex:263-270`).
* `fetch/4` / `waiters/3` — raw record and parked signal-waiter names
  (`facade.ex:279-304`).

## Falsifiers

The facade's own falsifier list (`facade.ex:48-60`, courts
`test/a2a_facade_test.exs`): double execution on repeated
`start_or_adopt/5`, a `resume/4` that consumes more or less than one signal
or moves a terminal state, a deadline-parked run reported
`:input_required`, or `to_state/1` mapping an unknown atom instead of
refusing typed.
