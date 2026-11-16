defmodule AshPPlan.MirrorSim.A2A do
  @moduledoc """
  Mirror-sim route handlers for the A2A area: A2A-style task send/get/cancel/resume over
  HTTP, backed by the REAL `AshPPlan.A2A.Facade`, real `Durable.Store.Ets`, real Reactor
  steps; plus the SA2A owner-side surface (`Provider`, `SubjectGuard`, `Replay`,
  `Capability`) and the generated `Providers.A2a` descriptor.

  Mount at `/a2a/*` (a leading `a2a` path segment is stripped, so the module also works
  mounted at the root, e.g. directly under Bandit).

  Typed refusals: HTTP 422 `{"refused":true,"broken_term":"..","reason":".."}`.

  The sim state (one ETS store, one counting-effects agent, one test adapter) lives in a
  named Agent started lazily by the first request; `reset/0` tears it down.
  """

  use Plug.Router

  alias AshPPlan.A2A.Facade
  alias AshPPlan.Reactor.Durable.{Engine, Status}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.SA2A.{Capability, Provider, Replay, SubjectGuard}
  alias AshPPlan.Test.Effects

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effect]` names the counter."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc "Sim adapter: counting effects plus the engine's own Await/Poll durable steps."
    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :mirror_a2a_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await, :state_hold]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]},
        state_hold:
          {Steps.Poll,
           [
             until: {AshPPlan.Reactor.Adapters.Durable, :argument_until, [:ready]},
             every: 3_600_000
           ]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  @plans ~w(simple await poll)
  @agent AshPPlan.MirrorSim.A2A.StateAgent

  # -- surfaces ----------------------------------------------------------------

  @doc "Public ash_pplan surfaces reachable through this area."
  def surfaces do
    [
      %{module: Facade, fun: :start_or_adopt, arity: 5, route: "/a2a/tasks/send"},
      %{module: Facade, fun: :status, arity: 3, route: "/a2a/tasks/:id"},
      %{module: Facade, fun: :cancel, arity: 3, route: "/a2a/tasks/:id/cancel"},
      %{module: Facade, fun: :resume, arity: 4, route: "/a2a/tasks/:id/resume"},
      %{module: Facade, fun: :attempt, arity: 3, route: "/a2a/tasks/:id/attempt"},
      %{module: Facade, fun: :signal, arity: 5, route: "/a2a/tasks/:id/signal"},
      %{module: Facade, fun: :fetch, arity: 3, route: "/a2a/tasks/:id/record"},
      %{module: Facade, fun: :waiters, arity: 3, route: "/a2a/tasks/:id/waiters"},
      %{module: Facade, fun: :to_state, arity: 1, route: "/a2a/status_map/:status"},
      %{module: Facade, fun: :run_status?, arity: 1, route: "/a2a/status_map/:status"},
      %{module: Provider, fun: :propose, arity: 2, route: "/a2a/sa2a/propose"},
      %{module: Provider, fun: :supports?, arity: 1, route: "/a2a/sa2a/supports/:formalism"},
      %{module: Capability, fun: :supported, arity: 0, route: "/a2a/sa2a/supports/:formalism"},
      %{module: SubjectGuard, fun: :fetch, arity: 1, route: "/a2a/sa2a/subject/fetch"},
      %{module: SubjectGuard, fun: :preserve, arity: 2, route: "/a2a/sa2a/subject/preserve"},
      %{module: Replay, fun: :fond, arity: 3, route: "/a2a/sa2a/replay/fond"},
      %{module: AshPPlan.Providers.A2a, fun: :capabilities, arity: 0, route: "/a2a/provider"}
    ]
  end

  # -- sim state (real collaborators) -------------------------------------------

  @doc "Boot (idempotent) and return `%{store: pid, effects: atom}`."
  def state do
    case Agent.start(&boot/0, name: @agent) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Agent.get(@agent, & &1)
  end

  @doc "Facade opts bound to the sim store."
  def opts, do: [store: state().store, store_module: Ets]

  @doc "Tear down the sim state and restore adapter config. Safe when not started."
  def reset do
    case Process.whereis(@agent) do
      nil ->
        :ok

      pid ->
        s = Agent.get(pid, & &1)
        Application.put_env(:ash_pplan, :extra_adapters, s.previous)
        Agent.stop(pid)

        for p <- [s.store, Process.whereis(s.effects)], is_pid(p), do: Process.exit(p, :kill)
        :ok
    end
  end

  defp boot do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :mirror_a2a_fx, Adapter)
    )

    effects = :"mirror_a2a_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: effects)
    {:ok, store} = Ets.start_link([])
    %{store: store, effects: effects, previous: previous}
  end

  @doc "`{model, bindings}` for a named sim plan (`simple` | `await` | `poll`), or `:error`."
  def plan(name) when name in @plans do
    {model(name), bindings(state().effects)}
  end

  def plan(_), do: :error

  defp model("simple"),
    do:
      mk("mirror_a2a_simple", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :finish, capability: "Process.Finish", depends_on: [:prepare]]
      ])

  defp model("await"),
    do:
      mk("mirror_a2a_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp model("poll"),
    do:
      mk("mirror_a2a_poll", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :hold, capability: "State.Hold", depends_on: [:prepare]]
      ])

  defp mk(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:finish, "Process.Finish"},
      {:await, "Event.Await"},
      {:hold, "State.Hold"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :mirror_a2a_fx,
         binding: %{adapter: :mirror_a2a_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  @doc "JSON-safe projection of any term (atoms to strings, tuples/structs via inspect)."
  def enc(nil), do: nil
  def enc(v) when is_boolean(v) or is_number(v) or is_binary(v), do: v
  def enc(v) when is_atom(v), do: Atom.to_string(v)
  def enc(v) when is_list(v), do: Enum.map(v, &enc/1)
  def enc(v) when is_struct(v), do: inspect(v)
  def enc(v) when is_map(v), do: Map.new(v, fn {k, x} -> {key(k), enc(x)} end)
  def enc(v), do: inspect(v)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  # -- plug pipeline --------------------------------------------------------------

  plug(:strip_prefix)
  plug(:match)
  plug(:dispatch)

  def strip_prefix(%{path_info: ["a2a" | rest]} = conn, _), do: %{conn | path_info: rest}
  def strip_prefix(conn, _), do: conn

  # -- tasks ----------------------------------------------------------------------

  post "/tasks/send" do
    with {:ok, body} <- body(conn),
         id when is_binary(id) and id != "" <- body["id"] || {:bad, :missing_id},
         {model, binds} <- plan(body["plan"] || "simple") do
      inputs = if is_map(body["inputs"]), do: body["inputs"], else: %{}

      case Facade.start_or_adopt(state().store, id, model, binds, opts() ++ [inputs: inputs]) do
        {:ok, st, detail} -> ok(conn, %{id: id, state: st, detail: detail})
        {:error, r} -> error(conn, r)
      end
    else
      {:bad, term} -> refuse(conn, term, "invalid task send")
      :error -> refuse(conn, :unknown_plan, "plan must be one of #{inspect(@plans)}")
      {:error, term} -> refuse(conn, term, "bad body")
      _ -> refuse(conn, :missing_id, "id must be a non-empty string")
    end
  end

  get "/tasks/:id" do
    case Facade.status(state().store, id, opts()) do
      {:ok, st, detail} -> ok(conn, %{id: id, state: st, detail: detail})
      {:error, r} -> error(conn, r)
    end
  end

  post "/tasks/:id/cancel" do
    case Facade.cancel(state().store, id, opts()) do
      {:ok, st, detail} -> ok(conn, %{id: id, state: st, detail: detail})
      {:error, r} -> error(conn, r)
    end
  end

  post "/tasks/:id/attempt" do
    case Facade.attempt(state().store, id, opts()) do
      {:ok, st, detail} -> ok(conn, %{id: id, state: st, detail: detail})
      {:error, r} -> error(conn, r)
    end
  end

  post "/tasks/:id/resume" do
    with {:ok, body} <- body(conn) do
      o = if Map.has_key?(body, "signal"), do: [signal: body["signal"]], else: []

      case Facade.resume(state().store, id, body["payload"], opts() ++ o) do
        {:ok, st, detail} -> ok(conn, %{id: id, state: st, detail: detail})
        {:error, r} -> error(conn, r)
      end
    else
      {:error, term} -> refuse(conn, term, "bad body")
    end
  end

  post "/tasks/:id/signal" do
    with {:ok, body} <- body(conn),
         name when is_binary(name) <- body["name"] || {:bad, :missing_name} do
      case Facade.signal(state().store, id, name, body["payload"], opts()) do
        {:ok, sig} -> ok(conn, %{id: id, signal: sig})
        {:error, r} -> error(conn, r)
      end
    else
      {:bad, term} -> refuse(conn, term, "signal name required")
      {:error, term} -> refuse(conn, term, "bad body")
      _ -> refuse(conn, :missing_name, "signal name must be a string")
    end
  end

  get "/tasks/:id/record" do
    case Facade.fetch(state().store, id, opts()) do
      {:ok, rec} -> ok(conn, %{id: id, run_status: rec.status, version: rec.version})
      {:error, r} -> error(conn, r)
    end
  end

  get "/tasks/:id/waiters" do
    ok(conn, %{id: id, waiters: Facade.waiters(state().store, id, opts())})
  end

  get "/tasks/:id/tape" do
    steps = Engine.steps(state().store, id, store_module: Ets)
    ok(conn, %{id: id, step_keys: Enum.map(steps, &inspect(&1.step_key))})
  end

  get "/effects" do
    ok(conn, %{counts: Effects.all(state().effects)})
  end

  get "/status_map/:status" do
    known = Enum.find(Status.all(), &(Atom.to_string(&1) == status))

    cond do
      known != nil ->
        {:ok, st} = Facade.to_state(known)
        ok(conn, %{status: status, run_status: Facade.run_status?(known), state: st})

      true ->
        case existing_atom(status) do
          {:ok, atom} ->
            case Facade.to_state(atom) do
              {:error, {:unmapped_status, _}} = e -> error(conn, elem(e, 1))
              {:ok, st} -> ok(conn, %{status: status, state: st})
            end

          :error ->
            refuse(conn, :unmapped_status, "unknown status #{inspect(status)}")
        end
    end
  end

  # -- SA2A owner side --------------------------------------------------------------

  get "/provider" do
    p = AshPPlan.Providers.A2a

    ok(conn, %{
      id: p.id(),
      capabilities: p.capabilities(),
      authorities_above_construct_refused: true,
      cost: p.cost()
    })
  end

  get "/sa2a/supports/:formalism" do
    supported = Capability.supported()
    f = Enum.find(supported, &(Atom.to_string(&1) == formalism))

    ok(conn, %{
      formalism: formalism,
      supported: f != nil and Provider.supports?(f),
      all_supported: supported
    })
  end

  post "/sa2a/propose" do
    with {:ok, body} <- body(conn) do
      request =
        %{formalism: formalism(body["formalism"])}
        |> put_present(:subject, body, "subject")
        |> put_present(:plan_iri, body, "plan_iri")

      case Provider.propose(request, []) do
        {:ok, cand} -> ok(conn, %{candidate: cand})
        {:error, ref} -> sa2a_refusal(conn, ref)
      end
    else
      {:error, term} -> refuse(conn, term, "bad body")
    end
  end

  post "/sa2a/subject/fetch" do
    with {:ok, body} <- body(conn) do
      case SubjectGuard.fetch(put_present(%{}, :subject, body, "subject")) do
        {:ok, subject} -> ok(conn, %{subject: subject})
        {:error, ref} -> sa2a_refusal(conn, ref)
      end
    else
      {:error, term} -> refuse(conn, term, "bad body")
    end
  end

  post "/sa2a/subject/preserve" do
    with {:ok, body} <- body(conn) do
      candidate =
        case body["candidate"] do
          m when is_map(m) -> put_present(%{}, :subject, m, "subject")
          other -> other
        end

      case SubjectGuard.preserve(body["subject"], candidate) do
        {:ok, cand} -> ok(conn, %{candidate: cand})
        {:error, ref} -> sa2a_refusal(conn, ref)
      end
    else
      {:error, term} -> refuse(conn, term, "bad body")
    end
  end

  post "/sa2a/replay/fond" do
    with {:ok, body} <- body(conn) do
      request = put_present(%{}, :subject, body["request"] || %{}, "subject")

      candidate =
        case body["candidate"] do
          m when is_map(m) -> put_present(%{}, :subject, m, "subject")
          other -> other
        end

      case Replay.fond(request, candidate, []) do
        {:ok, r} -> ok(conn, %{replay: r})
        {:error, ref} -> sa2a_refusal(conn, ref)
      end
    else
      {:error, term} -> refuse(conn, term, "bad body")
    end
  end

  match _ do
    refuse(conn, :no_route, "no route #{conn.method} #{conn.request_path}", 404)
  end

  # -- helpers ----------------------------------------------------------------------

  defp body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", _} ->
        {:ok, %{}}

      {:ok, raw, _} ->
        case Jason.decode(raw) do
          {:ok, m} when is_map(m) -> {:ok, m}
          {:ok, _} -> {:error, :body_not_object}
          {:error, _} -> {:error, :invalid_json}
        end

      _ ->
        {:error, :unreadable_body}
    end
  end

  defp put_present(map, key, body, jkey) when is_map(body) do
    if Map.has_key?(body, jkey), do: Map.put(map, key, body[jkey]), else: map
  end

  defp put_present(map, _key, _body, _jkey), do: map

  defp formalism("fond"), do: :fond
  defp formalism("powl"), do: :powl
  defp formalism(other), do: other

  defp existing_atom(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end

  defp ok(conn, map), do: send_json(conn, 200, Map.put(map, :refused, false))

  defp refuse(conn, term, reason, status \\ 422) do
    send_json(conn, status, %{refused: true, broken_term: key(term), reason: reason})
  end

  defp error(conn, reason) do
    term =
      case reason do
        a when is_atom(a) -> a
        t when is_tuple(t) and is_atom(elem(t, 0)) -> elem(t, 0)
        _ -> :error
      end

    refuse(conn, term, inspect(reason))
  end

  defp sa2a_refusal(conn, %{code: code} = ref) do
    send_json(conn, 422, %{
      refused: true,
      broken_term: key(code),
      reason: inspect(Map.get(ref, :detail)),
      authority: Map.get(ref, :authority)
    })
  end

  defp send_json(conn, status, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(enc(map)))
  end
end
