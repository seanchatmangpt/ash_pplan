defmodule AshPPlan.MirrorSim.FondTest do
  @moduledoc """
  Wire courts for the mirror-sim FOND area. Every court talks to the real listening
  socket (`:httpc`) and compares the response against a direct call into the real
  library. No doubles; the only simulated input is the independent-checker verdict
  for `/differential` (a real TLC run is infeasible in-process).
  """
  use ExUnit.Case, async: false

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
  alias AshPPlan.MirrorSim.{Fond, Server}
  alias AshPPlan.Test.FONDCorpus

  @modes [:strong, :strong_cyclic]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    pid = start_supervised!({Server, port: 0})
    %{base: Server.base_url(pid)}
  end

  setup %{base: base} do
    Process.put(:mirror_base, base)
    :ok
  end

  # -- wire helpers -----------------------------------------------------------

  defp post_raw(path, raw) do
    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(Process.get(:mirror_base) <> path), [], ~c"application/json", raw},
        [],
        body_format: :binary
      )

    {status, resp}
  end

  defp post(path, map) do
    {status, resp} = post_raw("/fond" <> path, Jason.encode!(map))
    {status, Jason.decode!(resp)}
  end

  defp norm(term), do: Fond.normalize(term)

  defp parity(path, body, direct) do
    {status, resp} = post(path, body)

    case direct do
      {:ok, v} ->
        assert {path, status, resp["ok"]} == {path, 200, norm(v)}

      {:value, v} ->
        assert {path, status, resp["value"]} == {path, 200, norm(v)}

      {:error, e} ->
        assert {path, status} == {path, 422}
        assert resp["detail"] == norm(e)
    end

    resp
  end

  defp wire(path, {t, g, pol, i}, mode),
    do: wire(path, {t, g, pol, i, nil}, mode)

  defp wire(_path, {t, g, pol, i, _expected}, mode) do
    %{
      "transitions" => Fond.enc(t),
      "goals" => Fond.enc(g),
      "policy" => Fond.enc(pol),
      "initial" => Fond.enc(i),
      "mode" => Atom.to_string(mode)
    }
  end

  defp dom({t, g, _pol, _i, _e}), do: dom({t, g, nil, nil})

  defp dom({t, g, _pol, _i}) do
    {:ok, d} = FOND.new(t, g)
    d
  end

  defp cases, do: FONDCorpus.cases()
  defp case!(name), do: Keyword.fetch!(cases(), name)

  defp retry_cycle, do: case!(:retry_cycle)
  defp dead_end, do: case!(:dead_end)

  defp tag(status_resp), do: status_resp |> elem(1) |> Map.get("broken_term")

  # -- surfaces ---------------------------------------------------------------

  describe "surfaces" do
    test "every declared surface is an exported function of its module" do
      for %{module: mod, fun: fun, arity: arity} <- Fond.surfaces() do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loaded"
        assert function_exported?(mod, fun, arity), "#{inspect(mod)}.#{fun}/#{arity} missing"
      end
    end

    test "router lists fond as mounted with the same surface count", %{base: base} do
      {:ok, {{_, 200, _}, _h, body}} =
        :httpc.request(:get, {String.to_charlist(base <> "/surfaces"), []}, [],
          body_format: :binary
        )

      mounted = Jason.decode!(body)["mounted"]
      assert %{"surfaces" => surfaces} = Enum.find(mounted, &(&1["area"] == "fond"))
      assert length(surfaces) == length(Fond.surfaces())
    end

    test "every surface route is routed (never unknown_route) and never 5xx on empty body" do
      for route <- routes() do
        {status, resp} = post_raw(route, "{}")
        assert status in [200, 422], "#{route} -> #{status}"
        refute Jason.decode!(resp)["broken_term"] == "unknown_route", route
      end
    end

    test "garbage bodies never produce a 5xx on any route" do
      bodies = [
        "{}",
        ~s({"transitions":5}),
        ~s({"transitions":{"a":{"x":["b"]}},"goals":["b"],"policy":5,"initial":7,"mode":9}),
        "[1,2]",
        ~s("str"),
        "null",
        "{bad"
      ]

      for route <- routes(), raw <- bodies do
        {status, _} = post_raw(route, raw)
        assert status in 200..499, "#{route} #{raw} -> #{status}"
      end
    end

    test "unknown fond route is a typed 404" do
      {404, resp} = post_raw("/fond/no_such", "{}")
      assert Jason.decode!(resp)["broken_term"] == "unknown_route"
    end
  end

  defp routes, do: Fond.surfaces() |> Enum.map(& &1.route) |> Enum.uniq()

  # -- core domain / validation ----------------------------------------------

  describe "FOND core" do
    test "domain, actions and outcomes match direct calls" do
      {t, g, _, _, _} = case!(:two_state_retry)
      {:ok, d} = FOND.new(t, g)
      body = %{"transitions" => Fond.enc(t), "goals" => Fond.enc(g)}

      parity("/domain", body, {:ok, d})
      parity("/check", body, {:ok, :ok})
      parity("/actions", Map.put(body, "state", "s0"), {:value, FOND.actions(d, :s0)})

      parity(
        "/outcomes",
        Map.merge(body, %{"state" => "s0", "action" => "try"}),
        {:value, FOND.outcomes(d, :s0, :try)}
      )
    end

    test "hand-written corpus: wire verdict equals the pinned expectation and direct call" do
      for {name, {t, g, pol, i, expected}} = entry <- cases(), mode <- @modes do
        d = dom(elem(entry, 1))
        direct = FOND.validate_policy(d, pol, i, mode)
        resp = parity("/validate", wire("/validate", {t, g, pol, i}, mode), direct)

        wire_verdict = if resp["ok"], do: :admitted, else: :refused
        assert {name, mode, wire_verdict} == {name, mode, Map.fetch!(expected, mode)}
      end
    end

    test "seeded random corpus: validate parity, both verdict kinds exercised" do
      random = FONDCorpus.random(25, {1, 2, 3})

      verdicts =
        for {_t, _g, pol, i} = c <- random, mode <- @modes do
          d = dom(c)
          direct = FOND.validate_policy(d, pol, i, mode)
          parity("/validate", wire("/validate", c, mode), direct)
          elem(direct, 0)
        end

      assert :ok in verdicts and :error in verdicts
    end

    test "typed refusals carry their broken_term" do
      cyc = wire("/validate", retry_cycle(), :strong)
      assert tag(post("/validate", cyc)) == "not_strong"
      assert {422, _} = post("/validate", cyc)

      # dead_end leaves `failed` undecided, so the walk refuses first with
      # missing_policy_action; closed_trap has a total policy that never reaches the goal.
      assert tag(post("/validate", wire("/validate", dead_end(), :strong_cyclic))) ==
               "missing_policy_action"

      assert tag(post("/validate", wire("/validate", case!(:closed_trap), :strong_cyclic))) ==
               "not_strong_cyclic"

      assert tag(post("/validate", wire("/validate", case!(:missing_decision), :strong))) ==
               "missing_policy_action"

      assert tag(post("/validate", wire("/validate", case!(:unavailable_action), :strong))) ==
               "unavailable_policy_action"

      assert tag(post("/validate", Map.put(cyc, "mode", "zzz"))) == "invalid_policy_request"
      assert tag(post("/validate", Map.put(cyc, "initial", "zzz"))) == "unknown_initial_state"

      assert tag(post("/validate", Map.put(cyc, "policy", %{"nope" => "x"}))) ==
               "unknown_policy_states"

      assert tag(post("/domain", %{"transitions" => %{"a" => %{"x" => []}}})) ==
               "empty_nondeterministic_outcome"

      assert tag(post("/domain", %{"transitions" => 5})) == "invalid_transition_relation"
      assert tag(post("/domain", %{"transitions" => %{}, "goals" => "x"})) == "invalid_goals"
    end

    test "hand-built domains that bypass new/2 are refused by check and synthesis" do
      undeclared = %{
        "transitions" => %{"a" => %{"x" => ["b"]}},
        "goals" => ["b"],
        "raw_states" => ["a"],
        "initial" => "a"
      }

      assert {422, resp} = post("/check", undeclared)
      assert resp["broken_term"] == "invalid_domain"
      assert resp["detail"]["detail"] == "undeclared_states"

      unnormalized = %{
        "transitions" => %{"a" => %{"x" => ["b", "a"]}},
        "goals" => ["b"],
        "raw_states" => ["a", "b"],
        "initial" => "a"
      }

      assert {422, resp} = post("/check", unnormalized)
      assert resp["detail"]["detail"] == "unnormalized_transitions"

      assert {422, resp} = post("/synthesize", undeclared)
      assert resp["broken_term"] == "invalid_domain"

      ok = %{undeclared | "raw_states" => ["a", "b"]}
      assert {200, %{"ok" => "ok"}} = post("/check", ok)
    end

    test "to_tla renders the same model as a direct call" do
      {t, g, pol, i, _} = retry_cycle()
      d = dom(retry_cycle())

      for mode <- @modes do
        parity("/to_tla", wire("/to_tla", {t, g, pol, i}, mode), FOND.to_tla(d, pol, i, mode))
      end
    end
  end

  # -- synthesis / switch -----------------------------------------------------

  describe "synthesis and switch" do
    test "synthesize and solvable_states match direct calls; synthesized policy validates over the wire" do
      for {name, {t, g, _pol, i, _e}} = entry <- cases(), mode <- @modes do
        d = dom(elem(entry, 1))
        body = wire("/synthesize", {t, g, %{}, i}, mode)

        resp = parity("/synthesize", body, Synthesis.synthesize(d, i, mode))
        parity("/solvable_states", body, Synthesis.solvable_states(d, mode))

        if resp["ok"] do
          validate = Map.put(body, "policy", resp["ok"])
          assert {name, mode, {200, _}} = {name, mode, post("/validate", validate)}
        end
      end
    end

    test "synthesis refusals are typed" do
      body = wire("/synthesize", dead_end(), :strong)
      assert {422, resp} = post("/synthesize", body)
      assert resp["broken_term"] == "unsolvable"
      assert ["unsolvable", "strong", witness] = resp["detail"]
      assert "pending" in witness

      assert tag(post("/synthesize", Map.put(body, "initial", "zzz"))) == "unknown_initial_state"
      assert tag(post("/synthesize", Map.put(body, "mode", "zzz"))) == "invalid_mode"
    end

    test "select falls back across modes and refuses with the horizon" do
      {t, g, pol, i, _} = retry_cycle()
      d = dom(retry_cycle())
      body = wire("/select", {t, g, pol, i}, :strong)

      resp = parity("/select", body, PolicySwitch.select(d, i, []))
      assert resp["ok"]["mode"] == "strong_cyclic"
      assert [%{} | _] = [resp["ok"]["subject"]]

      {dt, dg, dpol, di, _} = dead_end()
      dd = dom(dead_end())
      dbody = wire("/select", {dt, dg, dpol, di}, :strong)

      assert {422, none} = post("/select", dbody)
      assert none["broken_term"] == "no_admitted_policy"
      parity("/select", dbody, PolicySwitch.select(dd, di, []))

      horizon = Map.put(dbody, "horizon", 1)
      assert {422, hz} = post("/select", horizon)
      assert hz["broken_term"] == "horizon_exceeded"
      assert ["horizon_exceeded", 1, witness] = hz["detail"]
      assert witness =~ ~r/^[0-9a-f]{64}$/
      parity("/select", horizon, PolicySwitch.select(dd, di, horizon: 1))

      only_strong = Map.put(body, "modes", ["strong"])
      parity("/select", only_strong, PolicySwitch.select(d, i, modes: [:strong]))
      assert tag(post("/select", only_strong)) == "no_admitted_policy"
    end
  end

  # -- supervisor / session / registry ---------------------------------------

  describe "supervisor" do
    defp sup_body(extra) do
      {t, g, _pol, _i, _} = retry_cycle()

      Map.merge(
        %{
          "transitions" => Fond.enc(t),
          "goals" => Fond.enc(g),
          "initial" => "pending",
          "mode" => "strong_cyclic"
        },
        extra
      )
    end

    test "outcome stream reaches the goal and matches direct observation" do
      d = dom(retry_cycle())
      {:ok, s0} = PolicySupervisor.start(d, :pending, :strong_cyclic, [])
      {:ok, s1} = PolicySupervisor.observe(s0, 0, :pending)
      {:ok, s2} = PolicySupervisor.observe(s1, 1, :pending)
      {:ok, s3} = PolicySupervisor.observe(s2, 2, :succeeded)

      {200, resp} =
        post("/supervisor/run", sup_body(%{"outcomes" => ["pending", "pending", "succeeded"]}))

      run = resp["ok"]
      assert run["supervisor"] == norm(s3)
      assert run["supervisor"]["epoch"] == 3
      assert run["final_intent"] == norm(PolicySupervisor.intent(s3))
      assert ["ok", %{"kind" => "goal"}] = run["final_intent"]
      assert run["horizon_exceeded"] == false
      assert length(run["steps"]) == 3

      assert hd(run["steps"])["intent"] == norm(PolicySupervisor.intent(s0))
    end

    test "stale epoch, unadmitted outcome and exhausted horizon are typed refusals" do
      d = dom(retry_cycle())
      {:ok, s0} = PolicySupervisor.start(d, :pending, :strong_cyclic, horizon: 2)
      {:ok, s1} = PolicySupervisor.observe(s0, 0, :pending)
      {:ok, s2} = PolicySupervisor.observe(s1, 1, :pending)
      {:error, {:horizon_exceeded, 2, _w} = exhausted} = PolicySupervisor.observe(s2, 2, :pending)

      assert {422, stale} =
               post(
                 "/supervisor/run",
                 sup_body(%{"outcomes" => [%{"outcome" => "pending", "epoch" => 5}]})
               )

      assert stale["broken_term"] == "stale_epoch"
      assert stale["detail"]["error"] == norm({:stale_epoch, 5, 0})

      assert {422, bad} = post("/supervisor/run", sup_body(%{"outcomes" => ["broken"]}))
      assert bad["broken_term"] == "unadmitted_outcome"
      assert bad["detail"]["error"] == norm({:unadmitted_outcome, :pending, :broken})

      assert {422, hz} =
               post(
                 "/supervisor/run",
                 sup_body(%{"horizon" => 2, "outcomes" => ["pending", "pending", "pending"]})
               )

      assert hz["broken_term"] == "horizon_exceeded"
      assert hz["detail"]["error"] == norm(exhausted)
      assert length(hz["detail"]["steps"]) == 3

      assert {422, inv} = post("/supervisor/run", sup_body(%{"horizon" => -1}))
      assert inv["broken_term"] == "invalid_horizon"
    end

    test "replace_domain succeeds, burns attempts, and refuses unsolvable domains typed" do
      {t, _g, _, _, _} = retry_cycle()
      same = sup_body(%{"new_transitions" => Fond.enc(t)})

      assert {200, ok} = post("/supervisor/replace_domain", same)
      assert ok["ok"]["epoch"] == 1 and ok["ok"]["attempts"] == 1

      assert {200, twice} = post("/supervisor/replace_domain", Map.put(same, "times", 2))
      assert twice["ok"]["epoch"] == 2 and twice["ok"]["attempts"] == 2

      broken =
        sup_body(%{
          "new_transitions" => %{
            "pending" => %{"attempt" => ["broken"]},
            "broken" => %{},
            "succeeded" => %{}
          }
        })

      assert {422, failed} = post("/supervisor/replace_domain", broken)
      assert failed["broken_term"] == "synthesis_failed"
      assert ["synthesis_failed", _reason, burned] = failed["detail"]
      assert burned["attempts"] == 1

      assert {422, hz} = post("/supervisor/replace_domain", Map.put(broken, "horizon", 1))
      assert ["horizon_exceeded", 1, witness] = hz["detail"]
      assert witness =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "provider registry and supervision session" do
    @providers [
      %{"id" => "a", "capabilities" => ["x"], "cost" => 2},
      %{"id" => "b", "capabilities" => ["x", "y"], "cost" => 1}
    ]

    defp direct_registry do
      ProviderRegistry.new([
        %{id: "a", capabilities: ["x"], cost: 2},
        %{id: "b", capabilities: ["x", "y"], cost: 1}
      ])
    end

    test "registry op script matches direct calls, including stale and invalid operations" do
      reg0 = direct_registry()
      r1 = ProviderRegistry.select(reg0, ["x"])
      {:ok, reg1} = ProviderRegistry.observe_health(reg0, 2, "b", false)
      r3 = ProviderRegistry.select(reg1, ["x"])
      r4 = ProviderRegistry.observe_health(reg1, 0, "a", true)
      r5 = ProviderRegistry.put(reg1, %{cost: 1})
      r6 = ProviderRegistry.remove(reg1, "ghost")
      {:ok, reg2} = ProviderRegistry.put(reg1, %{id: "c", capabilities: ["x"], cost: 0})
      r8 = ProviderRegistry.select(reg2, ["x"])
      r9 = ProviderRegistry.select(reg2, ["zzz"])

      ops = [
        %{"op" => "select", "requirements" => ["x"]},
        %{"op" => "observe_health", "id" => "b", "healthy" => false},
        %{"op" => "select", "requirements" => ["x"]},
        %{"op" => "observe_health", "generation" => 0, "id" => "a", "healthy" => true},
        %{"op" => "put", "provider" => %{"cost" => 1}},
        %{"op" => "remove", "id" => "ghost"},
        %{"op" => "put", "provider" => %{"id" => "c", "capabilities" => ["x"], "cost" => 0}},
        %{"op" => "select", "requirements" => ["x"]},
        %{"op" => "select", "requirements" => ["zzz"]},
        %{"op" => "observe_health", "id" => "a", "healthy" => "yes"},
        %{"op" => "frobnicate"}
      ]

      {200, resp} = post("/registry/run", %{"providers" => @providers, "ops" => ops})
      results = resp["ok"]["results"]

      expected = [r1, {:ok, reg1}, r3, r4, r5, r6, {:ok, reg2}, r8, r9]
      assert Enum.take(results, 9) == norm(expected)
      assert resp["ok"]["registry"] == norm(reg2)

      assert ["error", %{"reason" => "bad_input"}] = Enum.at(results, 9)
      assert ["error", ["unknown_op", _]] = Enum.at(results, 10)

      assert [
               "ok",
               %{"id" => "b"},
               2
             ] = hd(results)
    end

    test "invalid provider at construction is a typed refusal, not a 500" do
      assert {422, resp} = post("/registry/run", %{"providers" => [%{"cost" => 1}]})
      assert resp["broken_term"] == "bad_input"
    end

    test "session routes intents through provider substitution and fences stale tokens" do
      d = dom(retry_cycle())
      {:ok, sup} = PolicySupervisor.start(d, :pending, :strong_cyclic, [])
      {:ok, s0} = SupervisionSession.start(sup, direct_registry(), ["x"])
      r1 = SupervisionSession.intent(s0)
      r2 = SupervisionSession.observe_provider_health(s0, s0.provider_generation, "b", false)
      {:ok, s1} = r2
      r3 = SupervisionSession.intent(s1)
      r4 = SupervisionSession.observe_outcome(s1, 0, :pending)
      {:ok, s2} = r4
      r5 = SupervisionSession.observe_outcome(s2, 0, :pending)
      r6 = SupervisionSession.observe_provider_health(s2, 0, "a", true)

      {t, g, _, _, _} = retry_cycle()

      body = %{
        "transitions" => Fond.enc(t),
        "goals" => Fond.enc(g),
        "initial" => "pending",
        "mode" => "strong_cyclic",
        "providers" => @providers,
        "requirements" => ["x"],
        "events" => [
          %{"kind" => "intent"},
          %{"kind" => "health", "provider" => "b", "healthy" => false},
          %{"kind" => "intent"},
          %{"kind" => "outcome", "epoch" => 0, "outcome" => "pending"},
          %{"kind" => "outcome", "epoch" => 0, "outcome" => "pending"},
          %{"kind" => "health", "generation" => 0, "provider" => "a", "healthy" => true},
          %{"kind" => "bogus"}
        ]
      }

      {200, resp} = post("/session/run", body)
      events = resp["ok"]["events"]

      assert Enum.take(events, 6) == norm([r1, r2, r3, r4, r5, r6])
      assert resp["ok"]["session"] == norm(s2)
      assert get_in(Enum.at(events, 0), [Access.at(1), "provider", "id"]) == "b"
      assert get_in(Enum.at(events, 2), [Access.at(1), "provider", "id"]) == "a"
      assert ["error", ["stale_epoch", 0, 1]] = Enum.at(events, 4)
      assert ["error", ["stale_generation", 0, _]] = Enum.at(events, 5)
      assert ["error", ["unknown_event", _]] = Enum.at(events, 6)
    end

    test "session with no matching provider is refused at start" do
      {t, g, _, _, _} = retry_cycle()

      body = %{
        "transitions" => Fond.enc(t),
        "goals" => Fond.enc(g),
        "initial" => "pending",
        "providers" => @providers,
        "requirements" => ["nonexistent"]
      }

      assert {422, resp} = post("/session/run", body)
      assert resp["broken_term"] == "no_provider"
    end
  end

  # -- differential / replay / subject / counterexample / recovery ------------

  describe "differential" do
    test "agreement, mismatch and agreeing refusal match direct calls" do
      {t, g, pol, i, _} = retry_cycle()
      d = dom(retry_cycle())

      cyclic = wire("/differential", {t, g, pol, i}, :strong_cyclic)

      parity(
        "/differential",
        cyclic,
        Differential.check(d, pol, i, :strong_cyclic, fn _ -> %{verdict: :admitted} end)
      )

      strong = wire("/differential", {t, g, pol, i}, :strong)

      mismatch = Map.put(strong, "checker", %{"verdict" => "admitted"})
      assert {422, resp} = post("/differential", mismatch)
      assert resp["broken_term"] == "differential_mismatch"

      parity(
        "/differential",
        mismatch,
        Differential.check(d, pol, i, :strong, fn _ -> %{verdict: :admitted} end)
      )

      agree = Map.put(strong, "checker", %{"verdict" => "refused", "kind" => "liveness"})

      resp =
        parity(
          "/differential",
          agree,
          Differential.check(d, pol, i, :strong, fn _ -> %{verdict: :refused, kind: :liveness} end)
        )

      assert resp["ok"]["agreement"] == true
      assert length(resp["ok"]["counterexamples"]) == 2

      # default checker mirrors the native validator, so every corpus case agrees
      for {_name, {t, g, pol, i, _}} = entry <- cases(), mode <- @modes do
        dd = dom(elem(entry, 1))

        mirror = fn _rendered ->
          case FOND.validate_policy(dd, pol, i, mode) do
            {:ok, _} -> %{verdict: :admitted}
            {:error, %{reason: reason}} -> %{verdict: :refused, kind: reason}
          end
        end

        parity(
          "/differential",
          wire("/differential", {t, g, pol, i}, mode),
          Differential.check(dd, pol, i, mode, mirror)
        )
      end
    end
  end

  describe "replay" do
    test "build is deterministic, matches direct, and the fingerprint tracks the seed" do
      {t, g, pol, i, _} = retry_cycle()
      d = dom(retry_cycle())
      body = wire("/replay/build", {t, g, pol, i}, :strong_cyclic)

      direct = Replay.build(d, pol, i, :strong_cyclic, [])
      first = parity("/replay/build", body, direct)
      assert post("/replay/build", body) == {200, first}

      seeded_a = body |> Map.put("seed", [1, 2]) |> Map.put("bind", true)
      seeded_b = body |> Map.put("seed", [1, 3]) |> Map.put("bind", true)

      {:ok, bundle} = Replay.build(d, pol, i, :strong_cyclic, seed: [1, 2])
      a = parity("/replay/build", seeded_a, {:ok, Replay.bind_fingerprint(bundle)})
      assert {200, b} = post("/replay/build", seeded_b)

      assert "sha256:" <> hex = a["ok"]["replay_fingerprint"]
      assert hex =~ ~r/^[0-9a-f]{64}$/
      refute a["ok"]["replay_fingerprint"] == b["ok"]["replay_fingerprint"]
    end

    test "fingerprint and hashable endpoints match direct calls" do
      one = %{"a" => 1}
      two = %{"a" => 2}

      f1 = parity("/replay/fingerprint", %{"bundle" => one}, {:value, Replay.fingerprint(one)})
      f2 = parity("/replay/fingerprint", %{"bundle" => two}, {:value, Replay.fingerprint(two)})
      refute f1["value"] == f2["value"]

      term = [1, %{"a" => 2}]
      parity("/replay/hashable", %{"term" => term}, {:value, Replay.hashable?(term)})
      assert {422, _} = post("/replay/fingerprint", %{"bundle" => "not a map"})
    end
  end

  describe "subject, projection, trace" do
    test "match direct calls over the whole hand corpus" do
      for {name, {t, g, pol, i, _}} = entry <- cases() do
        d = dom(elem(entry, 1))
        body = wire("/x", {t, g, pol, i}, :strong_cyclic)

        parity("/subject/bind", body, {:ok, Subject.bind(d, pol, i, :strong_cyclic)})

        parity(
          "/projection/portable",
          body,
          {:ok, Projection.portable(d, pol, i, :strong_cyclic)}
        )

        parity("/trace/edges", body, {:value, Trace.edges(d, pol)})

        assert name
        parity("/trace/shortest_goal_path", body, Trace.shortest_goal_path(d, pol, i))
      end
    end

    test "subject identity ignores spelling but not content" do
      {t, g, pol, i, _} = case!(:two_state_retry)
      a = wire("/x", {t, g, pol, i}, :strong_cyclic)

      reordered =
        a
        |> put_in(["transitions", "s0", "try"], ["s1", "s0"])
        |> Map.put("goals", Enum.reverse(a["goals"]))

      assert {200, %{"value" => true}} = post("/subject/same", %{"a" => a, "b" => reordered})

      assert {200, %{"value" => false}} =
               post("/subject/same", %{"a" => a, "b" => Map.put(a, "initial", "s1")})

      assert {200, %{"value" => false}} =
               post("/subject/same", %{"a" => a, "b" => Map.put(a, "mode", "strong")})

      assert {422, _} = post("/subject/same", %{"a" => a, "b" => 5})
    end

    test "projection authority is NONE" do
      {200, resp} = post("/projection/portable", wire("/x", retry_cycle(), :strong_cyclic))
      assert resp["ok"]["authority"] == "NONE"
    end
  end

  describe "counterexample and recovery" do
    test "counterexamples are classified and bound to the subject id" do
      c = retry_cycle()
      {t, g, pol, i, _} = c
      subject_body = wire("/x", {t, g, pol, i}, :strong)
      subject = Subject.bind(dom(c), pol, i, :strong)

      err = %{"reason" => "not_strong", "witness" => "w"}

      resp =
        parity(
          "/counterexample/from_validator",
          %{"subject" => subject_body, "error" => err},
          {:value, Counterexample.from_validator(subject, %{reason: :not_strong, witness: "w"})}
        )

      assert resp["value"]["class"] == "liveness"
      assert resp["value"]["subject_id"] == subject.id

      parity(
        "/counterexample/from_validator",
        %{"subject" => subject_body, "error" => %{}},
        {:value, Counterexample.from_validator(subject, %{})}
      )

      checker = %{"verdict" => "refused", "kind" => "deadlock"}

      resp =
        parity(
          "/counterexample/from_checker",
          %{"subject" => subject_body, "result" => checker},
          {:value, Counterexample.from_checker(subject, %{verdict: :refused, kind: :deadlock})}
        )

      assert resp["value"]["class"] == "deadlock"

      admitted =
        parity(
          "/counterexample/from_checker",
          %{"subject" => subject_body, "result" => %{"verdict" => "admitted"}},
          {:value, Counterexample.from_checker(subject, %{verdict: :admitted})}
        )

      assert admitted["value"]["class"] == "unclassifiable_checker_result"
    end

    test "classify table" do
      table = [
        {"not_strong", "liveness"},
        {"not_strong_cyclic", "liveness"},
        {"liveness", "liveness"},
        {"missing_policy_action", "deadlock"},
        {"unavailable_policy_action", "deadlock"},
        {"deadlock", "deadlock"},
        {"unknown_initial_state", "identity"},
        {"invalid_policy_request", "shape"},
        {"something_else", "something_else"}
      ]

      for {reason, class} <- table do
        assert {200, %{"value" => ^class}} =
                 post("/counterexample/classify", %{"reason" => reason})
      end

      assert {200, %{"value" => "unknown"}} = post("/counterexample/classify", %{"reason" => 5})
    end

    test "recovery routes every typed failure to its construction edge" do
      table = [
        {%{"shape" => "unsolvable", "mode" => "strong", "witness" => ["a"]},
         "respecify_or_expand_domain"},
        {%{"shape" => "horizon_exceeded", "horizon" => 3, "witness" => "w"}, "epistemic_horizon"},
        {%{"shape" => "missing_policy_action", "state" => "a"}, "resynthesize"},
        {%{"shape" => "unadmitted_outcome", "state" => "a", "outcome" => "b"}, "resynthesize"},
        {%{"shape" => "validator_error", "error" => %{"reason" => "not_strong"}},
         "try_strong_cyclic"},
        {%{"shape" => "validator_error", "error" => %{"reason" => "not_strong_cyclic"}},
         "resynthesize"},
        {%{"shape" => "validator_error", "error" => %{"reason" => "unavailable_policy_action"}},
         "resynthesize"},
        {%{"shape" => "validator_error", "error" => %{"reason" => "unknown_initial_state"}},
         "refuse_identity"},
        {%{"shape" => "validator_error", "error" => %{"reason" => "invalid_policy_request"}},
         "refuse_shape"},
        {%{"shape" => "bare_map", "error" => %{"reason" => "not_strong"}}, "try_strong_cyclic"},
        {%{"shape" => "other", "error" => "x"}, "refuse_unknown"}
      ]

      for {input, action} <- table do
        assert {200, %{"value" => %{"action" => ^action}}} = post("/recovery/route", input)
      end

      parity(
        "/recovery/route",
        %{"shape" => "unsolvable", "mode" => "strong", "witness" => ["a"]},
        {:value, Recovery.route({:error, {:unsolvable, :strong, [:a]}})}
      )
    end
  end

  # -- corpus -----------------------------------------------------------------

  describe "corpus" do
    test "seeded corpus is deterministic, seed-sensitive, and matches direct" do
      parity("/corpus/seeded", %{"count" => 5}, {:value, Corpus.seeded(5)})

      parity(
        "/corpus/seeded",
        %{"count" => 6, "seed" => [3, 1, 4]},
        {:value, Corpus.seeded(6, {3, 1, 4})}
      )

      {200, one} = post("/corpus/seeded", %{"count" => 8, "seed" => [1, 1, 1]})
      {200, again} = post("/corpus/seeded", %{"count" => 8, "seed" => [1, 1, 1]})
      {200, other} = post("/corpus/seeded", %{"count" => 8, "seed" => [9, 9, 9]})
      assert one == again
      refute one == other

      assert {422, _} = post("/corpus/seeded", %{"count" => 0})
    end

    test "seeded verdicts match direct and every synthesized policy validates" do
      body = %{"count" => 20, "seed" => [11, 29, 47]}
      {200, resp} = post("/corpus/verdicts", body)
      assert length(resp["value"]) == 20

      for %{"verdicts" => v} <- resp["value"], mode <- ["strong", "strong_cyclic"] do
        case v["synthesize"][mode] do
          %{"verdict" => "admitted", "validates" => validates} -> assert validates == true
          %{"verdict" => "refused"} -> :ok
        end
      end

      direct =
        for c <- Corpus.seeded(20, {11, 29, 47}) do
          {:ok, d} = FOND.new(c.transitions, c.goals)

          for mode <- @modes do
            FOND.validate_policy(d, c.policy, c.initial, mode) |> elem(0)
          end
        end

      wire_verdicts =
        for %{"verdicts" => v} <- resp["value"] do
          for mode <- ["strong", "strong_cyclic"] do
            if v["validate"][mode] == "admitted", do: :ok, else: :error
          end
        end

      assert wire_verdicts == direct
    end

    test "random fixtures: verdicts match direct" do
      {200, resp} = post("/corpus/random", %{"count" => 20, "seed" => [5, 6, 7]})

      direct =
        for {t, g, pol, i} <- FONDCorpus.random(20, {5, 6, 7}) do
          {:ok, d} = FOND.new(t, g)
          for mode <- @modes, do: FOND.validate_policy(d, pol, i, mode) |> elem(0)
        end

      wire =
        for %{"verdicts" => v} <- resp["value"] do
          for mode <- ["strong", "strong_cyclic"],
              do: if(v["validate"][mode] == "admitted", do: :ok, else: :error)
        end

      assert wire == direct
    end

    test "hand-written fixtures: server-computed verdicts equal the pinned expectations" do
      {200, resp} = post("/corpus/fixtures", %{})
      assert length(resp["value"]) == length(cases())

      for %{"name" => name, "expected" => expected, "actual" => actual} <- resp["value"] do
        assert {name, actual} == {name, expected}
      end
    end
  end

  # -- HTN --------------------------------------------------------------------

  describe "HTN" do
    @pick %{
      "name" => "pick",
      "preconditions" => ["free"],
      "add_list" => ["held"],
      "delete_list" => ["free"]
    }
    @method %{"id" => "m1", "task" => "get", "subtasks" => ["pick"]}

    test "strips_plan matches direct and refuses unsolvable goals" do
      actions = [
        %{"name" => "ab", "preconditions" => ["a"], "add_list" => ["b"], "delete_list" => ["a"]},
        %{"name" => "bc", "preconditions" => ["b"], "add_list" => ["c"]}
      ]

      body = %{"initial" => ["a"], "goal" => ["c"], "actions" => actions}
      direct = HTN.strips_plan(MapSet.new(["a"]), MapSet.new(["c"]), actions, [])
      resp = parity("/htn/strips_plan", body, direct)
      assert resp["ok"]["plan"] == ["ab", "bc"]
      assert resp["ok"]["authority_ceiling"] == "none"

      unsolvable = %{body | "goal" => ["zzz"]}
      assert {422, refused} = post("/htn/strips_plan", unsolvable)
      assert refused["broken_term"] == "no_plan_found"

      parity(
        "/htn/strips_plan",
        unsolvable,
        HTN.strips_plan(MapSet.new(["a"]), MapSet.new(["zzz"]), actions, [])
      )

      assert {422, bad} = post("/htn/strips_plan", %{body | "actions" => [%{"cost" => 1}]})
      assert bad["broken_term"] == "bad_input"
    end

    test "decompose and plan match direct calls; failed preconditions are typed refusals" do
      domain = HTN.new([@pick], [@method], %{})

      body = %{
        "actions" => [@pick],
        "methods" => [@method],
        "tasks" => ["get"],
        "initial" => ["free"]
      }

      resp = parity("/htn/decompose", body, HTN.decompose(domain, ["get"], ["free"], []))
      assert resp["ok"]["plan"] == ["pick"]

      parity(
        "/htn/plan",
        body,
        HTN.plan(domain, ["get"], ["free"], mode: :htn)
      )

      with_goal = Map.put(body, "goal_state", ["held"])

      parity(
        "/htn/plan",
        with_goal,
        HTN.plan(domain, ["get"], ["free"], mode: :htn, goal_state: ["held"])
      )

      missed = Map.put(body, "goal_state", ["nope"])
      assert {422, miss} = post("/htn/plan", missed)
      assert miss["broken_term"] == "goal_not_satisfied"

      blocked = %{body | "initial" => []}
      assert {422, _} = post("/htn/decompose", blocked)
      parity("/htn/decompose", blocked, HTN.decompose(domain, ["get"], [], []))
    end

    test "applicable? and apply_action match direct calls" do
      action = %{
        "name" => "x",
        "preconditions" => ["a"],
        "add_list" => ["b"],
        "delete_list" => ["a"]
      }

      direct = HTN.Action.new(action)

      for state <- [["a"], [], ["a", "z"]] do
        parity(
          "/htn/applicable",
          %{"state" => state, "action" => action},
          {:value, HTN.applicable?(MapSet.new(state), direct)}
        )
      end

      resp =
        parity(
          "/htn/apply_action",
          %{"state" => ["a", "z"], "action" => action},
          {:ok, HTN.apply_action(MapSet.new(["a", "z"]), direct)}
        )

      assert resp["ok"] == ["b", "z"]
    end
  end

  # -- court non-vacuity ------------------------------------------------------

  describe "court non-vacuity" do
    test "the parity comparison can flip: a wrong-mode expectation disagrees with the wire" do
      {t, g, pol, i, _} = retry_cycle()
      d = dom(retry_cycle())

      {status, resp} = post("/validate", wire("/validate", {t, g, pol, i}, :strong))
      {:ok, wrong} = FOND.validate_policy(d, pol, i, :strong_cyclic)

      assert status == 422
      refute resp["ok"] == norm(wrong)
      assert resp["ok"] == nil
    end

    test "a seed change flips the seeded-corpus verdict stream for at least one seed pair" do
      streams =
        for seed <- [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]] do
          {200, resp} = post("/corpus/verdicts", %{"count" => 15, "seed" => seed})
          resp["value"] |> Enum.map(& &1["verdicts"]) |> Enum.uniq()
        end

      assert length(Enum.uniq(streams)) > 1
    end
  end
end
