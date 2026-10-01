defmodule AshPPlan.Test.Chaos.Sabotage do
  @moduledoc """
  Anti-vacuity helper: rewrites a good observation so that exactly one named invariant is
  violated. A check that still answers `:ok` for the sabotaged observation is vacuous.
  """

  @spec violate(atom(), map()) :: map()
  def violate(:at_most_once, o), do: %{o | final_counts: Map.put(o.final_counts, {:t, 0}, 2)}

  def violate(:replay_identity, o),
    do: %{o | final_status: :completed, after_probe: %{o.after_probe | counts: %{{:t, 0} => 9}}}

  def violate(:terminal_absorbing, o),
    do: %{o | after_probe: %{o.after_probe | status: :pending}}

  def violate(:no_lost_wakeup, o), do: %{o | cancel: nil, final_status: :waiting}

  def violate(:standing_unique, o),
    do: %{o | after_probe: %{o.after_probe | step_keys: [:k, :k]}}

  def violate(:cancel_sticky, o) do
    %{
      o
      | cancel: :accepted,
        trace: [%{op: :cancel, status: :completed, counts: %{}, cancel: :accepted, tape: []}],
        final_status: :completed
    }
  end
end
