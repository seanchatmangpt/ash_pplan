defmodule AshPPlan.Examples.Selfhost.Frontier do
  @moduledoc """
  The completion graph the self-hosting loop consumes, as an `Agent` outside every runner.

  The frontier is built from the `selfhost` workflow model itself: each task of the workflow
  is one item (`id`, `deps`). The loop closes the very tasks that define the loop, so the
  graph that specifies completion is the graph that is executed (the fixed point).

  Item status is `:open | :claimed | :closed | :refused`. The agent registers under this
  module's name, so step options stay data and the state survives any simulated crash of a
  runner. Counters (`executions`) let a court assert each item executed exactly once.
  """
  use Agent

  alias AshPPlan.Workflow.Model

  @type item :: %{
          id: atom(),
          deps: [atom()],
          status: :open | :claimed | :closed | :refused,
          authority: atom()
        }

  @doc """
  Start the frontier from `model`. Option `:request_authority` is a map `%{item_id => authority}`
  overriding what the local agent asks for on that item (default `:construct`).
  """
  @spec start_link(Model.t(), keyword()) :: Agent.on_start()
  def start_link(%Model{} = model, opts \\ []) do
    asks = Keyword.get(opts, :request_authority, %{})

    items =
      for t <- model.tasks do
        %{
          id: t.id,
          deps: t.depends_on,
          status: :open,
          authority: Map.get(asks, t.id, :construct)
        }
      end

    Agent.start_link(
      fn -> %{items: items, claims: %{}, results: %{}, executions: %{}, receipts: %{}} end,
      name: __MODULE__
    )
  end

  @spec items() :: [item()]
  def items, do: Agent.get(__MODULE__, & &1.items)

  @doc "Ids of items that are not yet closed."
  @spec open() :: [atom()]
  def open, do: for(i <- items(), i.status != :closed, do: i.id)

  @doc "Claim the first open item whose dependencies are all closed, for `run_id`."
  @spec claim(String.t()) :: {:ok, atom()} | {:error, :nothing_selectable}
  def claim(run_id) do
    Agent.get_and_update(__MODULE__, fn s ->
      closed = for i <- s.items, i.status == :closed, into: MapSet.new(), do: i.id

      case Enum.find(
             s.items,
             &(&1.status == :open and Enum.all?(&1.deps, fn d -> d in closed end))
           ) do
        nil ->
          {{:error, :nothing_selectable}, s}

        item ->
          {{:ok, item.id},
           %{set_status(s, item.id, :claimed) | claims: Map.put(s.claims, run_id, item.id)}}
      end
    end)
  end

  @spec claimed(String.t()) :: atom() | nil
  def claimed(run_id), do: Agent.get(__MODULE__, &Map.get(&1.claims, run_id))

  @spec item(atom()) :: item() | nil
  def item(id), do: Enum.find(items(), &(&1.id == id))

  @doc "Record one execution of `id` with its result."
  @spec executed(atom(), map()) :: :ok
  def executed(id, result) do
    Agent.update(__MODULE__, fn s ->
      %{
        s
        | executions: Map.update(s.executions, id, 1, &(&1 + 1)),
          results: Map.put(s.results, id, result)
      }
    end)
  end

  @spec result(atom()) :: map() | nil
  def result(id), do: Agent.get(__MODULE__, &Map.get(&1.results, id))

  @spec executions() :: %{atom() => pos_integer()}
  def executions, do: Agent.get(__MODULE__, & &1.executions)

  @spec close(atom()) :: :ok
  def close(id), do: Agent.update(__MODULE__, &set_status(&1, id, :closed))

  @doc "Mark `id` refused (the agent asked for authority above the ceiling)."
  @spec refuse(atom()) :: :ok
  def refuse(id), do: Agent.update(__MODULE__, &set_status(&1, id, :refused))

  @spec put_receipt(String.t(), map()) :: :ok
  def put_receipt(run_id, receipt),
    do: Agent.update(__MODULE__, &%{&1 | receipts: Map.put(&1.receipts, run_id, receipt)})

  @spec receipts() :: %{String.t() => map()}
  def receipts, do: Agent.get(__MODULE__, & &1.receipts)

  defp set_status(s, id, status),
    do: %{
      s
      | items: Enum.map(s.items, fn i -> if i.id == id, do: %{i | status: status}, else: i end)
    }
end
