defmodule AshPPlan.Workflow.FondTerminalCourtTest do
  @moduledoc """
  FOND terminal-outcome Court. Falsifies: a terminal outcome still contributing
  a branch (the retry self-loop), a terminal declaration outside the declared
  outcome set passing validation, an all-terminal task still admitting an
  action, and a transition relation that includes unreachable states (the
  old power-set projection). Anti-vacuity mutations: dropping the terminal
  declaration must restore the pre-terminal `[next, done]` branches, and a
  terminal outcome on a task with no declared outcomes must be refused.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Model
  alias AshPPlan.Workflow.Project.FOND, as: Proj

  defp model(tasks) do
    {:ok, m} = Model.new(name: :terminal_wf, tasks: tasks)
    m
  end

  defp gate(outcomes, terminal) do
    [
      id: :a,
      capability: "File.Write",
      outcomes: outcomes,
      terminal_outcomes: terminal,
      evidence: ["prov"]
    ]
  end

  # ---- branches ----

  test "terminal outcome contributes no branch: no retry self-loop" do
    m = model([gate(["success", "failure"], ["failure"])])

    assert {:ok, %{domain: d, refusal: nil}} = Proj.project(m)
    assert d.transitions[[]][{:run, :a}] == [[:a]]
  end

  test "terminal [] pins the pre-terminal branches [next, done]" do
    m = model([gate(["success", "failure"], [])])

    assert {:ok, %{domain: d}} = Proj.project(m)
    # FOND.new normalizes every outcome list with a strict sort, so the stored
    # form of [next, done] is [[], [:a]] — the same bytes the pre-terminal
    # projection produced.
    assert d.transitions[[]][{:run, :a}] == [[], [:a]]
  end

  test "multiple live outcomes still retry; single live outcome is deterministic" do
    two_live = model([gate(["success", "retry", "failure"], ["failure"])])
    assert {:ok, %{domain: d}} = Proj.project(two_live)
    assert d.transitions[[]][{:run, :a}] == [[], [:a]]

    one_live = model([gate(["success", "BLOCKED"], ["BLOCKED"])])
    assert {:ok, %{domain: d2}} = Proj.project(one_live)
    assert d2.transitions[[]][{:run, :a}] == [[:a]]
  end

  # ---- validation ----

  test "terminal outcome outside the declared outcomes is refused" do
    assert {:error, %{reason: :unknown_terminal_outcomes, tasks: [:a]}} =
             Model.new(
               name: :bad_terminal,
               tasks: [
                 [
                   id: :a,
                   capability: "File.Write",
                   outcomes: ["success"],
                   terminal_outcomes: ["failure"]
                 ]
               ]
             )
  end

  test "mutation: a terminal outcome on a task with no declared outcomes is refused" do
    assert {:error, %{reason: :unknown_terminal_outcomes, tasks: [:a]}} =
             Model.new(
               name: :empty_terminal,
               tasks: [
                 [id: :a, capability: "File.Write", outcomes: [], terminal_outcomes: ["BLOCKED"]]
               ]
             )

    # The projection re-validates: a hand-built model cannot sneak past new/1.
    m = %Model{name: :empty_terminal, tasks: [Model.task(empty_terminal_task())]}
    assert {:error, %{reason: :unknown_terminal_outcomes}} = Proj.project(m)
  end

  defp empty_terminal_task do
    struct!(AshPPlan.Workflow.Task,
      id: :a,
      capability: "File.Write",
      outcomes: [],
      terminal_outcomes: ["BLOCKED"]
    )
  end

  # ---- all-terminal task ----

  test "all-terminal task: action omitted, state stored with empty action map" do
    m = model([gate(["BLOCKED"], ["BLOCKED"])])

    assert {:ok, %{domain: d}} = Proj.project(m)
    assert d.transitions[[]] == %{}
    assert MapSet.member?(d.states, [])
  end

  test "all-terminal gate task loses: no policy, non-nil refusal" do
    m = model([gate(["BLOCKED"], ["BLOCKED"])])

    assert {:ok, %{policy: nil, refusal: refusal}} = Proj.project(m)
    assert refusal != nil
  end

  test "mixed model: terminal-free task still completes, all-terminal task blocks the goal" do
    m =
      model([
        gate(["BLOCKED"], ["BLOCKED"]),
        [id: :b, capability: "File.Write", outcomes: ["success"], evidence: ["prov"]]
      ])

    assert {:ok, %{domain: d, policy: nil, refusal: refusal}} = Proj.project(m)
    assert d.transitions[[]] == %{{:run, :b} => [[:b]]}
    assert Map.has_key?(d.transitions, [:b]) and d.transitions[[:b]] == %{}
    assert refusal != nil
  end

  # ---- BFS reachability ----

  test "projection covers exactly the reachable states, not the power set" do
    {:ok, m} =
      Model.new(
        name: :fond_wf,
        tasks: [
          [
            id: :a,
            capability: "File.Write",
            outcomes: ["success", "failure"],
            evidence: ["prov"]
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

    assert {:ok, %{domain: d}} = Proj.project(m)

    assert d.states ==
             MapSet.new([[], [:a], [:b], [:a, :b], [:a, :b, :c]]),
           "expected exactly the BFS-reachable states, got #{inspect(d.states)}"

    for unreachable <- [[:c], [:b, :c], [:a, :c]] do
      refute MapSet.member?(d.states, unreachable),
             "unreachable subset #{inspect(unreachable)} must not be projected"
    end
  end

  test "BFS terminates on retry cycles: every reachable state appears exactly once as a key" do
    m = model([gate(["success", "failure"], [])])

    assert {:ok, %{domain: d}} = Proj.project(m)
    assert MapSet.size(d.states) == length(Map.keys(d.transitions))
  end

  # ---- end to end ----

  test "terminal chain admits a strong policy end to end" do
    tasks =
      for i <- 1..3 do
        [
          id: :"t#{i}",
          capability: "File.Write",
          depends_on: if(i == 1, do: [], else: [:"t#{i - 1}"]),
          outcomes: ["proceed", "BLOCKED"],
          terminal_outcomes: ["BLOCKED"],
          evidence: ["prov"]
        ]
      end

    m = model(tasks)

    assert {:ok, %{domain: d, initial: i, policy: p, refusal: nil}} =
             Proj.project(m, mode: :strong)

    assert {:ok, %{semantics: :strong}} = AshPPlan.validate_policy(d, p, i, :strong)
  end

  test "regression guard: the fond_court 3-task model still projects to an admitted strong-cyclic policy" do
    {:ok, m} =
      Model.new(
        name: :fond_wf,
        tasks: [
          [
            id: :a,
            capability: "File.Write",
            outcomes: ["success", "failure"],
            evidence: ["prov"]
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

    assert {:ok, %{domain: d, initial: i, policy: p, mode: :strong_cyclic, refusal: nil}} =
             Proj.project(m)

    assert {:ok, %{semantics: :strong_cyclic}} = AshPPlan.validate_policy(d, p, i)
  end
end
