defmodule AshPPlan.Reactor.Adapter do
  @moduledoc """
  Behaviour for the only modules allowed to name Reactor implementation modules.

  An adapter maps an operation (`:file_write`) to `{step_module, step_options}`.
  Unknown operations and absent implementations yield a typed
  `{:error, %{reason: :unsupported, adapter: id, detail: term}}`; nothing here
  grants DO authority.
  """

  @callback id() :: atom()
  @callback available?() :: boolean()
  @callback ops() :: [atom()]
  @callback step(op :: atom(), options :: keyword()) ::
              {:ok, {module(), keyword()}} | {:error, map()}

  @doc "Shared step/2 body: table lookup, availability gate, option merge."
  @spec resolve(module(), %{atom() => {module(), keyword()}}, atom(), keyword()) ::
          {:ok, {module(), keyword()}} | {:error, map()}
  def resolve(adapter, table, op, options) do
    {available, options} = Keyword.pop(options, :available?)
    available = if is_nil(available), do: adapter.available?(), else: available

    cond do
      not available ->
        {:error,
         %{reason: :unsupported, adapter: adapter.id(), detail: :implementation_unavailable}}

      true ->
        case Map.fetch(table, op) do
          {:ok, {mod, base}} ->
            {:ok, {mod, Keyword.merge(base, options)}}

          :error ->
            {:error, %{reason: :unsupported, adapter: adapter.id(), detail: {:unknown_op, op}}}
        end
    end
  end
end
