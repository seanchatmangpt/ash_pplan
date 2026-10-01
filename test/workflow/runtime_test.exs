defmodule AshPPlan.Workflow.RuntimeTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Model, Runtime}
  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Providers.Registry

  @frontier [
    %{id: :a, status: :open, deps: []},
    %{id: :b, status: :open, deps: [:a]}
  ]

  test "validate and plan grant no authority and bind a subject" do
    assert {:ok, v} = Runtime.validate(Steps.workflow())
    assert v.granted == []
    assert v.ceiling == :construct
    assert "sha256:" <> _ = v.subject.id
  end

  test "authority above the ceiling is refused" do
    bad =
      Keyword.update!(
        Steps.workflow(),
        :tasks,
        &[[id: :x, capability: "Work.Observe", authority: :do] | &1]
      )

    assert {:error, %{reason: :authority_above_ceiling}} = Runtime.validate(bad)
  end

  test "resolve picks lowest cost and refuses with a typed error when none qualify" do
    assert {:ok, r} = Runtime.resolve(Steps.workflow(), providers: [Steps.Flaky, Steps.Local])
    assert r.bindings[:execute].provider == :ultracode_flaky
    assert r.bindings[:observe].provider == :ultracode_local

    assert {:error, %{reason: :no_qualified_provider, task: :observe}} =
             Runtime.resolve(Steps.workflow(), providers: [Steps.Flaky])
  end

  test "inspect lists order and methods" do
    assert {:ok, i} = Runtime.inspect(Steps.workflow())
    assert i.order == [:observe, :select, :execute, :integrate, :verify]
  end

  test "observe maps a failure to a transition and seals the provider" do
    {:ok, r} = Runtime.resolve(Steps.workflow(), providers: [Steps.Flaky, Steps.Local])
    {:ok, m} = Model.new(Steps.workflow())
    {:ok, p} = Runtime.plan(m)

    state = %{
      model: m,
      subject: p.subject,
      registry: r.registry,
      bindings: r.bindings,
      resolutions: r.resolutions,
      attempt: 1
    }

    assert {:ok, s} = Runtime.observe(state, {:error, :boom}, failed_task: :execute)
    assert s.observation.transition == %{from: :running, action: :execute, to: :failed}
    assert s.observation.sealed == Steps.Flaky
    assert s.registry.generation == r.registry.generation + 1
    assert Steps.Flaky in Map.keys(s.registry.sealed)
  end

  test "run succeeds end to end with bound evidence" do
    assert {:ok, s} =
             Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Local])

    assert s.observation.state == :succeeded
    assert {:ok, %{verified: true, closed: :a, open: [:b]}} = s.outcome
    assert :ok = AshPPlan.Workflow.Evidence.verify(s.evidence, s.subject.id)
  end

  test "failed provider is sealed and resume selects the alternative" do
    assert {:ok, s1} =
             Runtime.run(Steps.workflow(), %{frontier: @frontier},
               providers: [Steps.Flaky, Steps.Local]
             )

    assert s1.observation.state == :failed
    assert s1.observation.failed_task == :execute
    assert s1.observation.sealed == Steps.Flaky

    assert {:ok, s2} = Runtime.resume(s1)
    assert s2.observation.state == :succeeded
    assert s2.bindings[:execute].provider == :ultracode_local
    assert s2.attempt == 2
  end

  test "sealing the only provider yields a typed refusal on resume" do
    reg = Registry.new([Steps.Flaky, Steps.Local])
    {:ok, s1} = Runtime.run(Steps.workflow(), %{frontier: @frontier}, registry: reg)
    only_flaky = %{s1 | registry: Registry.new([Steps.Flaky])}
    assert {:error, %{reason: :no_qualified_provider}} = Runtime.resume(only_flaky)
  end

  test "resume of a succeeded run is refused" do
    {:ok, s} = Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Local])
    assert {:error, %{reason: :not_resumable}} = Runtime.resume(s)
  end

  test "anti-vacuity: without sealing, resume re-selects the failing provider and fails again" do
    {:ok, s1} =
      Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Flaky, Steps.Local])

    unsealed = %{s1 | registry: Registry.new([Steps.Flaky, Steps.Local])}
    assert {:ok, s2} = Runtime.resume(unsealed)
    assert s2.observation.state == :failed
    assert s2.bindings[:execute].provider == :ultracode_flaky
  end

  describe "durable path (store: given)" do
    alias AshPPlan.Reactor.Durable.Engine
    alias AshPPlan.Reactor.Durable.Store.Ets

    setup do
      {:ok, store} = Ets.start_link()
      {:ok, store: store}
    end

    test "a store-backed run completes with the same result shape and a ledger", %{store: store} do
      assert {:ok, s} =
               Runtime.run(Steps.workflow(), %{frontier: @frontier},
                 providers: [Steps.Local],
                 store: store,
                 run_id: "rt-1"
               )

      assert s.observation.state == :succeeded
      assert s.observation.transition == %{from: :running, action: :execute, to: :succeeded}
      assert {:ok, %{verified: true, closed: :a, open: [:b]}} = s.outcome
      assert :ok = AshPPlan.Workflow.Evidence.verify(s.evidence, s.subject.id)

      assert %{status: :completed} = Engine.fetch(store, "rt-1")
      assert length(Engine.steps(store, "rt-1")) == 5
    end

    test "failed durable run seals the provider; resume re-resolves only the failed task",
         %{store: store} do
      assert {:ok, s1} =
               Runtime.run(Steps.workflow(), %{frontier: @frontier},
                 providers: [Steps.Flaky, Steps.Local],
                 store: store,
                 run_id: "rt-2"
               )

      assert s1.observation.state == :failed
      assert s1.observation.failed_task == :execute
      assert s1.observation.sealed == Steps.Flaky
      assert %{status: :failed} = Engine.fetch(store, "rt-2")

      assert {:ok, s2} = Runtime.resume(s1)
      assert s2.observation.state == :succeeded
      assert s2.attempt == 2
      assert s2.run_id == "rt-2-a2"
      assert s2.bindings[:execute].provider == :ultracode_local

      # only the failed task was re-bound
      for id <- [:observe, :select, :integrate, :verify] do
        assert s2.bindings[id] == s1.bindings[id]
      end

      # the failed run stays terminal and was not re-run
      assert %{status: :failed} = Engine.fetch(store, "rt-2")
      assert Engine.attempt(store, "rt-2") == :ended
    end

    test "anti-vacuity: failover with an unsealed registry re-selects the failing provider",
         %{store: store} do
      {:ok, s1} =
        Runtime.run(Steps.workflow(), %{frontier: @frontier},
          providers: [Steps.Flaky, Steps.Local],
          store: store,
          run_id: "rt-3"
        )

      unsealed = %{s1 | registry: Registry.new([Steps.Flaky, Steps.Local])}
      assert {:ok, s2} = Runtime.resume(unsealed)
      assert s2.observation.state == :failed
      assert s2.bindings[:execute].provider == :ultracode_flaky
    end

    test "sealing the only provider yields a typed refusal on durable failover", %{store: store} do
      {:ok, s1} =
        Runtime.run(Steps.workflow(), %{frontier: @frontier},
          providers: [Steps.Flaky, Steps.Local],
          store: store,
          run_id: "rt-4"
        )

      sealed = Registry.seal(Registry.new([Steps.Flaky]), Steps.Flaky, {:failed, :execute})
      only_flaky = %{s1 | registry: sealed}

      assert {:error, %{reason: :no_qualified_provider, task: :execute}} =
               Runtime.resume(only_flaky)
    end

    test "signal on a non-durable state is refused" do
      assert {:error, %{reason: :not_a_durable_run}} = Runtime.signal(%{}, "x", 1)
    end

    test "run without a store keeps the in-process path (no store key in state)" do
      {:ok, s} = Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Local])
      refute Map.has_key?(s, :store)
    end
  end
end
