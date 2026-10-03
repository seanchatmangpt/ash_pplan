defmodule AshPPlan.Hardening.CompilerObanHardeningTest do
  @moduledoc """
  HARDEN-lane falsifiers for the compiler and Oban control-plane surfaces.

  Every test drives the public boundary with malformed input and asserts a
  typed refusal (or an admitted, bounded result) — never a raise, hang, or
  untyped crash. Cycle detection is proven on the exact shapes that could
  loop an unguarded topological walk.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error
  alias AshPPlan.Oban

  defmodule NoopStep do
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :noop}
  end

  defp step(iri, predecessors \\ []) do
    %{iri: iri, label: iri, predecessors: predecessors, inputs: [], outputs: []}
  end

  defp handlers(%{steps: steps}), do: Map.new(steps, &{&1.iri, NoopStep})

  # ---------------------------------------------------------------------------
  # Malformed plan IR
  # ---------------------------------------------------------------------------

  test "a two-step predecessor cycle refuses as cyclic_plan instead of looping" do
    plan = %{
      iri: "urn:plan:cycle-2",
      steps: [
        step("urn:step:a", ["urn:step:b"]),
        step("urn:step:b", ["urn:step:a"])
      ]
    }

    assert {:error, %Error{reason: :cyclic_plan, details: %{steps: ["urn:step:a", "urn:step:b"]}}} =
             Compiler.compile_spec(plan, handlers(plan))
  end

  test "a self-loop predecessor refuses as cyclic_plan instead of looping" do
    plan = %{iri: "urn:plan:self-loop", steps: [step("urn:step:a", ["urn:step:a"])]}

    assert {:error, %Error{reason: :cyclic_plan, details: %{steps: ["urn:step:a"]}}} =
             Compiler.compile_spec(plan, handlers(plan))
  end

  test "a larger cycle mixed with reachable steps still refuses every cycle member" do
    plan = %{
      iri: "urn:plan:cycle-mixed",
      steps: [
        step("urn:step:root"),
        step("urn:step:mid", ["urn:step:root"]),
        step("urn:step:x", ["urn:step:y"]),
        step("urn:step:y", ["urn:step:z"]),
        step("urn:step:z", ["urn:step:x"])
      ]
    }

    assert {:error, %Error{reason: :cyclic_plan, details: %{steps: cycle}}} =
             Compiler.compile_spec(plan, handlers(plan))

    assert Enum.sort(cycle) == ["urn:step:x", "urn:step:y", "urn:step:z"]
  end

  test "cyclic refusal terminates under an adversarial timeout" do
    plan = %{
      iri: "urn:plan:cycle-timeout",
      steps: [
        step("urn:step:a", ["urn:step:b"]),
        step("urn:step:b", ["urn:step:a"])
      ]
    }

    task = Task.async(fn -> Compiler.compile_spec(plan, handlers(plan)) end)

    assert {:error, %Error{reason: :cyclic_plan}} = Task.await(task, 2_000)
  end

  test "refuses a step with an empty-string IRI" do
    plan = %{iri: "urn:plan:empty-iri", steps: [step("")]}

    assert {:error, %Error{reason: :invalid_step_spec}} =
             Compiler.compile_spec(plan, %{"" => NoopStep})
  end

  test "refuses a step body that is not a map with the four required keys" do
    for bad <- [nil, :atom, "string", 42, [], %{iri: "urn:step:only-iri"}] do
      plan = %{iri: "urn:plan:bad-body", steps: [bad]}

      assert {:error, %Error{reason: :invalid_step_spec}} =
               Compiler.compile_spec(plan, %{"urn:step:only-iri" => NoopStep})
    end
  end

  test "extra keys on a step or plan are projection-neutral" do
    plan = %{
      iri: "urn:plan:extra-keys",
      generated_by: "urn:ggen:some-pack",
      steps: [Map.put(step("urn:step:a"), :metadata, %{anything: true})]
    }

    assert {:ok, reactor} = Compiler.compile_spec(plan, handlers(plan))
    assert Enum.any?(reactor.steps, &(&1.name == "urn:step:a"))
  end

  test "refuses dangling predecessors with the offending edges named" do
    plan = %{
      iri: "urn:plan:dangling",
      steps: [
        step("urn:step:a", ["urn:step:ghost", "urn:step:ghost2"]),
        step("urn:step:b", ["urn:step:a"])
      ]
    }

    assert {:error, %Error{reason: :dangling_predecessors, details: %{edges: edges}}} =
             Compiler.compile_spec(plan, handlers(plan))

    assert Enum.sort(edges) == [
             {"urn:step:a", "urn:step:ghost"},
             {"urn:step:a", "urn:step:ghost2"}
           ]
  end

  test "refuses the first predecessor binding beyond the 16-name budget" do
    predecessor_steps = Enum.map(1..17, &step("urn:step:p#{&1}"))

    plan = %{
      iri: "urn:plan:wide-predecessors",
      steps: predecessor_steps ++ [step("urn:step:b", Enum.map(predecessor_steps, & &1.iri))]
    }

    assert {:error,
            %Error{
              reason: :too_many_predecessors,
              details: %{step: "urn:step:b", count: 17, maximum: 16}
            }} = Compiler.compile_spec(plan, handlers(plan))
  end

  test "deduplication applies before the predecessor budget is checked" do
    predecessors = Enum.map(1..16, &"urn:step:p#{&1}") ++ ["urn:step:p16", "urn:step:p16"]

    plan = %{
      iri: "urn:plan:dedup-predecessors",
      steps: Enum.map(1..16, &step("urn:step:p#{&1}")) ++ [step("urn:step:b", predecessors)]
    }

    # 18 raw predecessor entries deduplicate to 16 — inside the budget, admits.
    assert {:ok, reactor} = Compiler.compile_spec(plan, handlers(plan))
    assert length(reactor.steps) == 17
  end

  test "refuses a plan whose steps are a map rather than a list" do
    plan = %{iri: "urn:plan:map-steps", steps: %{"urn:step:a" => step("urn:step:a")}}

    assert {:error, %Error{reason: :invalid_plan_spec}} = Compiler.compile_spec(plan, %{})
  end

  test "compile_spec refuses a handlers argument that is not a map" do
    plan = %{iri: "urn:plan:not-map-handlers", steps: [step("urn:step:a")]}

    assert {:error, %Error{reason: :invalid_plan_spec}} =
             Compiler.compile_spec(plan, [NoopStep])
  end

  test "compile with a non-atom handler on an unknown plan still refuses typed" do
    assert {:error, %Error{reason: :unknown_plan}} = Compiler.compile("urn:plan:absent", %{})
  end

  # ---------------------------------------------------------------------------
  # Oban control-plane boundary with garbage arguments
  # ---------------------------------------------------------------------------

  test "describe_resource refuses non-atom subjects with a typed error, not a raise" do
    for garbage <- ["not a module", nil, 42, %{}, [AshPPlan.ObanIntegrationResource]] do
      assert {:error, %{reason: :not_an_ash_resource}} = Oban.describe_resource(garbage)
    end
  end

  test "activations and capabilities refuse non-atom subjects typed" do
    assert {:error, %{reason: :not_an_ash_resource}} = Oban.activations("garbage")
    assert {:error, %{reason: :not_an_ash_resource}} = Oban.capabilities(nil)
  end

  test "fetch_activation refuses non-atom resource or name typed" do
    assert {:error, %{reason: :not_an_ash_resource}} =
             Oban.fetch_activation("not a resource", :process)

    assert {:error, %{reason: :not_an_ash_resource}} =
             Oban.fetch_activation(AshPPlan.ObanIntegrationResource, "not an atom")
  end

  test "construct_trigger refuses garbage trigger terms typed" do
    record = struct(AshPPlan.ObanIntegrationResource, processed: false)

    for trigger <- ["not a trigger", 42, {:tuple, :garbage}, %{name: :process}] do
      assert {:error, %{reason: :unknown_ash_oban_trigger}} =
               Oban.construct_trigger(record, trigger)
    end
  end

  test "construct_trigger refuses garbage records and options typed" do
    for record <- [%{not: :a_struct}, "string", 42, nil] do
      assert {:error, %{reason: :invalid_ash_oban_construction}} =
               Oban.construct_trigger(record, :process)
    end

    record = struct(AshPPlan.ObanIntegrationResource, processed: false)

    assert {:error, %{reason: :invalid_ash_oban_construction}} =
             Oban.construct_trigger(record, :process, "not a list")
  end

  test "observation classifies garbage returns as unknown, never raises" do
    for garbage <- [%{unexpected: true}, make_ref(), self(), "error string"] do
      assert %{state: :unknown, terminal?: false} = Oban.observation(garbage)
    end
  end

  test "observation refuses malformed snooze payloads as unknown" do
    for bad <- [{:snooze, -1}, {:snooze, 1.5}, {:snooze, {1, :fortnight}}, {:snooze, "10"}] do
      assert %{state: :unknown} = Oban.observation(bad)
    end
  end
end
