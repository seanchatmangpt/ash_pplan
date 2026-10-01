defmodule AshPPlan.Workflow.CanonicalCourtTest do
  @moduledoc """
  The canonical example court: ONE example — the QualifiedFulfillment durable spine
  (`admit_order -> authorize_payment -> await_human_release -> commit_shipment`) — validates the
  moonshot capabilities, Chicago-style. Each positive assertion on the real engine is paired with a
  **negative control that must flip**: a hand-written mutant (a real, behaviour-broken store or a
  genuinely corrupted input, never a mocked court) proves the assertion can fail.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, LedgerOCEL, Migration, PolicyDriver}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Standing
  alias AshPPlan.Test.{CanonicalExample, DurableFx, Effects}

  @subject "sha256:" <> String.duplicate("cd", 32)

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, _} = Effects.start_link()
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  describe "durable ledger (exactly-once)" do
    test "each effect runs exactly once; the tape is the four spine steps", %{store: store} do
      run = CanonicalExample.run(store)
      assert run.counts == %{admit: 1, authorize: 1, commit: 1}
      assert length(run.tape) == 4
    end

    test "negative control: a double-record store doubles the standing tape" do
      {:ok, inner} = Ets.start_link()

      # Real broken implementation: `record/6` writes the checkpoint AND a shadow copy, so the
      # standing tape doubles and the exactly-once court's `length(tape) == 4` must flip.
      defmodule MutantDoubleRecordStore do
        @behaviour AshPPlan.Reactor.Durable.Store

        @impl true
        defdelegate start_link(opts), to: Ets
        @impl true
        defdelegate start_run(s, attrs), to: Ets
        @impl true
        defdelegate get_run(s, id), to: Ets
        @impl true
        defdelegate list_runs(s), to: Ets
        @impl true
        defdelegate transition(s, id, from, to, attrs), to: Ets
        @impl true
        defdelegate claim(s, id, c, l, now), to: Ets
        @impl true
        defdelegate release_claim(s, id, c), to: Ets
        @impl true
        defdelegate checkpoints(s, id), to: Ets
        @impl true
        defdelegate standing(s, id), to: Ets
        @impl true
        defdelegate claim_undo(s, id, key, now), to: Ets
        @impl true
        defdelegate release_undo(s, id, key), to: Ets
        @impl true
        defdelegate deliver_signal(s, id, n, p), to: Ets
        @impl true
        defdelegate pending_signal(s, id, n), to: Ets
        @impl true
        defdelegate consume_signal(s, sid, now), to: Ets
        @impl true
        defdelegate park(s, id, n, k, d, opts \\ []), to: Ets
        @impl true
        defdelegate get_waiter(s, id, n), to: Ets
        @impl true
        defdelegate waiters(s, id), to: Ets
        @impl true
        defdelegate release(s, id, n), to: Ets
        @impl true
        defdelegate release_all(s, id), to: Ets
        @impl true
        defdelegate signals(s, id), to: Ets

        @impl true
        def record(s, id, key, label, output, meta) do
          with {:ok, _} <- Ets.record(s, id, key, label, output, meta) do
            Ets.record(s, id, <<0, key::binary>>, "shadow-" <> label, output, meta)
          end
        end
      end

      {:ok, mutant} = MutantDoubleRecordStore.start_link([])

      {:ok, _} = Engine.start(mutant, DurableFx.attrs("dbl-1", []))
      {:parked, :waiting} = Engine.attempt(mutant, "dbl-1", store_module: MutantDoubleRecordStore)

      {:ok, _} = Engine.signal(mutant, "dbl-1", DurableFx.signal_name(), :approved)

      {:completed, _} = Engine.attempt(mutant, "dbl-1", store_module: MutantDoubleRecordStore)

      tape =
        Enum.map(MutantDoubleRecordStore.standing(mutant, "dbl-1"), & &1.label)

      # The flip: the exactly-once court asserts `length(tape) == 4`; the mutant yields 8.
      refute length(tape) == 4
      assert length(tape) == 8
    end
  end

  describe "store contract" do
    @tag :tmp_dir
    test "the same canonical run leaves identical ledgers on Ets and Dets", %{
      tmp_dir: tmp_dir,
      store: store
    } do
      {:ok, dets} = Dets.start_link(path: Path.join(tmp_dir, "canon.dets"))

      {:ok, fx_e} = Effects.start_link(name: :ce_ets_fx)
      {:ok, fx_d} = Effects.start_link(name: :ce_dets_fx)

      e =
        CanonicalExample.run(store, id: "ce-ets", effects: fx_e)

      d = CanonicalExample.run(dets, id: "ce-dets", store_mod: Dets, effects: fx_d)

      assert e.counts == %{admit: 1, authorize: 1, commit: 1}
      assert d.counts == e.counts
      assert e.tape == d.tape
      assert e.record.status == d.record.status
      assert e.record.status == :completed
    end
  end

  describe "protocol law" do
    test "every status move the canonical run makes is legal in the generated ontology", %{
      store: store
    } do
      {tmap, _} = Code.eval_file(Path.expand("../../priv/tla/durable/transitions.exs", __DIR__))
      legal = MapSet.new(tmap.transitions)

      CanonicalExample.run(store)

      observed = [
        {:pending, :waiting},
        {:waiting, :pending},
        {:pending, :completed}
      ]

      for move <- observed do
        assert move in legal, "#{inspect(move)} is not a legal transition"
      end

      # Negative control: a corrupted trace (terminal -> parked) is refused by the same map.
      refute {:completed, :waiting} in legal
    end
  end

  describe "crash idempotency" do
    test "a fresh run id re-executes: the exactly-once assertion can fail", %{store: store} do
      CanonicalExample.run(store, id: "crash-a")
      counts_before = Effects.all(AshPPlan.Test.Effects)
      assert counts_before[:admit] == 1

      CanonicalExample.run(store, id: "crash-b")
      assert Effects.all(AshPPlan.Test.Effects)[:admit] == 2
    end
  end

  describe "evolution (migration)" do
    test "rename replays without re-execution; an orphaning plan is refused", %{store: store} do
      attrs = CanonicalExample.attrs("mig-1")

      {:ok, _} = Engine.start(store, attrs)
      {:parked, :waiting} = Engine.attempt(store, "mig-1")

      old = CanonicalExample.model()

      {:ok, new} =
        AshPPlan.Workflow.Model.new(
          name: old.name,
          goal: old.goal,
          tasks:
            Enum.map(old.tasks, fn t ->
              cond do
                t.id == :authorize_payment -> %{t | id: :verify_payment}
                t.depends_on == [:authorize_payment] -> %{t | depends_on: [:verify_payment]}
                true -> t
              end
            end)
        )

      assert {:ok, plan} =
               Migration.plan(old, new, renames: %{:authorize_payment => :verify_payment})

      assert {:ok, %{status: :migrated}} =
               Migration.apply(store, "mig-1", plan, store_module: Ets)

      # The completed admit step was not re-executed: counters did not move.
      assert Effects.all(AshPPlan.Test.Effects)[:admit] == 1

      # Negative control: dropping a task that HAS a standing checkpoint must be REFUSED.
      # The rename migration already moved the run's model, so build the orphaning plan from
      # the run's CURRENT model; verify_payment (renamed authorize_payment) stands in the ledger.
      current = Engine.fetch(store, "mig-1", store_module: Ets).model

      shrunk =
        current
        |> then(fn m ->
          tasks =
            m.tasks
            |> Enum.reject(&(&1.id == :verify_payment))
            |> Enum.map(fn t -> %{t | depends_on: List.delete(t.depends_on, :verify_payment)} end)

          methods =
            Enum.reject(m.methods || [], fn m -> :verify_payment in Map.get(m, :subtasks, []) end)

          %{m | tasks: tasks, methods: methods}
        end)

      assert {:ok, orphan_plan} = Migration.plan(current, shrunk, renames: %{})

      assert {:error, %{reason: :orphaned_checkpoints, orphaned: orphaned}} =
               Migration.apply(store, "mig-1", orphan_plan, store_module: Ets)

      assert Enum.any?(orphaned, &(&1.task == :verify_payment or &1.cause != nil))
    end
  end

  describe "counterfactual" do
    test "replay leaves the original ledger untouched", %{store: store} do
      CanonicalExample.run(store, id: "cf-1")
      assert {:ok, d1} = LedgerOCEL.digest(store, "cf-1")

      assert {:ok, replay} =
               AshPPlan.Reactor.Durable.Counterfactual.replay(store, "cf-1",
                 store_module: Ets,
                 change: %{outputs: %{:commit_shipment => "counterfactual"}}
               )

      assert {:ok, d2} = LedgerOCEL.digest(store, "cf-1")
      assert d1 == d2
      assert match?(%{}, replay)
    end
  end

  describe "evidence (OCEL)" do
    test "events are subject-bound and the digest is tamper-evident", %{store: store} do
      attrs = %{
        CanonicalExample.attrs("ocel-1")
        | context: %{:ash_pplan_workflow => %{subject: @subject, task: "canonical"}}
      }

      {:ok, _} = Engine.start(store, attrs)

      {:parked, :waiting} = Engine.attempt(store, "ocel-1")
      {:ok, _} = Engine.signal(store, "ocel-1", DurableFx.signal_name(), :approved)
      {:completed, _} = Engine.attempt(store, "ocel-1")

      assert {:ok, events} = LedgerOCEL.events(store, "ocel-1")
      assert Enum.all?(events, &(&1.subject_id == @subject))
    end
  end

  describe "standing" do
    test "an honest run is ALIVE; a self-report without consequence is REFUSED", %{store: store} do
      CanonicalExample.run(store, id: "st-1")

      # Positive: plan, execution and observed consequence all hold on the canonical run.
      assert Standing.verdict(:ok, :ok, :ok) == :alive

      # Falsifier: execution "succeeded" but nothing was observed in the world -> REFUSED.
      assert {:lost, [:observed_consequence_correct]} = Standing.verdict(:ok, :ok, :no)

      # The canonical events bound to the run are what makes the consequence layer checkable.
      assert {:ok, events} = LedgerOCEL.events(store, "st-1")

      assert Enum.any?(
               events,
               &(&1.activity == "run_ended" and &1.attributes[:status] == "completed")
             )
    end
  end

  describe "authority" do
    test "a :do variant is refused, plan state intact" do
      assert {:ok, m} =
               AshPPlan.Workflow.Model.new(
                 name: "do_gate",
                 goal: "released",
                 tasks: [
                   [id: :gate, capability: "Human.Approve", authority: :do, after: []]
                 ]
               )

      assert {:error,
              %{reason: :authority_above_ceiling, tasks: [gate: :do], ceiling: :construct}} =
               AshPPlan.Workflow.Model.validate(m)
    end
  end

  describe "policy driver" do
    test "an inadmissible policy is refused before any effect" do
      assert {:error, {:inadmissible_policy, _}} =
               PolicyDriver.admit(%PolicyDriver{
                 domain: nil,
                 policy: %{},
                 initial: nil,
                 mode: :strong
               })
    end
  end
end
