defmodule AshPPlan.Reactor.Durable.Unwind do
  @moduledoc """
  Takes back the work a durable run left standing, newest checkpoint first.

  Reactor unwinds inside a live run from the undo stack it built. A rollback that must survive
  the process it started in has no executor entry point, so this walks the store's standing
  checkpoints directly. The `undone_at` marks written by `Store.claim_undo/4` are the progress
  log: a crash mid-rollback leaves the remaining checkpoints standing and the next call carries on
  from exactly there.

  Undo needs no rebuild of the reactor: each checkpoint snapshots its `impl` and `args`.
  The context is the record's context merged with `opts[:context]`, seeded with the workflow
  identity (so `AshPPlan.Reactor.Middleware.Identity` admits it) and the durable context.

  A failed undo leaves its checkpoint standing (`release_undo`) and is reported as an error; a
  checkpoint with no resolvable impl is reported unresolved and also left standing. A step that
  cannot `undo` stays standing by design (its effect is carried forward).

  Design derived from mbuhot/magma (MIT per its mix.exs), re-implemented.
  """

  require Logger

  alias AshPPlan.Reactor.Middleware.Identity
  alias AshPPlan.Workflow.Subject

  @max_undo_count 5
  @identity_key AshPPlan.Reactor.context_key()

  @doc """
  Take back every standing checkpoint of `run_id`. Returns `{:ok, unresolved_labels}` or
  `{:error, errors}`. `opts`: `:context` (merged over the record context), `:store_module`
  (store implementation module, default `AshPPlan.Reactor.Durable.Store.Ets`).
  """
  @spec run(term(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, [term()]}
  def run(store, run_id, opts \\ []) do
    mod =
      Keyword.get(opts, :store_module) || Keyword.get(opts, :store_mod) ||
        AshPPlan.Reactor.Durable.Store.Ets

    case mod.get_run(store, run_id) do
      nil ->
        {:error, [{:no_such_run, run_id}]}

      record ->
        case prepare(mod, store, record, opts) do
          {:ok, context} -> unwind(mod, store, record, context)
          {:error, reason} -> {:error, [{:middleware_failed, reason}]}
        end
    end
  end

  defp prepare(mod, store, record, opts) do
    checkpoints = mod.checkpoints(store, record.id) |> Map.new(fn {k, c} -> {k, c.output} end)

    context =
      (record.context || %{})
      |> Map.merge(Keyword.get(opts, :context, %{}))
      |> seed_identity(record)
      |> Map.put(:durable, %{
        store: store,
        store_module: mod,
        run_id: record.id,
        checkpoints: checkpoints
      })

    Identity.init(context)
  end

  defp seed_identity(%{@identity_key => %{subject: "sha256:" <> _}} = context, _record),
    do: context

  defp seed_identity(context, %{model: %AshPPlan.Workflow.Model{} = model}) do
    subject = Subject.bind(model)
    Map.put(context, @identity_key, %{subject: subject.id, workflow: model.name})
  end

  defp seed_identity(context, _record), do: context

  defp unwind(mod, store, record, context) do
    standing = mod.standing(store, record.id) |> Enum.sort_by(& &1.seq, :desc)

    {unresolved, errors} =
      standing
      |> Enum.flat_map(&undo_checkpoint(mod, store, &1, context))
      |> Enum.split_with(&match?({:unresolved, _}, &1))

    labels = Enum.map(unresolved, fn {:unresolved, label} -> label end)

    if labels != [] do
      Logger.warning(
        "durable unwind of #{record.id} left #{length(labels)} unresolved checkpoint(s): " <>
          Enum.join(labels, ", ")
      )
    end

    case errors do
      [] -> {:ok, labels}
      errors -> {:error, errors}
    end
  end

  defp undo_checkpoint(mod, store, checkpoint, context) do
    case step_for(checkpoint) do
      nil ->
        [{:unresolved, checkpoint.label}]

      step ->
        if undoable?(step) do
          drive(mod, store, step, checkpoint, context)
        else
          []
        end
    end
  end

  defp step_for(%{impl: nil}), do: nil

  defp step_for(%{impl: impl, step_key: _} = checkpoint) do
    impl = if is_atom(impl), do: {impl, []}, else: impl

    case impl do
      {m, o} when is_atom(m) and is_list(o) ->
        if Code.ensure_loaded?(m) do
          %Reactor.Step{name: step_name(checkpoint), impl: impl, arguments: []}
        end

      _ ->
        nil
    end
  end

  # A checkpoint written without the name term (a bare store caller) still carries its
  # `inspect`ed label; a literal label is read back to the term, anything else stays the label.
  defp step_name(%{name: nil, label: label}) when is_binary(label) do
    with {:ok, ast} <- Code.string_to_quoted(label, existing_atoms_only: true),
         true <- Macro.quoted_literal?(ast) do
      {term, _} = Code.eval_quoted(ast)
      term
    else
      _ -> label
    end
  rescue
    _ -> label
  end

  defp step_name(%{name: nil, label: label}), do: label
  defp step_name(%{name: name}), do: name

  defp undoable?(step) do
    Reactor.Step.can?(step, :undo)
  rescue
    _ -> false
  end

  defp drive(mod, store, step, checkpoint, context) do
    # Claim before undoing: two racing rollbacks would otherwise both read the same standing row.
    case mod.claim_undo(
           store,
           checkpoint.run_id,
           checkpoint.step_key,
           AshPPlan.Reactor.Durable.Clock.now()
         ) do
      {:ok, claimed} -> run_undo(mod, store, step, claimed, context, 0)
      :taken -> []
    end
  end

  defp run_undo(mod, store, _step, checkpoint, _context, @max_undo_count) do
    :ok = mod.release_undo(store, checkpoint.run_id, checkpoint.step_key)
    [{:undo_retries_exceeded, checkpoint.label}]
  end

  defp run_undo(mod, store, step, checkpoint, context, attempt) do
    ctx = Map.put(context, :current_step, step)
    args = checkpoint.args || %{}

    result =
      try do
        Reactor.Step.undo(step, checkpoint.output, args, ctx)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok ->
        []

      :retry ->
        run_undo(mod, store, step, checkpoint, context, attempt + 1)

      {:retry, _reason} ->
        run_undo(mod, store, step, checkpoint, context, attempt + 1)

      {:error, reason} ->
        :ok = mod.release_undo(store, checkpoint.run_id, checkpoint.step_key)
        [{:undo_failed, checkpoint.label, reason}]

      other ->
        :ok = mod.release_undo(store, checkpoint.run_id, checkpoint.step_key)
        [{:undo_failed, checkpoint.label, {:bad_undo_result, other}}]
    end
  end
end
