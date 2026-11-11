defmodule AshPPlan.POWL.Project do
  @moduledoc """
  POWL → Workflow projection: verified POWL 2.0 models to keyword-form task
  lists compatible with `AshPPlan.Workflow.Model.new/1`.

  Projection mapping (mirrors the verifier's recursive decomposition):

  | POWL operator   | projection                                            |
  |-----------------|--------------------------------------------------------|
  | `activity`      | one step, capability `workflow.execute`                |
  | `sequence`      | ordered steps with `depends_on` chaining               |
  | `choice`        | discriminator step + branch steps depending on it      |
  | `loop`          | single bounded-retry step (`powl:max_iterations` prop) |
  | `partial_order` | steps with `depends_on` edges from the order relations |

  ## Compensation links

  `AshPPlan.Workflow.Task` carries a `:compensation` field (an opaque term,
  default `nil`, e.g. an `{Mod, :fun, []}` MFA), accepted by `Model.new/1`,
  so a leaf activity with `metadata[:compensation]` set projects the
  reference directly in its step (`compensation:` keyword). A leaf without
  one is uncompensable: `compensation: nil` in the step plus a typed
  warning — honest completeness, never silent. The former side `compensations`
  list is retired: every compensation-bearing walk case (leaf, choice
  discriminator, loop retry) attaches to a step id, so no link needs a
  separate ledger.

  ## Bounded retry

  A loop projects to one bounded-retry step. `max_iterations` comes from
  `node.metadata[:max_iterations]`; default **3** (documented here, asserted
  in the test suite).

  Models are verified before projection (`AshPPlan.POWL.Verifier.verify/1`).
  An unsound model is a typed pass-through refusal with nothing projected.
  """

  alias AshPPlan.POWL
  alias AshPPlan.POWL.Node

  @default_max_iterations 3
  @default_capability "workflow.execute"

  @typedoc "Projection result: `Model.new/1`-compatible steps + warning ledger."
  @type result :: %{
          required(:steps) => [keyword()],
          required(:warnings) => [map()]
        }

  @doc """
  Project a verified POWL model to Workflow keyword-form.

  Returns `{:ok, result}` or passes through the verifier's typed refusal
  (`{:error, map()}`) with nothing projected.
  """
  @spec to_reactor_steps(term) :: {:ok, result()} | {:error, map()}
  def to_reactor_steps(input) do
    with :ok <- POWL.Verifier.verify(input),
         {:ok, %Node{} = root} <- POWL.normalize(input) do
      {rev_steps, rev_warns, _entry, _exit, _seen} = walk(root, [], [], MapSet.new(), [])

      {:ok, %{steps: Enum.reverse(rev_steps), warnings: Enum.reverse(rev_warns)}}
    end
  end

  # -- recursive walk
  #
  # walk(node, rev_steps, rev_warns, seen, incoming_deps)
  #   → {rev_steps', rev_warns', entry_ids, exit_ids, seen'}
  #
  # `incoming_deps` are step ids the block's entry must depend on (the chain
  # so far). Emitted ids are unique against `seen` at emission time.

  defp walk(%Node{operator: :activity} = leaf, rev_steps, rev_warns, seen, incoming) do
    %Node{id: powl_id, label: label, metadata: metadata} = leaf
    step_id = unique_id(powl_id, seen)
    compensation = Map.get(metadata, :compensation)

    properties =
      ["powl:operator=activity", "powl:id=#{powl_id}"] ++
        if(is_nil(label), do: [], else: ["powl:label=#{label}"])

    step = [
      id: step_id,
      capability: @default_capability,
      depends_on: incoming,
      outcomes: ["ok"],
      properties: properties,
      compensation: compensation
    ]

    rev_warns =
      if is_nil(compensation),
        do: [%{warning: :uncompensable_activity, step: step_id} | rev_warns],
        else: rev_warns

    {[step | rev_steps], rev_warns, [step_id], [step_id], MapSet.put(seen, step_id)}
  end

  defp walk(%Node{operator: :sequence, children: children}, rev_steps, rev_warns, seen, incoming) do
    {rev_steps, rev_warns, entry, chain, seen} =
      Enum.reduce(
        children,
        {rev_steps, rev_warns, nil, incoming, seen},
        fn child, {rs, rw, entry, chain, seen} ->
          {rs, rw, child_entry, child_exit, seen} = walk(child, rs, rw, seen, chain)

          {rs, rw, entry || child_entry, child_exit, seen}
        end
      )

    {rev_steps, rev_warns, entry, chain, seen}
  end

  defp walk(
         %Node{operator: :choice, id: id, children: children},
         rev_steps,
         rev_warns,
         seen,
         incoming
       ) do
    disc_id = unique_id("#{id}__discriminator", seen)
    seen = MapSet.put(seen, disc_id)

    disc_step = [
      id: disc_id,
      capability: @default_capability,
      depends_on: incoming,
      outcomes: ["selected"],
      properties: ["powl:operator=choice", "powl:block=#{id}"],
      compensation: nil
    ]

    disc_warn = %{
      warning: :choice_requires_runtime_discriminator,
      block: id,
      discriminator: disc_id
    }

    {rev_steps, rev_warns, branch_exits, seen} =
      Enum.reduce(
        children,
        {rev_steps, rev_warns, [], seen},
        fn child, {rs, rw, exits, seen} ->
          {rs, rw, _entry, exit_ids, seen} = walk(child, rs, rw, seen, [disc_id])

          {rs, rw, exits ++ exit_ids, seen}
        end
      )

    {[disc_step | rev_steps], [disc_warn | rev_warns], [disc_id], branch_exits, seen}
  end

  defp walk(
         %Node{operator: :loop, id: id, metadata: metadata, children: [_body, _redo]},
         rev_steps,
         rev_warns,
         seen,
         incoming
       ) do
    max_iterations = Map.get(metadata, :max_iterations, @default_max_iterations)
    retry_id = unique_id("#{id}__retry", seen)

    step = [
      id: retry_id,
      capability: @default_capability,
      depends_on: incoming,
      outcomes: ["done"],
      properties: [
        "powl:operator=loop",
        "powl:block=#{id}",
        "powl:max_iterations=#{max_iterations}"
      ],
      compensation: Map.get(metadata, :compensation)
    ]

    warn = %{warning: :loop_projected_as_bounded_retry, block: id, max_iterations: max_iterations}

    {[step | rev_steps], [warn | rev_warns], [retry_id], [retry_id], MapSet.put(seen, retry_id)}
  end

  defp walk(
         %Node{operator: :partial_order, children: children, order_edges: edges},
         rev_steps,
         rev_warns,
         seen,
         incoming
       ) do
    child_ids = MapSet.new(children, & &1.id)

    edges =
      Enum.filter(edges, fn {s, t} ->
        MapSet.member?(child_ids, s) and MapSet.member?(child_ids, t)
      end)

    {rev_steps, rev_warns, exits_by_child, entry, seen} =
      topo_sort(children, edges)
      |> Enum.reduce(
        {rev_steps, rev_warns, %{}, nil, seen},
        fn child, {rs, rw, exits_by_child, entry, seen} ->
          preds =
            edges
            |> Enum.filter(fn {_, t} -> t == child.id end)
            |> Enum.flat_map(fn {s, _} -> Map.get(exits_by_child, s, []) end)
            |> Enum.uniq()

          chain = if preds == [], do: incoming, else: preds

          {rs, rw, child_entry, child_exit, seen} = walk(child, rs, rw, seen, chain)

          {rs, rw, Map.put(exits_by_child, child.id, child_exit), entry || child_entry, seen}
        end
      )

    po_exits =
      exits_by_child
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    {rev_steps, rev_warns, entry, po_exits, seen}
  end

  # Kahn topological order of po children under `edges`; verified acyclic, so
  # every child is covered.
  defp topo_sort(children, edges) do
    ids = Enum.map(children, & &1.id)
    by_id = Map.new(children, &{&1.id, &1})

    indeg =
      Enum.reduce(edges, %{}, fn {_, t}, acc -> Map.update(acc, t, 1, &(&1 + 1)) end)

    dependents =
      Enum.reduce(edges, %{}, fn {s, t}, acc -> Map.update(acc, s, [t], &[t | &1]) end)

    frontier = Enum.filter(ids, fn cid -> not Map.has_key?(indeg, cid) end)

    order =
      do_topo(frontier, indeg, dependents, [])
      |> Enum.reverse()

    Enum.map(order, &Map.fetch!(by_id, &1))
  end

  defp do_topo(frontier, indeg, dependents, acc) do
    case frontier do
      [] ->
        acc

      [n | rest] ->
        {indeg, freed} =
          Enum.reduce(Map.get(dependents, n, []), {indeg, []}, fn c, {acc, freed} ->
            d = acc[c] - 1

            if d == 0 do
              {Map.put(acc, c, 0), [c | freed]}
            else
              {Map.put(acc, c, d), freed}
            end
          end)

        do_topo(rest ++ freed, indeg, dependents, [n | acc])
    end
  end

  defp unique_id(base, seen) do
    if MapSet.member?(seen, base), do: unique_id("#{base}_x", seen), else: base
  end
end
