defmodule AshPPlan.Workflow.QualifiedFulfillmentProcessCourtTest do
  @moduledoc """
  Process court for the GENERATED `qualified_fulfillment` model on the native durable ledger.

  Real collaborators throughout: Ash resources (ETS), a Bandit payment server, tmp-dir files, a
  supervised worker, the FulfillmentRobot GenServer, the ETS-backed durable store, the engine and
  Reactor. The human release is a real durable `Await` (signal `approved` / `refused`).

  Standing = PlanCorrect and ExecutionCorrect and ObservedConsequenceCorrect
  (`AshPPlan.Standing`, fed by `AshPPlan.Examples.QualifiedFulfillment.Standing.run/1`), derived from process-evidence events built
  from the standing ledger, the effect counters and real state, never from a step's own claim.

  Positive control: the attempt is killed while blocked on the release, the lease lapses, a fresh
  attempt replays from checkpoints, `approved` arrives; standing is alive and each effect counter
  is exactly 1. Falsifiers, each of which must lose standing with the matching broken term:
  self-reported commit persisting nothing; physical pick issued twice; picked item bound to
  another item than the order holds; manual method executed though the plan selected the robotic
  one; payment declined then shipment committed (FOND-inadmissible); payment authorized twice
  after a resume that lost its checkpoint.

  Anti-vacuity: the coverage assertion pins evidence to all 11 model tasks (empty evidence cannot
  pass), an injected extra commit counter flips the positive control to lost, and the resume with
  the full ledger keeps the payment at one request.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshPPlan.Examples.QualifiedFulfillment.{Domain, Ledger, Order, Shipment}
  alias AshPPlan.Examples.QualifiedFulfillment.Standing, as: Observe
  alias AshPPlan.Standing
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.AshEx4pm
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{Effects, FulfillmentRobot, PaymentServer, QualifiedFulfillmentCollab}
  alias AshPPlan.Workflow.Subject

  setup do
    Domain.reset!()
    Ledger.install_adapter!()
    Clock.use_test_clock()

    dir =
      Path.join(
        System.tmp_dir!(),
        "qf-proc-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
      )

    effects = :"qf_proc_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: effects)
    {:ok, store} = Ets.start_link()

    on_exit(fn ->
      Clock.reset()
      File.rm_rf(dir)
      Domain.reset!()
    end)

    order = Ash.create!(Order, %{sku: "ITEM-A", quantity: 2, amount: 500}, action: :place)
    {:ok, dir: dir, effects: effects, store: store, order: order}
  end

  defp collab(opts \\ []) do
    {:ok, c} = QualifiedFulfillmentCollab.start(Keyword.merge([step_ms: 5], opts))
    on_exit(c.stop)
    c
  end

  defp start(t, collab, id, overrides \\ %{}, extra \\ %{}) do
    context = Ledger.context(collab, t.dir, t.effects, extra)
    {:ok, _} = Engine.start(t.store, Ledger.attrs(id, t.order.id, context, overrides))
    :ok
  end

  # The library run for the current real state (re-read on every call).
  defp standing_run(t, collab, id, extra \\ %{}) do
    t |> standing_ctx(collab, id, extra) |> Observe.run()
  end

  defp standing_ctx(t, collab, id, extra) do
    Map.merge(
      %{
        run_id: id,
        model: Ledger.model(),
        selection: Ledger.selection(),
        events: Ledger.events(t.store, id),
        effects: t.effects,
        collab: collab,
        dir: t.dir,
        order_id: t.order.id
      },
      extra
    )
  end

  defp shipments(id), do: Shipment |> Ash.Query.filter(order_id == ^id) |> Ash.read!()

  # ---- selection is the plan's, the model is the generated one ----

  test "the plan selects the robotic provider and the model is the generated one" do
    sel = Ledger.selection()
    assert sel[:pick_inventory] == :actuator
    assert sel[:await_human_release] == :durable_gate
    assert Ledger.model().name == "qualified_fulfillment"
    assert length(Ledger.model().tasks) == 11
    assert Ledger.workflow().hddl() =~ "pick_inventory_physical"
  end

  # ---- positive control ----

  test "positive control: kill the blocked attempt, resume from checkpoints, standing alive",
       %{store: store, effects: effects} = t do
    collab = collab()
    id = "proc-ok"
    :ok = start(t, collab, id, %{await_human_release: [block_ms: 60_000]})

    parent = self()
    victim = spawn(fn -> send(parent, {:attempt, Engine.attempt(store, id)}) end)
    await_waiter(store, id)

    assert Effects.all(effects) == %{admit: 1, authorize: 1, pick_robot: 1}
    assert Effects.count(effects, :commit) == 0
    assert FulfillmentRobot.command_count(collab.robot) == 1

    Ledger.kill_attempt(victim)
    refute Process.alive?(victim)
    Clock.advance(3_600_000)

    {:ok, _} = Testing.signal(store, id, Ledger.signal_name(), :approved)
    assert [{^id, {:completed, _}}] = Testing.drain(store)

    assert Testing.status(store, id) == :completed
    assert Effects.all(effects) == %{admit: 1, authorize: 1, pick_robot: 1, commit: 1}
    assert PaymentServer.request_count(collab.payment) == 1

    run = standing_run(t, collab, id)
    assert length(run.events) == 11

    assert run.events |> Enum.map(& &1.attributes.task) |> Enum.sort() ==
             Ledger.model().tasks |> Enum.map(&to_string(&1.id)) |> Enum.sort()

    assert Standing.plan_correct(run) == :ok
    assert Standing.execution_correct(run) == :ok
    assert Standing.observed_consequence_correct(run) == :ok
    assert Standing.standing(run) == :alive

    # the receipt: five fields, ALIVE, replay digest over the sealed hash-chained ledger
    {:ok, receipt} = Standing.receipt(run, replay_commands: replay_commands())
    assert receipt.standing.value == "ALIVE"
    assert receipt.identity.run_id == id
    assert receipt.authority.ceiling == "CONSTRUCT"
    assert receipt.replay.ledger_digest =~ ~r/^[0-9a-f]{64}$/
    assert receipt.consequence.observed.shipments == 1

    # evidence form: OCEL2 JSON and the ex4pm envelope carry the run's subject
    subject = Subject.bind(Ledger.model())
    assert {:ok, json} = ProcessEvidence.export(run.events, :ocel2_json)
    assert json =~ subject.id
    env = AshEx4pm.envelope(run.events, subject: subject)
    assert env["schema"] == "ash_ex4pm/1"
    assert length(env["events"]) == 11

    if AshEx4pm.available?() do
      assert {:ok, _} = AshEx4pm.validate(run.events, subject: subject)
    else
      assert {:error, %{reason: :unsupported}} = AshEx4pm.validate(run.events)
    end

    # anti-vacuity: one injected extra commit and the same run loses standing
    Effects.record(effects, :commit)
    assert Standing.standing(standing_run(t, collab, id)) == {:lost, [:execution_correct]}
  end

  test "refused release commits nothing", %{store: store, effects: effects} = t do
    collab = collab()
    :ok = start(t, collab, "proc-refused")

    outcome = Ledger.drive(store, "proc-refused", :refused)
    refute match?({:completed, _}, outcome)
    assert Effects.count(effects, :commit) == 0
    assert shipments(t.order.id) == []
    assert Ash.get!(Order, t.order.id).status != :fulfilled
  end

  # ---- falsifiers: each loses standing with the matching broken term ----

  test "falsifier 1: CommitShipment self-reports success and persists nothing", t do
    collab = collab()
    :ok = start(t, collab, "f1", %{commit_shipment: [persist: false]})
    assert {:completed, _} = Ledger.drive(t.store, "f1")

    assert shipments(t.order.id) == []
    run = standing_run(t, collab, "f1")
    assert Standing.plan_correct(run) == :ok
    assert Standing.execution_correct(run) == :ok

    assert {:error, failed} = Standing.observed_consequence_correct(run)
    assert :order_fulfilled in failed and :one_shipment in failed
    assert Standing.standing(run) == {:lost, [:observed_consequence_correct]}

    # the receipt carries the refusal with its broken term
    {:ok, receipt} = Standing.receipt(run, replay_commands: replay_commands())
    assert receipt.standing.value == "REFUSED(observed_consequence_correct)"
    assert receipt.standing.broken_term == "R_missing_consequence"
  end

  test "falsifier 2: the physical pick is issued twice", t do
    collab = collab()
    :ok = start(t, collab, "f2", %{pick_inventory: [double: true]})
    assert {:completed, _} = Ledger.drive(t.store, "f2")

    assert FulfillmentRobot.command_count(collab.robot) == 2
    run = standing_run(t, collab, "f2")
    assert {:error, _} = Standing.execution_correct(run)
    assert Standing.standing(run) == {:lost, [:execution_correct]}
  end

  test "falsifier 3: InventoryPicked bound to ITEM-B while the order holds ITEM-A", t do
    collab = collab()
    :ok = start(t, collab, "f3", %{pick_inventory: [item: "ITEM-B"]})
    assert {:completed, _} = Ledger.drive(t.store, "f3")

    run = standing_run(t, collab, "f3")

    assert {:error, [:picked_item_is_ordered_item]} =
             Standing.observed_consequence_correct(run)

    assert Standing.standing(run) == {:lost, [:observed_consequence_correct]}
  end

  test "falsifier 4: the manual method runs though the plan selected the robotic one", t do
    collab = collab()
    :ok = start(t, collab, "f4", %{pick_inventory: [provider: :fulfillment_manual]})
    assert {:completed, _} = Ledger.drive(t.store, "f4")

    assert Effects.count(t.effects, :pick_manual) == 1
    assert Effects.count(t.effects, :pick_robot) == 0
    run = standing_run(t, collab, "f4")

    assert {:error, {:provider_not_selected, "pick_inventory", "fulfillment_manual", :actuator}} =
             Standing.plan_correct(run)

    assert Standing.standing(run) == {:lost, [:plan_correct]}
    {:ok, receipt} = Standing.receipt(run, replay_commands: replay_commands())
    assert receipt.standing.broken_term == "mu_on_O"
  end

  test "falsifier 5: payment declined then shipment committed is FOND-inadmissible", t do
    collab = collab(mode: fn _ -> 402 end)
    :ok = start(t, collab, "f5", %{authorize_payment: [lenient: true]})
    assert {:completed, _} = Ledger.drive(t.store, "f5")

    run = standing_run(t, collab, "f5")

    assert {:error, {:inadmissible_path, :authorize_payment, "declined"}} =
             Standing.plan_correct(run)

    assert Standing.standing(run) == {:lost, [:plan_correct]}
  end

  test "control for 5: an honest decline stops the run before any physical effect", t do
    collab = collab(mode: fn _ -> 402 end)
    :ok = start(t, collab, "f5c")
    outcome = Ledger.drive(t.store, "f5c")

    refute match?({:completed, _}, outcome)
    assert Effects.count(t.effects, :commit) == 0
    assert Effects.count(t.effects, :pick_robot) == 0
    assert FulfillmentRobot.command_count(collab.robot) == 0
    assert Ash.get!(Order, t.order.id).status == :new
  end

  test "falsifier 6: payment authorized twice after a resume that lost its checkpoint", t do
    collab = collab()
    :ok = start(t, collab, "f6")
    assert [{"f6", {:parked, _}}] = Testing.drain(t.store)
    assert Effects.count(t.effects, :authorize) == 1

    {:ok, fresh} = rebuild(t.store, "f6", &(Ledger.task_of(&1.label) == "authorize_payment"))
    t2 = %{t | store: fresh}
    assert {:completed, _} = Ledger.drive(fresh, "f6")

    assert PaymentServer.request_count(collab.payment) == 2
    run = standing_run(t2, collab, "f6")
    assert {:error, _} = Standing.execution_correct(run)

    # the re-run authorize also lands after its downstream steps in the ledger: plan order breaks too
    assert {:lost, broken} = Standing.standing(run)
    assert :execution_correct in broken and :plan_correct in broken
    refute :observed_consequence_correct in broken
  end

  test "control for 6: resume over the full ledger keeps the payment at one request", t do
    collab = collab()
    :ok = start(t, collab, "f6c")
    assert [{"f6c", {:parked, _}}] = Testing.drain(t.store)

    {:ok, fresh} = rebuild(t.store, "f6c", fn _ -> false end)
    t2 = %{t | store: fresh}
    assert {:completed, _} = Ledger.drive(fresh, "f6c")

    assert PaymentServer.request_count(collab.payment) == 1
    assert Standing.standing(standing_run(t2, collab, "f6c")) == :alive
  end

  @tag :unsupported
  @tag unsupported_reason:
         "AshPPlan.Workflow.Runtime.resolve over the example providers is refused by the shipped " <>
           "adapters (ash_reactor has no op order_admit), so provider selection in this court is " <>
           "the lowest-cost qualified provider per capability, bound to the :qf_ledger test adapter"
  test "Runtime.resolve over the example providers is refused by the shipped adapters" do
    assert {:error, %{reason: :no_qualified_provider, task: :admit_order}} =
             AshPPlan.Workflow.Runtime.resolve(Ledger.workflow(),
               providers: AshPPlan.Test.Examples.ProviderIndex.modules()
             )
  end

  # ---- helpers ----

  defp replay_commands do
    [
      %{
        cmd: "mix test test/workflow/qualified_fulfillment_process_court_test.exs",
        cwd: File.cwd!(),
        exit: 0
      }
    ]
  end

  defp await_waiter(store, id, tries \\ 400) do
    cond do
      Testing.waiting_on(store, id) != [] ->
        :ok

      tries == 0 ->
        flunk("attempt never parked a waiter")

      true ->
        Process.sleep(10)
        await_waiter(store, id, tries - 1)
    end
  end

  # Re-seed a fresh store from persisted data only; `drop?` omits checkpoints (a lost write).
  defp rebuild(old, id, drop?) do
    persisted = Ets.get_run(old, id)
    ledger = Ets.standing(old, id)
    waiters = Ets.waiters(old, id)
    GenServer.stop(old)

    {:ok, fresh} = Ets.start_link()

    {:ok, _} =
      Ets.start_run(fresh, %{
        id: persisted.id,
        model: persisted.model,
        bindings: persisted.bindings,
        inputs: persisted.inputs,
        context: persisted.context,
        parent: nil
      })

    {:ok, _} = Ets.transition(fresh, id, :any, persisted.status, %{})

    for cp <- ledger, not drop?.(cp) do
      {:ok, _} =
        Ets.record(fresh, id, cp.step_key, cp.label, cp.output, %{impl: cp.impl, args: cp.args})
    end

    for w <- waiters, do: {:ok, _} = Ets.park(fresh, id, w.name, w.kind, w.deadline, [])
    {:ok, fresh}
  end
end
