defmodule AshPPlan.Pm4.ReceiptsObligationsTest do
  @moduledoc """
  Process-conformance courts (pm4exunit) for ash_pplan receipts, obligations,
  the Reactor telemetry middleware and the A2A facade.

  Chicago style: real Reactor runs, real `:telemetry` handlers, real
  `AshPPlan.execute/5` receipts, real `AshPPlan.Obligation` tickets, real
  Durable Ets store + `AshPPlan.A2A.Facade`. Events are recorded from what
  those collaborators actually did; the only hand-written traces are the
  labelled negative controls fed to `refute_conformance/3`.
  """

  use ExUnit.Case, async: false
  use Pm4ExUnit

  @moduletag :pm4exunit

  alias AshPPlan.A2A.Facade
  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.Obligation
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  # ---------------------------------------------------------------------------
  # 1. Reactor telemetry spans
  # ---------------------------------------------------------------------------

  defmodule StepA do
    use Reactor.Step
    @impl true
    def run(%{n: n}, _context, _options), do: {:ok, n + 1}
  end

  defmodule StepB do
    use Reactor.Step
    @impl true
    def run(%{a: a}, _context, _options), do: {:ok, a * 2}
  end

  defmodule StepC do
    use Reactor.Step
    @impl true
    def run(%{b: b}, _context, _options), do: {:ok, b + 100}
  end

  defmodule ChainReactor do
    use Reactor

    middlewares do
      middleware AshPPlan.Reactor.Middleware.Telemetry
    end

    input :n

    step :a, StepA do
      argument :n, input(:n)
    end

    step :b, StepB do
      argument :a, result(:a)
    end

    step :c, StepC do
      argument :b, result(:b)
    end

    return :c
  end

  @doc false
  def forward_telemetry(event, _measurements, metadata, %{test_pid: pid}) do
    send(pid, {:pm4_tel, List.last(event), Map.get(metadata, :step)})
  end

  defp attach_step_telemetry! do
    id = "pm4-receipts-#{System.unique_integer([:positive])}"

    events =
      for phase <- [:start, :stop, :error, :halt, :retry],
          do: [:ash_pplan, :reactor, :step, phase]

    :ok = :telemetry.attach_many(id, events, &__MODULE__.forward_telemetry/4, %{test_pid: self()})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp drain_telemetry(acc \\ []) do
    receive do
      {:pm4_tel, phase, step} -> drain_telemetry([{phase, step} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "reactor telemetry middleware" do
    test "step spans are [start, stop] pairs in dependency order", %{pm4_session: session} do
      attach_step_telemetry!()

      assert {:ok, 104} = Reactor.run(ChainReactor, %{n: 1}, %{}, async?: false)

      observed = drain_telemetry()
      assert observed != []

      observed
      |> Enum.with_index()
      |> Enum.each(fn {{phase, step}, i} ->
        emit_event(session, "tel-#{i}", :"#{step}_#{phase}")
      end)

      assert_conformance(session, [
        [:a_start, :a_stop, :b_start, :b_stop, :c_start, :c_stop]
      ])
    end

    test "negative control: the real trace does not fit a reversed dependency model",
         %{pm4_session: session} do
      attach_step_telemetry!()
      assert {:ok, 104} = Reactor.run(ChainReactor, %{n: 1}, %{}, async?: false)

      drain_telemetry()
      |> Enum.with_index()
      |> Enum.each(fn {{phase, step}, i} ->
        emit_event(session, "tel-#{i}", :"#{step}_#{phase}")
      end)

      refute_conformance(session, [
        [:c_start, :c_stop, :b_start, :b_stop, :a_start, :a_stop]
      ])
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Execution receipts: effect, then receipt; never for a refused step
  # ---------------------------------------------------------------------------

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @renew "https://w3id.org/ash-pplan#RenewSubscription"

  defmodule AuthorizeStep do
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      Pm4ExUnit.Session.emit_event(arguments.input.session, "fx-authorize", :authorize_effect)
      {:ok, :authorized}
    end
  end

  defmodule RenewStep do
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      Pm4ExUnit.Session.emit_event(arguments.input.session, "fx-renew", :renew_effect)
      {:ok, :renewed}
    end
  end

  describe "execution receipts" do
    test "the receipt is minted after the effects complete", %{pm4_session: session} do
      handlers = %{@authorize => AuthorizeStep, @renew => RenewStep}

      assert {{:ok, _}, %ExecutionReceipt{status: :succeeded}} =
               AshPPlan.execute(@plan, handlers, %{session: session}, %{}, run_id: "pm4-receipt")

      emit_event(session, "receipt-1", :receipt_minted)

      assert_conformance(session, [[:authorize_effect, :renew_effect, :receipt_minted]])

      # negative control: a receipt-before-effect ordering is not the observed order.
      refute_conformance(session, [[:receipt_minted, :authorize_effect, :renew_effect]])
    end

    test "a refused plan runs no effect and mints no receipt", %{pm4_session: session} do
      # only one of the two required handlers: compilation refuses.
      result = AshPPlan.execute(@plan, %{@authorize => AuthorizeStep}, %{session: session})

      assert {:error, %AshPPlan.Compiler.Error{reason: :missing_handlers}} = result
      emit_event(session, "refused-1", :step_refused)

      # the only events are the refusal: no effect, no receipt.
      assert Enum.map(Pm4ExUnit.Session.get_events(session), & &1.activity) == ["step_refused"]
      assert_conformance(session, [[:step_refused]])
      refute_conformance(session, [[:authorize_effect, :renew_effect, :receipt_minted]])
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Obligations: declared -> task executed -> discharged
  # ---------------------------------------------------------------------------

  defp declare(session, run_id) do
    ticket = Obligation.mint(run_id, :send_sms, :dispatch_sms, %{to: "+15550100"})
    emit_event(session, "obl-declared-#{run_id}", :obligation_declared)
    ticket
  end

  defp execute_task(session, run_id) do
    emit_event(session, "task-#{run_id}", :task_executed)
    :ok
  end

  defp discharge(session, run_id, ticket) do
    true = Obligation.verify_digest(ticket)
    emit_event(session, "obl-discharged-#{run_id}", :obligation_discharged)
    :ok
  end

  describe "obligation discharge order" do
    @lawful [[:obligation_declared, :task_executed, :obligation_discharged]]

    test "declared, then executed, then discharged conforms", %{pm4_session: session} do
      ticket = declare(session, "run-ok")
      :ok = execute_task(session, "run-ok")
      :ok = discharge(session, "run-ok", ticket)

      assert_conformance(session, @lawful)
    end

    test "discharge before the task executed is refuted", %{pm4_session: session} do
      # negative control: the same real operations, driven in the unlawful order.
      ticket = declare(session, "run-bad")
      :ok = discharge(session, "run-bad", ticket)
      :ok = execute_task(session, "run-bad")

      refute_conformance(session, @lawful)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. A2A facade status trace
  # ---------------------------------------------------------------------------

  defmodule FacadeEffect do
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule FacadeAdapter do
    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :pm4_receipts_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {FacadeEffect, [effect: :prepare]},
        process_finish: {FacadeEffect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  defp facade_model do
    {:ok, m} =
      AshPPlan.Workflow.Model.new(
        name: "pm4_facade_await",
        goal: "pm4_facade_await",
        tasks: [
          [id: :prepare, capability: "Process.Prepare", depends_on: []],
          [id: :await, capability: "Event.Await", depends_on: [:prepare]],
          [id: :finish, capability: "Process.Finish", depends_on: [:await]]
        ]
      )

    m
  end

  defp facade_bindings(effects) do
    ops = [{:prepare, "Process.Prepare"}, {:await, "Event.Await"}, {:finish, "Process.Finish"}]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :pm4_receipts_fx,
         binding: %{adapter: :pm4_receipts_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  describe "A2A facade status trace" do
    setup do
      previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

      Application.put_env(
        :ash_pplan,
        :extra_adapters,
        Map.put(Map.new(previous), :pm4_receipts_fx, FacadeAdapter)
      )

      on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

      effects = :"pm4_receipts_effects_#{System.unique_integer([:positive])}"
      {:ok, _} = Effects.start_link(name: effects)
      {:ok, store} = Ets.start_link([])
      %{store: store, fx: effects}
    end

    defp observe_state(session, label, {:ok, state, _detail}) do
      emit_event(session, "a2a-#{label}", state)
      state
    end

    defp lifecycle_trace(session, store, fx) do
      key = "pm4-facade-#{System.unique_integer([:positive])}"
      opts = [store: store, store_module: Ets]

      {:ok, _record} =
        Engine.start(
          store,
          %{
            id: key,
            model: facade_model(),
            bindings: facade_bindings(fx),
            inputs: %{input: %{}},
            context: %{}
          },
          store_module: Ets
        )

      states = [
        observe_state(session, "pending", Facade.status(store, key, opts)),
        observe_state(session, "attempt", Facade.attempt(store, key, opts)),
        observe_state(session, "resume", Facade.resume(store, key, %{answer: 1}, opts)),
        observe_state(session, "after-resume", Facade.status(store, key, opts)),
        observe_state(session, "second-resume", Facade.resume(store, key, %{answer: 2}, opts))
      ]

      states
    end

    test "submitted -> input_required -> completed, terminal never regresses",
         %{pm4_session: session, store: store, fx: fx} do
      states = lifecycle_trace(session, store, fx)

      assert states == [:submitted, :input_required, :completed, :completed, :completed]

      assert_conformance(session, [
        [:submitted, :input_required, :completed, :completed, :completed]
      ])

      # absorbing terminal: once completed, every later observation is completed.
      {_before, from_terminal} = Enum.split_while(states, &(&1 != :completed))
      assert Enum.all?(from_terminal, &(&1 == :completed))

      # exactly one prepare and one finish effect across the whole lifecycle.
      assert Effects.count(fx, :prepare) == 1
      assert Effects.count(fx, :finish) == 1
    end

    test "negative control: the real trace does not fit a submitted->working->completed model",
         %{pm4_session: session, store: store, fx: fx} do
      _ = lifecycle_trace(session, store, fx)

      refute_conformance(session, [
        [:submitted, :working, :completed, :completed, :completed]
      ])
    end
  end
end
