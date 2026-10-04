defmodule AshPPlan.Courts.SemanticCompilerCourtTest do
  @moduledoc """
  Court for v26.10.1 contract items 4-6 (README.md):

    4. `AshPPlan.Compiler` validates admitted topology *before* building a Reactor.
    5. Executable behavior is bound by semantic step IRI to existing `Reactor.Step`
       implementations.
    6. P-PLAN precedence becomes Reactor result dependencies; Reactor stays the
       scheduler/executor.

  Chicago style: every test compiles and/or runs the real compiler against real
  `Reactor.Step` implementations. Refusals are asserted as typed
  `AshPPlan.Compiler.Error` values whose details name the offending structure
  (anti-vacuity: the reason must carry the exact step/edge that caused it).
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler

  defmodule RecordingStep do
    @moduledoc "Real Reactor step: records execution order and returns its step IRI."
    use Reactor.Step

    @impl true
    def run(arguments, context, _options) do
      Agent.update(arguments.input.recorder, &[context.ash_pplan.step_iri | &1])
      {:ok, context.ash_pplan.step_iri}
    end
  end

  defmodule ArithmeticStep do
    @moduledoc """
    Real Reactor step whose result genuinely depends on predecessor results,
    proving result-dependency flow (item 6), not just ordering.
    """
    use Reactor.Step

    @impl true
    def run(arguments, context, options) do
      n = Keyword.get(options, :n, Map.get(arguments.input, :n, 0))
      %{predecessor_arguments: pred_args} = context.ash_pplan

      incoming =
        pred_args
        |> Map.values()
        |> Enum.map(&Map.fetch!(arguments, &1))
        |> Enum.sum()

      {:ok, n + incoming}
    end
  end

  setup do
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(recorder), do: Agent.stop(recorder) end)
    %{recorder: recorder}
  end

  # ---------------------------------------------------------------------------
  # Item 4: validate first, then build
  # ---------------------------------------------------------------------------

  describe "item 4: topology is validated before a Reactor is built" do
    test "a cyclic topology is refused with a typed error naming the cycle members" do
      plan = %{
        iri: "urn:plan:cycle",
        steps: [
          step("urn:step:a", ["urn:step:c"]),
          step("urn:step:b", ["urn:step:a"]),
          step("urn:step:c", ["urn:step:b"])
        ]
      }

      assert {:error, %AshPPlan.Compiler.Error{} = error} =
               Compiler.compile_spec(plan, handlers(plan))

      assert error.reason == :cyclic_plan

      # Anti-vacuity: the refusal names exactly the offending structure.
      assert error.details.steps == ["urn:step:a", "urn:step:b", "urn:step:c"]
      refute Exception.message(error) == ""
    end

    test "a self-loop is refused as cyclic" do
      plan = %{iri: "urn:plan:self", steps: [step("urn:step:a", ["urn:step:a"])]}

      assert {:error, %AshPPlan.Compiler.Error{reason: :cyclic_plan, details: %{steps: steps}}} =
               Compiler.compile_spec(plan, handlers(plan))

      assert steps == ["urn:step:a"]
    end

    test "a dangling predecessor edge is refused with the edge itself in the details" do
      plan = %{
        iri: "urn:plan:dangling",
        steps: [step("urn:step:a", ["urn:step:ghost"])]
      }

      assert {:error, %AshPPlan.Compiler.Error{} = error} =
               Compiler.compile_spec(plan, handlers(plan))

      assert error.reason == :dangling_predecessors
      assert error.details.edges == [{"urn:step:a", "urn:step:ghost"}]
    end

    test "duplicate step IRIs are refused, naming the duplicated IRI" do
      plan = %{
        iri: "urn:plan:duplicate",
        steps: [step("urn:step:a"), step("urn:step:a")]
      }

      assert {:error,
              %AshPPlan.Compiler.Error{reason: :duplicate_steps, details: %{steps: steps}}} =
               Compiler.compile_spec(plan, handlers(plan))

      assert steps == ["urn:step:a"]
    end

    test "a step whose IRI-bound behavior is not a loaded Reactor.Step is refused" do
      plan = %{iri: "urn:plan:bad-handler", steps: [step("urn:step:a")]}

      assert {:error,
              %AshPPlan.Compiler.Error{reason: :invalid_handlers, details: %{steps: steps}}} =
               Compiler.compile_spec(plan, %{"urn:step:a" => NotAModule})

      assert steps == ["urn:step:a"]
    end

    test "a step with no bound behavior at all is refused, naming the IRI" do
      plan = %{iri: "urn:plan:no-handler", steps: [step("urn:step:a"), step("urn:step:b")]}

      assert {:error,
              %AshPPlan.Compiler.Error{reason: :missing_handlers, details: %{steps: missing}}} =
               Compiler.compile_spec(plan, %{"urn:step:a" => RecordingStep})

      assert missing == ["urn:step:b"]
    end

    test "an empty plan is refused rather than compiled into a degenerate Reactor" do
      assert {:error, %AshPPlan.Compiler.Error{reason: :empty_plan}} =
               Compiler.compile_spec(%{iri: "urn:plan:empty", steps: []}, %{})
    end

    test "validation precedes building: no reactor is returned on refusal" do
      # Cycle + valid handler: the compiler must stop at validation and never
      # hand back a half-built Reactor.
      plan = %{
        iri: "urn:plan:cycle-valid-handlers",
        steps: [step("urn:step:a", ["urn:step:b"]), step("urn:step:b", ["urn:step:a"])]
      }

      assert {:error, %AshPPlan.Compiler.Error{reason: :cyclic_plan}} =
               Compiler.compile_spec(plan, handlers(plan))
    end
  end

  # ---------------------------------------------------------------------------
  # Items 5 + 6: IRI-bound real behavior, real execution, precedence ordering
  # ---------------------------------------------------------------------------

  describe "items 5+6: valid plans compile into a Reactor that really runs" do
    test "a linear chain executes in precedence order through the bound steps", %{
      recorder: recorder
    } do
      plan = %{
        iri: "urn:plan:chain",
        steps: [
          step("urn:step:first"),
          step("urn:step:second", ["urn:step:first"]),
          step("urn:step:third", ["urn:step:second"])
        ]
      }

      assert {:ok, reactor} = Compiler.compile_spec(plan, handlers(plan))

      assert {:ok, "urn:step:third"} = Reactor.run(reactor, %{input: %{recorder: recorder}})

      order = recorder |> Agent.get(& &1) |> Enum.reverse()
      assert order == ["urn:step:first", "urn:step:second", "urn:step:third"]
    end

    test "a diamond topology honours every precedence edge at runtime", %{recorder: recorder} do
      plan = %{
        iri: "urn:plan:diamond",
        steps: [
          step("urn:step:root"),
          step("urn:step:left", ["urn:step:root"]),
          step("urn:step:right", ["urn:step:root"]),
          step("urn:step:sink", ["urn:step:left", "urn:step:right"])
        ]
      }

      assert {:ok, reactor} = Compiler.compile_spec(plan, handlers(plan))
      assert {:ok, "urn:step:sink"} = Reactor.run(reactor, %{input: %{recorder: recorder}})

      order = recorder |> Agent.get(& &1) |> Enum.reverse()
      assert length(order) == 4
      assert before?(order, "urn:step:root", "urn:step:left")
      assert before?(order, "urn:step:root", "urn:step:right")
      assert before?(order, "urn:step:left", "urn:step:sink")
      assert before?(order, "urn:step:right", "urn:step:sink")
    end

    test "precedence is a real data dependency: a step sums its predecessors' results" do
      plan = %{
        iri: "urn:plan:sum",
        steps: [
          step("urn:step:a"),
          step("urn:step:b"),
          step("urn:step:c", ["urn:step:a", "urn:step:b"])
        ]
      }

      handlers = %{
        "urn:step:a" => {ArithmeticStep, n: 1},
        "urn:step:b" => {ArithmeticStep, n: 10},
        "urn:step:c" => {ArithmeticStep, n: 100}
      }

      assert {:ok, reactor} = Compiler.compile_spec(plan, handlers)
      # a=1, b=10, c=100 + (1 + 10) = 111. If precedence were only a wait-for
      # edge with dropped arguments, c could not compute 111.
      assert {:ok, 111} = Reactor.run(reactor, %{input: %{n: 0}})
    end

    test "a compiled plan survives inspection: steps are bound by IRI to real modules" do
      plan = %{iri: "urn:plan:inspect", steps: [step("urn:step:only")]}

      assert {:ok, reactor} = Compiler.compile_spec(plan, %{"urn:step:only" => RecordingStep})

      assert %Reactor{} = reactor
      step = Enum.find(reactor.steps, &(&1.name == "urn:step:only"))
      assert %Reactor.Step{} = step
      assert step.impl == RecordingStep
      assert step.context.ash_pplan.step_iri == "urn:step:only"
    end

    test "independent terminals are collected through the return collector", %{recorder: recorder} do
      plan = %{
        iri: "urn:plan:fan-out",
        steps: [
          step("urn:step:root"),
          step("urn:step:left", ["urn:step:root"]),
          step("urn:step:right", ["urn:step:root"])
        ]
      }

      assert {:ok, reactor} = Compiler.compile_spec(plan, handlers(plan))

      assert {:ok, %{"urn:step:left" => "urn:step:left", "urn:step:right" => "urn:step:right"}} =
               Reactor.run(reactor, %{input: %{recorder: recorder}})
    end
  end

  defp before?(order, a, b),
    do: Enum.find_index(order, &(&1 == a)) < Enum.find_index(order, &(&1 == b))

  defp handlers(%{steps: steps}), do: Map.new(steps, &{&1.iri, RecordingStep})

  defp step(iri, predecessors \\ []) do
    %{iri: iri, label: iri, predecessors: predecessors, inputs: [], outputs: []}
  end
end
