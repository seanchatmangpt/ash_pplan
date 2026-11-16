defmodule AshPPlan.MirrorSim.ProvidersTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.{Providers, Server}
  alias AshPPlan.Providers.{Index, Qualify, Registry}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, pid} = Server.start_link(port: 0)
    on_exit(fn -> File.rm_rf(Providers.sandbox_root()) end)
    {:ok, base: Server.base_url(pid)}
  end

  defp call(method, url, body \\ nil) do
    request =
      case body do
        nil -> {String.to_charlist(url), []}
        b -> {String.to_charlist(url), [], ~c"application/json", Jason.encode!(b)}
      end

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(method, request, [], body_format: :binary)

    {status, Jason.decode!(resp)}
  end

  defp post(base, path, body), do: call(:post, base <> "/providers" <> path, body)

  defp direct_ids(modules), do: Enum.map(modules, &to_string(&1.id()))

  test "index parity: wire inventory equals Index.modules/0", %{base: base} do
    {200, %{"providers" => ps}} = call(:get, base <> "/providers/index")
    assert Enum.map(ps, & &1["id"]) == direct_ids(Index.modules())
    assert length(ps) == 11

    for p <- ps do
      mod = Enum.find(Index.modules(), &(to_string(&1.id()) == p["id"]))
      assert p["capabilities"] == mod.capabilities()
      assert p["cost"] == mod.cost()
    end
  end

  test "every declared capability: wire resolution matches direct Registry.resolve", %{base: base} do
    for mod <- Index.modules(), cap <- mod.capabilities() do
      direct =
        Registry.resolve(
          Registry.default(),
          %{capability: cap, properties: [], evidence: []},
          %{}
        )

      {status, body} = post(base, "/resolve", %{"capability" => cap})

      case direct do
        {:ok, res} ->
          assert status == 200, "#{cap}: #{inspect(body)}"
          assert body["provider"] == to_string(res.provider.id())
          assert body["adapter"] == to_string(res.adapter)
          assert body["op"] == to_string(res.op)

        {:error, _} ->
          assert status == 422
          assert body["refused"] == true
      end
    end
  end

  test "resolution picks lowest cost then id", %{base: base} do
    {200, body} = post(base, "/resolve", %{"capability" => "File.Write"})
    assert body["provider"] == "file"
    assert body["adapter"] == "reactor_file"
    assert body["op"] == "file_write"
    assert body["candidates"] == ["file"]
  end

  test "canonical capability spelling resolves to the same provider", %{base: base} do
    {200, a} = post(base, "/resolve", %{"capability" => "File.Write"})
    {200, b} = post(base, "/resolve", %{"capability" => "file.Write"})
    assert a["provider"] == b["provider"]
  end

  test "resolution refusals are typed 422, never 500", %{base: base} do
    cases = [
      %{"capability" => "Nope.Missing"},
      %{"capability" => "File.Write", "authority" => "do"},
      %{"capability" => "File.Write", "ceiling" => "do"},
      %{"capability" => "File.Write", "authority" => "construct", "ceiling" => "observe"},
      %{"capability" => "File.Write", "authority" => "godlike"},
      %{"capability" => "File.Write", "properties" => ["durable"]},
      %{"capability" => "File.Write", "evidence" => ["telemetry"]},
      %{"capability" => "Domain.Read", "properties" => ["compensable"]},
      %{"capability" => "not a capability"},
      %{}
    ]

    for c <- cases do
      {status, body} = post(base, "/resolve", c)
      assert status == 422, inspect({c, status, body})
      assert body["refused"] == true
      assert body["broken_term"] == "no_qualified_provider"
    end
  end

  test "namespaced annotation passes the resolver but the provider's strict check refuses",
       %{base: base} do
    {422, body} =
      post(base, "/resolve", %{"capability" => "File.Write", "properties" => ["powl:id=a"]})

    assert body["broken_term"] == "no_qualified_provider"
    file = Enum.find(body["rejected"], &(&1["provider"] == "file"))
    assert file["why"] =~ "missing_properties"
    assert file["why"] =~ "powl:id=a"
  end

  test "rejected candidates are reported when no provider can realize", %{base: base} do
    {422, body} =
      post(base, "/resolve", %{"capability" => "File.Write", "seal" => ["file"]})

    assert body["broken_term"] == "no_qualified_provider"
    assert length(body["rejected"]) == 10
    refute Enum.any?(body["rejected"], &(&1["provider"] == "file"))
    assert Enum.all?(body["rejected"], &(&1["why"] == ":capability_unsupported"))
  end

  test "registry seal drops a provider and bumps generation", %{base: base} do
    {200, r} =
      post(base, "/registry", %{
        "providers" => ["file", "domain"],
        "ops" => [%{"op" => "seal", "provider" => "file"}]
      })

    assert r["providers"] == ["domain"]
    assert r["generation"] == 1
    assert Map.has_key?(r["sealed"], "file")

    {200, r2} =
      post(base, "/registry", %{
        "providers" => ["domain"],
        "ops" => [%{"op" => "register", "provider" => "file"}]
      })

    assert r2["providers"] == ["domain", "file"]
    assert r2["generation"] == 1

    direct = Registry.new([AshPPlan.Providers.File, AshPPlan.Providers.Domain])
    assert Registry.seal(direct, AshPPlan.Providers.File).generation == 1

    # sealing an absent provider is a no-op (no generation bump)
    {200, r3} =
      post(base, "/registry", %{
        "providers" => ["domain"],
        "ops" => [%{"op" => "seal", "provider" => "file"}]
      })

    assert r3["generation"] == 0
  end

  test "registry/qualify/realize refuse unknown providers and malformed ops", %{base: base} do
    assert {422, %{"broken_term" => "unknown_provider"}} =
             post(base, "/registry", %{"providers" => ["ghost"]})

    assert {422, %{"broken_term" => "invalid_op"}} =
             post(base, "/registry", %{"ops" => [%{"op" => "explode"}]})

    assert {422, %{"broken_term" => "unknown_provider"}} =
             post(base, "/qualify", %{"provider" => "ghost", "capability" => "File.Read"})

    assert {422, %{"broken_term" => "unknown_provider"}} =
             post(base, "/realize", %{"provider" => "ghost", "capability" => "File.Read"})
  end

  test "invalid JSON body is a typed refusal", %{base: base} do
    {:ok, {{_, 400, _}, _, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> "/providers/resolve"), [], ~c"application/json", "{not json"},
        [],
        body_format: :binary
      )

    assert %{"refused" => true, "broken_term" => "malformed_json"} = Jason.decode!(resp)
  end

  test "qualify and realize per provider match direct calls", %{base: base} do
    for mod <- Index.modules(), cap <- mod.capabilities() do
      req = %{capability: cap, properties: [], evidence: []}
      body = %{"provider" => to_string(mod.id()), "capability" => cap}

      {qs, qb} = post(base, "/qualify", body)

      case mod.qualify(req, %{}) do
        :ok -> assert {qs, qb["ok"]} == {200, true}
        {:error, _} -> assert {qs, qb["refused"]} == {422, true}
      end

      {rs, rb} = post(base, "/realize", body)

      case mod.realize(req, %{}) do
        {:ok, r} ->
          assert rs == 200
          assert rb["adapter"] == to_string(r.binding.adapter)
          assert rb["op"] == to_string(r.binding.op)
          assert rb["properties"] == Enum.map(r.properties, &to_string/1)

        {:error, _} ->
          assert rs == 422
      end
    end
  end

  test "provider refuses a capability it does not declare", %{base: base} do
    assert {422, %{"broken_term" => "qualify_refused"}} =
             post(base, "/qualify", %{"provider" => "file", "capability" => "Domain.Read"})

    assert {422, %{"broken_term" => "realize_refused"}} =
             post(base, "/realize", %{"provider" => "network", "capability" => "File.Read"})
  end

  test "Qualify.check refusal vocabulary over the wire", %{base: base} do
    ok = %{
      "capability" => "File.Read",
      "capabilities" => ["File.Read"],
      "declared_properties" => ["compensable"],
      "declared_evidence" => ["file_stat"]
    }

    assert {200, %{"ok" => true}} = post(base, "/check", ok)

    assert {422, %{"reason" => r1}} = post(base, "/check", Map.put(ok, "capability", "File.Zip"))
    assert r1 =~ "unsupported_capability"

    assert {422, %{"reason" => r2}} = post(base, "/check", Map.put(ok, "properties", ["durable"]))
    assert r2 =~ "missing_properties"

    assert {422, %{"reason" => r3}} = post(base, "/check", Map.put(ok, "evidence", ["telemetry"]))
    assert r3 =~ "missing_evidence"

    assert {422, %{"reason" => r4}} = post(base, "/check", Map.put(ok, "authority", "do"))
    assert r4 =~ "authority_exceeds_ceiling"

    direct = Qualify.check(%{capability: "File.Read"}, %{}, ["File.Read"], [], [], [:none])
    assert direct == :ok
  end

  test "file provider executes for real inside the sandbox", %{base: base} do
    path = "run-#{System.unique_integer([:positive])}/a.txt"

    assert {200, %{"executed" => true}} =
             post(base, "/execute", %{
               "capability" => "File.Write",
               "args" => %{"path" => path, "content" => "hello"}
             })

    assert File.read!(Path.join(Providers.sandbox_root(), path)) == "hello"

    assert {200, %{"result" => %{"content" => "hello"}}} =
             post(base, "/execute", %{"capability" => "File.Read", "args" => %{"path" => path}})

    copy = path <> ".copy"

    assert {200, _} =
             post(base, "/execute", %{
               "capability" => "File.Copy",
               "args" => %{"path" => path, "dest" => copy}
             })

    assert File.read!(Path.join(Providers.sandbox_root(), copy)) == "hello"

    assert {200, _} =
             post(base, "/execute", %{"capability" => "File.Delete", "args" => %{"path" => copy}})

    refute File.exists?(Path.join(Providers.sandbox_root(), copy))

    dir = Path.dirname(path) <> "/sub"

    assert {200, _} =
             post(base, "/execute", %{"capability" => "File.Mkdir", "args" => %{"path" => dir}})

    assert File.dir?(Path.join(Providers.sandbox_root(), dir))
  end

  test "file execution refuses sandbox escapes", %{base: base} do
    for p <- ["../escape.txt", "/etc/passwd", "a/../../b"] do
      assert {422, %{"broken_term" => "path_outside_sandbox"}} =
               post(base, "/execute", %{"capability" => "File.Write", "args" => %{"path" => p}})
    end

    assert {422, %{"broken_term" => "invalid_path"}} =
             post(base, "/execute", %{"capability" => "File.Read", "args" => %{}})
  end

  test "network provider executes against the real local upstream", %{base: base} do
    url = base <> "/providers/upstream/echo"

    assert {200, %{"executed" => true, "status" => 200, "body" => b}} =
             post(base, "/execute", %{"capability" => "Network.Get", "args" => %{"url" => url}})

    assert Jason.decode!(b)["method"] == "GET"

    assert {200, %{"status" => 200, "body" => b2}} =
             post(base, "/execute", %{
               "capability" => "Network.Post",
               "args" => %{"url" => url, "body" => "payload"}
             })

    assert %{"method" => "POST", "body" => "payload"} = Jason.decode!(b2)

    assert {200, %{"body" => b3}} =
             post(base, "/execute", %{
               "capability" => "Network.Put",
               "args" => %{"url" => url, "body" => "p2"}
             })

    assert Jason.decode!(b3)["method"] == "PUT"

    assert {200, %{"body" => b4}} =
             post(base, "/execute", %{"capability" => "Network.Delete", "args" => %{"url" => url}})

    assert Jason.decode!(b4)["method"] == "DELETE"

    assert {200, %{"executed" => true, "op" => "remote_read", "body" => b5}} =
             post(base, "/execute", %{"capability" => "Remote.Read", "args" => %{"url" => url}})

    assert Jason.decode!(b5)["method"] == "GET"
  end

  test "network execution refuses non-loopback and missing urls", %{base: base} do
    assert {422, %{"broken_term" => "non_loopback_upstream"}} =
             post(base, "/execute", %{
               "capability" => "Network.Get",
               "args" => %{"url" => "http://example.com/"}
             })

    assert {422, %{"broken_term" => "missing_url"}} =
             post(base, "/execute", %{"capability" => "Network.Get"})
  end

  test "remaining providers resolve to real Reactor.Step modules", %{base: base} do
    for cap <- [
          "Domain.Read",
          "Observation.Telemetry",
          "Durability.Checkpoint",
          "Workflow.Dispatch",
          "Scheduling.Wakeup",
          "Scheduling.Deferred",
          "State.Observe",
          "Event.Await",
          "Distributed.Propose",
          "Process.Count"
        ] do
      direct =
        Registry.resolve(
          Registry.default(),
          %{capability: cap, properties: [], evidence: []},
          %{}
        )

      {status, body} = post(base, "/execute", %{"capability" => cap})

      case direct do
        {:ok, res} ->
          assert status == 200, "#{cap}: #{inspect(body)}"
          assert body["executed"] == false
          {step, _} = res.step
          assert body["step"] == inspect(step)

        {:error, _} ->
          assert status == 422
      end
    end
  end

  test "unknown route is a typed 404", %{base: base} do
    assert {404, %{"refused" => true, "broken_term" => "unknown_route"}} =
             call(:get, base <> "/providers/nothing-here")
  end

  test "surfaces/0 inventory names real exported functions" do
    for %{module: m, fun: f, arity: a, route: r} <- Providers.surfaces() do
      assert Code.ensure_loaded?(m)
      assert function_exported?(m, f, a), "#{inspect(m)}.#{f}/#{a}"
      assert String.starts_with?(r, "/providers/")
    end
  end
end
