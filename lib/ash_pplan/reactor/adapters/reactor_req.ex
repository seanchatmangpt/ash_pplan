defmodule AshPPlan.Reactor.Adapters.ReactorReq do
  @moduledoc "Adapter for HTTP operations via `reactor_req`."
  @behaviour AshPPlan.Reactor.Adapter

  @table %{
    network_get: {Reactor.Req.Step, [fun: :get]},
    network_post: {Reactor.Req.Step, [fun: :post]},
    network_put: {Reactor.Req.Step, [fun: :put]},
    network_patch: {Reactor.Req.Step, [fun: :patch]},
    network_delete: {Reactor.Req.Step, [fun: :delete]},
    network_head: {Reactor.Req.Step, [fun: :head]},
    remote_read: {Reactor.Req.Step, [fun: :get]}
  }

  @impl true
  def id, do: :reactor_req
  @impl true
  def available?, do: Code.ensure_loaded?(Reactor.Req.Step)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end
