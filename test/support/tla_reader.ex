defmodule AshPPlan.Test.TLAReader do
  @moduledoc """
  Independent in-process reader and liveness checker for the TLA+ fragment
  rendered by `AshPPlan.FOND.to_tla/4`.

  Why this exists next to `AshPPlan.Test.TLCCourt`: the TLC court needs the
  pinned tla2tools jar and a JVM; where either is absent every TLC test is a
  named skip, so the rendered artifact would otherwise go unexamined. This
  reader is not a double of TLC. It is a second, real checker that works on the
  rendered *text* only (it never sees the `AshPPlan.FOND` domain), so a renderer
  defect that changes the model — a dropped branch, a wrong target, a missing
  fairness clause, a stuttering self-loop — changes its verdict.

  Scope is deliberately closed: every line of the module must match one of the
  shapes the renderer emits, otherwise `check!/1` raises. It never guesses, so a
  drifted rendering cannot masquerade as a verdict.

  Semantics decided (TLA+ with `Spec == Init /\\ [][Next]_vars /\\ WF_vars(Next)
  /\\ Fairness`, property `<>Goal`, TLC deadlock checking on):

    * `:deadlock` — a reachable state with no enabled action at all (`Done` is
      enabled exactly at goal states).
    * `:liveness` — there is a set `C` of reachable non-goal states that a fair
      behavior can stay in forever: either a non-trivial strongly connected set
      (non-stuttering branch edges inside `C`) such that every `SF` branch whose
      source is in `C` targets `C`, and every `WF` branch of a singleton `C`
      targets `C`; or a single state whose only enabled branches are stuttering
      (`state' = state /\\ tick' = tick`), where `WF_vars(Next)` does not force a
      step.
    * `:admitted` otherwise.
  """

  defmodule Model do
    @moduledoc false
    defstruct module_name: nil,
              states: nil,
              goals: nil,
              init: nil,
              branches: %{},
              actions: %{},
              next: [],
              fairness: %{}
  end

  @ident "[A-Za-z][A-Za-z0-9_]*"

  @doc "Parses a rendered module. Raises on any line outside the rendered fragment."
  def parse!(module) when is_binary(module) do
    lines = String.split(module, "\n")

    {model, pending} =
      Enum.reduce(lines, {%Model{}, nil}, fn line, {model, pending} ->
        line(line, model, pending)
      end)

    if pending != nil and not match?({:fairness, _}, pending) and
         not match?({:disjunction, _, _}, pending),
       do: raise("unterminated definition #{inspect(pending)}")

    validate!(model)
  end

  @doc """
  Returns `%{verdict: :admitted | :refused, kind: :no_error | :deadlock |
  :liveness, witness: term}` for a rendered model (map with `:module`) or raw
  module text.
  """
  def check!(%{module: module}), do: check!(module)

  def check!(module) when is_binary(module) do
    model = parse!(module)
    reachable = reachable(model)
    enabled = enabled_by_state(model)

    deadlocked =
      reachable
      |> Enum.reject(&MapSet.member?(model.goals, &1))
      |> Enum.filter(&(Map.get(enabled, &1, []) == []))
      |> Enum.sort()

    cond do
      deadlocked != [] ->
        %{verdict: :refused, kind: :deadlock, witness: deadlocked}

      (trap = fair_trap(model, reachable, enabled)) != nil ->
        %{verdict: :refused, kind: :liveness, witness: trap}

      true ->
        %{verdict: :admitted, kind: :no_error, witness: nil}
    end
  end

  # -- parsing --------------------------------------------------------------

  defp line(line, model, {:disjunction, target, acc}) do
    case Regex.run(~r/\A  \\\/ (#{@ident})\z/, line) do
      [_, name] -> {model, {:disjunction, target, [name | acc]}}
      nil -> line(line, close(model, target, acc), nil)
    end
  end

  defp line(line, model, {:fairness, acc}) do
    case Regex.run(~r/\A  \/\\ (SF|WF)_vars\((#{@ident})\)\z/, line) do
      [_, kind, name] -> {model, {:fairness, Map.put(acc, name, kind)}}
      nil -> line(line, %{model | fairness: acc}, nil)
    end
  end

  defp line(line, model, nil) do
    cond do
      line == "" or String.starts_with?(line, "\\*") ->
        {model, nil}

      m = Regex.run(~r/\A---- MODULE (#{@ident}) ----\z/, line) ->
        {%{model | module_name: Enum.at(m, 1)}, nil}

      line in [
        "EXTENDS Naturals",
        "VARIABLES state, tick",
        "vars == <<state, tick>>",
        "Goal == state \\in Goals",
        "TypeOK == state \\in States /\\ tick \\in {0, 1}",
        "Done == state \\in Goals /\\ UNCHANGED vars",
        "Progress == WF_vars(Next)",
        "Spec == Init /\\ [][Next]_vars /\\ Progress /\\ Fairness",
        "GoalReached == <>Goal"
      ] ->
        {model, nil}

      line == String.duplicate("=", 77) ->
        {model, nil}

      m = Regex.run(~r/\AStates == (.*)\z/, line) ->
        {%{model | states: set!(Enum.at(m, 1))}, nil}

      m = Regex.run(~r/\AGoals == (.*)\z/, line) ->
        {%{model | goals: set!(Enum.at(m, 1))}, nil}

      m = Regex.run(~r/\AInit == state = "(s\d+)" \/\\ tick = 0\z/, line) ->
        {%{model | init: Enum.at(m, 1)}, nil}

      m =
          Regex.run(
            ~r/\A(B_\d+_\d+) == state = "(s\d+)" \/\\ state' = "(s\d+)" \/\\ tick' = (1 - tick|tick)\z/,
            line
          ) ->
        [_, name, from, to, tick] = m

        if Map.has_key?(model.branches, name), do: raise("duplicate branch #{name}")

        branch = %{from: from, to: to, stutter: from == to and tick == "tick"}
        {%{model | branches: Map.put(model.branches, name, branch)}, nil}

      m = Regex.run(~r/\A(A_\d+) ==\z/, line) ->
        {model, {:disjunction, {:action, Enum.at(m, 1)}, []}}

      line == "Next ==" ->
        {model, {:disjunction, :next, []}}

      line == "Fairness == TRUE" ->
        {%{model | fairness: %{}}, nil}

      line == "Fairness ==" ->
        {model, {:fairness, %{}}}

      true ->
        raise "line outside the rendered TLA+ fragment: #{inspect(line)}"
    end
  end

  defp close(_model, _target, []), do: raise("empty disjunction")

  defp close(model, {:action, name}, acc) do
    if Map.has_key?(model.actions, name), do: raise("duplicate action #{name}")
    %{model | actions: Map.put(model.actions, name, Enum.reverse(acc))}
  end

  defp close(model, :next, acc), do: %{model | next: Enum.reverse(acc)}

  defp set!("{}"), do: MapSet.new()

  defp set!(text) do
    case Regex.run(~r/\A\{("s\d+"(, "s\d+")*)\}\z/, text) do
      [_, body | _] ->
        body |> String.split(", ") |> Enum.map(&String.trim(&1, "\"")) |> MapSet.new()

      nil ->
        raise "not a rendered state set: #{inspect(text)}"
    end
  end

  defp validate!(%Model{} = m) do
    for {field, value} <- [
          module_name: m.module_name,
          states: m.states,
          goals: m.goals,
          init: m.init
        ],
        value == nil,
        do: raise("rendered module lacks #{field}")

    unless MapSet.member?(m.states, m.init), do: raise("Init #{m.init} not in States")
    unless MapSet.subset?(m.goals, m.states), do: raise("Goals not a subset of States")
    unless "Done" in m.next, do: raise("Next lacks Done")

    for name <- m.next,
        name != "Done",
        not Map.has_key?(m.actions, name),
        do: raise("Next references undefined action #{name}")

    for {_a, bs} <- m.actions,
        b <- bs,
        not Map.has_key?(m.branches, b),
        do: raise("action references undefined branch #{b}")

    for {b, _kind} <- m.fairness,
        not Map.has_key?(m.branches, b),
        do: raise("fairness references undefined branch #{b}")

    for {_b, %{from: f, to: t}} <- m.branches,
        s <- [f, t],
        not MapSet.member?(m.states, s),
        do: raise("branch state #{s} not in States")

    m
  end

  # -- checking -------------------------------------------------------------

  # Branches reachable through Next; a goal state only enables Done.
  defp enabled_by_state(model) do
    model.next
    |> Enum.reject(&(&1 == "Done"))
    |> Enum.flat_map(&Map.fetch!(model.actions, &1))
    |> Enum.map(&{&1, Map.fetch!(model.branches, &1)})
    |> Enum.group_by(fn {_name, b} -> b.from end)
  end

  defp reachable(model) do
    enabled = enabled_by_state(model)
    walk([model.init], MapSet.new(), enabled)
  end

  defp walk([], seen, _enabled), do: seen

  defp walk([s | rest], seen, enabled) do
    if MapSet.member?(seen, s) do
      walk(rest, seen, enabled)
    else
      next = enabled |> Map.get(s, []) |> Enum.map(fn {_n, b} -> b.to end)
      walk(next ++ rest, MapSet.put(seen, s), enabled)
    end
  end

  defp fair_trap(model, reachable, enabled) do
    candidates = reachable |> Enum.reject(&MapSet.member?(model.goals, &1)) |> MapSet.new()

    stutter_trap =
      candidates
      |> Enum.sort()
      |> Enum.find(fn s ->
        bs = Map.get(enabled, s, [])
        bs != [] and Enum.all?(bs, fn {_n, b} -> b.stutter end)
      end)

    if stutter_trap, do: [stutter_trap], else: scc_trap(model, candidates, enabled)
  end

  # Emerson–Lei style refinement: drop states whose fairness forces an exit,
  # recompute SCCs, until a fair non-trivial SCC survives or nothing remains.
  defp scc_trap(model, candidates, enabled) do
    if MapSet.size(candidates) == 0 do
      nil
    else
      edges = edges_within(candidates, enabled)
      sccs = sccs(candidates, edges) |> Enum.filter(&nontrivial?(&1, edges))

      Enum.find_value(sccs, fn scc ->
        exits = forced_exits(model, scc, enabled)

        cond do
          MapSet.size(exits) == 0 -> scc |> MapSet.to_list() |> Enum.sort()
          true -> scc_trap(model, MapSet.difference(scc, exits), enabled)
        end
      end)
    end
  end

  defp forced_exits(model, scc, enabled) do
    singleton? = MapSet.size(scc) == 1

    scc
    |> Enum.filter(fn s ->
      enabled
      |> Map.get(s, [])
      |> Enum.any?(fn {name, b} ->
        leaves? = not MapSet.member?(scc, b.to)

        case Map.get(model.fairness, name) do
          "SF" -> leaves? and not b.stutter
          "WF" -> leaves? and singleton? and not b.stutter
          nil -> false
        end
      end)
    end)
    |> MapSet.new()
  end

  defp edges_within(set, enabled) do
    for s <- set,
        {_n, b} <- Map.get(enabled, s, []),
        not b.stutter,
        MapSet.member?(set, b.to),
        reduce: %{} do
      acc -> Map.update(acc, s, MapSet.new([b.to]), &MapSet.put(&1, b.to))
    end
  end

  defp nontrivial?(scc, edges) do
    case MapSet.to_list(scc) do
      [s] -> MapSet.member?(Map.get(edges, s, MapSet.new()), s)
      _ -> true
    end
  end

  # Kosaraju over the small explicit graph.
  defp sccs(nodes, edges) do
    order =
      nodes
      |> Enum.sort()
      |> Enum.reduce({MapSet.new(), []}, fn n, {seen, out} -> dfs(n, edges, seen, out) end)
      |> elem(1)

    reverse =
      for {s, ts} <- edges, t <- ts, reduce: %{} do
        acc -> Map.update(acc, t, MapSet.new([s]), &MapSet.put(&1, s))
      end

    order
    |> Enum.reduce({MapSet.new(), []}, fn n, {seen, comps} ->
      if MapSet.member?(seen, n) do
        {seen, comps}
      else
        {seen, comp} = dfs(n, reverse, seen, [])
        {seen, [MapSet.new(comp) | comps]}
      end
    end)
    |> elem(1)
  end

  defp dfs(n, edges, seen, out) do
    if MapSet.member?(seen, n) do
      {seen, out}
    else
      {seen, out} =
        edges
        |> Map.get(n, MapSet.new())
        |> Enum.sort()
        |> Enum.reduce({MapSet.put(seen, n), out}, fn m, {seen, out} ->
          dfs(m, edges, seen, out)
        end)

      {seen, [n | out]}
    end
  end
end
