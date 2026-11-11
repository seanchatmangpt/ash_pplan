defmodule AshPPlan.Workflow.Project.HDDL do
  @moduledoc """
  HDDL projection of a workflow model (dialect of `planning/*.hddl`): a top
  compound task decomposed into the model's tasks, one `:action` per task whose
  preconditions are its dependencies, and one `:method` per model method.

  `parse/1` reads the rendered dialect back into data, and also parses HDDL
  *problem* files (`(define (problem ...) ...)`), returning a distinct map
  shape carrying `:problem`, `:objects`, `:init`, `:htn`, and `:goal`.
  `court/2` is the HDDL Court: it falsifies a rendered text that lost a
  subtask, a method, or an ordering precondition refuse-or-handle law: known
  shapes only, unknown forms are typed refusals. Grants no authority.
  """

  alias AshPPlan.Workflow.{Model, Subject}

  @typedoc "A term: a ground constant (binary) or a `{:var, name}` variable."
  @type hddl_term :: binary() | {:var, atom()}

  @typedoc """
  A fact: a bare binary (zero-argument predicate, e.g. `"t_plan"` after `d-`
  stripping) or a tuple `{pred, arg, ...}` of `hddl_term`s
  (e.g. `{"released", {:var, :p}, {:var, :r}}`).
  """
  @type fact :: binary() | tuple()

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
    :hddl_bad_form ->
      IO.inspect(__STACKTRACE__, label: "DEBUG_BAD_FORM")
      {:error, %{reason: :hddl_parse_error}}

    {:unsupported_precondition, form} ->
      {:error, %{reason: :hddl_parse_error, unsupported_precondition: form}}
  end

  # Typed-refusal law: a non-binary is a typed parse refusal, never a
  # FunctionClauseError.
  def parse(other), do: {:error, %{reason: :hddl_parse_error, value: other}}

  defp parse_forms(text) do
    case read(text) do
      {:ok, [{:list, ["define", {:list, ["problem", name]} | pforms]}]} ->
        parse_problem(name, pforms)

      {:ok, [{:list, ["define", {:list, ["domain", domain]} | forms]}]} ->
        parse_domain(domain, forms)

      _ ->
        {:error, %{reason: :hddl_parse_error}}
    end
  end

  defp parse_problem(name, forms) do
    # `forms` is a list of `{:list, ...}` forms, not a flat token list, so the
    # flat-token `pairs/1` helper cannot read it; build the kv map from forms.
    kv =
      Map.new(forms, fn
        {:list, [key | rest]} when is_binary(key) -> {key, rest}
        _ -> throw(:hddl_bad_form)
      end)

    domain =
      case kv[":domain"] do
        [d] when is_binary(d) -> d
        _ -> throw(:hddl_bad_form)
      end

    htn =
      case kv[":htn"] do
        nil ->
          []

        hrest when is_list(hrest) ->
          hkv = pairs(hrest)

          case hkv[":ordered-subtasks"] || hkv[":subtasks"] do
            {:list, ["and" | items]} -> subtask_instances(items)
            nil -> []
            _ -> throw(:hddl_bad_form)
          end

        _ ->
          throw(:hddl_bad_form)
      end

    {:ok,
     %{
       problem: name,
       domain: domain,
       objects: objects(kv[":objects"]),
       init: Enum.flat_map(List.wrap(kv[":init"]), &parse_fact_list/1),
       htn: htn,
       goal: Enum.flat_map(List.wrap(kv[":goal"]), &parse_fact_list/1)
     }}
  end

  defp objects(nil), do: []

  defp objects(toks) when is_list(toks), do: Enum.filter(toks, &is_binary/1)
  defp objects(_), do: throw(:hddl_bad_form)

  defp parse_domain(domain, forms) do
    methods = for {:list, [":method", id | rest]} <- forms, do: method(id, rest)

    actions =
      Map.new(for {:list, [":action", name | rest]} <- forms, do: {name, action(rest)})

    tasks =
      Map.new(for {:list, [":task", name | rest]} <- forms, do: {name, task_params(rest)})

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
       actions: actions,
       tasks: tasks
     }}
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

  # -- form parsers ---------------------------------------------------------

  defp method(id, rest) do
    kv = pairs(rest)

    task = parse_task_instance(kv[":task"])

    subs =
      case kv[":ordered-subtasks"] || kv[":subtasks"] do
        {:list, ["and" | items]} -> subtask_instances(items)
        nil -> []
        _ -> throw(:hddl_bad_form)
      end

    %{id: id, task: task, subtasks: subs, precondition: parse_fact_list(kv[":precondition"])}
  end

  defp action(rest) do
    kv = pairs(rest)

    %{
      pre: parse_fact_list(kv[":precondition"]),
      effect: parse_fact_list(kv[":effect"]),
      parameters: parse_parameters(kv[":parameters"])
    }
  end

  defp task_params(rest) do
    case rest do
      [] ->
        []

      [{:list, _} = params_form] ->
        parse_parameters(params_form)

      kv_rest ->
        kv_rest |> pairs() |> Map.get(":parameters") |> parse_parameters()
    end
  end

  # Refuse-or-handle law for preconditions/effects: only known shapes are
  # handled — `nil`, the empty form `()`, a single predicate, and `(and ...)`
  # nesting of those. Every other form is a typed refusal, never `_ -> []`.
  defp parse_fact_list(nil), do: []

  # `(not ...)` (and other unsupported heads) is a typed refusal with the
  # offending form attached, never a silent predicate read that dies later in
  # normalize_term as a bare :hddl_bad_form.
  defp parse_fact_list({:list, [head | _]} = form) when head in ["not", "or", "exists", "forall"],
    do: throw({:unsupported_precondition, form})

  defp parse_fact_list({:list, []}), do: []

  defp parse_fact_list({:list, ["and" | ps]}) do
    Enum.flat_map(ps, &parse_fact_list/1)
  end

  defp parse_fact_list({:list, [pred | _args]} = form) when is_binary(pred) do
    [normalize_fact(form)]
  end

  defp parse_fact_list(other), do: throw({:unsupported_precondition, other})

  # Ordering predicates are rendered as `d-<task>`; parse strips the `d-`
  # prefix so parse(render(m)) yields bare task names — the form the court's
  # comparison and the `fact` type doc both pin ("after `d-` stripping").
  # Render re-adds the prefix, so parse∘render is identity on the model names.
  defp normalize_fact({:list, [pred]}), do: strip_d_prefix(pred)

  defp normalize_fact({:list, [pred | args]}),
    do: List.to_tuple([pred | Enum.map(args, &normalize_term/1)])

  defp normalize_fact(_other), do: throw(:hddl_bad_form)

  defp strip_d_prefix("d-" <> name) when name != "", do: name
  defp strip_d_prefix(pred), do: pred

  defp normalize_term("?" <> name) when name != "", do: {:var, String.to_atom(name)}
  defp normalize_term(t) when is_binary(t), do: t
  defp normalize_term(_), do: throw(:hddl_bad_form)

  # A task instance: `(name)` -> `"name"`, `(name arg ...)` -> `{name, arg, ...}`.
  defp parse_task_instance({:list, [name | args]}) when is_binary(name),
    do: normalize_fact({:list, [name | args]})

  defp parse_task_instance(_), do: throw(:hddl_bad_form)

  defp subtask_instances(items) do
    for {:list, [_label, {:list, _} = inner]} <- items, do: normalize_fact(inner)
  end

  # `kv` values are the bare token lists after the key (no "parameters" head);
  # the filter drops any literal "parameters" token so both shapes parse.
  defp parse_parameters({:list, toks}) do
    for t <- toks, is_binary(t), String.starts_with?(t, "?"), uniq: true, do: normalize_term(t)
  end

  defp parse_parameters(nil), do: []
  defp parse_parameters(_), do: throw(:hddl_bad_form)

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
