# ECO-PROVIDER-QUALIFICATION — Root-Cause Report (ZD11 cross-product court, 837 pairs)

**Lane**: read-only diagnosis. **Date**: 2026-10-04.
**Scope**: `CapabilityCatalog.all/0` (31 capabilities) × `AshPPlan.Test.Examples.ProviderIndex.modules/0`
(11 shipped + 16 example providers = 27) = 837 pairs; 4 succeeded, 833 typed-refused, 0 crashes.
Court: `test/workflow/cross_product_e2e_court_test.exs`.

---

## Finding 1 — `properties: [:durable]` refuses 836/837

### Exact chain
1. Example-workflow tasks declare `ap:requiresProperty "durable"` —
   `test/support/examples/ontology/examples.ttl:77,211,288,289,292,307,308` (7 tasks).
2. The workflow template faithfully emits these into generated workflows:
   `priv/ggen/ash-pplan-workflow-pack/templates/workflow.ex.eex:67`
   (`properties: #{inspect(Enum.map(attr.(tprops, id, "property"), to_atom))}`), fed by
   gate `gates/100_task_props.rq` (`?t ap:requiresProperty ?property`).
3. Runtime builds the resolver requirement from the task:
   `lib/ash_pplan/workflow/runtime.ex:176-182` (`requirement(task)` → `properties: Enum.map(task.properties, ...)`)
   and resolves at `runtime.ex:160` via `Registry.resolve` → `Resolver.resolve`.
4. Resolver checks subset: `lib/ash_pplan/providers/resolver.ex:77-83`
   (`check_subset(:properties, requirement, mod.properties())`).
5. Provider surfaces: only 2 of 11 shipped providers declare `:durable` —
   `lib/ash_pplan/providers/durability.ex:15` (`[:checkpointed, :durable, :resumable]`),
   `lib/ash_pplan/providers/durable_dispatch.ex:15` (`[:durable, :resumable]`); every other
   provider declares narrower properties (`file.ex:15` `[:compensable]`, `network.ex:22`
   `[:retryable]`, `domain.ex:21` `[:policy_checked, :transactional]`, `scheduling.ex:13`
   `[:scheduled]`, etc.). In the examples ontology only the dedicated durable providers declare
   it (`examples.ttl:40,58,178,187,196,251,260,278`).
6. `Qualify.check` refuses: `lib/ash_pplan/providers/qualify.ex:35-36`
   (`{:error, {:missing_properties, missing}}`).

