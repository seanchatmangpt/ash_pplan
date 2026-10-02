# Chicago TDD Tools Pack — Adoption into ash_pplan (lane X4)

Source pack: `~/ggen-marketplace/packs/chicago-tdd-tools-pack` (v0.5.0; shape:
`ctt:` ontology + `run_boundary_spec` dispatch + 5-individual negative-witness
suite). 2026-10-01.

## What the pack provides

The pack's negative-witness pattern, from its ontology (`ontology.ttl`,
`ctt:` negative-witness suite section) and `pack.toml` description:

1. One reusable, real dispatch function (`run_boundary_spec`) — every test
   dispatches through it instead of duplicating spawn-and-assert logic.
2. Negative witnesses as REAL broken implementations or REAL corrupted inputs
   (stderrNeedle transcribed from live runs, not invented) — never mocks.
3. Assert the DETECTION, not the sabotage: every negative-witness individual
   pins an axiom of the form "X fails closed via enforcement Y".

## What was adopted

- **The three-part pattern above**, as `AshPPlan.Test.Chicago`
  (`test/support/chicago/chicago.ex`):
  - `sabotage_source!/3` — in-process analogue of the pack's CliHarness:
    read the real production source, apply mechanical breaks (each needle
    asserted to still match, so a refactored source fails loudly), rename the
    `defmodule`, compile in-process. No mocks; the mutant is a real
    compilable implementation.
  - `assert_detected!/4` — `BoundarySpec`-shaped assertion: one property run
    against the real subject (must pass) and every sabotage (must FAIL);
    returns `:detected` as the receipt.

## Surfaces chosen (gap analysis) and what was already covered

Already covered (not duplicated — verified by reading, 2026-10-01):

- `Migration.classify`, `Counterfactual.do_replay`, `PolicyDriver.admit`
  mutations (`test/durable/mutations/`, README table).
- Standing falsifier mutation (`test/workflow/standing_falsifier_mutation_test.exs`).
- Store conformance mutants (hand-written `Store` mutants vs the generated
  `AshPPlan.Test.StoreConformance` laws,
  `test/durable/store_conformance_dets_test.exs`'s
  `StoreConformanceAntiVacuityTest`).
- `manufacture_test.exs` regeneration: script-level hand-edit mutation court
  (`bin/manufacture-*` refusal/regenerate behavior on a real hand edit).

Gaps targeted (top 3 un-falsified surfaces):

1. **`Engine.wake/3` label honesty** — no court asserted `wake` returns
   `:ended` for a terminal run, `:not_found` for an unknown run, or that a
   `:waiting` run with an unconsumed signal wakes to `:pending` as a
   module-dispatched property. Sabotage: the terminal cond clause disabled.
2. **`Store.Dets`** — no court proved (a) a genuinely corrupted DETS file
   fails closed at start (`{:error, {:dets_open_failed, _}}`), (b) persistence
   across a real untrappable kill + restart on the same path, (c) claim CAS
   exclusivity via a real mutated Dets source (claim never refuses). (c) is
   the DETS-side analogue of the Ets-side conformance mutants.
3. **Regeneration court's detection path at recipe level** — the manufacture
   mutation exercises the `bin/manufacture-*` scripts; nothing proved the
   `ggen_igniter.sync` + byte-comparison the courts rely on fires on a
   hand-edited template at the recipe itself (`projection_catalog.ex.eex`).
   Test: honest sync == checked-in (control), sabotaged template sync !=
   checked-in (detection).

## Test files

- `test/support/chicago/chicago.ex` — helpers (sabotage compiler, detection
  assertion).
- `test/chicago_adoption_test.exs` — 5 tests, all green under
  `MIX_BUILD_ROOT=_build-x4 mix test test/chicago_adoption_test.exs` (5 tests, 0 failures).
