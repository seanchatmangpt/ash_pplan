defmodule AshPPlan.Compiler do
  @moduledoc """
  Compiles admitted P-PLAN topology into Reactor's public `Reactor.Builder` API.

  The compiler owns validation and projection only. Step behavior remains a
  caller-supplied Reactor step implementation, and Reactor remains the executor.
  """

  alias AshPPlan.Compiler.Error
  alias AshPPlan.Generated.PlanCatalog
  alias AshPPlan.Step.ReturnTerminals
  alias Reactor.{Argument, Builder}

  @return_step {:ash_pplan, :return}
  @terminal_argument_names [
    :terminal_0,
    :terminal_1,
    :terminal_2,
    :terminal_3,
    :terminal_4,
    :terminal_5,
    :terminal_6,
    :terminal_7,
    :terminal_8,
    :terminal_9,
    :terminal_10,
    :terminal_11,
    :terminal_12,
    :terminal_13,
    :terminal_14,
    :terminal_15
  ]

  @doc "Compiles a generated/cataloged plan by IRI."
  def compile(plan_iri, handlers) when is_binary(plan_iri) and is_map(handlers) do
    case PlanCatalog.fetch(plan_iri) do
      nil ->
        {:error, error(:unknown_plan, %{plan_iri: plan_iri})}

      plan ->
        compile_spec(plan, handlers)
    end
  end

  @doc "Compiles a pure-data plan specification after fail-closed validation."
  def compile_spec(%{iri: plan_iri, steps: steps} = plan, handlers)
      when is_binary(plan_iri) and is_list(steps) and is_map(handlers) do
    with :ok <- validate_steps(steps),
         :ok <- validate_predecessors(steps),
         :ok <- validate_handlers(steps, handlers),
         {:ok, ordered_steps} <- topological_order(steps),
         {:ok, reactor} <- Builder.add_input(Builder.new(plan_iri), :input),
         {:ok, reactor} <- add_steps(reactor, ordered_steps, handlers, plan_iri),
         {:ok, reactor} <- add_return(reactor, plan) do
      {:ok, reactor}
    end
  end

  def compile_spec(plan, handlers) do
    {:error, error(:invalid_plan_spec, %{plan: plan, handlers?: is_map(handlers)})}
  end

  defp validate_steps([]), do: {:error, error(:empty_plan, %{})}

  defp validate_steps(steps) do
    cond do
      not Enum.all?(steps, &valid_step?/1) ->
        {:error, error(:invalid_step_spec, %{})}

      true ->
        ids = Enum.map(steps, & &1.iri)
        duplicates = ids -- Enum.uniq(ids)

        if duplicates == [] do
          :ok
        else
          {:error, error(:duplicate_steps, %{steps: Enum.uniq(duplicates)})}
        end
    end
  end

  defp valid_step?(%{iri: iri, predecessors: predecessors, inputs: inputs, outputs: outputs})
       when is_binary(iri) and is_list(predecessors) and is_list(inputs) and is_list(outputs) do
    Enum.all?([predecessors, inputs, outputs], fn values ->
      Enum.all?(values, &is_binary/1)
    end)
  end

  defp valid_step?(_step), do: false

  defp validate_predecessors(steps) do
    known = steps |> Enum.map(& &1.iri) |> MapSet.new()

    dangling =
      for step <- steps,
          predecessor <- Enum.uniq(step.predecessors),
          not MapSet.member?(known, predecessor),
          do: {step.iri, predecessor}

    if dangling == [] do
      :ok
    else
      {:error, error(:dangling_predecessors, %{edges: dangling})}
    end
  end

  defp validate_handlers(steps, handlers) do
    missing =
      steps
      |> Enum.map(& &1.iri)
      |> Enum.reject(&Map.has_key?(handlers, &1))
      |> Enum.sort()

    invalid =
      steps
      |> Enum.map(& &1.iri)
      |> Enum.filter(&Map.has_key?(handlers, &1))
      |> Enum.reject(&valid_handler?(Map.fetch!(handlers, &1)))
      |> Enum.sort()

    cond do
      missing != [] -> {:error, error(:missing_handlers, %{steps: missing})}
      invalid != [] -> {:error, error(:invalid_handlers, %{steps: invalid})}
      true -> :ok
    end
  end

  defp valid_handler?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :run, 3)
  end

  defp valid_handler?({module, options}) when is_atom(module) and is_list(options) do
    valid_handler?(module)
  end

  defp valid_handler?(_handler), do: false

  defp topological_order(steps) do
    step_by_iri = Map.new(steps, &{&1.iri, &1})

    indegrees =
      Map.new(steps, fn step ->
        {step.iri, step.predecessors |> Enum.uniq() |> length()}
      end)

    dependents =
      Enum.reduce(steps, %{}, fn step, acc ->
        Enum.reduce(Enum.uniq(step.predecessors), acc, fn predecessor, acc ->
          Map.update(acc, predecessor, [step.iri], &[step.iri | &1])
        end)
      end)

    roots =
      indegrees
      |> Enum.filter(fn {_iri, degree} -> degree == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {order, _indegrees} = walk_topology(roots, indegrees, dependents, [])

    if length(order) == length(steps) do
      {:ok, Enum.map(order, &Map.fetch!(step_by_iri, &1))}
    else
      cyclic = Map.keys(step_by_iri) -- order
      {:error, error(:cyclic_plan, %{steps: Enum.sort(cyclic)})}
    end
  end

  defp walk_topology([], indegrees, _dependents, order),
    do: {Enum.reverse(order), indegrees}

  defp walk_topology([iri | rest], indegrees, dependents, order) do
    {indegrees, newly_ready} =
      dependents
      |> Map.get(iri, [])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce({indegrees, []}, fn dependent, {indegrees, ready} ->
        degree = Map.fetch!(indegrees, dependent) - 1
        indegrees = Map.put(indegrees, dependent, degree)
        ready = if degree == 0, do: [dependent | ready], else: ready
        {indegrees, ready}
      end)

    walk_topology(Enum.sort(rest ++ newly_ready), indegrees, dependents, [iri | order])
  end

  defp add_steps(reactor, steps, handlers, plan_iri) do
    Enum.reduce_while(steps, {:ok, reactor}, fn step, {:ok, reactor} ->
      arguments =
        [{:input, {:input, :input}}] ++
          Enum.map(Enum.uniq(step.predecessors), &Argument.from_result(:_, &1))

      context = %{
        ash_pplan: %{
          plan_iri: plan_iri,
          step_iri: step.iri,
          input_variables: step.inputs,
          output_variables: step.outputs
        }
      }

      case Builder.add_step(reactor, step.iri, Map.fetch!(handlers, step.iri), arguments,
             context: context
           ) do
        {:ok, reactor} ->
          {:cont, {:ok, reactor}}

        {:error, reason} ->
          {:halt,
           {:error, error(:reactor_builder_error, %{step: step.iri, reason: inspect(reason)})}}
      end
    end)
  end

  defp add_return(reactor, %{steps: steps}) do
    depended_on =
      steps
      |> Enum.flat_map(& &1.predecessors)
      |> MapSet.new()

    terminals =
      steps
      |> Enum.map(& &1.iri)
      |> Enum.reject(&MapSet.member?(depended_on, &1))
      |> Enum.sort()

    case terminals do
      [terminal] ->
        wrap_builder(Builder.return(reactor, terminal), :return_error, %{terminal: terminal})

      terminals when length(terminals) <= length(@terminal_argument_names) ->
        terminal_pairs = Enum.zip(@terminal_argument_names, terminals)

        arguments =
          Enum.map(terminal_pairs, fn {argument_name, terminal} ->
            Argument.from_result(argument_name, terminal)
          end)

        with {:ok, reactor} <-
               wrap_builder(
                 Builder.add_step(
                   reactor,
                   @return_step,
                   {ReturnTerminals, terminals: terminal_pairs},
                   arguments,
                   async?: false
                 ),
                 :return_collector_error,
                 %{terminals: terminals}
               ),
             {:ok, reactor} <-
               wrap_builder(
                 Builder.return(reactor, @return_step),
                 :return_error,
                 %{terminal: @return_step}
               ) do
          {:ok, reactor}
        end

      terminals ->
        {:error,
         error(:too_many_terminal_steps, %{
           count: length(terminals),
           maximum: length(@terminal_argument_names)
         })}
    end
  end

  defp wrap_builder({:ok, reactor}, _reason, _details), do: {:ok, reactor}

  defp wrap_builder({:error, reason}, error_reason, details) do
    {:error, error(error_reason, Map.put(details, :reason, inspect(reason)))}
  end

  defp error(reason, details), do: %Error{reason: reason, details: details}
end
