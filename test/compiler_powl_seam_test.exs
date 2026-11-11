defmodule AshPPlan.CompilerPowlSeamTest do
  @moduledoc """
  Lane Z3 seam court: POWL verification gates Compiler admission for
  candidates that explicitly carry a POWL model; steps-only candidates take
  the structural path unchanged. Real compiler, real refusals (Chicago:
  the compiler is the real collaborator, no mocks).
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error
  alias AshPPlan.POWL

  defmodule PassthroughStep do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :passthrough}
  end

  defp step(iri, preds \\ []) do
    %{
      iri: iri,
      label: iri,
      predecessors: preds,
      inputs: [],
      outputs: []
    }
  end

  defp handlers do
    %{
      "urn:step:a" => PassthroughStep,
      "urn:step:b" => PassthroughStep,
      "urn:step:c" => PassthroughStep,
      "urn:step:d" => PassthroughStep
    }
  end

  # PT-handle: choice `urn:step:c` interior to the poset with two
  # incomparable predecessors (b and d under a), so the in-side is not
  # totally ordered.
  defp pt_handle_model do
    POWL.partial_order(
      "po_pt",
      [
        POWL.activity("urn:step:a"),
        POWL.activity("urn:step:b"),
        POWL.activity("urn:step:d"),
        POWL.choice("urn:step:c", [
          POWL.activity("urn:step:c1"),
          POWL.activity("urn:step:c2")
        ])
      ],
      [
        {"urn:step:a", "urn:step:b"},
        {"urn:step:a", "urn:step:d"},
        {"urn:step:b", "urn:step:c"},
        {"urn:step:d", "urn:step:c"}
      ]
    )
  end

  defp base_steps do
    [step("urn:step:a"), step("urn:step:b", ["urn:step:a"])]
  end

  test "separable POWL candidate compiles" do
    plan = %{
      iri: "urn:plan:powl_separable",
      steps: base_steps(),
      formalism: :powl,
      plan:
        POWL.sequence("seq_ok", [
          POWL.activity("urn:step:a"),
          POWL.activity("urn:step:b")
        ])
    }

    assert {:ok, %Reactor{id: "urn:plan:powl_separable"}} =
             Compiler.compile_spec(plan, handlers())
  end

  test "PT-handle POWL model refused with the block named" do
    plan = %{
      iri: "urn:plan:powl_pt_handle",
      steps: base_steps(),
      formalism: :powl,
      plan: pt_handle_model()
    }

    assert {:error, %Error{reason: :non_separable_block, details: %{block: block}}} =
             Compiler.compile_spec(plan, handlers())

    assert %{cause: :pt_handle_choice_interior, node: "urn:step:c"} = block
    assert block.side in [:in, :out]
  end

  test "separable partial order under `plan:` key compiles" do
    plan = %{
      iri: "urn:plan:powl_po_ok",
      steps: base_steps(),
      plan:
        POWL.partial_order(
          "po_ok",
          [
            POWL.activity("urn:step:a"),
            POWL.activity("urn:step:b")
          ],
          [{"urn:step:a", "urn:step:b"}]
        )
    }

    assert {:ok, %Reactor{}} = Compiler.compile_spec(plan, handlers())
  end

  test "steps-only plan never touches the POWL gate (structural refusals intact)" do
    cyclic = %{
      iri: "urn:plan:steps_cycle",
      steps: [step("urn:step:a", ["urn:step:b"]), step("urn:step:b", ["urn:step:a"])]
    }

    assert {:error, %Error{reason: :cyclic_plan}} =
             Compiler.compile_spec(cyclic, %{
               "urn:step:a" => PassthroughStep,
               "urn:step:b" => PassthroughStep
             })
  end

  test "non-separable refusal fires under plain `plan:` key (no formalism tag)" do
    plan = %{
      iri: "urn:plan:powl_pt_no_tag",
      steps: base_steps(),
      plan: pt_handle_model()
    }

    assert {:error, %Error{reason: :non_separable_block}} =
             Compiler.compile_spec(plan, handlers())
  end
end
