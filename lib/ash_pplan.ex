defmodule AshPPlan do
  @moduledoc """
  P-PLAN/PROV-O semantic projection into the existing Ash process stack.

  `AshPPlan` intentionally owns no scheduler, queue, retry engine, transaction
  engine, or workflow executor. Those capabilities remain with Reactor,
  Ash.Reactor, AshOban/Oban, and Ash.
  """

  alias AshPPlan.{Compiler, ExecutionReceipt}
  alias AshPPlan.Generated.{PlanCatalog, ProjectionCatalog}

  @version "26.9.7"

  @doc "Returns the ash_pplan release version."
  def version, do: @version

  @doc "Returns every ontology-to-runtime projection manufactured from `ontology.ttl`."
  def projections, do: ProjectionCatalog.all()

  @doc "Looks up a projection by its public/source ontology IRI."
  def projection(source_iri) when is_binary(source_iri), do: ProjectionCatalog.fetch(source_iri)

  @doc "Returns projections for a semantic role such as `:plan`, `:step`, or `:temporal`."
  def projections_for(role) when is_atom(role),
    do: ProjectionCatalog.by_role(Atom.to_string(role))

  def projections_for(role) when is_binary(role), do: ProjectionCatalog.by_role(role)

  @doc "Returns every P-PLAN plan manufactured from the canonical ontology."
  def plans, do: PlanCatalog.all()

  @doc "Looks up a manufactured P-PLAN plan by IRI."
  def plan(plan_iri) when is_binary(plan_iri), do: PlanCatalog.fetch(plan_iri)

  @doc "Compiles an admitted plan into a Reactor using caller-supplied step implementations."
  def compile_plan(plan_iri, handlers) when is_binary(plan_iri) and is_map(handlers) do
    Compiler.compile(plan_iri, handlers)
  end

  @doc """
  Compiles and executes an admitted P-PLAN plan through Reactor.

  Returns `{reactor_outcome, receipt}` after execution. `:run_id` may be passed
  in `options`; it is consumed by ash_pplan and placed into Reactor context.
  """
  def execute(plan_iri, handlers, input, context \\ %{}, options \\ [])
      when is_binary(plan_iri) and is_map(handlers) and is_map(context) and is_list(options) do
    {run_id, reactor_options} = Keyword.pop(options, :run_id, new_run_id())

    with {:ok, reactor} <- Compiler.compile(plan_iri, handlers) do
      started_at = DateTime.utc_now()
      started_mono = System.monotonic_time(:microsecond)
      context = Map.put_new(context, :run_id, run_id)
      outcome = Reactor.run(reactor, %{input: input}, context, reactor_options)
      receipt = ExecutionReceipt.observe(plan_iri, run_id, outcome, started_at, started_mono)
      {outcome, receipt}
    end
  end

  @doc "Executes a Reactor without introducing an ash_pplan execution runtime."
  def run(reactor, inputs, context \\ %{}, options \\ []) do
    Reactor.run(reactor, inputs, context, options)
  end

  defp new_run_id do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "ash-pplan-" <> suffix
  end
end
