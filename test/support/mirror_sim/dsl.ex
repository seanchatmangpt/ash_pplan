defmodule AshPPlan.MirrorSim.Dsl.Step do
  @moduledoc false
  # Hand-written real Reactor.Step used as the handler for every compiled step.
  use Reactor.Step

  @impl true
  def run(arguments, _context, _options), do: {:ok, arguments}
end

defmodule AshPPlan.MirrorSim.Dsl.FixtureWorkflow do
  @moduledoc false
  use AshPPlan.Workflow

  workflow do
    goal "verified"
    task :observe, capability: "File.Read", outcomes: [:ok]
    task :verify, capability: "Verification.Run", after: [:observe]
  end
end

defmodule AshPPlan.MirrorSim.Dsl.FixturePPlan do
  @moduledoc false
  use AshPPlan.Dsl

  pplan do
    goal "ship"
    task :observe, capability: "File.Read"
  end
end

defmodule AshPPlan.MirrorSim.Dsl.NotAWorkflow do
  @moduledoc false
end

defmodule AshPPlan.MirrorSim.Dsl do
  @moduledoc """
  Mirror-sim area `dsl`: compile plans from JSON descriptors, resolve workflow
  models, and expose workflow explain/method/task/authority/subject/capability_catalog.

  Mounted at `/dsl/*`. Every route drives the real `AshPPlan.Compiler` /
  `AshPPlan.Workflow*` modules; refusals are HTTP 422
  `{"refused":true,"broken_term":...,"reason":...,"details":...}`.
  """
  use Plug.Router

  alias AshPPlan.Catalog.Plan
  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error
  alias AshPPlan.MirrorSim.Dsl.Step
  alias AshPPlan.Workflow
  alias AshPPlan.Workflow.{Authority, CapabilityCatalog, Explain, Model, Subject}

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:dispatch)

  @task_keys ~w(id capability after depends_on outcomes terminal_outcomes properties evidence authority compensation)
  @method_keys ~w(id task subtasks precondition)
  @model_keys ~w(name goal version tasks methods)
  @step_keys ~w(iri predecessors inputs outputs)
  @authorities ~w(none observe select plan construct do)
  @kinds ~w(pplan hddl fond reactor)

  @fixture_modules %{
    "workflow" => AshPPlan.MirrorSim.Dsl.FixtureWorkflow,
    "pplan" => AshPPlan.MirrorSim.Dsl.FixturePPlan
  }

  @doc "Surface inventory for the router/coverage compiler."
  def surfaces do
    [
      %{module: Compiler, fun: :compile, arity: 2, route: "/dsl/compile_iri"},
      %{module: Compiler, fun: :compile_spec, arity: 2, route: "/dsl/compile_spec"},
      %{module: Workflow, fun: :model, arity: 1, route: "/dsl/workflow_model"},
      %{module: Model, fun: :new, arity: 1, route: "/dsl/model"},
      %{module: Model, fun: :validate, arity: 1, route: "/dsl/model"},
      %{module: Model, fun: :task, arity: 1, route: "/dsl/task"},
      %{module: Model, fun: :method, arity: 1, route: "/dsl/method"},
      %{module: Explain, fun: :workflow, arity: 2, route: "/dsl/explain"},
      %{module: Authority, fun: :admit, arity: 1, route: "/dsl/authority"},
      %{module: Subject, fun: :bind, arity: 1, route: "/dsl/subject"},
      %{module: Subject, fun: :verify_projection, arity: 3, route: "/dsl/verify_projection"},
      %{module: CapabilityCatalog, fun: :all, arity: 0, route: "/dsl/capability_catalog"},
      %{module: CapabilityCatalog, fun: :ids, arity: 0, route: "/dsl/capability_catalog"}
    ]
  end

  # -- routes ---------------------------------------------------------------

  post "/model" do
    guarded(conn, fn ->
      with {:ok, model} <- Model.new(decode_model(conn.body_params["model"])),
           :ok <- Model.validate(model) do
        {:ok, %{model: model}}
      end
    end)
  end

  post "/workflow_model" do
    guarded(conn, fn ->
      with {:ok, model} <- Workflow.model(fixture_module(conn.body_params["module"])) do
        {:ok, %{model: model}}
      end
    end)
  end

  post "/task" do
    guarded(conn, fn -> {:ok, %{task: Model.task(decode_task(conn.body_params["task"]))}} end)
  end

  post "/method" do
    guarded(conn, fn ->
      {:ok, %{method: Model.method(decode_method(conn.body_params["method"]))}}
    end)
  end

  post "/explain" do
    guarded(conn, fn ->
      with {:ok, model} <- Model.new(decode_model(conn.body_params["model"])) do
        {:ok, %{explain: Explain.workflow(model)}}
      end
    end)
  end

  post "/subject" do
    guarded(conn, fn ->
      with {:ok, model} <- Model.new(decode_model(conn.body_params["model"])) do
        {:ok, %{subject: Subject.bind(model)}}
      end
    end)
  end

  post "/authority" do
    guarded(conn, fn ->
      result =
        case conn.body_params do
          %{"model" => descriptor} ->
            with {:ok, model} <- Model.new(decode_model(descriptor)),
                 {:ok, ceiling} <- Authority.admit(model) do
              {:ok, %{ceiling: ceiling, granted: Authority.granted(model)}}
            end

          %{"authority" => authority} ->
            with {:ok, ceiling} <- Authority.admit(decode_authority(authority)) do
              {:ok, %{ceiling: ceiling}}
            end

          _ ->
            {:error, %{reason: :missing_authority_input}}
        end

      result
    end)
  end

  post "/verify_projection" do
    guarded(conn, fn ->
      params = conn.body_params
      kind = decode_kind(params["kind"])

      with {:ok, model} <- Model.new(decode_model(params["model"])),
           :ok <- Subject.verify_projection(model, kind, decode_projection(params["projection"])) do
        {:ok, %{verified: true}}
      end
    end)
  end

  get "/capability_catalog" do
    respond(conn, 200, %{
      ok: true,
      capabilities: CapabilityCatalog.all(),
      ids: CapabilityCatalog.ids()
    })
  end

  post "/compile_spec" do
    guarded(conn, fn ->
      params = conn.body_params
      spec = decode_spec(params)
      handlers = handlers_for(spec, List.wrap(params["omit_handlers"]))

      with {:ok, reactor} <- Compiler.compile_spec(spec, handlers) do
        {:ok, %{compiled: summarize_reactor(reactor)}}
      end
    end)
  end

  post "/compile_iri" do
    guarded(conn, fn ->
      iri = conn.body_params["plan_iri"]

      handlers =
        case is_binary(iri) && Plan.fetch(iri) do
          %{steps: _} = plan -> handlers_for(plan, [])
          _ -> %{}
        end

      with {:ok, reactor} <- Compiler.compile(iri, handlers) do
        {:ok, %{compiled: summarize_reactor(reactor)}}
      end
    end)
  end

  match _ do
    respond(conn, 404, %{refused: true, broken_term: "unknown_route", reason: "unknown_route"})
  end

  # -- shared helpers (public so courts can compute the direct-call side) -------

  @doc "Handlers map for a plan spec: the real step module for every step iri not omitted."
  def handlers_for(%{steps: steps}, omit) when is_list(steps) do
    steps
    |> Enum.flat_map(fn
      %{iri: iri} when is_binary(iri) -> if iri in omit, do: [], else: [{iri, Step}]
      _ -> []
    end)
    |> Map.new()
  end

  def handlers_for(_spec, _omit), do: %{}

  @doc "JSON-stable summary of a compiled Reactor."
  def summarize_reactor(reactor) do
    %{
      id: reactor.id,
      steps: Enum.map(reactor.steps, & &1.name),
      return: reactor.return,
      inputs: reactor.inputs
    }
  end

  @doc "Decode a JSON model descriptor into the attrs map `Model.new/1` takes."
  def decode_model(%{} = descriptor) do
    descriptor
    |> atomize(@model_keys)
    |> Map.update(:tasks, [], &decode_list(&1, :task))
    |> then(fn attrs ->
      case descriptor do
        %{"methods" => methods} -> Map.put(attrs, :methods, decode_list(methods, :method))
        _ -> attrs
      end
    end)
  end

  def decode_model(other), do: other

  def decode_task(%{} = task) do
    task |> atomize(@task_keys) |> decode_authority_field()
  end

  def decode_task(other), do: other

  def decode_method(%{} = method), do: atomize(method, @method_keys)
  def decode_method(other), do: other

  def decode_spec(%{} = params) do
    steps =
      case params["steps"] do
        steps when is_list(steps) -> Enum.map(steps, &decode_step/1)
        other -> other
      end

    %{iri: params["iri"], steps: steps}
  end

  def decode_step(%{} = step), do: atomize(step, @step_keys)
  def decode_step(other), do: other

  def decode_authority(value) when is_binary(value) and value in @authorities,
    do: String.to_existing_atom(value)

  def decode_authority(value), do: value

  def decode_kind(value) when is_binary(value) and value in @kinds,
    do: String.to_existing_atom(value)

  def decode_kind(value), do: value

  def decode_projection(%{"steps" => steps}) when is_list(steps) do
    %{steps: Enum.map(steps, &decode_step/1)}
  end

  def decode_projection(%{"ids" => ids}) when is_list(ids), do: ids
  def decode_projection(other), do: other

  def fixture_module(name) when is_binary(name),
    do: Map.get(@fixture_modules, name, AshPPlan.MirrorSim.Dsl.NotAWorkflow)

  def fixture_module(_), do: AshPPlan.MirrorSim.Dsl.NotAWorkflow

  @doc "Normalize any term into a Jason-encodable structure with string keys."
  def jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  def jsonable(%{} = map), do: Map.new(map, fn {k, v} -> {key(k), jsonable(v)} end)
  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  def jsonable(value) when is_nil(value) or is_boolean(value), do: value
  def jsonable(value) when is_atom(value), do: Atom.to_string(value)
  def jsonable(value) when is_number(value), do: value

  def jsonable(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  def jsonable(other), do: inspect(other)

  defp key(k) when is_binary(k), do: if(String.valid?(k), do: k, else: inspect(k))
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  # -- internals --------------------------------------------------------------

  defp decode_list(list, :task) when is_list(list), do: Enum.map(list, &decode_task/1)
  defp decode_list(list, :method) when is_list(list), do: Enum.map(list, &decode_method/1)
  defp decode_list(other, _), do: other

  defp decode_authority_field(%{authority: a} = task),
    do: %{task | authority: decode_authority(a)}

  defp decode_authority_field(task), do: task

  # Whitelisted keys become atoms (never String.to_atom on input); the rest stay
  # string-keyed so the real module refuses them with its own typed error.
  defp atomize(map, keys) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        if k in keys, do: {String.to_existing_atom(k), v}, else: {k, v}

      other ->
        other
    end)
  end

  defp guarded(conn, fun) do
    case fun.() do
      {:ok, body} ->
        respond(conn, 200, Map.put(body, :ok, true))

      :ok ->
        respond(conn, 200, %{ok: true})

      {:error, %Error{reason: reason, details: details}} ->
        refuse(conn, reason, details)

      {:error, %{reason: reason} = detail} ->
        refuse(conn, reason, detail)

      {:error, reason} ->
        refuse(conn, :error, %{error: reason})
    end
  rescue
    e in [ArgumentError, KeyError, BadMapError, FunctionClauseError, MatchError] ->
      refuse(conn, :invalid_descriptor, %{exception: inspect(e.__struct__)})
  end

  defp refuse(conn, reason, details) do
    respond(conn, 422, %{
      refused: true,
      broken_term: to_string(reason),
      reason: to_string(reason),
      details: details
    })
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(jsonable(body)))
  end
end
