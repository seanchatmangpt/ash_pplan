defmodule AshPPlan.MirrorSim.Capability do
  @moduledoc """
  Mirror-sim area `capability`: wire surface over the real
  `AshPPlan.Capability`, `CapabilityPack`, `PolicyClosure.AuthorityCeiling`,
  `ManufactureTargets`, `Catalog.Plan`, `Catalog.Projection`, `Airbus.Turtle`,
  `Airbus.Transpiler` and the `ash_pplan.gen.workflow` / `ash_pplan.dsl_docs` Mix tasks.

  Every response is a pure function of the request (sorted, no clocks), so replay is
  byte-identical. Typed refusals are HTTP 422 `{"refused":true,...}`.
  """
  use Plug.Router

  alias AshPPlan.Airbus.{Transpiler, Turtle}
  alias AshPPlan.{Capability, CapabilityPack, ManufactureTargets}
  alias AshPPlan.Catalog
  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.PolicyClosure.AuthorityCeiling

  plug(:match)
  plug(:dispatch)

  @subprocess_timeout_ms 180_000
  @name_re ~r/^[a-z][a-z0-9_]*$/
  @provider_re ~r/^[a-z][a-z0-9_,]*$/

  @doc "Surfaces mirrored by this area."
  @spec surfaces() :: [
          %{module: module(), fun: atom(), arity: non_neg_integer(), route: String.t()}
        ]
  def surfaces do
    [
      %{module: Capability, fun: :families, arity: 0, route: "/capability/families"},
      %{module: Capability, fun: :parse, arity: 1, route: "/capability/parse"},
      %{module: Capability, fun: :valid?, arity: 1, route: "/capability/valid"},
      %{module: Capability, fun: :normalize, arity: 1, route: "/capability/normalize"},
      %{module: CapabilityPack, fun: :load, arity: 1, route: "/capability/pack/load"},
      %{module: CapabilityPack, fun: :validate, arity: 1, route: "/capability/pack/validate"},
      %{module: AuthorityCeiling, fun: :admit, arity: 1, route: "/capability/ceiling"},
      %{module: ManufactureTargets, fun: :targets, arity: 0, route: "/capability/targets"},
      %{module: ManufactureTargets, fun: :providers, arity: 0, route: "/capability/providers"},
      %{
        module: ManufactureTargets,
        fun: :generated_dirs,
        arity: 0,
        route: "/capability/generated_dirs"
      },
      %{module: Catalog.Plan, fun: :all, arity: 0, route: "/capability/catalog/plans"},
      %{module: Catalog.Plan, fun: :fetch, arity: 1, route: "/capability/catalog/plans/fetch"},
      %{
        module: Catalog.Projection,
        fun: :all,
        arity: 0,
        route: "/capability/catalog/projections"
      },
      %{
        module: Catalog.Projection,
        fun: :fetch,
        arity: 1,
        route: "/capability/catalog/projections/fetch"
      },
      %{
        module: Catalog.Projection,
        fun: :by_role,
        arity: 1,
        route: "/capability/catalog/projections/by_role"
      },
      %{module: Turtle, fun: :parse, arity: 1, route: "/capability/airbus/parse"},
      %{module: Turtle, fun: :to_fond_domain, arity: 2, route: "/capability/airbus/fond"},
      %{module: Transpiler, fun: :to_oracle_fond, arity: 3, route: "/capability/airbus/oracle"},
      %{module: Transpiler, fun: :to_pddl, arity: 3, route: "/capability/airbus/pddl"},
      %{
        module: Mix.Tasks.AshPplan.DslDocs,
        fun: :render,
        arity: 1,
        route: "/capability/dsl_docs/render"
      },
      %{
        module: Mix.Tasks.AshPplan.DslDocs,
        fun: :run,
        arity: 1,
        route: "/capability/dsl_docs/check"
      },
      %{
        module: Mix.Tasks.AshPplan.Gen.Workflow,
        fun: :igniter,
        arity: 1,
        route: "/capability/gen_workflow"
      }
    ]
  end

  # -- Capability ------------------------------------------------------------

  get "/families" do
    ok(conn, %{"families" => Enum.map(Capability.families(), &Atom.to_string/1)})
  end

  post "/parse" do
    conn |> param("id") |> Capability.parse() |> result(conn, &cap_json/1)
  end

  post "/valid" do
    ok(conn, %{"valid" => Capability.valid?(param(conn, "id"))})
  end

  post "/normalize" do
    conn |> param("id") |> Capability.normalize() |> result(conn, &%{"id" => &1})
  end

  # -- CapabilityPack / AuthorityCeiling ---------------------------------------

  post "/pack/load" do
    conn |> body_map() |> CapabilityPack.load() |> result(conn, &pack_json/1)
  end

  post "/pack/validate" do
    case CapabilityPack.load(body_map(conn)) do
      {:ok, pack} ->
        pack |> CapabilityPack.validate() |> result(conn, fn :ok -> %{"valid" => true} end)

      {:error, _} = err ->
        result(err, conn, & &1)
    end
  end

  post "/ceiling" do
    case param(conn, "authority") do
      a when a in ["observe", "select", "construct"] ->
        a
        |> String.to_existing_atom()
        |> AuthorityCeiling.admit()
        |> result(conn, &%{"admitted" => to_string(&1)})

      other ->
        other |> AuthorityCeiling.admit() |> result(conn, & &1)
    end
  end

  # -- ManufactureTargets --------------------------------------------------------

  get "/targets" do
    ok(conn, %{"targets" => Enum.map(ManufactureTargets.targets(), &target_json/1)})
  end

  get "/providers" do
    ok(conn, %{"providers" => ManufactureTargets.providers()})
  end

  get "/generated_dirs" do
    ok(conn, %{"generated_dirs" => ManufactureTargets.generated_dirs()})
  end

  # -- Catalog --------------------------------------------------------------------

  get "/catalog/plans" do
    ok(conn, %{"plans" => Catalog.Plan.all()})
  end

  get "/catalog/plans/fetch" do
    conn = fetch_query_params(conn)

    case Catalog.Plan.fetch(conn.query_params["iri"]) do
      nil -> Json.refuse(conn, "unknown_plan", "no plan for iri")
      plan -> ok(conn, %{"plan" => plan})
    end
  end

  get "/catalog/projections" do
    ok(conn, %{"projections" => Catalog.Projection.all()})
  end

  get "/catalog/projections/fetch" do
    conn = fetch_query_params(conn)

    case Catalog.Projection.fetch(conn.query_params["source"]) do
      nil -> Json.refuse(conn, "unknown_projection", "no projection for source")
      p -> ok(conn, %{"projection" => p})
    end
  end

  get "/catalog/projections/by_role" do
    conn = fetch_query_params(conn)
    ok(conn, %{"projections" => Catalog.Projection.by_role(conn.query_params["role"])})
  end

  # -- Airbus ----------------------------------------------------------------------

  post "/airbus/parse" do
    case param(conn, "text") do
      text when is_binary(text) ->
        text |> Turtle.parse() |> result(conn, &graph_json/1)

      _ ->
        Json.refuse(conn, "invalid_text", "text must be a string")
    end
  end

  post "/airbus/fond" do
    with_domain(conn, fn %{domain: d, initial: i, mode: m} ->
      %{"initial" => i, "mode" => Atom.to_string(m), "domain" => inspect(d, limit: :infinity)}
    end)
  end

  post "/airbus/oracle" do
    with_domain(conn, fn %{domain: d, initial: i, mode: m} ->
      Transpiler.to_oracle_fond(d, i, m)
    end)
  end

  post "/airbus/pddl" do
    with_domain(conn, fn %{domain: d, initial: i} ->
      {:ok, {dom, prob}} = Transpiler.to_pddl(d, i)
      %{"domain" => dom, "problem" => prob}
    end)
  end

  # -- Mix tasks (real subprocesses) ---------------------------------------------------

  get "/dsl_docs/render" do
    conn = fetch_query_params(conn)

    case conn.query_params["extension"] do
      "workflow" -> render_ext(conn, AshPPlan.Workflow.Dsl)
      "pplan" -> render_ext(conn, AshPPlan.Dsl.PPlan)
      _ -> Json.refuse(conn, "unknown_extension", "extension must be workflow|pplan")
    end
  end

  # `--check` writes nothing: exit code + output are the observable.
  post "/dsl_docs/check" do
    subprocess(conn, ["ash_pplan.dsl_docs", "--check"])
  end

  # `--dry-run` (Igniter): the scaffold is rendered, nothing is written to disk.
  post "/gen_workflow" do
    name = param(conn, "name")
    goal = param(conn, "goal")
    providers = param(conn, "providers")

    cond do
      not (is_binary(name) and Regex.match?(@name_re, name)) ->
        Json.refuse(conn, "invalid_workflow_name", "name must match #{inspect(@name_re.source)}")

      not (is_nil(goal) or (is_binary(goal) and not String.starts_with?(goal, "-"))) ->
        Json.refuse(conn, "invalid_goal", "goal must be a string not starting with '-'")

      not (is_nil(providers) or (is_binary(providers) and Regex.match?(@provider_re, providers))) ->
        Json.refuse(
          conn,
          "invalid_providers",
          "providers must be a comma list of snake_case names"
        )

      true ->
        args =
          ["ash_pplan.gen.workflow", name, "--dry-run"] ++
            if(goal, do: ["--goal", goal], else: []) ++
            if(providers, do: ["--providers", providers], else: [])

        subprocess(conn, args)
    end
  end

  match _ do
    Json.refuse(
      conn,
      "unknown_route",
      "no capability route for #{conn.method} #{conn.request_path}",
      404
    )
  end

  # -- helpers -------------------------------------------------------------------------

  defp ok(conn, data), do: Json.send_json(conn, 200, data)

  defp result({:ok, v}, conn, f), do: ok(conn, f.(v))
  defp result(:ok, conn, f), do: ok(conn, f.(:ok))

  defp result({:error, %{reason: reason} = e}, conn, _f),
    do: Json.refuse(conn, reason, inspect(Map.delete(e, :reason), limit: 20))

  defp result({:error, reason}, conn, _f), do: Json.refuse(conn, reason, "refused")

  defp body_map(conn) do
    case conn.body_params do
      %{} = m -> Map.delete(m, "_json")
      _ -> %{}
    end
  end

  defp param(conn, key), do: Map.get(body_map(conn), key)

  defp cap_json(%Capability{id: id, family: f, name: n}),
    do: %{"id" => id, "family" => Atom.to_string(f), "name" => n}

  defp pack_json(%CapabilityPack{} = p) do
    %{
      "id" => p.id,
      "version" => p.version,
      "capabilities" => p.capabilities,
      "properties" => Enum.map(p.properties, &to_string/1),
      "evidence" => Enum.map(p.evidence, &to_string/1),
      "authority" => to_string(p.authority)
    }
  end

  defp target_json(%{template: t, out: o, module: m}),
    do: %{"template" => t, "out" => o, "module" => inspect(m)}

  defp graph_json(%{prefixes: p, triples: ts}) do
    %{
      "prefixes" => p,
      "triples" => Enum.map(ts, fn {s, pr, o} -> [term_json(s), term_json(pr), term_json(o)] end)
    }
  end

  defp term_json({:iri, i}), do: %{"iri" => i}
  defp term_json({:literal, v, d, l}), do: %{"literal" => v, "datatype" => d, "lang" => l}

  defp with_domain(conn, f) do
    with text when is_binary(text) <- param(conn, "text"),
         {:ok, graph} <- Turtle.parse(text) do
      graph |> Turtle.to_fond_domain() |> result(conn, f)
    else
      {:error, _} = err -> result(err, conn, & &1)
      _ -> Json.refuse(conn, "invalid_text", "text must be a string")
    end
  end

  defp render_ext(conn, ext),
    do: ok(conn, %{"markdown" => Mix.Tasks.AshPplan.DslDocs.render(ext)})

  defp subprocess(conn, args) do
    case run_mix(args) do
      {:ok, out, code} -> ok(conn, %{"args" => args, "exit" => code, "output" => out})
      {:error, reason} -> Json.refuse(conn, "subprocess_#{reason}", "mix #{Enum.join(args, " ")}")
    end
  end

  defp run_mix(args) do
    case System.find_executable("mix") do
      nil ->
        {:error, :mix_not_found}

      mix ->
        env = [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", Mix.Project.build_path()}]

        task =
          Task.async(fn ->
            System.cmd(mix, args, cd: ManufactureTargets.root(), env: env, stderr_to_stdout: true)
          end)

        case Task.yield(task, @subprocess_timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {out, code}} -> {:ok, out, code}
          _ -> {:error, :timeout}
        end
    end
  end
end
