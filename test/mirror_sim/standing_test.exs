defmodule AshPPlan.MirrorSim.StandingTest do
  @moduledoc """
  Wire courts for `AshPPlan.MirrorSim.Standing`: real Bandit listener, real :httpc client,
  real AshPPlan modules behind the routes. Parity = response equals the direct call.
  Tamper courts = each mutated receipt/chain/envelope is refused with its broken_term.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.Server
  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Standing
  alias AshPPlan.Standing.{Chain, Ladder}

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @epoch ~U[2026-01-01 00:00:00Z]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    pid = start_supervised!({Server, port: 0})
    {:ok, base: Server.base_url(pid)}
  end

  defp call(method, base, path, body \\ nil) do
    url = String.to_charlist(base <> path)

    req =
      case method do
        :get -> {url, []}
        :post -> {url, [], ~c"application/json", Jason.encode!(body || %{})}
      end

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(method, req, [], body_format: :binary)

    {status, Jason.decode!(resp)}
  end

  defp post(base, path, body), do: call(:post, base, path, body)

  defp json_run(overrides \\ %{}) do
    Map.merge(
      %{
        "run_id" => "run-1",
        "subject_id" => "subject-1",
        "head" => @head,
        "base" => @base,
        "repo" => "ash_pplan",
        "tasks" => [
          %{"id" => "a", "depends_on" => []},
          %{"id" => "b", "depends_on" => ["a"]}
        ],
        "selection" => %{"a" => "p1", "b" => "p2"},
        "events" => [
          %{"id" => "e1", "task" => "a", "seq" => 1, "provider" => "p1", "outcome" => "ok"},
          %{"id" => "e2", "task" => "b", "seq" => 2, "provider" => "p2", "outcome" => "ok"}
        ],
        "execution" => %{"observed" => 1, "wanted" => 1},
        "consequence" => %{"file_exists" => true},
        "observation" => %{"x" => 1}
      },
      overrides
    )
  end

  @commands [%{"cmd" => "mix test", "cwd" => ".", "exit" => 0}]

  defp receipt_req(run, extra \\ %{}),
    do: Map.merge(%{"run" => run, "replay_commands" => @commands}, extra)

  defp direct_run do
    ev = fn id, task, seq, prov ->
      %Event{
        id: id,
        activity: "task_executed",
        timestamp: DateTime.add(@epoch, seq, :second),
        objects: [],
        attributes: %{task: task, seq: seq, provider: prov, outcome: "ok"},
        subject_id: "subject-1"
      }
    end

    %{
      events: [ev.("e1", "a", 1, "p1"), ev.("e2", "b", 2, "p2")],
      model: %{tasks: [%{id: "a", depends_on: []}, %{id: "b", depends_on: ["a"]}]},
      selection: %{"a" => "p1", "b" => "p2"},
      fond_gates: [],
      run_id: "run-1",
      subject_id: "subject-1",
      head: @head,
      base: @base,
      repo: "ash_pplan",
      observation: %{"x" => 1},
      execution: {1, 1},
      consequence: [{"file_exists", true}]
    }
  end

  defp direct_opts,
    do: [replay_commands: [%{cmd: "mix test", cwd: ".", exit: 0}]]

  test "layers and verdict combinations match direct calls", %{base: base} do
    {200, %{"layers" => layers}} = call(:get, base, "/standing/layers")
    assert layers == Enum.map(Standing.layers(), &Atom.to_string/1)

    {200, alive} =
      post(base, "/standing/verdict", %{
        "plan" => "ok",
        "execution" => true,
        "consequence" => true
      })

    assert alive["standing"] == "alive"

    {200, lost} =
      post(base, "/standing/verdict", %{
        "plan" => "ok",
        "execution" => "bad",
        "consequence" => "bad"
      })

    assert lost["standing"] == "lost"
    assert lost["broken"] == ["execution_correct", "observed_consequence_correct"]
  end

  test "standing over the wire agrees with the direct run verdict", %{base: base} do
    assert Standing.standing(direct_run()) == :alive
    {200, %{"standing" => "alive"}} = post(base, "/standing/standing", %{"run" => json_run()})

    bad = json_run(%{"execution" => %{"observed" => 1, "wanted" => 2}})
    {200, v} = post(base, "/standing/standing", %{"run" => bad})
    assert v["standing"] == "lost"
    assert v["broken"] == ["execution_correct"]

    {200, %{"verdicts" => vs}} = post(base, "/standing/verdicts", %{"run" => bad})
    assert vs["plan_correct"] == "ok"
    assert vs["execution_correct"]["error"] =~ "wanted" or is_map(vs["execution_correct"])
  end

  test "dependency order violation loses the plan layer", %{base: base} do
    swapped =
      json_run(%{
        "events" => [
          %{"id" => "e1", "task" => "b", "seq" => 1, "provider" => "p2", "outcome" => "ok"},
          %{"id" => "e2", "task" => "a", "seq" => 2, "provider" => "p1", "outcome" => "ok"}
        ]
      })

    {200, v} = post(base, "/standing/standing", %{"run" => swapped})
    assert v["broken"] == ["plan_correct"]

    {200, %{"receipt" => r}} = post(base, "/standing/receipt", receipt_req(swapped))
    assert r["standing"]["value"] == "REFUSED(plan_correct)"
    assert r["standing"]["broken_term"] == "mu_on_O"
  end

  test "receipt carries five fields and equals the direct receipt", %{base: base} do
    {200, %{"receipt" => r}} = post(base, "/standing/receipt", receipt_req(json_run()))
    assert Map.keys(r) |> Enum.sort() == ~w(authority consequence identity replay standing)
    assert r["authority"]["ceiling"] == "CONSTRUCT"
    assert r["authority"]["grant"] == "NONE"
    assert r["identity"]["subject_sha"] == @head
    assert r["standing"]["value"] == "ALIVE"

    {:ok, direct} = Standing.receipt(direct_run(), direct_opts())
    assert r["replay"]["ledger_digest"] == direct.replay.ledger_digest
    assert r["standing"]["value"] == direct.standing.value
    assert r["standing"]["derived_from"] == direct.standing.derived_from
  end

  test "receipt without replay commands is refused R_missing_replay", %{base: base} do
    {422, body} = post(base, "/standing/receipt", %{"run" => json_run()})
    assert body["refused"] == true
    assert body["broken_term"] == "R_missing_replay"
  end

  test "receipt without identity is refused R_missing_identity", %{base: base} do
    run = json_run() |> Map.delete("run_id")
    {422, body} = post(base, "/standing/receipt", receipt_req(run))
    assert body["broken_term"] == "R_missing_identity"
  end

  test "authority ceiling DO is refused at issue time", %{base: base} do
    {422, body} = post(base, "/standing/receipt", receipt_req(json_run(), %{"ceiling" => "DO"}))
    assert body["broken_term"] == "R_missing_authority"
  end

  test "cached receipt is byte-identical to the uncached receipt", %{base: base} do
    {200, _} = post(base, "/standing/cache/clear", %{})
    req = receipt_req(json_run())
    {200, plain} = post(base, "/standing/receipt", req)
    {200, first} = post(base, "/standing/receipt_cached", req)
    {200, second} = post(base, "/standing/receipt_cached", req)

    assert first["receipt"] == plain["receipt"]
    assert second["receipt"] == first["receipt"]
    assert second["cache_size"] == first["cache_size"]
    assert first["cache_size"] >= 1

    changed = json_run(%{"run_id" => "run-2"})
    {200, third} = post(base, "/standing/receipt_cached", receipt_req(changed))
    assert third["receipt"]["identity"]["run_id"] == "run-2"
    assert third["cache_size"] == first["cache_size"] + 1
  end

  test "receipt/validate accepts a real receipt and refuses each tamper", %{base: base} do
    {200, %{"receipt" => r}} = post(base, "/standing/receipt", receipt_req(json_run()))
    assert {200, %{"valid" => true}} = post(base, "/standing/receipt/validate", %{"receipt" => r})

    tampers = [
      {"R_missing_authority", put_in(r, ["authority", "ceiling"], "DO")},
      {"R_missing_authority", put_in(r, ["authority", "ceiling"], "GOD")},
      {"R_missing_standing", put_in(r, ["standing", "value"], "MOSTLY_WORKS")},
      {"R_missing_replay", put_in(r, ["replay", "commands"], [])},
      {"R_missing_identity", Map.put(r, "identity", nil)},
      {"R_missing_consequence", Map.delete(r, "consequence")}
    ]

    for {term, tampered} <- tampers do
      {422, body} = post(base, "/standing/receipt/validate", %{"receipt" => tampered})
      assert body["refused"] == true
      assert body["broken_term"] == term, "expected #{term}, got #{inspect(body)}"
    end
  end

  test "receipt/verify replays the run and refuses tampered digest or standing", %{base: base} do
    run = json_run()
    {200, %{"receipt" => r}} = post(base, "/standing/receipt", receipt_req(run))

    assert {200, %{"verified" => true}} =
             post(base, "/standing/receipt/verify", %{"receipt" => r, "run" => run})

    bad_digest = put_in(r, ["replay", "ledger_digest"], String.duplicate("0", 64))
    {422, b1} = post(base, "/standing/receipt/verify", %{"receipt" => bad_digest, "run" => run})
    assert b1["broken_term"] == "R_replay_mismatch"

    bad_standing = put_in(r, ["standing", "value"], "BLOCKED")
    {422, b2} = post(base, "/standing/receipt/verify", %{"receipt" => bad_standing, "run" => run})
    assert b2["broken_term"] == "R_replay_mismatch"

    other_run = json_run(%{"events" => tl(run["events"])})
    {422, b3} = post(base, "/standing/receipt/verify", %{"receipt" => r, "run" => other_run})
    assert b3["refused"] == true
  end

  test "ladder over the wire equals the direct ladder", %{base: base} do
    {:ok, direct} = Standing.ladder(direct_run(), direct_opts())
    {200, wire} = post(base, "/standing/ladder", receipt_req(json_run()))
    assert wire["state"] == Atom.to_string(direct.state)
    assert wire["index"] == direct.index
    assert length(wire["trail"]) == length(direct.trail)
    assert hd(wire["trail"])["from"] == "UNKNOWN"

    {200, %{"states" => states}} = call(:get, base, "/standing/ladder/states")
    assert states == Enum.map(Ladder.states(), &Atom.to_string/1)

    # without observation the ladder stops below ACTUATED
    no_obs = json_run() |> Map.delete("observation")
    {200, lower} = post(base, "/standing/ladder", receipt_req(no_obs))
    assert lower["index"] < wire["index"]
  end

  test "ladder admit refuses skipped rungs, unknown states, dangling facts", %{base: base} do
    good = %{
      "fact" => "f",
      "state" => "OBSERVED",
      "transitions" => [%{"from" => "UNKNOWN", "to" => "OBSERVED", "evidence" => "events=2"}]
    }

    {200, %{"admitted" => a}} = post(base, "/standing/ladder/admit", good)
    assert a["state"] == "OBSERVED"

    skipped = Map.put(good, "state", "VALIDATED")
    {422, s} = post(base, "/standing/ladder/admit", skipped)
    assert s["broken_term"] == "STL_missing_rung"

    {422, u} = post(base, "/standing/ladder/admit", Map.put(good, "state", "NOPE"))
    assert u["broken_term"] == "STL_unknown_state"

    {422, d} = post(base, "/standing/ladder/admit", Map.put(good, "fact", nil))
    assert d["broken_term"] == "STL_dangling_fact"

    {422, i} = post(base, "/standing/ladder/index", %{"state" => "NOPE"})
    assert i["broken_term"] == "STL_unknown_state"
    assert {200, %{"index" => 1}} = post(base, "/standing/ladder/index", %{"state" => "OBSERVED"})
  end

  test "chain build matches direct Chain and any tampered entry breaks verify", %{base: base} do
    pairs = [%{"event_id" => "e1", "task" => "a"}, %{"event_id" => "e2", "task" => "b"}]
    req = %{"pairs" => pairs, "standing" => "ALIVE", "subject" => "s"}
    {200, built} = post(base, "/standing/chain/build", req)

    {:ok, direct} = Chain.build_sealed([{"e1", "a"}, {"e2", "b"}], "seal", "ALIVE", "s")
    assert built["head"] == Chain.head(direct)
    assert built["verified"] == true
    assert built["algorithm"] == Chain.algorithm()

    entries = built["entries"]

    assert {200, %{"verified" => true}} =
             post(base, "/standing/chain/verify", %{"entries" => entries})

    tampered = List.update_at(entries, 1, &Map.put(&1, "subject", "evil"))
    {422, t} = post(base, "/standing/chain/verify", %{"entries" => tampered})
    assert t["broken_term"] == "chain_broken"

    dropped = List.delete_at(entries, 2)
    {422, d} = post(base, "/standing/chain/verify", %{"entries" => dropped})
    assert d["broken_term"] == "chain_broken"

    {422, bad} = post(base, "/standing/chain/build", %{req | "standing" => "MOSTLY"})
    assert bad["refused"] == true
  end

  test "portable projection: direct, refused payload, no-counterpart, unknown", %{base: base} do
    {200, %{"projected" => "ALIVE"}} =
      post(base, "/standing/projection/standing", %{"value" => "ALIVE"})

    {200, %{"projected" => "REFUSED:PLAN_CORRECT"}} =
      post(base, "/standing/projection/standing", %{"value" => "REFUSED:PLAN_CORRECT"})

    {422, bare} = post(base, "/standing/projection/standing", %{"value" => "REFUSED"})
    assert bare["broken_term"] == "refused_requires_ggen_payload"

    {422, lower} = post(base, "/standing/projection/standing", %{"value" => "REFUSED:plan"})
    assert lower["broken_term"] == "refused_payload_not_ggen_conformant"

    {200, nc} = post(base, "/standing/projection/standing", %{"value" => "COMPENSATED"})
    assert nc["disposition"] == "no_ggen_counterpart"

    {422, unk} = post(base, "/standing/projection/standing", %{"value" => "VIBES"})
    assert unk["broken_term"] == "unknown_standing"

    {200, id} = post(base, "/standing/projection/identity", %{"subject_sha" => @head})
    assert id["flags"] == ["sha_length_mismatch"]

    {422, bad} = post(base, "/standing/projection/identity", %{"subject_sha" => "xyz"})
    assert bad["broken_term"] == "bad_identity"

    {200, rep} =
      post(base, "/standing/projection/report", %{
        "standing" => "ALIVE",
        "identity" => %{"base_sha" => @base}
      })

    assert rep["ggen_schema"] == "https://ggen.dev/receipt/pack/v1"
  end

  test "execution receipt: digest parity, exact identity, bad sha refused", %{base: base} do
    outcome = %{"ok" => %{"v" => 1}}

    {200, %{"outcome_digest" => d}} =
      post(base, "/standing/execution_receipt/digest", %{"outcome" => outcome})

    assert d == AshPPlan.ExecutionReceipt.outcome_digest({:ok, %{"v" => 1}})

    {200, other} =
      post(base, "/standing/execution_receipt/digest", %{"outcome" => %{"ok" => %{"v" => 2}}})

    refute other["outcome_digest"] == d

    req = %{
      "plan_iri" => "urn:plan:1",
      "run_id" => "r1",
      "outcome" => outcome,
      "repo" => "ash_pplan",
      "subject_sha" => @head,
      "base_sha" => @base,
      "binding" => %{"plan" => "p", "inputs" => %{"i" => 1}, "tape" => nil}
    }

    {200, r} = post(base, "/standing/execution_receipt/observe", req)
    assert r["status"] == "succeeded"
    assert r["outcome_digest"] == d
    assert r["subject_sha"] == @head
    assert r["release_receipt_digest"] =~ ~r/^[0-9a-f]{64}$/
    assert r["rdf"] =~ "ap:resultDigest" or r["rdf"] =~ "resultDigest"
    assert r["rdf"] =~ "releaseReceiptDigest"

    {422, bad} =
      post(base, "/standing/execution_receipt/observe", %{req | "subject_sha" => "nothex"})

    assert bad["broken_term"] == "bad_identity"

    {422, malformed} =
      post(base, "/standing/execution_receipt/observe", %{req | "outcome" => "x"})

    assert malformed["broken_term"] == "malformed_execution_receipt"

    {200, b1} =
      post(base, "/standing/execution_receipt/binding", %{
        "plan" => "p1",
        "inputs" => 1,
        "observed" => outcome
      })

    {200, b2} =
      post(base, "/standing/execution_receipt/binding", %{
        "plan" => "p2",
        "inputs" => 1,
        "observed" => outcome
      })

    refute b1["release_receipt_digest"] == b2["release_receipt_digest"]
  end

  test "release receipt binds the exact head and refuses a non-hex head", %{base: base} do
    {200, r} = post(base, "/standing/release_receipt", %{"head" => @head})
    assert r["head"] == @head
    assert r["release"] == AshPPlan.version()
    assert r["digest"] == AshPPlan.ReleaseReceipt.observe(@head).digest

    {200, r2} = post(base, "/standing/release_receipt", %{"head" => @base})
    refute r2["digest"] == r["digest"]

    {422, bad} = post(base, "/standing/release_receipt", %{"head" => "abc"})
    assert bad["broken_term"] == "release_head_not_exact"
    {422, bad2} = post(base, "/standing/release_receipt", %{"head" => 12})
    assert bad2["broken_term"] == "release_head_not_exact"

    {200, %{"sources" => srcs}} = call(:get, base, "/standing/release_receipt/sources")
    assert srcs == AshPPlan.ReleaseReceipt.sources()

    {200, %{"digest" => d}} =
      post(base, "/standing/release_receipt/digest", %{
        "head" => @head,
        "release" => r["release"],
        "sources" => srcs
      })

    assert d == r["digest"]

    {200, %{"digest" => d2}} =
      post(base, "/standing/release_receipt/digest", %{
        "head" => @head,
        "release" => r["release"],
        "sources" => Map.put(srcs, "ontology.ttl", String.duplicate("0", 64))
      })

    refute d2 == d
  end

  test "frontier evidence: CONSTRUCT ceiling and tampered envelope refused", %{base: base} do
    req = %{
      "control_plane" => %{"plans" => ["a"], "n" => 1},
      "fond_validation" => "ok",
      "producer_head" => @head
    }

    {200, %{"envelope" => env}} = post(base, "/standing/frontier", req)
    assert env["authority_ceiling"] == "CONSTRUCT"
    assert env["standing"] == "CANDIDATE"
    assert "actuation_authority" in env["refused"]
    assert env["artifact_hash"] =~ ~r/^sha256:[0-9a-f]{64}$/

    assert {200, %{"verified" => true}} =
             post(base, "/standing/frontier/verify", %{"envelope" => env})

    for tampered <- [
          Map.put(env, "standing", "ALIVE"),
          Map.put(env, "authority_ceiling", "DO"),
          Map.put(env, "producer_head", @base),
          Map.put(env, "artifact_hash", "sha256:" <> String.duplicate("0", 64))
        ] do
      {422, t} = post(base, "/standing/frontier/verify", %{"envelope" => tampered})
      assert t["broken_term"] == "digest_mismatch"
    end

    {422, missing} = post(base, "/standing/frontier", Map.delete(req, "producer_head"))
    assert missing["broken_term"] == "frontier_missing_producer_head"
  end

  test "runtime contract: exact subject, authority gate, receipt, replay, refusal", %{base: base} do
    {200, id} = call(:get, base, "/standing/runtime_contract/identity")
    assert id == %{"repo" => "ash_pplan", "base" => id["base"], "head" => id["head"]}
    assert AshPPlan.RuntimeContract.ExactSubject.identity().head == id["head"]

    assert {200, %{"exact" => true}} = post(base, "/standing/runtime_contract/exact", id)
    {422, ne} = post(base, "/standing/runtime_contract/exact", %{id | "head" => @head})
    assert ne["broken_term"] == "not_exact_subject"

    assert {200, %{"authorized" => true}} =
             post(base, "/standing/runtime_contract/authorize", %{
               "action" => "CONSTRUCT",
               "policy" => "p"
             })

    {422, denied} =
      post(base, "/standing/runtime_contract/authorize", %{"action" => "DO", "policy" => "p"})

    assert denied["broken_term"] == "authority"

    {422, nopolicy} =
      post(base, "/standing/runtime_contract/authorize", %{"action" => "CONSTRUCT"})

    assert nopolicy["broken_term"] == "authority"

    {200, rc} =
      post(base, "/standing/runtime_contract/receipt", %{
        "subject" => "s",
        "action" => "CONSTRUCT",
        "result" => "ok",
        "replay_key" => "k1"
      })

    assert rc["replay_key"] == "k1"
    assert {:ok, _, _} = DateTime.from_iso8601(rc["recorded_at"])

    assert {200, %{"replayed" => "k1"}} =
             post(base, "/standing/runtime_contract/replay", %{"receipt" => rc})

    {422, norep} =
      post(base, "/standing/runtime_contract/replay", %{
        "receipt" => Map.put(rc, "replay_key", nil)
      })

    assert norep["broken_term"] == "missing_replay_key"

    {200, ref} =
      post(base, "/standing/runtime_contract/refusal", %{
        "code" => "c",
        "reason" => "r",
        "subject" => "s"
      })

    assert ref == %{"code" => "c", "reason" => "r", "subject" => "s"}
  end

  test "surfaces/0 routes are all mounted", %{base: base} do
    {200, %{"mounted" => mounted}} = call(:get, base, "/surfaces")
    area = Enum.find(mounted, &(&1["area"] == "standing"))
    assert area
    assert length(area["surfaces"]) == length(AshPPlan.MirrorSim.Standing.surfaces())
  end

  test "malformed input is a typed refusal, never a 500", %{base: base} do
    {422, a} = post(base, "/standing/receipt", %{"run" => "nope"})
    assert a["broken_term"] == "malformed_run"

    {404, b} = call(:get, base, "/standing/no_such_route")
    assert b["broken_term"] == "unknown_route"
  end
end
