defmodule AshPPlan.Workflow.Project.HDDL do
  @moduledoc """
  HDDL projection of a workflow model (dialect of `planning/*.hddl`): a top
  compound task decomposed into the model's tasks, one `:action` per task whose
  preconditions are its dependencies, and one `:method` per model method.

  `parse/1` reads the rendered dialect back into data. `court/2` is the HDDL
  Court: it falsifies a rendered text that lost a subtask, a method, or an
  ordering precondition relative to the model. Grants no authority.
  """

  alias AshPPlan.Workflow.{Model, Subject}

  @spec render(Model.t()) :: String.t()
  def render(%Model{} = model) do
    {:ok, order} = Model.topological_order(model)
    by_id = Map.new(model.tasks, &{&1.id, &1})
    top = top_name(model)
    action_names = MapSet.new(model.tasks, &hname(model, &1.id))

    preds = Enum.map_join(order, " ", &"(d-#{hname(model, &1)})")

    top_sub =
      order
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {id, i} -> "      (s#{i} (#{hname(model, id)}))" end)

    compounds =
      model.methods
      |> Enum.map(&compound_name(&1, action_names))
      |> Enum.reject(&MapSet.member?(action_names, &1))
      |> Enum.uniq()
      |> Enum.map_join("", &"  (:task #{&1} :parameters ())\n")

    methods =
      Enum.map_join(model.methods, "", fn m ->
        subs =
          m.subtasks
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {s, i} -> "      (s#{i} (#{hname(model, s)}))" end)

        "  (:method m-#{m.id}\n    :parameters ()\n    :task (#{compound_name(m, action_names)})\n" <>
          "    :ordered-subtasks (and\n#{subs}))\n\n"
      end)

    actions =
      Enum.map_join(order, "\n", fn id ->
        t = Map.fetch!(by_id, id)
        pre = Enum.map_join(t.depends_on, " ", &"(d-#{hname(model, &1)})")

        "  (:action #{hname(model, id)}\n    :parameters ()\n    :precondition (and #{pre})\n" <>
          "    :effect (and (d-#{hname(model, id)})))"
      end)

    """
    (define (domain wf-#{model.name})
      (:requirements :typing :hierarchy)

      (:predicates #{preds})

      (:task #{top} :parameters ())
    #{compounds}
      (:method m-#{top}
        :parameters ()
        :task (#{top})
        :ordered-subtasks (and
    #{top_sub}))

    #{methods}#{actions})
    """
  end

  @doc "Parses rendered HDDL back into `%{domain, top, top_subtasks, methods, actions}`."
  @spec parse(String.t()) :: {:ok, map()} | {:error, map()}
  def parse(text) when is_binary(text) do
    parse_forms(text)
  catch
    :hddl_bad_form -> {:error, %{reason: :hddl_parse_error}}
  end

  # Typed-refusal law: a non-binary is a typed parse refusal, never a
  # FunctionClauseError.
  def parse(other), do: {:error, %{reason: :hddl_parse_error, value: other}}

  defp parse_forms(text) do
    with {:ok, [{:list, ["define", {:list, ["domain", domain]} | forms]}]} <- read(text) do
      methods = for {:list, [":method", id | rest]} <- forms, do: method(id, rest)

      actions =
        Map.new(for {:list, [":action", name | rest]} <- forms, do: {name, action(rest)})

      {top, top_subs} =
        case Enum.find(methods, &String.starts_with?(&1.id, "m-solve-")) do
          nil -> {nil, []}
          m -> {m.task, m.subtasks}
        end

      {:ok,
       %{
         domain: domain,
         top: top,
         top_subtasks: top_subs,
         methods: Enum.reject(methods, &String.starts_with?(&1.id, "m-solve-")),
         actions: actions
       }}
    else
      _ -> {:error, %{reason: :hddl_parse_error}}
    end
  end

  @doc """
  HDDL Court: `:ok` when `text` decomposes exactly the model (every task a
  top-level subtask and an action, every method with its ordered subtasks,
  every dependency a precondition); otherwise a typed divergence.
  """
  @spec court(Model.t(), String.t()) :: :ok | {:error, map()}
  def court(%Model{} = model, text) do
    with {:ok, parsed} <- parse(text) do
      expected_tasks = Enum.map(model.tasks, &hname(model, &1.id))

      expected_methods =
        Map.new(
          model.methods,
          &{"m-#{&1.id}", Enum.map(&1.subtasks, fn s -> hname(model, s) end)}
        )

      found_methods = Map.new(parsed.methods, &{&1.id, &1.subtasks})

      expected_pre =
        Map.new(model.tasks, fn t ->
          {hname(model, t.id), Enum.sort(Enum.map(t.depends_on, &hname(model, &1)))}
        end)

      found_pre = Map.new(parsed.actions, fn {n, a} -> {n, Enum.sort(a.pre)} end)

      cond do
        Enum.sort(parsed.top_subtasks) != Enum.sort(expected_tasks) ->
          {:error,
           %{
             reason: :decomposition_diverges,
             missing: expected_tasks -- parsed.top_subtasks,
             unexpected: parsed.top_subtasks -- expected_tasks
           }}

        expected_methods != found_methods ->
          {:error, %{reason: :method_diverges, expected: expected_methods, found: found_methods}}

        expected_pre != found_pre ->
          {:error, %{reason: :precondition_diverges, expected: expected_pre, found: found_pre}}

        true ->
          :ok
      end
    end
  end

  defp hname(model, task), do: Subject.correspondence(model.name, task).hddl
  defp top_name(model), do: "solve-#{model.name}"

  defp compound_name(m, action_names) do
    name = "t_#{m.task}"
    if MapSet.member?(action_names, name), do: "t_#{m.id}", else: name
  end

  defp method(id, rest) do
    kv = pairs(rest)

    task =
      case kv[":task"] do
        {:list, [task | _]} when is_binary(task) -> task
        _ -> throw(:hddl_bad_form)
      end

    subs =
      case kv[":ordered-subtasks"] || kv[":subtasks"] do
        {:list, ["and" | items]} ->
          for {:list, [_label, {:list, [n | _]}]} <- items, do: n

        nil ->
          []

        _ ->
          throw(:hddl_bad_form)
      end

    %{id: id, task: task, subtasks: subs}
  end

  defp action(rest) do
    kv = pairs(rest)

    pre =
      case kv[":precondition"] do
        {:list, ["and" | ps]} -> for {:list, ["d-" <> n]} <- ps, do: n
        _ -> []
      end

    %{pre: pre}
  end

  defp pairs(list) do
    list
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [k, v] -> [{k, v}]
      _ -> throw(:hddl_bad_form)
    end)
    |> Map.new()
  end

  # -- s-expression reader ------------------------------------------------

  defp read(text) do
    tokens =
      text
      |> String.replace(~r/;[^\n]*/, "")
      |> then(&Regex.scan(~r/\(|\)|[^\s()]+/, &1))
      |> List.flatten()

    case parse_forms(tokens, []) do
      {forms, []} -> {:ok, forms}
      _ -> {:error, :unbalanced}
    end
  catch
    :unbalanced -> {:error, :unbalanced}
  end

  defp parse_forms([], acc), do: {Enum.reverse(acc), []}
  defp parse_forms([")" | _] = rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_forms(["(" | rest], acc) do
    case parse_forms(rest, []) do
      {items, [")" | tail]} -> parse_forms(tail, [{:list, items} | acc])
      _ -> throw(:unbalanced)
    end
  end

  defp parse_forms([atom | rest], acc), do: parse_forms(rest, [atom | acc])
end
