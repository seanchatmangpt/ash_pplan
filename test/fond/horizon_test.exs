defmodule AshPPlan.FONDHorizonTest do
  @moduledoc """
  The FOND epistemic horizon (K_max, loops-of-loops spec L4): the
  PolicySupervisor's reconstruction horizon, the PolicySwitch mode-sweep
  horizon and the Recovery route of the typed exhaustion. Real collaborators
  only -- every module here is pure; nothing is doubled.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{PolicySupervisor, PolicySwitch, Recovery}

  # The plan-next promote-stick shape: `promote` may stick (:pending is one
  # of its own outcomes), so an observation of :pending can repeat forever
  # and the horizon is the only stop. Only :strong_cyclic admits it.
  defp looping_domain do
    FOND.new(%{pending: %{promote: [:done, :pending]}, done: %{}}, [:done])
  end

  describe "PolicySupervisor -- the reconstruction horizon" do
    test "default horizon is 9, default attempts 0" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending)

      assert s.horizon == 9
      assert s.attempts == 0
      refute PolicySupervisor.horizon_exceeded?(s)
    end

    test "observe admits up to the horizon, then refuses {:horizon_exceeded, k, witness}" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 2)

      assert {:ok, s1} = PolicySupervisor.observe(s, 0, :pending)
      assert s1.attempts == 1
      assert s1.epoch == 1
      refute PolicySupervisor.horizon_exceeded?(s1)

      assert {:ok, s2} = PolicySupervisor.observe(s1, 1, :pending)
      assert s2.attempts == 2
      assert PolicySupervisor.horizon_exceeded?(s2)

      # exhaustion: typed refusal, k = the horizon, witness a sha256 hex
      assert {:error, {:horizon_exceeded, 2, witness}} =
               PolicySupervisor.observe(s2, 2, :pending)

      assert is_binary(witness)
      assert String.length(witness) == 64

      # the witness is the no-drift fingerprint: the same exhausted state
      # reproduces it, a different one moves it
      assert {:error, {:horizon_exceeded, 2, witness}} =
               PolicySupervisor.observe(s2, 2, :pending)

      assert {:error, {:horizon_exceeded, 3, other}} =
               PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 3)
               |> then(fn {:ok, s3} ->
                 {:ok, s3} = PolicySupervisor.observe(s3, 0, :pending)
                 {:ok, s3} = PolicySupervisor.observe(s3, 1, :pending)
                 {:ok, s3} = PolicySupervisor.observe(s3, 2, :pending)
                 PolicySupervisor.observe(s3, 3, :pending)
               end)

      refute witness == other
    end

    test "exhaustion outranks unadmitted outcomes: the typed horizon refusal is deterministic" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 1)

      assert {:ok, s1} = PolicySupervisor.observe(s, 0, :pending)
      assert PolicySupervisor.horizon_exceeded?(s1)

      # even a bogus outcome cannot preempt the horizon verdict
      assert {:error, {:horizon_exceeded, 1, _witness}} =
               PolicySupervisor.observe(s1, 1, :impossible_state)
    end

    test "the goal case: start/observe over a solved domain still honors the horizon" do
      {:ok, d} = FOND.new(%{start: %{go: [:done]}, done: %{}}, [:done])
      {:ok, s} = PolicySupervisor.start(d, :start, :strong_cyclic, horizon: 1)

      assert {:ok, s1} = PolicySupervisor.observe(s, 0, :done)
      assert PolicySupervisor.horizon_exceeded?(s1)

      assert {:error, {:horizon_exceeded, 1, _}} = PolicySupervisor.observe(s1, 1, :done)
    end

    test "stale-epoch fencing still wins over the horizon" do
      {:ok, domain} = looping_domain()
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic, horizon: 0)

      assert {:error, {:stale_epoch, 5, 0}} = PolicySupervisor.observe(s, 5, :pending)
    end
  end

  describe "PolicySwitch -- the mode-sweep horizon" do
    test "default sweep is unchanged (2 modes < default horizon 9)" do
      {:ok, domain} = FOND.new(%{pending: %{fail: [:dead]}, dead: %{}, done: %{}}, [:done])

      assert {:error, %{reason: :no_admitted_policy, attempted_modes: modes}} =
               PolicySwitch.select(domain, :pending)

      assert length(modes) == 2
    end

    test "horizon: 1 stops after the first failed mode with the typed exhaustion" do
      # no mode solves :pending here, so every attempt is a failure and the
      # sweep can only exhaust
      {:ok, domain} = FOND.new(%{pending: %{fail: [:dead]}, dead: %{}, done: %{}}, [:done])

      assert {:error, {:horizon_exceeded, 1, witness}} =
               PolicySwitch.select(domain, :pending, horizon: 1)

      assert is_binary(witness) and String.length(witness) == 64

      # deterministic: the same sweep reproduces the same witness
      assert {:error, {:horizon_exceeded, 1, witness}} =
               PolicySwitch.select(domain, :pending, horizon: 1)

      # a different (longer) sweep moves it: three modes over horizon 2 --
      # two failures consume the budget, the third mode is refused by the
      # horizon, not attempted
      assert {:error, {:horizon_exceeded, 2, other}} =
               PolicySwitch.select(domain, :pending,
                 horizon: 2,
                 modes: [:strong, :strong_cyclic, :strong]
               )

      refute witness == other
    end

    test "a sweep that succeeds inside the horizon is unaffected" do
      # :strong admits immediately -- one attempt, inside any horizon >= 1
      {:ok, strong_domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])
      assert {:ok, %{mode: :strong}} = PolicySwitch.select(strong_domain, :pending, horizon: 1)

      # the fallback consumed its budget and still made it: :strong fails
      # (attempt 1), :strong_cyclic admits (attempt 2 of horizon 2)
      {:ok, domain} =
        FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

      assert {:ok, %{mode: :strong_cyclic}} = PolicySwitch.select(domain, :pending, horizon: 2)
    end
  end

  describe "Recovery -- routing the typed exhaustion" do
    test "the horizon refusal routes to :epistemic_horizon, subject preserved" do
      route = Recovery.route({:error, {:horizon_exceeded, 9, "witnesshex"}})

      assert route.action == :epistemic_horizon
      assert route.horizon == 9
      assert route.witness == "witnesshex"
      assert route.preserve_subject
    end

    test "the horizon clause does not disturb the existing routes" do
      assert Recovery.route({:error, {:unsolvable, :strong, [:x]}}).action ==
               :respecify_or_expand_domain

      assert Recovery.route(%{reason: :not_strong}).action == :try_strong_cyclic
      refute Recovery.route(%{reason: :unknown_initial_state}).preserve_subject
    end

    test "the typed supervisor refusals route with preserve_subject" do
      assert Recovery.route({:error, {:missing_policy_action, :pending}}).preserve_subject

      assert Recovery.route({:error, {:missing_policy_action, :pending}}).action ==
               :resynthesize

      assert Recovery.route({:error, {:unadmitted_outcome, :pending, :boom}}).preserve_subject

      assert Recovery.route({:error, {:unadmitted_outcome, :pending, :boom}}).action ==
               :resynthesize
    end
  end

  describe "PolicySupervisor -- failed synthesis consumes the horizon" do
    # From :limbo no strong policy exists (non-goal dead end), so an observe
    # INTO :limbo under :strong mode is a failed synthesis attempt. The
    # supervisor is hand-built from the pure struct: no synthesized policy can
    # admit a losing outcome, so this is the only way to reach the branch --
    # the struct is data, not a mock.
    defp losing_supervisor(horizon) do
      {:ok, domain} = FOND.new(%{pending: %{go: [:done, :limbo]}, limbo: %{}}, [:done])

      %PolicySupervisor{
        domain: domain,
        state: :pending,
        mode: :strong,
        policy: %{pending: :go},
        epoch: 0,
        horizon: horizon,
        attempts: 0
      }
    end

    test "a failed synthesis returns the incremented attempts in the error payload" do
      sup = losing_supervisor(9)

      assert {:error, {:synthesis_failed, {:unsolvable, :strong, [:limbo]}, burned}} =
               PolicySupervisor.observe(sup, 0, :limbo)

      # the burn lives in the returned supervisor, so a caller re-submitting
      # `burned` accumulates budget consumption across calls
      assert burned.attempts == 1

      refute PolicySupervisor.horizon_exceeded?(sup)
    end

    test "repeated failed synthesis is bounded: the horizon refusal arrives at K_max" do
      sup = losing_supervisor(3)

      # A bounded loop: each failed observe consumes one attempt; the loop
      # must terminate on the typed refusal within the horizon, never spin.
      {final, result} =
        Enum.reduce_while(1..50, {sup, nil}, fn _i, {supervisor, acc} ->
          case PolicySupervisor.observe(supervisor, supervisor.epoch, :limbo) do
            {:ok, next} ->
              {:cont, {next, acc}}

            # the failed attempt consumed budget; the returned supervisor
            # carries the burn — re-submit it to accumulate
            {:error, {:synthesis_failed, _reason, burned}} ->
              {:cont, {burned, acc}}

            {:error, _} = err ->
              {:halt, {supervisor, err}}
          end
        end)

      assert {:error, {:horizon_exceeded, 3, witness}} = result
      assert is_binary(witness)

      # the refusal arrived on the third call: `final` is the struct as it
      # entered that call (2 attempts consumed on it); the third call itself
      # consumed the last budget unit (attempts 3 in the refusal, horizon 3)
      assert final.attempts == 2
      refute PolicySupervisor.horizon_exceeded?(final)
    end

    test "goals do not need a policy entry: observe of a goal outcome still synthesizes" do
      {:ok, domain} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])
      {:ok, s} = PolicySupervisor.start(domain, :pending, :strong_cyclic)
      assert {:ok, s1} = PolicySupervisor.observe(s, 0, :done)
      assert s1.state == :done
    end
  end
end
