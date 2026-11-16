defmodule AshPPlan.MirrorSim.A2ATest do
  @moduledoc """
  Wire courts for the mirror-sim A2A area. A real Bandit listener serves
  `AshPPlan.MirrorSim.A2A`; the client is `:httpc` over the real socket. Backing
  collaborators are real (Facade, Durable Ets store, Reactor steps). Parity courts
  compare the wire response to a direct `AshPPlan.A2A.Facade` call on the same store.
  No sleeps: every call is synchronous request/response.

  Not covered: `Provider.propose` success paths and `Replay.fond` success (need a FOND
  domain struct, not expressible as JSON).
  """

  use ExUnit.Case, async: false

  alias AshPPlan.A2A.Facade
  alias AshPPlan.MirrorSim.A2A

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    A2A.reset()
    A2A.state()
    pid = start_supervised!({Bandit, plug: A2A, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    on_exit(&A2A.reset/0)
    %{base: "http://127.0.0.1:#{port}"}
  end

  # -- wire client -------------------------------------------------------------

  defp post(base, path, body \\ %{}) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> path), [], ~c"application/json", raw},
        [],
        body_format: :binary
      )

    {status, Jason.decode!(resp)}
  end

  defp get(base, path) do
    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(:get, {String.to_charlist(base <> path), []}, [], body_format: :binary)

    {status, Jason.decode!(resp)}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # -- surfaces ----------------------------------------------------------------

  test "surfaces/0 lists real exported functions" do
    for %{module: m, fun: f, arity: a, route: r} <- A2A.surfaces() do
      assert Code.ensure_loaded?(m)
      assert function_exported?(m, f, a), "#{inspect(m)}.#{f}/#{a}"
      assert String.starts_with?(r, "/a2a/")
    end
  end

  # -- send / get / replay ---------------------------------------------------------

  test "send completes a simple task; mapping :completed; effects ran once", %{base: b} do
    id = uniq("simple")
    assert {200, %{"state" => "completed", "id" => ^id}} = post(b, "/a2a/tasks/send", %{id: id})

    assert {200, %{"state" => "completed", "detail" => %{"run_status" => "completed"}}} =
             get(b, "/a2a/tasks/#{id}")

    assert {200, %{"counts" => %{"prepare" => 1, "finish" => 1}}} = get(b, "/a2a/effects")
  end

  test "replay: re-sending the same id adopts; tape and effects unchanged", %{base: b} do
    id = uniq("replay")

    assert {200, %{"state" => "completed", "detail" => d1}} =
             post(b, "/a2a/tasks/send", %{id: id})

    {200, %{"step_keys" => tape0}} = get(b, "/a2a/tasks/#{id}/tape")
    {200, %{"counts" => c0}} = get(b, "/a2a/effects")

    assert {200, %{"state" => "completed", "detail" => ^d1}} =
             post(b, "/a2a/tasks/send", %{id: id})

    assert {200, %{"step_keys" => ^tape0}} = get(b, "/a2a/tasks/#{id}/tape")
    assert {200, %{"counts" => ^c0}} = get(b, "/a2a/effects")
    assert tape0 != []
  end

  test "await park -> input_required with waiters; resume completes; second resume is sealed",
       %{base: b} do
    id = uniq("await")

    assert {200, %{"state" => "input_required", "detail" => ["go"]}} =
             post(b, "/a2a/tasks/send", %{id: id, plan: "await"})

    assert {200, %{"waiters" => ["go"]}} = get(b, "/a2a/tasks/#{id}/waiters")

    assert {200, %{"state" => "completed"}} =
             post(b, "/a2a/tasks/#{id}/resume", %{payload: %{answer: 42}})

    assert {200, %{"detail" => %{"version" => v}}} = get(b, "/a2a/tasks/#{id}")

    assert {200, %{"state" => "completed"}} = post(b, "/a2a/tasks/#{id}/resume", %{payload: 2})
    assert {200, %{"detail" => %{"version" => ^v}}} = get(b, "/a2a/tasks/#{id}")
    assert {200, %{"counts" => %{"prepare" => 1, "finish" => 1}}} = get(b, "/a2a/effects")
  end

  test "poll park -> working; resume refuses no_signal_waiter", %{base: b} do
    id = uniq("poll")

    assert {200, %{"state" => "working", "detail" => nil}} =
             post(b, "/a2a/tasks/send", %{id: id, plan: "poll"})

    assert {422, %{"refused" => true, "broken_term" => "no_signal_waiter"}} =
             post(b, "/a2a/tasks/#{id}/resume", %{payload: %{}})

    assert {200, %{"state" => "working", "detail" => %{"run_status" => "polling"}}} =
             get(b, "/a2a/tasks/#{id}")
  end

  test "invalid signal name refuses typed and moves nothing", %{base: b} do
    id = uniq("badsig")

    assert {200, %{"state" => "input_required"}} =
             post(b, "/a2a/tasks/send", %{id: id, plan: "await"})

    assert {422, %{"refused" => true, "broken_term" => "invalid_signal"}} =
             post(b, "/a2a/tasks/#{id}/resume", %{payload: 1, signal: 5})

    assert {200, %{"state" => "input_required"}} = get(b, "/a2a/tasks/#{id}")
  end

  # -- cancel ----------------------------------------------------------------------

  test "cancel a parked run -> canceled (cancelled run_status); cancel on ended returns standing",
       %{base: b} do
    id = uniq("cancel")

    assert {200, %{"state" => "input_required"}} =
             post(b, "/a2a/tasks/send", %{id: id, plan: "await"})

    assert {200, %{"state" => "canceled"}} = post(b, "/a2a/tasks/#{id}/cancel")
    # Real behavior: cancel returns :canceled immediately, but the standing run status is
    # the rollback (:cancelling -> :working) until it settles to :cancelled -> :canceled.
    # Law: the A2A state is always the facade mapping of the run status (disjunctive).
    mapping = %{"cancelling" => "working", "cancelled" => "canceled"}

    assert {200, %{"state" => s1, "detail" => %{"run_status" => rs1}}} =
             get(b, "/a2a/tasks/#{id}")

    assert rs1 in Map.keys(mapping)
    assert s1 == mapping[rs1]

    assert {200, %{"state" => s2}} = post(b, "/a2a/tasks/#{id}/cancel")
    assert s2 in ["working", "canceled"]

    done = uniq("done")
    assert {200, %{"state" => "completed"}} = post(b, "/a2a/tasks/send", %{id: done})
    assert {200, %{"state" => "completed"}} = post(b, "/a2a/tasks/#{done}/cancel")
  end

  # -- refusals --------------------------------------------------------------------

  test "unknown run fails closed with typed no_such_run on every task route", %{base: b} do
    for {kind, path} <- [
          {:get, "/a2a/tasks/ghost"},
          {:post, "/a2a/tasks/ghost/cancel"},
          {:post, "/a2a/tasks/ghost/attempt"},
          {:post, "/a2a/tasks/ghost/resume"},
          {:post, "/a2a/tasks/ghost/signal"},
          {:get, "/a2a/tasks/ghost/record"}
        ] do
      resp =
        case {kind, path} do
          {:get, _} -> get(b, path)
          {_, "/a2a/tasks/ghost/signal"} -> post(b, path, %{name: "go"})
          _ -> post(b, path)
        end

      assert {422, %{"refused" => true, "broken_term" => "no_such_run"}} = resp, path
    end
  end

  test "bad bodies and routes never 500", %{base: b} do
    assert {422, %{"broken_term" => "invalid_json"}} = post(b, "/a2a/tasks/send", "{nope")
    assert {422, %{"broken_term" => "body_not_object"}} = post(b, "/a2a/tasks/send", "[1]")
    assert {422, %{"broken_term" => "missing_id"}} = post(b, "/a2a/tasks/send", %{})

    assert {422, %{"broken_term" => "unknown_plan"}} =
             post(b, "/a2a/tasks/send", %{id: "x", plan: "zzz"})

    assert {404, %{"refused" => true, "broken_term" => "no_route"}} = get(b, "/a2a/nothing")
  end

  # -- status mapping ----------------------------------------------------------------

  test "status mapping table over the wire is total over Status.all and refuses unknowns",
       %{base: b} do
    expected = %{
      "pending" => "submitted",
      "waiting" => "input_required",
      "polling" => "working",
      "unwinding" => "working",
      "cancelling" => "working",
      "unwind_blocked" => "working",
      "completed" => "completed",
      "failed" => "failed",
      "cancelled" => "canceled"
    }

    assert length(AshPPlan.Reactor.Durable.Status.all()) == map_size(expected)

    for {status, state} <- expected do
      assert {200, %{"state" => ^state, "run_status" => true}} =
               get(b, "/a2a/status_map/#{status}")
    end

    assert {422, %{"broken_term" => "unmapped_status"}} = get(b, "/a2a/status_map/ok")

    assert {422, %{"broken_term" => "unmapped_status"}} =
             get(b, "/a2a/status_map/never_an_atom_zq91")
  end

  # -- parity differential -----------------------------------------------------------

  test "parity: wire send/status/resume == direct Facade calls on the same store", %{base: b} do
    {model, binds} = A2A.plan("await")
    opts = A2A.opts()
    store = A2A.state().store

    direct = uniq("direct")
    {:ok, d_state, d_detail} = Facade.start_or_adopt(store, direct, model, binds, opts)

    wire = uniq("wire")

    assert {200, %{"state" => w_state, "detail" => w_detail}} =
             post(b, "/a2a/tasks/send", %{id: wire, plan: "await"})

    assert w_state == A2A.enc(d_state)
    assert w_detail == A2A.enc(d_detail)

    {:ok, ds_state, ds_detail} = Facade.status(store, direct, opts)
    assert {200, %{"state" => ws, "detail" => wd}} = get(b, "/a2a/tasks/#{wire}")
    assert ws == A2A.enc(ds_state)
    assert Map.drop(wd, ["version"]) == Map.drop(A2A.enc(ds_detail), ["version"])

    {:ok, dr_state, _} = Facade.resume(store, direct, %{answer: 1}, opts)

    assert {200, %{"state" => wr}} =
             post(b, "/a2a/tasks/#{wire}/resume", %{payload: %{answer: 1}})

    assert wr == A2A.enc(dr_state)
  end

  # -- SA2A: subject guard / replay / provider ----------------------------------------------

  test "subject guard fetch: identity terms admitted, garbage refused", %{base: b} do
    assert {200, %{"subject" => "alice"}} =
             post(b, "/a2a/sa2a/subject/fetch", %{subject: "alice"})

    for bad <- [
          %{},
          %{subject: nil},
          %{subject: ""},
          %{subject: 7},
          %{subject: [1]},
          %{subject: %{a: 1}}
        ] do
      assert {422,
              %{"refused" => true, "broken_term" => "missing_subject", "authority" => "none"}} =
               post(b, "/a2a/sa2a/subject/fetch", bad),
             inspect(bad)
    end
  end

  test "subject guard preserve: same subject passes, drift and non-map candidates refuse", %{
    base: b
  } do
    assert {200, %{"candidate" => %{"subject" => "alice"}}} =
             post(b, "/a2a/sa2a/subject/preserve", %{
               subject: "alice",
               candidate: %{subject: "alice"}
             })

    assert {422, %{"broken_term" => "planner_refused", "reason" => reason}} =
             post(b, "/a2a/sa2a/subject/preserve", %{
               subject: "alice",
               candidate: %{subject: "mallory"}
             })

    assert reason =~ "subject_drift"

    assert {422, %{"broken_term" => "missing_subject"}} =
             post(b, "/a2a/sa2a/subject/preserve", %{subject: "alice", candidate: 5})
  end

  test "replay fond refusals: missing subject, drift, missing domain", %{base: b} do
    assert {422, %{"broken_term" => "missing_subject"}} =
             post(b, "/a2a/sa2a/replay/fond", %{request: %{}, candidate: %{subject: "a"}})

    assert {422, %{"broken_term" => "missing_subject"}} =
             post(b, "/a2a/sa2a/replay/fond", %{request: %{subject: "a"}, candidate: 3})

    assert {422, %{"broken_term" => "planner_refused", "reason" => r}} =
             post(b, "/a2a/sa2a/replay/fond", %{
               request: %{subject: "a"},
               candidate: %{subject: "b"}
             })

    assert r =~ "subject_drift"

    assert {422, %{"broken_term" => "missing_domain", "authority" => "none"}} =
             post(b, "/a2a/sa2a/replay/fond", %{
               request: %{subject: "a"},
               candidate: %{subject: "a"}
             })
  end

  test "provider propose refusals are closed-code and authority none", %{base: b} do
    codes = Enum.map(AshPPlan.SA2A.Refusal.codes(), &Atom.to_string/1)

    cases = [
      {%{formalism: "htn", subject: "s"}, "unsupported_formalism"},
      {%{subject: "s"}, "unsupported_formalism"},
      {%{formalism: "fond"}, "missing_subject"},
      {%{formalism: "fond", subject: "s"}, "missing_domain"},
      {%{formalism: "powl", subject: "s"}, "missing_plan_iri"}
    ]

    for {req, code} <- cases do
      assert {422, %{"refused" => true, "broken_term" => ^code, "authority" => "none"}} =
               post(b, "/a2a/sa2a/propose", req)

      assert code in codes
    end
  end

  test "supports and provider descriptor", %{base: b} do
    assert {200, %{"supported" => true}} = get(b, "/a2a/sa2a/supports/fond")
    assert {200, %{"supported" => true}} = get(b, "/a2a/sa2a/supports/powl")
    assert {200, %{"supported" => false}} = get(b, "/a2a/sa2a/supports/htn")

    assert {200, %{"id" => "a2a", "capabilities" => ["Distributed.Propose"], "cost" => 5}} =
             get(b, "/a2a/provider")
  end
end
