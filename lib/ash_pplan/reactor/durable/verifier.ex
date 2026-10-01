defmodule AshPPlan.Reactor.Durable.Verifier do
  @moduledoc """
  Refuses a reactor that nests a durable wait step inside a composite that runs a private reactor.

  `group`, `around`, `recurse` and `compose` run their steps inline in a reactor of their own,
  which never reaches the outer plan: such a step holds no checkpoint and cannot halt to park.
  Rather than let it fail obscurely at run time, the plan is walked before it runs and refused
  loudly with `%{reason: :durable_step_in_nesting_composite, composite: name, step: name}`.

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """

  @nesting [Reactor.Step.Group, Reactor.Step.Around, Reactor.Step.Recurse, Reactor.Step.Compose]
  @durable [
    AshPPlan.Reactor.Durable.Steps.Await,
    AshPPlan.Reactor.Durable.Steps.Poll,
    AshPPlan.Reactor.Durable.Steps.Dispatch
  ]

  @spec verify(Reactor.t()) :: :ok | {:error, map()}
  def verify(%Reactor{steps: steps}) do
    Enum.find_value(steps, :ok, fn step ->
      case check(step, nil) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp check(%Reactor.Step{} = step, composite) do
    {module, _opts} = unwrap(step.impl)

    cond do
      composite != nil and module in @durable ->
        {:error,
         %{
           reason: :durable_step_in_nesting_composite,
           composite: composite,
           step: step.name,
           module: module
         }}

      true ->
        composite = if module in @nesting, do: composite || step.name, else: composite
        nested = nested(step)

        Enum.find_value(nested, :ok, fn child ->
          case check(child, composite) do
            :ok -> nil
            error -> error
          end
        end)
    end
  end

  defp check(_other, _composite), do: :ok

  # Children a step carries: what `nested_steps/1` reports (map, switch) plus the steps or
  # reactors held in its options (group, around, recurse and compose keep theirs there).
  defp nested(%Reactor.Step{impl: impl}) do
    {module, opts} = unwrap(impl)

    declared =
      if Code.ensure_loaded?(module) and function_exported?(module, :nested_steps, 1),
        do: module.nested_steps(opts),
        else: []

    declared ++ Enum.flat_map(opts, fn {_key, value} -> held(value) end)
  rescue
    _ -> []
  end

  defp held(%Reactor{steps: steps}), do: steps

  defp held([%Reactor.Step{} | _] = steps), do: Enum.filter(steps, &is_struct(&1, Reactor.Step))
  defp held(_), do: []

  # Look through a Checkpointed wrapper to the step it carries.
  defp unwrap({AshPPlan.Reactor.Durable.Checkpointed, opts}),
    do: opts |> Keyword.fetch!(:durable_inner) |> normalize()

  defp unwrap(impl), do: normalize(impl)

  defp normalize({m, o}), do: {m, o}
  defp normalize(m) when is_atom(m), do: {m, []}
end
