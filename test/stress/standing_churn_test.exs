defmodule AshPPlan.Standing.ChurnStressTest do
  @moduledoc """
  STRESS lane: churn the standing surface (`AshPPlan.Standing.receipt/2`, `ladder/2`,
  `verdicts/1`) under concurrency — no mocks, the pure standing functions are the real
  collaborators and the race window itself is the subject.

  Topology (10 processes, one ExUnit test):

    * 8 churn processes x 500 iterations each: build a randomized (per-process seeded)
      run (events/model/selection/gates/execution/consequence/observation), compute
      `receipt/2`, `ladder/2`, and a fixed-input determinism re-check.
    * 1 appender process: concurrently appends events to a shared public ETS event
      stream that churn processes snapshot from, so receipts are computed over inputs
      that are mutating mid-flight.
    * 1 verdicts process: concurrently calls `Standing.verdicts/1` on both randomized
      runs and the live (mid-append) run map.

  Courts:
    1. receipt determinism: for a fixed run, two `receipt/2` calls return byte-identical
       maps (`:erlang.term_to_binary` equality).
    2. no crash under concurrent append: every `receipt/2`, `ladder/2`, `verdicts/1` call
       either returns a value or a `{:error, map}` / `{:error, term}` — any raise is a
       failure (typed errors only).
    3. the ladder never emits a skipped rung: every trail is a contiguous single-rung
       chain from `UNKNOWN`, ending at the reported state, with non-empty evidence.
  """

  use ExUnit.Case, async: false

  @moduletag :stress

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Standing

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @iters 500
  @churn 8

  @model %{
    tasks: [
      %{id: :admit, depends_on: []},
      %{id: :pay, depends_on: [:admit]},
      %{id: :ship, depends_on: [:pay]}
    ]
  }

  # ---- shared event stream (real append surface) ----

  defp next_seq(seq_agent) do
    Agent.get_and_update(seq_agent, fn n -> {n + 1, n + 1} end, 30_000)
  end

  defp append_event(table, subject, task, seq, provider, outcome) do
    ev = %Event{
      id: "run:live/#{task}/#{seq}",
      activity: "task_succeeded",
      timestamp: DateTime.utc_now(),
      objects: [{"WorkflowRun", "run:live", "run"}],
      attributes: %{task: task, seq: seq, provider: provider, outcome: outcome},
      subject_id: subject
    }

    true = :ets.insert(table, {:ev, seq, ev})
    ev
  end

  defp snapshot(table) do
    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_, seq, _} -> seq end)
    |> Enum.map(fn {_, _, ev} -> ev end)
  end

  # ---- deterministic randomized run builder (own seed per process) ----

  defp random_run(seed, subject) do
    :rand.seed(:exsss, {seed, seed, seed})
    pay_outcome = Enum.random(["authorized", "declined"])

    events = [
      ev(subject, "admit", 1, "p1", nil),
      ev(subject, "pay", 2, "p2", pay_outcome),
      ev(subject, "ship", 3, "p3")
    ]

    # Run shape varies across the legal input space: whether each evidence layer
    # passes, whether observation/repo/SHAs are present, gates present or not.
    execution =
      case Enum.random([:ok, :drift]) do
        :ok -> {%{pay: 1}, %{pay: 1}}
        :drift -> {%{pay: 2}, %{pay: 1}}
      end

    consequence =
      case Enum.random([:ok, :fail]) do
        :ok -> [order_fulfilled: true, one_shipment: true]
        :fail -> [order_fulfilled: Enum.random([true, false]), one_shipment: true]
      end

    %{
      run_id: "r-#{subject}",
      repo: if(Enum.random([true, false]), do: "ash_pplan", else: nil),
      head: if(Enum.random([true, false]), do: @head, else: nil),
      base: @base,
      events: events,
      model: @model,
      selection: %{admit: :p1, pay: :p2, ship: :p3},
      fond_gates:
        case Enum.random([:gates, :none]) do
          :gates -> [%{task: "pay", admit: ["authorized", "declined"], successors: ["ship"]}]
          :none -> []
        end,
      execution: execution,
      consequence: consequence,
      observation:
        case Enum.random([:present, :absent]) do
          :present -> %{shipments: Enum.random(0..3)}
          :absent -> %{}
        end
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp ev(subject, task, seq, provider, outcome \\ nil) do
    %Event{
      id: "run:#{subject}/#{task}",
      activity: "task_succeeded",
      timestamp: ~U[2026-10-01 00:00:00Z],
      objects: [{"WorkflowRun", "run:#{subject}", "run"}],
      attributes: %{task: task, seq: seq, provider: provider, outcome: outcome},
      subject_id: subject
    }
  end

  # ---- typed-error wrapper: a raise is a crash, anything else is admissible ----

  defp typed(fun) do
    fun.()
  catch
    :exit, reason -> {:typed_exit, reason}
    class, reason -> {:typed_error, class, reason}
  end

  # ---- the churn workers ----

  defp fault(results, term), do: Agent.get_and_update(results, fn l -> {:ok, [term | l]} end)

  defp churn_loop(table, _seq_agent, seed, subject, results) do
    for i <- 1..@iters do
      run = random_run(seed + i, subject)
      fixed = Map.put(run, :events, run.events) |> Map.put(:repo, "ash_pplan")

      # Court 1: receipt determinism for fixed inputs.
      r1 = typed(fn -> Standing.receipt(fixed, replay_commands: replay_cmds()) end)
      r2 = typed(fn -> Standing.receipt(fixed, replay_commands: replay_cmds()) end)

      case {r1, r2} do
        {{:ok, a}, {:ok, b}} ->
          if :erlang.term_to_binary(a) != :erlang.term_to_binary(b) do
            fault(results, {:nondeterministic_receipt, subject, i})
          end

        {{:error, _}, {:error, _}} ->
          :ok

        _ ->
          fault(results, {:receipt_flip, subject, i, elem(r1, 0), elem(r2, 0)})
      end

      # Court 2: typed errors only, over both stable and live (mid-append) inputs.
      _ = typed(fn -> Standing.receipt(run, replay_commands: replay_cmds()) end)

      live_run = %{
        run_id: "live",
        events: Enum.take(snapshot(table), -50),
        model: @model,
        selection: %{admit: :p1, pay: :p2, ship: :p3},
        execution: {%{pay: 1}, %{pay: 1}},
        consequence: [order_fulfilled: true]
      }

      _ = typed(fn -> Standing.receipt(live_run, replay_commands: replay_cmds()) end)

      # Court 3: no skipped rungs under churn.
      case typed(fn -> Standing.ladder(run, []) end) do
        {:ok, %{state: state, trail: trail}} -> assert_trail!(trail, state, subject, i, results)
        {:error, %{broken_term: _}} -> :ok
        {:error, term} when is_atom(term) -> :ok
        other -> fault(results, {:bad_ladder_shape, subject, i, other})
      end

      _ = typed(fn -> Standing.ladder(live_run, []) end)
    end

    :ok
  end

  defp assert_trail!(trail, state, subject, i, results) do
    last_to =
      Enum.reduce_while(Enum.with_index(trail, 1), :UNKNOWN, fn {step, order}, acc ->
        cond do
          step.order != order or step.from != acc or step.to == acc or
            not is_binary(step.evidence) or step.evidence == "" ->
            {:halt, :bad}

          true ->
            {:cont, step.to}
        end
      end)

    last_state = if trail == [], do: :UNKNOWN, else: List.last(trail).to

    if last_to == :bad or last_state != state do
      fault(results, {:skipped_rung, subject, i, state, trail})
    end
  end

  defp replay_cmds,
    do: [%{cmd: "mix test test/stress/standing_churn_test.exs", cwd: File.cwd!(), exit: 0}]

  # ---- the two support processes ----

  defp appender_loop(_table, _seq, 0), do: :ok

  defp appender_loop(table, seq_agent, n) do
    task = Enum.random(["admit", "pay", "ship"])
    provider = Enum.random(["p1", "p2", "p3"])
    outcome = Enum.random([nil, "authorized", "declined"])
    append_event(table, "live-subject", task, next_seq(seq_agent), provider, outcome)
    appender_loop(table, seq_agent, n - 1)
  end

  defp verdicts_loop(_table, 0), do: :ok

  defp verdicts_loop(table, n) do
    run = %{
      run_id: "live",
      events: Enum.take(snapshot(table), -50),
      model: @model,
      selection: %{admit: :p1, pay: :p2, ship: :p3},
      execution: {%{pay: 1}, %{pay: 1}},
      consequence: [order_fulfilled: true]
    }

    _ = typed(fn -> Standing.verdicts(run) end)
    _ = typed(fn -> Standing.verdicts(%{}) end)
    verdicts_loop(table, n - 1)
  end

  # ---- the court ----

  @tag :stress
  @tag timeout: 600_000
  test "standing churn: 8x500 receipts+ladders under concurrent append and verdicts" do
    table = :ets.new(:standing_churn_events, [:public, :bag, write_concurrency: true])
    {:ok, seq_agent} = Agent.start_link(fn -> 0 end)
    {:ok, results} = Agent.start_link(fn -> [] end)

    workers =
      for w <- 1..@churn do
        Task.async(fn ->
          churn_loop(table, seq_agent, :erlang.phash2({self(), w}) + w * 1_000_000, "subject-#{w}", results)
        end)
      end

    appender = Task.async(fn -> appender_loop(table, seq_agent, 4_000) end)
    verdicts = Task.async(fn -> verdicts_loop(table, 4_000) end)

    Task.await_many(workers ++ [appender, verdicts], 590_000)

    faults = Agent.get(results, & &1)
    Agent.stop(results)
    :ets.delete(table)

    assert faults == [],
           "standing churn court found #{length(faults)} faults: " <>
             inspect(Enum.take(faults, 10), limit: 20, pretty: true)

    seq = Agent.get(seq_agent, & &1)
    Agent.stop(seq_agent)
    IO.puts("[standing_churn] OK: #{@churn}x#{@iters} receipts+ladders, " <> "#{seq} appended events, 0 faults")
  end
end