### Verdict
**Defect is in the ontology (examples.ttl), not the template or runtime.** The generator,
providers, and qualification semantics are all consistent. `durable` on a task is an
over-requirement: the durable runtime is engaged by passing `store:` to `Runtime.run/2`
(`lib/ash_pplan/workflow/runtime.ex:218`, `225-250`), not by the `:durable` property. The
court's own harness already encodes this correction —
`test/workflow/cross_product_e2e_court_test.exs:65-68` ("the task must not demand properties
(e.g. :durable) that would refuse at qualification before any real execution. The durable
runtime is engaged by passing `store:`, not by this property").

### Lawful fix
Edit the source ontology, not generated artifacts:
- Remove `ap:requiresProperty "durable"` from tasks in
  `test/support/examples/ontology/examples.ttl` (lines 77, 211, 288, 289, 292, 307, 308) whose
  capability does not need an explicitly durable *provider* (all of them per the court's
  rationale), OR add `ap:supportsProperty "durable"` to the corresponding example providers.
- Regenerate: `bin/manufacture-examples` (regenerates example workflows/providers).

---

## Finding 2 — `Durability.Checkpoint` has no qualifying provider

### Exact chain
1. Catalog: `lib/ash_pplan/workflow/capability_catalog.ex:15`
   (`%{id: "Durability.Checkpoint", family: "durability"}`).
2. `Capability.parse/1` accepts it (family `durability` is registered,
   `lib/ash_pplan/capability.ex:9-11,44-52`).
3. Provider exists and declares the capability:
   `lib/ash_pplan/providers/durability.ex:14` (`@capabilities ["Durability.Checkpoint"]`),
   properties/evidence checks pass for an empty requirement (resolver.ex:77-83).
4. Qualification's LAST stage is realizability, not capability match:
   `lib/ash_pplan/providers/resolver.ex:143-161` (`realize_step/7`) calls
   `AshPPlan.Reactor.step_for/1`, which looks up `(adapter, op)` in the adapter registry
   (`lib/ash_pplan/reactor.ex:26,55-56`) via `Reactor.Adapter.resolve`
   (`lib/ash_pplan/reactor/adapter.ex:20-41`). Unknown op →
   `{:error, %{reason: :unsupported, detail: {:unknown_op, op}}}` → candidate rejected with
   `{:unsupported_adapter, ...}` → when no candidate remains, `realize_first/5` returns
   `{:error, %{reason: :no_qualified_provider, rejected: [...]}}` (resolver.ex:137-139).
5. The durability provider binds
   `"Durability.Checkpoint" => {:local, :durability_checkpoint, []}`
   (`lib/ash_pplan/providers/durability.ex:25-27`, generated from pack ontology
   `priv/ggen/ash-pplan-workflow-pack/ontology.ttl:511-517`: `ap:adapter "local" ;
   ap:operation "durability_checkpoint"`).
6. **No adapter implements `durability_checkpoint`.** `Adapters.Local` table
   (`lib/ash_pplan/reactor/adapters/local.ex:7-16`) contains only `event_await`, `state_await`,
   `state_observe`, `actuation_command`, `actuation_actuate`, `distributed_propose`,
   `observation_telemetry`. `Adapters.Durable` table
   (`lib/ash_pplan/reactor/adapters/{durable.ex}:24-32`) contains only `human_approve`,
   `event_await`, `state_await`, `schedule_deferred`, `scheduling_deferred`, `workflow_dispatch`.

### Verdict
**Declared-realizable vs actually-realizable drift**: the pack ontology asserts a realization
the runtime cannot bind. The generation pipeline is faithful; the runtime adapter table
(hand-written, not generated) never grew the op. Same class as Finding 3.

### Lawful fix
Two lawful sources, pick one per doctrine (ontology is source, runtime is projection target —
but adapters are NOT generated, so both edits are lawful):
- **Option A (runtime, additive)**: add `durability_checkpoint: {Steps.…}` to
  `lib/ash_pplan/reactor/adapters/local.ex` (or a durable-engine-backed step). Note: the
  durable engine already checkpoints implicitly per step (park/resume over the store);
  if no explicit step exists, the capability is arguably unrealizable as declared.
- **Option B (ontology, subtractive)**: remove the `Durability.Checkpoint` realization +
  `ap:supportsCapability` from `priv/ggen/ash-pplan-workflow-pack/ontology.ttl:511-517` and
  regenerate (`priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow`) — but this also
  shrinks `CapabilityCatalog` (catalog is generated from the same pack ontology), a **public
  behavior change (breaking)**: capability count gate in the court requires >= 31
  (`cross_product_e2e_court_test.exs:31,84`).

---

## Finding 3 — `Scheduling.Wakeup` refuses against its natural provider

### Exact chain
1. Catalog: `capability_catalog.ex:34` (`"Scheduling.Wakeup"`); family `scheduling` parses.
2. Natural provider declares it: `lib/ash_pplan/providers/scheduling.ex:12`
   (`@capabilities ["Scheduling.Deferred", "Scheduling.Wakeup"]`).
3. Capability/property/evidence checks pass for an empty requirement; the provider binds
   `"Scheduling.Wakeup" => {:local, :scheduling_wakeup, []}`
   (`scheduling.ex:21-24`, generated from pack ontology `ontology.ttl:529`:
   `ap:adapter "local" ; ap:operation "scheduling_wakeup"`).
4. Same failure point as Finding 2: `Reactor.step_for/1` → `Adapters.Local` / `Adapters.Durable`
   tables (local.ex:7-16, durable.ex:24-32) contain **no `scheduling_wakeup` op**. The durable
   analog exists only for Deferred (`scheduling_deferred`, durable.ex:30). Rejected with
   `{:unsupported_adapter, {:unknown_op, :scheduling_wakeup}}` → `no_qualified_provider`.

### Verdict
Same drift class as Finding 2. NOT catalog/provider drift between generated files (the catalog
and provider agree — both generated from pack ontology `ontology.ttl:523-531`); the drift is
**ontology vs runtime adapter coverage**.

### Lawful fix
Add the op to a runtime adapter (additive, non-breaking): e.g.
`scheduling_wakeup: {Steps.Await, [mode: :await]}` (or a durable `Steps.Poll`-based
until-signal binding) in `lib/ash_pplan/reactor/adapters/local.ex` (or `durable.ex`); no
ontology change needed since the ontology's intent (wait/wake semantics) is then honored.
Alternatively, if Wakeup is deferred-scheduling-with-signal, retarget the ontology realization
`ontology.ttl:529` to an existing bound op and regenerate via
`priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow`.

---

## Ranked fixes (capability restored × workflows unblocked ÷ risk)

| Rank | Fix | Restores | Unblocks | Risk | Breaking? |
|---|---|---|---|---| scale |
| 1 | **Remove `ap:requiresProperty "durable"` over-requirement in examples.ttl** (lines 77, 211, 288, 289, 292, 307, 308), regenerate examples | n/a (removes false refusal) | Largest: every example-workflow run + the majority of the 833 refusals in the `properties: [:durable]` variant of the court | Very low — test-support ontology only; runtime semantics unchanged; matches the court harness's own documented rationale | No (test support only) |
| 2 | **Bind `scheduling_wakeup` op** in `lib/ash_pplan/reactor/adapters/local.ex`/`durable.ex` (additive) | `Scheduling.Wakeup` (1 capability) | All workflows/tasks requiring wakeup semantics (schedule-then-notify patterns); Deferred chains that end in a wake | Low — additive table entry; typed-refusal path unchanged; a new step binding is real execution behavior, court-covered | No |
| 3 | **Bind `durability_checkpoint` op** (runtime) or retract the capability (ontology, regenerate) | `Durability.Checkpoint` (1 capability) | Checkpoint workflows; also repairs the "provider exists but never qualifies" incoherence | Medium — needs a decision: an explicit checkpoint step (new behavior) vs retraction (shrinks public catalog below the court's >= 31 gate, breaking) | Option A no; Option B **yes** (catalog shrink) |

None of the three fixes requires hand-editing a generated file. Regeneration commands:
- Shipped providers/catalog: `priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow`
- Examples (workflows/providers/courts from examples.ttl): `bin/manufacture-examples`

## Cross-cutting note (guard candidate)

Findings 2 and 3 are the same defect class: the pack ontology can assert
`ap:Realization (adapter, op)` pairs with no corresponding `AshPPlan.Reactor.Adapters.*.ops/0`
entry, and nothing refuses until runtime resolution. Lawful guard: a court/gate that asserts
`∀ ontology realization (adapter, op) → op ∈ Adapters.adapters()[adapter].ops()` — a
generate-time (verify gate in the pack) or court-time check that turns this drift into a
manufacture-time refusal instead of 833 runtime refusals. This is the
"generate-and-kill court" shaped fix; the existing per-provider courts
(`test/courts/providers/*`) do not cover it because they test single providers in isolation
against their own declared ops.

---

## Execution status (2026-10-04)

**ORDER EXECUTED.** All three diagnosed fixes verified on disk; guard court exists and passes.

### Fix 1 — durable over-requirement: FIXED (examples regen)
`ap:requiresProperty "durable"` removed from the 7 tasks:
`grep -c "requiresProperty" test/support/examples/ontology/examples.ttl` → `0`.
Remaining "durable" hits are `ap:supportsProperty` (provider-side declarations only:
`examples.ttl:40,58,178,187,196,251,260,278`). Generated workflows carry the corrected
properties (e.g. `properties: []` at
`test/support/examples/workflows/qualified_fulfillment.ex:30`).

### Fix 2 — durability_checkpoint: FIXED-AS-DESIGNED (bound on local adapter)
`lib/ash_pplan/reactor/adapters/local.ex:29` —
`durability_checkpoint: {Steps.Await, [probe: {__MODULE__, :continuation, [:continuation]}]}`
(probe at `local.ex:60-68`). Deliberately unbound on `Adapters.Durable`: the durable engine
checkpoints every step output to the ledger per-step (documented in the adapter table comment,
`local.ex:24-28`: "in a durable run the engine checkpoints every step output to the ledger,
so this output IS the checkpoint"). Option A (additive, non-breaking) taken; catalog stays >= 31.

### Fix 3 — scheduling_wakeup: FIXED (bound on BOTH adapters)
- Local: `lib/ash_pplan/reactor/adapters/local.ex:23` —
  `scheduling_wakeup: {Steps.Await, [probe: {__MODULE__, :wake_due, [:wake_at]}]}` (clock-gated
  await over the injectable `Durable.Clock`, probe at `local.ex:45-54`).
- Durable: `lib/ash_pplan/reactor/adapters/durable.ex:35-37` —
  `scheduling_wakeup: {Steps.Poll, [until: {__MODULE__, :clock_reached, [:wake_at]}, every: 1_000]}`
  (`clock_reached` at `durable.ex:63`), same parking machinery as `scheduling_deferred`.

### Guard court — exists and passes
`test/courts/realization_adapter_court_test.exs` (88 lines, 4 tests): ontology-pairs ->
adapter-table coverage sweep, anti-vacuity typed-`unknown_op` assertions, and the two
historically drifting pairs (`local`/`durability_checkpoint`, `local`/`scheduling_wakeup`)
resolved end-to-end via `Reactor.step_for/1` (court line 77).
Run: `MIX_BUILD_ROOT=_build-ecoq mix test test/courts/realization_adapter_court_test.exs` →
`4 tests, 0 failures` (0.4s). Lane build root `_build-ecoq` deleted after the run.
