defmodule AshPPlan.Reactor.Durable.LedgerOCEL do
  @moduledoc """
  Export a durable run's standing checkpoint ledger as process-mining evidence.

  One event per standing checkpoint (activity `task_succeeded`, ordered by the ledger's
  monotonic `seq`), plus `run_started` / `run_ended` events carrying the run's terminal
  status. Events carry the workflow subject id when the run context holds one, so the
  export binds to the same subject the standing receipt will cite.

  Honesty note: checkpoint rows carry no wall-clock timestamps, so event timestamps
  reflect export time; the authoritative order is the ledger's `seq`, which is also
  carried in each event's attributes. Design lineage: mbuhot/magma's ledger idea,
  re-implemented (see `docs/NOTICE.md`).
  """

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Status}

  @spec events(term(), String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, map()}
  def events(store, run_id, opts \\ []) do
    opts = Keyword.put_new(opts, :store_module, AshPPlan.Reactor.Durable.Store.Ets)
    mod = opts[:store_module]

    if function_exported?(mod, :snapshot, 2) do
      # O(1)-call snapshotted read: the store hands back the run and its standing
      # already seq-ascending from inside one GenServer message — no per-call sort.
      case mod.snapshot(store, run_id) do
        nil ->
          {:error, %{reason: :no_such_run, run_id: run_id}}

        {run, standing} ->
          {:ok, build_events(run, standing, _presorted = true)}
      end
    else
      case Engine.fetch(store, run_id, opts) do
        nil ->
          {:error, %{reason: :no_such_run, run_id: run_id}}

        run ->
          {:ok, build_events(run, mod.standing(store, run_id), _presorted = false)}
      end
    end
  end

  defp build_events(run, standing, presorted?) do
    now = Clock.now()
    run_ref = "run:" <> run.id

    subject = get_in(run.context || %{}, [:ash_pplan_workflow, :subject])

    run_started =
      %Event{
        id: "#{run_ref}/started",
        activity: "run_started",
        timestamp: now,
        objects: [{"WorkflowRun", run_ref, "run"}],
        attributes: %{plan: run.plan_iri, seq: 0},
        subject_id: subject
      }

    # snapshot path: standing arrives seq-ascending, no sort. Fallback path: standing is
    # used sorted twice (step events in seq order, run_ended seq = max+1); sort once and
    # take max from the tail instead of a second full Enum.max pass over the list
    sorted = if presorted?, do: standing, else: Enum.sort_by(standing, & &1.seq)

    step_events =
      sorted
      |> Enum.map(fn cp ->
        %Event{
          id: "#{run_ref}/#{cp.label}@#{cp.seq}",
          activity: "task_succeeded",
          timestamp: now,
          objects: [
            {"WorkflowRun", run_ref, "run"},
            {"Step", "step:" <> cp.label, "step"},
            {"Realization", "impl:" <> impl_ref(cp.impl), "realization"}
          ],
          attributes: %{
            task: cp.label,
            seq: cp.seq,
            output_digest:
              :crypto.hash(:sha256, :erlang.term_to_binary(cp.output))
              |> Base.encode16(case: :lower)
          },
          subject_id: subject
        }
      end)

    run_ended =
      if Status.terminal?(run.status) do
        [
          %Event{
            id: "#{run_ref}/ended",
            activity: "run_ended",
            timestamp: now,
            objects: [{"WorkflowRun", run_ref, "run"}],
            attributes: %{status: to_string(run.status), seq: max_seq(sorted) + 1},
            subject_id: subject
          }
        ]
      else
        []
      end

    [run_started] ++ step_events ++ run_ended
  end

  @spec export(term(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, map()}
  def export(store, run_id, opts \\ []) do
    with {:ok, events} <- events(store, run_id, opts) do
      AshPPlan.ProcessEvidence.export(events, :ocel2_json)
    end
  end

  @doc "Content digest over the exported evidence; changes if any standing output changes."
  @spec digest(term(), String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def digest(store, run_id, opts \\ []) do
    with {:ok, events} <- events(store, run_id, opts) do
      {:ok,
       events
       |> Enum.map(&{&1.id, &1.activity, &1.attributes})
       |> :erlang.term_to_binary()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower)}
    end
  end

  defp impl_ref(nil), do: "unresolved"
  defp impl_ref({m, _opts}), do: Atom.to_string(m)
  defp impl_ref(m) when is_atom(m), do: Atom.to_string(m)
  defp impl_ref(other), do: inspect(other)

  defp max_seq([]), do: 0
  # input is seq-ascending; the max is the tail — no full pass
  defp max_seq(standing), do: List.last(standing).seq
end
