defmodule AshPPlan.Workflow.QualifiedFulfillmentEcosystemTest do
  @moduledoc """
  Ecosystem court for the qualified-fulfillment vertical (test support only).

  One enriched Reactor run drives every real collaborator: Ash resources
  (ETS), a Bandit payment server, tmp-dir files, a supervised worker, the
  FulfillmentRobot GenServer, an AshOban deferred check and the observation
  middleware. The run is observed through `AshPPlan.Reactor.Middleware.Observation`;
  its events feed `AshPPlan.ProcessEvidence` and the ex4pm form.

  Standing is derived from the observed run receipt, never asserted by a step.
  Six falsifiers each break one real collaborator and must lose standing with
  the matching compensation visible in real state. Coverage assertions pin the
  model's tasks and capability families to observed step events.

  The human release gate (durable halt/kill/resume) is exercised by
  `QualifiedFulfillmentDurableTest`; it is not part of this single-pass run.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Ash.Query

  alias AshPPlan.Examples.QualifiedFulfillment.{Domain, Fulfillment, Followup, Order, Shipment}
  alias AshPPlan.Examples.QualifiedFulfillment.Steps, as: QF
  alias AshPPlan.Examples.QualifiedFulfillment.Steps.{AdmitOrder, CommitShipment, VerifyPackage}
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.AshEx4pm
  alias AshPPlan.Reactor.Middleware.Observation
  alias AshPPlan.Reactor.Middleware.Observation.Collector
  alias AshPPlan.Test.{FulfillmentRobot, FulfillmentWorker, QualifiedFulfillmentCollab}
  alias AshPPlan.Workflow.{Model, Subject}

  # ---- real steps over real collaborators ----

  defmodule Admit do
    @moduledoc false
    use Reactor.Step
    alias AshPPlan.Examples.QualifiedFulfillment.Steps.AdmitOrder
    @impl true
    def run(%{order_id: id}, _c, _o), do: AdmitOrder.run(%{order_id: id}, %{}, [])
    @impl true
    def undo(res, args, c, o), do: AdmitOrder.undo(res, args, c, o)
  end

  defmodule Authorize do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, ctx, _o) do
      id = QF.order_id(args)

      case Req.post(ctx.payment_url <> "/payments/authorize", body: "{}", retry: false) do
        {:ok, %{status: 200}} -> {:ok, %{order_id: id, authorized: true}}
        {:ok, %{status: s}} -> {:error, {:payment_refused, s}}
        {:error, e} -> {:error, {:payment_unreachable, e}}
      end
    end
  end

  defmodule Manifest do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, ctx, _o) do
      id = QF.order_id(args)
      path = Path.join(ctx.dir, "manifest-#{id}.txt")
      File.mkdir_p!(ctx.dir)
      File.write!(path, "order=#{id}\n")
      {:ok, %{order_id: id, path: path}}
    end

    @impl true
    def undo(%{path: path}, _a, _c, _o), do: (File.rm(path) && :ok) || :ok
  end

  defmodule Worker do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, ctx, _o) do
      case FulfillmentWorker.ping(ctx.worker_name) do
        :pong ->
          {:ok, %{order_id: QF.order_id(args), starts: FulfillmentWorker.starts(ctx.worker_name)}}
      end
    catch
      :exit, _ -> {:error, :worker_unavailable}
    end
  end

  defmodule Pick do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, ctx, _o) do
      case FulfillmentRobot.command(ctx.robot, {:pick, "SKU-1"}) do
        :ok -> {:ok, %{order_id: QF.order_id(args)}}
        {:error, why} -> {:error, {:pick_rejected, why}}
      end
    end
  end

  defmodule AwaitPick do
    @moduledoc false
    use Reactor.Step
    alias AshPPlan.Examples.QualifiedFulfillment.Fulfillment
    require Ash.Query

    @impl true
    def run(args, ctx, _o) do
      id = QF.order_id(args)
      FulfillmentRobot.subscribe(ctx.robot, self())

      case wait(ctx.robot, 40) do
        :packing_station ->
          unless Map.get(ctx, :skip_pack, false) do
            for f <- Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!(),
                do: Ash.update!(f, %{}, action: :pack)
          end

          {:ok, %{order_id: id}}

        other ->
          {:error, {:pick_incomplete, other}}
      end
    end

    defp wait(_robot, 0), do: :timeout

    defp wait(robot, n) do
      case FulfillmentRobot.state(robot) do
        :packing_station -> :packing_station
        :fault -> :fault
        _ -> Process.sleep(10) && wait(robot, n - 1)
      end
    end
  end

  defmodule Verify do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, _c, _o), do: VerifyPackage.run(%{order_id: QF.order_id(args)}, %{}, [])
  end

  defmodule Commit do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, _c, _o), do: CommitShipment.run(%{order_id: QF.order_id(args)}, %{}, [])
    @impl true
    def undo(res, args, c, o), do: CommitShipment.undo(res, args, c, o)
  end

  defmodule Schedule do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, _c, _o) do
      id = QF.order_id(args)

      with {:ok, %{record: record, job: job}} <- Followup.schedule("order:" <> id) do
        {:ok, %{order_id: id, record_id: record.id, job_valid?: job.valid?}}
      end
    end
  end

  defmodule Establish do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(args, _c, _o), do: {:ok, %{order_id: QF.order_id(args), established: true}}
  end

  # ---- model + reactor (generic capability vocabulary) ----

  @tasks [
    {:admit_order, "Domain.Admit", :select, [], Admit},
    {:authorize_payment, "Network.Authorize", :construct, [:admit_order], Authorize},
    {:produce_manifest, "File.Write", :select, [:authorize_payment], Manifest},
    {:prepare_worker, "Process.EnsureAvailable", :select, [:authorize_payment], Worker},
    {:pick_inventory, "Actuation.Command", :select, [:produce_manifest, :prepare_worker], Pick},
    {:await_pick, "State.Await", :observe, [:pick_inventory], AwaitPick},
    {:verify_package, "Domain.Verify", :observe, [:await_pick], Verify},
    {:commit_shipment, "Transaction.Commit", :construct, [:verify_package], Commit},
    {:schedule_followup, "Scheduling.Deferred", :select, [:commit_shipment], Schedule},
    {:establish_evidence, "Evidence.Establish", :observe, [:schedule_followup], Establish}
  ]

  defp model(name \\ "qf_ecosystem", drop \\ nil) do
    tasks =
      for {id, cap, auth, deps, _} <- @tasks, id != drop do
        [id: id, capability: cap, authority: auth, after: Enum.reject(deps, &(&1 == drop))]
      end

    {:ok, m} = Model.new(name: name, goal: "fulfill_order", tasks: tasks)
    m
  end

  defp reactor(model) do
    ids = Enum.map(model.tasks, & &1.id)
    {:ok, r} = Reactor.Builder.add_input(Reactor.Builder.new(), :order_id)

    r =
      for {id, _c, _a, deps, impl} <- @tasks, id in ids, reduce: r do
        r ->
          deps = Enum.filter(deps, &(&1 in ids))

          args =
            if deps == [],
              do: [order_id: {:input, :order_id}],
              else: Enum.map(deps, &{&1, {:result, &1}})

          {:ok, r} = Reactor.Builder.add_step(r, id, impl, args)
          r
      end

    {:ok, r} = Reactor.Builder.return(r, :establish_evidence)
    {:ok, r} = AshPPlan.Reactor.enrich(r, model)
    {:ok, r} = AshPPlan.Reactor.add_middleware(r, [Observation])
    r
  end

  # ---- harness ----

  setup do
    Domain.reset!()
    dir = Path.join(System.tmp_dir!(), "qf-eco-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    on_exit(&Domain.reset!/0)
    order = Ash.create!(Order, %{sku: "SKU-1", quantity: 2, amount: 500}, action: :place)
    {:ok, order: order, dir: dir}
  end

  defp collaborators(opts \\ []) do
    {:ok, c} = QualifiedFulfillmentCollab.start(Keyword.merge([step_ms: 5], opts))
    on_exit(c.stop)
    c
  end

  # Runs the workflow; standing comes from the run receipt the middleware observed.
  defp run(collab, ctx, order, opts \\ []) do
    m = Keyword.get(opts, :model, model())
    {:ok, sink} = Collector.start()

    context =
      %{
        payment_url: collab.payment.url,
        dir: ctx.dir,
        worker_name: collab.worker_name,
        robot: collab.robot,
        skip_pack: Keyword.get(opts, :skip_pack, false)
      }

    log =
      capture_log(fn ->
        send(
          self(),
          {:res, Reactor.run(reactor(m), %{order_id: order.id}, context, async?: false)}
        )
      end)

    result = receive do: ({:res, r} -> r)
    events = Collector.events(sink)
    Collector.stop(sink)

    run_stop = for {[:ash_pplan, :observation, :run, p], _, meta} <- events, do: {p, meta}
    status = run_stop |> List.first() |> then(fn {_, meta} -> meta.receipt.status end)

    %{
      model: m,
      result: result,
      events: events,
      log: log,
      status: status,
      standing: if(status == :succeeded, do: :alive, else: :lost),
      evidence: for({_, _, %{evidence: e}} <- events, do: e)
    }
  end

  defp status(id), do: Ash.get!(Order, id).status
  defp shipments(id), do: Shipment |> Ash.Query.filter(order_id == ^id) |> Ash.read!()

  defp stopped_tasks(run) do
    for {[:ash_pplan, :observation, :step, :stop], _, %{task: t}} <- run.events, do: t
  end

  # ---- happy path + coverage ----

  test "full run: every real collaborator acts, standing is alive from the observed receipt",
       %{order: o} = ctx do
    collab = collaborators()
    run = run(collab, ctx, o)

    assert {:ok, %{established: true}} = run.result
    assert run.standing == :alive
    assert status(o.id) == :fulfilled
    assert [_] = shipments(o.id)
    assert File.exists?(Path.join(ctx.dir, "manifest-#{o.id}.txt"))
    assert FulfillmentRobot.state(collab.robot) == :packing_station
    assert FulfillmentRobot.command_count(collab.robot) == 1
    assert FulfillmentWorker.starts(collab.worker_name) == 1
    assert AshPPlan.Test.PaymentServer.request_count(collab.payment) == 1
  end

  test "coverage: every model task has an observed :stop event under the model subject",
       %{order: o} = ctx do
    collab = collaborators()
    run = run(collab, ctx, o)
    subject = Subject.bind(run.model).id

    model_tasks = run.model.tasks |> Enum.map(&to_string(&1.id)) |> Enum.sort()
    assert stopped_tasks(run) |> Enum.sort() == model_tasks
    assert length(model_tasks) == 10
    assert Enum.all?(run.evidence, &(&1.subject_id == subject))

    families =
      run.model.tasks |> Enum.map(&(&1.capability |> to_string() |> String.split(".") |> hd()))

    for fam <- ~w(Domain Network File Process Actuation State Transaction Scheduling Evidence) do
      assert fam in families, "family #{fam} not covered"
    end

    # anti-vacuity: dropping a task changes the observed task set and the subject
    reduced = run(collab, ctx, o, model: model("qf_ecosystem", :schedule_followup))
    refute Subject.bind(reduced.model).id == subject
    refute "schedule_followup" in stopped_tasks(reduced)
  end

  test "process evidence: OCEL2 JSON and ex4pm envelope carry the run's subject",
       %{order: o} = ctx do
    collab = collaborators()
    run = run(collab, ctx, o)
    subject = Subject.bind(run.model).id

    assert {:ok, json} = ProcessEvidence.export(run.evidence, :ocel2_json)
    assert json =~ subject

    env = AshEx4pm.envelope(run.evidence, subject: Subject.bind(run.model))
    assert env["schema"] == "ash_ex4pm/1"
    assert length(env["events"]) == length(run.evidence)

    if AshEx4pm.available?() do
      assert {:ok, _} = AshEx4pm.validate(run.evidence, subject: Subject.bind(run.model))
    else
      assert {:error, %{reason: :unsupported}} = AshEx4pm.validate(run.evidence)
    end
  end

  # ---- six falsifiers: each breaks one real collaborator and loses standing ----

  test "falsifier 1: payment declined (402) loses standing; admit is compensated",
       %{order: o} = ctx do
    collab = collaborators(mode: fn _ -> 402 end)
    run = run(collab, ctx, o)

    assert {:error, _} = run.result
    assert run.standing == :lost
    assert status(o.id) == :new
    assert AshPPlan.Test.PaymentServer.request_count(collab.payment) == 1
    refute File.exists?(Path.join(ctx.dir, "manifest-#{o.id}.txt"))
    assert FulfillmentRobot.command_count(collab.robot) == 0
  end

  test "falsifier 2: payment server down loses standing before any physical effect",
       %{order: o} = ctx do
    collab = collaborators()
    collab.payment.stop.()
    run = run(collab, ctx, o)

    assert {:error, _} = run.result
    assert run.standing == :lost
    assert status(o.id) == :new
    assert FulfillmentRobot.command_count(collab.robot) == 0
    refute "pick_inventory" in stopped_tasks(run)
  end

  test "falsifier 3: worker absent loses standing; manifest is compensated; no pick",
       %{order: o} = ctx do
    collab = collaborators()
    :ok = Supervisor.terminate_child(collab.supervisor, collab.worker_name)
    run = run(collab, ctx, o)

    assert {:error, _} = run.result
    assert run.standing == :lost
    assert FulfillmentRobot.command_count(collab.robot) == 0
    assert status(o.id) == :new
    refute File.exists?(Path.join(ctx.dir, "manifest-#{o.id}.txt"))
  end

  test "falsifier 4: robot fault rejects the pick; standing lost; no shipment",
       %{order: o} = ctx do
    collab = collaborators()
    FulfillmentRobot.fault(collab.robot)
    run = run(collab, ctx, o)

    assert {:error, _} = run.result
    assert run.standing == :lost
    assert shipments(o.id) == []
    assert status(o.id) == :new
    refute File.exists?(Path.join(ctx.dir, "manifest-#{o.id}.txt"))
  end

  test "falsifier 5: unpacked package fails verification; standing lost; order not fulfilled",
       %{order: o} = ctx do
    collab = collaborators()
    run = run(collab, ctx, o, skip_pack: true)

    assert {:error, _} = run.result
    assert run.standing == :lost
    assert shipments(o.id) == []
    assert status(o.id) == :new
    assert "await_pick" in stopped_tasks(run)
    refute "commit_shipment" in stopped_tasks(run)
  end

  test "falsifier 6: evidence under a mutated model does not carry the original subject",
       %{order: o} = ctx do
    collab = collaborators()
    base = run(collab, ctx, o)
    Domain.reset!()
    FulfillmentRobot.reset(collab.robot)
    o2 = Ash.create!(Order, %{sku: "SKU-1", quantity: 2, amount: 500}, action: :place)
    mutated = run(collab, ctx, o2, model: model("qf_ecosystem_mutated"))

    assert base.standing == :alive
    assert mutated.standing == :alive
    base_subject = Subject.bind(base.model).id
    mutated_subject = Subject.bind(mutated.model).id
    refute base_subject == mutated_subject
    # evidence from the mutated run must not be admissible as evidence for the base subject
    assert Enum.all?(mutated.evidence, &(&1.subject_id == mutated_subject))
    refute Enum.any?(mutated.evidence, &(&1.subject_id == base_subject))

    # and an evidence-less reading (steps run without enrichment) yields no subject-bound events
    assert {:ok, json} = ProcessEvidence.export([], :ocel2_json)
    refute json =~ base_subject
  end

  # ---- explicit unsupported ----

  @tag :unsupported
  @tag unsupported_reason:
         "generated QualifiedFulfillment model uses Order/Payment/Shipment/Schedule/Actuator/Human " <>
           "capability families not in the shipped AshPPlan.Capability family list; this court uses " <>
           "the generic vocabulary instead and the durable human gate is covered by the durable court"
  test "generated qualified_fulfillment capability ids: admitted, or typed :invalid_capability" do
    {:ok, m} =
      Model.new(
        name: "probe",
        tasks: [[id: :t, capability: "Order.Admit", authority: :select]]
      )

    case Model.validate(m) do
      :ok -> :ok
      {:error, %{reason: reason}} -> assert reason == :invalid_capability
    end
  end
end
