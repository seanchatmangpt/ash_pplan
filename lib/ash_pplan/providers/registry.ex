defmodule AshPPlan.Providers.Registry do
  @moduledoc """
  Immutable provider registry with generation fencing.

  Every mutation (`register/2`, `seal/2`) bumps the generation. `seal/2` drops
  a failed provider so the next lawful provider is selected; sealing never
  crashes resolution, and an empty candidate set yields a typed refusal.
  """

  alias AshPPlan.Providers.Resolver

  @default ~w(Domain Network File Process EventState Durability Scheduling Observation A2A)

  defstruct providers: [], sealed: %{}, generation: 0

  @type t :: %__MODULE__{providers: [module()], sealed: map(), generation: non_neg_integer()}

  @spec new([module()]) :: t()
  def new(modules \\ []), do: %__MODULE__{providers: Enum.uniq(modules), generation: 0}

  @doc "Registry of the in-repo providers that are currently compiled."
  @spec default() :: t()
  def default do
    @default
    |> Enum.map(&Module.concat(AshPPlan.Providers, &1))
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :realize, 2)))
    |> new()
  end

  @spec register(t(), module()) :: t()
  def register(%__MODULE__{} = reg, module) when is_atom(module) do
    %{
      reg
      | providers: Enum.uniq(reg.providers ++ [module]),
        sealed: Map.delete(reg.sealed, module),
        generation: reg.generation + 1
    }
  end

  @doc "Active (unsealed) providers."
  @spec providers(t()) :: [module()]
  def providers(%__MODULE__{providers: p}), do: p

  @doc "Drop a failed provider and bump the generation."
  @spec seal(t(), module(), term()) :: t()
  def seal(%__MODULE__{} = reg, module, reason \\ :failed) do
    if module in reg.providers do
      %{
        reg
        | providers: List.delete(reg.providers, module),
          sealed: Map.put(reg.sealed, module, reason),
          generation: reg.generation + 1
      }
    else
      reg
    end
  end

  @spec resolve(t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def resolve(%__MODULE__{providers: modules}, requirement, ctx \\ %{}) do
    Resolver.resolve(modules, requirement, ctx)
  end
end
