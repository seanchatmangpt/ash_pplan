defmodule AshPPlan.MirrorSim.TLA do
  @moduledoc """
  Mirror-sim routes (mounted at `/tla/*`) over the real FOND -> TLA+ surface:
  `AshPPlan.FOND.to_tla/5` (`AshPPlan.FOND.TLA.render/5`), `AshPPlan.FOND.validate_policy/4`,
  `AshPPlan.FOND.TLA.{JSON, Manifest, Mutation}`, the in-process `AshPPlan.Test.TLAReader`
  checker, the optional external checkers (`AshPPlan.Test.NativeTLA`, `AshPPlan.Test.TLCCourt`)
  and `AshPPlan.Test.FONDTLABench`.

  Wire domain request (JSON): `{"transitions": {"s": {"act": ["t", ...]}}, "goals": [...],
  "policy": {"s": "act"}, "initial": "s", "mode": "strong" | "strong_cyclic",
  "module_name": optional}`. State and action names are converted with `String.to_atom/1`
  (test-only server).

  Responses: 200 with data; typed refusal 422 (`refused`, `broken_term`, `reason`); 503
  `{"unavailable": true, "reason": ...}` when an optional external checker is absent. A checker
  verdict (`admitted`/`refused`) is an observation and is returned with 200; only a refused
  *request* (including a policy refused by `validate_policy/4`) is 422.

  `/read` and `/mutate` interpret the rendered cfg: when `PROPERTY GoalReached` is absent the
  liveness verdict is not checked (the in-process reader itself sees only module text).
  """
  use Plug.Router

  import Plug.Conn

  alias AshPPlan.FOND
  alias AshPPlan.FOND.TLA.{JSON, Manifest, Mutation}
  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.Test.{FONDTLABench, NativeTLA, TLAReader, TLCCourt}

  @default_cfg "SPECIFICATION Spec\nINVARIANT TypeOK\nPROPERTY GoalReached\n"
  @bench_cap 200
  @bench_families %{
    "retry_chain" => :retry_chain,
    "fanout" => :fanout,
    "terminal_chain" => :terminal_chain
  }

  plug(:match)
  plug(:dispatch)

  post("/render", do: handle(conn, &render/1))
  post("/validate", do: handle(conn, &validate/1))
  post("/read", do: handle(conn, &read/1))
  post("/envelope", do: handle(conn, &envelope/1))
  post("/decode", do: handle(conn, &decode/1))
  post("/manifest", do: handle(conn, &manifest/1))
  post("/manifest/matches", do: handle(conn, &manifest_matches/1))
  post("/mutate", do: handle(conn, &mutate/1))
  post("/native", do: handle(conn, &native/1))
  post("/tlc", do: handle(conn, &tlc/1))
  post("/bench", do: handle(conn, &bench/1))

  match _ do
    Json.refuse(conn, "unknown_tla_route", conn.request_path, 404)
  end

  @doc "Surfaces reachable through this area."
  @spec surfaces() :: [
          %{module: module(), fun: atom(), arity: non_neg_integer(), route: String.t()}
        ]
  def surfaces do
    [
      %{module: FOND, fun: :to_tla, arity: 5, route: "/tla/render"},
      %{module: FOND.TLA, fun: :render, arity: 5, route: "/tla/render"},
      %{module: FOND, fun: :new, arity: 2, route: "/tla/render"},
      %{module: FOND, fun: :validate_policy, arity: 4, route: "/tla/validate"},
      %{module: JSON, fun: :encode_map, arity: 1, route: "/tla/envelope"},
      %{module: JSON, fun: :decode_map, arity: 1, route: "/tla/decode"},
      %{module: Manifest, fun: :from_rendered, arity: 1, route: "/tla/manifest"},
      %{module: Manifest, fun: :matches?, arity: 2, route: "/tla/manifest/matches"},
      %{module: Mutation, fun: :suite, arity: 1, route: "/tla/mutate"},
      %{module: TLAReader, fun: :check!, arity: 1, route: "/tla/read"},
      %{module: NativeTLA, fun: :check_string!, arity: 3, route: "/tla/native"},
      %{module: TLCCourt, fun: :check!, arity: 1, route: "/tla/tlc"},
      %{module: FONDTLABench, fun: :measure, arity: 4, route: "/tla/bench"},
      %{module: FONDTLABench, fun: :measure_projection, arity: 2, route: "/tla/bench"}
    ]
  end

  @doc """
  Maps any term to a JSON-encodable one: atoms to strings, `MapSet` to lists, map keys to
  strings, tuples and other terms to `inspect/1` strings.
  """
  @spec jsonable(term()) :: term()
  def jsonable(nil), do: nil
  def jsonable(true), do: true
  def jsonable(false), do: false
  def jsonable(v) when is_atom(v), do: Atom.to_string(v)
  def jsonable(v) when is_binary(v) or is_number(v), do: v
  def jsonable(%MapSet{} = v), do: v |> Enum.map(&jsonable/1) |> Enum.sort()
  def jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)

  def jsonable(v) when is_map(v) and not is_struct(v),
    do: Map.new(v, fn {k, x} -> {key_text(k), jsonable(x)} end)

  def jsonable(v), do: inspect(v, limit: 50)

  defp key_text(k) when is_atom(k), do: Atom.to_string(k)
  defp key_text(k) when is_binary(k), do: k
  defp key_text(k), do: inspect(k, limit: 20)

  # -- request plumbing -------------------------------------------------------

  defp handle(conn, fun) do
    case params(conn) do
      {:ok, p, conn} ->
        case safe(fun, p) do
          {:ok, data} ->
            Json.send_json(conn, 200, data)

          {:refuse, term, reason, extra} ->
            Json.send_json(conn, 422, Map.merge(Json.refusal(term, reason), extra))

          {:unavailable, reason} ->
            Json.send_json(conn, 503, %{"unavailable" => true, "reason" => reason})
        end

      {:error, conn} ->
        Json.refuse(conn, "invalid_json", "request body is not a JSON object")
    end
  end

  defp safe(fun, p) do
    fun.(p)
  rescue
    e -> {:refuse, "checker_exception", Exception.message(e), %{}}
  end

  defp params(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> read_params(conn)
      map when is_map(map) and map_size(map) > 0 -> {:ok, Map.delete(map, "_json"), conn}
      _ -> read_params(conn)
    end
  end

  defp read_params(conn) do
    case read_body(conn) do
      {:ok, "", conn} ->
        {:ok, %{}, conn}

      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{} = map} -> {:ok, map, conn}
          _ -> {:error, conn}
        end

      {_, _, conn} ->
        {:error, conn}
    end
  end

  # -- domain decoding --------------------------------------------------------

  defp build(p) do
    transitions =
      case p["transitions"] do
        %{} = m ->
          Map.new(m, fn {s, acts} ->
            {atom!(s),
             acts |> map!(:transitions) |> Map.new(fn {a, ts} -> {atom!(a), atoms!(ts)} end)}
          end)

        other ->
          throw({:bad, %{reason: :invalid_transition_relation, value: other}})
      end

    goals = atoms!(p["goals"] || [])

    policy =
      (p["policy"] || %{}) |> map!(:policy) |> Map.new(fn {s, a} -> {atom!(s), atom!(a)} end)

    initial = atom!(p["initial"])

    with {:ok, mode} <- mode(p["mode"]),
         {:ok, domain} <- FOND.new(transitions, goals) do
      {:ok, domain, policy, initial, mode}
    end
  catch
    {:bad, m} -> {:error, m}
  end

  defp mode(nil), do: {:ok, :strong_cyclic}
  defp mode("strong"), do: {:ok, :strong}
  defp mode("strong_cyclic"), do: {:ok, :strong_cyclic}
  defp mode(other), do: {:error, %{reason: :invalid_mode, mode: other}}

  defp atom!(v) when is_binary(v), do: String.to_atom(v)
  defp atom!(v), do: throw({:bad, %{reason: :invalid_name, value: v}})

  defp atoms!(v) when is_list(v), do: Enum.map(v, &atom!/1)
  defp atoms!(v), do: throw({:bad, %{reason: :invalid_name_list, value: v}})

  defp map!(%{} = m, _what), do: m
  defp map!(v, what), do: throw({:bad, %{reason: :"invalid_#{what}", value: v}})

  defp render_opts(p) do
    case p["module_name"] do
      name when is_binary(name) -> [module_name: name]
      _ -> []
    end
  end

  defp fail(%{reason: reason} = m),
    do: {:refuse, reason, inspect(m, limit: 50), %{"detail" => jsonable(m)}}

  defp fail(other), do: {:refuse, "invalid_request", inspect(other, limit: 50), %{}}

  defp rendered(p) do
    with {:ok, d, pol, init, mode} <- build(p),
         {:ok, r} <- FOND.TLA.render(d, pol, init, mode, render_opts(p)) do
      {:ok, r}
    else
      {:error, m} -> fail(m)
    end
  end

  # Module text and cfg: raw `module` text if given, else rendered from the domain request.
  defp source(p) do
    case p["module"] do
      text when is_binary(text) ->
        name =
          p["module_name"] ||
            case Regex.run(~r/---- MODULE ([A-Za-z][A-Za-z0-9_]*) ----/, text) do
              [_, n] -> n
              _ -> "FONDPolicy"
            end

        {:ok, name, text, p["cfg"] || @default_cfg}

      _ ->
        case rendered(p) do
          {:ok, r} -> {:ok, r.module_name, r.module, r.cfg}
          other -> other
        end
    end
  end

  # -- routes -----------------------------------------------------------------

  defp render(p) do
    with {:ok, r} <- rendered(p) do
      {:ok,
       r
       |> JSON.encode_map()
       |> Map.put("state_names", Map.new(r.state_names, fn {k, v} -> {inspect(k), v} end))}
    end
  end

  defp validate(p) do
    case build(p) do
      {:ok, d, pol, init, mode} ->
        case FOND.validate_policy(d, pol, init, mode) do
          {:ok, report} ->
            {:ok, %{"verdict" => "admitted", "report" => jsonable(report)}}

          {:error, m} ->
            {:refuse, Map.get(m, :reason, :refused), inspect(m, limit: 50),
             %{"verdict" => "refused", "detail" => jsonable(m)}}
        end

      {:error, m} ->
        fail(m)
    end
  end

  defp read(p) do
    with {:ok, _name, module, cfg} <- source(p) do
      {:ok, reader_result(module, cfg)}
    end
  end

  defp envelope(p) do
    with {:ok, r} <- rendered(p), do: {:ok, JSON.encode_map(r)}
  end

  defp decode(p) do
    case p["envelope"] do
      %{} = env ->
        case JSON.decode_map(env) do
          {:ok, r} -> {:ok, %{"decoded" => jsonable(Map.delete(r, :state_names))}}
          {:error, m} -> fail(m)
        end

      other ->
        fail(%{reason: :invalid_tla_json, value: other})
    end
  end

  defp manifest(p) do
    with {:ok, r} <- rendered(p), do: {:ok, jsonable(Manifest.from_rendered(r))}
  end

  defp manifest_matches(p) do
    with {:ok, r} <- rendered(p) do
      candidate = %{r | module: r.module <> to_string(p["module_suffix"] || "")}
      {:ok, %{"matches" => Manifest.matches?(Manifest.from_rendered(r), candidate)}}
    end
  end

  defp mutate(p) do
    with {:ok, r} <- rendered(p) do
      baseline = classify(r.module, r.cfg)

      mutants =
        for {name, m} <- Mutation.suite(r) do
          result = classify(m.module, m.cfg)
          %{"name" => Atom.to_string(name), "result" => result, "flipped" => result != baseline}
        end

      {:ok, %{"baseline" => baseline, "mutants" => mutants}}
    end
  end

  defp native(p) do
    with {:ok, name, module, cfg} <- source(p) do
      case NativeTLA.availability() do
        :ok ->
          try do
            r = NativeTLA.check_string!(name, module, cfg)

            {:ok,
             %{
               "verdict" => Atom.to_string(r.verdict),
               "kind" => Atom.to_string(r.kind),
               "stats" => jsonable(r.stats)
             }}
          rescue
            e in RuntimeError ->
              # NativeTLA.classify!/1 only recognizes "violated!" + "Counterexample trace";
              # tla-rs v0.11.1 reports a liveness violation as "Liveness property violated:
              # <name>". That explicit tla-rs message is a refusal; anything else re-raises.
              if Exception.message(e) =~ "Liveness property violated:" do
                {:ok,
                 %{
                   "verdict" => "refused",
                   "kind" => "liveness_violation",
                   "stats" => %{},
                   "classified_by" => "sim_liveness_message"
                 }}
              else
                reraise e, __STACKTRACE__
              end
          end

        {:unavailable, reason} ->
          {:unavailable, reason}
      end
    end
  end

  defp tlc(p) do
    with {:ok, name, module, cfg} <- source(p) do
      case TLCCourt.availability() do
        :ok ->
          r = TLCCourt.check!(%{module_name: name, module: module, cfg: cfg})

          {:ok,
           %{
             "verdict" => Atom.to_string(r.verdict),
             "kind" => Atom.to_string(r.kind),
             "exit_status" => r.exit_status
           }}

        {:unavailable, reason} ->
          {:unavailable, reason}
      end
    end
  end

  defp bench(p) do
    family = Map.get(@bench_families, p["family"])
    n = p["n"]

    cond do
      family == nil ->
        fail(%{reason: :unknown_bench_family, family: p["family"]})

      not (is_integer(n) and n >= 2 and n <= @bench_cap) ->
        fail(%{reason: :bench_size_out_of_range, n: n, max: @bench_cap})

      family == :terminal_chain ->
        r = FONDTLABench.measure_projection(:terminal_chain, n)
        {:ok, jsonable(Map.take(r, [:family, :n, :mode, :states, :verdict, :refusal]))}

      true ->
        case mode(p["mode"]) do
          {:ok, mode} ->
            r = FONDTLABench.measure(family, n, mode, 1)

            {:ok,
             jsonable(
               Map.take(r, [:family, :n, :mode, :states, :module_bytes, :verdict, :reader_verdict])
             )}

          {:error, m} ->
            fail(m)
        end
    end
  end

  # -- reader classification --------------------------------------------------

  defp reader_result(module, cfg) do
    r = TLAReader.check!(module)

    {r, dropped?} =
      if r.kind == :liveness and not String.contains?(cfg, "PROPERTY GoalReached") do
        {%{verdict: :admitted, kind: :no_error, witness: nil}, true}
      else
        {r, false}
      end

    %{
      "verdict" => Atom.to_string(r.verdict),
      "kind" => Atom.to_string(r.kind),
      "witness" => jsonable(r.witness),
      "property_dropped" => dropped?
    }
  end

  defp classify(module, cfg) do
    r = reader_result(module, cfg)
    %{"verdict" => r["verdict"], "kind" => r["kind"]}
  rescue
    _ -> %{"verdict" => "error", "kind" => "outside_fragment"}
  end
end
