defmodule AshPPlan.Examples.Selfhost.Adapter do
  @moduledoc """
  Test-only adapter `:selfhost`: maps the closure loop's capabilities to the in-repo steps of
  `AshPPlan.Examples.Selfhost.Steps`. `install!/0` registers it for the current test module and
  restores the previous registry on exit.
  """
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Examples.Selfhost.Steps

  @table %{
    repository_observe: {Steps.Observe, []},
    work_select: {Steps.Select, []},
    agent_execute: {Steps.Execute, []},
    repository_integrate: {Steps.Integrate, []},
    verification_run: {Steps.Verify, []},
    evidence_record: {Steps.Record, []}
  }

  @impl true
  def id, do: :selfhost
  @impl true
  def available?, do: Code.ensure_loaded?(Steps.Observe)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)

  @doc """
  Register the adapter in `:extra_adapters` for the rest of the run (idempotent). The generated
  provider courts assert a realization's adapter is a registered one, and `config/test.exs`
  (not owned by the selfhost lane) names only `:ultracode`.
  """
  @spec register!() :: :ok
  def register! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :selfhost, __MODULE__)
    )
  end

  @doc "Register the adapter in `:extra_adapters` for the calling test; restores on exit."
  @spec install!() :: :ok
  def install! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :selfhost, __MODULE__)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
    :ok
  end
end
