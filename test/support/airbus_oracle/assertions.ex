defmodule AshPPlan.Test.AirbusOracle.Assertions do
  @moduledoc """
  ExUnit assertions for cross-engine mathematical and behavioral parity checking
  between Airbus deliberation outputs and native `ash_pplan` policies.
  """

  import ExUnit.Assertions

  @doc """
  Asserts that an Airbus policy map and an `AshPPlan.FOND` policy map select
  semantically equivalent actions for every reachable state.
  """
  def assert_policy_parity(airbus_policy, ash_policy, domain) do
    # Normalize keys to strings or atoms
    airbus_norm =
      Map.new(airbus_policy, fn {k, v} -> {to_string(k), to_string(v)} end)

    ash_norm =
      Map.new(ash_policy, fn {k, v} -> {to_string(k), to_string(v)} end)

    assert Map.keys(airbus_norm) == Map.keys(ash_norm),
           """
           POLICY DOMAIN REACHABILITY MISMATCH:
             Airbus states: #{inspect(Map.keys(airbus_norm))}
             Ash states:    #{inspect(Map.keys(ash_norm))}
             Domain:        #{inspect(domain)}
           """

    for {state, airbus_action} <- airbus_norm do
      ash_action = Map.get(ash_norm, state)

      assert airbus_action == ash_action,
             """
             POLICY ACTION SELECTION DIVERGENCE at state '#{state}':
               Airbus selected: #{airbus_action}
               Ash selected:    #{ash_action}
             """
    end

    :ok
  end

  @doc """
  Asserts bit-for-bit winning region equivalence (Solvable_A == Solvable_E).
  """
  def assert_winning_region_parity(airbus_winning_region, ash_winning_region) do
    airbus_set = airbus_winning_region |> Enum.map(&to_string/1) |> MapSet.new()
    ash_set = ash_winning_region |> Enum.map(&to_string/1) |> MapSet.new()

    assert MapSet.equal?(airbus_set, ash_set),
           """
           WINNING REGION PARITY VIOLATION:
             Airbus solvable: #{inspect(MapSet.to_list(airbus_set))}
             Ash solvable:    #{inspect(MapSet.to_list(ash_set))}
             Difference A\\E:  #{inspect(MapSet.difference(airbus_set, ash_set) |> MapSet.to_list())}
             Difference E\\A:  #{inspect(MapSet.difference(ash_set, airbus_set) |> MapSet.to_list())}
           """

    :ok
  end

  @doc """
  Asserts that deadlock witnesses match when a domain is deemed unsolvable.
  """
  def assert_witness_parity(airbus_witness, ash_witness) do
    airbus_sorted = airbus_witness |> Enum.map(&to_string/1) |> Enum.sort()
    ash_sorted = ash_witness |> Enum.map(&to_string/1) |> Enum.sort()

    assert airbus_sorted == ash_sorted,
           """
           DEADLOCK WITNESS MISMATCH:
             Airbus witness: #{inspect(airbus_sorted)}
             Ash witness:    #{inspect(ash_sorted)}
           """

    :ok
  end

  @doc """
  Asserts that STNU Dynamic Controllability verdicts match between engines.
  """
  def assert_stnu_dc_parity(airbus_dc_result, ash_dc_result) do
    a_dc = Map.get(airbus_dc_result, "dynamically_controllable", false)
    e_dc = Map.get(ash_dc_result, :dynamically_controllable, false)

    assert a_dc == e_dc,
           """
           STNU DYNAMIC CONTROLLABILITY DIVERGENCE:
             Airbus verdict: #{inspect(a_dc)}
             Ash verdict:    #{inspect(e_dc)}
             Conflicts:      #{inspect(Map.get(airbus_dc_result, "conflicts"))}
           """

    :ok
  end
end
