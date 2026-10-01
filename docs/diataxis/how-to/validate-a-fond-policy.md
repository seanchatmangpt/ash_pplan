# How to validate a strong / strong-cyclic FOND policy

Goal: you have (or will obtain) a candidate policy — one action per state — and you
want an admitted verdict that it reaches a goal from an initial state under
`:strong` or `:strong_cyclic` semantics, with typed refusals when it does not.

This is validation only. Nothing in this guide executes a Reactor, an Ash action,
or a job. `AshPPlan.FOND` validates policies; it never runs them
(`/Users/sac/ash_pplan/AGENTS.md`, Planning fence).

## Prerequisites

- `ash_pplan` compiled in your project (`mix compile`).
- The modules used below: `AshPPlan.FOND`, `AshPPlan.StateMachine`,
  `AshPPlan.ReactorOutcome`, and optionally `AshPPlan.FOND.Synthesis`.
- A goal state set and an initial state, both drawn from the domain's state
  universe (Step 1).
- A candidate policy, or willingness to synthesize one (Step 2).

## Step 1: Obtain the FOND domain

Pick one of three sources. All return `{:ok, %AshPPlan.FOND{}}` or
`{:error, map()}` with a typed `:reason`.

### From an AshStateMachine resource

```elixir
{:ok, domain} = AshPPlan.StateMachine.from_resource(MyResource, [:goal_state])
```

`from_resource/2` reads the resource's declared transitions through
`AshStateMachine.Info` and never performs a state transition
(`lib/ash_pplan/state_machine.ex`, `from_resource/2` at
`lib/ash_pplan/state_machine.ex:23`). Goals must be declared states; an
undeclared goal is refused with `:unknown_goal_states`
(`lib/ash_pplan/state_machine.ex:346`).

Wildcard caveat: `from_resource/2` passes both the full state set and
AshStateMachine's narrower wildcard-state universe
(`lib/ash_pplan/state_machine.ex:32`). Deprecated states stay valid as explicit
transition endpoints but are excluded from `from: :*` / `to: :*` expansion, so a
deprecated-only state can appear in `domain.states` with no wildcard edges. A
FOND state is a planner state, not automatically an Ash resource state: the
projection never mutates records (`lib/ash_pplan/state_machine.ex:9`).

### From explicit transition data

```elixir
transitions = [
  %{action: :renew, from: [:renewal_pending], to: [:active, :payment_failed]}
]

{:ok, domain} =
  AshPPlan.StateMachine.from_transitions([:active, :renewal_pending, :payment_failed], transitions, [:active])
```

`from_transitions/4` expands `from: :*` / `to: :*` against `wildcard_states`
(defaults to all states) and `action: :*` against concrete `wildcard_actions` —
the latter must be supplied explicitly or the transition is refused with
`:wildcard_action_requires_actions` (`lib/ash_pplan/state_machine.ex:415`,
`test/state_machine_test.exs:57`).

### From a raw transition relation

```elixir
{:ok, domain} =
  AshPPlan.FOND.new(
    %{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}},
    [:succeeded]
  )
```

`FOND.new/2` normalizes the relation and refuses an action with an empty
outcome list as `:empty_nondeterministic_outcome` — an action with no outcome is
never admitted as a vacuous success (`lib/ash_pplan/fond.ex:44`,
`lib/ash_pplan/fond.ex:207`).

## Step 2: Express the candidate policy

A policy is a plain map from non-goal state to one admitted action
(`lib/ash_pplan/fond.ex:17`):

```elixir
policy = %{pending: :attempt}
```

Refusal rules to design against (all typed, from
`lib/ash_pplan/fond.ex:130-178`):

- A policy key naming no domain state is refused: `:unknown_policy_states`.
- A reachable non-goal state with no policy entry: `:missing_policy_action`.
- An action the state does not admit:
  `:unavailable_policy_action` (includes `:available`, the sorted admitted
  actions for that state — use it to fix the entry).

Entries on goal states or on states the policy never reaches cannot change the
verdict; they are reported back in `:ignored_policy_states` rather than refused
(`lib/ash_pplan/fond.ex:181`).

