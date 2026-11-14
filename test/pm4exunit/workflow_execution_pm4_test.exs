defmodule AshPPlan.Pm4ExUnit.WorkflowExecutionTest do
  @moduledoc """
  Process-conformance court for workflow execution. Every activity is read from the ordered
  log written by real Reactor steps running inside the real durable `Engine` (run, undo) plus
  the real return of `Engine.cancel/3`; nothing is synthesised. The log is replayed into the
  pm4exunit session with the timestamps the steps captured when they ran.
  """
  use ExUnit.Case, async: false
  use Pm4ExUnit

  @moduletag :pm4exunit

  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Model

  @log :pm4_wf_log

  defmodule Step do
    @moduledoc false
    use Reactor.Step

    defp record(opts, kind) do
      id = Keyword.fetch!(opts, :task)
      act = String.to_atom("#{kind}_#{id}")
      Agent.update(Keyword.fetch!(opts, :log), &[{act, DateTime.utc_now()} | &1])
    end

    @impl true
    def run(_args, _ctx, opts) do
      record(opts, :run)
      if opts[:fail], do: {:error, :boom}, else: {:ok, Keyword.fetch!(opts, :task)}
    end

    @impl true
    def undo(_value, _args, _ctx, opts) do
      record(opts, :undo)
      :ok
    end
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter
    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :pm4_wf
    @impl true
    def available?, do: true
    @impl true
    def ops, do: [:file_write, :human_approve]

    @impl true
    def step(op, options) do
      table = %{
        file_write: {Step, []},
        human_approve: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  setup do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})
    Application.put_env(:ash_pplan, :extra_adapters, Map.put(Map.new(previous), :pm4_wf, Adapter))
    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

    Clock.use_test_clock()
    on_exit(&Clock.reset/0)

    {:ok, _} = Agent.start_link(fn -> [] end, name: @log)
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  # tasks: [{id, op, extra_opts}] chained in order via after:
  defp attrs(id, tasks) do
    specs =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {{tid, _op, _o}, i} ->
        base = [id: tid, capability: "File.Write", authority: :construct]
        if i == 0, do: base, else: base ++ [after: [elem(Enum.at(tasks, i - 1), 0)]]
      end)

    {:ok, model} = Model.new(name: "pm4-#{id}", goal: "g", tasks: specs)

    bindings =
      Map.new(tasks, fn {tid, op, extra} ->
        {tid,
         %Realization{
           capability: "File.Write",
           provider: :pm4_wf,
           binding: %{adapter: :pm4_wf, op: op},
           options: [log: @log, task: tid] ++ extra
         }}
      end)

    %{id: id, model: model, bindings: bindings, inputs: %{input: %{}}, context: %{}, parent: nil}
  end

  defp chain(id, extra),
    do:
      attrs(
        id,
        [{:a, :file_write, []}, {:b, :file_write, []}, {:c, :file_write, []}] ++ extra
      )

  defp events, do: @log |> Agent.get(& &1) |> Enum.reverse()

  defp note(activity), do: Agent.update(@log, &[{activity, DateTime.utc_now()} | &1])

  defp replay(session) do
    events()
    |> Enum.with_index()
    |> Enum.each(fn {{act, ts}, i} -> emit_event(session, "e#{i}", act, timestamp: ts) end)
  end

  # Declared DAG order from the model's depends_on edges (a chain here, so one topo order).
  defp declared_order(model) do
    ids = Enum.map(model.tasks, & &1.id)
    deps = Map.new(model.tasks, &{&1.id, &1.depends_on})

    Enum.reduce(ids, [], fn _, acc ->
      next = Enum.find(ids, &(&1 not in acc and Enum.all?(deps[&1], fn d -> d in acc end)))
      acc ++ [next]
    end)
  end

  test "completed run: task activities follow the declared DAG; wrong order is refuted",
       %{pm4_session: session, store: s} do
    at = chain("ok1", [])
    {:ok, _} = Engine.start(s, at)
    assert {:completed, _} = Engine.attempt(s, "ok1")
    assert Testing.status(s, "ok1") == :completed

    declared = Enum.map(declared_order(at.model), &:"run_#{&1}")
    assert declared == [:run_a, :run_b, :run_c]

    replay(session)
    assert_conformance(session, [declared])
    refute_conformance(session, [Enum.reverse(declared)])
    refute_conformance(session, [[:run_a, :run_c, :run_b]])
  end

  test "SLA between first and last task of a completed run", %{pm4_session: session, store: s} do
    {:ok, _} = Engine.start(s, chain("sla1", []))
    assert {:completed, _} = Engine.attempt(s, "sla1")

    replay(session)
    assert_sla(session, :run_a, :run_c, max_seconds: 30)
  end

  test "failed task: compensation of finished steps comes after the failure, never before",
       %{pm4_session: session, store: s} do
    {:ok, _} = Engine.start(s, chain("f1", [{:boom, :file_write, [fail: true]}]))
    assert {:failed, _} = Engine.attempt(s, "f1")
    assert Testing.status(s, "f1") == :failed

    acts = Enum.map(events(), &elem(&1, 0))
    boom = Enum.find_index(acts, &(&1 == :run_boom))
    assert boom
    undo_idx = for {a, i} <- Enum.with_index(acts), String.starts_with?("#{a}", "undo_"), do: i
    assert undo_idx != []
    assert Enum.all?(undo_idx, &(&1 > boom))

    for t <- [:a, :b, :c] do
      assert Enum.find_index(acts, &(&1 == :"run_#{t}")) <
               Enum.find_index(acts, &(&1 == :"undo_#{t}"))
    end

    # the failed step itself produced no value, so it is never compensated
    refute :undo_boom in acts

    replay(session)

    # each finished step runs in DAG order and is taken back exactly once after the failure;
    # Reactor owns the rollback order, so conformance allows any of the unwind permutations
    perms = for p <- permutations([:undo_a, :undo_b, :undo_c]), do: [:run_a, :run_b, :run_c, :run_boom] ++ p
    assert_conformance(session, perms)
    refute_conformance(session, [[:undo_a, :run_a, :run_b, :run_c, :run_boom, :undo_b, :undo_c]])
  end

  test "cancel of a parked run: unwind newest first, strictly after the cancel request",
       %{pm4_session: session, store: s} do
    {:ok, _} = Engine.start(s, attrs("c1", [{:a, :file_write, []}, {:b, :file_write, []}, {:wait, :human_approve, []}]))
    assert {:parked, _} = Engine.attempt(s, "c1")

    assert {:ok, %{status: :cancelling}} = Engine.cancel(s, "c1")
    note(:cancel_requested)
    assert {:rolled_back, :cancelled} = Engine.attempt(s, "c1")
    assert Testing.status(s, "c1") == :cancelled

    replay(session)
    assert_conformance(session, [[:run_a, :run_b, :cancel_requested, :undo_b, :undo_a]])
    refute_conformance(session, [[:run_a, :run_b, :undo_b, :undo_a, :cancel_requested]])
    refute_conformance(session, [[:run_a, :run_b, :cancel_requested, :undo_a, :undo_b]])
    assert_sla(session, :cancel_requested, :undo_a, max_seconds: 30)
  end

  defp permutations([]), do: [[]]
  defp permutations(l), do: for(x <- l, rest <- permutations(l -- [x]), do: [x | rest])
end
