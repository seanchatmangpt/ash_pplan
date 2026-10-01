defmodule AshPPlan.Examples.QualifiedFulfillment.Ledger do
  @moduledoc """
  Test support: the GENERATED `qualified_fulfillment` model realised over real collaborators and
  run through the native durable engine (`AshPPlan.Reactor.Durable.*`).

  `Ledger.Adapter` is a test `AshPPlan.Reactor.Adapter` (`:qf_ledger`) mapping each of the model's
  capabilities to a real step over the Ash resources, the Bandit payment server, tmp-dir files, the
  supervised worker and the FulfillmentRobot. Step options are data (provider id plus behaviour
  flags); the collaborator handles travel in the run context. Every consequential step also counts
  into an `AshPPlan.Test.Effects` agent that lives outside every runner.

  `selection/1` is the plan's provider choice (lowest cost qualified provider per capability, the
  robotic actuator before the manual fulfilment provider). `events/3` turns the standing ledger
  into `AshPPlan.ProcessEvidence.Event`s; `AshPPlan.Examples.QualifiedFulfillment.Standing`
  derives standing from them.
  """

  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.{Engine, Testing}
  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Test.Examples.ProviderIndex
  alias AshPPlan.Workflow.Subject

  @workflow AshPPlan.Generated.Workflows.QualifiedFulfillment
  @signal "human_release"

  def workflow, do: @workflow
  def model, do: @workflow.model()
  def signal_name, do: @signal

  @doc "Register the `:qf_ledger` adapter for the calling test; restores on exit."
  def install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :qf_ledger, __MODULE__.Adapter)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
    :ok
  end

  @doc "Plan selection: task id => provider id (lowest cost provider supporting the capability)."
  def selection(model \\ model()) do
    providers = ProviderIndex.modules()

    Map.new(model.tasks, fn t ->
      chosen =
        providers
        |> Enum.filter(&(t.capability in &1.capabilities()))
        |> Enum.sort_by(&{&1.cost(), to_string(&1.id())})
        |> List.first()

      {t.id, chosen && chosen.id()}
    end)
  end

  @doc """
  Bindings for `model`: every task realised by `:qf_ledger` under the selected provider.
  `overrides` is `%{task_id => keyword}`; a `:provider` override changes the provider that
  actually runs while `selection/1` is unchanged (used by falsifiers).
  """
  def bindings(model \\ model(), overrides \\ %{}) do
    sel = selection(model)

    Map.new(model.tasks, fn t ->
      extra = Map.get(overrides, t.id, [])
      provider = Keyword.get(extra, :provider, Map.fetch!(sel, t.id))

      {t.id,
       %Realization{
         capability: t.capability,
         provider: provider,
         binding: %{adapter: :qf_ledger, op: Realization.op_for(t.capability)},
         options: Keyword.put(extra, :provider, provider)
       }}
    end)
  end

  @doc "Run attrs for `Engine.start/2`."
  def attrs(id, order_id, context, overrides \\ %{}) do
    %{
      id: id,
      model: model(),
      bindings: bindings(model(), overrides),
      inputs: %{input: %{order_id: order_id}},
      context: context,
      parent: nil
    }
  end

  @doc "Task id (string) from a standing label (`...#step-<task>`)."
  def task_of(label) do
    case Regex.run(~r/#step-([a-z_]+)/, label) do
      [_, task] -> task
      _ -> label
    end
  end

  @doc "Process-evidence events of a run from its standing ledger (undone steps excluded)."
  def events(store, run_id, model \\ model()) do
    sid = Subject.bind(model).id
    caps = Map.new(model.tasks, &{to_string(&1.id), &1.capability})

    for cp <- Engine.steps(store, run_id), cp.undone_at == nil do
      task = task_of(cp.label)
      out = if is_map(cp.output), do: cp.output, else: %{}
      provider = Map.get(out, :provider)

      %Event{
        id: "run:#{run_id}/#{task}/succeeded",
        activity: "task_succeeded",
        timestamp: DateTime.utc_now(),
        objects: [
          {"WorkflowRun", "run:" <> run_id, "run"},
          {"Capability", "cap:" <> to_string(caps[task]), "capability"},
          {"Realization", "real:" <> to_string(provider || "unrealized:" <> task), "realization"}
        ],
        attributes: %{
          task: task,
          seq: cp.seq,
          provider: provider && to_string(provider),
          outcome: Map.get(out, :outcome) && to_string(Map.fetch!(out, :outcome))
        },
        subject_id: sid
      }
    end
  end

  @doc "Run context carrying the collaborator handles (data; no closures)."
  def context(collab, dir, effects, extra \\ %{}) do
    Map.merge(
      %{
        payment_url: collab.payment.url,
        dir: dir,
        worker_name: collab.worker_name,
        robot: collab.robot,
        effects: effects,
        skip_pack: false
      },
      extra
    )
  end

  @doc """
  Drive a started run to rest: drain until it parks at the human release, deliver `payload`, drain
  again. A run that ended before the release (failure) is returned as it ended. Returns the last
  attempt outcome of `id`.
  """
  def drive(store, id, payload \\ :approved) do
    first = Testing.drain(store)

    if AshPPlan.Reactor.Durable.Status.terminal?(Testing.status(store, id)) do
      last_outcome(first, id)
    else
      {:ok, _} = Testing.signal(store, id, @signal, payload)
      last_outcome(Testing.drain(store), id)
    end
  end

  @doc """
  Kill an attempt outright: the attempt process and any step task it left blocked inside the
  durable `Await` (a step task is not linked to the attempt, so it would otherwise race the
  resumed attempt for the signal).
  """
  def kill_attempt(victim) do
    orphans =
      for pid <- Process.list(),
          pid != self(),
          {:current_stacktrace, st} <- [Process.info(pid, :current_stacktrace)],
          Enum.any?(st, fn {m, _, _, _} -> m == AshPPlan.Reactor.Durable.Steps.Await end),
          do: pid

    Enum.each([victim | orphans], &Process.exit(&1, :kill))
    :ok
  end

  defp last_outcome(outs, id) do
    case outs |> Enum.filter(&match?({^id, _}, &1)) |> List.last() do
      {_, out} -> out
      nil -> nil
    end
  end

  # ---------------------------------------------------------------- adapter

  defmodule Adapter do
    @moduledoc "Test adapter mapping the qualified_fulfillment capabilities to real steps."
    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S
    alias AshPPlan.Reactor.Durable.Steps.Await

    @impl true
    def id, do: :qf_ledger
    @impl true
    def available?, do: true
    @impl true
    def ops do
      [
        :order_admit,
        :payment_authorize,
        :artifact_write,
        :process_ensureavailable,
        :actuator_command,
        :state_await,
        :order_verifypackage,
        :human_approve,
        :shipment_commit,
        :schedule_deferred,
        :evidence_establish
      ]
    end

    @impl true
    def step(:human_approve, options) do
      {:ok,
       {Await, [signal: "human_release", timeout: nil] ++ Keyword.take(options, [:block_ms])}}
    end

    def step(:actuator_command, options) do
      case Keyword.get(options, :provider) do
        :fulfillment_manual -> {:ok, {S.PickManual, options}}
        _ -> {:ok, {S.PickRobot, options}}
      end
    end

    def step(op, options) do
      table = %{
        order_admit: S.Admit,
        payment_authorize: S.Authorize,
        artifact_write: S.Manifest,
        process_ensureavailable: S.Worker,
        state_await: S.AwaitPick,
        order_verifypackage: S.Verify,
        shipment_commit: S.Commit,
        schedule_deferred: S.Schedule,
        evidence_establish: S.Establish
      }

      case Map.fetch(table, op) do
        {:ok, mod} ->
          {:ok, {mod, options}}

        :error ->
          {:error, %{reason: :unsupported, adapter: :qf_ledger, detail: {:unknown_op, op}}}
      end
    end
  end

  # ------------------------------------------------------------------ steps

  defmodule Steps do
    @moduledoc false

    alias AshPPlan.Examples.QualifiedFulfillment.Steps, as: QF
    alias AshPPlan.Test.Effects

    def count(ctx, effect), do: Effects.record(ctx.effects, effect)

    def out(args, options, outcome, extra \\ %{}) do
      Map.merge(
        %{
          order_id: QF.order_id(args),
          provider: Keyword.get(options, :provider),
          outcome: outcome
        },
        extra
      )
    end

    defmodule Admit do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Steps.AdmitOrder
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S

      @impl true
      def run(args, ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)

        with {:ok, _} <- AdmitOrder.run(%{order_id: id}, %{}, []) do
          S.count(ctx, :admit)
          {:ok, S.out(args, opts, :success)}
        end
      end

      @impl true
      def undo(res, args, c, o), do: AdmitOrder.undo(res, args, c, o)
    end

    defmodule Authorize do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S

      @impl true
      def run(args, ctx, opts) do
        S.count(ctx, :authorize)

        case Req.post(ctx.payment_url <> "/payments/authorize", body: "{}", retry: false) do
          {:ok, %{status: 200}} ->
            {:ok, S.out(args, opts, :authorized)}

          {:ok, %{status: s}} ->
            # `lenient: true` models a defective step that swallows a decline.
            if Keyword.get(opts, :lenient, false),
              do: {:ok, S.out(args, opts, :declined)},
              else: {:error, {:payment_refused, s}}

          {:error, e} ->
            {:error, {:payment_unreachable, e}}
        end
      end
    end

    defmodule Manifest do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S

      @impl true
      def run(args, ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)
        path = Path.join(ctx.dir, "manifest-#{id}.txt")
        File.mkdir_p!(ctx.dir)
        File.write!(path, "order=#{id}\n")
        {:ok, S.out(args, opts, :success, %{path: path})}
      end

      @impl true
      def undo(%{path: path}, _a, _c, _o), do: (File.rm(path) && :ok) || :ok
    end

    defmodule Worker do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S
      alias AshPPlan.Test.FulfillmentWorker

      @impl true
      def run(args, ctx, opts) do
        case FulfillmentWorker.ping(ctx.worker_name) do
          :pong -> {:ok, S.out(args, opts, :available)}
        end
      catch
        :exit, _ -> {:error, :worker_unavailable}
      end
    end

    defmodule PickRobot do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S
      alias AshPPlan.Examples.QualifiedFulfillment.Order
      alias AshPPlan.Test.FulfillmentRobot

      @impl true
      def run(args, ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)
        order = Ash.get!(Order, id)
        item = Keyword.get(opts, :item, order.sku)

        S.count(ctx, :pick_robot)
        reply = FulfillmentRobot.command(ctx.robot, {:pick, item})

        # `double: true` models a defective step that issues the physical command twice.
        if Keyword.get(opts, :double, false) do
          S.count(ctx, :pick_robot)
          FulfillmentRobot.command(ctx.robot, {:pick, item})
        end

        case reply do
          :ok -> {:ok, S.out(args, opts, :accepted, %{item: item})}
          {:error, why} -> {:error, {:pick_rejected, why}}
        end
      end
    end

    defmodule PickManual do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S
      alias AshPPlan.Examples.QualifiedFulfillment.Order
      alias AshPPlan.Test.FulfillmentRobot

      # A human picker: same physical consequence, but a different provider than the plan chose.
      @impl true
      def run(args, ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)
        order = Ash.get!(Order, id)
        S.count(ctx, :pick_manual)

        case FulfillmentRobot.command(ctx.robot, {:pick, order.sku}) do
          :ok -> {:ok, S.out(args, opts, :accepted, %{item: order.sku})}
          {:error, why} -> {:error, {:pick_rejected, why}}
        end
      end
    end

    defmodule AwaitPick do
      @moduledoc false
      use Reactor.Step
      require Ash.Query
      alias AshPPlan.Examples.QualifiedFulfillment.Fulfillment
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S
      alias AshPPlan.Test.FulfillmentRobot

      @impl true
      def run(args, ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)

        case wait(ctx.robot, 200) do
          :packing_station ->
            unless Map.get(ctx, :skip_pack, false) do
              for f <- Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!(),
                  do: Ash.update!(f, %{}, action: :pack)
            end

            {:ok, S.out(args, opts, :completed)}

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
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S
      alias AshPPlan.Examples.QualifiedFulfillment.Steps.VerifyPackage

      @impl true
      def run(args, _ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)

        with {:ok, _} <- VerifyPackage.run(%{order_id: id}, %{}, []),
             do: {:ok, S.out(args, opts, :success)}
      end
    end

    defmodule Commit do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S
      alias AshPPlan.Examples.QualifiedFulfillment.Steps.CommitShipment

      @impl true
      def run(args, ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)

        case Map.get(args, :predecessor_0) do
          :approved -> commit(id, args, ctx, opts)
          other -> {:error, {:release_not_approved, other}}
        end
      end

      defp commit(id, args, ctx, opts) do
        S.count(ctx, :commit)

        if Keyword.get(opts, :persist, true) do
          with {:ok, res} <- CommitShipment.commit(id),
               do: {:ok, S.out(args, opts, :success, %{shipment_id: res.shipment_id})}
        else
          # Defective step: reports success without persisting anything.
          {:ok, S.out(args, opts, :success, %{shipment_id: "self-reported"})}
        end
      end

      @impl true
      def undo(%{shipment_id: sid} = res, args, c, o) when sid != "self-reported",
        do: CommitShipment.undo(res, args, c, o)

      def undo(_res, _args, _c, _o), do: :ok
    end

    defmodule Schedule do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Followup
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S

      @impl true
      def run(args, _ctx, opts) do
        id = AshPPlan.Examples.QualifiedFulfillment.Steps.order_id(args)

        with {:ok, %{record: record}} <- Followup.schedule("order:" <> id),
             do: {:ok, S.out(args, opts, :success, %{record_id: record.id})}
      end
    end

    defmodule Establish do
      @moduledoc false
      use Reactor.Step
      alias AshPPlan.Examples.QualifiedFulfillment.Ledger.Steps, as: S

      @impl true
      def run(args, _ctx, opts), do: {:ok, S.out(args, opts, :success, %{established: true})}
    end
  end
end
