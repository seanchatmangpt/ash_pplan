defmodule AshPPlan.FONDHorizonBurnTest do
  @moduledoc """
  Burn-in for the FOND epistemic horizon (K_max) under churn: real
  PolicySupervisor/PolicySwitch only (both pure -- nothing doubled).

  * 1000 seeded random replace_domain/observe interleavings must always land
    on the typed `{:horizon_exceeded, k, witness}` refusal, never bypass it.
  * Failed mutations (failed reconstruction, unadmitted outcome, stale epoch)
    never consume budget.
  * `horizon: 0` is born exhausted: the first mutation is refused.
  * PolicySwitch's default two-mode sweep cannot exhaust the default horizon
    9 (the bound is asserted, not assumed).
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{PolicySupervisor, PolicySwitch}

  # The plan-next promote-stick shape: `promote` may stick (:pending is one of
  # its own outcomes), so :pending observations can repeat forever and only the
  # horizon stops the loop. Only :strong_cyclic admits it.
  defp looping_domain do
    FOND.new(%{pending: %{promote: [:done, :pending]}, done: %{}}, [:done])
  end

  # A domain from which the goal is unreachable: every reconstruction attempt
  # at :pending fails synthesis in any mode, without consuming budget.
  defp dead_end_domain do
    FOND.new(%{pending: %{stuck: [:stuck]}, stuck: %{}, done: %{}}, [:done])
  end

  describe "burn: 1000 seeded interleavings of replace_domain/observe" do
    test "exhaustion is always the typed refusal and is never bypassed" do
      seed = {1, 2026, 103}
      :rand.seed(:exsss, seed)
      {:ok, domain} = looping_domain()

      exhaustion_k =
        Enum.map(1..1000, fn i ->
          horizon = 1 + :rand.uniform(9)
          {:ok, s0} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: horizon)

          # churn: random interleaving of successful mutations until refusal
          {status, s_final} = churn(s0, domain, horizon, :rand)

          # the loop can only end on the typed exhaustion -- never a crash,
          # never an {:ok, _} past the horizon
          assert {:horizon_exceeded, ^horizon, witness} = status,
                 "iteration #{i}: expected typed exhaustion at horizon #{horizon}, " <>
                   "got #{inspect(status)}"

          assert is_binary(witness) and String.length(witness) == 64
          assert PolicySupervisor.horizon_exceeded?(s_final)
          assert s_final.attempts == horizon

          # never bypassed: every further mutation is the same typed refusal,
          # deterministic witness (no-drift fingerprint)
          assert {:error, {:horizon_exceeded, ^horizon, ^witness}} =
                   PolicySupervisor.observe(s_final, s_final.epoch, :pending)

          assert {:error, {:horizon_exceeded, ^horizon, ^witness}} =
                   PolicySupervisor.replace_domain(s_final, domain)

          horizon
        end)

      # sanity: the burn actually swept a range of horizons, not one path
      assert length(exhaustion_k) == 1000
      assert Enum.uniq(exhaustion_k) |> length() > 1
    end

    test "stale-epoch probes interleaved into the churn never consume budget" do
      :rand.seed(:exsss, {2, 2026, 104})
      {:ok, domain} = looping_domain()
      {:ok, s0} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 4)

      # 50 stale-epoch refusals interleaved with 3 real observations
      s =
        Enum.reduce(1..50, s0, fn _i, s ->
          assert {:error, {:stale_epoch, _, _}} =
                   PolicySupervisor.observe(s, s.epoch + 1000, :pending)

          assert s.attempts == attempts_before(s)

          case s.attempts do
            a when a < 3 ->
              assert {:ok, s1} = PolicySupervisor.observe(s, s.epoch, :pending)
              s1

            _ ->
              s
          end
        end)

      assert s.attempts == 3
      refute PolicySupervisor.horizon_exceeded?(s)

      # the budget is exactly 3 consumed: one more consumes, the next refuses
      assert {:ok, s5} = PolicySupervisor.observe(s, s.epoch, :pending)
      assert {:error, {:horizon_exceeded, 4, witness}} =
               PolicySupervisor.observe(s5, s5.epoch, :pending)

      assert String.length(witness) == 64
    end

    # Random mutation walk. Returns {typed_exhaustion, final_supervisor}.
    defp churn(s, domain, horizon, _rand) do
      case PolicySupervisor.observe(s, s.epoch, :pending) do
        {:ok, s1} ->
          case :rand.uniform(3) do
            1 ->
              # interleave a reconstruction (also one attempt on success)
              case PolicySupervisor.replace_domain(s1, domain) do
                {:ok, s2} -> churn(s2, domain, horizon, :rand)
                {:error, {:horizon_exceeded, _, _} = exhausted} -> {exhausted, s1}
                other -> flunk("unexpected replace_domain result: #{inspect(other)}")
              end

            _ ->
              churn(s1, domain, horizon, :rand)
          end

        {:error, {:horizon_exceeded, _k, _w} = exhausted} ->
          {exhausted, s}

        other ->
          flunk("unexpected non-typed result mid-churn: #{inspect(other)}")
      end
    end
  end

  describe "failed mutations never consume budget" do
    test "a failed reconstruction (unsynthesizable domain) returns an error and burns nothing" do
      {:ok, dead} = dead_end_domain()
      {:ok, domain} = looping_domain()
      {:ok, s0} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 3)

      # every replace_domain against the dead-end domain fails synthesis
      Enum.reduce(1..10, s0, fn _i, s ->
        refute PolicySupervisor.horizon_exceeded?(s)
        assert s.attempts == 0

        assert {:error, reason} = PolicySupervisor.replace_domain(s, dead)
        refute match?({:horizon_exceeded, _, _}, reason)

        s
      end)

      # the untouched budget still admits exactly 3 real mutations
      s = s0

      assert {:ok, s1} = PolicySupervisor.observe(s, s.epoch, :pending)
      assert {:ok, s2} = PolicySupervisor.observe(s1, s1.epoch, :pending)
      assert {:ok, s3} = PolicySupervisor.observe(s2, s2.epoch, :pending)
      assert s3.attempts == 3

      assert {:error, {:horizon_exceeded, 3, _}} =
               PolicySupervisor.observe(s3, s3.epoch, :pending)
    end

    test "an unadmitted outcome burns nothing, admitted ones burn exactly the horizon" do
      {:ok, domain} = looping_domain()
      {:ok, s0} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 2)

      Enum.each(1..10, fn _ ->
        assert {:error, {:unadmitted_outcome, :pending, :impossible}} =
                 PolicySupervisor.observe(s0, 0, :impossible)

        assert s0.attempts == 0
        refute PolicySupervisor.horizon_exceeded?(s0)
      end)

      # only real admitted observations consumed the horizon
      assert {:ok, s1} = PolicySupervisor.observe(s0, 0, :pending)
      assert {:ok, s2} = PolicySupervisor.observe(s1, 1, :pending)
      assert s2.attempts == 2

      # exhaustion outranks even another unadmitted outcome
      assert {:error, {:horizon_exceeded, 2, _}} =
               PolicySupervisor.observe(s2, 2, :impossible)
    end
  end

  describe "horizon: 0 -- born exhausted" do
    test "the first observe is refused before any outcome check" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 0)

      assert s.attempts == 0 and s.horizon == 0
      assert PolicySupervisor.horizon_exceeded?(s)

      # admitted outcome, unadmitted outcome, reconstruction: all the same
      # typed refusal, deterministic witness
      assert {:error, {:horizon_exceeded, 0, w1}} = PolicySupervisor.observe(s, 0, :pending)
      assert {:error, {:horizon_exceeded, 0, ^w1}} = PolicySupervisor.observe(s, 0, :impossible)

      assert {:error, {:horizon_exceeded, 0, ^w1}} =
               PolicySupervisor.replace_domain(s, domain)

      assert is_binary(w1) and String.length(w1) == 64
    end
  end

  describe "PolicySwitch -- the two-mode sweep cannot exhaust the default horizon" do
    test "both modes failing lands on :no_admitted_policy, never the horizon (2 < 9)" do
      {:ok, domain} = FOND.new(%{pending: %{fail: [:dead]}, dead: %{}, done: %{}}, [:done])

      # 200 repeats: the bound is structural, not lucky
      Enum.each(1..200, fn _i ->
        assert {:error, %{reason: :no_admitted_policy, attempted_modes: modes}} =
                 PolicySwitch.select(domain, :pending)

        assert Enum.all?(modes, fn {mode, _reason} -> mode in [:strong, :strong_cyclic] end)
        assert length(modes) == 2
        assert length(modes) < 9
      end)
    end

    test "the bound holds even with duplicate modes in the sweep list" do
      {:ok, domain} = FOND.new(%{pending: %{fail: [:dead]}, dead: %{}, done: %{}}, [:done])

      # 8 failing attempts < horizon 9: still :no_admitted_policy, not exhaustion
      assert {:error, %{reason: :no_admitted_policy, attempted_modes: modes}} =
               PolicySwitch.select(domain, :pending,
                 modes: List.duplicate(:strong, 4) ++ List.duplicate(:strong_cyclic, 4)
               )

      assert length(modes) == 8

      # exactly 9 failing modes with horizon 9: the sweep has consumed the
      # horizon, so it refuses with the typed error at exactly horizon
      # (the exhaustion check fires on the attempt that consumes it)
      assert {:error, {:horizon_exceeded, 9, witness9}} =
               PolicySwitch.select(domain, :pending, modes: List.duplicate(:strong, 9))

      assert String.length(witness9) == 64

      # the 10th failing attempt never runs: the sweep already refused at 9
      assert {:error, {:horizon_exceeded, 9, witness}} =
               PolicySwitch.select(domain, :pending,
                 modes:
                   List.duplicate(:strong, 4) ++
                     List.duplicate(:strong_cyclic, 4) ++ [:strong, :strong]
               )

      assert String.length(witness) == 64
    end

    test "a successful sweep inside the horizon never reports exhaustion" do
      {:ok, domain} = FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

      Enum.each(1..100, fn _i ->
        assert {:ok, %{mode: :strong_cyclic, attempts: attempts}} =
                 PolicySwitch.select(domain, :pending)

        assert length(attempts) == 1
        assert length(attempts) < 9
      end)
    end
  end

  # s at that point still carries its pre-call attempts (s is immutable);
  # read it before the refusal assertion above consumed nothing.
  defp attempts_before(%PolicySupervisor{attempts: a}), do: a
end
