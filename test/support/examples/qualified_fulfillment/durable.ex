defmodule AshPPlan.Examples.QualifiedFulfillment.Durable do
  @moduledoc """
  Durable halt / kill / resume runner for the qualified-fulfillment human-release
  gate.

  A real Reactor (admit -> authorize -> await_human_release -> commit) runs inside a
  `GenServer` until the release step halts. The halted Reactor is captured through
  `AshPPlan.Continuation` and persisted by `Store`, a file-backed
  `AshPPlan.Continuation.Store` (one file per continuation id). The runner process
  is then stopped, discarding all in-memory state. `resume/4` starts a fresh
  runner that holds nothing, loads the envelope from the file store and resumes
  with the human decision.

  Consequential effects (`:admit`, `:authorize`, `:commit`) increment named
  counters in `Counters`, an Agent owned by the caller and therefore outliving
  the runner. A court asserts that every effect ran exactly once across
  halt, kill and resume.
  """

  alias AshPPlan.Continuation
  alias AshPPlan.Continuation.ETFCodec

  alias AshPPlan.Workflow.{Evidence, Model, Subject}

  @model_name "qualified_fulfillment_durable"

  defmodule Counters do
    @moduledoc "Per-effect execution counters held outside the runner process."
    use Agent

    @spec start_link(keyword()) :: Agent.on_start()
    def start_link(opts \\ []), do: Agent.start_link(fn -> %{} end, opts)

    @doc """
    Portable key for a counters process. A halted Reactor context must hold only
    durable terms, so steps carry this binary key, never the pid.
    """
    @spec key(pid()) :: String.t()
    def key(pid) when is_pid(pid) do
      key = "qf-counters-" <> inspect(pid)
      :persistent_term.put({__MODULE__, key}, pid)
      key
    end

    defp resolve(pid) when is_pid(pid), do: pid
    defp resolve(key) when is_binary(key), do: :persistent_term.get({__MODULE__, key})

    @spec bump(GenServer.server() | String.t(), atom()) :: :ok
    def bump(counters, effect),
      do: Agent.update(resolve(counters), &Map.update(&1, effect, 1, fn n -> n + 1 end))

    @spec all(GenServer.server()) :: %{atom() => pos_integer()}
    def all(counters), do: Agent.get(resolve(counters), & &1)

    @spec count(GenServer.server(), atom()) :: non_neg_integer()
    def count(counters, effect), do: Agent.get(resolve(counters), &Map.get(&1, effect, 0))
  end

  defmodule Store do
    @moduledoc "File-backed `AshPPlan.Continuation.Store`; `ctx` is `%{dir: path}`."
    @behaviour AshPPlan.Continuation.Store

    @impl true
    def put(%Continuation{} = c, %{dir: dir}) do
      File.mkdir_p!(dir)
      File.write(path(dir, c.id), :erlang.term_to_binary(c))
    end

    @impl true
    def fetch(id, %{dir: dir}) do
      with {:ok, bin} <- File.read(path(dir, id)) do
        {:ok, :erlang.binary_to_term(bin, [:safe])}
      end
    end

    @impl true
    def delete(id, %{dir: dir}) do
      case File.rm(path(dir, id)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        other -> other
      end
    end

    defp path(dir, id), do: Path.join(dir, "#{id}.continuation")
  end

  defmodule Admit do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(%{order: order}, ctx, _), do: effect(ctx, :admit, {:admitted, order})

    defp effect(ctx, name, value) do
      Counters.bump(ctx.counters, name)
      {:ok, value}
    end
  end

  defmodule Authorize do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(%{admitted: {:admitted, order}}, ctx, _) do
      Counters.bump(ctx.counters, :authorize)
      {:ok, {:authorized, order}}
    end
  end

  defmodule AwaitRelease do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(%{authorized: _}, ctx, _) do
      Counters.bump(ctx.counters, :release_poll)

      case Map.get(ctx, :release_decision) do
        nil -> {:halt, :awaiting_human_release}
        :approved -> {:ok, :approved}
        other -> {:error, {:release_not_approved, other}}
      end
    end
  end

  defmodule Commit do
    @moduledoc """
    Reactor stores a halt value as the halted step's result, so the human decision
    arrives through the resume context, not through the `release` argument (which
    only orders this step after the gate).
    """
    use Reactor.Step
    @impl true
    def run(%{authorized: {:authorized, order}}, ctx, _) do
      case Map.get(ctx, :release_decision) do
        :approved ->
          Counters.bump(ctx.counters, :commit)
          {:ok, {:shipment_committed, order}}

        other ->
          {:error, {:release_not_approved, other}}
      end
    end
  end

  @doc "The semantic workflow model the durable Reactor is enriched with."
  @spec model() :: Model.t()
  def model do
    {:ok, model} =
      Model.new(
        name: @model_name,
        tasks: [
          [id: :admitted, capability: "Domain.Admit", authority: :select],
          [
            id: :authorized,
            capability: "Network.Authorize",
            authority: :construct,
            after: [:admitted]
          ],
          [
            id: :release,
            capability: "HumanInteraction.Approve",
            properties: ["durable"],
            authority: :select,
            after: [:authorized]
          ],
          [
            id: :commit,
            capability: "Transaction.Commit",
            authority: :construct,
            after: [:release]
          ]
        ]
      )

    model
  end

  @doc "Stable plan IRI of the durable workflow."
  @spec plan_iri() :: String.t()
  def plan_iri, do: Evidence.plan_iri(Subject.bind(model()).id)

  @doc "Builds the un-run, enriched Reactor."
  @spec reactor() :: Reactor.t()
  def reactor do
    alias Reactor.Builder
    r = Builder.new()
    {:ok, r} = Builder.add_input(r, :order)
    {:ok, r} = Builder.add_step(r, :admitted, Admit, order: {:input, :order})
    {:ok, r} = Builder.add_step(r, :authorized, Authorize, admitted: {:result, :admitted})
    {:ok, r} = Builder.add_step(r, :release, AwaitRelease, authorized: {:result, :authorized})

    {:ok, r} =
      Builder.add_step(r, :commit, Commit,
        authorized: {:result, :authorized},
        release: {:result, :release}
      )

    {:ok, r} = Builder.return(r, :commit)
    {:ok, r} = AshPPlan.Reactor.enrich(r, model())
    r
  end

  # ---- runner process ----

  use GenServer

  @doc "Starts a runner holding no state beyond its store and counters."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc "Runs until the release halt; persists the continuation. Returns `{:halted, id}`."
  def run(pid, run_id, order), do: GenServer.call(pid, {:run, run_id, order}, 30_000)

  @doc "Restores continuation `id` from the store and resumes with `decision`."
  def resume(pid, id, decision), do: GenServer.call(pid, {:resume, id, decision}, 30_000)

  @doc "Simulates process death: the runner is killed and all memory discarded."
  @spec kill(pid()) :: :ok
  def kill(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 -> {:error, :not_dead}
    end
  end

  @impl GenServer
  def init(state), do: {:ok, Map.put(state, :reactor, nil)}

  @impl GenServer
  def handle_call({:run, run_id, order}, _from, state) do
    ctx = %{run_id: run_id, counters: Counters.key(state.counters)}

    case Reactor.run(reactor(), %{order: order}, ctx) do
      {:halted, halted} ->
        with {:ok, c} <- Continuation.capture(plan_iri(), run_id, halted, ETFCodec),
             :ok <- ok(Store.put(c, %{dir: state.dir})) do
          {:reply, {:halted, c.id}, %{state | reactor: halted}}
        else
          err -> {:reply, {:error, err}, state}
        end

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:resume, id, decision}, _from, state) do
    reply =
      with {:ok, c} <- Store.fetch(id, %{dir: state.dir}) do
        Continuation.resume(c, ETFCodec, %{
          counters: Counters.key(state.counters),
          release_decision: decision
        })
      end

    {:reply, reply, state}
  end

  defp ok(:ok), do: :ok
  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other
end
