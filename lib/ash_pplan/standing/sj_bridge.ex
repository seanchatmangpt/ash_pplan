defmodule AshPPlan.Standing.SjBridge do
  @moduledoc """
  Bridge from the closed sj standing vocabulary (the 7 receipt standing bases) to
  ash_pplan's standing machinery, without ever granting standing.

  Two families, deliberately disjoint: an sj status is a string over
  `Receipt.standings/0`; a ladder rung is an atom over `Ladder.states/0`. The
  bridge's law: **the rung comes only from `Standing.ladder/2`** — a status
  never lifts a rung. An `ALIVE` status over an unevidenced run maps with value
  `ALIVE` but rung `:UNKNOWN`: the mismatch is visible data, never repaired.

  `terminal?/1` is exact: `BLOCKED` singleton.

  Parsing is refusive, not fuzzy: an unknown base is
  `{:error, %{reason: :sj_unknown_status, value: v}}`, a bare `REFUSED` (no
  layers) is `{:error, %{reason: :sj_refused_requires_layers, value: v}}`, and a
  layer outside `Standing.layers/0` is `{:error, %{reason: :sj_unknown_layer,
  value: v, layer: l}}`. `derived_from` is always present — `map/2` derives it
  from the closed vocabulary itself, `map/3` from the real `Standing.ladder/2`
  result. Nothing here lifts a ladder rung: `AshPPlan.Standing.Ladder` is
  untouched and remains the only rung authority.
  """

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Receipt

  @statuses Receipt.standings()

  @doc "The 7 closed sj status bases, alphabetical."
  @spec statuses() :: [String.t(), ...]
  def statuses, do: @statuses

  @doc "Terminal statuses: exactly `\"BLOCKED\"`."
  @spec terminal?(String.t()) :: boolean()
  def terminal?(status), do: status == "BLOCKED"

  @doc "The FOND terminal-outcome declaration matching `terminal?/1`."
  @spec terminal_outcomes() :: [String.t()]
  def terminal_outcomes, do: ["BLOCKED"]

  @doc """
  Map an sj status value to the bridge map (value family): no rung is consulted.
  `opts` is accepted for call-site uniformity and deliberately not read — a
  value-family map is standing-free by construction.
  """
  @spec map(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def map(value, opts) when is_binary(value) and is_list(opts) do
    with {:ok, parsed} <- parse(value) do
      {:ok, family(parsed, value, "sj closed vocabulary #{parsed.base}")}
    end
  end

  @doc """
  Map an sj status value to the bridge map with the rung a real run evidences:
  `rung`, `index` and `trail` come only from `Standing.ladder(run, opts)`.
  """
  @spec map(String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def map(value, run, opts) when is_binary(value) and is_map(run) and is_list(opts) do
    with {:ok, parsed} <- parse(value),
         {:ok, ladder} <- Standing.ladder(run, opts) do
      derived = "standing ladder #{ladder.state} (index #{ladder.index})"

      {:ok,
       parsed
       |> family(value, derived)
       |> Map.put(:standing, %{
         value: standing_value(parsed),
         derived_from: derived,
         broken_term: broken_term(parsed)
       })
       |> Map.merge(%{rung: ladder.state, index: ladder.index, trail: ladder.trail})}
    end
  end

  # ---- parse ----

  defp parse(value) do
    base = value |> String.split("(", parts: 2) |> hd() |> String.trim()

    cond do
      base not in @statuses ->
        {:error, %{reason: :sj_unknown_status, value: value}}

      String.contains?(value, "(") ->
        with {:ok, names} <- layers(value, base) do
          {:ok, %{base: base, layers: names}}
        end

      base == "REFUSED" ->
        {:error, %{reason: :sj_refused_requires_layers, value: value}}

      true ->
        {:ok, %{base: base, layers: []}}
    end
  end

  # `REFUSED(plan_correct,execution_correct)` — each trimmed layer must name a
  # real verdict layer; an empty layer list on REFUSED is the bare form.
  defp layers(value, base) do
    inner =
      value
      |> String.split("(", parts: 2)
      |> tl()
      |> IO.iodata_to_binary()
      |> String.trim()

    inner = if String.ends_with?(inner, ")"), do: String.slice(inner, 0..-2//1), else: inner

    names =
      inner
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    known = Enum.map(Standing.layers(), &to_string/1)

    case Enum.reject(names, &(&1 in known)) do
      [] ->
        if names == [] and base == "REFUSED" do
          {:error, %{reason: :sj_refused_requires_layers, value: value}}
        else
          {:ok, Enum.map(names, &String.to_existing_atom/1)}
        end

      unknown ->
        {:error, %{reason: :sj_unknown_layer, value: value, layer: hd(unknown)}}
    end
  end

  # ---- bridge map ----

  defp family(parsed, value, derived_from) do
    %{
      status: value,
      base: parsed.base,
      layers: parsed.layers,
      standing: %{
        value: standing_value(parsed),
        derived_from: derived_from,
        broken_term: broken_term(parsed)
      },
      terminal?: terminal?(parsed.base)
    }
  end

  # REFUSED renders with its declared layers; every other base is direct.
  defp standing_value(%{base: "REFUSED", layers: [first | rest]}),
    do: "REFUSED(#{Enum.join([first | rest], ",")})"

  defp standing_value(%{base: base}), do: base

  defp broken_term(%{base: "REFUSED", layers: [first | _]}), do: Receipt.layer_term(first)
  defp broken_term(_), do: nil
end
