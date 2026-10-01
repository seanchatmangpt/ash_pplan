defmodule AshPPlan.Workflow.ReactorExtensionTest do
  @moduledoc """
  Court: `AshPPlan.Reactor.enrich/3` stamps semantic identity onto a real
  Reactor, installs the identity/evidence middlewares, and a real run observes
  that identity. Anti-vacuity: a reactor that diverges from the model is
  refused, and an un-enriched reactor carries no identity.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Evidence, Model, Subject}

  defmodule Probe do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_arguments, context, _options) do
      {:ok, Map.get(context, :ash_pplan_workflow)}
    end
  end

  def model(name \\ "rx-ext") do
    {:ok, model} =
      Model.new(
        name: name,
        goal: "close",
        tasks: [
          [id: :observe, capability: "File.Read", properties: ["durable"], authority: :observe],
          [id: :build, capability: "File.Write", after: [:observe], authority: :construct]
        ]
      )

    model
  end

  def reactor(model, extra \\ []) do
    base = Reactor.Builder.new()
    {:ok, r} = Reactor.Builder.add_step(base, :observe, Probe, [])
    {:ok, r} = Reactor.Builder.add_step(r, :build, Probe, observed: {:result, :observe})

    r =
      Enum.reduce(extra, r, fn name, acc ->
        {:ok, acc} = Reactor.Builder.add_step(acc, name, Probe, [])
        acc
      end)

    {:ok, r} = Reactor.Builder.return(r, :build)
    _ = model
    r
  end

  test "enrich stamps identity on every step and binds the reactor id to the subject" do
    model = model()
    assert {:ok, enriched} = AshPPlan.Reactor.enrich(reactor(model), model)
    subject = Subject.bind(model)

    assert enriched.id == Evidence.plan_iri(subject.id)

    for step <- enriched.steps do
      identity = AshPPlan.Reactor.identity_of(step)
      assert identity.subject == subject.id
      assert identity.workflow == "rx-ext"
      assert identity.task == to_string(step.name)
      assert identity.iri == subject.correspondence[String.to_atom(identity.task)].semantic
    end

    observe = Enum.find(enriched.steps, &(&1.name == :observe))
    assert AshPPlan.Reactor.identity_of(observe).properties == ["durable"]
    assert AshPPlan.Reactor.identity_of(observe).authority == :observe
  end

  test "a real run sees the identity and emits subject-bound telemetry" do
    model = model()
    {:ok, enriched} = AshPPlan.Reactor.enrich(reactor(model), model)
    subject = Subject.bind(model)
    test_pid = self()
    handler = "rx-ext-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Evidence.telemetry_event(),
      fn _event, _measurements, metadata, _config -> send(test_pid, {:telemetry, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, seen} = Reactor.run(enriched, %{}, %{run_id: "rx-ext-run"})
    assert seen.task == "build"
    assert seen.subject == subject.id

    assert_receive {:telemetry, %{subject_id: id, status: :succeeded, workflow: "rx-ext"}}
    assert id == subject.id
  end

  test "a reactor that diverges from the model is refused" do
    model = model()

    assert {:error, %{reason: :projection_diverges, unexpected: ["stowaway"]}} =
             AshPPlan.Reactor.enrich(reactor(model, [:stowaway]), model)
  end

  test "an un-enriched reactor carries no identity (anti-vacuity)" do
    model = model()
    r = reactor(model)
    assert Enum.all?(r.steps, &(AshPPlan.Reactor.identity_of(&1) == nil))
    assert {:ok, nil} = Reactor.run(r, %{}, %{run_id: "bare"})
  end

  test "the Identity middleware refuses a run whose workflow identity is gone" do
    assert {:error, %{reason: :missing_workflow_identity}} =
             AshPPlan.Reactor.Middleware.Identity.init(%{})
  end

  test "enrich is idempotent on middleware" do
    model = model()
    {:ok, once} = AshPPlan.Reactor.enrich(reactor(model), model)
    {:ok, twice} = AshPPlan.Reactor.enrich(once, model)
    assert length(once.middleware) == length(twice.middleware)
  end
end
