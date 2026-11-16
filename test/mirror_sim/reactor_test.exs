defmodule AshPPlan.MirrorSim.ReactorTest.Upstream do
  @moduledoc false
  # Real local upstream for the reactor_req courts (served by a real Bandit listener).
  use Plug.Router
  import Plug.Conn

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  get "/boom" do
    reply(conn, 500, %{"error" => "boom"})
  end

  match "/echo" do
    reply(conn, 200, %{"method" => conn.method, "body" => conn.body_params})
  end

  match _ do
    reply(conn, 404, %{"error" => "not_found"})
  end

  defp reply(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end
end

defmodule AshPPlan.MirrorSim.ReactorTest do
  @moduledoc """
  Wire courts for the reactor area of the mirror sim: real Reactors run through the real
  adapters/steps/middleware behind a real Bandit listener, plus a real local Bandit upstream
  for `reactor_req`. Asserts final outcomes and evidence, and sim-vs-direct parity.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.ReactorTest.Upstream
  alias AshPPlan.ReactorOutcome
  alias AshPPlan.Workflow.{Model, Subject}

  setup do
    sim =
      start_supervised!(
        {Bandit, plug: AshPPlan.MirrorSim.Reactor, port: 0, ip: :loopback, startup_log: false},
        id: :sim
      )

    up =
      start_supervised!({Bandit, plug: Upstream, port: 0, ip: :loopback, startup_log: false},
        id: :upstream
      )

    {:ok, sim: url(sim), upstream: url(up)}
  end

  defp url(pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp post(base, path, body), do: Req.post!(base <> path, json: body, retry: false)
  defp get(base, path), do: Req.get!(base <> path, retry: false)

  defp refused?(resp, term) do
    assert resp.status == 422
    assert %{"refused" => true, "broken_term" => ^term} = resp.body
    resp.body["reason"]
  end

  defp realization(adapter, op) do
    %AshPPlan.Realization{
      capability: "x",
      provider: "x",
      binding: %{adapter: adapter, op: op},
      options: []
    }
  end

  defp all_adapters do
    Map.put_new(
      AshPPlan.Reactor.adapters(),
      :ash_reactor_extended,
      AshPPlan.Reactor.Adapters.AshReactorExtended
    )
  end

  # ------------------------------------------------------------ adapters / step_for

  test "GET /adapters mirrors the adapter table", %{sim: sim} do
    resp = get(sim, "/adapters")
    assert resp.status == 200

    wire = Map.new(resp.body["adapters"], &{&1["id"], &1})
    direct = AshPPlan.Reactor.adapters()

    assert Map.keys(wire) |> Enum.sort() ==
             direct |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    for {id, mod} <- direct do
      row = wire[Atom.to_string(id)]
      assert row["module"] == inspect(mod)
      assert row["available"] == mod.available?()
      assert row["ops"] == mod.ops() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end
  end

  test "step_for parity: every adapter op over the wire equals the direct call", %{sim: sim} do
    adapters = all_adapters()

    for {id, mod} <- adapters, op <- mod.ops() do
      resp =
        post(sim, "/step_for", %{"adapter" => Atom.to_string(id), "op" => Atom.to_string(op)})

      case AshPPlan.Reactor.step_for(realization(id, op), adapters: adapters) do
        {:ok, {m, kw}} ->
          assert resp.status == 200, "#{id}/#{op}: #{inspect(resp.body)}"
          assert resp.body["module"] == inspect(m)

          assert resp.body["options"] |> Map.keys() |> Enum.sort() ==
                   kw |> Keyword.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

        {:error, err} ->
          assert resp.status == 422
          assert resp.body["broken_term"] == to_string(err.reason)
      end
    end
  end

  test "step_for resolves concrete implementations per adapter", %{sim: sim} do
    expect = [
      {"reactor_file", "file_write", "Reactor.File.Step.WriteFile"},
      {"reactor_file", "file_read", "Reactor.File.Step.ReadFile"},
      {"reactor_file", "file_copy", "Reactor.File.Step.Cp"},
      {"reactor_file", "file_delete", "Reactor.File.Step.Rm"},
      {"reactor_file", "file_mkdir", "Reactor.File.Step.MkdirP"},
      {"reactor_req", "network_get", "Reactor.Req.Step"},
      {"reactor_process", "process_start", "Reactor.Process.Step.StartChild"},
      {"bb_reactor", "actuator_command", "BB.Reactor.Step.Command"},
      {"ash_reactor", "domain_create", "AshPPlan.Reactor.Steps.DomainAction"},
      {"local", "actuation_command", "AshPPlan.Reactor.Steps.Command"},
      {"local", "distributed_propose", "AshPPlan.Reactor.Steps.Propose"}
    ]

    for {adapter, op, module} <- expect do
      resp = post(sim, "/step_for", %{"adapter" => adapter, "op" => op})
      assert resp.status == 200, "#{adapter}/#{op}: #{inspect(resp.body)}"
      assert resp.body["module"] == module
    end

    get_resp = post(sim, "/step_for", %{"adapter" => "reactor_req", "op" => "network_get"})
    assert get_resp.body["options"]["fun"] == "get"
    dom = post(sim, "/step_for", %{"adapter" => "ash_reactor", "op" => "domain_destroy"})
    assert dom.body["options"]["kind"] == "destroy"
  end

  test "step_for typed refusals: unavailable, unknown op, unknown adapter", %{sim: sim} do
    reason =
      post(sim, "/step_for", %{
        "adapter" => "reactor_file",
        "op" => "file_write",
        "available?" => false
      })
      |> refused?("unsupported")

    assert reason =~ "implementation_unavailable"

    reason =
      post(sim, "/step_for", %{"adapter" => "reactor_file", "op" => "no_such_op"})
      |> refused?("unsupported")

    assert reason =~ "unknown_op"

    reason =
      post(sim, "/step_for", %{"adapter" => "no_such_adapter", "op" => "file_write"})
      |> refused?("unsupported")

    assert reason =~ "unknown_adapter"

    # anti-vacuity: the same call flips to ok when availability is forced true
    ok =
      post(sim, "/step_for", %{
        "adapter" => "reactor_file",
        "op" => "file_write",
        "available?" => true
      })

    assert ok.status == 200
  end

  test "malformed JSON and non-object bodies are typed refusals, never 500", %{sim: sim} do
    bad =
      Req.post!(sim <> "/step_for",
        body: "{not json",
        headers: [{"content-type", "application/json"}],
        retry: false
      )

    assert refused?(bad, "malformed_json")

    arr =
      Req.post!(sim <> "/step_for",
        body: "[1,2]",
        headers: [{"content-type", "application/json"}],
        retry: false
      )

    assert refused?(arr, "invalid_body")

    unknown = get(sim, "/nope")
    assert unknown.status == 404
    assert unknown.body["broken_term"] == "unknown_route"
  end

  # ------------------------------------------------------------ reactor_file

  test "reactor_file: mkdir -> write -> read -> copy -> rm run for real on disk", %{sim: sim} do
    content = "mirror-sim payload #{System.unique_integer([:positive])}"
    resp = post(sim, "/run/file", %{"content" => content})

    assert resp.status == 200, inspect(resp.body)
    assert resp.body["state"] == "succeeded"
    assert resp.body["value"]["read"] == content
    assert resp.body["value"]["written"] == %{"changed" => true}
    assert resp.body["value"]["removed"] == %{"changed" => true}
    # final state on disk: source stays, the copy was removed by the rm step
    assert resp.body["source_exists"] == true
    assert resp.body["source_content"] == content
    assert resp.body["copy_exists"] == false
  end

  test "reactor_file: invalid content refused; reading an absent file is a failed outcome", %{
    sim: sim
  } do
    assert post(sim, "/run/file", %{"content" => 5}) |> refused?("invalid_content")

    resp = post(sim, "/run/file_missing", %{})
    assert resp.status == 200
    assert resp.body["state"] == "failed"
    assert resp.body["reason"] not in [nil, "", %{}]
  end

  # ------------------------------------------------------------ reactor_req over a real upstream

  test "reactor_req: every verb reaches the real upstream and returns its response", %{
    sim: sim,
    upstream: up
  } do
    for verb <- ["get", "remote_read"] do
      resp = post(sim, "/run/req", %{"url" => up <> "/echo", "method" => verb})
      assert resp.status == 200
      assert resp.body["state"] == "succeeded"
      assert resp.body["status"] == 200
      assert resp.body["body"]["method"] == "GET"
      assert resp.body["content_type"] =~ "application/json"
    end

    for {verb, upper} <- [{"post", "POST"}, {"put", "PUT"}, {"patch", "PATCH"}] do
      resp =
        post(sim, "/run/req", %{
          "url" => up <> "/echo",
          "method" => verb,
          "json" => %{"k" => verb}
        })

      assert resp.body["status"] == 200
      assert resp.body["body"]["method"] == upper
      assert resp.body["body"]["body"] == %{"k" => verb}
    end

    del = post(sim, "/run/req", %{"url" => up <> "/echo", "method" => "delete"})
    assert del.body["body"]["method"] == "DELETE"

    head = post(sim, "/run/req", %{"url" => up <> "/echo", "method" => "head"})
    assert head.body["state"] == "succeeded"
    assert head.body["status"] == 200
  end

  test "reactor_req: upstream 500 is a succeeded step with status 500; dead port fails", %{
    sim: sim,
    upstream: up
  } do
    boom = post(sim, "/run/req", %{"url" => up <> "/boom", "method" => "get"})
    assert boom.body["state"] == "succeeded"
    assert boom.body["status"] == 500
    assert boom.body["body"] == %{"error" => "boom"}

    dead = post(sim, "/run/req", %{"url" => "http://127.0.0.1:1/echo", "method" => "get"})
    assert dead.status == 200
    assert dead.body["state"] == "failed"
  end

  test "reactor_req: non-loopback urls and unknown verbs are refused", %{sim: sim} do
    assert post(sim, "/run/req", %{"url" => "http://example.com/", "method" => "get"})
           |> refused?("non_loopback_url")

    assert post(sim, "/run/req", %{"url" => "http://127.0.0.1:9/", "method" => "trace"})
           |> refused?("unknown_method")

    assert post(sim, "/run/req", %{"method" => "get"}) |> refused?("invalid_url")
  end

  # ------------------------------------------------------------ reactor_process

  test "reactor_process: start child, count, terminate, count again", %{sim: sim} do
    resp = post(sim, "/run/process", %{})
    assert resp.status == 200, inspect(resp.body)
    assert resp.body["state"] == "succeeded"
    v = resp.body["value"]

    assert v["started"] == %{"id" => "AshPPlan.MirrorSim.Reactor.SimWorker", "started" => true}
    assert v["count_before"]["active"] == 1
    assert v["count_before"]["workers"] == 1
    assert v["count_after"]["active"] == 0
    assert v["count_after"]["specs"] == 1
    assert v["terminated"] == "ok"
  end

  # ------------------------------------------------------------ local adapter steps

  test "local command: handler result is wrapped; failing handler is a failed outcome", %{
    sim: sim
  } do
    ok = post(sim, "/run/local/command", %{"handler" => "echo", "value" => 7})
    assert ok.body["state"] == "succeeded"
    assert ok.body["value"] == %{"command" => "sim_cmd", "result" => %{"value" => 7}}

    bad = post(sim, "/run/local/command", %{"handler" => "boom", "value" => 7})
    assert bad.body["state"] == "failed"
    assert inspect(bad.body["reason"]) =~ "boom"
  end

  test "local actuate constructs an intent and never executes it", %{sim: sim} do
    resp = post(sim, "/run/local/actuate", %{"payload" => %{"valve" => "open"}})
    assert resp.body["state"] == "succeeded"

    assert resp.body["value"] == %{
             "intent" => "sim_intent",
             "arguments" => %{"payload" => %{"valve" => "open"}},
             "executed?" => false,
             "authority" => "construct"
           }
  end

  test "local await: pending halts, ready succeeds, observe never halts", %{sim: sim} do
    halted = post(sim, "/run/local/await", %{"op" => "state_await", "ready" => false})
    assert halted.body["state"] == "halted"

    for op <- ["state_await", "event_await"] do
      ready = post(sim, "/run/local/await", %{"op" => op, "ready" => true})
      assert ready.body["state"] == "succeeded"
      assert ready.body["value"] == %{"observed" => true, "value" => "up"}
    end

    observed = post(sim, "/run/local/await", %{"op" => "state_observe", "ready" => false})
    assert observed.body["state"] == "succeeded"
    assert observed.body["value"] == %{"observed" => false, "value" => nil}

    assert post(sim, "/run/local/await", %{"op" => "bogus"}) |> refused?("unknown_op")
  end

  test "local telemetry emits the observation event with the step arguments", %{sim: sim} do
    resp = post(sim, "/run/local/telemetry", %{"name" => "alpha", "payload" => "p"})
    assert resp.body["state"] == "succeeded"
    assert resp.body["value"]["observed"] == "alpha"

    assert resp.body["emitted"] == [
             %{
               "event" => ["ash_pplan", "observation", "alpha"],
               "arguments" => %{"payload" => "p"}
             }
           ]

    assert post(sim, "/run/local/telemetry", %{"name" => "zeta"})
           |> refused?("unknown_telemetry_name")
  end

  test "local wakeup: halted until the injectable clock reaches wake_at", %{sim: sim} do
    early = post(sim, "/run/local/wakeup", %{"offset_ms" => 1000, "advance_ms" => 500})
    assert early.body["before"]["state"] == "halted"
    assert early.body["after"]["state"] == "halted"

    due = post(sim, "/run/local/wakeup", %{"offset_ms" => 1000, "advance_ms" => 1000})
    assert due.body["before"]["state"] == "halted"
    assert due.body["after"]["state"] == "succeeded"
    assert due.body["after"]["value"] == %{"observed" => true, "value" => due.body["wake_at"]}

    # the sim restored the process-global clock: a real clock reads wall time again
    assert DateTime.diff(AshPPlan.Reactor.Durable.Clock.now(), DateTime.utc_now(), :second)
           |> abs() < 5
  end

  test "local checkpoint returns the continuation; absent continuation fails", %{sim: sim} do
    ok = post(sim, "/run/local/checkpoint", %{"continuation" => %{"k" => 1}})
    assert ok.body["state"] == "succeeded"
    assert ok.body["value"] == %{"observed" => true, "value" => %{"k" => 1}}

    missing = post(sim, "/run/local/checkpoint", %{})
    assert missing.body["state"] == "failed"
    assert inspect(missing.body["reason"]) =~ "missing_argument"
  end

  # ------------------------------------------------------------ enrichment + middleware

  defp direct_subject(workflow) do
    {:ok, m} =
      Model.new(
        name: workflow,
        goal: "close",
        tasks: [
          [id: :observe, capability: "File.Read", authority: :observe],
          [id: :build, capability: "File.Write", after: [:observe], authority: :construct]
        ]
      )

    Subject.bind(m).id
  end

  test "enriched run: every step observation and the run receipt resolve to the model subject", %{
    sim: sim
  } do
    resp = post(sim, "/run/enriched", %{"workflow" => "sim-wf-ok"})
    assert resp.status == 200, inspect(resp.body)
    b = resp.body
    subject = direct_subject("sim-wf-ok")

    assert b["state"] == "succeeded"
    assert b["value"] == "done"
    assert b["subject"] == subject

    assert Enum.map(b["steps"], & &1["phase"]) |> Enum.sort() == [
             "start",
             "start",
             "stop",
             "stop"
           ]

    assert Enum.all?(
             b["steps"],
             &(&1["subject_id"] == subject and &1["evidence_subject"] == subject)
           )

    assert Enum.map(b["steps"], & &1["task"]) |> Enum.uniq() |> Enum.sort() == [
             "build",
             "observe"
           ]

    assert Enum.any?(b["steps"], &(&1["activity"] == "task_succeeded"))

    assert [run] = b["runs"]
    assert run["phase"] == "stop"
    assert run["status"] == "succeeded"
    assert run["subject_id"] == subject
    assert run["prov_activity"] == true
    assert is_binary(run["outcome_digest"])
    assert b["ledger_events"] == 0
  end

  test "enriched run: failing step yields step error, run error, failed outcome", %{sim: sim} do
    resp = post(sim, "/run/enriched", %{"workflow" => "sim-wf-fail", "fail" => true})
    b = resp.body

    assert b["state"] == "failed"
    assert Enum.any?(b["steps"], &(&1["phase"] == "error" and &1["task"] == "build"))
    assert [run] = b["runs"]
    assert run["phase"] == "error"
    assert run["status"] == "failed"
  end

  test "enriched run: subject tracks the workflow; success and failure digests differ", %{
    sim: sim
  } do
    a = post(sim, "/run/enriched", %{"workflow" => "sim-wf-a"}).body
    b = post(sim, "/run/enriched", %{"workflow" => "sim-wf-b"}).body
    refute a["subject"] == b["subject"]

    failed = post(sim, "/run/enriched", %{"workflow" => "sim-wf-a", "fail" => true}).body
    assert a["subject"] == failed["subject"]
    refute hd(a["runs"])["outcome_digest"] == hd(failed["runs"])["outcome_digest"]

    assert post(sim, "/run/enriched", %{"workflow" => "bad name!"})
           |> refused?("invalid_workflow")
  end

  test "identity middleware refuses a run whose context lost its workflow subject", %{sim: sim} do
    resp = post(sim, "/run/identity_missing", %{})
    assert resp.body["state"] == "failed"
    assert resp.body["reason"] == %{"reason" => "missing_workflow_identity"}
  end

  test "inherit: child authority is capped by the parent ceiling", %{sim: sim} do
    inherited =
      post(sim, "/inherit", %{"parent_authority" => "construct", "child_authority" => "observe"})

    assert inherited.status == 200
    assert inherited.body["task"] == "parent/kid"
    assert inherited.body["authority"] == "observe"
    assert inherited.body["parent"] == "parent"
    assert inherited.body["iri"] == "urn:mirror-sim:parent/kid"

    default = post(sim, "/inherit", %{"parent_authority" => "plan"})
    assert default.body["authority"] == "plan"

    escalation =
      post(sim, "/inherit", %{"parent_authority" => "observe", "child_authority" => "construct"})

    assert refused?(escalation, "authority_escalation") =~ "ceiling"

    assert post(sim, "/inherit", %{"parent_authority" => "plan", "child_authority" => "do"})
           |> refused?("unknown_authority")
  end

  # ------------------------------------------------------------ reactor_outcome

  test "outcome classification parity with ReactorOutcome", %{sim: sim} do
    cases = [
      {"ok", {:ok, "v"}},
      {"ok3", {:ok, "v", Reactor.Builder.new()}},
      {"halted", {:halted, Reactor.Builder.new()}},
      {"error", {:error, "v"}},
      {"other", {:unrecognized, "v"}}
    ]

    for {kind, term} <- cases do
      resp = post(sim, "/outcome", %{"kind" => kind, "value" => "v"})
      assert resp.body["state"] == Atom.to_string(ReactorOutcome.state(term)), kind
      assert resp.body["observe_state"] == Atom.to_string(ReactorOutcome.observe(term).state)
    end

    assert post(sim, "/outcome", %{"kind" => "ok3", "value" => "v"}).body["observe_keys"] == [
             "reactor",
             "state",
             "value"
           ]

    assert post(sim, "/outcome", %{"kind" => "error", "value" => "why"}).body["reason"] == "why"
    assert post(sim, "/outcome", %{"kind" => "other"}).body["state"] == "unknown"
  end

  # ------------------------------------------------------------ surfaces

  test "surfaces/0 names real exported functions" do
    for %{module: m, fun: f, arity: a, route: route} <- AshPPlan.MirrorSim.Reactor.surfaces() do
      assert Code.ensure_loaded?(m)
      assert function_exported?(m, f, a), "#{inspect(m)}.#{f}/#{a} not exported"
      assert String.starts_with?(route, "/reactor/")
    end
  end

  test "mounted behind the L01 server at /reactor/* (needs AshPPlan.MirrorSim.Server)" do
    assert Code.ensure_loaded?(AshPPlan.MirrorSim.Server),
           "AshPPlan.MirrorSim.Server absent: L01 router not landed (IN-FLIGHT)"

    {:ok, pid} = AshPPlan.MirrorSim.Server.start_link(port: 0)

    try do
      resp =
        Req.get!(AshPPlan.MirrorSim.Server.base_url(pid) <> "/reactor/adapters", retry: false)

      assert resp.status == 200
      assert is_list(resp.body["adapters"])
    after
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end
  end
end
