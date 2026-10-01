defmodule AshPPlan.Reactor.Adapters.AshOban do
  @moduledoc """
  Adapter for deferred scheduling via `ash_oban`.

  `Schedule.Deferred` -> `:schedule_deferred` resolves to `Schedule`, which
  CONSTRUCTs an AshOban trigger job (through `AshPPlan.Oban.construct_trigger/3`;
  never inserts) whose args carry the continuation reference, so the deferred
  follow-up resumes the `AshPPlan.Continuation` instead of a private workflow.
  """
  @behaviour AshPPlan.Reactor.Adapter

  defmodule Schedule do
    @moduledoc """
    Options: `:record` (Ash record), `:trigger` (AshOban trigger name or
    struct), `:continuation` (an `AshPPlan.Continuation` or a reference map),
    `:args` (extra job args). Arguments `record`/`trigger`/`continuation`
    override options. Result carries `continuation_ref` and the unexecuted
    job changeset (`inserted?: false`).
    """
    use Reactor.Step

    @impl true
    def run(arguments, _context, options) do
      opts = Keyword.merge(options, Map.to_list(arguments))

      with {:ok, record} <- fetch(opts, :record),
           {:ok, trigger} <- fetch(opts, :trigger),
           {:ok, ref} <- reference(Keyword.get(opts, :continuation)),
           args = opts |> Keyword.get(:args, %{}) |> Map.new() |> Map.put("continuation_ref", ref),
           {:ok, job} <- AshPPlan.Oban.construct_trigger(record, trigger, args: args) do
        {:ok, %{job: job, continuation_ref: ref, args: args, inserted?: false}}
      end
    end

    @doc "The portable reference to a continuation: `%{id, plan_iri, run_id}` (string keys)."
    def reference(%AshPPlan.Continuation{id: id, plan_iri: plan, run_id: run}),
      do: {:ok, %{"id" => id, "plan_iri" => plan, "run_id" => run}}

    def reference(%{"id" => _, "plan_iri" => _, "run_id" => _} = ref), do: {:ok, ref}

    def reference(%{id: id, plan_iri: plan, run_id: run}),
      do: {:ok, %{"id" => id, "plan_iri" => plan, "run_id" => run}}

    def reference(other), do: {:error, %{reason: :missing_continuation_reference, value: other}}

    defp fetch(opts, key) do
      case Keyword.get(opts, key) do
        nil -> {:error, %{reason: :missing_option, option: key}}
        v -> {:ok, v}
      end
    end
  end

  @table %{
    schedule_deferred: {Schedule, []}
  }

  @impl true
  def id, do: :ash_oban
  @impl true
  def available?, do: Code.ensure_loaded?(AshOban)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end
