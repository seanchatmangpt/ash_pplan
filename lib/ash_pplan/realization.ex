defmodule AshPPlan.Realization do
  @moduledoc """
  A provider's description of how a capability is realized, independent of any
  Reactor extension. Only `AshPPlan.Reactor` turns a realization into Reactor
  steps; workflows and generated catalogs never name an implementation.

  The binding is `%{adapter: atom, op: atom}` where `op` is the capability id
  downcased with `.` replaced by `_` (`File.Write` -> `:file_write`) and
  `adapter` is one of #{inspect(~w(reactor_file reactor_req reactor_process ash_reactor local ultracode)a)}.
  """

  @adapters ~w(reactor_file reactor_req reactor_process ash_reactor local ultracode)a

  @enforce_keys [:capability, :provider]
  defstruct capability: nil, provider: nil, binding: nil, options: [], properties: []

  @type binding :: %{required(:adapter) => atom(), required(:op) => atom()}
  @type t :: %__MODULE__{
          capability: String.t(),
          provider: atom(),
          binding: binding() | nil,
          options: keyword(),
          properties: [atom()]
        }

  @doc "The adapter ids a binding may name."
  @spec adapters() :: [atom()]
  def adapters, do: @adapters

  @doc "Canonical operation id for a capability id: `File.Write` -> `:file_write`."
  @spec op_for(String.t()) :: atom()
  def op_for(capability) when is_binary(capability) do
    capability |> String.downcase() |> String.replace(".", "_") |> String.to_atom()
  end

  @doc "Check the binding shape; returns `:ok` or `{:error, reason}`."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{capability: cap, binding: %{adapter: adapter, op: op}})
      when is_binary(cap) and is_atom(op) do
    cond do
      adapter not in @adapters -> {:error, {:invalid_binding, {:unknown_adapter, adapter}}}
      op != op_for(cap) -> {:error, {:invalid_binding, {:op_mismatch, op, op_for(cap)}}}
      true -> :ok
    end
  end

  def validate(%__MODULE__{binding: binding}), do: {:error, {:invalid_binding, binding}}

  @doc """
  Build a validated realization. Accepts `%{adapter:, op:}` bindings (or
  `:adapter`/`:operation` keys at the top level of `map`). A map without an explicit
  binding (the legacy `%{step:, options:, provider:}` shape) yields `binding: nil`, which
  `validate/1` refuses: providers describe, they never name a step.
  """
  @spec from_map(map(), String.t()) :: t()
  def from_map(%{provider: provider} = map, capability) do
    binding =
      case map do
        %{binding: %{adapter: _, op: _} = b} -> b
        %{adapter: a, op: o} -> %{adapter: a, op: o}
        %{adapter: a, operation: o} -> %{adapter: a, op: o}
        _ -> nil
      end

    %__MODULE__{
      capability: capability,
      provider: provider,
      binding: binding,
      options: Map.get(map, :options, []),
      properties: Map.get(map, :properties, [])
    }
  end

  @doc "Like `from_map/2` but returns `{:error, reason}` for an invalid binding."
  @spec new(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def new(map, capability) do
    r = from_map(map, capability)

    case validate(r) do
      :ok -> {:ok, r}
      {:error, _} = e -> e
    end
  end
end
