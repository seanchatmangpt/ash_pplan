defmodule AshPPlan.Capability do
  @moduledoc """
  Typed capability identity: `Family.Name`, e.g. `File.Write`.

  A capability is a semantic requirement, never an implementation. Plans target
  capabilities; `AshPPlan.Provider` realizations are resolved separately.
  """

  @families ~w(domain network filesystem process event state actuation transaction
               durability scheduling observation human_interaction distributed
               authority evidence file remote repository work agent verification artifact)a

  @enforce_keys [:id, :family, :name]
  defstruct [:id, :family, :name]

  @type id :: String.t()
  @type t :: %__MODULE__{id: id(), family: atom(), name: String.t()}

  @spec families() :: [atom()]
  def families, do: @families

  @doc "Parse `\"Family.Name\"` (name may contain further dots) into a capability."
  @spec parse(id() | atom() | t()) :: {:ok, t()} | {:error, map()}
  def parse(%__MODULE__{} = c), do: {:ok, c}
  def parse(id) when is_atom(id), do: id |> Atom.to_string() |> parse()

  def parse(id) when is_binary(id) do
    with [family, name] when name != "" <- String.split(id, ".", parts: 2),
         {:ok, fam} <- family_atom(family) do
      {:ok, %__MODULE__{id: id, family: fam, name: name}}
    else
      _ -> {:error, %{reason: :invalid_capability, capability: id}}
    end
  end

  def parse(other), do: {:error, %{reason: :invalid_capability, capability: other}}

  defp family_atom(family) do
    snake = family |> Macro.underscore() |> String.to_atom()
    if snake in @families, do: {:ok, snake}, else: :error
  end
end
