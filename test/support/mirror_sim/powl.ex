defmodule AshPPlan.MirrorSim.Powl do
  @moduledoc """
  Mirror-sim route handlers for the POWL area (`AshPPlan.POWL`,
  `.Verifier`, `.Project`, `.Reachability`).

  Mounted at `/powl/*` (also tolerates a leading `/powl` when called
  directly, so the module can be served standalone by Bandit).

  Routes (all POST, JSON in/out):

  - `/normalize`    -> `AshPPlan.POWL.normalize/1`
  - `/verify`       -> `AshPPlan.POWL.Verifier.verify/1`
  - `/project`      -> `AshPPlan.POWL.Project.to_reactor_steps/1`
  - `/reachability` -> `AshPPlan.POWL.Reachability.simulate/2` (200 verdict)
  - `/court`        -> same simulation, 422 typed refusal unless `sound`

  ## Wire format

  A model is a node object
  `{"id","operator","label","children":[...],"order_edges":[[s,t]],
  "edges":[[from,to]],"metadata":{"max_iterations":n,"compensation":x}}`
  with operator one of `activity|sequence|choice|loop|partial_order|
  choice_graph`. Choice-graph endpoints are `"start"`, `"end"`,
  `{"child":i}` or a bare integer. Alternatively `{"steps":[...]}` (catalog
  plan) or `{"model": node}`.

  Typed refusals: HTTP 422, `{"refused":true,"broken_term":<reason>,
  "reason":..., "block":...}`. Never 500 on bad input.
  """
  use Plug.Router

  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.POWL
  alias AshPPlan.POWL.Node
  alias AshPPlan.POWL.Project
  alias AshPPlan.POWL.Reachability
  alias AshPPlan.POWL.Verifier

  @operators %{
    "activity" => :activity,
    "sequence" => :sequence,
    "choice" => :choice,
    "loop" => :loop,
    "partial_order" => :partial_order,
    "choice_graph" => :choice_graph
  }

  @max_markings_cap 5_000

  plug(:strip_prefix)
  plug(:match)
  plug(:dispatch)

  @doc "Wired surfaces (module, fun, arity, route)."
  @spec surfaces() :: [
          %{module: module(), fun: atom(), arity: non_neg_integer(), route: String.t()}
        ]
  def surfaces do
    [
      %{module: POWL, fun: :normalize, arity: 1, route: "/powl/normalize"},
      %{module: Verifier, fun: :verify, arity: 1, route: "/powl/verify"},
      %{module: Project, fun: :to_reactor_steps, arity: 1, route: "/powl/project"},
      %{module: Reachability, fun: :simulate, arity: 2, route: "/powl/reachability"},
      %{module: Reachability, fun: :simulate, arity: 2, route: "/powl/court"}
    ]
  end

  @doc false
  def strip_prefix(%Plug.Conn{path_info: ["powl" | rest]} = conn, _opts),
    do: %{conn | path_info: rest}

  def strip_prefix(conn, _opts), do: conn

  post "/normalize" do
    run(conn, fn input, _body ->
      case POWL.normalize(input) do
        {:ok, %Node{} = n} ->
          Json.send_json(conn, 200, %{
            "ok" => true,
            "root_id" => n.id,
            "operator" => Atom.to_string(n.operator),
            "children" => length(n.children),
            "order_edges" => length(n.order_edges)
          })

        {:error, err} ->
          refuse_err(conn, err)
      end
    end)
  end

  post "/verify" do
    run(conn, fn input, _body ->
      case Verifier.verify(input) do
        :ok -> Json.send_json(conn, 200, %{"ok" => true})
        {:error, err} -> refuse_err(conn, err)
      end
    end)
  end

  post "/project" do
    run(conn, fn input, _body ->
      case Project.to_reactor_steps(input) do
        {:ok, %{steps: steps, warnings: warnings}} ->
          Json.send_json(conn, 200, %{
            "ok" => true,
            "steps" => Enum.map(steps, fn s -> j(Map.new(s)) end),
            "warnings" => j(warnings)
          })

        {:error, err} ->
          refuse_err(conn, err)
      end
    end)
  end

  post "/reachability" do
    run(conn, fn input, body ->
      case Reachability.simulate(input, sim_opts(body)) do
        {:ok, verdict} -> Json.send_json(conn, 200, verdict_json(verdict))
        {:error, err} -> refuse_err(conn, err)
      end
    end)
  end

  post "/court" do
    run(conn, fn input, body ->
      case Reachability.simulate(input, sim_opts(body)) do
        {:ok, %{outcome: :sound} = verdict} ->
          Json.send_json(conn, 200, verdict_json(verdict))

        {:ok, verdict} ->
          refuse_err(conn, %{
            reason: verdict.outcome,
            block: %{
              deadlocks: length(verdict.deadlocks),
              orphans: length(verdict.orphans),
              final_reachable: verdict.final_reachable
            }
          })

        {:error, err} ->
          refuse_err(conn, err)
      end
    end)
  end

  match _ do
    Json.refuse(conn, "unknown_route", "no powl route #{conn.request_path}", 404)
  end

  # -- request plumbing

  defp run(conn, fun) do
    with {:ok, raw, conn} <- read_all(conn),
         {:ok, body} <- Json.decode(raw),
         {:ok, input} <- input(body) do
      try do
        fun.(input, body)
      rescue
        e -> Json.refuse(conn, "powl_crash", Exception.message(e))
      catch
        kind, value -> Json.refuse(conn, "powl_crash", inspect({kind, value}, limit: 20))
      end
    else
      {:error, %Jason.DecodeError{}} -> Json.refuse(conn, "powl_decode", "invalid json")
      {:error, reason} -> Json.refuse(conn, "powl_decode", reason)
    end
  end

  defp read_all(conn, acc \\ "") do
    case Plug.Conn.read_body(conn) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_all(conn, acc <> chunk)
      {:error, reason} -> {:error, "body read failed: #{inspect(reason)}"}
    end
  end

  defp input(%{"steps" => steps}) when is_list(steps) do
    decoded =
      Enum.map(steps, fn
        %{} = s ->
          %{
            iri: s["iri"],
            label: s["label"],
            predecessors: s["predecessors"] || []
          }

        other ->
          other
      end)

    {:ok, %{steps: decoded}}
  end

  defp input(%{"model" => model}), do: decode_node(model)
  defp input(%{"operator" => _} = node), do: decode_node(node)
  defp input(_), do: {:error, "body is not a POWL model, {model}, or {steps}"}

  defp sim_opts(body) do
    case body do
      %{"max_markings" => n} when is_integer(n) and n > 0 ->
        [max_markings: min(n, @max_markings_cap)]

      _ ->
        [max_markings: @max_markings_cap]
    end
  end

  defp verdict_json(v) do
    %{
      "outcome" => Atom.to_string(v.outcome),
      "deadlock_count" => length(v.deadlocks),
      "orphan_count" => length(v.orphans),
      "final_reachable" => v.final_reachable,
      "budget_exhausted" => v.budget_exhausted,
      "markings_explored" => v.markings_explored,
      "deadlocks" => Enum.map(v.deadlocks, fn m -> Enum.map(m, &inspect(&1, limit: 8)) end)
    }
  end

  defp refuse_err(conn, %{reason: reason} = err) do
    body =
      reason
      |> Json.refusal(inspect(Map.delete(err, :reason), limit: 30))
      |> Map.put("block", j(Map.get(err, :block, %{})))

    Json.send_json(conn, 422, body)
  end

  defp refuse_err(conn, other), do: Json.refuse(conn, "powl_error", inspect(other, limit: 30))

  # -- decode / encode of the node wire format

  @doc "Decode a wire node map into `%AshPPlan.POWL.Node{}`."
  @spec decode_node(term()) :: {:ok, Node.t()} | {:error, String.t()}
  def decode_node(%{"operator" => op, "id" => id} = m) when is_binary(id) do
    with {:ok, operator} <- fetch_operator(op),
         {:ok, children} <- decode_children(Map.get(m, "children", [])),
         :ok <- check_arity(operator, children),
         {:ok, order_edges} <- decode_pairs(Map.get(m, "order_edges", []), &id_pair/1),
         {:ok, edges} <- decode_pairs(Map.get(m, "edges", []), &endpoint_pair/1) do
      {:ok,
       %Node{
         id: id,
         operator: operator,
         label: label(m["label"]),
         children: children,
         order_edges: order_edges,
         edges: edges,
         metadata: decode_metadata(Map.get(m, "metadata", %{}))
       }}
    end
  end

  def decode_node(_), do: {:error, "node needs string id and operator"}

  defp fetch_operator(op) do
    case Map.fetch(@operators, op) do
      {:ok, operator} -> {:ok, operator}
      :error -> {:error, "unknown operator #{inspect(op)}"}
    end
  end

  defp label(nil), do: nil
  defp label(l) when is_binary(l), do: l
  defp label(l), do: inspect(l)

  defp decode_children(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn c, {:ok, acc} ->
      case decode_node(c) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp decode_children(_), do: {:error, "children must be a list"}

  defp check_arity(:loop, children) when length(children) != 2,
    do: {:error, "loop needs exactly two children (body, redo)"}

  defp check_arity(_, _), do: :ok

  defp decode_pairs(list, f) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn
      [a, b], {:ok, acc} ->
        case f.({a, b}) do
          {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
          :error -> {:halt, {:error, "bad edge #{inspect([a, b])}"}}
        end

      other, _ ->
        {:halt, {:error, "bad edge #{inspect(other)}"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp decode_pairs(_, _), do: {:error, "edges must be a list"}

  defp id_pair({a, b}) when is_binary(a) and is_binary(b), do: {:ok, {a, b}}
  defp id_pair(_), do: :error

  defp endpoint_pair({a, b}) do
    with {:ok, x} <- endpoint(a), {:ok, y} <- endpoint(b), do: {:ok, {x, y}}
  end

  defp endpoint("start"), do: {:ok, :start}
  defp endpoint("end"), do: {:ok, :end}
  defp endpoint(%{"child" => i}) when is_integer(i), do: {:ok, {:child, i}}
  defp endpoint(i) when is_integer(i), do: {:ok, {:child, i}}
  defp endpoint(_), do: :error

  defp decode_metadata(%{} = m) do
    Enum.reduce(m, %{}, fn
      {"max_iterations", n}, acc when is_integer(n) -> Map.put(acc, :max_iterations, n)
      {"compensation", c}, acc when not is_nil(c) -> Map.put(acc, :compensation, c)
      _, acc -> acc
    end)
  end

  defp decode_metadata(_), do: %{}

  @doc "Encode a `%Node{}` to the wire map (test helper; inverse of `decode_node/1`)."
  @spec encode_node(Node.t()) :: map()
  def encode_node(%Node{} = n) do
    %{
      "id" => n.id,
      "operator" => Atom.to_string(n.operator),
      "label" => n.label,
      "children" => Enum.map(n.children, &encode_node/1),
      "order_edges" => Enum.map(n.order_edges, fn {s, t} -> [s, t] end),
      "edges" => Enum.map(n.edges, fn {f, t} -> [enc_ep(f), enc_ep(t)] end),
      "metadata" => Map.new(n.metadata, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp enc_ep(:start), do: "start"
  defp enc_ep(:end), do: "end"
  defp enc_ep({:child, i}), do: %{"child" => i}

  # -- generic jsonable

  defp j(v) when is_struct(v), do: inspect(v, limit: 20)
  defp j(v) when is_map(v), do: Map.new(v, fn {k, x} -> {key(k), j(x)} end)
  defp j(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&j/1)
  defp j(v) when is_list(v), do: Enum.map(v, &j/1)
  defp j(v) when is_nil(v) or is_boolean(v) or is_binary(v) or is_number(v), do: v
  defp j(v) when is_atom(v), do: Atom.to_string(v)
  defp j(v), do: inspect(v, limit: 20)

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_binary(k), do: k
  defp key(k), do: inspect(k)
end
