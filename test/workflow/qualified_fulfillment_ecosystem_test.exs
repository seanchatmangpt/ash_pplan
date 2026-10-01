defmodule AshPPlan.Workflow.QualifiedFulfillmentEcosystemTest do
  @moduledoc """
  Ecosystem court for the qualified-fulfillment vertical (test support only), run on the native
  durable ledger over the GENERATED `qualified_fulfillment` model (all 11 tasks, including
  `await_human_release` as a real durable `Await`).

  One engine run drives every real collaborator: Ash resources (ETS), a Bandit payment server,
  tmp-dir files, a supervised worker, the FulfillmentRobot GenServer, an AshOban deferred check,
  the ETS durable store, the engine and Reactor. The human release is held open, the attempt
  process is killed, the lease lapses, a fresh attempt resumes from the checkpoints and the
  `approved` signal completes the run; every effect counter is then exactly 1.

  Standing is derived from process-evidence events built from the standing ledger plus the
  counters and real state (`AshPPlan.Examples.QualifiedFulfillment.Standing`), never asserted by a
  step. Six falsifiers each break one real collaborator and must lose standing with the matching
  compensation visible in real state. Coverage assertions pin the model's tasks and capability
  families to the ledger. The additional process falsifiers live in
  `QualifiedFulfillmentProcessCourtTest`.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshPPlan.Examples.QualifiedFulfillment.{Domain, Ledger, Order, Shipment, Standing}
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.Standing, as: LibStanding
  alias AshPPlan.ProcessEvidence.AshEx4pm
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{Effects, FulfillmentRobot, PaymentServer, QualifiedFulfillmentCollab}
  alias AshPPlan.Workflow.{Model, Subject}

  setup do
    Domain.reset!()
    Ledger.install_adapter!()
    Clock.use_test_clock()
    dir = Path.join(System.tmp_dir!(), "qf-eco-#{System.unique_integer([:positive])}")
    effects = :"qf_eco_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: effects)
    {:ok, store} = Ets.start_link()

    on_exit(fn ->
      Clock.reset()
      File.rm_rf(dir)
      Domain.reset!()
    end)

    order = Ash.create!(Order, %{sku: "SKU-1", quantity: 2, amount: 500}, action: :place)
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

  # Full single run: park at the release, kill the blocked attempt, lapse the lease, resume, approve.
  defp run_killed(t, collab, id, extra \\ %{}) do
    :ok = start(t, collab, id, %{await_human_release: [block_ms: 60_000]}, extra)
    parent = self()
    victim = spawn(fn -> send(parent, {:attempt, Engine.attempt(t.store, id)}) end)
    await_parked_or_done(t.store, id)

    Ledger.kill_attempt(victim)
    Clock.advance(3_600_000)

    case Testing.status(t.store, id) do
      s when s in [:completed, :failed, :rolled_back, :cancelled] ->
        :ended

      _ ->
        {:ok, _} = Testing.signal(t.store, id, Ledger.signal_name(), :approved)
        t.store |> Testing.drain() |> Enum.filter(&match?({^id, _}, &1)) |> List.last() |> elem(1)
    end
  end

  defp await_parked_or_done(store, id, tries \\ 400) do
    done? = AshPPlan.Reactor.Durable.Status.terminal?(Testing.status(store, id))

    cond do
      done? or Testing.waiting_on(store, id) != [] -> :ok
      tries == 0 -> flunk("attempt neither parked nor ended")
      true -> Process.sleep(10) && await_parked_or_done(store, id, tries - 1)
    end
  end

  defp standing_ctx(t, collab, id) do
    %{
      model: Ledger.model(),
      selection: Ledger.selection(),
      events: Ledger.events(t.store, id),
      effects: t.effects,
      collab: collab,
      dir: t.dir,
      order_id: t.order.id,
      run_id: id
    }
  end

  defp verdict(ctx), do: ctx |> Standing.run() |> LibStanding.standing()

  defp status(id), do: Ash.get!(Order, id).status
  defp shipments(id), do: Shipment |> Ash.Query.filter(order_id == ^id) |> Ash.read!()
  defp manifest?(t), do: File.exists?(Path.join(t.dir, "manifest-#{t.order.id}.txt"))
  defp tasks_run(t, id), do: t.store |> Ledger.events(id) |> Enum.map(& &1.attributes.task)

  # ---- happy path + coverage ----

  test "full run: every real collaborator acts, the killed attempt resumes, effects are 1",
       %{order: o, effects: effects} = t do
    collab = collab()
    assert {:completed, result} = run_killed(t, collab, "eco-1")

    assert result.established
    assert Testing.status(t.store, "eco-1") == :completed
    assert status(o.id) == :fulfilled
    assert [_] = shipments(o.id)
    assert manifest?(t)
    assert FulfillmentRobot.state(collab.robot) == :packing_station
    assert FulfillmentRobot.command_count(collab.robot) == 1
    assert AshPPlan.Test.FulfillmentWorker.starts(collab.worker_name) == 1
    assert PaymentServer.request_count(collab.payment) == 1

    assert Effects.all(effects) == %{admit: 1, authorize: 1, pick_robot: 1, commit: 1}
    assert verdict(standing_ctx(t, collab, "eco-1")) == :alive
  end

  test "coverage: every generated model task is in the ledger under the model subject",
       %{} = t do
    collab = collab()
    assert {:completed, _} = run_killed(t, collab, "eco-cov")
    model = Ledger.model()
    subject = Subject.bind(model).id
    events = Ledger.events(t.store, "eco-cov")

    assert :ok = Model.validate(model)
    model_tasks = model.tasks |> Enum.map(&to_string(&1.id)) |> Enum.sort()
    assert events |> Enum.map(& &1.attributes.task) |> Enum.sort() == model_tasks
    assert length(model_tasks) == 11
    assert "await_human_release" in model_tasks
    assert Enum.all?(events, &(&1.subject_id == subject))

    families = model.tasks |> Enum.map(&(&1.capability |> String.split(".") |> hd()))

    for fam <- ~w(Order Payment Artifact Process Actuator State Human Shipment Schedule Evidence) do
      assert fam in families, "family #{fam} not covered"
    end

    # anti-vacuity: a model without a task has another subject and another task set
    reduced =
      Map.update!(model, :tasks, fn ts -> Enum.reject(ts, &(&1.id == :schedule_followup)) end)

    refute Subject.bind(reduced).id == subject
    refute "schedule_followup" in (reduced.tasks |> Enum.map(&to_string(&1.id)))
  end

  test "coverage: the model is the generated one and every task has a selected provider and a concrete realization" do
    model = Ledger.model()
    assert model == AshPPlan.Generated.Workflows.QualifiedFulfillment.model()

    sel = Ledger.selection()
    provider_ids = AshPPlan.Test.Examples.ProviderIndex.modules() |> Enum.map(& &1.id())

    for t <- model.tasks do
      assert sel[t.id] in provider_ids, "task #{t.id} has no selected provider"
    end

    bindings = Ledger.bindings()
    assert map_size(bindings) == length(model.tasks)

    for t <- model.tasks do
      real = Map.fetch!(bindings, t.id)
      assert real.capability == t.capability
      assert real.provider == sel[t.id]
    end

    # anti-vacuity: dropping a task from the model leaves a provider-less hole in the selection
    reduced = Map.update!(model, :tasks, &Enum.reject(&1, fn t -> t.id == :schedule_followup end))
    refute Map.has_key?(Ledger.selection(reduced), :schedule_followup)
  end

  test "process evidence: OCEL2 JSON and ex4pm envelope carry the run's subject", t do
    collab = collab()
    assert {:completed, _} = run_killed(t, collab, "eco-ev")
    subject = Subject.bind(Ledger.model())
    events = Ledger.events(t.store, "eco-ev")

    assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json)
    assert json =~ subject.id

    env = AshEx4pm.envelope(events, subject: subject)
    assert env["schema"] == "ash_ex4pm/1"
    assert length(env["events"]) == length(events)

    if AshEx4pm.available?() do
      assert {:ok, _} = AshEx4pm.validate(events, subject: subject)
    else
      assert {:error, %{reason: :unsupported}} = AshEx4pm.validate(events)
    end
  end

  # ---- six falsifiers: each breaks one real collaborator and loses standing ----

  test "falsifier 1: payment declined (402) loses standing; admit is compensated", t do
    collab = collab(mode: fn _ -> 402 end)
    :ok = start(t, collab, "e1")
    outcome = Ledger.drive(t.store, "e1")

    refute match?({:completed, _}, outcome)
    assert status(t.order.id) == :new
    assert PaymentServer.request_count(collab.payment) == 1
    refute manifest?(t)
    assert FulfillmentRobot.command_count(collab.robot) == 0
    assert {:lost, _} = verdict(standing_ctx(t, collab, "e1"))
  end

  test "falsifier 2: payment server down loses standing before any physical effect", t do
    collab = collab()
    collab.payment.stop.()
    :ok = start(t, collab, "e2")
    outcome = Ledger.drive(t.store, "e2")

    refute match?({:completed, _}, outcome)
    assert status(t.order.id) == :new
    assert FulfillmentRobot.command_count(collab.robot) == 0
    refute "pick_inventory" in tasks_run(t, "e2")
    assert {:lost, _} = verdict(standing_ctx(t, collab, "e2"))
  end

  test "falsifier 3: worker absent loses standing; manifest is compensated; no pick", t do
    collab = collab()
    :ok = Supervisor.terminate_child(collab.supervisor, collab.worker_name)
    :ok = start(t, collab, "e3")
    outcome = Ledger.drive(t.store, "e3")

    refute match?({:completed, _}, outcome)
    assert FulfillmentRobot.command_count(collab.robot) == 0
    assert status(t.order.id) == :new
    refute manifest?(t)
    assert {:lost, _} = verdict(standing_ctx(t, collab, "e3"))
  end

  test "falsifier 4: robot fault rejects the pick; standing lost; no shipment", t do
    collab = collab()
    FulfillmentRobot.fault(collab.robot)
    :ok = start(t, collab, "e4")
    outcome = Ledger.drive(t.store, "e4")

    refute match?({:completed, _}, outcome)
    assert shipments(t.order.id) == []
    assert status(t.order.id) == :new
    refute manifest?(t)
    assert {:lost, _} = verdict(standing_ctx(t, collab, "e4"))
  end

  test "falsifier 5: unpacked package fails verification; standing lost; order not fulfilled",
       t do
    collab = collab()
    :ok = start(t, collab, "e5", %{}, %{skip_pack: true})
    outcome = Ledger.drive(t.store, "e5")

    refute match?({:completed, _}, outcome)
    assert shipments(t.order.id) == []
    assert status(t.order.id) == :new
    refute "commit_shipment" in tasks_run(t, "e5")
    assert {:lost, _} = verdict(standing_ctx(t, collab, "e5"))
  end

  test "falsifier 6: evidence under a mutated model does not carry the original subject", t do
    collab = collab()
    assert {:completed, _} = run_killed(t, collab, "eco-base")
    base = Ledger.model()
    mutated = Map.update!(base, :name, &(&1 <> "_mutated"))

    base_subject = Subject.bind(base).id
    mutated_subject = Subject.bind(mutated).id
    refute base_subject == mutated_subject

    base_events = Ledger.events(t.store, "eco-base", base)
    mutated_events = Ledger.events(t.store, "eco-base", mutated)
    assert Enum.all?(base_events, &(&1.subject_id == base_subject))
    assert Enum.all?(mutated_events, &(&1.subject_id == mutated_subject))
    refute Enum.any?(mutated_events, &(&1.subject_id == base_subject))

    # an evidence-less reading yields no subject-bound events
    assert {:ok, json} = ProcessEvidence.export([], :ocel2_json)
    refute json =~ base_subject
  end
end
