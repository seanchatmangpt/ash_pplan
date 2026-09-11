defmodule AshPPlan.CompilerRefusalTest do
  @moduledoc """
  Every refusal `AshPPlan.Compiler` claims is proven to actually refuse.

  The compiler's fail-closed contract is a public release claim, so each
  documented refusal reason gets an executable falsifier rather than prose.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error

  defmodule NoopStep do
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :noop}
  end

  # 16 terminal argument names are bound in the compiler; 17 independent
  # terminals is the first fan-out it must refuse.
  @terminal_limit 16

  test "refuses a plan IRI absent from the manufactured catalog" do
    assert {:error, %Error{reason: :unknown_plan, details: %{plan_iri: "urn:plan:absent"}}} =
             AshPPlan.compile_plan("urn:plan:absent", %{})
  end

  test "refuses a specification that is not a plan" do
    assert {:error, %Error{reason: :invalid_plan_spec}} = Compiler.compile_spec(%{}, %{})

    assert {:error, %Error{reason: :invalid_plan_spec}} =
             Compiler.compile_spec(%{iri: :not_a_binary, steps: []}, %{})
  end

  test "refuses a plan with no steps" do
    assert {:error, %Error{reason: :empty_plan}} =
             Compiler.compile_spec(%{iri: "urn:plan:empty", steps: []}, %{})
  end

  test "refuses a plan that declares the same step twice" do
    plan = %{iri: "urn:plan:dup", steps: [step("urn:step:a"), step("urn:step:a")]}

    assert {:error, %Error{reason: :duplicate_steps, details: %{steps: ["urn:step:a"]}}} =
             Compiler.compile_spec(plan, %{"urn:step:a" => NoopStep})
  end

  test "refuses a handler that does not implement Reactor.Step" do
    plan = %{iri: "urn:plan:bad-handler", steps: [step("urn:step:a")]}

    assert {:error, %Error{reason: :invalid_handlers, details: %{steps: ["urn:step:a"]}}} =
             Compiler.compile_spec(plan, %{"urn:step:a" => String})

    assert {:error, %Error{reason: :invalid_handlers}} =
             Compiler.compile_spec(plan, %{"urn:step:a" => "not even a module"})
  end

  test "admits a bounded terminal fan-out and refuses the first one beyond it" do
    admitted = plan_with_terminals(@terminal_limit)
    assert {:ok, _reactor} = Compiler.compile_spec(admitted, handlers(admitted))

    refused = plan_with_terminals(@terminal_limit + 1)

    assert {:error,
            %Error{
              reason: :too_many_terminal_steps,
              details: %{count: 17, maximum: @terminal_limit}
            }} = Compiler.compile_spec(refused, handlers(refused))
  end

  test "refusals carry a readable message" do
    {:error, error} = AshPPlan.compile_plan("urn:plan:absent", %{})

    assert Exception.message(error) =~ "ash_pplan compiler refused unknown_plan"
  end

  defp plan_with_terminals(count) do
    %{
      iri: "urn:plan:fanout-#{count}",
      steps: Enum.map(1..count, &step("urn:step:#{&1}"))
    }
  end

  defp handlers(%{steps: steps}), do: Map.new(steps, &{&1.iri, NoopStep})

  defp step(iri, predecessors \\ []) do
    %{iri: iri, label: iri, predecessors: predecessors, inputs: [], outputs: []}
  end
end
