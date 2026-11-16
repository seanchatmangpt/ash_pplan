defmodule AshPPlan.MirrorSim.KillCompilerTest do
  @moduledoc """
  Kills mirror-sim mutants that survived their mapped court:
  CMP-03, CMP-19, CMP-20 against lib/ash_pplan/compiler.ex.
  Real compiler, final-state / typed-refusal assertions.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error

  defmodule Passthrough do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :passthrough}
  end

  defp step(iri, preds \\ []) do
    %{iri: iri, label: iri, predecessors: preds, inputs: [], outputs: []}
  end

  defp handlers do
    %{
      "urn:kc:a" => Passthrough,
      "urn:kc:b" => Passthrough,
      "" => Passthrough
    }
  end

  # CMP-03: `not MapSet.member?(known, predecessor)` -> `false`
  test "CMP-03 dangling predecessor is refused with the dangling edge named" do
    plan = %{
      iri: "urn:kc:plan_dangling",
      steps: [step("urn:kc:a"), step("urn:kc:b", ["urn:kc:ghost"])]
    }

    assert {:error, %Error{reason: :dangling_predecessors, details: %{edges: edges}}} =
             Compiler.compile_spec(plan, handlers())

    assert edges == [{"urn:kc:b", "urn:kc:ghost"}]
  end

  # CMP-19: admit_powl(unsupported_powl_shape) :ok -> {:error, ...}
  test "CMP-19 unsupported POWL shape is not a refusal; structural path compiles" do
    plan = %{
      iri: "urn:kc:plan_unsupported_shape",
      steps: [step("urn:kc:a"), step("urn:kc:b", ["urn:kc:a"])],
      formalism: :powl,
      plan: :not_a_powl_model
    }

    assert {:ok, %Reactor{id: "urn:kc:plan_unsupported_shape"}} =
             Compiler.compile_spec(plan, handlers())
  end

  # CMP-20: `byte_size(iri) > 0` guard dropped
  test "CMP-20 empty step IRI is refused as invalid_step_spec" do
    plan = %{
      iri: "urn:kc:plan_empty_iri",
      steps: [step("urn:kc:a"), step("")]
    }

    assert {:error, %Error{reason: :invalid_step_spec, details: %{steps: bad}}} =
             Compiler.compile_spec(plan, handlers())

    assert [%{iri: ""}] = bad
  end
end
