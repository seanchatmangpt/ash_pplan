defmodule AshPPlan.MirrorSim.TLATest do
  @moduledoc """
  Wire courts for the `/tla/*` mirror-sim area. Every request goes over the real listening
  socket (`:httpc` against Bandit); every response is compared with the direct call of the
  real module. No doubles.

  External checkers (tla-rs, TLC) are optional: the `/native` and `/tlc` routes must answer
  either 503 `unavailable` (checker absent) or a real verdict (present); the flip courts that
  need a real checker are tagged with a loud `[SKIP]` reason (never a fake pass) and become
  mandatory under `ASH_PPLAN_REQUIRE_TLA=1` / `ASH_PPLAN_REQUIRE_TLC=1`.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.FOND.TLA.{JSON, Manifest}
  alias AshPPlan.MirrorSim.Server
  alias AshPPlan.MirrorSim.TLA, as: Sim
  alias AshPPlan.Test.{FONDCorpus, FONDTLABench, NativeTLA, TLAReader, TLCCourt}

  @modes [:strong, :strong_cyclic]

  @native_skip (case NativeTLA.availability() do
                  :ok -> false
                  {:unavailable, why} -> "[SKIP] native tla-rs court unavailable: " <> why
                end)
  @tlc_skip (case TLCCourt.availability() do
               :ok -> false
               {:unavailable, why} -> "[SKIP] TLC court unavailable: " <> why
             end)

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, pid} = Server.start_link(port: 0)
    %{base: Server.base_url(pid)}
  end

  # -- wire helpers -----------------------------------------------------------

  defp post_raw(base, path, body) do
    url = String.to_charlist(String.trim_trailing(base, "/") <> path)

    {:ok, {{_, status, _}, _headers, resp}} =
      :httpc.request(:post, {url, [], ~c"application/json", body}, [], body_format: :binary)

    {status, resp}
  end

  defp post(base, path, map) do
    {status, resp} = post_raw(base, path, Jason.encode!(map))
    {status, Jason.decode!(resp)}
  end

  defp req(transitions, goals, policy, initial, mode, extra \\ %{}) do
    Map.merge(
      %{
        "transitions" => Sim.jsonable(transitions),
        "goals" => Sim.jsonable(goals),
        "policy" => Sim.jsonable(policy),
        "initial" => Sim.jsonable(initial),
        "mode" => Atom.to_string(mode)
      },
      extra
    )
  end

  defp direct(transitions, goals, policy, initial, mode) do
    {:ok, domain} = FOND.new(transitions, goals)
    {:ok, rendered} = FOND.to_tla(domain, policy, initial, mode)
    {domain, rendered}
  end

  defp elixir_verdict(domain, policy, initial, mode) do
    case FOND.validate_policy(domain, policy, initial, mode) do
      {:ok, _} -> "admitted"
      {:error, _} -> "refused"
    end
  end

  @retry {%{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}}, [:succeeded],
          %{pending: :attempt}, :pending}

  defp retry_req(mode, extra \\ %{}) do
    {t, g, p, i} = @retry
    req(t, g, p, i, mode, extra)
  end

  # -- surfaces ---------------------------------------------------------------

  test "surfaces/0 lists exported functions under /tla" do
    for %{module: mod, fun: fun, arity: arity, route: route} <- Sim.surfaces() do
      assert String.starts_with?(route, "/tla/"), route
      assert Code.ensure_loaded?(mod), inspect(mod)
      assert function_exported?(mod, fun, arity), "#{inspect(mod)}.#{fun}/#{arity}"
    end
  end

  # -- parity -----------------------------------------------------------------

  test "render/validate/read over the wire equal the direct calls on the whole corpus", %{
    base: base
  } do
    for {name, {t, g, p, i, expected}} <- FONDCorpus.cases(), mode <- @modes do
      {domain, rendered} = direct(t, g, p, i, mode)
      body = req(t, g, p, i, mode)

      assert {200, wire} = post(base, "/tla/render", body)
      assert wire["module"] == rendered.module, "#{name} #{mode}"
      assert wire["cfg"] == rendered.cfg
      assert wire["branches"] == rendered.branches
      assert wire["mode"] == Atom.to_string(mode)

      want = elixir_verdict(domain, p, i, mode)
      assert want == Atom.to_string(expected[mode]), "#{name} #{mode}"

      case post(base, "/tla/validate", body) do
        {200, v} ->
          assert v["verdict"] == "admitted"
          assert want == "admitted"

        {422, v} ->
          assert v["verdict"] == "refused"
          assert v["refused"] == true
          assert want == "refused"
      end

      assert {200, read} = post(base, "/tla/read", body)
      direct_read = TLAReader.check!(rendered)
      assert read["verdict"] == Atom.to_string(direct_read.verdict), "#{name} #{mode}"
      assert read["kind"] == Atom.to_string(direct_read.kind)
      assert read["verdict"] == want
    end
  end

  test "envelope round-trips over the wire and a tampered module is refused", %{base: base} do
    {_d, rendered} = direct(elem(@retry, 0), elem(@retry, 1), elem(@retry, 2), :pending, :strong)

    assert {200, env} = post(base, "/tla/envelope", retry_req(:strong))
    assert env == JSON.encode_map(rendered)

    assert {200, %{"decoded" => dec}} = post(base, "/tla/decode", %{"envelope" => env})
    assert dec["module"] == rendered.module
    assert dec["cfg"] == rendered.cfg
    assert dec["mode"] == "strong"

    tampered = Map.update!(env, "module", &(&1 <> "\n\\* tampered"))

    assert {422, ref} = post(base, "/tla/decode", %{"envelope" => tampered})
    assert ref["refused"] == true
    assert ref["broken_term"] == "manifest_mismatch"

    assert {422, ref} = post(base, "/tla/decode", %{"envelope" => %{"schema" => "nope"}})
    assert ref["broken_term"] == "invalid_tla_json"
    assert {422, ref} = post(base, "/tla/decode", %{})
    assert ref["broken_term"] == "invalid_tla_json"
  end

  test "manifest over the wire equals Manifest.from_rendered; suffix breaks matches?", %{
    base: base
  } do
    {_d, rendered} =
      direct(elem(@retry, 0), elem(@retry, 1), elem(@retry, 2), :pending, :strong_cyclic)

    assert {200, m} = post(base, "/tla/manifest", retry_req(:strong_cyclic))
    assert m == Sim.jsonable(Manifest.from_rendered(rendered))
    assert m["subject_sha256"] =~ ~r/\A[0-9a-f]{64}\z/

    assert {200, %{"matches" => true}} =
             post(base, "/tla/manifest/matches", retry_req(:strong_cyclic))

    assert {200, %{"matches" => false}} =
             post(
               base,
               "/tla/manifest/matches",
               retry_req(:strong_cyclic, %{"module_suffix" => "\n\\* drift"})
             )
  end

  # -- hardening --------------------------------------------------------------

  test "hardening: malformed and adversarial requests are typed refusals, never 500", %{
    base: base
  } do
    for name <- ["Next", "WF_x", "A_1", "B_1_2", "9bad", "has space", "EXTENDS", "Naturals"] do
      assert {422, r} = post(base, "/tla/render", retry_req(:strong, %{"module_name" => name}))
      assert r["broken_term"] == "invalid_tla_module_name", name
    end

    assert {200, ok} = post(base, "/tla/render", retry_req(:strong, %{"module_name" => "Okay_1"}))
    assert ok["module"] =~ "---- MODULE Okay_1 ----"

    assert {422, r} = post(base, "/tla/render", Map.put(retry_req(:strong), "initial", "ghost"))
    assert r["broken_term"] == "unknown_initial_state"

    assert {422, r} = post(base, "/tla/render", Map.put(retry_req(:strong), "mode", "weak"))
    assert r["broken_term"] == "invalid_mode"

    assert {422, r} = post(base, "/tla/render", %{"transitions" => 7, "initial" => "a"})
    assert r["broken_term"] == "invalid_transition_relation"

    assert {422, r} = post(base, "/tla/render", Map.put(retry_req(:strong), "initial", 5))
    assert r["broken_term"] == "invalid_name"

    # The router's body parser may refuse first (400 malformed_json) or the area handler (422).
    {status, raw} = post_raw(base, "/tla/render", "{not json")
    r = Jason.decode!(raw)
    assert status in [400, 422]
    assert r["refused"] == true
    assert r["broken_term"] in ["malformed_json", "invalid_json"]

    assert {422, r} =
             post_raw(base, "/tla/read", ~s({"module": "garbage line"}))
             |> then(fn {s, b} -> {s, Jason.decode!(b)} end)

    assert r["broken_term"] == "checker_exception"

    assert {404, r} = post(base, "/tla/nope", %{})
    assert r["broken_term"] == "unknown_tla_route"
  end

  test "hardening: state terms with comment delimiters and line breaks still render and check",
       %{base: base} do
    weird_a = :"a(*b"
    weird_b = :"c*)\nd e"

    t = %{weird_a => %{go: [weird_b]}, weird_b => %{}}
    {domain, rendered} = direct(t, [weird_b], %{weird_a => :go}, weird_a, :strong)

    body = req(t, [weird_b], %{weird_a => :go}, weird_a, :strong)
    assert {200, wire} = post(base, "/tla/render", body)
    assert wire["module"] == rendered.module

    assert {200, read} = post(base, "/tla/read", body)
    assert read["verdict"] == elixir_verdict(domain, %{weird_a => :go}, weird_a, :strong)
    assert read["verdict"] == "admitted"
  end

  # -- mutation: a court that cannot flip is FAIL -----------------------------

  test "mutation suite flips verdicts over the wire (both baselines)", %{base: base} do
    # Refused baseline (strong, retry cycle): dropping the property admits.
    assert {200, refused} = post(base, "/tla/mutate", retry_req(:strong))
    assert refused["baseline"] == %{"verdict" => "refused", "kind" => "liveness"}
    by_name = Map.new(refused["mutants"], &{&1["name"], &1})
    assert by_name["drop_goal_property"]["flipped"] == true
    assert by_name["drop_goal_property"]["result"]["verdict"] == "admitted"

    # Admitted baseline (strong_cyclic): structural mutants must be rejected by the reader.
    assert {200, admitted} = post(base, "/tla/mutate", retry_req(:strong_cyclic))
    assert admitted["baseline"] == %{"verdict" => "admitted", "kind" => "no_error"}
    by_name = Map.new(admitted["mutants"], &{&1["name"], &1})

    for name <- ["drop_first_branch", "undefined_next_action"] do
      assert by_name[name]["flipped"] == true, name
      assert by_name[name]["result"]["verdict"] == "error", name
    end

    assert length(admitted["mutants"]) == 5
    assert Enum.any?(admitted["mutants"] ++ refused["mutants"], & &1["flipped"])
  end

  test "spec-text mutation (fairness stripped) flips admitted -> refused liveness via /read",
       %{base: base} do
    assert {200, %{"module" => module, "cfg" => cfg}} =
             post(base, "/tla/render", retry_req(:strong_cyclic))

    assert {200, %{"verdict" => "admitted"}} =
             post(base, "/tla/read", %{"module" => module, "cfg" => cfg})

    mutated = strip_fairness(module)
    refute mutated == module

    assert {200, %{"verdict" => "refused", "kind" => "liveness"}} =
             post(base, "/tla/read", %{"module" => mutated, "cfg" => cfg})
  end

  @tag skip: @native_skip
  test "spec-text mutation flips the real tla-rs verdict over the wire", %{base: base} do
    assert {200, %{"module" => module, "cfg" => cfg}} =
             post(base, "/tla/render", retry_req(:strong_cyclic))

    assert {200, %{"verdict" => "admitted"}} =
             post(base, "/tla/native", %{"module" => module, "cfg" => cfg})

    assert {200, %{"verdict" => "refused"}} =
             post(base, "/tla/native", %{"module" => strip_fairness(module), "cfg" => cfg})
  end

  @tag skip: @tlc_skip
  test "spec-text mutation flips the real TLC verdict over the wire", %{base: base} do
    assert {200, %{"module" => module, "cfg" => cfg}} =
             post(base, "/tla/render", retry_req(:strong_cyclic))

    assert {200, %{"verdict" => "admitted"}} =
             post(base, "/tla/tlc", %{"module" => module, "cfg" => cfg})

    assert {200, %{"verdict" => "refused", "kind" => "liveness"}} =
             post(base, "/tla/tlc", %{"module" => strip_fairness(module), "cfg" => cfg})
  end

  test "checker routes report unavailable (503) or a real verdict, disjunctively", %{base: base} do
    body = retry_req(:strong_cyclic)

    for {route, avail} <- [
          {"/tla/native", NativeTLA.observe_availability()},
          {"/tla/tlc", TLCCourt.observe_availability()}
        ] do
      {status, resp} = post(base, route, body)

      case avail do
        :ok ->
          assert status == 200
          assert resp["verdict"] in ["admitted", "refused"]

        {:unavailable, reason} ->
          IO.puts("[SKIP-OBSERVED] #{route}: #{reason}")
          assert status == 503
          assert resp["unavailable"] == true
      end
    end
  end

  # -- bench ------------------------------------------------------------------

  test "bench route equals FONDTLABench on deterministic fields; size cap refuses", %{base: base} do
    for {family, mode} <- [
          {:retry_chain, :strong},
          {:retry_chain, :strong_cyclic},
          {:fanout, :strong}
        ] do
      direct = FONDTLABench.measure(family, 20, mode, 1)

      assert {200, wire} =
               post(base, "/tla/bench", %{
                 "family" => Atom.to_string(family),
                 "n" => 20,
                 "mode" => Atom.to_string(mode)
               })

      assert wire["states"] == direct.states
      assert wire["module_bytes"] == direct.module_bytes
      assert wire["verdict"] == Atom.to_string(direct.verdict)
      assert wire["reader_verdict"] == Atom.to_string(direct.reader_verdict)
    end

    direct = FONDTLABench.measure_projection(:terminal_chain, 5)
    assert {200, wire} = post(base, "/tla/bench", %{"family" => "terminal_chain", "n" => 5})
    assert wire["states"] == direct.states
    assert wire["verdict"] == Atom.to_string(direct.verdict)

    assert {422, r} = post(base, "/tla/bench", %{"family" => "retry_chain", "n" => 100_000})
    assert r["broken_term"] == "bench_size_out_of_range"
    assert {422, r} = post(base, "/tla/bench", %{"family" => "bogus", "n" => 5})
    assert r["broken_term"] == "unknown_bench_family"
  end

  defp strip_fairness(module) do
    Regex.replace(~r/^Fairness ==\n(?:  \/\\ SF_vars\(\w+\)\n)+/m, module, "Fairness == TRUE\n")
  end
end
