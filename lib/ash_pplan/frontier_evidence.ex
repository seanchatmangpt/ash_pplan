defmodule AshPPlan.FrontierEvidence do
  @moduledoc """
  Deterministic FrontierEvidence v1 projection for ash_pplan control-plane data.

  The input descriptors and FOND validation results must already exist. This
  adapter performs no Ash action, lifecycle transition, Oban insertion/schedule,
  Reactor execution, or continuation resume. It preserves ash_pplan's descriptive
  SELECT/CONSTRUCT boundary while making that evidence portable to a downstream
  admission court.
  """

  @schema "frontier-evidence/v1"
  @producer "ash_pplan"
  @authority_ceiling "CONSTRUCT"

  @spec from_control_plane(map(), term(), keyword()) :: map()
  def from_control_plane(control_plane, fond_validation, opts \\ []) when is_map(control_plane) do
    producer_head = Keyword.fetch!(opts, :producer_head)
    standing = Keyword.get(opts, :standing, "CANDIDATE")

    evidence = %{
      control_plane: canonical_term(control_plane),
      fond_validation: canonical_term(fond_validation)
    }

    body = %{
      schema: @schema,
      producer: @producer,
      producer_head: producer_head,
      standing: standing,
      authority_ceiling: @authority_ceiling,
      evidence: evidence,
      refused: [
        "ash_action_execution",
        "state_transition",
        "oban_insert",
        "oban_schedule",
        "reactor_execution",
        "actuation_authority"
      ]
    }

    Map.put(body, :artifact_hash, fingerprint(body))
  end

  defp fingerprint(term) do
    term
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp canonical_term(%_{} = struct), do: struct |> Map.from_struct() |> canonical_term()

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)

  defp canonical_term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&canonical_term/1)

  defp canonical_term(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp canonical_term(other), do: other
end
