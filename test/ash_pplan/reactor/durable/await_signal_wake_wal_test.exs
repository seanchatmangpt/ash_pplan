defmodule AshPPlan.Reactor.Durable.AwaitSignalWakeWalTest do
  @moduledoc """
  Court (fnox v26.11.16 L06, ARD Tier 2 §4 / Tier 4 §2): a durable run parks on
  `Steps.Await` for the signal `"tech_arrived"`, holds NO process while parked, survives a
  store restart (`Store.Wal` closed and reopened from the same file), and is woken by
  `Engine.signal/5` + `Engine.attempt/3` on the reopened store. The payload reaches the next
  step as its `predecessor_0` argument, the completed run yields an `ExecutionReceipt` with
  PROV-O N-Triples, and the `LedgerOCEL` export carries the await (signal-take) checkpoint
  and the terminal `run_ended` event.

  Real collaborators only: real `Engine`, real `Store.Wal` on a tmp file, real Reactor, the
  test `Clock`. The adapter below is a hand-written real `AshPPlan.Reactor.Adapter`
  implementation (counting effect + argument-capturing step), not a mock. No `Process.sleep`:
  the parked run is a row, the restart is a real close/open, and "no process held" is a
  structural check over `Process.list/0` (`$callers` chain), not a timed wait.

  Non-vacuity: a signal with the wrong name does NOT make the parked run runnable (name-matched
  wake law, fnox v26.11.16 S02-M5); a forced attempt re-parks on the same waiter, the downstream
  step does not run, and the wrong-name signal stays stored unconsumed. Only the signal carrying
  the waiter's name wakes it.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Key, LedgerOCEL, Testing, Waiter}
  alias AshPPlan.Reactor.Durable.Steps.Await
  alias AshPPlan.Reactor.Durable.Store.Wal
  alias AshPPlan.Test.Effects
  alias AshPPlan.Workflow.Model
  alias AshPPlan.Workflow.Project

  @signal "tech_arrived"
  @wrong_signal "tech_cancelled"
  @payload %{technician: "tech-17", eta_min: 0, site: "natfac-site-3"}

  # -- real adapter: counting effect + argument-capturing dispatch step --------------------

  defmodule Effect do
    @moduledoc "Counting effect step (real `Effects` agent, referenced by name)."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Dispatch do
    @moduledoc """
    The step after the await: records its run and returns what its predecessor (the await)
    produced, so the checkpoint ledger proves the signal payload was delivered downstream.
    """
    use Reactor.Step

    @impl true
    def run(arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), :dispatch) do
        {:ok, n} -> {:ok, %{received: Map.get(arguments, :predecessor_0), n: n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc "Real adapter: observe -> effect, select -> Await, integrate -> Dispatch."
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :await_wal_fx
    @impl true
    def available?, do: true
    @impl true
    def ops, do: [:work_observe, :work_select, :work_integrate]

    @impl true
    def step(op, options) do
      {wait, options} = Keyword.pop(options, :wait, [])

      table = %{
        work_observe:
          {AshPPlan.Reactor.Durable.AwaitSignalWakeWalTest.Effect, [effect: :observe]},
        work_select: {Await, wait},
        work_integrate: {AshPPlan.Reactor.Durable.AwaitSignalWakeWalTest.Dispatch, []}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- model: linear observe -> gate (await) -> dispatch -----------------------------------

  defp model do
    {:ok, m} =
      Model.new(
        name: :tech_arrival_gate,
        goal: :dispatch_work_order,
        tasks: [
          [id: :observe, capability: "Work.Observe", authority: :observe],
          [id: :gate, capability: "Work.Select", after: [:observe], authority: :observe],
          [id: :dispatch, capability: "Work.Integrate", after: [:gate], authority: :construct]
        ]
      )

    m
  end

  defp attrs(id, fx) do
    model = model()

    bindings =
      Map.new(model.tasks, fn t ->
        op = Realization.op_for(t.capability)

        options =
          case t.id do
            :gate -> [effects: fx, wait: [signal: @signal, timeout: nil]]
            _ -> [effects: fx]
          end

        {t.id,
         %Realization{
           capability: t.capability,
           provider: :await_wal_fx,
           binding: %{adapter: :await_wal_fx, op: op},
           options: options
         }}
      end)

    %{
      id: id,
      model: model,
      bindings: bindings,
      inputs: %{work_order: "wo-4711"},
      context: %{ash_pplan_workflow: %{subject: "sha256:" <> String.duplicate("cd", 32)}},
      parent: nil
    }
  end

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :await_wal_fx, Adapter)
    )

    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
    :ok
  end

  @wal [store_module: Wal]

  setup do
    install_adapter!()
    Clock.use_test_clock(~U[2026-11-16 09:00:00Z])
    on_exit(&Clock.reset/0)

    fx = :"fx_await_wal_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    path =
      Path.join(
        System.tmp_dir!(),
        "await_signal_wake_#{System.unique_integer([:positive])}.wal"
      )

    {:ok, wal} = Wal.open(path)

    # The test may close/reopen the store itself; the exit hook closes whatever is open last.
    # The holder is UNLINKED (`Agent.start/2`): `on_exit` runs after the test process has
    # exited (`:shutdown`), which would have taken a linked holder down with it (gate round 2:
    # `GenServer.call(:wal_holder_N, ...)` -> no process). The hook stops it itself.
    holder = :"wal_holder_#{System.unique_integer([:positive])}"
    {:ok, holder_pid} = Agent.start(fn -> wal end, name: holder)

    on_exit(fn ->
      if Process.alive?(holder_pid) do
        try do
          holder_pid |> Agent.get(& &1) |> safe_close()
        catch
          :exit, _ -> :ok
        end

        try do
          Agent.stop(holder_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm(path)
    end)

    %{wal: wal, path: path, fx: fx, holder: holder}
  end

  defp safe_close(%Wal{} = wal) do
    Wal.close(wal)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Processes alive now whose `$callers` chain includes this test process: Reactor runs
  # steps under its Task.Supervisor with `$callers` set to the caller, so any step task
  # still alive after `Engine.attempt/3` returned would appear here. The store's own
  # writer is started by `Wal.open/1` from this process (ancestor, not caller) and is
  # excluded explicitly so the check is about the RUN, not the store.
  defp processes_held_by_run(%Wal{writer: writer}) do
    me = self()

    Process.list()
    |> Enum.reject(&(&1 == me or &1 == writer))
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> me in Keyword.get(dict, :"$callers", [])
        nil -> false
      end
    end)
  end

  # Standing output of the step named `name` on the Wal store (Testing.recorded/3 reads the
  # app-configured default store, so the Wal variant lives here).
  defp recorded(wal, run_id, name) do
    key = Key.for_name(name)

    case Enum.find(Engine.steps(wal, run_id, @wal), &(&1.step_key == key)) do
      nil -> nil
      cp -> cp.output
    end
  end

  defp gate_iri, do: Project.Reactor.step_iri(model(), :gate)
  defp dispatch_iri, do: Project.Reactor.step_iri(model(), :dispatch)

  test "await parks as a row, survives a Wal restart, wakes on its signal, exports receipt + OCEL",
       %{wal: wal, path: path, fx: fx, holder: holder} do
    run_id = "wo-tech-gate-#{System.unique_integer([:positive])}"
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:microsecond)

    assert {:ok, %{id: ^run_id, status: :pending}} = Engine.start(wal, attrs(run_id, fx), @wal)

    # -- 1. park: the Await halts; the Engine settles the run as :waiting (no poll waiter) --
    assert {:parked, :waiting} = Engine.attempt(wal, run_id, @wal)

    parked = Wal.get_run(wal, run_id)
    assert parked.status == :waiting
    # claim released AFTER the outcome was written (engine law): nothing holds the row
    assert parked.claimed_at == nil and parked.claimed_by == nil and parked.lease_until == nil

    # pinned waiter shape (Await.park/7 -> Store.park/6 with kind :signal, timeout nil)
    assert [%Waiter{run_id: ^run_id, name: @signal, kind: :signal, deadline: nil}] =
             Wal.waiters(wal, run_id)

    # the observe effect ran once; the await step holds no checkpoint yet; dispatch never ran
    assert Effects.count(fx, :observe) == 1
    assert Effects.count(fx, :dispatch) == 0
    assert recorded(wal, run_id, gate_iri()) == nil

    # -- 2. no process is held for the parked run -------------------------------------------
    assert processes_held_by_run(wal) == []
    # and the run is not runnable: level-triggered scheduling has nothing to do until a signal
    refute Engine.runnable?(wal, parked, Clock.now(), @wal)
    refute run_id in Engine.runnable(wal, Clock.now(), @wal)

    # -- 3. non-vacuity: a wrong signal name is stored but is NOT a wake --------------------
    assert {:ok, _} = Engine.signal(wal, run_id, @wrong_signal, %{reason: :noise}, @wal)
    refute Engine.runnable?(wal, Wal.get_run(wal, run_id), Clock.now(), @wal)
    refute run_id in Engine.runnable(wal, Clock.now(), @wal)
    # wake/3 answers :ok (parked, not terminal) and leaves the label honest: still :waiting
    assert :ok = Engine.wake(wal, run_id, @wal)
    assert Wal.get_run(wal, run_id).status == :waiting
    # a forced attempt (attempt/3 is not gated by runnable?) re-parks on the same waiter
    assert {:parked, :waiting} = Engine.attempt(wal, run_id, @wal)
    assert Testing.waiting_on(wal, run_id, @wal) == [@signal]
    assert Effects.count(fx, :dispatch) == 0
    assert recorded(wal, run_id, gate_iri()) == nil
    # the wrong-name signal is still unconsumed (nobody waits on it)
    assert [%{name: @wrong_signal, consumed_at: nil}] = Wal.signals(wal, run_id)

    # -- 4. restart twin: close the store, reopen the WAL from disk ---------------------------
    :ok = Wal.close(wal)
    assert {:ok, %Wal{} = wal2} = Wal.open(path)
    Agent.update(holder, fn _ -> wal2 end)

    rehydrated = Wal.get_run(wal2, run_id)
    assert rehydrated.status == :waiting
    assert rehydrated.claimed_at == nil

    assert [%Waiter{name: @signal, kind: :signal, deadline: nil}] = Wal.waiters(wal2, run_id)
    # the observe checkpoint stands across the restart (replay source), the gate has none
    assert Enum.map(Engine.steps(wal2, run_id, @wal), & &1.label) ==
             [Key.label(Project.Reactor.step_iri(model(), :observe))]

    # -- 5. signal + attempt on the reopened store completes the run --------------------------
    assert {:ok, %{name: @signal, payload: @payload}} =
             Engine.signal(wal2, run_id, @signal, @payload, @wal)

    assert run_id in Engine.runnable(wal2, Clock.now(), @wal)
    assert {:completed, result} = Engine.attempt(wal2, run_id, @wal)

    done = Wal.get_run(wal2, run_id)
    assert done.status == :completed
    assert done.result == result

    # the await checkpoint IS the consumed signal payload (take_signal adopt-or-insert law)
    assert recorded(wal2, run_id, gate_iri()) == @payload

    # payload delivered to the next step as predecessor_0, exactly once, after the restart
    assert %{received: @payload, n: 1} = recorded(wal2, run_id, dispatch_iri())
    assert Effects.count(fx, :dispatch) == 1
    assert Effects.count(fx, :observe) == 1

    # the right signal is consumed, the wrong one still sits unconsumed; waiter released
    sigs = Wal.signals(wal2, run_id)
    assert %{consumed_at: %DateTime{}} = Enum.find(sigs, &(&1.name == @signal))
    assert %{consumed_at: nil} = Enum.find(sigs, &(&1.name == @wrong_signal))
    assert Wal.waiters(wal2, run_id) == []
    assert processes_held_by_run(wal2) == []

    # a terminal run refuses further signals and further attempts end
    assert {:error, {:run_terminal, :completed}} =
             Engine.signal(wal2, run_id, @signal, @payload, @wal)

    assert Engine.attempt(wal2, run_id, @wal) == :ended

    # -- 6. ExecutionReceipt with PROV-O N-Triples over the real outcome ----------------------
    plan_iri = Project.Reactor.plan_iri(model())
    standing = Engine.steps(wal2, run_id, @wal)

    # Checkpoint identity is the step_key (Key.for_name of the step IRI). The `name` meta
    # differs by writer: Checkpointed records the step IRI, while Await's take_signal records
    # the SIGNAL name (`Await.take/5` passes `%{name: signal}`) — pinned here, not assumed.
    assert Enum.find(standing, &(&1.step_key == Key.for_name(gate_iri()))).name == @signal

    assert Enum.find(standing, &(&1.step_key == Key.for_name(dispatch_iri()))).name ==
             dispatch_iri()

    # Step IRIs for correspondsToStep come from the model projection (the source of step
    # identity), filtered to the steps that actually stand in the ledger.
    step_iris =
      model().tasks
      |> Enum.map(&Project.Reactor.step_iri(model(), &1.id))
      |> Enum.filter(fn iri -> Enum.any?(standing, &(&1.step_key == Key.for_name(iri))) end)

    assert gate_iri() in step_iris and dispatch_iri() in step_iris

    receipt =
      ExecutionReceipt.observe(plan_iri, run_id, {:ok, result}, started_at, started_mono,
        corresponds_to_steps: step_iris
      )

    assert receipt.status == :succeeded
    assert :ok = ExecutionReceipt.validate_identity(receipt)
    assert receipt.outcome_digest == ExecutionReceipt.outcome_digest({:ok, result})

    nt = ExecutionReceipt.to_rdf(receipt)
    assert nt =~ "<urn:ash-pplan:receipt:#{run_id}:#{receipt.outcome_digest}>"
    assert nt =~ "<http://www.w3.org/ns/prov#Entity>"
    assert nt =~ "<http://www.w3.org/ns/prov#wasGeneratedBy> <urn:ash-pplan:execution:#{run_id}>"
    assert nt =~ "<http://www.w3.org/ns/prov#used> <#{plan_iri}>"
    assert nt =~ ~s(<https://w3id.org/ash-pplan#executionStatus> "succeeded")
    assert nt =~ "<http://purl.org/net/p-plan#correspondsToStep> <#{gate_iri()}>"
    assert nt =~ "<http://purl.org/net/p-plan#correspondsToStep> <#{dispatch_iri()}>"
    # every line is one N-Triple
    assert nt |> String.split("\n", trim: true) |> Enum.all?(&String.ends_with?(&1, " ."))

    # -- 7. LedgerOCEL export carries the await (signal-take) checkpoint + run_ended ----------
    assert {:ok, events} = LedgerOCEL.events(wal2, run_id, @wal)
    # run_started + observe + gate(await) + dispatch + run_ended
    assert length(events) == 5
    assert [%{activity: "run_started"} | _] = events
    assert %{activity: "run_ended", attributes: %{status: "completed"}} = List.last(events)

    await_event =
      Enum.find(events, &(&1.activity == "task_succeeded" and &1.attributes.task =~ "#step-gate"))

    assert await_event, "no task_succeeded event for the await step in #{inspect(events)}"
    assert await_event.attributes.undone == false

    assert await_event.attributes.output_digest ==
             AshPPlan.Digest.hash(:erlang.term_to_binary(@payload)) |> AshPPlan.Digest.hex()

    assert Enum.any?(
             events,
             &(&1.activity == "task_succeeded" and &1.attributes.task =~ "#step-dispatch")
           )

    for e <- events, do: assert(e.subject_id == "sha256:" <> String.duplicate("cd", 32))

    assert {:ok, json} = LedgerOCEL.export(wal2, run_id, @wal)
    assert json =~ "\"events\"" and json =~ "#step-gate" and json =~ "run_ended"

    # -- 8. the completed ledger is durable: a second reopen reads the same standing --------
    :ok = Wal.close(wal2)
    assert {:ok, %Wal{} = wal3} = Wal.open(path)
    Agent.update(holder, fn _ -> wal3 end)
    assert Wal.get_run(wal3, run_id).status == :completed
    assert recorded(wal3, run_id, gate_iri()) == @payload
    assert {:ok, events3} = LedgerOCEL.events(wal3, run_id, @wal)
    assert Enum.map(events3, &{&1.id, &1.activity}) == Enum.map(events, &{&1.id, &1.activity})
  end

  test "wrong signal name is stored but never makes the run runnable across a restart; the right name wakes it (non-vacuity)",
       %{wal: wal, path: path, fx: fx, holder: holder} do
    run_id = "wo-tech-gate-wrong-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Engine.start(wal, attrs(run_id, fx), @wal)
    assert {:parked, :waiting} = Engine.attempt(wal, run_id, @wal)

    :ok = Wal.close(wal)
    assert {:ok, %Wal{} = wal2} = Wal.open(path)
    Agent.update(holder, fn _ -> wal2 end)

    # Name-matched wake law (S02-M5): a wrong-name unconsumed signal is NOT a wake. The run is
    # not runnable, so a scheduler draining `Engine.runnable/3` never spins on it.
    assert {:ok, _} = Engine.signal(wal2, run_id, @wrong_signal, @payload, @wal)
    refute Engine.runnable?(wal2, Wal.get_run(wal2, run_id), Clock.now(), @wal)
    refute run_id in Engine.runnable(wal2, Clock.now(), @wal)
    assert :ok = Engine.wake(wal2, run_id, @wal)
    assert Wal.get_run(wal2, run_id).status == :waiting

    # A forced attempt (attempt/3 is not gated by runnable?) re-parks on the same waiter; the
    # wrong-name signal is left stored, unconsumed, for a later waiter of that name.
    assert {:parked, :waiting} = Engine.attempt(wal2, run_id, @wal)
    assert Wal.get_run(wal2, run_id).status == :waiting
    assert Testing.waiting_on(wal2, run_id, @wal) == [@signal]
    assert [%{name: @wrong_signal, consumed_at: nil}] = Wal.signals(wal2, run_id)
    assert recorded(wal2, run_id, gate_iri()) == nil
    assert recorded(wal2, run_id, dispatch_iri()) == nil
    assert Effects.count(fx, :dispatch) == 0
    assert Effects.count(fx, :observe) == 1
    assert processes_held_by_run(wal2) == []
    refute run_id in Engine.runnable(wal2, Clock.now(), @wal)

    # no run_ended event while parked
    assert {:ok, events} = LedgerOCEL.events(wal2, run_id, @wal)
    refute Enum.any?(events, &(&1.activity == "run_ended"))
    refute Enum.any?(events, &(&1.attributes[:task] && &1.attributes.task =~ "#step-gate"))

    # The not-runnable state survives a second restart (the law reads rows, not memory).
    :ok = Wal.close(wal2)
    assert {:ok, %Wal{} = wal3} = Wal.open(path)
    Agent.update(holder, fn _ -> wal3 end)
    refute run_id in Engine.runnable(wal3, Clock.now(), @wal)
    assert [%{name: @wrong_signal, consumed_at: nil}] = Wal.signals(wal3, run_id)

    # Only the signal carrying the waiter's name wakes the run; the wrong one stays stored.
    assert {:ok, _} = Engine.signal(wal3, run_id, @signal, @payload, @wal)
    assert Engine.runnable?(wal3, Wal.get_run(wal3, run_id), Clock.now(), @wal)
    assert run_id in Engine.runnable(wal3, Clock.now(), @wal)
    assert :ok = Engine.wake(wal3, run_id, @wal)
    assert Wal.get_run(wal3, run_id).status == :pending
    assert {:completed, _} = Engine.attempt(wal3, run_id, @wal)
    assert recorded(wal3, run_id, gate_iri()) == @payload
    assert Effects.count(fx, :dispatch) == 1
    sigs = Wal.signals(wal3, run_id)
    assert %{consumed_at: %DateTime{}} = Enum.find(sigs, &(&1.name == @signal))
    assert %{consumed_at: nil} = Enum.find(sigs, &(&1.name == @wrong_signal))
    assert Wal.waiters(wal3, run_id) == []
  end
end
