defmodule AshPPlan.FOND.TLA.Mutation do
  @moduledoc """
  Deterministic negative mutations for the rendered FOND/TLA contract.

  Mutants are test inputs. They are never admitted projections.
  """

  @spec suite(map()) :: [{atom(), map()}]
  def suite(%{module: module, cfg: cfg} = rendered) do
    [
      {:drop_goal_property, %{rendered | cfg: String.replace(cfg, "PROPERTY GoalReached\n", "")}},
      {:weaken_strong_fairness, mutate_first_sf(rendered)},
      {:stutter_first_tick, %{rendered | module: replace_first(module, "tick' = 1 - tick", "tick' = tick")}},
      {:drop_first_branch, %{rendered | module: drop_first_branch_definition(module)}},
      {:undefined_next_action, %{rendered | module: String.replace(module, "Next ==\n", "Next ==\n  \\/ A_999999\n", global: false)}}
    ]
  end

  defp mutate_first_sf(%{module: module} = rendered) do
    %{rendered | module: Regex.replace(~r/SF_vars\(/, module, "WF_vars(", global: false)}
  end

  defp replace_first(text, from, to), do: String.replace(text, from, to, global: false)

  defp drop_first_branch_definition(module) do
    Regex.replace(
      ~r/^B_\d+_\d+ == .*\n/m,
      module,
      "",
      global: false
    )
  end
end