If you have no candidate yet, `AshPPlan.FOND.Synthesis.synthesize/3` returns a
policy that is guaranteed to satisfy `validate_policy/4` for the same arguments
(`lib/ash_pplan/fond/synthesis.ex:64`). Its refusal `{:error, {:unsolvable,
mode, witness_states}}` names the states outside the winning region, always
including `initial` (`lib/ash_pplan/fond/synthesis.ex:39`).

## Step 3: Call the validator

```elixir
case AshPPlan.FOND.validate_policy(domain, policy, :pending, :strong_cyclic) do
  {:ok, report} -> report
  {:error, refusal} -> refusal
end
```

Verified signature: `validate_policy(domain, policy, initial, mode \\ :strong_cyclic)`
returning `{:ok, map()} | {:error, map()}`
(`lib/ash_pplan/fond.ex:130`). `mode` must be `:strong` or `:strong_cyclic`.

Semantics (`lib/ash_pplan/fond.ex:21`):

- `:strong` — every execution reaches a goal without relying on fairness: every
  nondeterministic outcome of every policy step must remain winning.
- `:strong_cyclic` — retry cycles are allowed when every reachable policy state
  still has a path to a goal (the standard fairness assumption).

The same domain/policy can admit under one mode and refuse under the other: the
retry cycle `%{pending: %{attempt: [:pending, :succeeded]}}` is strong-cyclic
but `:not_strong` (`test/fond_test.exs:6`). Cross-check against TLC by rendering
the same arguments with `AshPPlan.FOND.to_tla/5` — render only, authority
`NONE`, ceiling `:construct` (`lib/ash_pplan/fond.ex:148`).

## Step 4: Interpret the result

`{:ok, report}` keys (`lib/ash_pplan/fond.ex:401`,
`lib/ash_pplan/fond.ex:141`):

| key | meaning |
|---|---|
| `:semantics` | the mode checked |
| `:initial` | the initial state checked |
| `:reachable_states` | complete reachable policy state set, sorted |
| `:reachable_count` | its size |
| `:ignored_policy_states` | policy entries that cannot affect any verdict |

`{:error, refusal}` reasons, in the order validation checks them
(`lib/ash_pplan/fond.ex:133-143`):

| reason | field | fix |
|---|---|---|
| `:invalid_domain` | `:detail` (`:undeclared_states` lists the offenders), `:unnormalized_transitions`, `:not_a_fond_domain` | rebuild via `FOND.new/2`; never hand-build the struct |
| `:unknown_initial_state` | `:state` | initial must be in `domain.states` |
| `:unknown_policy_states` | `:states` | typo or atom/string mixup in policy keys |
| `:missing_policy_action` | `:state` | add a decision for that reachable state |
| `:unavailable_policy_action` | `:state`, `:action`, `:available` | use an action from `:available` |
| `:not_strong` | `:losing_states` | some outcome of a policy step leaves the winning region; strengthen the policy or accept `:strong_cyclic` |
| `:not_strong_cyclic` | `:states_without_goal_path` | a reachable closed component cannot reach a goal; reroute it |

BFS order means the first refused state is the one closest to `initial`
(`lib/ash_pplan/fond.ex:250`).

## Optional: feed observed outcomes back as planner inputs

Reactor's own results can be classified into symbolic planner states with
`AshPPlan.ReactorOutcome.state/1` → `:succeeded | :halted | :failed | :unknown`
(`lib/ash_pplan/reactor_outcome.ex:10`). Use these observations to refine which
outcomes you declare for an action in Step 1. Observation is classification
only: `ReactorOutcome` grants no execution authority
(`lib/ash_pplan/reactor_outcome.ex:5`), and observing a Reactor or Oban outcome
never grants DO authority (AGENTS.md, Planning fence).

## Invocation evidence

The call shapes above are the ones exercised by `test/fond_test.exs`,
`test/state_machine_test.exs`, and `test/fond_synthesis_test.exs`. Run them
against your checkout:

```sh
mix test test/fond_test.exs test/state_machine_test.exs test/fond_synthesis_test.exs
```
