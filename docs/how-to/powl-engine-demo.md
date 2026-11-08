# POWL Engine Demo

Standing: PASS — `MIX_BUILD_ROOT=_build-laneB10 mix run examples/powl_engine_demo.exs` exit 0,
full pipeline execute + typed refusal witnessed 2026-11-07.

The ash_pplan-side runnable proof mirroring lane Z19:
reticle → verify → etch → admit → execute → refusal, one script, real modules.

## Prerequisites

- Elixir/Erlang (OTP) with `mix` on PATH
- Dependencies fetched once (`mix deps.get`)

## Run

```sh
MIX_BUILD_ROOT=_build-laneB10 mix run examples/powl_engine_demo.exs
```

`MIX_BUILD_ROOT` isolates the lane/demo build root; any writable root name works.

## Expected transcript (stages)

1. **Reticle** — builds a sound POWL 2.0 model with `AshPPlan.POWL`:
   a sequence of activity → choice → bounded loop → activity.
2. **Verify** — `AshPPlan.POWL.Verifier.verify/1` returns `:ok`
   (Algorithm-3-class separability: MG leaves, MG chain, SM block, bounded MG cycle).
3. **Etch** — `AshPPlan.POWL.Project.to_reactor_steps/1` projects 6 steps +
   a typed warning ledger (uncompensable activities, choice discriminator,
   loop-as-bounded-retry).
4. **Admit** — `AshPPlan.Workflow.Model.new/1` compiles the projection
   (6 tasks, `Model.validate == :ok`, outcome topology present).
5. **Execute** — `AshPPlan.Workflow.Runtime.run/3` over the real durable engine
   (`Store.Ets` + `Engine`): `observation.state == :succeeded`, ledger
   `status == :completed` with 6 step checkpoints (per-task step IRIs).
6. **Refusal** — an unsound PT-handle variant (a choice interior to a partial
   order with two incomparable in-flows) is typed-refused by the verifier and
   projected by nothing: `{:error, %{reason: :non_separable_block, block: %{cause:
   :pt_handle_choice_interior, ...}}}`.

## What each stage proves

| Stage | Claim proven |
|-------|--------------|
| Reticle | POWL AST builders (`POWL.sequence/choice/loop/activity`) compose |
| Verify | Sound models verify `:ok`; the recursion closes without a residual block |
| Etch | Projection to `Workflow.Model.new/1` keyword-form with honest warning ledger |
| Admit | The projection is structurally valid, acyclic, terminal-checked |
| Execute | The compiled model runs on the real durable runtime (ETS ledger) end to end |
| Refusal | Unsound models get typed refusals, never silent projection |

## Demo-local provider/adapter

The demo ships its own provider + adapter (real collaborators, no mocks):
`PowlEngineDemo.Provider` realizes `workflow.execute`; `PowlEngineDemo.Adapter`
maps `:workflow_execute` to a real `Reactor.Step`. The adapter is registered via
the sanctioned `:extra_adapters` application-env seam (the same mechanism
`config/test.exs` uses for `:ultracode`).

## Known seam (defect ledger B10-D1)

`AshPPlan.Providers.Resolver` intersects each task's required properties with the
provider's STATIC `properties/0`. The POWL projection annotates every step with
per-step `powl:*` string annotations (`powl:id=receive`, ...), which no static
provider list can contain — a `workflow.execute` task with its projection intact
cannot qualify under any generated provider. Until that seam lands, the demo's
runtime stage re-annotates tasks with the provider-declared atom property; the
compile stage keeps the exact projected steps untouched.

## See Also

- `examples/powl_engine_demo.exs`
- `lib/ash_pplan/powl/verifier.ex`
- `lib/ash_pplan/powl/project.ex`
- `test/workflow/durable_runtime_test.exs`
