defmodule AshPPlan.Continuation.ETFCodec do
  @moduledoc """
  Conservative Erlang External Term Format codec for halted Reactor values.

  Runtime-only identities such as pids, ports, references and functions are
  refused before encoding. This avoids manufacturing durability for terms that
  cannot be meaningfully replayed after the originating BEAM process is gone.
  Decoding uses `:safe` mode.
  """

  @behaviour AshPPlan.Continuation.Codec

  @impl true
  def id, do: "erlang-external-term"

  @impl true
  def version, do: "1"

  @impl true
  def encode(%Reactor{} = reactor) do
    if portable?(reactor) do
      {:ok, :erlang.term_to_binary(reactor, [:compressed])}
    else
      {:error, :non_portable_runtime_term}
    end
  end

  def encode(other), do: {:error, {:not_a_reactor, other}}

  @impl true
  def decode(payload) when is_binary(payload) do
    try do
      case :erlang.binary_to_term(payload, [:safe]) do
        %Reactor{} = reactor -> {:ok, reactor}
        other -> {:error, {:not_a_reactor, other}}
      end
    rescue
      ArgumentError -> {:error, :invalid_external_term}
    end
  end

  def decode(_payload), do: {:error, :invalid_payload}

  defp portable?(term)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term),
       do: false

  defp portable?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.all?(&portable?/1)
  end

  defp portable?(term) when is_map(term) do
    Enum.all?(term, fn {key, value} -> portable?(key) and portable?(value) end)
  end

  defp portable?([]), do: true
  defp portable?([head | tail]), do: portable?(head) and portable?(tail)
  defp portable?(_term), do: true
end
