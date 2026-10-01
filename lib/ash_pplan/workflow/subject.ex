defmodule AshPPlan.Workflow.Subject do
  @moduledoc """
  One content-addressed identity for a workflow plus the explicit correspondence of
  that identity across projections. Correspondence is computed, never inferred
  from coincidental names.
  """

  alias AshPPlan.Workflow.Model

  @schema "ash_pplan/workflow-subject/v1"

  @spec bind(Model.t()) :: map()
  def bind(%Model{} = model) do
    canonical = Model.canonical(model)

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))
      |> Base.encode16(case: :lower)

    %{
      schema: @schema,
      id: "sha256:" <> digest,
      digest: digest,
      workflow: model.name,
      correspondence: Map.new(model.tasks, &{&1.id, correspondence(model.name, &1.id)})
    }
  end

  @spec same?(map(), map()) :: boolean()
  def same?(%{id: id}, %{id: id}), do: true
  def same?(_, _), do: false

  @doc "Projection-specific names for one semantic task id."
  @spec correspondence(String.t(), atom() | String.t()) :: map()
  def correspondence(workflow, task) do
    iri = "urn:ash-pplan:workflow:#{workflow}##{task}"

    %{
      semantic: iri,
      pplan: iri,
      hddl: "t_#{task}",
      fond: to_string(task),
      reactor: to_string(task)
    }
  end

  @kinds [:pplan, :hddl, :fond, :reactor]

  @doc """
  Per-task correspondence audit of one projection: `:ok` when the projection carries exactly
  the correspondence ids the model binds for `kind`, else `{:error, %{missing:, extra:, drift:}}`
  where `drift` pairs each missing id with the extra id that replaced it (a swapped task id).
  `projection` may be a raw projection (read via `verify_projection/3` readers) or a list of ids.
  """
  @spec verify_correspondence(Model.t(), atom(), term()) :: :ok | {:error, map()}
  def verify_correspondence(%Model{} = model, kind, projection) when kind in @kinds do
    expected = expected_ids(model, kind)

    found =
      case projection do
        ids when is_list(ids) and (ids == [] or is_binary(hd(ids))) ->
          ids

        other ->
          case observe(model, kind, other) do
            {:ok, %{ids: ids}} -> ids
            {:error, _} -> :unreadable
          end
      end

    if found == :unreadable do
      {:error, %{missing: expected, extra: [], drift: []}}
    else
      allowed = expected ++ extra_allowed(model, kind)
      missing = Enum.sort(expected -- found)
      extra = Enum.sort(found -- allowed)

      if missing == [] and extra == [] do
        :ok
      else
        {:error, %{missing: missing, extra: extra, drift: Enum.zip(missing, extra)}}
      end
    end
  end

  @doc """
  Checks that `projection` carries exactly the correspondence ids the model
  binds for `kind` (no task lost, none invented) and, where the projection
  encodes ordering, that it respects the model's dependencies and is acyclic.
  """
  @spec verify_projection(Model.t(), :pplan | :hddl | :fond | :reactor, term()) ::
          :ok | {:error, map()}
  def verify_projection(%Model{} = model, kind, projection) when kind in @kinds do
    with :ok <- Model.validate(model) do
      subject = bind(model)
      expected = expected_ids(model, kind)

      case observe(model, kind, projection) do
        {:ok, %{ids: found} = obs} ->
          check_ids(subject, kind, expected, found, model) |> then(&check_order(&1, model, obs))

        {:error, _} = err ->
          err
      end
    end
  end

  def verify_projection(%Model{}, kind, _),
    do: {:error, %{reason: :unknown_projection, kind: kind}}

  def verify_projection(other, _, _), do: {:error, %{reason: :not_a_model, value: other}}

  defp expected_ids(model, kind) do
    for t <- model.tasks, do: Map.fetch!(correspondence(model.name, t.id), kind)
  end

  defp check_ids(subject, kind, expected, found, model) do
    allowed = MapSet.new(expected ++ extra_allowed(model, kind))
    found = MapSet.new(found)
    missing = expected |> MapSet.new() |> MapSet.difference(found) |> Enum.sort()
    unexpected = found |> MapSet.difference(allowed) |> Enum.sort()

    if missing == [] and unexpected == [] do
      :ok
    else
      {:error,
       %{
         reason: :projection_diverges,
         kind: kind,
         subject: subject.id,
         missing: missing,
         unexpected: unexpected
       }}
    end
  end

  defp extra_allowed(model, :hddl) do
    Enum.flat_map(model.methods, &["t_#{&1.task}", "t_#{&1.id}"])
  end

  defp extra_allowed(_, _), do: []

  defp check_order(:ok, model, %{edges: nil}), do: acyclic_only(model)

  defp check_order(:ok, model, %{edges: edges, kind: kind}) do
    # edges: %{id => [predecessor ids]} in the projection's own naming.
    wanted =
      Map.new(model.tasks, fn t ->
        {Map.fetch!(correspondence(model.name, t.id), kind),
         Enum.map(t.depends_on, &Map.fetch!(correspondence(model.name, &1), kind))}
      end)

    broken =
      for {id, preds} <- wanted,
          missing = preds -- Map.get(edges, id, []),
          missing != [],
          do: {id, missing}

    cond do
      broken != [] ->
        {:error, %{reason: :projection_order_lost, kind: kind, dependencies: Enum.sort(broken)}}

      cyclic?(edges) ->
        {:error, %{reason: :projection_cyclic, kind: kind}}

      true ->
        :ok
    end
  end

  defp check_order(err, _, _), do: err

  defp acyclic_only(model) do
    case Model.topological_order(model) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp cyclic?(edges) do
    deps = Map.new(edges, fn {id, preds} -> {id, MapSet.new(preds)} end)
    ids = MapSet.new(Map.keys(deps))
    deps = Map.new(deps, fn {id, d} -> {id, MapSet.intersection(d, ids)} end)
    peel(deps)
  end

  defp peel(deps) when map_size(deps) == 0, do: false

  defp peel(deps) do
    case for({id, d} <- deps, MapSet.size(d) == 0, do: id) do
      [] ->
        true

      ready ->
        deps
        |> Map.drop(ready)
        |> Map.new(fn {i, d} -> {i, MapSet.difference(d, MapSet.new(ready))} end)
        |> peel()
    end
  end

  # -- projection readers -------------------------------------------------

  defp observe(model, :pplan, %{steps: steps} = plan) when is_list(steps) do
    iri = fn s -> s[:iri] || s["iri"] end
    preds = fn s -> List.wrap(s[:predecessors] || s["predecessors"]) end
    ids = Enum.map(steps, iri)

    cond do
      Enum.uniq(ids) != ids ->
        {:error, %{reason: :projection_diverges, kind: :pplan, duplicates: ids -- Enum.uniq(ids)}}

      not is_nil(plan[:iri]) and not String.contains?(to_string(plan[:iri]), model.name) ->
        {:error, %{reason: :projection_wrong_subject, kind: :pplan, iri: plan[:iri]}}

      true ->
        {:ok, %{kind: :pplan, ids: ids, edges: Map.new(steps, &{iri.(&1), preds.(&1)})}}
    end
  end

  defp observe(_model, :hddl, text) when is_binary(text) do
    ids = ~r/\bt_[A-Za-z0-9_\-]+/ |> Regex.scan(text) |> List.flatten() |> Enum.uniq()
    {:ok, %{kind: :hddl, ids: ids, edges: nil}}
  end

  defp observe(_model, :hddl, term) when is_map(term) or is_list(term) do
    ids =
      term |> collect_strings([]) |> Enum.filter(&String.starts_with?(&1, "t_")) |> Enum.uniq()

    {:ok, %{kind: :hddl, ids: ids, edges: nil}}
  end

  defp observe(_model, :fond, %{domain: domain}), do: observe(nil, :fond, domain)

  defp observe(_model, :fond, %AshPPlan.FOND{transitions: transitions}) do
    ids =
      transitions
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&fond_action_id/1)
      |> Enum.uniq()

    {:ok, %{kind: :fond, ids: ids, edges: nil}}
  end

  defp observe(_model, :reactor, %{steps: steps}) when is_list(steps) do
    ids = steps |> Enum.map(&to_string(&1.name)) |> Enum.uniq()
    {:ok, %{kind: :reactor, ids: ids, edges: nil}}
  end

  defp observe(_model, kind, projection),
    do:
      {:error,
       %{reason: :unreadable_projection, kind: kind, projection: inspect(projection, limit: 5)}}

  # FOND actions are `{:run, task}` tuples (or bare atoms); the task id is the correspondence key.
  defp fond_action_id({:run, task}), do: to_string(task)
  defp fond_action_id(action), do: to_string(action)

  defp collect_strings(term, acc) when is_binary(term), do: [term | acc]

  defp collect_strings(term, acc)
       when is_atom(term) and not is_nil(term) and not is_boolean(term),
       do: [Atom.to_string(term) | acc]

  defp collect_strings(%{__struct__: _} = s, acc), do: collect_strings(Map.from_struct(s), acc)

  defp collect_strings(term, acc) when is_map(term),
    do: Enum.reduce(term, acc, fn {k, v}, a -> collect_strings(v, collect_strings(k, a)) end)

  defp collect_strings(term, acc) when is_list(term),
    do: Enum.reduce(term, acc, &collect_strings/2)

  defp collect_strings(term, acc) when is_tuple(term),
    do: collect_strings(Tuple.to_list(term), acc)

  defp collect_strings(_, acc), do: acc
end
