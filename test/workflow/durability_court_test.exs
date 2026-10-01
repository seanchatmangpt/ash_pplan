defmodule AshPPlan.Workflow.DurabilityCourtTest do
  @moduledoc """
  Durability Court: a halted, enriched Reactor captured through
  `AshPPlan.Continuation` resumes with its semantic identity (subject, task,
  IRI, properties) intact. Anti-vacuity: a continuation of a reactor enriched
  for a different workflow carries a different identity, and a tampered payload
  is refused.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Continuation
  alias AshPPlan.Continuation.ETFCodec
  alias AshPPlan.Workflow.{Evidence, Model, Subject}

  defmodule Gate do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_a, context, _o) do
      if Map.has_key?(context, :resumed_by),
        do: {:ok, :released},
        else: {:halt, :awaiting}
    end
  end

  defmodule Finish do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(%{gate: gate}, context, _o), do: {:ok, {gate, context.ash_pplan_workflow}}
  end

  defp build(name) do
    {:ok, model} =
      Model.new(
        name: name,
        tasks: [
          [id: :gate, capability: "File.Read", properties: ["durable"], authority: :observe],
          [id: :finish, capability: "File.Write", after: [:gate]]
        ]
      )

    {:ok, r} = Reactor.Builder.add_step(Reactor.Builder.new(), :gate, Gate, [])
    {:ok, r} = Reactor.Builder.add_step(r, :finish, Finish, gate: {:result, :gate})
    {:ok, r} = Reactor.Builder.return(r, :finish)
    {:ok, r} = AshPPlan.Reactor.enrich(r, model)
    {model, r}
  end

  defp halt(r, run_id) do
    assert {:halted, halted} = Reactor.run(r, %{}, %{run_id: run_id})
    halted
  end

  test "resume preserves semantic identity across capture and restore" do
    {model, r} = build("dur")
    subject = Subject.bind(model)
    halted = halt(r, "dur-1")
    plan_iri = Evidence.plan_iri(subject.id)
    assert halted.id == plan_iri

    assert {:ok, continuation} = Continuation.capture(plan_iri, "dur-1", halted, ETFCodec)
    assert {:ok, restored} = Continuation.restore(continuation, ETFCodec)

    steps = planned_steps(restored)
    assert steps != []

    for step <- steps do
      assert AshPPlan.Reactor.identity_of(step).subject == subject.id
    end

    assert {:ok, {:awaiting, identity}} =
             Continuation.resume(continuation, ETFCodec, %{resumed_by: "op"})

    assert identity.task == "finish"
    assert identity.subject == subject.id
    assert identity.iri == subject.correspondence[:finish].semantic
  end

  test "resume re-emits subject-bound telemetry" do
    {model, r} = build("dur-tel")
    subject = Subject.bind(model)
    plan_iri = Evidence.plan_iri(subject.id)
    halted = halt(r, "dur-tel-1")
    {:ok, continuation} = Continuation.capture(plan_iri, "dur-tel-1", halted, ETFCodec)

    test_pid = self()
    handler = "dur-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Evidence.telemetry_event(),
      fn _e, _m, md, _c -> send(test_pid, {:ev, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = Continuation.resume(continuation, ETFCodec, %{resumed_by: "op"})
    assert_receive {:ev, %{subject_id: id, status: :succeeded, run_id: "dur-tel-1"}}
    assert id == subject.id
  end

  test "a different workflow's continuation carries a different identity (anti-vacuity)" do
    {model_a, ra} = build("dur-a")
    {model_b, rb} = build("dur-b")
    refute Subject.bind(model_a).id == Subject.bind(model_b).id

    ca = restored_identity(ra, model_a, "a")
    cb = restored_identity(rb, model_b, "b")
    refute ca.subject == cb.subject
    assert ca.workflow == "dur-a" and cb.workflow == "dur-b"
  end

  test "a tampered continuation is refused rather than resumed" do
    {model, r} = build("dur-tamper")
    plan_iri = Evidence.plan_iri(Subject.bind(model).id)
    halted = halt(r, "t-1")
    {:ok, continuation} = Continuation.capture(plan_iri, "t-1", halted, ETFCodec)
    tampered = %{continuation | payload: continuation.payload <> <<0>>}

    assert {:error, %{reason: :continuation_payload_digest_mismatch}} =
             Continuation.resume(tampered, ETFCodec, %{resumed_by: "op"})
  end

  defp planned_steps(%Reactor{steps: steps, plan: plan}) do
    from_plan =
      if plan, do: for(%Reactor.Step{} = s <- Multigraph.vertices(plan), do: s), else: []

    steps ++ from_plan
  end

  defp restored_identity(r, model, tag) do
    plan_iri = Evidence.plan_iri(Subject.bind(model).id)
    halted = halt(r, "id-" <> tag)
    {:ok, c} = Continuation.capture(plan_iri, "id-" <> tag, halted, ETFCodec)
    {:ok, restored} = Continuation.restore(c, ETFCodec)
    restored |> planned_steps() |> hd() |> AshPPlan.Reactor.identity_of()
  end
end
