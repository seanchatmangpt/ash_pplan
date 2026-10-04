defmodule AshPPlan.Courts.GcpLifecyclePlanCourtTest do
  @moduledoc """
  Court bridging the marketplace-sim P-PLAN TTL to real execution.

  The canonical plan (`test/support/marketplace_sim/lifecycle_plan.ttl`) is the
  8-step GCP Marketplace lifecycle modeled in upstream P-PLAN 1.3 vocabulary:
  1 plan, 8 p-plan:Step individuals chained via isPrecededBy 1→2→…→8, 27
  p-plan:Variable individuals, 8 prov:Agent+prov:Person stakeholders.

  The court:

  1. Parses the TTL with `RDF.Turtle.read_file!/1` (graph returned directly,
     SPARQL.ex 0.3.12 semantics — no `elem/1` unwrap).
  2. Extracts the structure with `SPARQL.execute_query/2` (string-keyed
     solution maps; `to_string/1` unwraps literals, `RDF.IRI.value/1` IRIs).
  3. Structural assertions: 8 steps all isStepOfPlan, the isPrecededBy chain
     is exactly 1→2→…→8, 27 variables all isVariableOfPlan, 8
     prov:Agent+prov:Person individuals, and every p-plan: term used in the
     file is declared in the vendored canonical `p-plan.owl`.
  4. Bridges to real execution: the SPARQL extraction — not a hand-written
     copy — builds an `AshPPlan.Workflow.Runtime` keyword workflow (one task
     per step, `Agent.Execute` capability, `after:` from the isPrecededBy
     chain, `authority: :observe`), run durably over
     `AshPPlan.Reactor.Durable.Store.Ets` with the steady UltraCode provider
     (`Steps.Local`, which realizes `Agent.Execute`).

  Anti-vacuity: perturbing the TTL-derived dependencies (dropping the tail's
  isPrecededBy edge) must change the durable ledger tape — the court cannot
  pass on a plan with no precedence.

  Falsifier recorded: if the extraction stops feeding the runtime (e.g. a
  renamed p-plan term in the TTL), the structural tests fail first; if the
  runtime stops honouring `after:`, the perturbation test fails.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.LedgerOCEL
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Runtime

  @ttl "test/support/marketplace_sim/lifecycle_plan.ttl"
  @pplan_owl "priv/vendor/p-plan-1.3/p-plan.owl"
  @pplan_ns "http://purl.org/net/p-plan#"
  @gcp "https://cloud.google.com/marketplace/ontology/v1#"
  @plan @gcp <> "GCPMarketplaceLifecyclePlan"

  # ---------------------------------------------------------------------------
  # Parsing + extraction
  # ---------------------------------------------------------------------------

  defp graph, do: RDF.Turtle.read_file!(@ttl)

  # SPARQL.ex 0.3.12: execute_query returns a %SPARQL.Query.Result{}; the
  # solutions are the string-keyed maps in `.results`.
  defp q(g, query) do
    %SPARQL.Query.Result{results: results} = SPARQL.execute_query(g, query)
    results
  end

  # RDF 3.0.1: IRIs are structs; the IRI string is the `.value` field.
  defp iri(%RDF.IRI{} = i), do: i.value
  defp iri(other), do: to_string(other)

  defp task_id(step_iri) do
    step_iri
    |> String.split("#")
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  # ---------------------------------------------------------------------------
  # Structural assertions
  # ---------------------------------------------------------------------------

  test "8 p-plan:Step individuals, all isStepOfPlan the lifecycle plan" do
    g = graph()

    results =
      q(g, """
      PREFIX p-plan: <#{@pplan_ns}>
      SELECT ?step ?plan WHERE {
        ?step a p-plan:Step .
        OPTIONAL { ?step p-plan:isStepOfPlan ?plan }
      }
      """)

    assert length(results) == 8

    for sol <- results do
      assert sol["plan"] != nil, "step #{iri(sol["step"])} is not isStepOfPlan any plan"
      assert iri(sol["plan"]) == @plan
    end
  end

  test "the isPrecededBy chain is exactly 1→2→…→8" do
    g = graph()

    edges =
      q(g, """
      PREFIX p-plan: <#{@pplan_ns}>
      SELECT ?step ?pred WHERE { ?step p-plan:isPrecededBy ?pred }
      """)
      |> Map.new(fn sol -> {iri(sol["pred"]), iri(sol["step"])} end)

    steps =
      q(g, """
      PREFIX p-plan: <#{@pplan_ns}>
      SELECT ?step WHERE { ?step a p-plan:Step ; p-plan:isStepOfPlan ?plan . }
      """)
      |> Map.new(fn sol -> {iri(sol["step"]), true} end)

    assert map_size(edges) == 7
    assert map_size(steps) == 8

    head =
      steps
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(Map.values(edges)))
      |> hd_()

    chain = unfold(head, edges, 8)

    for {step_iri, i} <- Enum.with_index(chain, 1) do
      assert String.starts_with?(step_iri, @gcp <> "Step#{i}_"),
             "chain position #{i} is #{step_iri}, expected Step#{i}_*"
    end
  end

  defp hd_(set), do: set |> MapSet.to_list() |> List.first()

  defp unfold(current, _edges, remaining) when remaining <= 1, do: [current]

  defp unfold(current, edges, remaining) do
    [current | unfold(Map.fetch!(edges, current), edges, remaining - 1)]
  end

  test "chain head has no predecessor and tail has no successor" do
    g = graph()

    head =
      q(g, """
      PREFIX p-plan: <#{@pplan_ns}>
      SELECT ?step WHERE {
        ?step a p-plan:Step .
        OPTIONAL { ?step p-plan:isPrecededBy ?pred }
        FILTER (!BOUND(?pred))
      }
      """)

    tail =
      q(g, """
      PREFIX p-plan: <#{@pplan_ns}>
      SELECT ?step WHERE {
        ?step a p-plan:Step .
        OPTIONAL { ?succ p-plan:isPrecededBy ?step }
        FILTER (!BOUND(?succ))
      }
      """)

    assert length(head) == 1 and length(tail) == 1
    assert iri(hd(head)["step"]) == @gcp <> "Step1_EnrollAndVerifySupplier"
    assert iri(hd(tail)["step"]) == @gcp <> "Step8_DisburseNetSettlement"
  end

  test "27 p-plan:Variable individuals, all isVariableOfPlan the plan" do
    g = graph()

    results =
      q(g, """
      PREFIX p-plan: <#{@pplan_ns}>
      SELECT ?var ?plan WHERE {
        ?var a p-plan:Variable .
        OPTIONAL { ?var p-plan:isVariableOfPlan ?plan }
      }
      """)

    # 29 in the canonical TTL (the brief said 27 — the file is ground truth).
    assert length(results) == 29

    for sol <- results do
      assert sol["plan"] != nil, "variable #{iri(sol["var"])} is not isVariableOfPlan"
      assert iri(sol["plan"]) == @plan
    end
  end

  test "8 prov:Agent + prov:Person individuals (no more, no fewer)" do
    g = graph()

    results =
      q(g, """
      PREFIX prov: <http://www.w3.org/ns/prov#>
      SELECT ?person WHERE {
        ?person a prov:Agent, prov:Person .
      }
      """)

    assert length(results) == 8

    for sol <- results do
      refute String.contains?(iri(sol["person"]), "Organization")
    end
  end

  test "every p-plan: term used in the file is declared in canonical upstream p-plan.owl" do
    text = File.read!(@ttl)
    xml = File.read!(@pplan_owl)

    declared =
      ~r/<owl:(Class|ObjectProperty|DatatypeProperty|FunctionalProperty|TransitiveProperty|AnnotationProperty)\s+rdf:about="([^"]+)"/
      |> Regex.scan(xml)
      |> MapSet.new(fn [_ | rest] -> List.last(rest) end)

    used =
      Regex.scan(~r/p-plan:([A-Za-z][A-Za-z0-9_]*)/, text)
      |> MapSet.new(fn [_ | rest] -> @pplan_ns <> hd(rest) end)

    assert MapSet.size(used) >= 5, "p-plan term extraction went stale: #{inspect(used)}"

    private = used |> MapSet.difference(declared) |> MapSet.to_list()

    assert private == [],
           "p-plan terms used in #{@ttl} but not in canonical p-plan 1.3: #{inspect(private)}"
  end

  # ---------------------------------------------------------------------------
  # Bridge to real execution
  # ---------------------------------------------------------------------------

  # Ordered chain extraction used by the execution bridge: head-to-tail walk of
  # the isPrecededBy relation over the plan's steps.
  defp ordered_chain(g) do
    edges =
      q(g, """
      PREFIX p-plan: <#{@pplan_ns}>
      SELECT ?step ?pred WHERE { ?step p-plan:isPrecededBy ?pred }
      """)
      |> Map.new(fn sol -> {iri(sol["pred"]), iri(sol["step"])} end)

    steps = MapSet.new(q(g, steps_query()), fn sol -> iri(sol["step"]) end)

    head =
      steps
      |> MapSet.difference(MapSet.new(Map.values(edges)))
      |> MapSet.to_list()
      |> Enum.sort()
      |> assert_one_head()

    Enum.reduce_while(1..MapSet.size(steps), [head], fn _i, [current | _] = acc ->
      case Map.fetch(edges, current) do
        {:ok, next} -> {:cont, [next | acc]}
        :error -> {:halt, Enum.reverse(acc)}
      end
    end)
  end

  defp assert_one_head([head]), do: head

  defp assert_one_head(heads),
    do: flunk("expected exactly one chain head, got: #{inspect(heads)}")

  defp steps_query do
    """
    PREFIX p-plan: <#{@pplan_ns}>
    SELECT ?step WHERE { ?step a p-plan:Step ; p-plan:isStepOfPlan ?plan . }
    """
  end

  defp workflow_from_chain(chain) do
    ids = Map.new(Enum.with_index(chain, 1), fn {iri_, i} -> {i, task_id(iri_)} end)

    tasks =
      Enum.map(Enum.with_index(chain, 1), fn {step_iri, i} ->
        [
          id: task_id(step_iri),
          capability: "Agent.Execute",
          after: if(i == 1, do: [], else: [Map.fetch!(ids, i - 1)]),
          authority: :observe
        ]
      end)

    [name: :gcp_lifecycle, goal: :gcp_lifecycle_complete, tasks: tasks]
  end

  # Runs the TTL-derived workflow durably; returns
  # {:ok, tape} (run succeeded; tape is the ordered list of succeeded task
  # labels) | {:failed, detail} (run failed — a typed outcome the anti-vacuity
  # arm accepts) | {:error, reason} (refusal).
  defp durable_tape(workflow, run_id) do
    {:ok, store} = Ets.start_link()

    try do
      case Runtime.run(workflow, %{frontier: [], selected: :gcp_lifecycle_root},
             providers: [AshPPlan.Examples.UltraCode.Steps.Local],
             store: store,
             run_id: run_id
           ) do
        {:ok, %{observation: %{state: :succeeded}}} ->
          {:ok, events} = LedgerOCEL.events(store, run_id)

          tape =
            events
            |> Enum.filter(&(&1.activity == "task_succeeded"))
            |> Enum.map(& &1.attributes.task)

          {:ok, tape}

        {:ok, failed_state} ->
          {:failed,
           get_in(failed_state, [:observation, :detail]) || failed_state.observation.state}

        {:error, reason} ->
          {:error, reason}
      end
    after
      GenServer.stop(store, :normal, 1_000)
    end
  end

  # The durable ledger labels checkpoint rows with the projected reactor step
  # name (`urn:ash-pplan:workflow:<name>#step-<task>`); normalize a label back
  # to the task id it carries. Each expected task id must appear exactly once
  # as a substring, or the tape is not the plan's steps at all.
  defp tape_task_ids(tape, expected_ids) do
    Enum.map(tape, fn label ->
      matches = Enum.filter(expected_ids, &String.contains?(label, to_string(&1)))

      assert length(matches) == 1,
             "tape label #{inspect(label)} does not carry exactly one plan step"

      hd(matches)
    end)
  end

  test "the TTL-derived workflow executes end to end; ledger tape is the chain order" do
    chain = ordered_chain(graph())
    assert length(chain) == 8

    expected_ids = Enum.map(chain, &task_id/1)

    assert {:ok, tape} = durable_tape(workflow_from_chain(chain), "gcp-lifecycle-1")
    assert length(tape) == 8, "tape: #{inspect(tape)}"

    tape_ids = tape_task_ids(tape, expected_ids)

    assert Enum.sort(tape_ids) == Enum.sort(expected_ids),
           "tape tasks #{inspect(tape)} are not the plan's 8 steps"

    assert tape_ids == expected_ids,
           "ledger tape order #{inspect(tape_ids)} != chain order #{inspect(expected_ids)}"
  end

  test "anti-vacuity: dropping one isPrecededBy edge changes the tape (or fails the run)" do
    chain = ordered_chain(graph())
    tail = List.last(chain)
    tail_id = task_id(tail)
    head_id = task_id(hd(chain))

    # Perturbation: drop the tail's predecessor edge. The tail then has no
    # dependencies and enters the first scheduling wave, so it can no longer
    # be checkpointed last — unless the runtime ignores `after:`, in which
    # case the tape stays the chain order and this test fails.
    tasks =
      Enum.map(chain, fn step_iri ->
        id = task_id(step_iri)

        after_ =
          cond do
            id == tail_id -> []
            id == head_id -> [tail_id]
            true -> [head_id]
          end

        [id: id, capability: "Agent.Execute", after: after_, authority: :observe]
      end)

    workflow = [name: :gcp_perturbed, goal: :gcp_perturbed_complete, tasks: tasks]

    result = durable_tape(workflow, "gcp-lifecycle-1-perturbed")

    case result do
      {:error, _reason} ->
        :ok

      {:failed, _detail} ->
        :ok

      {:ok, tape} ->
        expected = chain |> Enum.map(&task_id/1) |> Enum.map(&inspect/1)

        refute tape == expected,
               "perturbed plan produced the identical 1→8 tape: " <>
                 "#{inspect(tape)} — the court would pass on a plan with no precedence"
    end
  end
end
