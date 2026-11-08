defmodule PowlEngineDemo.Provider do
  @moduledoc false

  @behaviour AshPPlan.Provider

  @impl true
  def id, do: :powl_engine_demo

  @impl true
  def capabilities, do: ["workflow.execute"]

  @impl true
  def properties, do: [:powl_annotated]

  @impl true
  def evidence, do: []
  @impl true
  def cost, do: 1

  # The projected tasks carry descriptive annotations (per-step `powl:*`
  # strings); required-property support is enforced mechanically by
  # `AshPPlan.Providers.Resolver` against `properties/0`, so availability here
  # is: capability declared + authority at or below the :construct ceiling.
  # No DO authority is granted.
  @impl true
  def qualify(%{capability: cap} = requirement, _context) do
    cond do
      cap != "workflow.execute" ->
        {:error, {:unsupported_capability, cap}}

      Map.get(requirement, :authority) not in [nil, :none, :observe, :select, :plan, :construct] ->
        {:error, {:authority_exceeds_ceiling, Map.get(requirement, :authority)}}

      true ->
        :ok
    end
  end

  @impl true
  def realize(%{capability: cap} = requirement, _context) do
    {:ok,
     %AshPPlan.Realization{
       capability: cap,
       provider: id(),
       binding: %{adapter: :powl_engine_demo, op: :workflow_execute},
       options: [],
       properties: requirement |> Map.get(:properties, []) |> List.wrap()
     }}
  end
end

defmodule PowlEngineDemo.Step do
  @moduledoc false

  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options) do
    {:ok, %{ok: true, executed_at: System.system_time(:microsecond)}}
  end
end

defmodule PowlEngineDemo.Adapter do
  @moduledoc false

  @behaviour AshPPlan.Reactor.Adapter

  @table %{workflow_execute: {PowlEngineDemo.Step, []}}

  @impl true
  def id, do: :powl_engine_demo

  @impl true
  def available?, do: true

  @impl true
  def ops, do: Map.keys(@table)

  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end

