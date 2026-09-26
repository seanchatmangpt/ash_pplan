defmodule AshPPlan.FONDTLATest do
  @moduledoc """
  FOND x TLA+ shared-abstraction court.

  Rendering tests run everywhere. The differential court runs the pinned TLC
  1.7.4 jar as a real `java` subprocess and requires, for every corpus case and
  both modes, that `AshPPlan.FOND.validate_policy/4` and TLC return the same
  verdict on the model rendered by `AshPPlan.FOND.to_tla/4`. No collaborator is
  replaced by a double.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.Test.TLCCourt

  # name => {transitions, goals, policy, initial, expected %{strong:, strong_cyclic:}}
  @corpus [
    retry_cycle:
      {%{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}}, [:succeeded],
       %{pending: :attempt}, :pending, %{strong: :refused, strong_cyclic: :admitted}},
    two_state_retry:
      {%{
         s0: %{try: [:s0, :s1]},
         s1: %{try: [:s0, :done]},
         done: %{}
       }, [:done], %{s0: :try, s1: :try}, :s0, %{strong: :refused, strong_cyclic: :admitted}},
    pure_strong_fanout:
      {%{pending: %{finish: [:succeeded, :failed]}, succeeded: %{}, failed: %{}},
       [:succeeded, :failed], %{pending: :finish}, :pending,
       %{strong: :admitted, strong_cyclic: :admitted}},
    pure_strong_chain:
      {%{
         a: %{go: [:b, :c]},
         b: %{go: [:c]},
         c: %{go: [:goal_1, :goal_2]},
         goal_1: %{},
         goal_2: %{}
       }, [:goal_1, :goal_2], %{a: :go, b: :go, c: :go}, :a,
       %{strong: :admitted, strong_cyclic: :admitted}},
    dead_end:
      {%{pending: %{finish: [:succeeded, :failed]}, succeeded: %{}, failed: %{}}, [:succeeded],
       %{pending: :finish}, :pending, %{strong: :refused, strong_cyclic: :refused}},
    retry_into_dead_end:
      {%{pending: %{attempt: [:pending, :broken]}, broken: %{}, succeeded: %{}}, [:succeeded],
       %{pending: :attempt}, :pending, %{strong: :refused, strong_cyclic: :refused}},
    missing_decision:
      {%{
         pending: %{attempt: [:review]},
         review: %{approve: [:succeeded]},
         succeeded: %{}
       }, [:succeeded], %{pending: :attempt}, :pending,
       %{strong: :refused, strong_cyclic: :refused}},
    unavailable_action:
      {%{pending: %{attempt: [:succeeded]}, succeeded: %{}}, [:succeeded], %{pending: :invented},
       :pending, %{strong: :refused, strong_cyclic: :refused}},
    closed_trap:
      {%{pending: %{attempt: [:stuck]}, stuck: %{retry: [:stuck]}, succeeded: %{}}, [:succeeded],
       %{pending: :attempt, stuck: :retry}, :pending,
       %{strong: :refused, strong_cyclic: :refused}},
    branch_into_trap:
      {%{
         pending: %{attempt: [:succeeded, :trap]},
         trap: %{spin: [:trap_b]},
         trap_b: %{spin: [:trap]},
         succeeded: %{}
       }, [:succeeded], %{pending: :attempt, trap: :spin, trap_b: :spin}, :pending,
       %{strong: :refused, strong_cyclic: :refused}},
    initial_is_goal:
      {%{done: %{}}, [:done], %{}, :done, %{strong: :admitted, strong_cyclic: :admitted}},
    unreachable_undecided_state:
      {%{
         pending: %{attempt: [:succeeded]},
         orphan: %{attempt: [:orphan]},
         succeeded: %{}
       }, [:succeeded], %{pending: :attempt}, :pending,
       %{strong: :admitted, strong_cyclic: :admitted}},
    decision_choice_matters:
      {%{
         pending: %{safe: [:succeeded], risky: [:pending, :succeeded]},
         succeeded: %{}
       }, [:succeeded], %{pending: :risky}, :pending,
       %{strong: :refused, strong_cyclic: :admitted}}
  ]

  @modes [:strong, :strong_cyclic]

  defp domain!(transitions, goals) do
    {:ok, domain} = FOND.new(transitions, goals)
    domain
  end

  defp elixir_verdict(domain, policy, initial, mode) do
    case FOND.validate_policy(domain, policy, initial, mode) do
      {:ok, _report} -> :admitted
      {:error, _refusal} -> :refused
    end
  end

  describe "to_tla/4 rendering" do
    setup do
      domain =
        domain!(%{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}}, [:succeeded])

      %{domain: domain, policy: %{pending: :attempt}}
    end

    test "strong_cyclic renders one action per decision, an outcome disjunction and SF per branch",
         %{domain: domain, policy: policy} do
      assert {:ok, rendered} = FOND.to_tla(domain, policy, :pending, :strong_cyclic)

      assert rendered.module_name == "FONDPolicy"
      assert rendered.state_names == %{pending: "s0", succeeded: "s1"}
      assert rendered.initial == "s0"
      assert rendered.branches == ["B_0_1", "B_0_2"]

      module = rendered.module
      assert module =~ ~r/\A---- MODULE FONDPolicy ----\n/
      assert module =~ "VARIABLES state, tick"
      assert module =~ ~s(Init == state = "s0" /\\ tick = 0)
      assert module =~ ~s(B_0_1 == state = "s0" /\\ state' = "s0" /\\ tick' = 1 - tick)
      assert module =~ ~s(B_0_2 == state = "s0" /\\ state' = "s1" /\\ tick' = 1 - tick)
      assert module =~ "A_0 ==\n  \\/ B_0_1\n  \\/ B_0_2\n"
      assert module =~ "Next ==\n  \\/ A_0\n  \\/ Done\n"
      assert module =~ ~s(Goals == {"s1"})
      assert module =~ "Fairness ==\n  /\\ SF_vars(B_0_1)\n  /\\ SF_vars(B_0_2)\n"
      assert module =~ "Spec == Init /\\ [][Next]_vars /\\ Progress /\\ Fairness"
      assert module =~ "GoalReached == <>Goal"
      assert module =~ ~r/\n={77}\n\z/

      assert rendered.cfg == "SPECIFICATION Spec\nINVARIANT TypeOK\nPROPERTY GoalReached\n"
    end

    test "strong renders no fairness over outcomes", %{domain: domain, policy: policy} do
      assert {:ok, rendered} = FOND.to_tla(domain, policy, :pending, :strong)
      assert rendered.module =~ "Fairness == TRUE"
      refute rendered.module =~ "SF_vars"
      assert rendered.module =~ "Progress == WF_vars(Next)"
    end

    test "rendering is deterministic and independent of map construction order" do
      a = domain!(%{b: %{go: [:c, :a]}, a: %{go: [:b]}, c: %{}}, [:c])
      b = domain!(%{c: %{}, a: %{go: [:b]}, b: %{go: [:a, :c]}}, [:c])

      assert {:ok, ra} = FOND.to_tla(a, %{a: :go, b: :go}, :a, :strong_cyclic)
      assert {:ok, rb} = FOND.to_tla(b, %{b: :go, a: :go}, :a, :strong_cyclic)
      assert ra == rb
    end

    test "undecided and unavailable decisions render no action (TLC deadlock), goals are absorbing" do
      domain =
        domain!(
          %{
            pending: %{attempt: [:review]},
            review: %{approve: [:done]},
            done: %{redo: [:pending]}
          },
          [:done]
        )

      assert {:ok, rendered} =
               FOND.to_tla(domain, %{pending: :attempt, done: :redo}, :pending, :strong_cyclic)

      # done=s0, pending=s1, review=s2
      assert rendered.state_names == %{done: "s0", pending: "s1", review: "s2"}
      assert rendered.branches == ["B_1_1"]
      refute rendered.module =~ "A_0 =="
      refute rendered.module =~ "A_2 =="
      assert rendered.module =~ "Done == state \\in Goals /\\ UNCHANGED vars"
    end

    test "non-atom state terms are encoded by index with an inspect table in comments" do
      domain = domain!(%{{:job, 1} => %{"run" => [{:job, 1}, "ok\nnow"]}}, ["ok\nnow"])

      assert {:ok, rendered} =
               FOND.to_tla(domain, %{{:job, 1} => "run"}, {:job, 1}, :strong_cyclic)

      assert rendered.state_names == %{{:job, 1} => "s0", "ok\nnow" => "s1"}
      assert rendered.module =~ ~s(\\*   "s0" = {:job, 1} policy="run")
      assert rendered.module =~ ~s(\\*   "s1" = "ok\\nnow")
    end

    test "empty goal set renders an empty TLA+ set" do
      domain = domain!(%{spin: %{go: [:spin]}}, [])
      assert {:ok, rendered} = FOND.to_tla(domain, %{spin: :go}, :spin, :strong)
      assert rendered.module =~ "Goals == {}"
    end

    test "refuses unknown initial state, invalid mode and invalid module name",
         %{domain: domain, policy: policy} do
      assert {:error, %{reason: :unknown_initial_state, state: :nowhere}} =
               FOND.to_tla(domain, policy, :nowhere, :strong)

      assert {:error, %{reason: :invalid_policy_request, mode: :weak}} =
               FOND.to_tla(domain, policy, :pending, :weak)

      assert {:error, %{reason: :invalid_policy_request}} =
               FOND.to_tla(domain, :not_a_policy, :pending, :strong)

      assert {:error, %{reason: :invalid_tla_module_name, module_name: "1bad name"}} =
               FOND.to_tla(domain, policy, :pending, :strong, module_name: "1bad name")

      assert {:ok, %{module: module, module_name: "Retry"}} =
               FOND.to_tla(domain, policy, :pending, :strong, module_name: "Retry")

      assert module =~ ~r/\A---- MODULE Retry ----/
    end

    test "corpus expectations are non-degenerate in both modes" do
      for mode <- @modes do
        verdicts =
          @corpus
          |> Enum.map(fn {_name, {_t, _g, _p, _i, expected}} -> expected[mode] end)
          |> Enum.uniq()
          |> Enum.sort()

        assert verdicts == [:admitted, :refused], "mode #{mode} corpus is one-sided"
      end
    end

    for {name, {transitions, goals, policy, initial, expected}} <- @corpus, mode <- @modes do
      @tag corpus: name, mode: mode
      test "validate_policy verdict matches corpus expectation: #{name} #{mode}" do
        domain =
          domain!(unquote(Macro.escape(transitions)), unquote(Macro.escape(goals)))

        assert elixir_verdict(
                 domain,
                 unquote(Macro.escape(policy)),
                 unquote(Macro.escape(initial)),
                 unquote(mode)
               ) == unquote(expected[mode])
      end
    end
  end

  describe "TLC differential court (tla2tools 1.7.4, real java subprocess)" do
    case TLCCourt.availability() do
      :ok -> @describetag :tlc
      {:unavailable, reason} -> @describetag skip: "TLC court unavailable: " <> reason
    end

    test "pinned jar digest is admitted" do
      assert TLCCourt.verify_jar!() == TLCCourt.jar_sha256()
    end

    for {name, {transitions, goals, policy, initial, expected}} <- @corpus, mode <- @modes do
      @tag corpus: name, mode: mode
      test "TLC verdict == validate_policy verdict: #{name} #{mode}" do
        domain =
          domain!(unquote(Macro.escape(transitions)), unquote(Macro.escape(goals)))

        policy = unquote(Macro.escape(policy))
        initial = unquote(Macro.escape(initial))
        mode = unquote(mode)

        elixir = elixir_verdict(domain, policy, initial, mode)
        {:ok, rendered} = FOND.to_tla(domain, policy, initial, mode)
        tlc = TLCCourt.check!(rendered)

        assert elixir == unquote(expected[mode])

        assert tlc.verdict == elixir,
               "disagreement on #{unquote(name)} #{mode}: elixir=#{elixir} tlc=#{tlc.verdict}\n" <>
                 rendered.module <> "\n" <> tlc.output
      end
    end

    test "anti-vacuity: deleting the SF fairness clause flips the strong_cyclic retry case" do
      domain =
        domain!(%{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}}, [:succeeded])

      {:ok, rendered} = FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong_cyclic)
      assert %{verdict: :admitted} = TLCCourt.check!(rendered)

      mutated_module =
        Regex.replace(
          ~r/Fairness ==\n(  \/\\ SF_vars\([A-Z0-9_]+\)\n)+/,
          rendered.module,
          "Fairness == TRUE\n"
        )

      refute mutated_module == rendered.module
      refute mutated_module =~ "SF_vars"

      assert %{verdict: :refused, kind: :liveness} =
               TLCCourt.check!(%{rendered | module: mutated_module})
    end

    test "anti-vacuity: weakening SF to WF on the retry branch is refused (fairness strength matters)" do
      domain =
        domain!(
          %{s0: %{try: [:s0, :s1]}, s1: %{try: [:s0, :done]}, done: %{}},
          [:done]
        )

      {:ok, rendered} = FOND.to_tla(domain, %{s0: :try, s1: :try}, :s0, :strong_cyclic)
      assert %{verdict: :admitted} = TLCCourt.check!(rendered)

      weakened = %{rendered | module: String.replace(rendered.module, "SF_vars(", "WF_vars(")}
      assert %{verdict: :refused, kind: :liveness} = TLCCourt.check!(weakened)
    end

    test "anti-vacuity: a rendering TLC cannot parse raises instead of counting as a refusal" do
      domain = domain!(%{pending: %{attempt: [:succeeded]}, succeeded: %{}}, [:succeeded])
      {:ok, rendered} = FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong)

      broken = %{rendered | module: String.replace(rendered.module, "Init ==", "Init ===")}

      assert_raise RuntimeError, ~r/no classifiable verdict/, fn ->
        TLCCourt.check!(broken)
      end
    end
  end
end
