# How to schedule P-PLAN work through AshOban

`ash_pplan` does not schedule anything. It gives you a verified SELECT surface over the
resolved AshOban configuration of a resource, a CONSTRUCT-only function that builds the
Oban job changeset, and a classifier for the Oban result. Insertion and execution stay
with Oban through your application's own authorized path. This guide walks that
SELECT → CONSTRUCT → DO sequence for a record trigger.

## Prerequisites

- An Ash resource with the `AshOban` extension and a declared `trigger` (scheduled
  actions are covered in step 1, but cannot be constructed in step 2).
- `ash_oban` and `oban` configured and running in your application. `ash_pplan` does
  not start queues, schedulers, or workers — AshOban/Oban own all of that
  (`lib/ash_pplan/oban.ex:1`).
- The trigger must be declared on the resource you pass in. `construct_trigger/3`
  resolves the trigger through the public DSL (`AshOban.Info.oban_trigger/2`,
  `lib/ash_pplan/oban.ex:295`) and refuses anything else.

## Step 1: Select the trigger target (SELECT)

Inspect the resolved AshOban surface and pick one activation by name. This is
observation only — it grants no execution authority.

```elixir
{:ok, descriptor} = AshPPlan.Oban.describe_resource(MyApp.Support.Ticket)
{:ok, trigger}    = AshPPlan.Oban.fetch_activation(MyApp.Support.Ticket, :process)
```

`describe_resource/1` returns every configured trigger and scheduled action
(`activations/1`), a `capabilities` map, and an `authority` map naming the owner of
each stage (`lib/ash_pplan/oban.ex:29-47`). `fetch_activation/2` refuses unknown
names with `{:error, %{reason: :unknown_ash_oban_activation, ...}}`
(`lib/ash_pplan/oban.ex:77-84`). The same descriptors are reachable as
`AshPPlan.oban/1`, `AshPPlan.oban_activation/2`, `AshPPlan.oban_activations/1`, and
`AshPPlan.oban_capabilities/1` (`lib/ash_pplan.ex:113-123`).

The `capabilities` map classifies what this specific resource's resolved
configuration supports — conditional/temporal activation, retry delivery, actor
persistence, tenant fan-out, shared context, Oban Pro chunking, stable worker/scheduler
identity. These are **classification facts, not execution evidence**:

- They are derived only from activations whose `state` is `:active`; paused or
  deleted activations are visible but contribute no capability
  (`lib/ash_pplan/oban.ex:321-351`).
- Actor persistence and tenant fan-out are resolved the way AshOban resolves them at
  runtime: the trigger value, else `config :ash_oban, :actor_persister`, and the
  `oban` section's `list_tenants` (`lib/ash_pplan/oban.ex:307-319`). A resource-level
  `list_tenants: [nil]` is AshOban's "no tenant" default and is not reported as
  fan-out (`lib/ash_pplan/oban.ex:397-406`).
- `chunk_processing_available?: true` means Oban Pro is installed; it is not a claim
  that any trigger uses chunks. Only `chunk_processing?` (an active trigger with a
  `chunks` configuration) claims that.

Use this step to confirm the trigger is `active?` and configured the way you expect
before constructing anything.

## Step 2: Construct the trigger changeset (CONSTRUCT)

```elixir
{:ok, changeset} = AshPPlan.Oban.construct_trigger(record, :process)
```

`construct_trigger/3` verifies the record is an Ash resource, that the resource has
AshOban, and that the trigger belongs to that resource, then delegates to the public
`AshOban.build_trigger/3` and returns the Oban job changeset without inserting it
(`lib/ash_pplan/oban.ex:199-215`). Keyword options are passed through to
`AshOban.build_trigger/3`.

The changeset has **no delivery standing** until Oban inserts it. The typed refusals
at this boundary (all returned as `{:error, %{reason: ..., ...}}`):

| refusal reason | cause |
|---|---|
| `:not_an_ash_resource` | record is not an Ash resource struct |
| `:ash_oban_not_configured` | resource does not use the AshOban extension |
| `:unknown_ash_oban_trigger` | name (or struct) is not a configured trigger on the resource; scheduled actions are also refused here — cron scheduling is owned by AshOban's generated scheduler, not by job insertion |
| `:foreign_ash_oban_trigger` | trigger struct belongs to a different resource |
| `:invalid_ash_oban_construction` | record is not a struct or opts is not a list |

All five refusals are exercised in `test/oban_test.exs` (`construct_trigger/3
refusals` describe block).

## Step 3: Hand the changeset to your application's DO path (DO)

This step is yours, not `ash_pplan`'s. Insert the changeset the way your application
already authorizes work — typically:

```elixir
{:ok, job} = Oban.insert(MyApp.Oban, changeset)
```

or through an Ash action / wrapper in your domain that performs your own authorization
before calling `Oban.insert/2`. From here, AshOban's generated worker runs the trigger
action; queueing, uniqueness, retries, backoff, and actor/tenant restoration are
resolved by AshOban/Oban at runtime, per their own configuration
(`lib/ash_pplan/oban.ex:359-367` records this ownership split in the descriptor's
`authority` map).

## Step 4: Classify the Oban result (observation)

To fold a worker outcome back into planner-visible state, classify the return —
this is description, never actuation:

```elixir
AshPPlan.Oban.observation(result)
```

Returns a bounded map with `state` in `[:succeeded, :snoozed, :cancelled, :failed,
:unknown]`, plus `terminal?`/`retryable?` facts: `:ok`/`{:ok, value}` succeed,
`{:snooze, seconds_or_period}` snooze, `{:cancel, reason}` cancel, `{:error, error}`
is decoded through `AshOban.check_for_oban_return/1` (`lib/ash_pplan/oban.ex:222-269`).
Malformed snooze periods and unrecognized returns classify as `:unknown` rather than
being invented into a known state (`test/oban_test.exs:179-182`).

## What `ash_pplan` does not do here

Per the repository's SELECT / CONSTRUCT / DO fence and Oban fence
(`AGENTS.md`): it does not create workers or schedulers, insert jobs, run cron,
implement retries or queue semantics, restore actors, or fan out tenants. Every
capability fact it reports is derived from resolved configuration and is
classification/description only — treat `capabilities/1` output as a map of what is
configured, never as proof that a job ran. Execution evidence comes only from your
own Oban/Ash observations.
