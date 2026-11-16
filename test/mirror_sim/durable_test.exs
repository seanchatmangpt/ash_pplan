defmodule AshPPlan.MirrorSim.DurableWire do
  @moduledoc "Standalone mount of the durable mirror-sim area at /durable (L01 owns the full router)."
  use Plug.Router
  plug(:match)
  plug(:dispatch)
  forward("/durable", to: AshPPlan.MirrorSim.Durable)
end

defmodule AshPPlan.MirrorSim.DurableTest do
  @moduledoc """
  Wire courts for the durable mirror-sim area: a real Bandit listener, real `:httpc` requests,
  real `Engine`/`Store.Ets`/`LeaseMonitor`/`Counterfactual`. Parity: each wire outcome is compared
  with the same call made directly against a private store. No sleeps: deadlines cross by the
  test `Clock` and observables are polled under a monotonic deadline.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.Durable.Host
  alias AshPPlan.Reactor.Durable.{Clock, Counterfactual, Engine, LedgerOCEL, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  @poll_budget_ms 5_000

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    DurableFx.install_adapter!()
    :ok = Host.reset()
    on_exit(fn -> if Process.whereis(Host), do: GenServer.stop(Host) end)

    pid =
      start_supervised!({Bandit, plug: AshPPlan.MirrorSim.DurableWire, port: 0, ip: :loopback})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, base: "http://127.0.0.1:#{port}/durable"}
  end

  # ---- wire helpers ---------------------------------------------------------------------

  defp post(base, path, body \\ %{}), do: request(:post, base <> path, Jason.encode!(body))
  defp get(base, path), do: request(:get, base <> path, nil)

  defp request(:get, url, _) do
    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    {status, decode(resp)}
  end

  defp request(:post, url, body) do
    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), [], ~c"application/json", body},
        [],
        body_format: :binary
      )

    {status, decode(resp)}
  end

  defp decode(resp), do: Jason.decode!(resp)

  defp eventually(fun) do
    deadline = System.monotonic_time(:millisecond) + @poll_budget_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      {:ok, v} ->
        v

      :retry ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("bounded poll exhausted"),
          else: poll(fun, deadline)
    end
  end

  # Direct (no wire) twin: a private store and counter driving the same attrs.
  defp direct do
    {:ok, store} = Ets.start_link()
    name = :"mirror_direct_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: name)
    {store, name}
  end

  defp direct_start({store, fx}, id) do
    {:ok, _} = Engine.start(store, DurableFx.attrs(id, effects: fx))
    store
  end

  # ---- courts ---------------------------------------------------------------------------

  test "surfaces/0 lists real exported functions", %{base: _} do
    for %{module: m, fun: f, arity: a, route: "/durable/" <> _} <-
          AshPPlan.MirrorSim.Durable.surfaces() do
      Code.ensure_loaded!(m)
      assert function_exported?(m, f, a), "#{inspect(m)}.#{f}/#{a} not exported"
    end
  end

  test "start is idempotent by id over the wire", %{base: base} do
    assert {200, %{"run" => %{"id" => "w1", "status" => "pending"}}} =
             post(base, "/runs", %{id: "w1"})

    assert {200, %{"run" => %{"id" => "w1"}}} = post(base, "/runs", %{id: "w1"})
    assert {200, %{"run" => %{"status" => "pending"}}} = get(base, "/runs/w1")
  end

  test "start, park, signal, resume completes with each effect once (parity with direct)", %{
    base: base
  } do
    post(base, "/runs", %{id: "r1"})
    assert {200, %{"outcome" => "parked", "detail" => "waiting"}} = post(base, "/runs/r1/attempt")
    assert {200, %{"counts" => %{"admit" => 1, "authorize" => 1}}} = get(base, "/effects")

    assert {200, %{"delivered" => true}} =
             post(base, "/runs/r1/signal", %{payload: %{released: true}})

    assert {200, %{"runnable" => true}} = get(base, "/runs/r1/runnable")
    assert {200, %{"outcome" => "completed"}} = post(base, "/runs/r1/attempt")

    assert {200, %{"counts" => %{"admit" => 1, "authorize" => 1, "commit" => 1}}} =
             get(base, "/effects")

    # resume idempotency: a terminal run is never re-run
    assert {200, %{"outcome" => "ended"}} = post(base, "/runs/r1/attempt")
    assert {200, %{"counts" => %{"commit" => 1}}} = get(base, "/effects")

    {200, %{"steps" => wire_steps}} = get(base, "/runs/r1/steps")

    {store, fx} = direct()
    direct_start({store, fx}, "r1")
    assert {:parked, :waiting} = Engine.attempt(store, "r1")
    {:ok, _} = Engine.signal(store, "r1", DurableFx.signal_name(), %{released: true})
    assert {:completed, _} = Engine.attempt(store, "r1")
    assert wire_steps == Testing.tape(store, "r1")
    assert Effects.all(fx) == %{admit: 1, authorize: 1, commit: 1}
  end

  test "crash-restart: an abandoned claim blocks until the lease lapses, then resumes once", %{
    base: base
  } do
    post(base, "/runs", %{id: "c1"})

    assert {200, %{"claimed" => true}} =
             post(base, "/runs/c1/claim", %{claimer: "dead-worker", lease_ms: 1_000})

    assert {200, %{"outcome" => "taken"}} = post(base, "/runs/c1/attempt", %{claimer: "w2"})
    assert {200, %{"runnable" => false}} = get(base, "/runs/c1/runnable")
    assert {200, %{"counts" => counts}} = get(base, "/effects")
    assert counts == %{}

    assert {200, %{"now" => _}} = post(base, "/clock/advance", %{ms: 2_000})

    eventually(fn ->
      case get(base, "/runs/c1/runnable") do
        {200, %{"runnable" => true}} -> {:ok, true}
        _ -> :retry
      end
    end)

    assert {200, %{"outcome" => "parked"}} = post(base, "/runs/c1/attempt", %{claimer: "w2"})
    assert {200, %{"counts" => %{"admit" => 1, "authorize" => 1}}} = get(base, "/effects")
    post(base, "/runs/c1/signal", %{})
    assert {200, %{"outcome" => "completed"}} = post(base, "/runs/c1/attempt")
    assert {200, %{"counts" => %{"admit" => 1, "commit" => 1}}} = get(base, "/effects")
  end

  test "cancel rolls back to cancelled; second cancel and bad signal are typed refusals", %{
    base: base
  } do
    post(base, "/runs", %{id: "k1"})
    assert {200, %{"outcome" => "parked"}} = post(base, "/runs/k1/attempt")
    assert {200, %{"run" => %{"status" => "cancelling"}}} = post(base, "/runs/k1/cancel")

    assert {200, %{"outcome" => "rolled_back", "detail" => "cancelled"}} =
             post(base, "/runs/k1/attempt")

    assert {200, %{"run" => %{"status" => "cancelled"}}} = get(base, "/runs/k1")

    assert {422, %{"refused" => true, "broken_term" => "cancel_refused"}} =
             post(base, "/runs/k1/cancel")

    assert {422, %{"refused" => true, "broken_term" => "signal_refused"}} =
             post(base, "/runs/k1/signal", %{})

    assert {422, %{"refused" => true, "broken_term" => "no_such_run"}} =
             get(base, "/runs/nope")

    assert {200, %{"outcome" => "not_found"}} = post(base, "/runs/nope/attempt")
  end

  test "unwind over the wire equals the direct Unwind result", %{base: base} do
    post(base, "/runs", %{id: "u1"})
    post(base, "/runs/u1/attempt")
    {status, wire} = post(base, "/runs/u1/unwind")

    {store, fx} = direct()
    direct_start({store, fx}, "u1")
    Engine.attempt(store, "u1")

    case AshPPlan.Reactor.Durable.Unwind.run(store, "u1", store_module: Ets) do
      {:ok, unresolved} ->
        assert status == 200
        assert wire["unresolved"] == AshPPlan.MirrorSim.Durable.enc(unresolved)

      {:error, _} ->
        assert status == 422
        assert wire["broken_term"] == "unwind_failed"
    end
  end

  test "counterfactual: identity replay is empty and leaves the ledger untouched", %{base: base} do
    post(base, "/runs", %{id: "cf1"})
    post(base, "/runs/cf1/attempt")
    post(base, "/runs/cf1/signal", %{payload: %{released: true}})
    assert {200, %{"outcome" => "completed"}} = post(base, "/runs/cf1/attempt")

    {200, %{"digest" => before}} = get(base, "/runs/cf1/ledger_digest")

    assert {200, %{"replay" => replay}} =
             post(base, "/runs/cf1/counterfactual", %{change: %{}})

    assert replay["empty"] == true
    assert replay["untouched"] == true
    assert replay["tasks_reexecuted"] == []
    assert {200, %{"digest" => ^before}} = get(base, "/runs/cf1/ledger_digest")

    # parity with the direct call
    {store, fx} = direct()
    direct_start({store, fx}, "cf1")
    Engine.attempt(store, "cf1")
    {:ok, _} = Engine.signal(store, "cf1", DurableFx.signal_name(), %{released: true})
    Engine.attempt(store, "cf1")
    {:ok, d} = Counterfactual.replay(store, "cf1", store_module: Ets, change: %{})
    assert d.diff.empty? == replay["empty"]
    assert d.untouched? == replay["untouched"]
  end

  test "counterfactual: substituted output flips the result; bad changes are refused", %{
    base: base
  } do
    post(base, "/runs", %{id: "cf2"})
    post(base, "/runs/cf2/attempt")
    post(base, "/runs/cf2/signal", %{payload: %{released: true}})
    post(base, "/runs/cf2/attempt")

    assert {200, %{"replay" => replay}} =
             post(base, "/runs/cf2/counterfactual", %{
               change: %{outputs: %{authorize_payment: "forced"}}
             })

    assert replay["untouched"] == true
    assert replay["original_status"] == "completed"
    assert replay["result_changed"] == true or replay["empty"] == false

    assert {422, %{"refused" => true, "broken_term" => "invalid_change"}} =
             post(base, "/runs/cf2/counterfactual", %{change: %{bogus_change: 1}})

    assert {422, %{"refused" => true, "broken_term" => "invalid_change"}} =
             post(base, "/runs/cf2/counterfactual", %{
               change: %{outputs: %{no_such_task_zzz_unminted: 1}}
             })

    assert {422, %{"refused" => true, "broken_term" => "run_not_found"}} =
             post(base, "/runs/ghost/counterfactual", %{change: %{}})
  end

  test "ledger OCEL digest over the wire equals the direct digest", %{base: base} do
    post(base, "/runs", %{id: "o1"})
    post(base, "/runs/o1/attempt")

    assert {200, %{"digest" => wire_digest, "bytes" => n}} = get(base, "/runs/o1/ocel")
    assert n > 0
    assert {:ok, ^wire_digest} = LedgerOCEL.digest(Host.store(), "o1", store_module: Ets)
    assert {422, %{"refused" => true}} = get(base, "/runs/missing/ocel")
  end

  test "verifier accepts the spine reactor", %{base: base} do
    post(base, "/runs", %{id: "v1"})
    assert {200, %{"verified" => true}} = get(base, "/runs/v1/verify")
  end

  test "lease monitor: exclusive claim, release on holder death observed by bounded poll", %{
    base: base
  } do
    {200, %{"holder" => a}} = post(base, "/lease/holders")
    {200, %{"holder" => b}} = post(base, "/lease/holders")

    assert {200, %{"ok" => true, "epoch" => 1}} =
             post(base, "/lease/claim", %{run_id: "L1", holder: a})

    assert {422, %{"refused" => true, "broken_term" => "claimed"}} =
             post(base, "/lease/claim", %{run_id: "L1", holder: b})

    assert {200, %{"epoch" => 2}} = post(base, "/lease/heartbeat", %{run_id: "L1", holder: a})

    assert {422, %{"broken_term" => "not_held"}} =
             post(base, "/lease/heartbeat", %{run_id: "L1", holder: b})

    assert {200, %{"killed" => true}} = post(base, "/lease/kill", %{holder: a})

    eventually(fn ->
      case get(base, "/lease/status?run_id=L1") do
        {200, %{"status" => "vacant"}} -> {:ok, true}
        _ -> :retry
      end
    end)

    assert {200, %{"ok" => true}} = post(base, "/lease/claim", %{run_id: "L1", holder: b})
    assert {200, %{"status" => "held"}} = get(base, "/lease/status?run_id=L1")
    assert {200, %{"ok" => true}} = post(base, "/lease/release", %{run_id: "L1", holder: b})
    assert {200, %{"status" => "vacant"}} = get(base, "/lease/status?run_id=L1")

    assert {422, %{"broken_term" => "no_such_holder"}} =
             post(base, "/lease/claim", %{run_id: "L1", holder: "zzz"})
  end

  test "portable: JSON terms round-trip; runtime terms are refused", %{base: base} do
    assert {200, %{"portable" => true, "roundtrip" => true}} =
             post(base, "/portable/check", %{term: %{"a" => [1, 2, 3]}})

    assert {422, %{"refused" => true, "broken_term" => "non_portable_runtime_term"}} =
             post(base, "/portable/check", %{probe: "pid"})

    assert {422, %{"broken_term" => "non_portable_runtime_term"}} =
             post(base, "/portable/check", %{probe: "fun"})
  end

  test "wire hygiene: malformed JSON and unknown routes are typed, never 500", %{base: base} do
    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> "/runs"), [], ~c"application/json", "{not json"},
        [],
        body_format: :binary
      )

    assert status == 422
    assert %{"refused" => true, "broken_term" => "bad_json"} = Jason.decode!(resp)

    assert {404, %{"refused" => true, "broken_term" => "unknown_route"}} =
             get(base, "/nope/at/all")

    assert {422, %{"refused" => true, "broken_term" => "bad_id"}} = post(base, "/runs", %{})

    assert {422, %{"refused" => true, "broken_term" => "bad_ms"}} =
             post(base, "/clock/advance", %{ms: "x"})
  end
end
