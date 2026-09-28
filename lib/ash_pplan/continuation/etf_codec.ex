defmodule AshPPlan.Continuation.ETFCodec do
  @moduledoc """
  Conservative Erlang External Term Format codec for halted Reactor values.

  Runtime-only identities such as pids, ports, references and closures (local
  funs) are refused before encoding. This avoids manufacturing durability for
  terms that cannot be meaningfully replayed after the originating BEAM
  process is gone.

  External funs (`&Module.function/arity`) are admitted when the module is
  loadable and exports that function: they are names, not runtime identities,
  and a halted Reactor carries some in its execution plan graph.

  Decoding uses `:safe` mode and then re-applies the same portability check to
  the decoded term, so a payload this codec would refuse to encode is also
  refused on decode.

  Portability is not authority. An admitted external fun still names code that
  can run on resume; tamper resistance against an adversary who can write to
  the store requires `AshPPlan.Continuation`'s keyed `:integrity_key` option.
  """

  @behaviour AshPPlan.Continuation.Codec

  @impl true
  def id, do: "erlang-external-term"

  @impl true
  def version, do: "1"

  @impl true
  def encode(%Reactor{} = reactor) do
    if portable?(reactor) do
      {:ok, :erlang.term_to_binary(reactor, [:compressed, :deterministic])}
    else
      {:error, :non_portable_runtime_term}
    end
  end

  def encode(other), do: {:error, {:not_a_reactor, other}}

  @impl true
  def decode(payload) when is_binary(payload) do
    case safe_binary_to_term(payload) do
      {:ok, %Reactor{} = reactor} ->
        if portable?(reactor), do: {:ok, reactor}, else: {:error, :non_portable_runtime_term}

      {:ok, _other} ->
        {:error, :not_a_reactor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_payload), do: {:error, :invalid_payload}

  @doc """
  Returns whether a term contains only durable values.

  Pids, ports, references and closures are refused at any depth, including
  map keys, tuple elements, improper list tails and struct fields. External
  funs are admitted only when they name an exported function.
  """
  @spec portable?(term()) :: boolean()
  def portable?(term) when is_pid(term) or is_port(term) or is_reference(term), do: false
  def portable?(term) when is_function(term), do: portable_function?(term)

  def portable?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.all?(&portable?/1)
  end

  def portable?(term) when is_map(term) do
    term
    |> :maps.to_list()
    |> Enum.all?(fn {key, value} -> portable?(key) and portable?(value) end)
  end

  def portable?([]), do: true
  def portable?([head | tail]), do: portable?(head) and portable?(tail)
  def portable?(_term), do: true

  defp portable_function?(fun) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        {:module, module} = Function.info(fun, :module)
        {:name, name} = Function.info(fun, :name)
        {:arity, arity} = Function.info(fun, :arity)

        is_atom(module) and Code.ensure_loaded?(module) and
          function_exported?(module, name, arity)

      {:type, :local} ->
        false
    end
  end

  defp safe_binary_to_term(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_external_term}
  end
end
