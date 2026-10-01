defmodule AshPPlan.Workflow.FondCourtTest do
  @moduledoc """
  FOND Court. Falsifies: an admitted task outcome that is neither observable
  (backed by declared evidence) nor explicitly listed unsupported, and a
  projected policy that the FOND validator does not admit. Anti-vacuity
  mutation: stripping evidence from a task must move its outcomes into
  `unsupported`; a model with an unreachable goal must yield no policy.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Model
  alias AshPPlan.Workflow.Project.FOND, as: Proj

  defp model(evidence) do
    {:ok, m} =
      Model.new(
        name: :fond_wf,
        tasks: [
          [
            id: :a,
            capability: "File.Write",
            outcomes: ["success", "failure"],
            evidence: evidence
          ],
          [id: :b, capability: "File.Write", outcomes: ["success"], evidence: ["prov"]],
          [
            id: :c,
            capability: "File.Write",
            depends_on: [:a, :b],
            outcomes: ["success"],
            evidence: ["prov"]
          ]
        ]
      )

    m
  end

  test "projected policy is strong-cyclic and admitted by the validator" do
    assert {:ok, %{domain: d, initial: i, policy: p, mode: :strong_cyclic, refusal: nil}} =
             Proj.project(model(["prov"]))

    assert is_map(p)
    assert {:ok, %{semantics: :strong_cyclic}} = AshPPlan.validate_policy(d, p, i)
  end

  test "every outcome is observable or explicitly unsupported" do
    m = model([])
    {:ok, r} = Proj.project(m)
    all = for t <- m.tasks, o <- t.outcomes, do: {t.id, o}
    assert Enum.sort(r.observable ++ r.unsupported) == Enum.sort(all)
    assert {:a, "failure"} in r.unsupported
    assert {:b, "success"} in r.observable
  end

  test "mutation: evidence moves outcomes between observable and unsupported" do
    {:ok, with_ev} = Proj.project(model(["prov"]))
    {:ok, without} = Proj.project(model([]))
    assert {:a, "failure"} in with_ev.observable
    refute {:a, "failure"} in with_ev.unsupported
    assert {:a, "failure"} in without.unsupported
    assert length(without.unsupported) > length(with_ev.unsupported)
  end

  test "mutation: goal states are exactly the full completion" do
    {:ok, r} = Proj.project(model(["prov"]))
    assert r.domain.goals == MapSet.new([[:a, :b, :c]])
    refute MapSet.member?(r.domain.goals, [])
  end

  test "non-model is refused" do
    assert {:error, %{reason: :not_a_model}} = Proj.project(:nope)
  end
end
