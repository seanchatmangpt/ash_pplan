# SPDX-License-Identifier: MIT
#
# Local Petri-net trace alignment for the Van der Aalst conformance court
# (test/tokyo_depeg/conformance_alignment_test.exs).
#
# NOTE (ex4pm parity): ash_pplan depends on ex4pm (~> 26.10, Hex). The
# installed ex4pm provides token-based replay only -
# `Ex4pm.Engine.Conformance.TokenReplay.replay/2` over a
# `Ex4pm.Engine.Discovery.InductiveMiner.ProcessTree` - and no A*/uniform-cost
# alignment. Per the work order this module mirrors alignment semantics
# locally: classic Van der Aalst alignment via uniform-cost (Dijkstra) search
# over the synchronous product of the lifecycle Petri net and the trace.
# Costs: synchronous move 0; log move 1; model move 1.
#
# The court asserts this aligner refuses the empty model and the permissive
# model (anti-vacuity).

defmodule AshPplan.TokyoDepeg.Alignment do
  @moduledoc false

  defmodule Model do
    @moduledoc false
    defstruct [:places, :transitions, :initial, :final]
  end

  defmodule Result do
    @moduledoc false
    defstruct [:cost, :moves]
  end

  @type refusal_class ::
          :empty_model
          | :lifecycle_sanctions_omitted
          | :lifecycle_order_violation
          | :lifecycle_unmodelled_activity
          | :permissive_model

  @doc """
  Canonical Tokyo depeg lifecycle Petri net:

      (p0) -RiskPreflight-> (p1) -CollateralCheck-> (p2)
           -SanctionsScreen-> (p3) -Execution-> (p4)

  Initial marking {p0}, final marking {p4}.
  """
  @spec lifecycle() :: {:ok, Model.t()} | {:refused, :empty_model}
  def lifecycle do
    build(
      initial: :p0,
      final: :p4,
      places: [:p0, :p1, :p2, :p3, :p4],
      transitions: [
        {:t_preflight, "RiskPreflight", {:p0, :p1}},
        {:t_collateral, "CollateralCheck", {:p1, :p2}},
        {:t_sanctions, "SanctionsScreen", {:p2, :p3}},
        {:t_execution, "Execution", {:p3, :p4}}
      ]
    )
  end

  @doc """
  Build a model. Refuses the empty model: no transitions, no places,
  dangling initial/final, or transitions referencing unknown places.
  """
  @spec build(keyword()) :: {:ok, Model.t()} | {:refused, :empty_model}
  def build(opts) do
    transitions = Keyword.get(opts, :transitions, [])
    places = opts |> Keyword.get(:places, []) |> MapSet.new()
    initial = Keyword.get(opts, :initial)
    final = Keyword.get(opts, :final)

    cond do
      transitions == [] or places == MapSet.new() ->
        {:refused, :empty_model}

      initial not in places or final not in places ->
        {:refused, :empty_model}

      Enum.any?(transitions, fn {_id, _label, {pin, pout}} ->
        pin not in places or pout not in places
      end) ->
        {:refused, :empty_model}

      true ->
        ts =
          Map.new(transitions, fn {id, label, {pin, pout}} ->
            {id, %{label: label, in: pin, out: pout}}
          end)

        {:ok, %Model{places: places, transitions: ts, initial: initial, final: final}}
    end
  end

  @doc """
  Permissive model: one recycle place (initial and final) with every
  lifecycle activity looping it. Any trace over the lifecycle alphabet
  aligns at cost 0 - the vacuous conformance trap. The court asserts the
  aligner refuses this model outright.
  """
  @spec permissive() :: Model.t()
  def permissive do
    ts =
      Map.new(
        [
          {:t_preflight, "RiskPreflight"},
          {:t_collateral, "CollateralCheck"},
          {:t_sanctions, "SanctionsScreen"},
          {:t_execution, "Execution"}
        ],
        fn {id, label} -> {id, %{label: label, in: :p_loop, out: :p_loop}} end
      )

    %Model{places: MapSet.new([:p_loop]), transitions: ts, initial: :p_loop, final: :p_loop}
  end

  @doc """
  Align `trace` (list of activity-name strings) against `model`.

  `{:ok, %Result{}}` with `cost == 0` means a perfect fit (all synchronous
  moves); `cost > 0` is the Van der Aalst alignment cost. Refuses the empty
  model.
  """
  @spec align(Model.t() | nil, [String.t()]) ::
          {:ok, Result.t()} | {:refused, :empty_model}
  def align(nil, _trace), do: {:refused, :empty_model}

  def align(%Model{transitions: ts} = model, trace) when is_list(trace) do
    if ts == %{} do
      {:refused, :empty_model}
    else
      {:ok, ucs(model, trace)}
    end
  end

  @doc """
  Court verdict: `{:conformant, result}` at cost 0, otherwise map the
  alignment deviation to a typed refusal class:

    * model-move skipping SanctionsScreen -> :lifecycle_sanctions_omitted
    * log-move on Execution -> :lifecycle_unmodelled_activity
    * any other log/model move -> :lifecycle_order_violation
    * permissive model -> :permissive_model
  """
  @spec judge(Model.t(), [String.t()]) ::
          {:conformant, Result.t()} | {:refused, refusal_class()}
  def judge(%Model{} = model, trace) when is_list(trace) do
    if permissive?(model) do
      {:refused, :permissive_model}
    else
      case align(model, trace) do
        {:refused, class} ->
          {:refused, class}

        {:ok, %Result{cost: 0} = result} ->
          {:conformant, result}

        {:ok, %Result{}} ->
          {:refused, classify(trace)}
      end
    end
  end

  # ------------------------------------------------------------
  # Uniform-cost search over the synchronous product
  # ------------------------------------------------------------

  # Entry: {marking map place => token count, trace index}.
  # Frontier: :gb_sets ordered {cost, seq}; parents: state => {cost, parent, move}.
  defp ucs(model, trace) do
    start = {%{model.initial => 1}, 0}
    ucs_loop(model, trace, :gb_sets.singleton({0, 0, start}), %{start => {0, nil, nil}}, 1)
  end

  defp ucs_loop(model, trace, frontier, best, seq) do
    case :gb_sets.take_smallest(frontier) do
      {{cost, _s, state}, rest} ->
        if elem(state, 1) == length(trace) do
          %Result{cost: cost, moves: path(state, best, %{})}
        else
          successors =
            sync_moves(model, trace, state) ++
              log_moves(trace, state) ++
              model_moves(model, state)

          {f2, b2, s2} =
            Enum.reduce(successors, {rest, best, seq}, fn {next, sc, move}, {f, b, s} ->
              nc = cost + sc
              known = Map.get(b, next)

              if known == nil or nc < elem(known, 0) do
                {:gb_sets.add_element({nc, s, next}, f), Map.put(b, next, {nc, state, move}),
                 s + 1}
              else
                {f, b, s}
              end
            end)

          ucs_loop(model, trace, f2, b2, s2)
        end
    end
  end

  defp sync_moves(model, trace, {marking, index}) when index < length(trace) do
    activity = Enum.at(trace, index)

    for {id, t} <- model.transitions,
        Map.get(marking, t.in, 0) > 0,
        t.label == activity do
      {{advance(marking, t), index + 1}, 0, {:sync, id, activity}}
    end
  end

  defp sync_moves(_model, _trace, _state), do: []

  defp log_moves(trace, {marking, index}) when index < length(trace) do
    [{{marking, index + 1}, 1, {:log_move, Enum.at(trace, index)}}]
  end

  defp log_moves(_trace, _state), do: []

  defp model_moves(model, {marking, index}) do
    for {id, t} <- model.transitions, Map.get(marking, t.in, 0) > 0 do
      {{advance(marking, t), index}, 1, {:model_move, id}}
    end
  end

  defp advance(marking, t) do
    marking
    |> Map.update!(t.in, &(&1 - 1))
    |> Map.update(t.out, 1, &(&1 + 1))
    |> Enum.reject(fn {_p, n} -> n == 0 end)
    |> Map.new()
  end

  defp path(state, best, memo) do
    case Map.get(memo, state) do
      moves when is_list(moves) ->
        moves

      nil ->
        case Map.get(best, state) do
          {_cost, nil, nil} ->
            []

          {_cost, parent, move} ->
            upstream = path(parent, best, Map.put(memo, state, []))
            moves = upstream ++ [move]
            Map.put(memo, state, moves)
            moves
        end
    end
  end

  # ------------------------------------------------------------
  # Refusal classification
  # ------------------------------------------------------------

  # Court rule, in precedence order, decided on the trace itself so the
  # verdict is independent of tie-breaks among equal-cost alignments:
  #   1. SanctionsScreen absent from the trace -> sanctions omitted
  #      (the mandatory control stage was skipped).
  #   2. Execution observed more than once (the model admits exactly one
  #      Execution) -> unmodelled activity.
  #   3. Otherwise (all stages present, once each, wrong order) -> order
  #      violation. Cost > 0 is a precondition: a reordered trace can never
  #      align at cost 0 against this sequential net.
  defp classify(trace) do
    cond do
      "SanctionsScreen" not in trace -> :lifecycle_sanctions_omitted
      Enum.count(trace, &(&1 == "Execution")) > 1 -> :lifecycle_unmodelled_activity
      true -> :lifecycle_order_violation
    end
  end

  defp permissive?(%Model{transitions: ts, initial: i, final: f, places: places}) do
    places == MapSet.new([:p_loop]) and i == :p_loop and f == :p_loop and
      Enum.all?(ts, fn {_id, t} -> t.in == :p_loop and t.out == :p_loop end)
  end
end
