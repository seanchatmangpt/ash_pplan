defmodule AshPPlan do
  @moduledoc """
  P-PLAN/PROV-O semantic projection into the existing Ash process stack.

  `AshPPlan` intentionally owns no scheduler, queue, retry engine, transaction
  engine, or workflow executor. Those capabilities remain with Reactor,
  Ash.Reactor, AshOban/Oban, and Ash.

  It does own the semantic planning layer those runtimes do not provide:
  hierarchical process semantics, FOND policy validation, and adapters that
  observe Ash resource lifecycles and Reactor outcomes without stealing their
  authority.
  """

  alias AshPPlan.{Compiler, ExecutionReceipt, FOND, ReactorOutcome, StateMachine}
  alias AshPPlan.Generated.{PlanCatalog, ProjectionCatalog}

  # Derived from mix.exs at compile time so the runtime surface and the
  # package metadata can never disagree about which release is running.
  @version Mix.Project.config()[:version]

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

  @doc "Builds a pure-data FOND domain for downstream policy validation."
  def fond_domain(transitions, goals \\ []), do: FOND.new(transitions, goals)

  @doc "Validates a strong or strong-cyclic FOND policy from an initial state."
  def validate_policy(domain, policy, initial, mode \\ :strong_cyclic),
    do: FOND.validate_policy(domain, policy, initial, mode)

  @doc "Projects an installed AshStateMachine resource into a FOND domain."
  def state_machine_domain(resource, goals \\ []), do: StateMachine.from_resource(resource, goals)

  @doc "Classifies Reactor's public result as a stable planner observation."
  def reactor_outcome_state(outcome), do: ReactorOutcome.state(outcome)

  @doc "Compiles an admitted plan into a Reactor using caller-supplied step implementations."
  def compile_plan(plan_iri, handlers) when is_binary(plan_iri) and is_map(handlers) do
    Compiler.compile(plan_iri, handlers)
  end

  @doc """
  Compiles and executes an admitted P-PLAN plan through Reactor.

  On an observed execution this returns `{reactor_outcome, receipt}`.

  A refused compilation returns the refusal itself — `{:error,
  AshPPlan.Compiler.Error.t()}` — with no receipt, because nothing was executed
  and there is therefore nothing to observe. Match on
  `AshPPlan.Compiler.Error` to tell a refusal apart from an observed failure.

  `:run_id` may be passed in `options`; otherwise an existing context `:run_id`
  is preserved, or a new run identity is generated. The selected identity is
  given to Reactor as its own run option, placed in the step context, and
  recorded on the receipt, so all three agree.

  The `:ash_pplan` context key is reserved: Reactor merges the run context over
  each step's context, so a caller-supplied `:ash_pplan` would replace the
  semantic step metadata the compiler bound. It is refused rather than silently
  overwritten.
  """
  def execute(plan_iri, handlers, input, context \\ %{}, options \\ [])
      when is_binary(plan_iri) and is_map(handlers) and is_map(context) and is_list(options) do
    {option_run_id, reactor_options} = Keyword.pop(options, :run_id)
    run_id = option_run_id || Map.get(context, :run_id) || new_run_id()

    with :ok <- assert_context_free_of_reserved_keys(context),
         {:ok, reactor} <- Compiler.compile(plan_iri, handlers) do
      started_at = DateTime.utc_now()
      started_mono = System.monotonic_time(:microsecond)
      context = Map.put(context, :run_id, run_id)

      outcome =
        Reactor.run(
          reactor,
          %{input: input},
          context,
          Keyword.put(reactor_options, :run_id, run_id)
        )

      receipt = ExecutionReceipt.observe(plan_iri, run_id, outcome, started_at, started_mono)
      {outcome, receipt}
    end
  end

  @reserved_context_keys [:ash_pplan]

  defp assert_context_free_of_reserved_keys(context) do
    case Enum.filter(@reserved_context_keys, &Map.has_key?(context, &1)) do
      [] ->
        :ok

      reserved ->
        {:error,
         %Compiler.Error{reason: :reserved_context_keys, details: %{keys: Enum.sort(reserved)}}}
    end
  end

  @doc """
  Returns a step's P-PLAN predecessor results, keyed by predecessor step IRI.

  Call this from inside a `Reactor.Step` with the arguments and context Reactor
  handed it. `p-plan:isPrecededBy` becomes a real Reactor result dependency, so
  a step can observe what preceded it without ash_pplan holding any execution
  state of its own.

      def run(arguments, context, _options) do
        %{"https://w3id.org/ash-pplan#AuthorizePayment" => authorization} =
          AshPPlan.predecessor_results(arguments, context)

        {:ok, authorization}
      end
  """
  def predecessor_results(arguments, %{ash_pplan: %{predecessor_arguments: bindings}})
      when is_map(arguments) and is_map(bindings) do
    Map.new(bindings, fn {predecessor, argument_name} ->
      {predecessor, Map.get(arguments, argument_name)}
    end)
  end

  def predecessor_results(arguments, _context) when is_map(arguments), do: %{}

  @doc "Executes a Reactor without introducing an ash_pplan execution runtime."
  def run(reactor, inputs, context \\ %{}, options \\ []) do
    Reactor.run(reactor, inputs, context, options)
  end

  defp new_run_id do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "ash-pplan-" <> suffix
  end
end
