defmodule AshPPlan.Examples.QualifiedFulfillment.Durable do
  @moduledoc """
  Durable halt / kill / resume runner for the qualified-fulfillment human-release gate, on the
  native ledger engine (`AshPPlan.Reactor.Durable.Engine`).

  The workflow is the generated QualifiedFulfillment spine (admit -> authorize -> human release ->
  commit; see `AshPPlan.Test.DurableFx`). `run/3` starts a run in a store and attempts it until
  the release step parks. The attempt is made inside a throwaway process that is killed
  afterwards, so nothing but the store survives. `resume/3` starts a fresh process that holds
  nothing and drives the same run with the human decision: `:approved` delivers the release
  signal, `:refused` cancels the run (the unwinder takes back what was done, nothing commits).

  Consequential effects increment named counters in `AshPPlan.Test.Effects`, an Agent outside
  every runner; a court asserts each ran exactly once across park, kill and resume.
  """

  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Test.DurableFx

  @doc "Stable plan identity of the durable workflow (the run record's plan IRI source)."
  @spec model() :: AshPPlan.Workflow.Model.t()
  def model, do: DurableFx.model()

  @doc "Starts `run_id` for `order`, attempts it in a throwaway process, then kills that process."
  @spec run(term(), String.t(), String.t()) :: {:halted, String.t()} | {:error, term()}
  def run(store, run_id, order) do
    attrs = %{DurableFx.attrs(run_id) | inputs: %{input: %{order: order}}}
    {:ok, _} = Engine.start(store, attrs)

    case in_runner(fn -> Engine.attempt(store, run_id) end) do
      {:parked, _} -> {:halted, run_id}
      other -> {:error, other}
    end
  end

  @doc "A fresh process drives `run_id` with the human `decision`."
  @spec resume(term(), String.t(), :approved | :refused | term()) ::
          {:ok, term()} | {:error, term()}
  def resume(store, run_id, :approved) do
    {:ok, _} = Engine.signal(store, run_id, DurableFx.signal_name(), :approved)

    case in_runner(fn -> Engine.attempt(store, run_id) end) do
      {:completed, result} -> {:ok, result}
      other -> {:error, other}
    end
  end

  def resume(store, run_id, decision) do
    case Engine.cancel(store, run_id) do
      {:ok, _} ->
        in_runner(fn -> Engine.attempt(store, run_id) end)
        {:error, {:release_not_approved, decision}}

      {:error, reason} ->
        {:error, reason}
    end
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
end
