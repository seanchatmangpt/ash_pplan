defmodule AshPPlan.POWL.Reachability do
  @moduledoc """
  Bounded reachability simulator over the POWL AST (T-006 property court).

  Compiles a POWL model to a Petri-net-style marking simulation and fires
  transitions from the initial marking, collecting the bounded reachable
  set. Verdict fields:

  - `outcome` — `:sound | :deadlock | :unbounded | :orphan_tokens`
  - `deadlocks` — reachable markings with no enabled transition that are
    not the final marking (T-006 case 1: the known unsound
    `loop(choice(a,b), c)` class must exhibit one of these);
  - `orphans` — places marked somewhere in the reachable set that never
    appear in any marking from which the final marking is reachable
    (tokens that can never contribute to completion);
  - `final_reachable` — whether the clean completion is reachable;
  - `budget_exhausted` — the marking budget ran out (infinite state space).

  ## Translation (authored semantics, disclosed)

  - `activity` — one transition; a `nil`-label activity is silent (`:tau`).
  - `choice` — silent split into each child's source; block sinks are the
    concatenation of child sinks. Choice does not merge branch sinks:
    SM-class branch threads stay distinguishable so composition defects
    stay observable.
  - `sequence` — sink(child_i) wired to source(child_{i+1}); block sinks
    are the last child's sinks.
  - `loop` — the MG-cycle class the verifier claims (verifier.ex:13):
    body -> redo -> cycle with no silent exit and no sink of its own. The
    loop composes onto a single body-sink interface; a choice body does
    not provide a single sink (no merge), so the loop wires its redo from
    `hd(body sinks)` only and any further branch sink is stranded with no
    outgoing transition. That is the composition the verifier moduledoc
    discloses as unproven; this court exhibits its consequence as a real
    reachable deadlock.
  - `partial_order` — silent fork into each child source, order edges as
    silent ordering wires sink(child_s) -> source(child_t), sinks joined
    by silent tau into one join place.
  - `choice_graph` — silent entry per `{:start, _}` edge, child-to-child
    wiring per edges, `{_, :end}` edges wired by silent tau into the
    block sink.
  """

  alias AshPPlan.POWL
  alias AshPPlan.POWL.Node

  @default_max_markings 50_000

  @typedoc "A net place (opaque key)."
  @type place :: term()

  @typedoc "A transition: input places, output places, label."
  @type transition :: {ins :: [place()], outs :: [place()], label :: term()}

  @typedoc "A marking is a set of places."
  @type marking :: MapSet.t(place())

  @typedoc "Compiled block: nets plus interface (source place, sink places)."
  @type block :: {nets :: [transition()], source :: place(), sinks :: [place()]}

  @doc "Simulate a POWL model and return the bounded reachability verdict."
  @spec simulate(term, keyword()) :: {:ok, verdict :: map()} | {:error, %{reason: atom()}}
  def simulate(input, opts \\ []) do
    max = Keyword.get(opts, :max_markings, @default_max_markings)

    case POWL.normalize(input) do
      {:ok, %Node{} = root} -> {:ok, analyse(root, max)}
      {:error, %{reason: reason}} -> {:error, %{reason: reason}}
    end
  end

  @doc "Simulate and raise on refusal (court convenience)."
  @spec simulate!(term, keyword()) :: map()
  def simulate!(input, opts \\ []) do
    case simulate(input, opts) do
      {:ok, verdict} ->
        verdict

      {:error, %{reason: reason}} ->
        raise ArgumentError, "unusable POWL model: #{inspect(reason)}"
    end
  end

  # -- analysis ---------------------------------------------------------------

  defp analyse(root, max) do
    {nets, source, sinks} = compile(root)
    final = {:final, make_ref()}

    nets = nets ++ Enum.map(sinks, fn p -> {[p], [final], :tau} end)

    initial = MapSet.new([source])
    final_marking = MapSet.new([final])

    {reachable, budget_exhausted} = explore(nets, initial, max)

    final_reachable = MapSet.member?(reachable, final_marking)

    deadlocks =
      reachable
      |> Enum.reject(&(&1 == final_marking))
      |> Enum.filter(fn marking ->
        not Enum.any?(nets, fn {ins, _outs, _label} -> enabled?(ins, marking) end)
      end)
      |> Enum.map(&MapSet.to_list/1)

    co = co_reachable(reachable, nets, final_marking)

    marked_places = reachable |> Enum.flat_map(&MapSet.to_list/1) |> MapSet.new()

    orphans =
      marked_places
      |> Enum.reject(fn place ->
        Enum.any?(co, fn marking -> MapSet.member?(marking, place) end)
      end)

    outcome =
      cond do
        deadlocks != [] -> :deadlock
        not final_reachable -> :unbounded
        orphans != [] -> :orphan_tokens
        true -> :sound
      end

    %{
      outcome: outcome,
      deadlocks: deadlocks,
      orphans: orphans,
      final_reachable: final_reachable,
      budget_exhausted: budget_exhausted,
      markings_explored: MapSet.size(reachable)
    }
  end

  # Places marked in some reachable marking but absent from every marking
  # that can still reach the final marking.
  defp co_reachable(reachable, nets, final_marking) do
    if MapSet.member?(reachable, final_marking) do
      index = Map.new(reachable, fn m -> {m, true} end)
      grow_co(nets, reachable, index, MapSet.new([final_marking]))
    else
      MapSet.new()
    end
  end

  defp grow_co(nets, reachable, index, co) do
    next =
      Enum.reduce(reachable, co, fn marking, acc ->
        if MapSet.member?(acc, marking) do
          acc
        else
          feeds_final? =
            Enum.any?(nets, fn {ins, outs, _label} ->
              enabled?(ins, marking) and MapSet.member?(acc, fire(marking, ins, outs))
            end)

          if feeds_final?, do: MapSet.put(acc, marking), else: acc
        end
      end)

    if MapSet.equal?(next, co) do
      next
    else
      grow_co(nets, reachable, index, next)
    end
  end

  # -- exploration ------------------------------------------------------------

  defp explore(nets, initial, max) do
    explore(nets, :queue.from_list([initial]), MapSet.new([initial]), max)
  end

  defp explore(_nets, _queue, seen, max) when map_size(seen) > max do
    {seen, true}
  end

  defp explore(nets, queue, seen, max) do
    case :queue.out(queue) do
      {:empty, _} ->
        {seen, false}

      {{:value, marking}, queue} ->
        {queue, seen} =
          nets
          |> Enum.filter(fn {ins, _outs, _label} -> enabled?(ins, marking) and ins != [] end)
          |> Enum.map(fn {ins, outs, _label} -> fire(marking, ins, outs) end)
          |> Enum.reduce({queue, seen}, fn successor, {queue, seen} ->
            if MapSet.member?(seen, successor) do
              {queue, seen}
            else
              {:queue.in(successor, queue), MapSet.put(seen, successor)}
            end
          end)

        explore(nets, queue, seen, max)
    end
  end

  defp enabled?(ins, marking) do
    Enum.all?(ins, fn p -> MapSet.member?(marking, p) end)
  end

  defp fire(marking, ins, outs) do
    marking
    |> MapSet.difference(MapSet.new(ins))
    |> MapSet.union(MapSet.new(outs))
  end

  # -- compile ----------------------------------------------------------------

  defp compile(%Node{operator: :activity, id: id, label: label}) do
    src = {:act_in, id, make_ref()}
    snk = {:act_out, id, make_ref()}
    net([{[src], [snk], label || :tau}], src, [snk])
  end

  defp compile(%Node{operator: :sequence, children: []}) do
    p = {:empty, make_ref()}
    net([], p, [p])
  end

  defp compile(%Node{operator: :sequence, children: children}) do
    blocks = Enum.map(children, &compile/1)

    first = hd(blocks)

    {nets, _last} =
      Enum.reduce(Enum.drop(blocks, 1), {elem(first, 0), first}, fn
        block, {nets, prev} ->
          wires =
            for p <- elem(prev, 2), s <- [elem(block, 1)] do
              {[p], [s], :tau}
            end

          {nets ++ wires ++ elem(block, 0), block}
      end)

    net(nets, elem(first, 1), elem(List.last(blocks), 2))
  end

  defp compile(%Node{operator: :choice, children: []}) do
    p = {:empty_choice, make_ref()}
    net([], p, [p])
  end

  defp compile(%Node{operator: :choice, children: children}) do
    blocks = Enum.map(children, &compile/1)
    src = {:choice, make_ref()}

    split =
      for block <- blocks do
        {[src], [elem(block, 1)], :tau}
      end

    nets = Enum.flat_map(blocks, &elem(&1, 0)) ++ split

    net(nets, src, Enum.flat_map(blocks, &elem(&1, 2)))
  end

  defp compile(%Node{operator: :loop, children: [body, redo]} = node) do
    %Node{id: id} = node
    body_block = compile(body)
    redo_block = compile(redo)
    src = {:loop, id, make_ref()}

    wired_sink = hd(elem(body_block, 2))

    entry = {[src], [elem(body_block, 1)], :tau}
    redo_entry = {[wired_sink], [elem(redo_block, 1)], :tau}

    redo_return =
      for p <- elem(redo_block, 2) do
        {[p], [src], :tau}
      end

    nets =
      [entry, redo_entry] ++
        Enum.flat_map([body_block, redo_block], &elem(&1, 0)) ++ redo_return

    # MG-cycle: no silent exit, no sinks of its own; any body sink beyond
    # hd is stranded (no outgoing transition) — the disclosed-unproven
    # loop/choice composition, exhibited as a real deadlock.
    net(nets, src, [])
  end

  defp compile(%Node{operator: :partial_order, children: children, order_edges: edges}) do
    blocks = Enum.map(children, &compile/1)
    src = {:po, make_ref()}
    join = {:po_join, make_ref()}

    fork = for block <- blocks, do: {[src], [elem(block, 1)], :tau}

    by_id = Map.new(Enum.with_index(children), fn {c, i} -> {c.id, i} end)

    edge_wires =
      for {s, t} <- edges,
          is_map_key(by_id, s),
          is_map_key(by_id, t) do
        {[hd(elem(Enum.at(blocks, by_id[s]), 2))], [elem(Enum.at(blocks, by_id[t]), 1)], :tau}
      end

    join_wires =
      for block <- blocks, p <- elem(block, 2) do
        {[p], [join], :tau}
      end

    nets =
      Enum.flat_map(blocks, &elem(&1, 0)) ++
        fork ++ edge_wires ++ join_wires

    net(nets, src, [join])
  end

  defp compile(%Node{operator: :choice_graph, children: children, edges: edges}) do
    blocks = Enum.map(children, &compile/1)
    src = {:cg, make_ref()}
    snk = {:cg_end, make_ref()}

    entry =
      for {:start, {:child, i}} <- edges do
        {[src], [elem(Enum.at(blocks, i), 1)], :tau}
      end

    inner =
      for {{:child, i}, {:child, j}} <- edges do
        {[hd(elem(Enum.at(blocks, i), 2))], [elem(Enum.at(blocks, j), 1)], :tau}
      end

    exits =
      for {{:child, i}, :end} <- edges do
        {[hd(elem(Enum.at(blocks, i), 2))], [snk], :tau}
      end

    nets =
      Enum.flat_map(blocks, &elem(&1, 0)) ++ entry ++ inner ++ exits

    net(nets, src, [snk])
  end

  defp net(nets, source, sinks), do: {nets, source, sinks}
end
