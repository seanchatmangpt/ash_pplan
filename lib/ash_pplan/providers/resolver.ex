defmodule AshPPlan.Providers.Resolver do
  @moduledoc """
  Pure provider resolution for a capability requirement.

  A provider is a candidate only if it passes, in order: semantic capability
  compatibility, execution-property support, evidence support, authority
  ceiling, and availability (`qualify/2`). Candidates are ordered by cost, then
  provider id. The first candidate whose `realize/2` succeeds is selected.
  Selection never grants authority: the ceiling is capped at `:construct`.
  """

  alias AshPPlan.Capability

  @authority_rank %{none: 0, observe: 1, select: 2, plan: 3, construct: 4}

  @type rejection :: {module(), term()}

  @doc "Resolve a requirement against provider modules."
  @spec resolve([module()], map(), map()) :: {:ok, map()} | {:error, map()}
  def resolve(modules, requirement, ctx \\ %{})

  def resolve(modules, requirement, ctx) when is_map(requirement) do
    with {:ok, cap} <- Capability.parse(Map.get(requirement, :capability)),
         :ok <- check_authority(requirement, ctx) do
      requirement = %{requirement | capability: cap.id}
      {candidates, rejected} = partition(modules, requirement, ctx)
      ordered = Enum.sort_by(candidates, &{&1.cost(), to_string(&1.id())})
      realize_first(ordered, requirement, ctx, rejected, ordered)
    else
      {:error, reason} ->
        {:error, %{reason: :no_qualified_provider, rejected: [], detail: reason}}
    end
  end

  # Typed-refusal law: a requirement that is not a map is refused, never a BadMapError.
  def resolve(_modules, _requirement, _ctx),
    do: {:error, %{reason: :no_qualified_provider, rejected: [], detail: :invalid_requirement}}

  defp partition(modules, requirement, ctx) do
    Enum.reduce(modules, {[], []}, fn mod, {ok, bad} ->
      case safe_qualify(mod, requirement, ctx) do
        :ok -> {[mod | ok], bad}
        {:error, reason} -> {ok, [{mod, reason} | bad]}
      end
    end)
    |> then(fn {ok, bad} -> {Enum.reverse(ok), Enum.reverse(bad)} end)
  end

  defp qualify(mod, requirement, ctx) do
    with :ok <- check_capability(mod, requirement),
         :ok <- check_subset(:properties, requirement, mod.properties()),
         :ok <- check_subset(:evidence, requirement, mod.evidence()) do
      availability(mod, requirement, ctx)
    end
  end

  defp check_capability(mod, %{capability: cap}) do
    if cap in mod.capabilities(), do: :ok, else: {:error, :capability_unsupported}
  end

  defp check_subset(key, requirement, supported) do
    case Map.get(requirement, key, []) |> List.wrap() |> Enum.reject(&(&1 in supported)) do
      [] -> :ok
      missing -> {:error, {:"missing_#{key}", Enum.sort(missing)}}
    end
  end

  defp availability(mod, requirement, ctx) do
    case mod.qualify(requirement, ctx) do
      :ok -> :ok
      {:error, {:unsupported, _} = unsupported} -> {:error, unsupported}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  # Typed-refusal law: a provider whose qualify/2 raises is a rejected candidate,
  # never a crash of resolution.
  defp safe_qualify(mod, requirement, ctx) do
    qualify(mod, requirement, ctx)
  rescue
    e -> {:error, {:qualify_raised, Exception.message(e)}}
  end

  defp check_authority(requirement, ctx) do
    ceiling = Map.get(ctx, :ceiling, :construct)
    wanted = Map.get(requirement, :authority, :construct)

    cond do
      wanted == :do ->
        {:error, {:authority_refused, :do}}

      ceiling == :do ->
        {:error, {:authority_refused, :do}}

      not Map.has_key?(@authority_rank, wanted) ->
        {:error, {:unknown_authority, wanted}}

      not Map.has_key?(@authority_rank, ceiling) ->
        {:error, {:unknown_authority, ceiling}}

      @authority_rank[wanted] > @authority_rank[ceiling] ->
        {:error, {:authority_exceeds_ceiling, wanted, ceiling}}

      true ->
        :ok
    end
  end

  defp realize_first([], _req, _ctx, rejected, _ordered) do
    {:error, %{reason: :no_qualified_provider, rejected: rejected}}
  end

  defp realize_first([mod | rest], requirement, ctx, rejected, ordered) do
    case safe_realize(mod, requirement, ctx) do
      {:ok, realization} ->
        realize_step(mod, realization, rest, requirement, ctx, rejected, ordered)

      {:error, reason} ->
        realize_first(
          rest,
          requirement,
          ctx,
          rejected ++ [{mod, {:realize_failed, reason}}],
          ordered
        )
    end
  end

  # A realization is lawful only if `AshPPlan.Reactor` can bind it to a step;
  # an :unsupported adapter makes the provider a typed rejected candidate.
  defp realize_step(mod, realization, rest, requirement, ctx, rejected, ordered) do
    case AshPPlan.Reactor.step_for(realization) do
      {:ok, {step, step_options}} ->
        {:ok,
         %{
           provider: mod,
           realization: realization,
           adapter: realization.binding.adapter,
           op: realization.binding.op,
           step: {step, step_options},
           candidates: ordered,
           rejected: rejected,
           reason:
             "selected #{inspect(mod)} via #{realization.binding.adapter}/#{realization.binding.op}: " <>
               "lowest cost then id among #{length(ordered)} qualified"
         }}

      {:error, reason} ->
        realize_first(
          rest,
          requirement,
          ctx,
          rejected ++ [{mod, {:unsupported_adapter, reason}}],
          ordered
        )
    end
  end

  defp safe_realize(mod, requirement, ctx) do
    case mod.realize(requirement, ctx) do
      {:ok, %AshPPlan.Realization{} = realization} ->
        case AshPPlan.Realization.validate(realization) do
          :ok -> {:ok, realization}
          {:error, reason} -> {:error, {:invalid_realization, reason}}
        end

      {:ok, other} ->
        {:error, {:not_a_realization, other}}

      other ->
        other
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end
end
