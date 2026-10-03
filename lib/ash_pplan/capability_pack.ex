defmodule AshPPlan.CapabilityPack do
  @moduledoc """
  A named bundle of capability declarations contributed by a provider package.

  A pack declares capabilities, execution properties and evidence kinds only.
  Declaring a capability confers no authority; `authority` is a ceiling
  capped at `:construct`.
  """

  alias AshPPlan.Capability
  alias AshPPlan.PolicyClosure.AuthorityCeiling

  @enforce_keys [:id, :capabilities]
  defstruct id: nil,
            version: "0.0.0",
            capabilities: [],
            properties: [],
            evidence: [],
            authority: :construct

  @type t :: %__MODULE__{}

  @doc "Build a pack from a map or keyword list (atom or string keys), then validate it."
  @spec load(map() | keyword() | t()) :: {:ok, t()} | {:error, map()}
  def load(%__MODULE__{} = pack), do: with(:ok <- validate(pack), do: {:ok, pack})

  def load(attrs) when is_map(attrs), do: do_load(Map.new(attrs, fn {k, v} -> {to_key(k), v} end))

  # Guard-safe keyword-list check: a list of `{key, value}` pairs. A bare list
  # (e.g. `[1, 2]`) falls through to the typed `:not_a_map` refusal below.
  def load(attrs) when is_list(attrs) and is_tuple(hd(attrs)) do
    do_load(Map.new(attrs, fn {k, v} -> {to_key(k), v} end))
  end

  def load(_), do: {:error, %{reason: :invalid_pack, detail: :not_a_map}}

  defp do_load(attrs) do
    case attrs do
      %{id: id, capabilities: caps} when is_list(caps) ->
        pack = %__MODULE__{
          id: to_string(id),
          version: Map.get(attrs, :version, "0.0.0"),
          capabilities: Enum.map(caps, &to_string/1),
          properties: attrs |> Map.get(:properties, []) |> Enum.map(&to_atom/1),
          evidence: attrs |> Map.get(:evidence, []) |> Enum.map(&to_atom/1),
          authority: attrs |> Map.get(:authority, :construct) |> to_atom()
        }

        with :ok <- validate(pack), do: {:ok, pack}

      _ ->
        {:error, %{reason: :invalid_pack, detail: :missing_id_or_capabilities}}
    end
  end

  @doc "Validate pack invariants (SHACL shape `ontology/capability_pack.ttl` mirrors these)."
  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = p) do
    cond do
      p.id in [nil, ""] ->
        {:error, %{reason: :invalid_pack, detail: :empty_id}}

      p.capabilities == [] ->
        {:error, %{reason: :invalid_pack, detail: :no_capabilities}}

      p.capabilities != Enum.uniq(p.capabilities) ->
        {:error, %{reason: :invalid_pack, detail: :duplicate_capabilities}}

      bad = Enum.find(p.capabilities, &match?({:error, _}, Capability.parse(&1))) ->
        {:error, %{reason: :invalid_capability, capability: bad}}

      match?({:error, _}, AuthorityCeiling.admit(p.authority)) ->
        {:error, %{reason: :authority_ceiling, authority: p.authority, max: :construct}}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, %{reason: :invalid_pack, detail: :not_a_pack}}

  defp to_key(k) when is_atom(k), do: k
  defp to_key(k) when is_binary(k), do: String.to_atom(k)

  # Non-string/atom keys never map to `:id`/`:capabilities`; pass them through so
  # `load/1` refuses with a typed `:missing_id_or_capabilities` instead of raising.
  defp to_key(other), do: other

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)
  defp to_atom(other), do: other
end
