defmodule AshPPlan.MirrorSim.Standing do
  @moduledoc """
  Mirror-sim area `standing`, mounted at `/standing/*`.

  Drives the real `AshPPlan.Standing` (+ `Receipt`, `Chain`, `Cached`, `Ladder`,
  `PortableProjection`), `AshPPlan.ExecutionReceipt`, `AshPPlan.ReleaseReceipt`,
  `AshPPlan.FrontierEvidence` and `AshPPlan.RuntimeContract.*` over JSON. No doubles: every
  response is computed by the real module. Typed refusals are
  `{"refused":true,"broken_term":...,"reason":...}` with HTTP 422.

  A JSON "run" is: `run_id`, `subject_id`, `head`, `base`, `repo`, `tasks` (`[{id, depends_on}]`),
  `selection` (task => provider), `events` (`[{id, task, seq, provider, outcome}]`),
  `fond_gates`, `execution` (`{observed, wanted}`), `consequence` (`{name: bool}`), `observation`.
  Receipt options: `replay_commands` (`[{cmd, cwd, exit}]`), `ceiling`, `grant`, `actor`, `evidence`.
  """
  use Plug.Router

  alias AshPPlan.{ExecutionReceipt, FrontierEvidence, ReleaseReceipt, Standing}
  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.RuntimeContract.{AuthorityGate, ExactSubject, Refusal, Replay}
  alias AshPPlan.RuntimeContract.Receipt, as: RcReceipt
  alias AshPPlan.Standing.{Cached, Chain, Ladder, PortableProjection}
  alias AshPPlan.Standing.Receipt

  plug(:match)
  plug(:dispatch)

  @chain_keys ~w(entry_id parent_hash phase standing subject action pending_ref seal hash)
  @epoch ~U[2026-01-01 00:00:00Z]

  @doc "Surfaces mirrored by this area."
  @spec surfaces() :: [map()]
  def surfaces do
    [
      {Standing, :layers, 0, "/standing/layers"},
      {Standing, :verdict, 3, "/standing/verdict"},
      {Standing, :verdicts, 1, "/standing/verdicts"},
      {Standing, :standing, 1, "/standing/standing"},
      {Standing, :plan_correct, 1, "/standing/verdicts"},
      {Standing, :execution_correct, 1, "/standing/verdicts"},
      {Standing, :observed_consequence_correct, 1, "/standing/verdicts"},
      {Standing, :ladder, 2, "/standing/ladder"},
      {Standing, :receipt, 2, "/standing/receipt"},
      {Standing, :receipt_cached, 2, "/standing/receipt_cached"},
      {Receipt, :validate, 1, "/standing/receipt/validate"},
      {Receipt, :fields, 0, "/standing/receipt/fields"},
      {Receipt, :standings, 0, "/standing/receipt/fields"},
      {Receipt, :to_map, 1, "/standing/receipt"},
      {Chain, :build_sealed, 4, "/standing/chain/build"},
      {Chain, :verify, 1, "/standing/chain/verify"},
      {Chain, :head, 1, "/standing/chain/build"},
      {Cached, :size, 0, "/standing/receipt_cached"},
      {Cached, :clear, 0, "/standing/cache/clear"},
      {Ladder, :states, 0, "/standing/ladder/states"},
      {Ladder, :index, 1, "/standing/ladder/index"},
      {Ladder, :admit, 1, "/standing/ladder/admit"},
      {PortableProjection, :project_standing, 1, "/standing/projection/standing"},
      {PortableProjection, :project_identity, 1, "/standing/projection/identity"},
      {PortableProjection, :projection_report, 2, "/standing/projection/report"},
      {ExecutionReceipt, :observe, 6, "/standing/execution_receipt/observe"},
      {ExecutionReceipt, :to_rdf, 2, "/standing/execution_receipt/observe"},
      {ExecutionReceipt, :validate_identity, 1, "/standing/execution_receipt/observe"},
      {ExecutionReceipt, :outcome_digest, 1, "/standing/execution_receipt/digest"},
      {ExecutionReceipt, :release_receipt_digest, 2, "/standing/execution_receipt/binding"},
      {ReleaseReceipt, :observe, 1, "/standing/release_receipt"},
      {ReleaseReceipt, :digest, 3, "/standing/release_receipt/digest"},
      {ReleaseReceipt, :sources, 0, "/standing/release_receipt/sources"},
      {ReleaseReceipt, :to_json, 1, "/standing/release_receipt"},
      {FrontierEvidence, :from_control_plane, 3, "/standing/frontier"},
      {FrontierEvidence, :verify, 1, "/standing/frontier/verify"},
      {ExactSubject, :identity, 0, "/standing/runtime_contract/identity"},
      {ExactSubject, :exact?, 1, "/standing/runtime_contract/exact"},
      {AuthorityGate, :authorize, 1, "/standing/runtime_contract/authorize"},
      {RcReceipt, :new, 4, "/standing/runtime_contract/receipt"},
      {Replay, :replay, 2, "/standing/runtime_contract/replay"},
      {Refusal, :new, 3, "/standing/runtime_contract/refusal"},
      {Refusal, :tagged, 1, "/standing/runtime_contract/refusal"}
    ]
    |> Enum.map(fn {m, f, a, r} -> %{module: m, fun: f, arity: a, route: r} end)
  end

  # ---- layers / verdicts ----

  get "/layers" do
    ok(conn, %{"layers" => Enum.map(Standing.layers(), &Atom.to_string/1)})
  end

  post "/verdict" do
    p = params(conn)

    result =
      Standing.verdict(
        layer_verdict(p["plan"]),
        layer_verdict(p["execution"]),
        layer_verdict(p["consequence"])
      )

    ok(conn, standing_json(result))
  end

  post "/verdicts" do
    with_run(conn, fn run ->
      v = Standing.verdicts(run)
      ok(conn, %{"verdicts" => Map.new(v, fn {k, x} -> {Atom.to_string(k), verdict_json(x)} end)})
    end)
  end

  post "/standing" do
    with_run(conn, fn run -> ok(conn, standing_json(Standing.standing(run))) end)
  end

  # ---- ladder ----

  get "/ladder/states" do
    ok(conn, %{"states" => Enum.map(Ladder.states(), &Atom.to_string/1)})
  end

  post "/ladder/index" do
    state = to_ladder_state(params(conn)["state"])

    case Ladder.index(state) do
      {:error, e} -> refuse_map(conn, e)
      i -> ok(conn, %{"index" => i})
    end
  end

  post "/ladder/admit" do
    p = params(conn)

    transitions =
      for t <- list(p["transitions"]), is_map(t) do
        %{
          from: to_ladder_state(t["from"]),
          to: to_ladder_state(t["to"]),
          evidence: t["evidence"]
        }
      end

    claim = %{fact: p["fact"], state: to_ladder_state(p["state"]), transitions: transitions}

    case Ladder.admit(claim) do
      {:ok, r} -> ok(conn, %{"admitted" => jsonable(r)})
      {:error, e} -> refuse_map(conn, e)
    end
  end

  post "/ladder" do
    with_run(conn, fn run ->
      case Standing.ladder(run, receipt_opts(params(conn))) do
        {:ok, r} -> ok(conn, jsonable(r))
        {:error, e} -> refuse_map(conn, e)
      end
    end)
  end

  # ---- receipt ----

  post "/receipt" do
    with_run(conn, fn run ->
      render_receipt(conn, Standing.receipt(run, receipt_opts(params(conn))), %{})
    end)
  end

  post "/receipt_cached" do
    with_run(conn, fn run ->
      result = Standing.receipt_cached(run, receipt_opts(params(conn)))
      render_receipt(conn, result, %{"cache_size" => Cached.size()})
    end)
  end

  post "/cache/clear" do
    ok(conn, %{"cleared" => Cached.clear() == :ok, "cache_size" => Cached.size()})
  end

  get "/receipt/fields" do
    ok(conn, %{"fields" => Receipt.fields(), "standings" => Receipt.standings()})
  end

  post "/receipt/validate" do
    r = Receipt.new(map(params(conn)["receipt"]))

    case Receipt.validate(r) do
      :ok -> ok(conn, %{"valid" => true})
      {:error, e} -> refuse_map(conn, e)
    end
  end

  # Tamper court: shape-validate the claimed receipt, then replay the run and compare the
  # ledger digest and standing value. Mismatch term `R_replay_mismatch` is the sim's own.
  post "/receipt/verify" do
    p = params(conn)
    claimed = map(p["receipt"])

    case Receipt.validate(Receipt.new(claimed)) do
      {:error, e} ->
        refuse_map(conn, e)

      :ok ->
        with_run(conn, fn run -> verify_claimed(conn, claimed, run) end)
    end
  end

  # ---- chain ----

  post "/chain/build" do
    p = params(conn)

    pairs =
      for x <- list(p["pairs"]), is_map(x) do
        {x["event_id"], x["task"]}
      end

    if Enum.all?(pairs, fn {a, b} -> is_binary(a) and is_binary(b) end) and
         is_binary(p["subject"]) do
      case Chain.build_sealed(pairs, "seal", p["standing"] || "ALIVE", p["subject"]) do
        {:ok, chain} ->
          ok(conn, %{
            "entries" => jsonable(chain),
            "verified" => Chain.verify(chain),
            "head" => Chain.head(chain),
            "algorithm" => Chain.algorithm()
          })

        {:error, reason} ->
          refuse(conn, "chain_#{reason}", reason)
      end
    else
      refuse(conn, "chain_malformed", "pairs need binary event_id/task and a binary subject")
    end
  end

  post "/chain/verify" do
    entries =
      for e <- list(params(conn)["entries"]), is_map(e) do
        Map.new(@chain_keys, fn k -> {String.to_atom(k), Map.fetch!(e, k)} end)
      end

    if Chain.verify(entries) do
      ok(conn, %{"verified" => true, "head" => Chain.head(entries)})
    else
      refuse(conn, "chain_broken", "hash chain verification failed")
    end
  end

  # ---- projection ----

  post "/projection/standing" do
    case PortableProjection.project_standing(params(conn)["value"]) do
      {:ok, s} ->
        ok(conn, %{"projected" => s})

      {:no_ggen_counterpart, reason} ->
        ok(conn, %{"disposition" => "no_ggen_counterpart", "reason" => to_string(reason)})

      {:error, %{broken_term: t} = e} ->
        refuse(conn, t, inspect(e))

      {:error, {:unknown_standing, v}} ->
        refuse(conn, "unknown_standing", inspect(v))
    end
  end

  post "/projection/identity" do
    case PortableProjection.project_identity(params(conn)) do
      {:ok, i} -> ok(conn, jsonable(i))
      {:error, {:bad_identity, f}} -> refuse(conn, "bad_identity", f)
    end
  end

  post "/projection/report" do
    p = params(conn)
    ok(conn, jsonable(PortableProjection.projection_report(p["standing"], map(p["identity"]))))
  end

  # ---- execution receipt ----

  post "/execution_receipt/observe" do
    p = params(conn)

    with {:ok, outcome} <- outcome(p["outcome"]),
         true <- is_binary(p["plan_iri"]) or {:error, "plan_iri must be a string"} do
      opts =
        [
          repo: p["repo"],
          subject_sha: p["subject_sha"],
          base_sha: p["base_sha"],
          corresponds_to_steps: Enum.filter(list(p["steps"]), &is_binary/1)
        ] ++ binding_opt(p["binding"])

      r =
        ExecutionReceipt.observe(
          p["plan_iri"],
          p["run_id"] || "run",
          outcome,
          DateTime.utc_now(),
          System.monotonic_time(:microsecond),
          opts
        )

      case ExecutionReceipt.validate_identity(r) do
        :ok ->
          ok(conn, %{
            "status" => Atom.to_string(r.status),
            "outcome_digest" => r.outcome_digest,
            "run_id" => ExecutionReceipt.run_identifier(r.run_id),
            "repo" => r.repo,
            "subject_sha" => r.subject_sha,
            "base_sha" => r.base_sha,
            "release_receipt_digest" => r.release_receipt_digest,
            "rdf" => ExecutionReceipt.to_rdf(r)
          })

        {:error, {:bad_identity, f}} ->
          refuse(conn, "bad_identity", f)
      end
    else
      {:error, reason} -> refuse(conn, "malformed_execution_receipt", reason)
    end
  end

  post "/execution_receipt/digest" do
    case outcome(params(conn)["outcome"]) do
      {:ok, o} -> ok(conn, %{"outcome_digest" => ExecutionReceipt.outcome_digest(o)})
      {:error, reason} -> refuse(conn, "malformed_outcome", reason)
    end
  end

  post "/execution_receipt/binding" do
    p = params(conn)

    binding =
      %{plan: p["plan"], inputs: p["inputs"], tape: p["tape"]}
      |> then(fn b ->
        if Map.has_key?(p, "outcome"),
          do: Map.put(b, :outcome, outcome_or_raw(p["outcome"])),
          else: b
      end)

    observed = outcome_or_raw(p["observed"])

    ok(conn, %{
      "release_receipt_digest" => ExecutionReceipt.release_receipt_digest(binding, observed)
    })
  end

  # ---- release receipt ----

  post "/release_receipt" do
    head = params(conn)["head"]

    try do
      r = ReleaseReceipt.observe(head)

      ok(conn, %{
        "release" => r.release,
        "head" => r.head,
        "digest" => r.digest,
        "sources" => Map.new(r.sources),
        "json" => ReleaseReceipt.to_json(r)
      })
    rescue
      e in ArgumentError -> refuse(conn, "release_head_not_exact", Exception.message(e))
    end
  end

  get "/release_receipt/sources" do
    ok(conn, %{"sources" => ReleaseReceipt.sources()})
  end

  post "/release_receipt/digest" do
    p = params(conn)
    sources = p["sources"] |> map() |> Enum.map(fn {k, v} -> {k, v} end)

    try do
      ok(conn, %{"digest" => ReleaseReceipt.digest(p["head"], p["release"], sources)})
    rescue
      e in [ArgumentError, FunctionClauseError] ->
        refuse(conn, "release_head_not_exact", Exception.message(e))
    end
  end

  # ---- frontier evidence ----

  post "/frontier" do
    p = params(conn)

    if is_binary(p["producer_head"]) do
      env =
        FrontierEvidence.from_control_plane(
          map(p["control_plane"]),
          p["fond_validation"],
          producer_head: p["producer_head"],
          standing: p["standing"] || "CANDIDATE"
        )

      ok(conn, %{"envelope" => jsonable(env)})
    else
      refuse(conn, "frontier_missing_producer_head", "producer_head is required")
    end
  end

  post "/frontier/verify" do
    case FrontierEvidence.verify(map(params(conn)["envelope"])) do
      {:ok, _} -> ok(conn, %{"verified" => true})
      {:refusal, reason} -> refuse(conn, reason, "artifact_hash does not match canonical payload")
    end
  end

  # ---- runtime contract ----

  get "/runtime_contract/identity" do
    ok(conn, jsonable(ExactSubject.identity()))
  end

  post "/runtime_contract/exact" do
    p = params(conn)
    id = %{repo: p["repo"], base: p["base"], head: p["head"]}

    if ExactSubject.exact?(id),
      do: ok(conn, %{"exact" => true}),
      else: refuse(conn, "not_exact_subject", "identity does not match the exact subject")
  end

  post "/runtime_contract/authorize" do
    p = params(conn)

    case AuthorityGate.authorize(%{action: p["action"], policy: p["policy"]}) do
      :ok ->
        ok(conn, %{"authorized" => true})

      {:error, {:refused, term, what}} ->
        refuse(conn, term, inspect(what))
    end
  end

  post "/runtime_contract/receipt" do
    p = params(conn)
    r = RcReceipt.new(p["subject"], p["action"], p["result"], p["replay_key"])

    ok(conn, %{
      "subject" => r.subject,
      "action" => r.action,
      "result" => jsonable(r.result),
      "replay_key" => r.replay_key,
      "recorded_at" => DateTime.to_iso8601(r.recorded_at)
    })
  end

  post "/runtime_contract/replay" do
    r = map(params(conn)["receipt"]) |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

    case Replay.replay(r, fn key -> {:ok, key} end) do
      {:ok, key} -> ok(conn, %{"replayed" => key})
      {:error, {:refused, term}} -> refuse(conn, term, "receipt has no replay_key")
    end
  end

  post "/runtime_contract/refusal" do
    p = params(conn)
    r = Refusal.new(p["code"], p["reason"], p["subject"])
    {:refused, code, reason} = Refusal.tagged(r)

    ok(conn, %{
      "code" => jsonable(code),
      "reason" => jsonable(reason),
      "subject" => jsonable(r.subject)
    })
  end

  match _ do
    Json.refuse(
      conn,
      "unknown_route",
      "no standing route for #{conn.method} #{conn.request_path}",
      404
    )
  end

  # ---- helpers ----

  defp ok(conn, data), do: Json.send_json(conn, 200, data)
  defp refuse(conn, term, reason), do: Json.refuse(conn, term, reason)

  defp refuse_map(conn, %{broken_term: t} = e),
    do: refuse(conn, t, inspect(Map.delete(e, :broken_term)))

  defp refuse_map(conn, e), do: refuse(conn, "refused", inspect(e))

  defp params(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> %{}
      %{} = m -> m
      _ -> %{}
    end
  end

  defp map(m) when is_map(m), do: m
  defp map(_), do: %{}
  defp list(l) when is_list(l), do: l
  defp list(_), do: []

  defp layer_verdict(true), do: :ok
  defp layer_verdict("ok"), do: :ok
  defp layer_verdict(other), do: {:error, other}

  defp verdict_json(:ok), do: "ok"
  defp verdict_json({:error, t}), do: %{"error" => inspect(t, limit: 20)}

  defp standing_json(:alive), do: %{"standing" => "alive", "broken" => []}

  defp standing_json({:lost, broken}),
    do: %{"standing" => "lost", "broken" => Enum.map(broken, &Atom.to_string/1)}

  defp to_ladder_state(s) do
    Enum.find(Ladder.states(), s, fn a -> Atom.to_string(a) == s end)
  end

  defp outcome(%{"ok" => v}), do: {:ok, {:ok, v}}
  defp outcome(%{"error" => v}), do: {:ok, {:error, v}}
  defp outcome(_), do: {:error, "outcome must be {\"ok\": v} or {\"error\": v}"}

  defp outcome_or_raw(o) do
    case outcome(o) do
      {:ok, t} -> t
      _ -> o
    end
  end

  defp binding_opt(%{} = b) do
    binding =
      %{plan: b["plan"], inputs: b["inputs"], tape: b["tape"]}
      |> then(fn m ->
        if Map.has_key?(b, "outcome"),
          do: Map.put(m, :outcome, outcome_or_raw(b["outcome"])),
          else: m
      end)

    [receipt_binding: binding]
  end

  defp binding_opt(_), do: []

  defp receipt_opts(p) do
    commands =
      for c <- list(p["replay_commands"]), is_map(c) do
        %{cmd: c["cmd"], cwd: c["cwd"], exit: c["exit"]}
      end

    [replay_commands: commands]
    |> put_opt(:ceiling, p["ceiling"])
    |> put_opt(:grant, p["grant"])
    |> put_opt(:actor, p["actor"])
    |> then(fn o -> if p["evidence"] == false, do: Keyword.put(o, :evidence, false), else: o end)
  end

  defp put_opt(opts, _k, nil), do: opts
  defp put_opt(opts, k, v), do: Keyword.put(opts, k, v)

  defp with_run(conn, fun) do
    case build_run(params(conn)["run"]) do
      {:ok, run} ->
        try do
          fun.(run)
        rescue
          e in ArgumentError -> refuse(conn, "malformed_run", Exception.message(e))
        end

      {:error, reason} ->
        refuse(conn, "malformed_run", reason)
    end
  end

  defp build_run(%{} = p) do
    evs = list(p["events"])

    if Enum.all?(evs, &is_map/1) and Enum.all?(list(p["tasks"]), &is_map/1) do
      subject = p["subject_id"]

      events =
        for e <- evs do
          %Event{
            id: e["id"],
            activity: "task_executed",
            timestamp: DateTime.add(@epoch, trunc_int(e["seq"]), :second),
            objects: [],
            attributes: %{
              task: e["task"],
              seq: e["seq"],
              provider: e["provider"],
              outcome: e["outcome"]
            },
            subject_id: subject
          }
        end

      tasks =
        for t <- list(p["tasks"]), do: %{id: t["id"], depends_on: list(t["depends_on"])}

      gates =
        for g <- list(p["fond_gates"]), is_map(g) do
          %{task: g["task"], admit: list(g["admit"]), successors: list(g["successors"])}
        end

      base = %{
        events: events,
        model: %{tasks: tasks},
        selection: map(p["selection"]),
        fond_gates: gates
      }

      run =
        base
        |> put_key(:run_id, p["run_id"])
        |> put_key(:subject_id, subject)
        |> put_key(:head, p["head"])
        |> put_key(:base, p["base"])
        |> put_key(:repo, p["repo"])
        |> put_key(:observation, p["observation"])
        |> put_execution(p["execution"])
        |> put_consequence(p["consequence"])

      {:ok, run}
    else
      {:error, "events and tasks must be lists of objects"}
    end
  end

  defp build_run(_), do: {:error, "run must be an object"}

  defp trunc_int(i) when is_integer(i), do: i
  defp trunc_int(_), do: 0

  defp put_key(m, _k, nil), do: m
  defp put_key(m, k, v), do: Map.put(m, k, v)

  defp put_execution(run, %{"observed" => o, "wanted" => w}), do: Map.put(run, :execution, {o, w})
  defp put_execution(run, _), do: run

  defp put_consequence(run, %{} = c),
    do: Map.put(run, :consequence, c |> Enum.sort() |> Enum.map(fn {k, v} -> {k, v} end))

  defp put_consequence(run, _), do: run

  defp render_receipt(conn, {:ok, %Receipt{} = r}, extra),
    do: ok(conn, Map.merge(%{"receipt" => Receipt.to_map(r)}, extra) |> jsonable())

  defp render_receipt(conn, {:error, %{broken_term: t} = e}, _extra),
    do: refuse(conn, t, inspect(Map.delete(e, :broken_term), limit: 20))

  defp verify_claimed(conn, claimed, run) do
    replay = map(claimed["replay"])

    commands =
      for c <- list(replay["commands"]),
          is_map(c),
          do: %{cmd: c["cmd"], cwd: c["cwd"], exit: c["exit"]}

    auth = map(claimed["authority"])

    opts =
      [replay_commands: commands, evidence: map_size(map(replay["evidence"])) > 0]
      |> put_opt(:ceiling, auth["ceiling"])
      |> put_opt(:grant, auth["grant"])
      |> put_opt(:actor, auth["actor"])

    case Standing.receipt(run, opts) do
      {:error, %{broken_term: t} = e} ->
        refuse(conn, t, inspect(Map.delete(e, :broken_term), limit: 20))

      {:ok, fresh} ->
        cond do
          fresh.replay.ledger_digest != replay["ledger_digest"] ->
            refuse(conn, "R_replay_mismatch", "ledger_digest differs from replay of the run")

          fresh.standing.value != map(claimed["standing"])["value"] ->
            refuse(conn, "R_replay_mismatch", "standing value differs from replay of the run")

          true ->
            ok(conn, %{"verified" => true, "ledger_digest" => fresh.replay.ledger_digest})
        end
    end
  end

  defp jsonable(nil), do: nil
  defp jsonable(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp jsonable(%_{} = s), do: s |> Map.from_struct() |> jsonable()
  defp jsonable(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(a) when is_atom(a) and a not in [true, false], do: Atom.to_string(a)
  defp jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> jsonable()
  defp jsonable(v), do: v
end
