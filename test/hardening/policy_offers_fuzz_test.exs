defmodule AshPPlan.FOND.PolicySupervisor.OffersFuzzTest do
  @moduledoc """
  Fuzz court: `AshPPlan.FOND.PolicySupervisor.Offers` under hostile offer
  shapes, kill storms, and offer starvation. Typed refusals, never raise,
  `authority: :none` on every admitted action/event.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.PolicySupervisor.Offers

  defp domain do
    {:ok, d} =
      FOND.new(
        %{
          pending: %{attempt: [:pending, :done]},
          other: %{},
          done: %{}
        },
        [:done]
      )

    d
  end

  defp policy, do: %{pending: :attempt}

  defp offer(provider \\ :p1, extra \\ []) do
    Map.merge(%{provider: provider, policy: policy(), mode: :strong_cyclic}, Map.new(extra))
  end

  defp supervisor(offers \\ [offer()]) do
    {:ok, s} = Offers.new(domain(), :pending, offers)
    s
  end

  defp total(fun) do
    result =
      try do
        fun.()
      rescue
        e -> {:raise, Exception.message(e), __STACKTRACE__}
      catch
        kind, value -> {:raise, {kind, value}, __STACKTRACE__}
      end

    assert not match?({:raise, _, _}, result), "raised: #{inspect(result, limit: 3)}"
    result
  end

  describe "new/3 under hostile offers" do
    test "malformed offer lists never raise" do
      hostile = [
        [],
        [nil],
        [:atom],
        [42],
        ["str"],
        [%{}],
        [%{provider: nil, policy: %{pending: :attempt}}],
        [%{provider: :p1}],
        [%{provider: :p1, policy: :garbage}],
        [%{provider: :p1, policy: %{unknown_state: :attempt}}],
        [%{provider: :p1, policy: %{pending: :unknown_action}}],
        [%{provider: :p1, policy: %{pending: :attempt}, mode: :unknown_mode}],
        [%{provider: :p1, policy: %{pending: :attempt}, cost: "free"}],
        [%{provider: :p1, policy: %{pending: :attempt}, cost: nil}],
        [%{provider: :p1, policy: %{pending: :attempt}, authority: :root}],
        [offer(:p1), %{}],
        [offer(:p1), nil]
      ]

      for offers <- hostile do
        result = total(fn -> Offers.new(domain(), :pending, offers) end)

        case result do
          {:ok, s} ->
            assert s.provider in [:p1, :p2]
            assert is_map(s.policy)

          {:error, _reason} ->
            :ok
        end
      end
    end

    test "unknown initial state refused, not raised" do
      assert {:error, {:unknown_state, :nope}} = Offers.new(domain(), :nope, [offer()])
    end

    test "starvation: empty list refused with :no_admissible_policy" do
      assert {:error, :no_admissible_policy} = Offers.new(domain(), :pending, [])
    end

    test "hand-built malformed FOND struct refused, not raised" do
      bad_domain = %FOND{states: nil, goals: MapSet.new([:done]), transitions: %{}}
      result = total(fn -> Offers.new(bad_domain, :pending, [offer()]) end)
      assert match?({:error, _}, result)
    end
  end

  describe "select/3 hostility" do
    test "select is total over garbage offer lists" do
      garbage = [nil, :atom, 42, "x", [], %{subject: 1}, offer(:p1)]

      result = total(fn -> Offers.select(domain(), :pending, garbage) end)
      assert {:ok, chosen} = result
      assert chosen == offer(:p1)
    end

    test "all-garbage list starves with typed refusal" do
      assert {:error, :no_admissible_policy} =
               Offers.select(domain(), :pending, [nil, 42, :atom, %{}])
    end
  end

  describe "kill storm: provider_down / reselect / observe under attack" do
    test "killing the only provider starves with typed refusal and preserves state" do
      s = supervisor([offer(:p1)])

      assert {:error, :no_admissible_policy} = Offers.provider_down(s, :p1)

      # state must be unchanged after a refused transition
      assert s.epoch == 0
      assert s.provider == :p1
    end

    test "kill storm across many providers keeps typed refusals and epochs intact" do
      s =
        supervisor([
          offer(:p1),
          offer(:p2, cost: 1),
          offer(:p3, cost: 2)
        ])

      # lowest cost wins
      assert s.provider == :p1

      {:ok, s1} = Offers.provider_down(s, :p1)
      assert s1.provider == :p2
      assert s1.epoch == 1

      {:ok, s2} = Offers.provider_down(s1, :p2)
      assert s2.provider == :p3
      assert s2.epoch == 2

      # killing an absent provider is a no-op delete + reselect from survivors
      {:ok, s2b} = Offers.provider_down(s2, :absent)
      assert s2b.provider == :p3
      assert s2b.epoch == 3

      # final kill starves but leaves the surviving supervisor intact
      assert {:error, :no_admissible_policy} = Offers.provider_down(s2, :p3)
      assert s2.provider == :p3

      {:ok, s3} = Offers.add_provider(s2, offer(:p4))
      assert Map.has_key?(s3.providers, :p4)

      {:ok, s4} = Offers.provider_down(s3, :p3)
      assert s4.provider == :p4
      assert s4.epoch == 3
    end

    test "hostile reselect on starved supervisor is a typed refusal" do
      s = supervisor([offer(:p1)])
      starved = %{s | providers: %{}}

      assert {:error, :no_admissible_policy} = Offers.reselect(starved)
    end
  end

  describe "observe / next_action hostility" do
    test "observe refuses stale epoch, unknown outcome, stale action, impossible outcome" do
      s = supervisor()

      assert {:error, {:stale_epoch, 99, 0}} = Offers.observe(s, 99, :attempt, :pending)
      assert {:error, {:unknown_outcome, :nowhere}} = Offers.observe(s, 0, :attempt, :nowhere)
      assert {:error, {:stale_action, :nope, :pending}} = Offers.observe(s, 0, :nope, :pending)

      # :other is a declared state but not an outcome of pending × attempt
      assert {:error, {:impossible_outcome, :other}} = Offers.observe(s, 0, :attempt, :other)

      # reaching the goal succeeds even though the goal has no policy entry
      assert {:ok, :goal, _} = Offers.observe(s, 0, :attempt, :done)
    end

    test "successful observe keeps authority :none on the next action" do
      s = supervisor()
      assert {:ok, :continue, s1} = Offers.observe(s, 0, :attempt, :pending)
      assert {:ok, %{action: :attempt, authority: :none}} = Offers.next_action(s1)
      assert {:ok, :goal, _} = Offers.observe(s1, 0, :attempt, :done)
    end

    test "next_action on a state with no policy entry is a typed refusal" do
      s = supervisor()
      {:ok, :goal, s_goal} = Offers.observe(s, 0, :attempt, :done)
      assert {:error, {:no_policy_action, :done}} = Offers.next_action(s_goal)
    end
  end

  describe "event/3 and add_provider hostility" do
    test "event always carries authority :none" do
      s = supervisor()
      ev = Offers.event(s, :observe, %{any: :attrs})
      assert %{authority: :none, provider: :p1, state: :pending, epoch: 0} = ev
    end

    test "add_provider with hostile offers is typed-refused, never raises" do
      s = supervisor()

      for bad <- [nil, :atom, 42, "x", [], %{}] do
        result = total(fn -> Offers.add_provider(s, bad) end)
        assert match?({:error, _}, result)
      end
    end

    test "add_provider with duplicate provider replaces the stored offer" do
      s = supervisor([offer(:p1)])
      {:ok, s1} = Offers.add_provider(s, offer(:p1, cost: 99))
      assert s1.providers[:p1][:cost] == 99
    end
  end

  describe "reselect rank ordering" do
    test "strong mode outranks strong_cyclic even at higher cost" do
      # a deterministic domain admits both :strong and :strong_cyclic policies
      {:ok, det} = FOND.new(%{a: %{go: [:b]}, b: %{}}, [:b])

      {:ok, s} =
        Offers.new(det, :a, [
          offer(:weak, cost: 0, mode: :strong_cyclic, policy: %{a: :go}),
          offer(:strong, cost: 99, mode: :strong, policy: %{a: :go})
        ])

      assert s.provider == :strong
    end
  end
end
