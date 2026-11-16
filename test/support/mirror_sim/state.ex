defmodule AshPPlan.MirrorSim.State do
  @moduledoc """
  Mirror-sim area `state` (mounted at `/state/*`).

  Drives the REAL `AshPPlan.StateMachine`, `Obligation`, `Realization`, `Digest`,
  `Config` and `ControlPlane` modules. Every handler is a thin JSON adapter: it
  decodes the request, calls the real function, and encodes the returned term.
  `encode/1` is public so parity courts can encode a direct call with the exact
  same encoder and compare it to the wire response.

  Typed refusals: `{"refused":true,"broken_term":...,"reason":...}` with HTTP 422.
  Bad input never yields a 500.

  Wire conventions (test-env simulation only): JSON strings stay strings as
  planner terms, except `"*"` which decodes to the wildcard atom `:*`.
  """

  use Plug.Router

  alias AshPPlan.{ControlPlane, Config, Digest, Obligation, Realization, StateMachine}

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:dispatch)

  @resources %{
    "integration" => AshPPlan.StateMachineIntegrationResource,
    "control_plane" => AshPPlan.ControlPlaneIntegrationResource
  }

  @doc "Surface inventory for the router coverage compiler."
  def surfaces do
    [
      %{
        module: StateMachine,
        fun: :from_transitions,
        arity: 4,
        route: "/state/projection/from_transitions"
      },
      %{
        module: StateMachine,
        fun: :from_transitions,
        arity: 2,
        route: "/state/projection/from_transitions"
      },
      %{
        module: StateMachine,
        fun: :from_transitions,
        arity: 3,
        route: "/state/projection/from_transitions"
      },
      %{module: StateMachine, fun: :from_resource, arity: 1, route: "/state/resource/project"},
      %{module: StateMachine, fun: :from_resource, arity: 2, route: "/state/resource/project"},
      %{module: Obligation, fun: :mint, arity: 4, route: "/state/obligation/mint"},
      %{
        module: StateMachine,
        fun: :describe_resource,
        arity: 1,
        route: "/state/resource/describe"
      },
      %{
        module: StateMachine,
        fun: :capabilities,
        arity: 1,
        route: "/state/resource/capabilities"
      },
      %{
        module: StateMachine,
        fun: :possible_next_states,
        arity: 1,
        route: "/state/resource/possible_next_states"
      },
      %{
        module: StateMachine,
        fun: :possible_next_states,
        arity: 2,
        route: "/state/resource/possible_next_states"
      },
      %{module: Obligation, fun: :mint, arity: 5, route: "/state/obligation/mint"},
      %{module: Obligation, fun: :verify_digest, arity: 1, route: "/state/obligation/verify"},
      %{module: Realization, fun: :adapters, arity: 0, route: "/state/realization/adapters"},
      %{module: Realization, fun: :op_for, arity: 1, route: "/state/realization/op_for"},
      %{module: Realization, fun: :validate, arity: 1, route: "/state/realization/validate"},
      %{module: Realization, fun: :from_map, arity: 2, route: "/state/realization/from_map"},
      %{module: Realization, fun: :new, arity: 2, route: "/state/realization/new"},
      %{module: Digest, fun: :hash, arity: 1, route: "/state/digest/hash"},
      %{module: Digest, fun: :hex, arity: 1, route: "/state/digest/hex"},
      %{module: Config, fun: :extra_adapters, arity: 0, route: "/state/config"},
      %{module: Config, fun: :extra_capability_families, arity: 0, route: "/state/config"},
      %{module: Config, fun: :standing_flight_timeout_ms, arity: 0, route: "/state/config"},
      %{module: Config, fun: :durable_store_module, arity: 0, route: "/state/config"},
      %{module: Config, fun: :durable_halt_timeout, arity: 0, route: "/state/config"},
      %{module: Config, fun: :digest_module, arity: 0, route: "/state/config"},
      %{module: ControlPlane, fun: :describe, arity: 1, route: "/state/control_plane/describe"},
      %{
        module: ControlPlane,
        fun: :action_catalog,
        arity: 1,
        route: "/state/control_plane/action_catalog"
      }
    ]
  end

  # ---- state machine -------------------------------------------------------

  post "/projection/from_transitions" do
    run(conn, fn p ->
      states = conv(Map.get(p, "states"))
      transitions = decode_transitions(Map.get(p, "transitions", []))
      goals = conv(Map.get(p, "goals", []))

      opts =
        []
        |> put_opt(p, "wildcard_states")
        |> put_opt(p, "wildcard_actions")

      # Dispatch by the arity the request implies: /4 with wildcard options,
      # /3 with explicit goals, /2 with neither.
      cond do
        opts != [] -> StateMachine.from_transitions(states, transitions, goals, opts)
        Map.has_key?(p, "goals") -> StateMachine.from_transitions(states, transitions, goals)
        true -> StateMachine.from_transitions(states, transitions)
      end
    end)
  end

  post "/resource/project" do
    run(conn, fn p ->
      with {:ok, res} <- resource(p) do
        goals = p |> Map.get("goals", []) |> conv() |> existing_atoms()
        StateMachine.from_resource(res, goals)
      end
    end)
  end

  post "/resource/describe" do
    run(conn, fn p ->
      with {:ok, res} <- resource(p), do: StateMachine.describe_resource(res)
    end)
  end

  post "/resource/capabilities" do
    run(conn, fn p ->
      with {:ok, res} <- resource(p), do: StateMachine.capabilities(res)
    end)
  end

  post "/resource/possible_next_states" do
    run(conn, fn p ->
      with {:ok, res} <- resource(p),
           {:ok, record} <- record(res, p) do
        case Map.fetch(p, "action") do
          :error -> StateMachine.possible_next_states(record)
          {:ok, action} -> StateMachine.possible_next_states(record, action_atom(action))
        end
      end
    end)
  end

  # ---- obligation ----------------------------------------------------------

  post "/obligation/mint" do
    run(conn, fn p ->
      payload = Map.get(p, "payload")

      if is_map(payload) do
        opts =
          []
          |> put_kw(:expires_at, Map.get(p, "expires_at"))
          |> put_kw(:metadata, Map.get(p, "metadata"))

        {:ok,
         Obligation.mint(
           Map.get(p, "run_id"),
           Map.get(p, "step_name"),
           Map.get(p, "intent"),
           payload,
           opts
         )}
      else
        {:error, %{reason: :payload_must_be_map}}
      end
    end)
  end

  post "/obligation/verify" do
    run(conn, fn p ->
      ob =
        case Map.get(p, "obligation") do
          %{} = m -> struct(Obligation, atomize(m, ~w(id run_id step_name intent payload digest
                                                      issued_at expires_at metadata)))
          other -> other
        end

      {:ok, %{valid: Obligation.verify_digest(ob)}}
    end)
  end

  # ---- realization ---------------------------------------------------------

  get "/realization/adapters" do
    run(conn, fn _p -> {:ok, Realization.adapters()} end)
  end

  post "/realization/op_for" do
    run(conn, fn p ->
      case Map.get(p, "capability") do
        cap when is_binary(cap) -> {:ok, Realization.op_for(cap)}
        other -> {:error, %{reason: :capability_must_be_string, capability: other}}
      end
    end)
  end

  post "/realization/validate" do
    run(conn, fn p ->
      with {:ok, cap, map} <- realization_input(p) do
        case Realization.validate(Realization.from_map(map, cap)) do
          :ok -> {:ok, %{valid: true}}
          {:error, _} = e -> e
        end
      end
    end)
  end

  post "/realization/from_map" do
    run(conn, fn p ->
      with {:ok, cap, map} <- realization_input(p) do
        {:ok, Realization.from_map(map, cap)}
      end
    end)
  end

  post "/realization/new" do
    run(conn, fn p ->
      with {:ok, cap, map} <- realization_input(p) do
        Realization.new(map, cap)
      end
    end)
  end

  # ---- digest --------------------------------------------------------------

  post "/digest/hash" do
    run(conn, fn p ->
      case Map.get(p, "input") do
        input when is_binary(input) ->
          raw = Digest.hash(input)
          {:ok, %{hash_hex: Digest.hex(raw), bytes: byte_size(raw)}}

        other ->
          {:error, %{reason: :input_must_be_string, input: other}}
      end
    end)
  end

  post "/digest/hex" do
    run(conn, fn p ->
      with b64 when is_binary(b64) <- Map.get(p, "base64"),
           {:ok, raw} <- Base.decode64(b64) do
        {:ok, %{hex: Digest.hex(raw)}}
      else
        _ -> {:error, %{reason: :base64_required}}
      end
    end)
  end

  # ---- config --------------------------------------------------------------

  get "/config" do
    run(conn, fn _p ->
      {:ok,
       %{
         extra_adapters: Config.extra_adapters(),
         extra_capability_families: Config.extra_capability_families(),
         standing_flight_timeout_ms: Config.standing_flight_timeout_ms(),
         durable_store_module: Config.durable_store_module(),
         durable_halt_timeout: Config.durable_halt_timeout(),
         digest_module: Config.digest_module()
       }}
    end)
  end

  # ---- control plane -------------------------------------------------------

  post "/control_plane/describe" do
    run(conn, fn p ->
      with {:ok, res} <- resource(p), do: ControlPlane.describe(res)
    end)
  end

  post "/control_plane/action_catalog" do
    run(conn, fn p ->
      with {:ok, res} <- resource(p), do: {:ok, ControlPlane.action_catalog(res)}
    end)
  end

  match _ do
    refuse(conn, 404, "route_not_found", "no such /state route")
  end

  # ---- encoding ------------------------------------------------------------

  @doc "JSON-safe encoding of any planner term (shared with parity courts)."
  def encode(nil), do: nil
  def encode(true), do: true
  def encode(false), do: false
  def encode(a) when is_atom(a), do: Atom.to_string(a)
  def encode(n) when is_number(n), do: n
  def encode(b) when is_binary(b), do: if(String.valid?(b), do: b, else: Base.encode64(b))
  def encode(%MapSet{} = s), do: s |> MapSet.to_list() |> Enum.map(&encode/1) |> Enum.sort()
  def encode(%_{} = s), do: s |> Map.from_struct() |> encode()

  def encode(%{} = m) do
    Map.new(m, fn {k, v} ->
      ek = encode(k)
      {if(is_binary(ek), do: ek, else: inspect(k)), encode(v)}
    end)
  end

  def encode(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&encode/1)
  def encode(l) when is_list(l), do: Enum.map(l, &encode/1)
  def encode(other), do: inspect(other)

  # ---- helpers -------------------------------------------------------------

  defp run(conn, fun) do
    params =
      case conn.body_params do
        %{} = m when not is_struct(m) -> Map.merge(conn.query_params |> ensure_map(), m)
        _ -> ensure_map(conn.query_params)
      end

    try do
      case fun.(params) do
        {:ok, value} -> json(conn, 200, %{ok: true, result: encode(value)})
        {:error, err} -> refuse_term(conn, err)
        other -> refuse(conn, 422, "unexpected_result", inspect(other))
      end
    rescue
      e -> refuse(conn, 422, "exception", Exception.message(e))
    catch
      kind, value -> refuse(conn, 422, "#{kind}", inspect(value))
    end
  end

  defp ensure_map(%{} = m) when not is_struct(m), do: m
  defp ensure_map(_), do: %{}

  defp refuse_term(conn, %{reason: reason} = err) do
    json(conn, 422, %{
      refused: true,
      broken_term: encode(reason),
      reason: inspect(reason),
      detail: encode(err)
    })
  end

  defp refuse_term(conn, {tag, _} = err) when is_atom(tag) do
    json(conn, 422, %{
      refused: true,
      broken_term: Atom.to_string(tag),
      reason: inspect(err),
      detail: encode(err)
    })
  end

  defp refuse_term(conn, err) do
    json(conn, 422, %{
      refused: true,
      broken_term: "error",
      reason: inspect(err),
      detail: encode(err)
    })
  end

  defp refuse(conn, status, term, reason) do
    json(conn, status, %{refused: true, broken_term: term, reason: reason})
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp resource(p) do
    case Map.get(p, "resource") do
      name when is_binary(name) ->
        case Map.fetch(@resources, name) do
          {:ok, mod} when is_atom(mod) ->
            {:ok, mod}

          _ ->
            try do
              {:ok, String.to_existing_atom("Elixir." <> name)}
            rescue
              ArgumentError -> {:error, %{reason: :unknown_resource, resource: name}}
            end
        end

      other ->
        {:error, %{reason: :resource_required, resource: other}}
    end
  end

  defp record(res, p) do
    case Map.get(p, "state") do
      nil ->
        {:ok, Map.get(p, "record")}

      state when is_binary(state) ->
        try do
          {:ok, struct(res, state: String.to_existing_atom(state))}
        rescue
          ArgumentError -> {:error, %{reason: :unknown_state, state: state}}
        end

      other ->
        {:error, %{reason: :unknown_state, state: other}}
    end
  end

  # Resource lifecycles use atom states; map strings to already-existing atoms and
  # leave unknown strings as strings so the real module refuses them.
  defp existing_atoms(list) when is_list(list), do: Enum.map(list, &existing_atoms/1)

  defp existing_atoms(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
  end

  defp existing_atoms(other), do: other

  defp action_atom(a) when is_binary(a) do
    String.to_existing_atom(a)
  rescue
    ArgumentError -> a
  end

  defp action_atom(a), do: a

  defp conv("*"), do: :*
  defp conv(list) when is_list(list), do: Enum.map(list, &conv/1)
  defp conv(other), do: other

  defp decode_transitions(list) when is_list(list) do
    Enum.map(list, fn
      %{} = t ->
        Enum.reduce(~w(action from to), %{}, fn key, acc ->
          case Map.fetch(t, key) do
            {:ok, v} -> Map.put(acc, String.to_atom(key), conv(v))
            :error -> acc
          end
        end)

      other ->
        other
    end)
  end

  defp decode_transitions(other), do: other

  defp put_opt(opts, p, key) do
    case Map.fetch(p, key) do
      {:ok, v} -> Keyword.put(opts, String.to_atom(key), conv(v))
      :error -> opts
    end
  end

  defp put_kw(opts, _k, nil), do: opts
  defp put_kw(opts, k, v), do: Keyword.put(opts, k, v)

  defp atomize(map, keys) do
    for k <- keys, Map.has_key?(map, k), do: {String.to_atom(k), Map.fetch!(map, k)}
  end

  defp realization_input(p) do
    cap = Map.get(p, "capability")
    map = Map.get(p, "realization")

    cond do
      not is_binary(cap) ->
        {:error, %{reason: :capability_must_be_string, capability: cap}}

      not is_map(map) or not Map.has_key?(map, "provider") ->
        {:error, %{reason: :provider_required}}

      true ->
        {:ok, cap, decode_realization(map)}
    end
  end

  defp decode_realization(map) do
    base = %{provider: to_atom(Map.get(map, "provider"))}

    base =
      case Map.get(map, "binding") do
        %{"adapter" => a, "op" => o} ->
          Map.put(base, :binding, %{adapter: to_atom(a), op: to_atom(o)})

        _ ->
          base
      end

    base =
      case {Map.get(map, "adapter"), Map.get(map, "op"), Map.get(map, "operation")} do
        {a, o, _} when not is_nil(a) and not is_nil(o) ->
          Map.merge(base, %{adapter: to_atom(a), op: to_atom(o)})

        {a, _, o} when not is_nil(a) and not is_nil(o) ->
          Map.merge(base, %{adapter: to_atom(a), operation: to_atom(o)})

        _ ->
          base
      end

    base
    |> put_if(map, "options", :options, fn v -> if is_list(v), do: [], else: [] end)
    |> put_if(map, "properties", :properties, fn v -> Enum.map(List.wrap(v), &to_atom/1) end)
  end

  defp put_if(acc, map, key, as, fun) do
    case Map.fetch(map, key) do
      {:ok, v} -> Map.put(acc, as, fun.(v))
      :error -> acc
    end
  end

  # Test-env simulation only: bounded by the finite request vocabulary.
  defp to_atom(a) when is_binary(a), do: String.to_atom(a)
  defp to_atom(a), do: a
end
