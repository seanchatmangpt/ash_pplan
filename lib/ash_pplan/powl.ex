defmodule AshPPlan.POWL do
  @moduledoc """
  POWL 2.0 process-model AST for AshPPlan.

  Prior art: `ex4pm lib/ex4pm_engine/powl.ex` (read-only, consulted via git show
  into /tmp scratch). Operators: activity leaves, sequence, choice, loop, and
  partial orders (strict order relations over children).

  Models are trees of `%AshPPlan.POWL.Node{}`. Verify with
  `AshPPlan.POWL.Verifier.verify/1`.
  """

  defmodule Node do
    @moduledoc false

    defstruct [:id, :operator, :label, children: [], order_edges: [], metadata: %{}]

    @type t :: %__MODULE__{
            id: String.t(),
            operator: :activity | :sequence | :choice | :loop | :partial_order,
            label: String.t() | nil,
            children: [t()],
            order_edges: [{String.t(), String.t()}],
            metadata: map()
          }
  end

  @type powl_node :: Node.t()
  @type edge :: {String.t(), String.t()}

  @doc "Activity leaf: one labeled transition."
  @spec activity(term, term) :: powl_node()
  def activity(id, label \\ nil) do
    %Node{id: to_id(id), operator: :activity, label: label && to_string(label)}
  end

  @doc "Sequential composition of children."
  @spec sequence(term, [powl_node()]) :: powl_node()
  def sequence(id, children) when is_list(children) do
    %Node{id: to_id(id), operator: :sequence, children: children}
  end

  @doc "Exclusive choice between children."
  @spec choice(term, [powl_node()]) :: powl_node()
  def choice(id, children) when is_list(children) do
    %Node{id: to_id(id), operator: :choice, children: children}
  end

  @doc "Loop with a body and a redo branch."
  @spec loop(term, powl_node(), powl_node()) :: powl_node()
  def loop(id, body, redo) do
    %Node{id: to_id(id), operator: :loop, children: [body, redo]}
  end

  @doc "Partial order over children with strict-order edges."
  @spec partial_order(term, [powl_node()], [edge()]) :: powl_node()
  def partial_order(id, children, order_edges) when is_list(children) and is_list(order_edges) do
    %Node{
      id: to_id(id),
      operator: :partial_order,
      children: children,
      order_edges: Enum.map(order_edges, fn {s, t} -> {to_id(s), to_id(t)} end)
    }
  end

  @doc """
  Normalize divergent representations into a POWL node.

  Accepts a `%Node{}`, a candidate map `%{formalism: :powl, plan: plan}` or
  `%{plan: plan}`, or a catalog plan map `%{steps: [...]}` where each step
  carries `iri`, `label`, and `predecessors`.
  """
  @spec normalize(term) :: {:ok, powl_node()} | {:error, %{reason: atom()}}
  def normalize(%Node{} = node), do: {:ok, node}

  def normalize(%{formalism: :powl, plan: plan}), do: normalize(plan)

  def normalize(%{plan: plan}) when is_map(plan), do: normalize(plan)

  def normalize(%{steps: steps}) when is_list(steps) do
    children =
      Enum.map(steps, fn step ->
        activity(step[:iri] || step[:label], step[:label])
      end)

    ids = MapSet.new(children, & &1.id)

    edges =
      Enum.flat_map(steps, fn step ->
        step_id = to_id(step[:iri] || step[:label])
        preds = step[:predecessors] || []

        Enum.map(preds, fn p -> {to_id(p), step_id} end)
      end)
      |> Enum.filter(fn {s, t} -> MapSet.member?(ids, s) and MapSet.member?(ids, t) end)

    root_id = "po_" <> root_suffix(steps)

    {:ok,
     %Node{
       id: root_id,
       operator: :partial_order,
       children: children,
       order_edges: edges
     }}
  end

  def normalize(_other), do: {:error, %{reason: :unsupported_powl_shape}}

  defp root_suffix([first | _]) do
    first
    |> case do
      %{iri: iri} when is_binary(iri) -> iri
      %{label: label} when is_binary(label) -> label
      _ -> "anon"
    end
    |> to_string()
    |> String.replace(~r/\W+/, "_")
  end

  defp root_suffix([]), do: "empty"

  defp to_id(id) when is_binary(id), do: id
  defp to_id(id), do: to_string(id)
end
