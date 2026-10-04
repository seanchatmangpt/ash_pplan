# R4b — State-Transition-Pack Falsifier (delta-ERRC P5)

- Date: 2026-10-04
- Lane: READ-ONLY falsifier (no source edits, no git)
- Subject SHA: `git -C /Users/sac/ash_pplan rev-parse HEAD` = `9a89aac` (working tree carries uncommitted state; file-level citations are against the tree, not the commit)
- Pack: `/Users/sac/ash_pplan/priv/ggen/vendor/state-transition-pack` (v26.9.13)
- Queue rows audited: `lib/HANDWRITTEN.md:171` (status.ex — "state-transition-pack candidate") and `lib/HANDWRITTEN.md:242` (state_machine.ex — "state-transition-pack candidate")

## Method

R4-method: for each queued module, hold the module's actual semantics against the
pack's only Elixir-emitting template class (`templates/fsm.ex.tmpl`) and the
ontology individual schema (`ontology.ttl:90-109`, `st:Machine/State/Transition/
Guard` with `st:inMachine`, `st:seq`, `st:transitionName`, `st:from`, `st:to`,
`st:kind`, `st:guardedBy`/`st:predicateKey`). Verdict scale: GENERABLE /
PARTIAL (named residue) / MISFILED (typed UNSUPPORTED).

## What the template actually emits

`fsm.ex.tmpl` (`priv/ggen/vendor/state-transition-pack/templates/fsm.ex.tmpl`):

- frontmatter `to: src/st_fsm/fsm.ex` (line 2) — one fixed output path.
- Per `st:Machine`: a module `StFsm.{{ m.m }}` with `@states`, `@initial`,
  `@transitions` (`{name, from, to, guard}` 4-tuples, lines 40-47).
- `step/3` — find-by-name-and-from, guard dispatch on `ctx` map (lines 49-55).
- `replay/1` — violation detection over `{name, from, to}` events (lines 57-75).
- `StFsm.Chain` digest module from `st:ChainPolicy`/`st:HashImpl` (lines 20-37).

The template's entire semantic vocabulary is: static rows in, transition table
out, step/replay API. There is no row vocabulary for runtime introspection,
Spark DSL reflection, or consumer-defined predicate helpers.

## Module 1: lib/ash_pplan/state_machine.ex (470 LOC)

**Verdict: MISFILED → typed UNSUPPORTED (generator-capability).**

The module is a runtime adapter over `ash_state_machine`'s Spark/Ash
introspection, not a state machine. Row-by-row falsifier:

- `from_resource/2` (`lib/ash_pplan/state_machine.ex:23`) accepts ANY atom
  resource at runtime and projects its declared lifecycle into a FOND domain.
  The template can only emit a compile-time-fixed `StFsm.<Machine>` module from
  static rows; there is no row vocabulary for "arbitrary resource at runtime".
- `describe_resource/1` (`state_machine.ex:41-84`) derives its data from
  `AshStateMachine.Info.*`, `Ash.Resource.Info.actions/changes/policies/
  preparations` — live framework reflection (lines 44-79). Rows cannot express
  "read the consumer's Spark DSL at runtime".
- The capability descriptor (`state_machine.ex:256-318`) derives booleans from
  action changes (`uses_change?/3`, line 304), policy checks
  (`valid_next_state_policy?/1`, line 313), and preparation inspection
  (`state_always_selected?/1`, line 323). The template's only "capability"
  vocabulary is guard predicates on a ctx map; no overlap.
- Typed-refusal law: 8 function heads returning `{:error, %{reason: ...}}` for
  non-atom resources, unconfigured resources, unknown actions, invalid
  transitions, wildcards (lines 88, 113, 127, 146-150, 194, 350-382, 443-444).
  The template emits no refusal heads at all — its `step/3` returns
  `{:error, {:no_transition, ...}}` values, a different failure vocabulary.
- The one generable slice — `from_transitions/4`'s relation building
  (`state_machine.ex:176-192, 384-468`) for a FIXED resource — is not the
  module. Removing it leaves ~85% of the module as irreducible reflection
  logic.

