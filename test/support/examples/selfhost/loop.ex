defmodule AshPPlan.Examples.Selfhost.Loop do
  @moduledoc """
  The self-hosting closure loop on the native durable engine.

  The loop's graph is the generated `selfhost` workflow
  (`AshPPlan.Examples.Workflows.Selfhost`, an `ap:Workflow` in `examples.ttl`), and the frontier
  it consumes is that same graph's task list (`AshPPlan.Examples.Selfhost.Frontier`). One
  iteration is one durable run of the workflow: observe, select, execute (deterministic local
  agent under the `:construct` ceiling), integration gate (durable park), integrate, verify,
  record standing. The runner process is killed at the gate of every iteration; a fresh runner
  resumes from the store, so no in-memory state carries the loop.

  `advance/2` performs one transition (start-and-park, or resume the in-flight run) so a court
  can kill the whole driver between transitions; `run/2` repeats `advance/2` until the frontier
  is empty or an iteration loses standing. `receipt/1` is the loop receipt: it names the
  loop-closure order and grants standing only when the frontier is empty, each item executed
  once, and every run completed. Nothing here grants DO authority.
  """

  alias AshPPlan.Examples.Selfhost.{Frontier, Steps}
  alias AshPPlan.Reactor.Durable.{Engine, Status}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.{Runtime, Subject}

  @workflow AshPPlan.Examples.Workflows.Selfhost
  @gate "selfhost_integration_gate"

  @providers [
    AshPPlan.Providers.SelfhostRepository,
    AshPPlan.Providers.SelfhostWork,
    AshPPlan.Providers.SelfhostAgent,
    AshPPlan.Providers.SelfhostGate,
    AshPPlan.Providers.SelfhostVerification,
    AshPPlan.Providers.SelfhostEvidence
  ]

  @doc "The generated workflow module the loop executes."
  @spec workflow() :: module()
  def workflow, do: @workflow

  @doc "The generated providers, in registry order."
  @spec providers() :: [module()]
  def providers, do: @providers

  @doc "Bindings for every task of the workflow, resolved through the generated providers."
  @spec bindings() :: map()
  def bindings do
    {:ok, %{bindings: bindings}} = Runtime.resolve(@workflow, providers: @providers)
    bindings
  end

  @doc """
  One transition. Resumes the in-flight (non-terminal) run if there is one, otherwise starts
  the next iteration if the frontier is not closed. Each attempt runs in a throwaway process
  that is killed afterwards.

  Returns `{:parked, run_id}`, `{:completed, run_id}`, `{:failed, run_id, reason}` or `:closed`.
  """
  @spec advance(term(), keyword()) :: tuple() | :closed
  def advance(store, opts \\ []) do
    case in_flight(store) do
      nil -> start_next(store, opts)
      run -> resume(store, run)
    end
  end

  @doc "Repeat `advance/2` until the frontier is closed, an iteration fails, or `:max_steps` pass."
  @spec run(term(), keyword()) :: :closed | {:failed, String.t(), term()} | :max_steps
  def run(store, opts \\ []) do
    loop(store, opts, Keyword.get(opts, :max_steps, 100))
  end

  defp loop(_store, _opts, 0), do: :max_steps

  defp loop(store, opts, n) do
    case advance(store, opts) do
      :closed -> :closed
      {:failed, _, _} = failed -> failed
      _ -> loop(store, opts, n - 1)
    end
  end

  defp start_next(store, opts) do
    cond do
      Enum.any?(Frontier.items(), &(&1.status == :refused)) ->
        :closed

      Frontier.open() == [] ->
        :closed

      true ->
        id = "selfhost-" <> Integer.to_string(length(Ets.list_runs(store)) + 1)

        attrs = %{
          id: id,
          model: @workflow.model(),
          bindings: bindings(),
          inputs: %{input: %{loop: Keyword.get(opts, :loop, "selfhost")}},
          context: %{},
          parent: nil
        }

        {:ok, _} = Engine.start(store, attrs)
        settle(store, id, in_runner(fn -> Engine.attempt(store, id) end))
    end
  end

  defp resume(store, run) do
    {:ok, _} = Engine.signal(store, run.id, @gate, :approved)
    settle(store, run.id, in_runner(fn -> Engine.attempt(store, run.id) end))
  end

  defp settle(store, id, outcome) do
    case outcome do
      {:parked, _} ->
        {:parked, id}

      {:completed, _} ->
        {:completed, id}

      other ->
        item = Frontier.claimed(id)
        if item, do: Frontier.refuse(item)
        {:failed, id, failure_reason(store, id, other)}
    end
  end

  defp failure_reason(store, id, outcome) do
    %{status: Engine.fetch(store, id).status, outcome: outcome}
  end

  defp in_flight(store) do
    Enum.find(Ets.list_runs(store), &(not Status.terminal?(&1.status)))
  end

  @doc "Runs `fun` in a process that is killed afterwards: all in-memory state is discarded."
  @spec in_runner((-> term())) :: term()
  def in_runner(fun) do
    parent = self()
    ref = make_ref()
    pid = spawn(fn -> send(parent, {ref, fun.()}) end)
    mon = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        kill(pid)
        result

      {:DOWN, ^mon, _, _, reason} ->
        {:runner_died, reason}
    after
      30_000 -> {:error, :runner_timeout}
    end
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 -> {:error, :not_dead}
    end
  end

  @doc """
  The loop receipt. Standing is granted only when the frontier is empty, each item executed
  exactly once, and every run completed with a standing run receipt; otherwise standing is
  `:lost` with a `broken_term`.
  """
  @spec receipt(term()) :: map()
  def receipt(store) do
    runs = Ets.list_runs(store) |> Enum.sort_by(& &1.id)
    items = Frontier.items()
    executions = Frontier.executions()
    run_receipts = Frontier.receipts()
    open = Frontier.open()
    refused = for i <- items, i.status == :refused, do: i.id
    all_completed? = runs != [] and Enum.all?(runs, &(&1.status == :completed))
    once? = Enum.all?(items, &(Map.get(executions, &1.id) == 1))
    recorded? = Enum.all?(runs, &Map.has_key?(run_receipts, &1.id))

    broken =
      cond do
        refused != [] -> :authority_refused
        open != [] -> :frontier_not_empty
        not all_completed? -> :run_not_completed
        not once? -> :item_not_executed_once
        not recorded? -> :run_receipt_missing
        true -> nil
      end

    %{
      loop_closure_order: Steps.closure_order(),
      identity: %{
        workflow: @workflow.model().name,
        subject_digest: digest(Subject.bind(@workflow.model())),
        runs: Enum.map(runs, & &1.id)
      },
      authority: %{ceiling: Steps.ceiling(), do_granted: false},
      consequence: %{frontier_open: open, refused: refused, executions: executions},
      replay: %{statuses: Map.new(runs, &{&1.id, &1.status}), run_receipts: run_receipts},
      standing: if(broken, do: :lost, else: :standing),
      broken_term: broken
    }
  end

  defp digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
      |> Base.encode16(case: :lower)

  @doc false
  def gate_signal, do: @gate
end
