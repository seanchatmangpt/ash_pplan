defmodule AshPPlan.MirrorSim.Providers do
  @moduledoc """
  Mirror-sim routes for `AshPPlan.Provider*` (registry, resolver, index, qualify and the
  eleven generated providers). Mounted by the router at `/providers/*`; routes below are
  relative to that mount.

  Routes (JSON in/out, typed refusals are HTTP 422):

    * `GET  /index`      - `AshPPlan.Providers.Index.modules/0` with each provider's surface
    * `POST /registry`   - `{providers?: [id], ops: [{op: "seal"|"register", provider: id}]}`
    * `POST /resolve`    - `AshPPlan.Providers.Registry.resolve/3`
    * `POST /qualify`    - `Provider.qualify/2` of one provider
    * `POST /realize`    - `Provider.realize/2` of one provider
    * `POST /check`      - `AshPPlan.Providers.Qualify.check/6`
    * `POST /execute`    - resolve, then run the realization for real: file ops inside a tmp
                           sandbox, network ops against a loopback upstream; other adapters
                           report the resolved step module only
    * `ANY  /upstream/echo` - real local upstream for the network provider
  """
  use Plug.Router

  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.Providers.{Index, Qualify, Registry}

  plug(:match)
  plug(:dispatch)

  @doc "Surface inventory for the coverage compiler."
  @spec surfaces() :: [map()]
  def surfaces do
    [
      %{module: Index, fun: :modules, arity: 0, route: "/providers/index"},
      %{module: Registry, fun: :new, arity: 1, route: "/providers/registry"},
      %{module: Registry, fun: :register, arity: 2, route: "/providers/registry"},
      %{module: Registry, fun: :seal, arity: 3, route: "/providers/registry"},
      %{module: Registry, fun: :providers, arity: 1, route: "/providers/registry"},
      %{module: Registry, fun: :resolve, arity: 3, route: "/providers/resolve"},
      %{
        module: AshPPlan.Providers.Resolver,
        fun: :resolve,
        arity: 3,
        route: "/providers/resolve"
      },
      %{module: Qualify, fun: :check, arity: 6, route: "/providers/check"},
      %{module: Qualify, fun: :realize, arity: 4, route: "/providers/realize"},
      %{module: Qualify, fun: :adapter_available, arity: 1, route: "/providers/qualify"}
    ] ++
      Enum.flat_map(Index.modules(), fn mod ->
        [
          %{module: mod, fun: :qualify, arity: 2, route: "/providers/qualify"},
          %{module: mod, fun: :realize, arity: 2, route: "/providers/realize"}
        ]
      end)
  end

  get "/index" do
    data =
      Enum.map(Index.modules(), fn mod ->
        %{
          "id" => to_string(mod.id()),
          "module" => inspect(mod),
          "capabilities" => mod.capabilities(),
          "properties" => Enum.map(mod.properties(), &to_string/1),
          "evidence" => Enum.map(mod.evidence(), &to_string/1),
          "cost" => mod.cost()
        }
      end)

    Json.send_json(conn, 200, %{"providers" => data})
  end

  post "/registry" do
    with_body(conn, fn m ->
      with {:ok, mods} <- modules_from(m["providers"]),
           {:ok, reg} <- apply_ops(Registry.new(mods), List.wrap(m["ops"])) do
        Json.send_json(conn, 200, registry_json(reg))
      else
        {:error, term, reason} -> Json.refuse(conn, term, reason)
      end
    end)
  end

  post "/resolve" do
    with_body(conn, fn m ->
      with {:ok, mods} <- modules_from(m["providers"]),
           {:ok, reg} <- apply_ops(Registry.new(mods), seal_ops(m["seal"])) do
        case Registry.resolve(reg, requirement(m), context(m)) do
          {:ok, res} -> Json.send_json(conn, 200, resolution_json(res))
          {:error, err} -> send_resolve_refusal(conn, err)
        end
      else
        {:error, term, reason} -> Json.refuse(conn, term, reason)
      end
    end)
  end

  post "/qualify" do
    with_body(conn, fn m ->
      case provider(m["provider"]) do
        {:ok, mod} ->
          case mod.qualify(requirement(m), context(m)) do
            :ok -> Json.send_json(conn, 200, %{"ok" => true, "provider" => to_string(mod.id())})
            {:error, reason} -> Json.refuse(conn, "qualify_refused", reason)
          end

        {:error, term, reason} ->
          Json.refuse(conn, term, reason)
      end
    end)
  end

  post "/realize" do
    with_body(conn, fn m ->
      case provider(m["provider"]) do
        {:ok, mod} ->
          case mod.realize(requirement(m), context(m)) do
            {:ok, r} ->
              Json.send_json(conn, 200, %{
                "ok" => true,
                "capability" => r.capability,
                "provider" => to_string(r.provider),
                "adapter" => to_string(r.binding.adapter),
                "op" => to_string(r.binding.op),
                "options" => inspect(r.options),
                "properties" => Enum.map(r.properties, &to_string/1)
              })

            {:error, reason} ->
              Json.refuse(conn, "realize_refused", reason)
          end

        {:error, term, reason} ->
          Json.refuse(conn, term, reason)
      end
    end)
  end

  post "/check" do
    with_body(conn, fn m ->
      known = known_atoms()

      result =
        Qualify.check(
          requirement(m),
          context(m),
          List.wrap(m["capabilities"]),
          Enum.map(List.wrap(m["declared_properties"]), &to_known(&1, known)),
          Enum.map(List.wrap(m["declared_evidence"]), &to_known(&1, known)),
          Enum.map(
            List.wrap(m["authorities"] || ["none", "observe", "select", "plan", "construct"]),
            &to_known(&1, known)
          )
        )

      case result do
        :ok -> Json.send_json(conn, 200, %{"ok" => true})
        {:error, reason} -> Json.refuse(conn, "qualify_check_refused", reason)
      end
    end)
  end

  post "/execute" do
    with_body(conn, fn m ->
      case Registry.resolve(Registry.default(), requirement(m), context(m)) do
        {:ok, res} -> execute(conn, res, if(is_map(m["args"]), do: m["args"], else: %{}))
        {:error, err} -> send_resolve_refusal(conn, err)
      end
    end)
  end

  match "/upstream/echo" do
    {:ok, raw, conn} = read_body(conn)

    Json.send_json(conn, 200, %{
      "upstream" => "mirror-sim",
      "method" => conn.method,
      "body" => raw
    })
  end

  match _ do
    Json.refuse(
      conn,
      "unknown_route",
      "no providers route #{conn.method} #{conn.request_path}",
      404
    )
  end

  # --- execution ------------------------------------------------------------------------

  defp execute(conn, %{adapter: :reactor_file, op: op, step: {step, _}}, args) do
    case file_exec(op, args) do
      {:ok, result} ->
        Json.send_json(conn, 200, %{
          "executed" => true,
          "adapter" => "reactor_file",
          "op" => to_string(op),
          "step" => inspect(step),
          "result" => result
        })

      {:error, term, reason} ->
        Json.refuse(conn, term, reason)
    end
  end

  defp execute(conn, %{adapter: :reactor_req, op: op, realization: r, step: {step, _}}, args) do
    method = Keyword.get(r.options, :fun, :get)

    with url when is_binary(url) <- args["url"],
         :ok <- loopback?(url) do
      opts =
        [method: method, url: url, retry: false, decode_body: false] ++
          if method in [:post, :put, :patch], do: [body: to_string(args["body"] || "")], else: []

      case Req.request(opts) do
        {:ok, resp} ->
          Json.send_json(conn, 200, %{
            "executed" => true,
            "adapter" => "reactor_req",
            "op" => to_string(op),
            "step" => inspect(step),
            "status" => resp.status,
            "body" => body_text(resp.body)
          })

        {:error, e} ->
          Json.refuse(conn, "network_failed", Exception.message(e))
      end
    else
      nil -> Json.refuse(conn, "missing_url", "args.url required")
      {:error, term, reason} -> Json.refuse(conn, term, reason)
      _ -> Json.refuse(conn, "invalid_url", "args.url must be a string")
    end
  end

  defp execute(conn, %{adapter: adapter, op: op, step: {step, _}}, _args) do
    Json.send_json(conn, 200, %{
      "executed" => false,
      "adapter" => to_string(adapter),
      "op" => to_string(op),
      "step" => inspect(step),
      "note" => "resolved to a real Reactor.Step module; no sandboxed run for this adapter"
    })
  end

  defp file_exec(:file_write, args) do
    with {:ok, p} <- sandbox_path(args["path"]),
         :ok <- File.mkdir_p(Path.dirname(p)),
         :ok <- File.write(p, to_string(args["content"] || "")) do
      {:ok, %{"path" => args["path"]}}
    else
      {:error, term, reason} -> {:error, term, reason}
      {:error, reason} -> {:error, "file_error", reason}
    end
  end

  defp file_exec(:file_read, args) do
    with {:ok, p} <- sandbox_path(args["path"]),
         {:ok, bin} <- File.read(p) do
      {:ok, %{"content" => bin}}
    else
      {:error, term, reason} -> {:error, term, reason}
      {:error, reason} -> {:error, "file_error", reason}
    end
  end

  defp file_exec(:file_mkdir, args) do
    with {:ok, p} <- sandbox_path(args["path"]),
         :ok <- File.mkdir_p(p) do
      {:ok, %{"path" => args["path"]}}
    else
      {:error, term, reason} -> {:error, term, reason}
      {:error, reason} -> {:error, "file_error", reason}
    end
  end

  defp file_exec(:file_copy, args) do
    with {:ok, src} <- sandbox_path(args["path"]),
         {:ok, dest} <- sandbox_path(args["dest"]),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- File.cp(src, dest) do
      {:ok, %{"dest" => args["dest"]}}
    else
      {:error, term, reason} -> {:error, term, reason}
      {:error, reason} -> {:error, "file_error", reason}
    end
  end

  defp file_exec(:file_delete, args) do
    with {:ok, p} <- sandbox_path(args["path"]),
         :ok <- File.rm(p) do
      {:ok, %{"path" => args["path"]}}
    else
      {:error, term, reason} -> {:error, term, reason}
      {:error, reason} -> {:error, "file_error", reason}
    end
  end

  defp file_exec(op, _args), do: {:error, "unsupported_file_op", op}

  @doc "Sandbox root for file execution."
  @spec sandbox_root() :: Path.t()
  def sandbox_root, do: Path.join(System.tmp_dir!(), "mirror_sim_providers")

  defp sandbox_path(rel) when is_binary(rel) and rel != "" do
    if Path.type(rel) == :relative and ".." not in Path.split(rel) do
      {:ok, Path.join(sandbox_root(), rel)}
    else
      {:error, "path_outside_sandbox", rel}
    end
  end

  defp sandbox_path(other), do: {:error, "invalid_path", other}

  defp loopback?(url) do
    case URI.parse(url) do
      %URI{host: h} when h in ["127.0.0.1", "localhost", "::1"] -> :ok
      _ -> {:error, "non_loopback_upstream", url}
    end
  end

  defp body_text(b) when is_binary(b), do: b
  defp body_text(b), do: inspect(b)

  # --- request decoding -----------------------------------------------------------------

  defp with_body(conn, fun) do
    case body_map(conn) do
      {:ok, m} -> fun.(m)
      {:error, reason} -> Json.refuse(conn, "invalid_body", reason)
    end
  end

  defp body_map(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn) do
      {:ok, "", _} ->
        {:ok, %{}}

      {:ok, raw, _} ->
        case Jason.decode(raw) do
          {:ok, m} when is_map(m) -> {:ok, m}
          {:ok, _} -> {:error, "body must be a JSON object"}
          {:error, _} -> {:error, "body is not valid JSON"}
        end

      _ ->
        {:error, "body unreadable"}
    end
  end

  defp body_map(%Plug.Conn{body_params: %{"_json" => _}}),
    do: {:error, "body must be a JSON object"}

  defp body_map(%Plug.Conn{body_params: m}) when is_map(m), do: {:ok, m}

  defp known_atoms do
    from_providers =
      Enum.flat_map(Index.modules(), fn mod -> mod.properties() ++ mod.evidence() end)

    (from_providers ++ Qualify.authorities() ++ [:do])
    |> Map.new(&{Atom.to_string(&1), &1})
  end

  defp to_known(v, known) when is_binary(v), do: Map.get(known, v, v)
  defp to_known(v, _known), do: v

  defp requirement(m) do
    known = known_atoms()

    base = %{
      capability: m["capability"],
      properties: m["properties"] |> List.wrap() |> Enum.map(&to_known(&1, known)),
      evidence: m["evidence"] |> List.wrap() |> Enum.map(&to_known(&1, known))
    }

    case Map.fetch(m, "authority") do
      {:ok, a} -> Map.put(base, :authority, to_known(a, known))
      :error -> base
    end
  end

  defp context(m) do
    known = known_atoms()

    case Map.fetch(m, "ceiling") do
      {:ok, c} -> %{ceiling: to_known(c, known)}
      :error -> %{}
    end
  end

  defp provider(id) when is_binary(id) do
    case Enum.find(Index.modules(), &(to_string(&1.id()) == id)) do
      nil -> {:error, "unknown_provider", id}
      mod -> {:ok, mod}
    end
  end

  defp provider(other), do: {:error, "unknown_provider", other}

  defp modules_from(nil), do: {:ok, Index.modules()}

  defp modules_from(ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case provider(id) do
        {:ok, mod} -> {:cont, {:ok, acc ++ [mod]}}
        err -> {:halt, err}
      end
    end)
  end

  defp modules_from(other), do: {:error, "invalid_providers", other}

  defp seal_ops(nil), do: []
  defp seal_ops(ids) when is_list(ids), do: Enum.map(ids, &%{"op" => "seal", "provider" => &1})
  defp seal_ops(other), do: [%{"op" => "seal", "provider" => other}]

  defp apply_ops(reg, ops) do
    Enum.reduce_while(ops, {:ok, reg}, fn
      %{"op" => "seal", "provider" => id}, {:ok, r} ->
        case provider(id) do
          {:ok, mod} -> {:cont, {:ok, Registry.seal(r, mod, :mirror_sim_sealed)}}
          err -> {:halt, err}
        end

      %{"op" => "register", "provider" => id}, {:ok, r} ->
        case provider(id) do
          {:ok, mod} -> {:cont, {:ok, Registry.register(r, mod)}}
          err -> {:halt, err}
        end

      other, _ ->
        {:halt, {:error, "invalid_op", other}}
    end)
  end

  # --- response encoding ----------------------------------------------------------------

  defp registry_json(reg) do
    %{
      "providers" => Enum.map(Registry.providers(reg), &to_string(&1.id())),
      "sealed" => Map.new(reg.sealed, fn {mod, why} -> {to_string(mod.id()), inspect(why)} end),
      "generation" => reg.generation
    }
  end

  defp resolution_json(res) do
    {step, _opts} = res.step

    %{
      "ok" => true,
      "provider" => to_string(res.provider.id()),
      "adapter" => to_string(res.adapter),
      "op" => to_string(res.op),
      "step" => inspect(step),
      "candidates" => Enum.map(res.candidates, &to_string(&1.id())),
      "rejected" => rejected_json(res.rejected),
      "reason" => res.reason
    }
  end

  defp rejected_json(rejected) do
    Enum.map(rejected, fn {mod, why} ->
      %{"provider" => to_string(mod.id()), "why" => inspect(why, limit: 20)}
    end)
  end

  defp send_resolve_refusal(conn, err) do
    body =
      Json.refusal(err[:reason] || "no_qualified_provider", inspect(err, limit: 30))
      |> Map.put("rejected", rejected_json(Map.get(err, :rejected, [])))
      |> Map.put("detail", inspect(Map.get(err, :detail)))

    Json.send_json(conn, 422, body)
  end
end
