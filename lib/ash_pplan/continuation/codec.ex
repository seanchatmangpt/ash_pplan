defmodule AshPPlan.Continuation.Codec do
  @moduledoc """
  Behaviour for encoding a halted Reactor into a durable continuation payload.

  A codec is part of the persistence contract and therefore has a stable
  identity and version. Codecs must not perform persistence themselves.
  """

  @callback id() :: String.t()
  @callback version() :: String.t()
  @callback encode(Reactor.t()) :: {:ok, binary()} | {:error, term()}
  @callback decode(binary()) :: {:ok, Reactor.t()} | {:error, term()}
end
