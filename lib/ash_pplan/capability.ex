defmodule AshPPlan.Capability do
  @moduledoc """
  Typed capability identity: `Family.Name`, e.g. `File.Write`.

  A capability is a semantic requirement, never an implementation. Plans target
  capabilities; `AshPPlan.Provider` realizations are resolved separately.
  """

  @families ~w(domain network filesystem process event state actuation transaction
               durability scheduling observation human_interaction distributed
               authority evidence file remote verification artifact)a

  @id_pattern ~r/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/

  @enforce_keys [:id, :family, :name]
  defstruct [:id, :family, :name]

  @type id :: String.t()
  @type t :: %__MODULE__{id: id(), family: atom(), name: String.t()}

  @spec families() :: [atom()]
  def families, do: @families ++ extra_families()

  # Application-specific families are registered by the host (e.g. a test suite) via
  # `config :ash_pplan, :extra_capability_families, [...]`; the shipped set stays generic.
  defp extra_families, do: Application.get_env(:ash_pplan, :extra_capability_families, [])

  @doc "Parse `\"Family.Name\"` (name may contain further dots) into a capability."
  @spec parse(id() | atom() | t()) :: {:ok, t()} | {:error, map()}
  def parse(%__MODULE__{} = c), do: {:ok, c}
  def parse(id) when is_atom(id), do: id |> Atom.to_string() |> parse()

  def parse(id) when is_binary(id) do
    with true <- Regex.match?(@id_pattern, id),
         [family, name] <- String.split(id, ".", parts: 2),
         {:ok, fam} <- family_atom(family) do
      {:ok, %__MODULE__{id: id, family: fam, name: name}}
    else
      _ -> {:error, %{reason: :invalid_capability, capability: id}}
    end
  end

  def parse(other), do: {:error, %{reason: :invalid_capability, capability: other}}

  @doc "True when `id` parses as a capability."
  @spec valid?(term()) :: boolean()
  def valid?(id), do: match?({:ok, _}, parse(id))

  @doc "Canonical string id of anything `parse/1` accepts."
  @spec normalize(id() | atom() | t()) :: {:ok, id()} | {:error, map()}
  def normalize(value) do
    with {:ok, %__MODULE__{id: id}} <- parse(value), do: {:ok, id}
  end

  defp family_atom(family) do
    snake = Macro.underscore(family)

    case Enum.find(families(), &(Atom.to_string(&1) == snake)) do
      nil -> :error
      fam -> {:ok, fam}
    end
  end
end
