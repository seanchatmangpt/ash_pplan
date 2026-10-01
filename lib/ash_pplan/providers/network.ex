defmodule AshPPlan.Providers.Network do
  @moduledoc """
  HTTP realizations via reactor_req (Reactor.Req.Step).

  Capabilities: #{inspect(~w(Network.Get Network.Post Network.Put Network.Patch Network.Delete Network.Head))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Network.Get Network.Post Network.Put Network.Patch Network.Delete Network.Head)
  @properties [:retryable]
  @evidence [:http_response]
  @table %{
    "Network.Get" => {Reactor.Req.Step, fun: :get},
    "Network.Post" => {Reactor.Req.Step, fun: :post},
    "Network.Put" => {Reactor.Req.Step, fun: :put},
    "Network.Patch" => {Reactor.Req.Step, fun: :patch},
    "Network.Delete" => {Reactor.Req.Step, fun: :delete},
    "Network.Head" => {Reactor.Req.Step, fun: :head}
  }

  @impl true
  def id, do: :network
  @impl true
  def capabilities, do: @capabilities
  @impl true
  def properties, do: @properties
  @impl true
  def evidence, do: @evidence
  @impl true
  def cost, do: 3

  @impl true
  def qualify(requirement, context),
    do: Common.qualify(requirement, context, @capabilities, @properties, @evidence)

  @impl true
  def realize(requirement, context) do
    with :ok <- qualify(requirement, context) do
      Common.realize(requirement, id(), @table)
    end
  end
end
