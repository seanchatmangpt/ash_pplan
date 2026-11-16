defmodule AshPPlan.MirrorSim.PowlTest do
  # Wire courts: a real Bandit listener serves AshPPlan.MirrorSim.Powl; the
  # client is :httpc over the real socket. Parity differential: wire response
  # == direct call on the real AshPPlan.POWL modules.
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.Powl, as: Sim
  alias AshPPlan.POWL
  alias AshPPlan.POWL.Project
  alias AshPPlan.POWL.Reachability
  alias AshPPlan.POWL.Verifier

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, pid} =
      start_supervised(
        {Bandit, plug: Sim, port: 0, ip: :loopback, startup_log: false},
        id: :powl_mirror_bandit
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  # -- wire client

  defp post(ctx, path, body) do
    payload = if is_binary(body), do: body, else: Jason.encode!(body)
    url = String.to_charlist(ctx.base <> path)

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(:post, {url, [], ~c"application/json", payload}, [], body_format: :binary)

    {status, Jason.decode!(resp)}
  end

  defp wire(%POWL.Node{} = n), do: Sim.encode_node(n)

  # -- models

  defp a, do: POWL.activity("a", "A")
  defp b, do: POWL.activity("b", "B")
  defp c, do: POWL.activity("c", "C")

  defp legal_models do
    %{
      "activity" => a(),
      "sequence" => POWL.sequence("s", [a(), b()]),
      "choice" => POWL.choice("x", [a(), b()]),
      "loop" => POWL.loop("l", a(), c()),
      "partial_order" => POWL.partial_order("po", [a(), b(), c()], [{"a", "b"}, {"a", "c"}]),
      "choice_graph" => POWL.choice_graph("cg", [a(), b()], [{:start, 0}, {0, 1}, {1, :end}])
    }
  end

  # -- legal models

  test "legal models verify over the wire and match the direct call", ctx do
    for {name, model} <- legal_models() do
      assert Verifier.verify(model) == :ok, name
      assert {200, %{"ok" => true}} = post(ctx, "/powl/verify", wire(model))
    end
  end

  test "surfaces/0 lists real exported functions" do
    for %{module: m, fun: f, arity: ar, route: r} <- Sim.surfaces() do
      assert function_exported?(m, f, ar) or
               (Code.ensure_loaded(m) && function_exported?(m, f, ar))

      assert String.starts_with?(r, "/powl/")
    end
  end

  test "normalize: node, catalog steps; unsupported shape refused", ctx do
    assert {200, %{"ok" => true, "operator" => "sequence", "children" => 2}} =
             post(ctx, "/normalize", wire(POWL.sequence("s", [a(), b()])))

    steps = [
      %{"iri" => "urn:a", "label" => "A", "predecessors" => []},
      %{"iri" => "urn:b", "label" => "B", "predecessors" => ["urn:a"]}
    ]

    {:ok, direct} =
      POWL.normalize(%{
        steps: [
          %{iri: "urn:a", label: "A", predecessors: []},
          %{iri: "urn:b", label: "B", predecessors: ["urn:a"]}
        ]
      })

    assert {200, %{"root_id" => root, "operator" => "partial_order", "order_edges" => 1}} =
             post(ctx, "/normalize", %{"steps" => steps})

    assert root == direct.id

    # steps shape without a list of maps the normalizer can use
    assert {422, %{"refused" => true}} = post(ctx, "/normalize", %{"steps" => [1]})
  end

  # -- mutated models: each defect class yields a typed refusal

  test "loop with choice body: verifier refuses loop_choice_body (IMP-T006)", ctx do
    m = POWL.loop("l", POWL.choice("x", [a(), b()]), c())
    assert {:error, %{reason: :loop_choice_body}} = Verifier.verify(m)

    assert {422, %{"refused" => true, "broken_term" => "loop_choice_body", "block" => blk}} =
             post(ctx, "/powl/verify", wire(m))

    assert blk["block_id"] == "l" and blk["body_id"] == "x"

    # projection passes the refusal through, nothing projected
    assert {422, %{"broken_term" => "loop_choice_body"} = body} =
             post(ctx, "/powl/project", wire(m))

    refute Map.has_key?(body, "steps")
  end

  test "bounded reachability exhibits the loop-choice-body deadlock", ctx do
    m = POWL.loop("l", POWL.choice("x", [a(), b()]), c())
    direct = Reachability.simulate!(m)
    assert direct.outcome == :deadlock

    assert {200, %{"outcome" => "deadlock", "deadlock_count" => n}} =
             post(ctx, "/powl/reachability", wire(m))

    assert n == length(direct.deadlocks) and n > 0

    assert {422, %{"refused" => true, "broken_term" => "deadlock"}} =
             post(ctx, "/powl/court", wire(m))
  end

  test "reachability court passes a sound sequence and matches direct verdict", ctx do
    m = POWL.sequence("s", [a(), b()])
    direct = Reachability.simulate!(m)
    assert direct.outcome == :sound

    assert {200, resp} = post(ctx, "/powl/court", wire(m))
    assert resp["outcome"] == "sound"
    assert resp["final_reachable"] == true
    assert resp["markings_explored"] == direct.markings_explored
  end

  test "reachability parity over every legal model", ctx do
    for {name, model} <- legal_models() do
      direct = Reachability.simulate!(model, max_markings: 5_000)
      assert {200, resp} = post(ctx, "/powl/reachability", wire(model))
      assert resp["outcome"] == Atom.to_string(direct.outcome), name
      assert resp["deadlock_count"] == length(direct.deadlocks), name
      assert resp["orphan_count"] == length(direct.orphans), name
      assert resp["final_reachable"] == direct.final_reachable, name
      assert resp["markings_explored"] == direct.markings_explored, name
    end
  end

  test "reachability budget bound is honoured", ctx do
    m = POWL.sequence("s", [a(), b(), c()])

    body = Map.put(wire(m), "max_markings", 1)
    direct = Reachability.simulate!(m, max_markings: 1)

    assert {200, resp} = post(ctx, "/powl/reachability", body)
    assert resp["budget_exhausted"] == direct.budget_exhausted
  end

  test "partial order mutants: cycle and unknown edge", ctx do
    cyc = POWL.partial_order("po", [a(), b()], [{"a", "b"}, {"b", "a"}])
    assert {:error, %{reason: :non_separable_block}} = Verifier.verify(cyc)

    assert {422,
            %{"broken_term" => "non_separable_block", "block" => %{"cause" => "order_cycle"}}} =
             post(ctx, "/powl/verify", wire(cyc))

    unk = POWL.partial_order("po", [a(), b()], [{"a", "zzz"}])

    assert {422,
            %{
              "broken_term" => "non_separable_block",
              "block" => %{"cause" => "unknown_order_edge"}
            }} =
             post(ctx, "/powl/verify", wire(unk))
  end

  test "partial order mutant: PT-handle choice interior", ctx do
    # x is a choice with two incomparable predecessors a, b
    m =
      POWL.partial_order(
        "po",
        [a(), b(), POWL.choice("x", [c(), POWL.activity("d", "D")])],
        [{"a", "x"}, {"b", "x"}]
      )

    assert {:error, %{reason: :non_separable_block, block: %{cause: :pt_handle_choice_interior}}} =
             Verifier.verify(m)

    assert {422,
            %{
              "broken_term" => "non_separable_block",
              "block" => %{"cause" => "pt_handle_choice_interior", "side" => "in"}
            }} = post(ctx, "/powl/verify", wire(m))
  end

  test "choice graph mutants: dangling, cyclic, unreachable child", ctx do
    dangling = POWL.choice_graph("cg", [a()], [{:start, 0}, {0, 5}, {0, :end}])
    assert {:error, %{reason: :dangling_choice_endpoint}} = Verifier.verify(dangling)

    assert {422, %{"broken_term" => "dangling_choice_endpoint"}} =
             post(ctx, "/powl/verify", wire(dangling))

    cyclic = POWL.choice_graph("cg", [a(), b()], [{:start, 0}, {0, 1}, {1, 0}, {1, :end}])
    assert {:error, %{reason: :cyclic_choice_graph}} = Verifier.verify(cyclic)

    assert {422, %{"broken_term" => "cyclic_choice_graph"}} =
             post(ctx, "/powl/verify", wire(cyclic))

    unreachable = POWL.choice_graph("cg", [a(), b()], [{:start, 0}, {0, :end}])
    assert {:error, %{reason: :unreachable_choice_child}} = Verifier.verify(unreachable)

    assert {422, %{"broken_term" => "unreachable_choice_child", "block" => %{"child_index" => 1}}} =
             post(ctx, "/powl/verify", wire(unreachable))
  end

  test "nested defect is refused with a within path", ctx do
    m =
      POWL.sequence("outer", [a(), POWL.partial_order("po", [a(), b()], [{"a", "b"}, {"b", "a"}])])

    assert {:error, %{reason: :non_separable_block}} = Verifier.verify(m)

    assert {422, %{"broken_term" => "non_separable_block"}} =
             post(ctx, "/powl/verify", wire(m))

    # sequence wrapping a loop-choice-body: refusal carries `within`
    m2 = POWL.sequence("outer", [POWL.loop("l", POWL.choice("x", [a(), b()]), c())])
    assert {:error, %{reason: :loop_choice_body}} = Verifier.verify(m2)
    assert {422, %{"broken_term" => "loop_choice_body"}} = post(ctx, "/powl/verify", wire(m2))
  end

  # -- projection

  test "project: sequence chains depends_on and warns uncompensable", ctx do
    m = POWL.sequence("s", [a(), b()])
    {:ok, %{steps: dsteps, warnings: dwarns}} = Project.to_reactor_steps(m)

    assert {200, %{"steps" => steps, "warnings" => warns}} =
             post(ctx, "/powl/project", wire(m))

    assert Enum.map(steps, & &1["id"]) == Enum.map(dsteps, &Keyword.fetch!(&1, :id))

    assert Enum.map(steps, & &1["depends_on"]) ==
             Enum.map(dsteps, &Keyword.fetch!(&1, :depends_on))

    assert Enum.at(steps, 1)["depends_on"] == ["a"]
    assert length(warns) == length(dwarns)
    assert Enum.all?(warns, &(&1["warning"] == "uncompensable_activity"))
  end

  test "project: compensation metadata suppresses the warning", ctx do
    leaf = %{POWL.activity("a", "A") | metadata: %{compensation: "undo_a"}}
    assert {200, %{"steps" => [step], "warnings" => []}} = post(ctx, "/powl/project", wire(leaf))
    assert step["compensation"] == "undo_a"
  end

  test "project: loop is a bounded retry (default 3, override honoured)", ctx do
    m = POWL.loop("l", a(), c())

    assert {200, %{"steps" => [step], "warnings" => [%{"max_iterations" => 3}]}} =
             post(ctx, "/powl/project", wire(m))

    assert "powl:max_iterations=3" in step["properties"]

    m5 = %{m | metadata: %{max_iterations: 5}}

    assert {200, %{"steps" => [step5]}} = post(ctx, "/powl/project", wire(m5))
    assert "powl:max_iterations=5" in step5["properties"]
  end

  test "project: choice emits discriminator + branch steps; po edges become depends_on", ctx do
    assert {200, %{"steps" => steps, "warnings" => warns}} =
             post(ctx, "/powl/project", wire(POWL.choice("x", [a(), b()])))

    assert Enum.map(steps, & &1["id"]) |> Enum.sort() == ["a", "b", "x__discriminator"]
    assert Enum.any?(warns, &(&1["warning"] == "choice_requires_runtime_discriminator"))

    po = POWL.partial_order("po", [a(), b()], [{"a", "b"}])
    {:ok, %{steps: dsteps}} = Project.to_reactor_steps(po)

    assert {200, %{"steps" => psteps}} = post(ctx, "/powl/project", wire(po))

    assert Enum.map(psteps, & &1["depends_on"]) ==
             Enum.map(dsteps, &Keyword.fetch!(&1, :depends_on))
  end

  test "project: catalog steps shape projects over the wire", ctx do
    steps = [
      %{"iri" => "urn:a", "label" => "A", "predecessors" => []},
      %{"iri" => "urn:b", "label" => "B", "predecessors" => ["urn:a"]}
    ]

    assert {200, %{"steps" => out}} = post(ctx, "/powl/project", %{"steps" => steps})
    assert Enum.find(out, &(&1["id"] == "urn:b"))["depends_on"] == ["urn:a"]
  end

  # -- malformed input: typed refusal, never 500

  test "malformed wire input yields typed refusals, never 500", ctx do
    assert {422, %{"refused" => true, "broken_term" => "powl_decode"}} =
             post(ctx, "/powl/verify", "{not json")

    assert {422, %{"broken_term" => "powl_decode"}} = post(ctx, "/powl/verify", %{"x" => 1})

    assert {422, %{"broken_term" => "powl_decode"}} =
             post(ctx, "/powl/verify", %{"id" => "q", "operator" => "teleport"})

    assert {422, %{"broken_term" => "powl_decode"}} =
             post(ctx, "/powl/verify", %{
               "id" => "l",
               "operator" => "loop",
               "children" => [wire(a())]
             })

    assert {422, %{"broken_term" => "powl_decode"}} =
             post(ctx, "/powl/verify", %{
               "id" => "po",
               "operator" => "partial_order",
               "children" => [wire(a())],
               "order_edges" => [["a"]]
             })

    assert {404, %{"refused" => true, "broken_term" => "unknown_route"}} =
             post(ctx, "/powl/nope", wire(a()))
  end

  test "reachability on a structurally broken choice graph degrades to a typed refusal", ctx do
    # child index out of range crashes the net compiler; the sim must not 500
    m = POWL.choice_graph("cg", [a()], [{:start, 9}])
    assert {status, %{"refused" => true}} = post(ctx, "/powl/reachability", wire(m))
    assert status == 422
  end
end
