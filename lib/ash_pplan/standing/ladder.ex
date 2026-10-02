defmodule AshPPlan.Standing.Ladder do
  @moduledoc """
  The fixed 10-state evidentiary standing ladder, adopted from
  `ggen-marketplace/packs/standing-ladder-pack` (`stl:` ontology, proven in ex4pm).

      UNKNOWN(0) -> OBSERVED(1) -> VALIDATED(2) -> DERIVED(3) -> CANDIDATE(4)
      -> EXPERIMENTALLY_SUPPORTED(5) -> ADMITTED(6) -> MANUFACTURED(7) -> ACTUATED(8)
      -> VERIFIED(9)

  Law (pack gates/010_no_skipped_states.rq): a claim's current standing is not
  self-certifying. It is admissible only through a real, evidenced, single-rung
  transition chain reaching it from `:UNKNOWN` -- no skipped rungs, no empty
  evidence references. `admit/1` enforces this law on a supplied chain;
  `AshPPlan.Standing.ladder/1` derives the highest rung reachable from a run's
  real evidence and returns the single-rung audit trail.

  Deliberately out of scope (as in the pack): no automatic promotion authority.
  Nothing here grants DO authority; the ladder reads evidence, it never
  manufactures it.
  """

  @states [
    :UNKNOWN,
    :OBSERVED,
    :VALIDATED,
    :DERIVED,
    :CANDIDATE,
    :EXPERIMENTALLY_SUPPORTED,
    :ADMITTED,
    :MANUFACTURED,
    :ACTUATED,
    :VERIFIED
  ]

  @type state ::
          :UNKNOWN
          | :OBSERVED
          | :VALIDATED
          | :DERIVED
          | :CANDIDATE
          | :EXPERIMENTALLY_SUPPORTED
          | :ADMITTED
          | :MANUFACTURED
          | :ACTUATED
          | :VERIFIED

  @type transition :: %{
          required(:from) => state(),
          required(:to) => state(),
          required(:evidence) => String.t()
        }

  @type claim :: %{
          required(:fact) => term(),
          required(:state) => state(),
          required(:transitions) => [transition()]
        }

  @doc "The fixed 10 ladder states, in promotion order."
  @spec states() :: [state(), ...]
  def states, do: @states

  @doc """
  0-based index of a ladder state. Outside the closed set of 10 this is a
  refusal, not a fallback: `{:error, %{broken_term: "STL_unknown_state"}}`.
  """
  @spec index(state()) :: non_neg_integer() | {:error, map()}
  def index(state)
  def index(state) when state in @states, do: Enum.find_index(@states, &(&1 == state))

  def index(state),
    do: {:error, %{broken_term: "STL_unknown_state", reason: {:stl_unknown_state, state}}}

  @doc """
  Admit one claim's current standing against its transition chain (the
  `stl:` gate law). A claim is a map with:

    * `:fact` - what the standing is about (must be present; a dangling fact is refused)
    * `:state` - the claimed rung
    * `:transitions` - the promotion history, one map `%{from:, to:, evidence:}` per rung

  Returns `{:ok, %{fact:, state:, trail:}}` or
  `{:error, %{broken_term: "STL_missing_rung", missing_rung_index: k}}` when rung
  `k` (1-based) of the required chain has no valid supporting transition --
  mirroring gates/010_no_skipped_states.rq's two-column output. Each transition
  must be exactly one rung (`index(to) == index(from) + 1`) with a non-empty,
  specific `:evidence`; a chain must start from `:UNKNOWN`.
  """
  @spec admit(claim()) :: {:ok, %{fact: term(), state: state(), trail: [map()]}} | {:error, map()}
  def admit(%{fact: fact, state: state, transitions: transitions})
      when is_list(transitions) do
    cond do
      is_nil(fact) ->
        {:error, %{broken_term: "STL_dangling_fact", reason: :stl_dangling_fact}}

      state not in @states ->
        {:error, %{broken_term: "STL_unknown_state", reason: {:stl_unknown_state, state}}}

      true ->
        with {:ok, target} <- check_chain(transitions, state) do
          {:ok, %{fact: fact, state: target, trail: trail(transitions)}}
        end
    end
  end

  def admit(_claim),
    do: {:error, %{broken_term: "STL_malformed_claim", reason: :stl_malformed_claim}}

  # The required rungs are 1..index(state); rung k needs from=states[k-1], to=states[k].
  defp check_chain(transitions, state) do
    required = index(state)

    missing =
      Enum.find(1..required//1, fn k ->
        not Enum.any?(transitions, fn t ->
          valid_rung?(t, Enum.fetch!(@states, k - 1), Enum.fetch!(@states, k))
        end)
      end)

    if missing,
      do: {:error, %{broken_term: "STL_missing_rung", missing_rung_index: missing}},
      else: {:ok, state}
  end

  defp valid_rung?(%{from: from, to: to, evidence: ev}, from_state, to_state) do
    from == from_state and to == to_state and is_binary(ev) and String.trim(ev) != ""
  end

  defp valid_rung?(_, _, _), do: false

  defp trail(transitions) do
    transitions
    |> Enum.with_index(1)
    |> Enum.map(fn {t, order} -> Map.put(t, :order, order) end)
  end
end
