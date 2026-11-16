defmodule AshPPlan.MirrorSim.CapabilityTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.{Json, Server}
  alias AshPPlan.{Capability, CapabilityPack, ManufactureTargets}
  alias AshPPlan.Airbus.{Transpiler, Turtle}

  @turtle """
  @prefix ap: <http://example.org/ap#> .
  ap:s0 ap:hasAction ap:go ; ap:initial "true" .
  ap:go ap:hasOutcome ap:s1 .
  ap:s1 ap:goal "true" .
  """

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  setup do
    pid = start_supervised!({Server, port: 0})
    {:ok, base: Server.base_url(pid)}
  end

  defp http(method, base, path, body \\ nil) do
    url = String.to_charlist(base <> path)

    request =
      case body do
        nil -> {url, []}
        b -> {url, [], ~c"application/json", Jason.encode!(b)}
      end

    {:ok, {{_, status, _}, _h, raw}} =
      :httpc.request(method, request, [{:timeout, 200_000}], body_format: :binary)

    {status, raw, Jason.decode!(raw)}
  end

  defp get(base, path), do: http(:get, base, path)
  defp post(base, path, body), do: http(:post, base, path, body)

  defp direct(term), do: term |> Json.encode!() |> Jason.decode!()

  test "families parity", %{base: b} do
    {200, _, body} = get(b, "/capability/families")
    assert body["families"] == Enum.map(Capability.families(), &Atom.to_string/1)
  end

  test "parse/normalize/valid parity and typed refusal", %{base: b} do
    {:ok, cap} = Capability.parse("File.Write")
    {200, _, body} = post(b, "/capability/parse", %{"id" => "File.Write"})
    assert body == %{"id" => cap.id, "family" => "file", "name" => cap.name}

    {200, _, n} = post(b, "/capability/normalize", %{"id" => "File.Write"})
    assert {:ok, n["id"]} == Capability.normalize("File.Write")

    {200, _, v} = post(b, "/capability/valid", %{"id" => "File.Write"})
    assert v["valid"] == true

    {422, _, r} = post(b, "/capability/parse", %{"id" => "nope"})
    assert r["refused"] == true and r["broken_term"] == "invalid_capability"

    {200, _, v2} = post(b, "/capability/valid", %{"id" => 42})
    assert v2["valid"] == false
  end

  test "pack load parity and refusals", %{base: b} do
    attrs = %{
      "id" => "p1",
      "capabilities" => ["File.Write", "Domain.Read"],
      "authority" => "select"
    }

    {200, _, body} = post(b, "/capability/pack/load", attrs)
    {:ok, pack} = CapabilityPack.load(attrs)
    assert body["id"] == pack.id
    assert body["capabilities"] == pack.capabilities
    assert body["authority"] == "select"

    {422, _, dup} =
      post(b, "/capability/pack/load", %{
        "id" => "p",
        "capabilities" => ["File.Write", "File.Write"]
      })

    assert dup["broken_term"] == "invalid_pack"

    {422, _, auth} =
      post(b, "/capability/pack/load", %{
        "id" => "p",
        "capabilities" => ["File.Write"],
        "authority" => "admin"
      })

    assert auth["broken_term"] == "authority_ceiling"

    {422, _, bad} = post(b, "/capability/pack/load", %{"id" => "p", "capabilities" => ["bogus"]})
    assert bad["broken_term"] == "invalid_capability"

    {422, _, missing} = post(b, "/capability/pack/load", %{"x" => 1})
    assert missing["broken_term"] == "invalid_pack"
  end

  test "authority ceiling admits only observe/select/construct", %{base: b} do
    for a <- ["observe", "select", "construct"] do
      {200, _, body} = post(b, "/capability/ceiling", %{"authority" => a})
      assert body["admitted"] == a
    end

    for a <- ["actuate", "admin", 7] do
      {422, _, body} = post(b, "/capability/ceiling", %{"authority" => a})
      assert body["broken_term"] == "authority_ceiling"
    end
  end

  test "manufacture targets parity and byte-identical replay", %{base: b} do
    {200, raw1, body} = get(b, "/capability/targets")
    {200, raw2, _} = get(b, "/capability/targets")
    assert raw1 == raw2

    assert body["targets"] ==
             direct(
               Enum.map(ManufactureTargets.targets(), fn t ->
                 %{template: t.template, out: t.out, module: inspect(t.module)}
               end)
             )

    {200, _, p} = get(b, "/capability/providers")
    assert p["providers"] == ManufactureTargets.providers()
    {200, _, g} = get(b, "/capability/generated_dirs")
    assert g["generated_dirs"] == ManufactureTargets.generated_dirs()
  end

  test "catalog parity", %{base: b} do
    {200, _, plans} = get(b, "/capability/catalog/plans")
    assert plans["plans"] == direct(AshPPlan.Catalog.Plan.all())

    [first | _] = AshPPlan.Catalog.Plan.all()

    {200, _, one} =
      get(b, "/capability/catalog/plans/fetch?iri=" <> URI.encode_www_form(first.iri))

    assert one["plan"] == direct(first)
    {422, _, miss} = get(b, "/capability/catalog/plans/fetch?iri=nope")
    assert miss["broken_term"] == "unknown_plan"

    {200, _, projs} = get(b, "/capability/catalog/projections")
    assert projs["projections"] == direct(AshPPlan.Catalog.Projection.all())

    {200, _, step} = get(b, "/capability/catalog/projections/by_role?role=step")
    assert step["projections"] == direct(AshPPlan.Catalog.Projection.by_role("step"))
    assert step["projections"] != []

    [p | _] = AshPPlan.Catalog.Projection.all()

    {200, _, f} =
      get(b, "/capability/catalog/projections/fetch?source=" <> URI.encode_www_form(p.source))

    assert f["projection"] == direct(p)
  end

  test "airbus turtle ingest parity and replay", %{base: b} do
    {200, _, graph} = post(b, "/capability/airbus/parse", %{"text" => @turtle})
    {:ok, g} = Turtle.parse(@turtle)
    assert length(graph["triples"]) == length(g.triples)

    # A crash in the direct call is a test failure (no rescue).
    {:ok, %{domain: d, initial: i, mode: m}} = Turtle.to_fond_domain(g)

    {200, raw1, fond} = post(b, "/capability/airbus/fond", %{"text" => @turtle})
    {200, raw2, _} = post(b, "/capability/airbus/fond", %{"text" => @turtle})
    assert raw1 == raw2
    assert fond["initial"] == i and fond["mode"] == Atom.to_string(m)
    assert fond["domain"] == inspect(d, limit: :infinity)

    {200, _, oracle} = post(b, "/capability/airbus/oracle", %{"text" => @turtle})
    assert oracle == direct(Transpiler.to_oracle_fond(d, i, m))

    {200, _, pddl} = post(b, "/capability/airbus/pddl", %{"text" => @turtle})
    {:ok, {dom, prob}} = Transpiler.to_pddl(d, i)
    assert pddl == %{"domain" => dom, "problem" => prob}
  end

  test "airbus typed refusals", %{base: b} do
    {422, _, a} = post(b, "/capability/airbus/parse", %{"text" => "ap:x ap:y ( 1 ) ."})
    assert a["refused"] == true

    {422, _, no_tr} =
      post(b, "/capability/airbus/fond", %{
        "text" => "@prefix ap: <http://x/ap#> .\nap:a ap:goal \"true\" .\n"
      })

    assert no_tr["broken_term"] == "no_transitions_in_graph"

    {422, _, nt} = post(b, "/capability/airbus/fond", %{"text" => 5})
    assert nt["broken_term"] == "invalid_text"
  end

  test "dsl_docs render parity and replay", %{base: b} do
    {200, raw1, body} = get(b, "/capability/dsl_docs/render?extension=workflow")
    {200, raw2, _} = get(b, "/capability/dsl_docs/render?extension=workflow")
    assert raw1 == raw2
    assert body["markdown"] == Mix.Tasks.AshPplan.DslDocs.render(AshPPlan.Workflow.Dsl)

    {200, _, pp} = get(b, "/capability/dsl_docs/render?extension=pplan")
    assert pp["markdown"] == Mix.Tasks.AshPplan.DslDocs.render(AshPPlan.Dsl.PPlan)

    {422, _, bad} = get(b, "/capability/dsl_docs/render?extension=zzz")
    assert bad["broken_term"] == "unknown_extension"
  end

  @tag timeout: 400_000
  test "mix subprocess surfaces: shape, replay, input refusal", %{base: b} do
    {200, _, c1} = post(b, "/capability/dsl_docs/check", %{})
    assert is_integer(c1["exit"])

    {200, _, w1} =
      post(b, "/capability/gen_workflow", %{
        "name" => "etl",
        "goal" => "Ingest",
        "providers" => "file,network"
      })

    {200, _, w2} =
      post(b, "/capability/gen_workflow", %{
        "name" => "etl",
        "goal" => "Ingest",
        "providers" => "file,network"
      })

    assert is_integer(w1["exit"])
    assert w1["exit"] == w2["exit"]
    assert w1["output"] == w2["output"]

    for bad <- [
          %{"name" => "Bad Name"},
          %{"name" => "ok", "goal" => "--yes"},
          %{"name" => "ok", "providers" => "a b"}
        ] do
      {422, _, r} = post(b, "/capability/gen_workflow", bad)
      assert r["refused"] == true
    end
  end

  test "unknown route is a typed 404", %{base: b} do
    {404, _, r} = get(b, "/capability/nope")
    assert r["refused"] == true
  end

  test "surfaces/0 declares every route under /capability" do
    for s <- AshPPlan.MirrorSim.Capability.surfaces() do
      assert String.starts_with?(s.route, "/capability/")
      assert Code.ensure_loaded?(s.module)
    end
  end
end
