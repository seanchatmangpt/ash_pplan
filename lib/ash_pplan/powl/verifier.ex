defmodule AshPPlan.POWL.Verifier do
  @moduledoc """
  Separability verification of POWL 2.0 models (Algorithm 3 class:
  PartitionMG / PartitionSM recursive decomposition, after PETRI25
  "Hierarchical Decomposition of Separable Workflow-Nets").

  A model is SOUND iff the recursion closes without a residual
  non-decomposable block. Per operator:

  - `activity` — marked-graph leaf: sound.
  - `sequence` — MG chain; sound iff every child is sound.
  - `choice`   — state-machine block; sound iff every child is sound.
  - `loop`     — MG cycle; sound iff body and redo are sound. A loop whose
    body is a choice is refused (`:loop_choice_body`): the loop composes
    onto a single body-sink interface but a choice exposes per-branch
    sinks (no merge), and the bounded reachability court
    (`AshPPlan.POWL.Reachability`) exhibits the stranded branch sink as a
    reachable non-final deadlock.
  - `partial_order` — MG fork/join block; sound iff the order edges are
    acyclic and no choice-class child is interior to the poset with two or
    more incomparable in- or out-flows (the PT-handle class).
  - `choice_graph` — gamma block over ▷ start / child / □ end endpoints;
    sound iff every child is sound, endpoints are in range (no dangling
    `{:child, i}`), the edges are acyclic, and every child is reachable
    from ▷ and can reach □ (no child self-loops; unreachable children
    refused).

  ## Compiler seam

  `verify/1` is the admissibility check for POWL candidates. Intended call
  point: `AshPPlan.Compiler`, before plan compilation, e.g.
  `AshPPlan.POWL.Verifier.verify(candidate)` alongside FOND policy
  validation. `lib/ash_pplan/compiler.ex` was not edited (lane ownership);
  the seam is disclosed here per the dispatch contract.
  """

  alias AshPPlan.POWL
  alias AshPPlan.POWL.Node

  @doc "Verify a POWL model: `:ok` when sound, typed refusal otherwise."
  @spec verify(term) :: :ok | {:error, map()}
  def verify(input) do
    case POWL.normalize(input) do
      {:ok, %Node{} = root} -> verify_node(root)
      {:error, %{reason: reason}} -> {:error, %{reason: reason}}
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # -- operator recursion

  defp verify_node(%Node{operator: :activity}), do: :ok

  defp verify_node(%Node{operator: :loop, id: id, children: [body, redo]}) do
    case body.operator do
      :choice ->
        {:error, %{reason: :loop_choice_body, block: %{block_id: id, body_id: body.id}}}

      _ ->
        verify_children([body, redo])
    end
  end

  defp verify_node(%Node{operator: op, children: children, id: id})
       when op in [:sequence, :choice] do
    case verify_children(children) do
      :ok -> :ok
      {:error, err} -> {:error, prefix(err, id, op)}
    end
  end

  defp verify_node(%Node{operator: :partial_order} = node) do
    %Node{id: id, children: children, order_edges: edges} = node

    with :ok <- verify_children(children),
         :ok <- check_edges(children, edges),
         :ok <- check_acyclic(id, edges) do
      check_choice_interior(id, children, edges)
    end
  end

  defp verify_node(%Node{operator: :choice_graph} = node) do
    %Node{id: id, children: children, edges: edges} = node

    with :ok <- verify_children(children),
         :ok <- check_choice_endpoints(id, children, edges),
         :ok <- check_choice_acyclic(id, edges) do
      check_choice_reachability(id, children, edges)
    end
  end

  # -- choice-graph (gamma) checks

  defp check_choice_endpoints(id, children, edges) do
    max = length(children)

    bad =
      Enum.find(edges, fn {f, t} ->
        out_of_range?(f, max) or out_of_range?(t, max)
      end)

    case bad do
      nil ->
        :ok

      edge ->
        {:error,
         %{reason: :dangling_choice_endpoint, block: %{block_id: id, edge: edge, children: max}}}
    end
  end

  defp out_of_range?({:child, i}, max), do: not (is_integer(i) and i >= 0 and i < max)
  defp out_of_range?(_, _), do: false

  defp check_choice_acyclic(id, edges) do
    loop_edges = Enum.reject(edges, fn {f, t} -> f == :end or t == :end end)

    case kahn(loop_edges) do
      :ok ->
        :ok

      {:cycle, cycle} ->
        {:error, %{reason: :cyclic_choice_graph, block: %{block_id: id, cycle: cycle}}}
    end
  end

  defp check_choice_reachability(id, children, edges) do
    adj = adjacency(edges)
    from_start = reachable_set(:start, adj)
    to_end = reachable_set(:end, adjacency(reverse(edges)))

    unreachable =
      children
      |> Enum.with_index()
      |> Enum.find(fn {_child, i} ->
        not MapSet.member?(from_start, {:child, i}) or
          not MapSet.member?(to_end, {:child, i})
      end)

    case unreachable do
      nil ->
        :ok

      {_child, i} ->
        {:error, %{reason: :unreachable_choice_child, block: %{block_id: id, child_index: i}}}
    end
  end

  defp reachable_set(target, adj) do
    walk_set([target], MapSet.new([target]), adj)
  end

  defp walk_set([], acc, _adj), do: acc

  defp walk_set(frontier, acc, adj) do
    next =
      frontier
      |> Enum.flat_map(fn n -> Map.get(adj, n, []) end)
      |> Enum.reject(&MapSet.member?(acc, &1))

    walk_set(next, MapSet.union(acc, MapSet.new(next)), adj)
  end

  defp reverse(edges), do: Enum.map(edges, fn {f, t} -> {t, f} end)

  defp verify_children([]), do: :ok

  defp verify_children([child | rest]) do
    case verify_node(child) do
      :ok -> verify_children(rest)
      {:error, _} = err -> err
    end
  end

  # -- partial-order checks

  defp check_edges(children, edges) do
    ids = MapSet.new(children, & &1.id)

    bad =
      Enum.find(edges, fn {s, t} ->
        not (MapSet.member?(ids, s) and MapSet.member?(ids, t))
      end)

    case bad do
      nil ->
        :ok

      edge ->
        {:error,
         %{reason: :non_separable_block, block: %{cause: :unknown_order_edge, edge: edge}}}
    end
  end

  defp check_acyclic(id, edges) do
    case kahn(edges) do
      :ok ->
        :ok

      {:cycle, cycle} ->
        {:error,
         %{
           reason: :non_separable_block,
           block: %{cause: :order_cycle, block_id: id, cycle: cycle}
         }}
    end
  end

  # Kahn's algorithm: peel zero-in-degree nodes; leftovers touch a cycle
  defp kahn(edges) do
    nodes =
      edges |> Enum.flat_map(fn {s, t} -> [s, t] end) |> Enum.uniq()

    indeg =
      Enum.reduce(edges, %{}, fn {_, t}, acc -> Map.update(acc, t, 1, &(&1 + 1)) end)

    by_source = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))

    frontier = Enum.filter(nodes, fn n -> not Map.has_key?(indeg, n) end)

    leftover = peel(frontier, indeg, by_source, MapSet.new(nodes))

    case leftover do
      [] -> :ok
      cycle -> {:cycle, Enum.sort(cycle)}
    end
  end

  defp peel(frontier, indeg, by_source, remaining) do
    case frontier do
      [] ->
        MapSet.to_list(remaining)

      [n | rest] ->
        children = Map.get(by_source, n, [])

        {updated_indeg, freed} =
          Enum.reduce(children, {indeg, []}, fn c, {acc, freed} ->
            d = acc[c] - 1

            if d == 0 do
              {Map.put(acc, c, 0), [c | freed]}
            else
              {Map.put(acc, c, d), freed}
            end
          end)

        remaining = MapSet.delete(remaining, n)
        peel(rest ++ freed, updated_indeg, by_source, remaining)
    end
  end

  # -- PT-handle check: choice-class child interior to the poset

  defp check_choice_interior(id, children, edges) do
    preds = predecessors(edges)
    succs = successors(edges)

    children
    |> Enum.filter(fn c -> c.operator == :choice end)
    |> Enum.find_value(fn child ->
      interior_block(child.id, preds, succs, edges)
    end)
    |> case do
      nil -> :ok
      block -> {:error, %{reason: :non_separable_block, block: Map.put(block, :block_id, id)}}
    end
  end

  defp interior_block(cid, preds, succs, edges) do
    pin = Map.get(preds, cid, [])
    pout = Map.get(succs, cid, [])

    cond do
      length(pin) >= 2 and not totally_ordered?(pin, edges) ->
        %{cause: :pt_handle_choice_interior, side: :in, node: cid, nodes: pin}

      length(pout) >= 2 and not totally_ordered?(pout, edges) ->
        %{cause: :pt_handle_choice_interior, side: :out, node: cid, nodes: pout}

      true ->
        nil
    end
  end

  # true iff `nodes` are pairwise comparable under the transitive closure
  defp totally_ordered?(nodes, edges) do
    adj = adjacency(edges)

    pairs =
      for {x, i} <- Enum.with_index(nodes), {y, j} <- Enum.with_index(nodes), i < j do
        {x, y}
      end

    Enum.all?(pairs, fn {x, y} ->
      reachable?(x, y, adj) or reachable?(y, x, adj)
    end)
  end

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn {s, t}, acc -> Map.update(acc, s, [t], &[t | &1]) end)
  end

  defp reachable?(from, to, adj), do: walk([from], MapSet.new([from]), to, adj)

  defp walk([], _seen, _to, _adj), do: false

  defp walk(frontier, seen, to, adj) do
    next =
      frontier
      |> Enum.flat_map(fn n -> Map.get(adj, n, []) end)
      |> Enum.reject(&MapSet.member?(seen, &1))

    cond do
      to in next -> true
      next == [] -> false
      true -> walk(next, MapSet.union(seen, MapSet.new(next)), to, adj)
    end
  end

  defp predecessors(edges) do
    Enum.reduce(edges, %{}, fn {s, t}, acc -> Map.update(acc, t, [s], &[s | &1]) end)
  end

  defp successors(edges) do
    Enum.reduce(edges, %{}, fn {s, t}, acc -> Map.update(acc, s, [t], &[t | &1]) end)
  end

  # -- error shaping

  defp prefix({:error, %{block: block} = err}, id, _op) do
    {:error, %{err | block: Map.put(block, :within, [id | Map.get(block, :within, [])])}}
  end

  defp prefix(other, _id, _op), do: other
end