defmodule PowlEngineDemo do
  @moduledoc """
  Runnable proof for the POWL engine: verify -> project -> compile -> execute,
  mirroring lane Z19's reticle -> verify -> etch -> admit chain on real modules.

  Run: `MIX_BUILD_ROOT=_build-laneT19 mix run examples/powl_engine_demo.exs`
  """

  alias AshPPlan.POWL
  alias AshPPlan.POWL.Node
  alias AshPPlan.POWL.Project
  alias AshPPlan.POWL.Verifier
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Model
  alias AshPPlan.Workflow.Runtime

  @frontier [%{id: :item1, status: :open, deps: []}]

  def main do
    section("STAGE 1 - reticle: build a sound POWL model (sequence of choice + bounded loop)")

    model =
      POWL.sequence("demo_sequence", [
        POWL.activity("receive", "Receive request"),
        POWL.choice("route_choice", [
          POWL.activity("route_a", "Route A"),
          POWL.activity("route_b", "Route B")
        ]),
        bounded_loop("retry_loop", POWL.activity("retry", "Retry"), POWL.activity("redo", "Redo")),
        POWL.activity("finalize", "Finalize")
      ])

    IO.puts("  root: demo_sequence :: sequence (#{length(model.children)} children)")

    section("STAGE 2 - verify: POWL 2.0 separability")
    assert(:ok == Verifier.verify(model), "verifier refuses a sound model")

    IO.puts("  AshPPlan.POWL.Verifier.verify -> :ok (sound)")

    section("STAGE 3 - etch: POWL -> Workflow keyword-form")
    {:ok, %{steps: steps, warnings: warnings}} = Project.to_reactor_steps(model)

    IO.puts("  projected #{length(steps)} steps, #{length(warnings)} warnings:")

    Enum.each(warnings, fn w -> IO.puts("    warning: #{inspect(w)}") end)

    Enum.each(steps, fn s ->
      IO.puts(
        "    step #{inspect(s[:id])} cap=#{s[:capability]} deps=#{inspect(s[:depends_on])}"
      )
    end)

    section("STAGE 4 - admit: Workflow.Model.new/1 compiles the projection")
    compiled =
      case Model.new(name: :powl_engine_demo, tasks: steps) do
        {:ok, %Model{} = m} -> m
        other -> raise_demo("Model.new refused the projection: #{inspect(other)}")
      end
    assert(Model.validate(compiled) == :ok, "compiled model fails validate")

    IO.puts(
      "  Model.new -> {:ok, %Model{}}: #{length(compiled.tasks)} tasks, " <>
        "topology #{inspect(Map.keys(compiled.outcome_topology))}"
    )

    durable_stage(compiled)

    section("STAGE 5 - refusal: unsound PT-handle variant is typed-refused")

    pt_handle =
      POWL.partial_order("pt_handle", [
        POWL.activity("x", "X"),
        POWL.activity("y", "Y"),
        POWL.choice("ch", [POWL.activity("c1", "C1"), POWL.activity("c2", "C2")]),
        POWL.activity("z", "Z")
      ], [{"x", "ch"}, {"y", "ch"}, {"ch", "z"}])

    refusal = Verifier.verify(pt_handle)

    assert(
      match?({:error, %{reason: :non_separable_block}}, refusal),
      "unsound PT-handle variant was not refused"
    )

    IO.puts("  verify -> #{inspect(refusal)}")

    IO.puts(
      "  Project.to_reactor_steps on unsound -> #{inspect(Project.to_reactor_steps(pt_handle))}"
    )

    IO.puts("""

    DEMO COMPLETE: reticle -> verify -> etch -> admit -> execute -> refusal, all real modules.
    """)

    :ok
  end

  # Durable execution stage: real ETS ledger + real Reactor through Runtime.run.
  # Terminal stage only if Runtime.run drives the projected model end to end;
  # any typed refusal here downgrades the terminal stage to compile-success and
  # is disclosed on the transcript (dispatch contract).
  defp durable_stage(compiled) do
    section("STAGE 4b - execute: durable runtime over the projected model")

    # B10's re-annotation workaround is gone: F1 landed the namespaced-
    # annotation qualification law (AshPPlan.Providers.Resolver supported?/2),
    # so the exact projected steps (per-step `powl:*` annotations intact)
    # qualify against the provider without re-annotation.
    #
    # KEPT workaround: `Realization.validate/1` checks the adapter id against
    # the GLOBAL registry (`AshPPlan.Reactor.adapters/0` = built-ins +
    # `config :ash_pplan, :extra_adapters`) at realize time; Runtime.run's
    # `adapters:` option only overrides step_for's table, not this validation.
    # The demo adapter must therefore still be registered via the sanctioned
    # `:extra_adapters` env (same mechanism config/test.exs uses for :ultracode).
    Application.put_env(:ash_pplan, :extra_adapters, %{
      powl_engine_demo: PowlEngineDemo.Adapter
    })

    {:ok, store} = Ets.start_link()

    result =
      Runtime.run(compiled, %{frontier: @frontier},
        providers: [PowlEngineDemo.Provider],
        adapters: %{powl_engine_demo: PowlEngineDemo.Adapter},
        store: store,
        run_id: "powl-demo-1"
      )

    case result do
      {:ok, state} ->
        obs = state.observation
        IO.puts("  Runtime.run -> :ok, observation.state=#{inspect(obs.state)}")

        IO.puts(
          "  observation.transition=#{inspect(Map.get(obs, :transition, nil))} " <>
            "failed_task=#{inspect(Map.get(obs, :failed_task, nil))}"
        )

        case state[:outcome] do
          {:ok, _} ->
            record = Engine.fetch(store, "powl-demo-1")
            checkpoints = Engine.steps(store, "powl-demo-1")

            IO.puts(
              "  ledger: status=#{record.status} checkpoints=#{length(checkpoints)} " <>
                "(#{checkpoints |> Enum.map(& &1.label) |> Enum.sort() |> Enum.join(", ")})"
            )

          other ->
            IO.puts("  outcome: #{inspect(other)}")
        end

        :ok

      {:error, err} ->
        IO.puts("  Runtime.run -> {:error, #{inspect(err)}}")
        IO.puts("  DISCLOSED: durable stage refused; terminal stage is compile-success (STAGE 4).")
        :ok
    end
  end

  defp bounded_loop(id, body, redo) do
    %Node{POWL.loop(id, body, redo) | metadata: %{max_iterations: 3}}
  end

  defp section(title), do: IO.puts("\n== #{title} ==")

  defp assert(true, _what), do: :ok

  defp assert(false, what) do
    IO.puts("DEMO FAILED: #{what}")
    System.halt(1)
  end

  defp raise_demo(msg) do
    IO.puts("DEMO FAILED: #{msg}")
    System.halt(1)
  end
end

case PowlEngineDemo.main() do
  :ok -> System.halt(0)
  other -> IO.puts("unexpected main return: #{inspect(other)}"); System.halt(1)
end
