defmodule AshPPlan.MirrorSim.Fond do
  @moduledoc """
  Mirror-sim route handlers for the FOND area (`AshPPlan.FOND`, `AshPPlan.HTN` and
  `AshPPlan.FOND.*` except the `TLA` family).

  Mounted by the mirror router at `/fond/*` (the router strips the `/fond` prefix, so
  this plug dispatches on `conn.path_info`). Every route is `POST` with a JSON body and
  drives the REAL library function; there are no doubles. The one hand-written function
  is the independent checker passed to `AshPPlan.FOND.Differential.check/5`: a real TLC
  run is infeasible in-process, so `/differential` takes the checker verdict from the
  request (or, when omitted, derives it from the native validator).

  ## Wire conventions

    * States, actions and provider ids are JSON strings. FOND state/action strings are
      turned into atoms (`String.to_atom/1`, test env only) so the library sees the same
      terms the direct-call courts use; HTN facts/names stay strings.
    * Results are encoded by `enc/1`: atoms become strings, tuples become lists, `MapSet`s
      become sorted lists, structs become maps. `normalize/1` is `enc/1` followed by a
      JSON round trip and is what parity courts compare against.
    * Success is `200 {"ok": enc(result)}` (or `{"value": ...}` for non-tagged returns).
      Refusal is `422 {"refused":true,"broken_term":...,"reason":...,"detail": enc(error)}`.
      Malformed input is a typed 422 (`bad_input`), never a 500.
  """

  @behaviour Plug

  alias AshPPlan.FOND

  alias AshPPlan.FOND.{
    Corpus,
    Counterexample,
    Differential,
    PolicySupervisor,
    PolicySwitch,
    Projection,
    ProviderRegistry,
    Recovery,
    Replay,
    Subject,
    SupervisionSession,
    Synthesis,
    Trace
  }

  alias AshPPlan.HTN
  alias AshPPlan.MirrorSim.Json

  @default_corpus_count 5

  @doc "Surface inventory for the router's `GET /surfaces`."
  @spec surfaces() :: [map()]
  def surfaces do
    [
      {FOND, :new, 2, "domain"},
      {FOND, :check, 1, "check"},
      {FOND, :actions, 2, "actions"},
      {FOND, :outcomes, 3, "outcomes"},
      {FOND, :validate_policy, 4, "validate"},
      {FOND, :to_tla, 5, "to_tla"},
      {Synthesis, :synthesize, 3, "synthesize"},
      {Synthesis, :solvable_states, 2, "solvable_states"},
      {PolicySwitch, :select, 3, "select"},
      {PolicySupervisor, :start, 4, "supervisor/run"},
      {PolicySupervisor, :intent, 1, "supervisor/run"},
      {PolicySupervisor, :observe, 3, "supervisor/run"},
      {PolicySupervisor, :horizon_exceeded?, 1, "supervisor/run"},
      {PolicySupervisor, :replace_domain, 2, "supervisor/replace_domain"},
      {SupervisionSession, :start, 3, "session/run"},
      {SupervisionSession, :intent, 1, "session/run"},
      {SupervisionSession, :observe_outcome, 3, "session/run"},
      {SupervisionSession, :observe_provider_health, 4, "session/run"},
      {SupervisionSession, :replace_registry, 2, "session/run"},
      {SupervisionSession, :rebind, 1, "session/run"},
      {ProviderRegistry, :new, 1, "registry/run"},
      {ProviderRegistry, :put, 2, "registry/run"},
      {ProviderRegistry, :remove, 2, "registry/run"},
      {ProviderRegistry, :observe_health, 4, "registry/run"},
      {ProviderRegistry, :select, 2, "registry/run"},
      {Differential, :check, 5, "differential"},
      {Replay, :build, 5, "replay/build"},
      {Replay, :fingerprint, 1, "replay/fingerprint"},
      {Replay, :bind_fingerprint, 1, "replay/build"},
      {Replay, :hashable?, 1, "replay/hashable"},
      {Subject, :bind, 4, "subject/bind"},
      {Subject, :same?, 2, "subject/same"},
      {Trace, :edges, 2, "trace/edges"},
      {Trace, :shortest_goal_path, 3, "trace/shortest_goal_path"},
      {Projection, :portable, 4, "projection/portable"},
      {Counterexample, :from_validator, 2, "counterexample/from_validator"},
      {Counterexample, :from_checker, 2, "counterexample/from_checker"},
      {Counterexample, :classify, 1, "counterexample/classify"},
      {Recovery, :route, 1, "recovery/route"},
      {Corpus, :seeded, 2, "corpus/seeded"},
      {AshPPlan.Test.FONDCorpus, :cases, 0, "corpus/fixtures"},
      {AshPPlan.Test.FONDCorpus, :random, 2, "corpus/random"},
      {HTN, :new, 3, "htn/decompose"},
      {HTN, :decompose, 4, "htn/decompose"},
      {HTN, :plan, 4, "htn/plan"},
      {HTN, :strips_plan, 4, "htn/strips_plan"},
      {HTN, :applicable?, 2, "htn/applicable"},
      {HTN, :apply_action, 2, "htn/apply_action"}
    ]
    |> Enum.map(fn {mod, fun, arity, route} ->
      %{module: mod, fun: fun, arity: arity, route: "/fond/" <> route}
    end)
  end

  # ---------------------------------------------------------------------------
  # Encoding (also used by parity courts)
  # ---------------------------------------------------------------------------

  @doc "Encodes an Elixir term into JSON-encodable data (see moduledoc)."
  @spec enc(term()) :: term()
  def enc(nil), do: nil
  def enc(v) when is_boolean(v) or is_number(v), do: v
  def enc(v) when is_atom(v), do: Atom.to_string(v)
  def enc(v) when is_binary(v), do: if(String.valid?(v), do: v, else: Base.encode64(v))
  def enc(%MapSet{} = set), do: set |> Enum.map(&enc/1) |> Enum.sort()
  def enc(%_{} = struct), do: struct |> Map.from_struct() |> enc()
  def enc(map) when is_map(map), do: Map.new(map, fn {k, v} -> {enc_key(k), enc(v)} end)
  def enc(list) when is_list(list), do: Enum.map(list, &enc/1)
  def enc(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&enc/1)
  def enc(other), do: inspect(other)

  defp enc_key(k) when is_binary(k), do: k
  defp enc_key(k) when is_atom(k), do: Atom.to_string(k)
  defp enc_key(k), do: inspect(k)

  @doc "`enc/1` followed by a JSON round trip: exactly what a wire client decodes."
  @spec normalize(term()) :: term()
  def normalize(term), do: term |> enc() |> Jason.encode!() |> Jason.decode!()

  # ---------------------------------------------------------------------------
  # Plug
  # ---------------------------------------------------------------------------

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, _opts),
    do: route(conn.path_info, conn, params(conn))

  def call(conn, _opts), do: Json.refuse(conn, "method_not_allowed", "POST only", 405)

  defp params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp params(%Plug.Conn{body_params: %{} = p}), do: p
  defp params(_conn), do: %{}

  # --- FOND core -------------------------------------------------------------

  defp route(["domain"], conn, p), do: domain_route(conn, p, fn d, _ -> {:ok, d} end)

  defp route(["check"], conn, p) do
    domain_route(conn, p, fn d, _ ->
      case FOND.check(d) do
        :ok -> {:ok, :ok}
        {:error, _} = err -> err
      end
    end)
  end

  defp route(["actions"], conn, p),
    do: domain_route(conn, p, fn d, p -> {:value, FOND.actions(d, dec_state(p["state"]))} end)

  defp route(["outcomes"], conn, p) do
    domain_route(conn, p, fn d, p ->
      {:value, FOND.outcomes(d, dec_state(p["state"]), dec_state(p["action"]))}
    end)
  end

  defp route(["validate"], conn, p),
    do:
      domain_route(conn, p, fn d, p -> FOND.validate_policy(d, pol(p), init_state(p), mode(p)) end)

  defp route(["to_tla"], conn, p),
    do: domain_route(conn, p, fn d, p -> FOND.to_tla(d, pol(p), init_state(p), mode(p)) end)

  defp route(["synthesize"], conn, p),
    do: domain_route(conn, p, fn d, p -> Synthesis.synthesize(d, init_state(p), mode(p)) end)

  defp route(["solvable_states"], conn, p),
    do: domain_route(conn, p, fn d, p -> Synthesis.solvable_states(d, mode(p)) end)

  defp route(["select"], conn, p),
    do:
      domain_route(conn, p, fn d, p -> PolicySwitch.select(d, init_state(p), select_opts(p)) end)

  # --- supervisor / session / registry ---------------------------------------

  defp route(["supervisor", "run"], conn, p),
    do: domain_route(conn, p, fn d, p -> run_supervisor(d, p) end)

  defp route(["supervisor", "replace_domain"], conn, p),
    do: domain_route(conn, p, fn d, p -> run_replace(d, p) end)

  defp route(["session", "run"], conn, p),
    do: domain_route(conn, p, fn d, p -> run_session(d, p) end)

  defp route(["registry", "run"], conn, p), do: plain_route(conn, fn -> run_registry(p) end)

  # --- differential / replay / subject / projection --------------------------

  defp route(["differential"], conn, p) do
    domain_route(conn, p, fn d, p ->
      policy = pol(p)
      initial = init_state(p)
      mode = mode(p)

      checker =
        case p["checker"] do
          nil ->
            fn _rendered -> native_checker(d, policy, initial, mode) end

          given ->
            fn _rendered -> dec_error(given) end
        end

      Differential.check(d, policy, initial, mode, checker)
    end)
  end

  defp route(["replay", "build"], conn, p) do
    domain_route(conn, p, fn d, p ->
      opts = if Map.has_key?(p, "seed"), do: [seed: p["seed"]], else: []

      bind? = p["bind"] == true

      case Replay.build(d, pol(p), init_state(p), mode(p), opts) do
        {:ok, bundle} when bind? -> {:ok, Replay.bind_fingerprint(bundle)}
        other -> other
      end
    end)
  end

  defp route(["replay", "fingerprint"], conn, p),
    do: plain_route(conn, fn -> {:value, Replay.fingerprint(p["bundle"])} end)

  defp route(["replay", "hashable"], conn, p),
    do: plain_route(conn, fn -> {:value, Replay.hashable?(p["term"])} end)

  defp route(["subject", "bind"], conn, p),
    do:
      domain_route(conn, p, fn d, p -> {:ok, Subject.bind(d, pol(p), init_state(p), mode(p))} end)

  defp route(["subject", "same"], conn, p) do
    plain_route(conn, fn ->
      with {:ok, a} <- subject_of(p["a"]),
           {:ok, b} <- subject_of(p["b"]) do
        {:value, Subject.same?(a, b)}
      end
    end)
  end

  defp route(["trace", "edges"], conn, p),
    do: domain_route(conn, p, fn d, p -> {:value, Trace.edges(d, pol(p))} end)

  defp route(["trace", "shortest_goal_path"], conn, p),
    do: domain_route(conn, p, fn d, p -> Trace.shortest_goal_path(d, pol(p), init_state(p)) end)

  defp route(["projection", "portable"], conn, p),
    do:
      domain_route(conn, p, fn d, p ->
        {:ok, Projection.portable(d, pol(p), init_state(p), mode(p))}
      end)

  # --- counterexample / recovery ----------------------------------------------

  defp route(["counterexample", "from_validator"], conn, p) do
    plain_route(conn, fn ->
      with {:ok, subject} <- subject_of(p["subject"]) do
        {:value, Counterexample.from_validator(subject, dec_error(p["error"]))}
      end
    end)
  end

  defp route(["counterexample", "from_checker"], conn, p) do
    plain_route(conn, fn ->
      with {:ok, subject} <- subject_of(p["subject"]) do
        {:value, Counterexample.from_checker(subject, dec_error(p["result"]))}
      end
    end)
  end

  defp route(["counterexample", "classify"], conn, p),
    do: plain_route(conn, fn -> {:value, Counterexample.classify(dec_atomish(p["reason"]))} end)

  defp route(["recovery", "route"], conn, p),
    do: plain_route(conn, fn -> {:value, Recovery.route(recovery_input(p))} end)

  # --- corpus ----------------------------------------------------------------

  defp route(["corpus", "seeded"], conn, p) do
    plain_route(conn, fn -> {:value, seeded(p)} end)
  end

  defp route(["corpus", "verdicts"], conn, p) do
    plain_route(conn, fn ->
      verdicts =
        Enum.map(seeded(p), fn c ->
          %{id: c.id, verdicts: verdicts({c.transitions, c.goals, c.policy, c.initial})}
        end)

      {:value, verdicts}
    end)
  end

  defp route(["corpus", "random"], conn, p) do
    plain_route(conn, fn ->
      count = Map.get(p, "count", @default_corpus_count)

      cases =
        count
        |> AshPPlan.Test.FONDCorpus.random(random_seed(p))
        |> Enum.with_index()
        |> Enum.map(fn {{t, g, pol, i}, idx} ->
          %{index: idx, verdicts: verdicts({t, g, pol, i})}
        end)

      {:value, cases}
    end)
  end

  defp route(["corpus", "fixtures"], conn, _p) do
    plain_route(conn, fn ->
      cases =
        Enum.map(AshPPlan.Test.FONDCorpus.cases(), fn {name, {t, g, pol, i, expected}} ->
          v = verdicts({t, g, pol, i})

          %{
            name: name,
            expected: expected,
            actual: v.validate
          }
        end)

      {:value, cases}
    end)
  end

  # --- HTN -------------------------------------------------------------------

  defp route(["htn", "strips_plan"], conn, p) do
    plain_route(conn, fn ->
      HTN.strips_plan(
        MapSet.new(p["initial"] || []),
        MapSet.new(p["goal"] || []),
        p["actions"] || [],
        htn_opts(p)
      )
    end)
  end

  defp route(["htn", "decompose"], conn, p) do
    plain_route(conn, fn ->
      domain = HTN.new(p["actions"] || [], p["methods"] || [], p["metadata"] || %{})
      HTN.decompose(domain, p["tasks"] || [], p["initial"] || [], htn_opts(p))
    end)
  end

  defp route(["htn", "plan"], conn, p) do
    plain_route(conn, fn ->
      domain = HTN.new(p["actions"] || [], p["methods"] || [], p["metadata"] || %{})

      opts =
        case Map.fetch(p, "goal_state") do
          {:ok, goal} -> [goal_state: goal]
          :error -> []
        end

      HTN.plan(domain, p["tasks"] || [], p["initial"] || [], [mode: :htn] ++ opts ++ htn_opts(p))
    end)
  end

  defp route(["htn", "applicable"], conn, p) do
    plain_route(conn, fn ->
      {:value, HTN.applicable?(MapSet.new(p["state"] || []), HTN.Action.new(p["action"]))}
    end)
  end

  defp route(["htn", "apply_action"], conn, p) do
    plain_route(conn, fn ->
      {:ok, HTN.apply_action(MapSet.new(p["state"] || []), HTN.Action.new(p["action"]))}
    end)
  end

  defp route(_path, conn, _p),
    do: Json.refuse(conn, "unknown_route", "no fond route #{conn.request_path}", 404)

  # ---------------------------------------------------------------------------
  # Reply plumbing
  # ---------------------------------------------------------------------------

  defp domain_route(conn, p, fun) do
    result =
      safe(fn ->
        case build_domain(p) do
          {:ok, domain} -> fun.(domain, p)
          {:error, _} = err -> err
        end
      end)

    reply(conn, result)
  end

  defp plain_route(conn, fun), do: reply(conn, safe(fun))

  defp reply(conn, {:ok, v}), do: Json.send_json(conn, 200, %{"ok" => enc(v)})
  defp reply(conn, {:value, v}), do: Json.send_json(conn, 200, %{"value" => enc(v)})
  defp reply(conn, {:error, e}), do: Json.send_json(conn, 422, refusal_body(e))

  defp refusal_body(e) do
    broken_term(e)
    |> Json.refusal(inspect(e, limit: 50))
    |> Map.put("detail", enc(e))
  end

  defp broken_term(%{reason: r}) when is_atom(r) and not is_nil(r), do: Atom.to_string(r)
  defp broken_term(e) when is_atom(e) and not is_nil(e), do: Atom.to_string(e)

  defp broken_term(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)),
    do: Atom.to_string(elem(t, 0))

  defp broken_term(_), do: "error"

  defp safe(fun) do
    case fun.() do
      {tag, _} = result when tag in [:ok, :error, :value] ->
        result

      # three-tuples such as select/2 never reach here; library `{:error, _}` is two-tuple
      other ->
        {:value, other}
    end
  rescue
    e -> {:error, %{reason: :bad_input, exception: Exception.message(e)}}
  catch
    kind, reason ->
      {:error, %{reason: :bad_input, exception: "#{kind}: #{inspect(reason, limit: 10)}"}}
  end

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  defp build_domain(p) do
    transitions = dec_transitions(p["transitions"])
    goals = dec_goals(p["goals"])

    case p["raw_states"] do
      nil ->
        FOND.new(transitions, goals)

      states when is_list(states) ->
        {:ok,
         %FOND{
           states: states |> Enum.map(&dec_state/1) |> MapSet.new(),
           goals: MapSet.new(goals),
           transitions: transitions
         }}

      _ ->
        {:error, %{reason: :invalid_raw_states}}
    end
  end

  defp subject_of(%{} = sub) do
    with {:ok, d} <- build_domain(sub) do
      {:ok, Subject.bind(d, pol(sub), init_state(sub), mode(sub))}
    end
  end

  defp subject_of(other), do: {:error, %{reason: :invalid_subject, subject: other}}

  defp dec_state(v) when is_binary(v), do: String.to_atom(v)
  defp dec_state(v), do: v

  defp dec_atomish(v) when is_binary(v), do: String.to_atom(v)
  defp dec_atomish(v), do: v

  defp dec_transitions(m) when is_map(m),
    do: Map.new(m, fn {s, acts} -> {dec_state(s), dec_actions(acts)} end)

  defp dec_transitions(other), do: other

  defp dec_actions(a) when is_map(a),
    do: Map.new(a, fn {act, outs} -> {dec_state(act), dec_outs(outs)} end)

  defp dec_actions(other), do: other

  defp dec_outs(l) when is_list(l), do: Enum.map(l, &dec_state/1)
  defp dec_outs(other), do: other

  defp dec_goals(nil), do: []
  defp dec_goals(l) when is_list(l), do: Enum.map(l, &dec_state/1)
  defp dec_goals(other), do: other

  defp dec_policy(nil), do: %{}
  defp dec_policy(m) when is_map(m), do: Map.new(m, fn {k, v} -> {dec_state(k), dec_state(v)} end)
  defp dec_policy(other), do: other

  defp dec_mode(nil), do: :strong_cyclic
  defp dec_mode("strong"), do: :strong
  defp dec_mode("strong_cyclic"), do: :strong_cyclic
  defp dec_mode(other), do: other

  defp pol(p), do: dec_policy(p["policy"])
  defp init_state(p), do: dec_state(p["initial"])
  defp mode(p), do: dec_mode(p["mode"])

  @atom_valued ~w(reason kind verdict)

  defp dec_error(m) when is_map(m) do
    Map.new(m, fn {k, v} ->
      {String.to_atom(k), if(k in @atom_valued and is_binary(v), do: String.to_atom(v), else: v)}
    end)
  end

  defp dec_error(other), do: other

  defp select_opts(p) do
    opts = if Map.has_key?(p, "horizon"), do: [horizon: p["horizon"]], else: []

    if Map.has_key?(p, "modes") do
      modes =
        case p["modes"] do
          l when is_list(l) -> Enum.map(l, &dec_mode/1)
          other -> other
        end

      [modes: modes] ++ opts
    else
      opts
    end
  end

  defp horizon_opts(p), do: if(Map.has_key?(p, "horizon"), do: [horizon: p["horizon"]], else: [])

  defp htn_opts(p) do
    for key <- ["max_depth", "max_steps"], Map.has_key?(p, key) do
      {String.to_atom(key), p[key]}
    end
  end

  defp native_checker(d, policy, initial, mode) do
    case FOND.validate_policy(d, policy, initial, mode) do
      {:ok, _} -> %{verdict: :admitted}
      {:error, %{reason: reason}} -> %{verdict: :refused, kind: reason}
      {:error, _} -> %{verdict: :refused}
    end
  end

  defp recovery_input(%{"shape" => shape} = p) do
    case shape do
      "unsolvable" ->
        {:error, {:unsolvable, dec_mode(p["mode"]), Enum.map(p["witness"] || [], &dec_state/1)}}

      "horizon_exceeded" ->
        {:error, {:horizon_exceeded, p["horizon"], p["witness"]}}

      "missing_policy_action" ->
        {:error, {:missing_policy_action, dec_state(p["state"])}}

      "unadmitted_outcome" ->
        {:error, {:unadmitted_outcome, dec_state(p["state"]), dec_state(p["outcome"])}}

      "validator_error" ->
        {:error, dec_error(p["error"])}

      "bare_map" ->
        dec_error(p["error"])

      _ ->
        p["error"]
    end
  end

  defp recovery_input(p), do: p["error"]

  # ---------------------------------------------------------------------------
  # Supervisor
  # ---------------------------------------------------------------------------

  defp run_supervisor(d, p) do
    with {:ok, sup} <- PolicySupervisor.start(d, init_state(p), mode(p), horizon_opts(p)) do
      drive(sup, List.wrap(p["outcomes"]), [])
    end
  end

  defp drive(sup, [], steps) do
    {:ok,
     %{
       steps: Enum.reverse(steps),
       final_intent: PolicySupervisor.intent(sup),
       horizon_exceeded: PolicySupervisor.horizon_exceeded?(sup),
       supervisor: sup
     }}
  end

  defp drive(sup, [entry | rest], steps) do
    {outcome, epoch} = decode_entry(entry, sup.epoch)
    intent = PolicySupervisor.intent(sup)
    step = %{intent: intent, outcome: outcome}

    case PolicySupervisor.observe(sup, epoch, outcome) do
      {:ok, next} ->
        drive(next, rest, [step | steps])

      {:error, err} ->
        {:error,
         %{
           reason: error_tag(err),
           error: err,
           steps: Enum.reverse([step | steps]),
           supervisor: sup
         }}
    end
  end

  defp decode_entry(%{"outcome" => o} = m, current),
    do: {dec_state(o), Map.get(m, "epoch", current)}

  defp decode_entry(o, current), do: {dec_state(o), current}

  defp run_replace(d, p) do
    with {:ok, sup} <- PolicySupervisor.start(d, init_state(p), mode(p), horizon_opts(p)),
         {:ok, new_domain} <-
           FOND.new(
             dec_transitions(p["new_transitions"]),
             dec_goals(p["new_goals"] || p["goals"])
           ) do
      times = Map.get(p, "times", 1)
      replace_n(sup, new_domain, times)
    end
  end

  defp replace_n(sup, _domain, 0), do: {:ok, sup}

  defp replace_n(sup, domain, n) when is_integer(n) and n > 0 do
    case PolicySupervisor.replace_domain(sup, domain) do
      {:ok, next} -> replace_n(next, domain, n - 1)
      {:error, _} = err -> err
    end
  end

  defp error_tag(err) when is_tuple(err) and tuple_size(err) > 0 and is_atom(elem(err, 0)),
    do: elem(err, 0)

  defp error_tag(%{reason: r}) when is_atom(r), do: r
  defp error_tag(_), do: :error

  # ---------------------------------------------------------------------------
  # Session
  # ---------------------------------------------------------------------------

  defp run_session(d, p) do
    with {:ok, sup} <- PolicySupervisor.start(d, init_state(p), mode(p), horizon_opts(p)),
         registry = ProviderRegistry.new(dec_providers(p["providers"])),
         {:ok, session} <- SupervisionSession.start(sup, registry, List.wrap(p["requirements"])) do
      session_drive(session, List.wrap(p["events"]), [])
    end
  end

  defp session_drive(session, [], results),
    do: {:ok, %{events: Enum.reverse(results), session: session}}

  defp session_drive(session, [event | rest], results) do
    result = safe_event(fn -> session_event(session, event) end)

    next =
      case result do
        {:ok, %SupervisionSession{} = s} -> s
        _ -> session
      end

    session_drive(next, rest, [result | results])
  end

  defp session_event(session, %{"kind" => "intent"}), do: SupervisionSession.intent(session)
  defp session_event(session, %{"kind" => "rebind"}), do: SupervisionSession.rebind(session)

  defp session_event(session, %{"kind" => "outcome"} = ev) do
    SupervisionSession.observe_outcome(
      session,
      Map.get(ev, "epoch", session.policy.epoch),
      dec_state(ev["outcome"])
    )
  end

  defp session_event(session, %{"kind" => "health"} = ev) do
    SupervisionSession.observe_provider_health(
      session,
      Map.get(ev, "generation", session.provider_generation),
      ev["provider"],
      ev["healthy"]
    )
  end

  defp session_event(session, %{"kind" => "replace_registry"} = ev) do
    SupervisionSession.replace_registry(
      session,
      ProviderRegistry.new(dec_providers(ev["providers"]))
    )
  end

  defp session_event(_session, ev), do: {:error, {:unknown_event, ev}}

  # ---------------------------------------------------------------------------
  # Registry
  # ---------------------------------------------------------------------------

  defp run_registry(p) do
    registry = ProviderRegistry.new(dec_providers(p["providers"]))
    registry_drive(registry, List.wrap(p["ops"]), [])
  end

  defp registry_drive(registry, [], results),
    do: {:ok, %{results: Enum.reverse(results), registry: registry}}

  defp registry_drive(registry, [op | rest], results) do
    result = safe_event(fn -> registry_op(registry, op) end)

    next =
      case result do
        {:ok, %ProviderRegistry{} = r} -> r
        _ -> registry
      end

    registry_drive(next, rest, [result | results])
  end

  defp registry_op(registry, %{"op" => "put", "provider" => provider}),
    do: ProviderRegistry.put(registry, dec_provider(provider))

  defp registry_op(registry, %{"op" => "remove", "id" => id}),
    do: ProviderRegistry.remove(registry, id)

  defp registry_op(registry, %{"op" => "observe_health"} = op) do
    ProviderRegistry.observe_health(
      registry,
      Map.get(op, "generation", registry.generation),
      op["id"],
      op["healthy"]
    )
  end

  defp registry_op(registry, %{"op" => "select"} = op),
    do: ProviderRegistry.select(registry, List.wrap(op["requirements"]))

  defp registry_op(_registry, op), do: {:error, {:unknown_op, op}}

  defp safe_event(fun) do
    fun.()
  rescue
    e -> {:error, %{reason: :bad_input, exception: Exception.message(e)}}
  catch
    kind, reason ->
      {:error, %{reason: :bad_input, exception: "#{kind}: #{inspect(reason, limit: 10)}"}}
  end

  defp dec_providers(nil), do: []
  defp dec_providers(l) when is_list(l), do: Enum.map(l, &dec_provider/1)
  defp dec_providers(other), do: other

  defp dec_provider(%{} = m) do
    [{"id", :id}, {"capabilities", :capabilities}, {"cost", :cost}, {"healthy", :healthy?}]
    |> Enum.reduce(%{}, fn {wire, key}, acc ->
      case Map.fetch(m, wire) do
        {:ok, v} -> Map.put(acc, key, v)
        :error -> acc
      end
    end)
  end

  defp dec_provider(other), do: other

  # ---------------------------------------------------------------------------
  # Corpus
  # ---------------------------------------------------------------------------

  defp seeded(p) do
    count = Map.get(p, "count", @default_corpus_count)

    case p["seed"] do
      [a, b, c] -> Corpus.seeded(count, {a, b, c})
      _ -> Corpus.seeded(count)
    end
  end

  defp random_seed(p) do
    case p["seed"] do
      [a, b, c] -> {a, b, c}
      _ -> {1, 2, 3}
    end
  end

  defp verdicts({transitions, goals, policy, initial}) do
    case FOND.new(transitions, goals) do
      {:ok, d} ->
        %{
          validate: %{
            strong: validate_verdict(d, policy, initial, :strong),
            strong_cyclic: validate_verdict(d, policy, initial, :strong_cyclic)
          },
          synthesize: %{
            strong: synth_verdict(d, initial, :strong),
            strong_cyclic: synth_verdict(d, initial, :strong_cyclic)
          }
        }

      {:error, e} ->
        %{invalid_domain: e}
    end
  end

  defp validate_verdict(d, policy, initial, mode) do
    case FOND.validate_policy(d, policy, initial, mode) do
      {:ok, _} -> :admitted
      {:error, _} -> :refused
    end
  end

  defp synth_verdict(d, initial, mode) do
    case Synthesis.synthesize(d, initial, mode) do
      {:ok, policy} ->
        %{
          verdict: :admitted,
          validates: match?({:ok, _}, FOND.validate_policy(d, policy, initial, mode))
        }

      {:error, e} ->
        %{verdict: :refused, error: error_tag(e)}
    end
  end
end
