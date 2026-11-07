defmodule AshPPlan.Hardening.ConfigFailClosedTest do
  @moduledoc """
  P19 lane W5: fail-closed config seams. `async: false` because the seams read
  and mutate application environment that other suites consume.
  """

  use ExUnit.Case, async: false

  # ---- Config fail-closed seams (P19) ----------------------------------------------------------

  describe "config fail-closed seams" do
    test "digest_module nil is a raised misconfiguration, not a silent default" do
      previous = Application.get_env(:ash_pplan, :digest_module)

      Application.put_env(:ash_pplan, :digest_module, nil)

      assert_raise ArgumentError, ~r/misconfiguration/, fn ->
        AshPPlan.Config.digest_module()
      end
    after
      if previous do
        Application.put_env(:ash_pplan, :digest_module, previous)
      else
        Application.delete_env(:ash_pplan, :digest_module)
      end
    end

    test "explicit nil durable_store_module refuses tagged, unset keeps the ETS default" do
      previous = Application.get_env(:ash_pplan, :durable_store_module)

      Application.put_env(:ash_pplan, :durable_store_module, nil)

      assert {:error, %{reason: :durable_store_unconfigured}} =
               AshPPlan.Config.durable_store_module()

      assert {:error, %{reason: :durable_store_unconfigured}} =
               AshPPlan.Reactor.Durable.Run.store_module([])

      Application.delete_env(:ash_pplan, :durable_store_module)
      assert {:ok, AshPPlan.Reactor.Durable.Store.Ets} = AshPPlan.Config.durable_store_module()

      assert {:ok, AshPPlan.Reactor.Durable.Store.Ets} =
               AshPPlan.Reactor.Durable.Run.store_module([])
    after
      if previous do
        Application.put_env(:ash_pplan, :durable_store_module, previous)
      else
        Application.delete_env(:ash_pplan, :durable_store_module)
      end
    end

    test "durable_halt_timeout non-pos-integer raises ArgumentError at the seam" do
      previous = Application.get_env(:ash_pplan, :durable_halt_timeout)

      Application.put_env(:ash_pplan, :durable_halt_timeout, 0)

      assert_raise ArgumentError, ~r/durable_halt_timeout/, fn ->
        AshPPlan.Config.durable_halt_timeout()
      end

      Application.put_env(:ash_pplan, :durable_halt_timeout, "five")

      assert_raise ArgumentError, ~r/durable_halt_timeout/, fn ->
        AshPPlan.Config.durable_halt_timeout()
      end
    after
      if previous do
        Application.put_env(:ash_pplan, :durable_halt_timeout, previous)
      else
        Application.delete_env(:ash_pplan, :durable_halt_timeout)
      end
    end

    test "standing_flight_timeout_ms non-pos-integer raises ArgumentError at the seam" do
      previous = Application.get_env(:ash_pplan, :standing_flight_timeout_ms)

      Application.put_env(:ash_pplan, :standing_flight_timeout_ms, -1)

      assert_raise ArgumentError, ~r/standing_flight_timeout_ms/, fn ->
        AshPPlan.Config.standing_flight_timeout_ms()
      end
    after
      if previous do
        Application.put_env(:ash_pplan, :standing_flight_timeout_ms, previous)
      else
        Application.delete_env(:ash_pplan, :standing_flight_timeout_ms)
      end
    end
  end

  defp restore(key, previous) do
    if previous do
      Application.put_env(:ash_pplan, key, previous)
    else
      Application.delete_env(:ash_pplan, key)
    end
  end
end
