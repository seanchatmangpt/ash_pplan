defmodule AshPPlan.PrecedenceTest do
  @moduledoc """
  Proves `p-plan:isPrecededBy` really becomes a Reactor result dependency for
  topologies the manufactured fixture does not contain.

  The catalog fixture is a single linear chain, so a step with more than one
  predecessor — and a step that several steps depend on — is only covered here.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler

  defmodule RecordingStep do
    use Reactor.Step

    @impl true
    def run(arguments, context, _options) do
      Agent.update(arguments.input.recorder, &[context.ash_pplan.step_iri | &1])
      {:ok, context.ash_pplan.step_iri}
    end
  end

  defmodule ReportPredecessorsStep do
    use Reactor.Step

    @impl true
    def run(arguments, context, _options) do
      {:ok, AshPPlan.predecessor_results(arguments, context)}
    end
  end

  setup do
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(recorder), do: Agent.stop(recorder) end)
    %{recorder: recorder}
  end

  test "a diamond topology honours every precedence edge", %{recorder: recorder} do
    # a -> {b, c} -> d
    plan = %{
      iri: "urn:plan:diamond",
      steps: [
        step("urn:step:a"),
        step("urn:step:b", ["urn:step:a"]),
        step("urn:step:c", ["urn:step:a"]),
        step("urn:step:d", ["urn:step:b", "urn:step:c"])
      ]
    }

    assert {:ok, reactor} = Compiler.compile_spec(plan, handlers(plan))
    assert {:ok, "urn:step:d"} = Reactor.run(reactor, %{input: %{recorder: recorder}})

    order = recorder |> Agent.get(& &1) |> Enum.reverse()

    assert length(order) == 4
    assert index(order, "urn:step:a") < index(order, "urn:step:b")
    assert index(order, "urn:step:a") < index(order, "urn:step:c")
    assert index(order, "urn:step:b") < index(order, "urn:step:d")

    # The second predecessor is the one a single dependency argument would
    # silently drop, so it is asserted explicitly.
    assert index(order, "urn:step:c") < index(order, "urn:step:d")
  end

  test "a repeated predecessor is deduplicated rather than double-counted", %{
    recorder: recorder
  } do
    plan = %{
      iri: "urn:plan:repeat",
      steps: [
        step("urn:step:a"),
        step("urn:step:b", ["urn:step:a", "urn:step:a"])
      ]
    }

    assert {:ok, reactor} = Compiler.compile_spec(plan, handlers(plan))
    assert {:ok, "urn:step:b"} = Reactor.run(reactor, %{input: %{recorder: recorder}})
    assert recorder |> Agent.get(& &1) |> Enum.reverse() == ["urn:step:a", "urn:step:b"]
  end

  test "independent terminals are all collected", %{recorder: recorder} do
    plan = %{
      iri: "urn:plan:fan",
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

  test "a step observes its predecessors' results, keyed by predecessor IRI", %{
    recorder: recorder
  } do
    plan = %{
      iri: "urn:plan:results",
      steps: [
        step("urn:step:a"),
        step("urn:step:b"),
        step("urn:step:c", ["urn:step:a", "urn:step:b"])
      ]
    }

    handlers = %{
      "urn:step:a" => RecordingStep,
      "urn:step:b" => RecordingStep,
      "urn:step:c" => ReportPredecessorsStep
    }

    assert {:ok, reactor} = Compiler.compile_spec(plan, handlers)

    assert {:ok, observed} =
             Reactor.run(reactor, %{input: %{recorder: recorder, test_pid: self()}})

    assert observed == %{"urn:step:a" => "urn:step:a", "urn:step:b" => "urn:step:b"}
  end

  test "a step with no predecessors observes an empty predecessor map", %{recorder: recorder} do
    plan = %{iri: "urn:plan:root-only", steps: [step("urn:step:only")]}

    assert {:ok, reactor} =
             Compiler.compile_spec(plan, %{"urn:step:only" => ReportPredecessorsStep})

    assert {:ok, %{}} = Reactor.run(reactor, %{input: %{recorder: recorder, test_pid: self()}})
  end

  test "predecessor fan-in is bounded and refused past the bound" do
    admitted = fan_in(16)
    assert {:ok, _reactor} = Compiler.compile_spec(admitted, handlers(admitted))

    refused = fan_in(17)

    assert {:error,
            %AshPPlan.Compiler.Error{
              reason: :too_many_predecessors,
              details: %{step: "urn:step:sink", count: 17, maximum: 16}
            }} = Compiler.compile_spec(refused, handlers(refused))
  end

  defp fan_in(count) do
    sources = Enum.map(1..count, &"urn:step:source-#{&1}")

    %{
      iri: "urn:plan:fan-in-#{count}",
      steps: Enum.map(sources, &step/1) ++ [step("urn:step:sink", sources)]
    }
  end

  defp index(order, iri), do: Enum.find_index(order, &(&1 == iri))

  defp handlers(%{steps: steps}), do: Map.new(steps, &{&1.iri, RecordingStep})

  defp step(iri, predecessors \\ []) do
    %{iri: iri, label: iri, predecessors: predecessors, inputs: [], outputs: []}
  end
end
