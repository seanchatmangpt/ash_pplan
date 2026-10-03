defmodule AshPPlan.FONDHardenH4Test do
  @moduledoc """
  Adversarial hardening for the FOND supervision surface (lane h4):

    * the reconstruction horizon must catch infinite strong-cyclic
      reconstruction loops through BOTH `observe/3` and `replace_domain/2`
    * malformed horizon/mode options produce typed refusals, not crashes
    * malformed court inputs produce typed counterexamples, not crashes
    * the seeded corpus produces valid domains and deterministic cases
    * the attempts counter never leaks between independent runs

  Real collaborators only: every assertion drives the real synthesizer,
  validator, registry and corpus; nothing is stubbed.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{
    Corpus,
    Counterexample,
    Differential,
    PolicySupervisor,
    PolicySwitch,
    ProviderRegistry,
    SupervisionSession
  }

  # `promote` sticks on :pending: an observation of :pending can repeat
  # forever, so only the horizon stops the loop.
  defp looping_domain do
    {:ok, _} = FOND.new(%{pending: %{promote: [:done, :pending]}, done: %{}}, [:done])
  end

  defp solvable_domain do
    {:ok, _} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])
  end

  describe "replace_domain -- reconstruction consumes the horizon" do
    test "an unbounded replace_domain loop terminates at K_max with the typed refusal" do
      {:ok, domain} = looping_domain()
      {:ok, other} = solvable_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 3)

      # three admitted reconstructions consume horizon 3; the fourth is the
      # typed refusal
      s =
        Enum.reduce(1..3, s, fn _i, sup ->
          assert {:ok, sup} = PolicySupervisor.replace_domain(sup, other)
          assert sup.attempts == sup.epoch
          sup
        end)

      assert PolicySupervisor.horizon_exceeded?(s)

      assert {:error, {:horizon_exceeded, 3, witness}} =
               PolicySupervisor.replace_domain(s, other)

      assert is_binary(witness) and String.length(witness) == 64
    end

    test "an interleaved observe/replace_domain loop is also bounded" do
      {:ok, domain} = looping_domain()
      # the replacement must keep :pending's outcome admissible, otherwise the
      # observe legs refuse on outcome admission, not the horizon
      {:ok, other} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 4)

      s = PolicySupervisor.observe(s, 0, :pending) |> unwrap_ok()
      s = PolicySupervisor.replace_domain(s, other) |> unwrap_ok()
      s = PolicySupervisor.observe(s, 2, :pending) |> unwrap_ok()
      s = PolicySupervisor.replace_domain(s, other) |> unwrap_ok()
      assert s.attempts == 4
      assert PolicySupervisor.horizon_exceeded?(s)

      assert {:error, {:horizon_exceeded, 4, _}} = PolicySupervisor.observe(s, 4, :pending)
      assert {:error, {:horizon_exceeded, 4, _}} = PolicySupervisor.replace_domain(s, other)
    end

    test "a failed reconstruction (unsolvable new domain) does not consume the budget" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 1)

      # a domain where :pending cannot reach a goal refuses the synthesis
      {:ok, dead} = FOND.new(%{pending: %{fail: [:dead]}, dead: %{}}, [:done])

      assert {:error, {:unsolvable, :strong_cyclic, _}} =
               PolicySupervisor.replace_domain(s, dead)

      # the budget is intact: the real reconstruction still fits
      {:ok, other} = solvable_domain()
      assert {:ok, s1} = PolicySupervisor.replace_domain(s, other)
      assert s1.attempts == 1
      assert PolicySupervisor.horizon_exceeded?(s1)
    end

    test "exhaustion outranks the shape of the replacement" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 1)
      {:ok, other} = solvable_domain()

      assert {:ok, s1} = PolicySupervisor.replace_domain(s, other)
      # even an invalid replacement cannot preempt the typed horizon verdict
      assert {:error, {:horizon_exceeded, 1, _}} = PolicySupervisor.replace_domain(s1, :not_a_domain)
    end
  end

  describe "malformed options are typed refusals, not crashes" do
    test "PolicySupervisor.start refuses a non-integer horizon" do
      {:ok, domain} = solvable_domain()

      for bad <- [:foo, -1, 1.5, "3"] do
        assert {:error, {:invalid_horizon, ^bad}} =
                 PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: bad)
      end
    end

    test "PolicySwitch.select refuses a non-integer or negative horizon" do
      {:ok, domain} = solvable_domain()

      for bad <- [:foo, -1, 1.5, nil] do
        assert {:error, {:invalid_horizon, ^bad}} =
                 PolicySwitch.select(domain, :pending, horizon: bad)
      end
    end

    test "PolicySwitch.select refuses a non-list modes option" do
      {:ok, domain} = solvable_domain()

      for bad <- [:strong, {:strong, :strong_cyclic}, "modes"] do
        assert {:error, {:invalid_modes, ^bad}} = PolicySwitch.select(domain, :pending, modes: bad)
      end
    end

    test "PolicySwitch.select with an empty mode list is a typed no_admitted_policy" do
      {:ok, domain} = solvable_domain()

      assert {:error, %{reason: :no_admitted_policy, attempted_modes: []}} =
               PolicySwitch.select(domain, :pending, modes: [])
    end
  end

  describe "counterexamples and differential evidence stay typed under malformed input" do
    test "a validator refusal without :reason becomes an unclassifiable counterexample" do
      subject = %{id: "subject-x"}

      ce = Counterexample.from_validator(subject, %{losing_states: [:a]})

      assert ce.class == :unclassifiable_validator_result
      assert ce.source == :validator
      assert ce.raw == %{losing_states: [:a]}
    end

    test "compare/3 with malformed checker output is a mismatch, not a crash" do
      {:ok, domain} = solvable_domain()
      {:ok, policy} = AshPPlan.FOND.Synthesis.synthesize(domain, :pending, :strong)

      malformed = fn _rendered -> %{unexpected: :shape} end

      assert {:error,
              %{
                reason: :differential_mismatch,
                native_verdict: :admitted,
                independent_verdict: :unknown
              }} = Differential.check(domain, policy, :pending, :strong, malformed)
    end

    test "compare/3 with both sides refused stays typed, even for malformed checker shapes" do
      subject = %{id: "s"}

      assert {:ok, %{verdict: :refused, agreement: true, counterexamples: [native_ce, checker_ce]}} =
               Differential.compare(subject, {:error, %{reason: :deadlock}}, %{
                 verdict: :refused,
                 kind: :deadlock
               })

      assert native_ce.class == :deadlock
      assert checker_ce.class == :deadlock

      # a bare-tuple checker result classifies as a typed unclassifiable,
      # it never crashes the court path
      assert {:ok, %{counterexamples: [_, tuple_ce]}} =
               Differential.compare(subject, {:error, %{reason: :deadlock}}, {:error, :whatever})

      assert tuple_ce.class == :unclassifiable_checker_result
    end
  end

  describe "the seeded corpus stays valid and deterministic" do
    test "every seeded case is a valid domain with a resynthesizable structure" do
      for case <- Corpus.seeded(60) do
        {:ok, domain} = FOND.new(case.transitions, case.goals)

        # transitions normalize to the same domain every re-parse
        assert {:ok, again} = FOND.new(case.transitions, case.goals)
        assert domain == again

        for initial <- MapSet.to_list(domain.states) do
          result = AshPPlan.FOND.Synthesis.synthesize(domain, initial, :strong_cyclic)

          case result do
            {:ok, policy} ->
              assert {:ok, _} = FOND.validate_policy(domain, policy, initial, :strong_cyclic)

            {:error, {:unsolvable, :strong_cyclic, witness}} ->
              assert initial in witness
              assert witness == Enum.sort(witness)
          end
        end
      end
    end
  end

  test "seeded corpus is deterministic per seed and fresh per independent run" do
    assert Corpus.seeded(10) == Corpus.seeded(10)
    assert Corpus.seeded(10, {1, 2, 3}) == Corpus.seeded(10, {1, 2, 3})
    refute Corpus.seeded(10) == Corpus.seeded(10, {1, 2, 3})
  end

  describe "the attempts counter never leaks between runs" do
    test "two supervisors over the same domain start at zero and diverge independently" do
      {:ok, domain} = looping_domain()
      {:ok, a} = PolicySupervisor.start(domain, :pending)
      {:ok, b} = PolicySupervisor.start(domain, :pending)

      assert a.attempts == 0 and b.attempts == 0

      assert {:ok, a1} = PolicySupervisor.observe(a, 0, :pending)
      assert a1.attempts == 1
      assert b.attempts == 0

      # b can still burn its own full default horizon of 9
      b_final =
        Enum.reduce(1..9, b, fn i, sup ->
          assert {:ok, sup} = PolicySupervisor.observe(sup, i - 1, :pending)
          sup
        end)

      assert b_final.attempts == 9
      assert PolicySupervisor.horizon_exceeded?(b_final)
      assert {:error, {:horizon_exceeded, 9, _}} = PolicySupervisor.observe(b_final, 9, :pending)
    end

    test "exhaustion is not sticky across a fresh start" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 1)
      assert {:ok, s1} = PolicySupervisor.observe(s, 0, :pending)
      assert PolicySupervisor.horizon_exceeded?(s1)

      assert {:ok, fresh} = PolicySupervisor.start(domain, :pending, :strong_cyclic)
      refute PolicySupervisor.horizon_exceeded?(fresh)
      assert {:ok, _} = PolicySupervisor.observe(fresh, 0, :pending)
    end
  end

  describe "supervision session stays fail-closed under provider churn" do
    test "marking the bound provider unhealthy with no alternative fails intent, typed" do
      {:ok, domain} = solvable_domain()
      {:ok, policy_sup} = PolicySupervisor.start(domain, :pending)
      registry = ProviderRegistry.new([%{id: :only, cost: 0}])
      assert {:ok, session} = SupervisionSession.start(policy_sup, registry, [])

      # stale generation is refused before anything moves
      assert {:error, {:stale_generation, 99, _}} =
               SupervisionSession.observe_provider_health(session, 99, :only, false)

      # marking the only provider unhealthy with no healthy alternative:
      # the rebind refuses typed
      assert {:error, {:no_provider, []}} =
               SupervisionSession.observe_provider_health(
                 session,
                 session.registry.generation,
                 :only,
                 false
               )

      # a session whose registry marks the bound provider unhealthy fails
      # closed on intent, typed
      {:ok, registry2} =
        ProviderRegistry.observe_health(session.registry, session.registry.generation, :only, false)

      assert {:error, {:provider_unhealthy, :only}} =
               SupervisionSession.intent(%{session | registry: registry2})
    end
  end

  defp unwrap_ok({:ok, value}), do: value
end
