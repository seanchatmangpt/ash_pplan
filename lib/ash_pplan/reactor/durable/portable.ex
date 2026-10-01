defmodule AshPPlan.Reactor.Durable.Portable do
  @moduledoc """
  ETF portability check for values recorded in the durable ledger.

  A checkpoint output must survive the originating BEAM process: pids, ports, references and
  local closures are runtime identities, not values, and recording one would manufacture
  durability for something that cannot be replayed. External funs (`&Mod.fun/arity`) are names,
  not identities, and are admitted when the module is loadable and exports the function.

  `check/1` is the gate a store applies before it persists an output; `decode/1` reads a trusted
  ledger blob (plain `binary_to_term`, atoms decode only inside the trusted store).

  Design derived from mbuhot/magma (MIT per its mix.exs), re-implemented.
  """

  @doc "True when `term` holds only durable values at any depth (map keys, tuples, improper tails)."
  @spec portable?(term()) :: boolean()
  def portable?(term) when is_pid(term) or is_port(term) or is_reference(term), do: false
  def portable?(term) when is_function(term), do: portable_function?(term)

  def portable?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&portable?/1)

  def portable?(term) when is_map(term),
    do: term |> :maps.to_list() |> Enum.all?(fn {k, v} -> portable?(k) and portable?(v) end)

  def portable?([]), do: true
  def portable?([head | tail]), do: portable?(head) and portable?(tail)
  def portable?(_term), do: true

  @doc "`:ok` for a portable term, else a typed refusal."
  @spec check(term()) :: :ok | {:error, :non_portable_runtime_term}
  def check(term), do: if(portable?(term), do: :ok, else: {:error, :non_portable_runtime_term})

  @doc "Encode a portable term (deterministic, compressed) or refuse."
  @spec encode(term()) :: {:ok, binary()} | {:error, :non_portable_runtime_term}
  def encode(term) do
    with :ok <- check(term),
         do: {:ok, :erlang.term_to_binary(term, [:compressed, :deterministic])}
  end

  @doc "Decode a blob written by `encode/1`; the decoded term is re-checked."
  @spec decode(binary()) ::
          {:ok, term()} | {:error, :invalid_payload | :non_portable_runtime_term}
  def decode(blob) when is_binary(blob) do
    term = :erlang.binary_to_term(blob)
    with :ok <- check(term), do: {:ok, term}
  rescue
    ArgumentError -> {:error, :invalid_payload}
  end

  def decode(_), do: {:error, :invalid_payload}

  defp portable_function?(fun) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        {:module, module} = Function.info(fun, :module)
        {:name, name} = Function.info(fun, :name)
        {:arity, arity} = Function.info(fun, :arity)
        Code.ensure_loaded?(module) and function_exported?(module, name, arity)

      {:type, :local} ->
        false
    end
  end
end