Pin courts that would fail under any template conversion (they test reflection
behavior, not table data): `test/state_machine_test.exs`,
`test/hardening/state_machine_hardening_test.exs`,
`test/semantic_reality_state_machine_court_test.exs`,
`test/state_machine_charts_test.exs`,
`test/hardening/status_fuzz_test.exs` is NOT among them (that's module 2);
additionally `test/support/state_machine_integration_resource.ex`,
`test/support/oban_integration_resource.ex`,
`test/support/control_plane_integration_resource.ex`,
`test/support/descriptor_fixtures.ex`,
`test/control_plane_test.exs`, `test/frontier_evidence_test.exs`.

**Receipt line for HANDWRITTEN.md (not applied — read-only lane):**
`lib/ash_pplan/state_machine.ex — AshStateMachine → planner data projection |
UNSUPPORTED (generator-capability): state-transition-pack's only Elixir
template (fsm.ex.tmpl) emits compile-time-static StFsm modules (step/replay)
from st:Machine rows; this module is runtime Spark/Ash introspection for an
arbitrary resource (describe_resource/1, capability descriptor from
action changes/policies/preparations, 8 typed-refusal heads) — zero row
vocabulary covers reflection. Reopen if the pack ships a runtime-projection
or DSL-reflection template class (R4b falsifier, 2026-10-04).`

## Module 2: lib/ash_pplan/reactor/durable/status.ex (55 LOC)

(Note: the task named `lib/ash_pplan/standing/status.ex`; that file does not
exist. The actual file is `lib/ash_pplan/reactor/durable/status.ex`, which is
the row queued at `HANDWRITTEN.md:171` as "state-transition-pack candidate".)

**Verdict: PARTIAL — confirmed genuine conversion candidate, but not
GENERABLE without a template extension.** This confirms the delta plan's flag
that it is the smallest genuine provenance win in the queue: it is the only
queued module whose semantics are literally a transition table.

- The core `@allowed` map (`lib/ash_pplan/reactor/durable/status.ex:23-35`) is
  exactly the template's `{name, from, to, guard}` row shape: 9 states
  (`status.ex:18-19`), each from→tos entry expands to one Transition row per
  target; terminal-absorbing (`completed/failed/cancelled` with `to: []`) is
  the natural-language reading of empty target sets; the two documented
  self-transitions (`unwind_blocked→unwind_blocked`, `status.ex:29-31`;
  `pending→pending`, `status.ex:49-51`) are ordinary rows.
- Named residue (why not GENERABLE today):
  1. **API surface mismatch.** The template emits `states/0, initial/0,
     transitions/0, step/3, replay/1` under `StFsm.{{machine}}`
     (`fsm.ex.tmpl:39-76`). Status's 16 call sites across 7 lib files
     (`engine.ex` ×11, `migration.ex`, `ledger_ocel.ex`, `steps/dispatch.ex`
     ×3, `store/{dets,ets}.ex` ×3, `testing.ex` ×2) call `Status.all/0,
     can?/2, terminal?/1, parked?/1, rolling_back?/1, cancellable?/1` — none
     of which the template emits. A byte-diff falsifier cannot pass without
     extending the template (or a generated delegator module
     `AshPPlan.Reactor.Durable.Status` delegating to `StFsm.RunStatus`).
  2. **Type/doc surface**: `@type t :: ...` (`status.ex:7-17`), `@spec`s, and
     the two law-bearing docstrings (`status.ex:29-31, 49-52`) are
     consumer-side surface the template has no rows for.
  3. **Template output path** `to: src/st_fsm/fsm.ex` (`fsm.ex.tmpl:2`) is
     pack-fixed; consumer-side instantiation must override it (or the pack
     ships a per-consumer `to` parameter).
- Guards: not needed — Status has no ctx-conditional transitions; all rows
  would be unguarded.

### Draft conversion (NOT executed — read-only lane)

Since verdict is PARTIAL, not GENERABLE, the following is the *named-residue
conversion sketch*, executable only after the template extension above is
admitted upstream:

1. Ontology rows (added to the consumer's ontology, referencing the pack
   vocabulary `https://ggen.dev/ontology/state-transition#`):

   ```turtle
   st:RunStatusMachine a st:Machine ; st:machineName "RunStatus" ; st:initial st:RunStatusPending .
   # 9 st:State rows: Pending(0) Waiting(1) Polling(2) Unwinding(3) Cancelling(4)
   #   UnwindBlocked(5) Completed(6) Failed(7) Cancelled(8), each
   #   st:inMachine st:RunStatusMachine ; st:stateName "..." ; st:seq N .
   # ~30 st:Transition rows from @allowed (status.ex:23-35), kind "advance";
   #   terminal states emit zero outgoing rows (absorbing);
   #   unwind_blocked→unwind_blocked and pending→pending are self-transition rows.
   ```

2. Template extension (upstream, in fsm.ex.tmpl) — emit consumer predicate
   helpers, e.g. emit `terminal?/1`, `parked?/1` style predicates from a new
   `st:Flag`/`st:predicateName` row class, or (cheaper) generate
   `AshPPlan.Reactor.Durable.Status` as a thin delegator to the generated
   `StFsm.RunStatus` and keep the 5 predicate one-liners as typed handwritten
   residue (~20 LOC, down from 55).

3. Sync invocation (shape, per repo conventions):

   ```sh
   ggen sync --pack state-transition-pack \
     --ontology <consumer-ontology-with-RunStatus-rows>.ttl \
     --template fsm.ex.tmpl --to lib/ash_pplan/reactor/durable/status.ex
   ```

4. Byte-diff falsifier:

   ```sh
   ggen sync ... --check   # or: ggen gen to /tmp/r4b-status.ex && diff -u lib/ash_pplan/reactor/durable/status.ex /tmp/r4b-status.ex
   ```

5. Pinning courts to re-run after conversion: `test/hardening/status_fuzz_test.exs`
   (179 lines, fuzzes `all/terminal?/parked?/rolling_back?/cancellable?/can?`
   over `Status.all() ++ unknown atoms + garbage`), `test/workflow/
   qualified_fulfillment_ecosystem_test.exs`,
   `test/support/examples/qualified_fulfillment/ledger.ex`; lib-side watchers:
   `lib/ash_pplan/reactor/durable/engine.ex` (11 call sites),
   `store/dets.ex`, `store/ets.ex`, `steps/dispatch.ex`, `migration.ex`,
   `ledger_ocel.ex`, `testing.ex`.

## Summary

| module | verdict | residue |
|---|---|---|
| `lib/ash_pplan/state_machine.ex` | MISFILED → UNSUPPORTED (generator-capability) | reflection adapter; only `from_transitions/4` row-expressible for a fixed resource |
| `lib/ash_pplan/reactor/durable/status.ex` | PARTIAL | ~20 LOC of predicate/API surface + template extension upstream; table itself 100% row-expressible |
