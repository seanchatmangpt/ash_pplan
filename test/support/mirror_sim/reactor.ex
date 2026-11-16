defmodule AshPPlan.MirrorSim.Reactor.OkStep do
  @moduledoc false
  use Reactor.Step
  @impl true
  def run(_arguments, _context, _options), do: {:ok, :done}
end

defmodule AshPPlan.MirrorSim.Reactor.FailStep do
  @moduledoc false
  use Reactor.Step
  @impl true
  def run(_arguments, _context, _options), do: {:error, :boom}
end

defmodule AshPPlan.MirrorSim.Reactor.CollectStep do
  @moduledoc false
  use Reactor.Step
  @impl true
  def run(arguments, _context, _options), do: {:ok, Map.new(arguments)}
end

defmodule AshPPlan.MirrorSim.Reactor.SimWorker do
  @moduledoc false
  use Agent

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> 0 end)
end

defmodule AshPPlan.MirrorSim.Reactor do
  @moduledoc """
  Mirror-sim routes for `lib/ash_pplan/reactor/**` (except `durable/`).

  Every route builds and runs a REAL `Reactor` through the real adapters, steps and
  middleware, and answers final outcomes plus evidence as JSON. Mounted at `/reactor/*`
  (a leading `reactor` path segment is tolerated and stripped, so the module also serves
  standalone). Typed refusals: HTTP 422 `{"refused":true,"broken_term":...,"reason":...}`.

  Atoms are never minted from request text: adapter, op, authority and telemetry names
  are resolved against closed tables.
  """
  use Plug.Router

  import Plug.Conn

  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.MirrorSim.Reactor.{CollectStep, FailStep, OkStep, SimWorker}
  alias AshPPlan.Reactor, as: PlanReactor
  alias AshPPlan.Reactor.Durable.Clock
  alias AshPPlan.Reactor.Middleware.Observation
  alias AshPPlan.ReactorOutcome
  alias AshPPlan.Workflow.{Model, Subject}
  alias Reactor.Argument

  @key AshPPlan.Reactor.context_key()
  @telemetry_names %{"alpha" => :alpha, "beta" => :beta, "gamma" => :gamma}
  @req_ops %{
    "get" => :network_get,
    "post" => :network_post,
    "put" => :network_put,
    "patch" => :network_patch,
    "delete" => :network_delete,
    "head" => :network_head,
    "remote_read" => :remote_read
  }
  @body_ops [:network_post, :network_put, :network_patch]
  @loopback ["127.0.0.1", "localhost", "::1"]

  plug(:strip_prefix)
  plug(:match)
  plug(:load_params)
  plug(:dispatch)

  @doc "Routable surfaces (module, function, arity, route)."
  @spec surfaces() :: [
          %{module: module(), fun: atom(), arity: non_neg_integer(), route: String.t()}
        ]
  def surfaces do
    [
      {PlanReactor, :adapters, 0, "/reactor/adapters"},
      {PlanReactor, :step_for, 2, "/reactor/step_for"},
      {PlanReactor, :validate_step, 1, "/reactor/step_for"},
      {PlanReactor, :context_key, 0, "/reactor/run/enriched"},
      {PlanReactor, :enrich, 3, "/reactor/run/enriched"},
      {PlanReactor, :identity_of, 1, "/reactor/run/enriched"},
      {PlanReactor, :inherit, 2, "/reactor/inherit"},
      {PlanReactor, :add_middleware, 2, "/reactor/run/identity_missing"},
      {AshPPlan.Reactor.Adapter, :resolve, 4, "/reactor/step_for"},
      {AshPPlan.Reactor.Adapters.Local, :step, 2, "/reactor/run/local/command"},
      {AshPPlan.Reactor.Adapters.Local, :wake_due, 2, "/reactor/run/local/wakeup"},
      {AshPPlan.Reactor.Adapters.Local, :continuation, 2, "/reactor/run/local/checkpoint"},
      {AshPPlan.Reactor.Adapters.ReactorFile, :step, 2, "/reactor/run/file"},
      {AshPPlan.Reactor.Adapters.ReactorReq, :step, 2, "/reactor/run/req"},
      {AshPPlan.Reactor.Adapters.ReactorProcess, :step, 2, "/reactor/run/process"},
      {AshPPlan.Reactor.Adapters.BbReactor, :step, 2, "/reactor/step_for"},
      {AshPPlan.Reactor.Adapters.AshReactor, :step, 2, "/reactor/step_for"},
      {AshPPlan.Reactor.Adapters.AshReactorExtended, :step, 2, "/reactor/step_for"},
      {AshPPlan.Reactor.Steps.Await, :run, 3, "/reactor/run/local/await"},
      {AshPPlan.Reactor.Steps.Command, :run, 3, "/reactor/run/local/command"},
      {AshPPlan.Reactor.Steps.Actuate, :run, 3, "/reactor/run/local/actuate"},
      {AshPPlan.Reactor.Steps.Telemetry, :run, 3, "/reactor/run/local/telemetry"},
      {AshPPlan.Reactor.Middleware.Identity, :init, 1, "/reactor/run/identity_missing"},
      {AshPPlan.Reactor.Middleware.Evidence, :complete, 2, "/reactor/run/enriched"},
      {AshPPlan.Reactor.Middleware.Observation, :event, 3, "/reactor/run/enriched"},
      {AshPPlan.Reactor.Middleware.Observation, :ledger_events, 2, "/reactor/run/enriched"},
      {AshPPlan.ReactorOutcome, :state, 1, "/reactor/outcome"},
      {AshPPlan.ReactorOutcome, :observe, 1, "/reactor/outcome"}
    ]
    |> Enum.map(fn {m, f, a, r} -> %{module: m, fun: f, arity: a, route: r} end)
  end

  # ---------------------------------------------------------------- routes

  get "/adapters" do
    safe(conn, fn ->
      list =
        PlanReactor.adapters()
        |> Enum.map(fn {id, mod} ->
          %{
            "id" => Atom.to_string(id),
            "module" => inspect(mod),
            "available" => mod.available?(),
            "ops" => mod.ops() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
          }
        end)
        |> Enum.sort_by(& &1["id"])

      {:ok, %{"adapters" => list}}
    end)
  end

  post "/step_for" do
    safe(conn, fn -> step_for(conn.assigns.params) end)
  end

  post "/outcome" do
    safe(conn, fn -> outcome(conn.assigns.params) end)
  end

  post "/inherit" do
    safe(conn, fn -> inherit(conn.assigns.params) end)
  end

  post "/run/file" do
    safe(conn, fn -> run_file(conn.assigns.params) end)
  end

  post "/run/file_missing" do
    safe(conn, fn ->
      path =
        Path.join(System.tmp_dir!(), "mirror_sim_absent_#{System.unique_integer([:positive])}")

      single(:reactor_file, :file_read, [], [Argument.from_value(:path, path)])
    end)
  end

  post "/run/req" do
    safe(conn, fn -> run_req(conn.assigns.params) end)
  end

  post "/run/process" do
    safe(conn, fn -> run_process() end)
  end

  post "/run/local/command" do
    safe(conn, fn ->
      p = conn.assigns.params
      handler = if p["handler"] == "boom", do: :boom, else: :echo

      single(:local, :actuation_command, [name: :sim_cmd, handler: {__MODULE__, handler}], [
        Argument.from_value(:value, p["value"])
      ])
    end)
  end

  post "/run/local/actuate" do
    safe(conn, fn ->
      single(:local, :actuation_actuate, [name: :sim_intent], [
        Argument.from_value(:payload, conn.assigns.params["payload"])
      ])
    end)
  end

  post "/run/local/await" do
    safe(conn, fn ->
      p = conn.assigns.params

      ops = %{
        "state_await" => :state_await,
        "event_await" => :event_await,
        "state_observe" => :state_observe
      }

      case Map.fetch(ops, p["op"] || "state_await") do
        {:ok, op} ->
          single(:local, op, [name: :sim_wait, probe: {__MODULE__, :probe, []}], [
            Argument.from_value(:ready, p["ready"] == true)
          ])

        :error ->
          {:refuse, "unknown_op", p["op"]}
      end
    end)
  end

  post "/run/local/telemetry" do
    safe(conn, fn -> run_telemetry(conn.assigns.params) end)
  end

  post "/run/local/wakeup" do
    safe(conn, fn -> run_wakeup(conn.assigns.params) end)
  end

  post "/run/local/checkpoint" do
    safe(conn, fn ->
      single(:local, :durability_checkpoint, [name: :sim_checkpoint], [
        Argument.from_value(:continuation, conn.assigns.params["continuation"])
      ])
    end)
  end

  post "/run/enriched" do
    safe(conn, fn -> run_enriched(conn.assigns.params) end)
  end

  post "/run/identity_missing" do
    safe(conn, fn -> run_identity_missing() end)
  end

  match _ do
    Json.refuse(conn, "unknown_route", "no reactor route #{conn.request_path}", 404)
  end

  # ---------------------------------------------------------------- plugs

  @doc false
  def strip_prefix(%{path_info: ["reactor" | rest]} = conn, _opts), do: %{conn | path_info: rest}
  def strip_prefix(conn, _opts), do: conn

  @doc false
  def load_params(conn, _opts) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> read_params(conn)
      %{} = map -> assign(conn, :params, map)
    end
  end

  defp read_params(conn) do
    case read_body(conn) do
      {:ok, "", conn} ->
        assign(conn, :params, %{})

      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{} = map} ->
            assign(conn, :params, map)

          {:ok, _other} ->
            conn |> Json.refuse("invalid_body", "body must be a JSON object") |> halt()

          {:error, _} ->
            conn |> Json.refuse("malformed_json", "body is not valid JSON") |> halt()
        end

      _ ->
        conn |> Json.refuse("unreadable_body", "body could not be read") |> halt()
    end
  end

  # ---------------------------------------------------------------- handlers

  defp step_for(params) do
    # AshReactorExtended is not in the built-in table; the sim reaches it through the
    # step_for `:adapters` override so its table is exercised over the wire too.
    adapters =
      Map.put_new(
        PlanReactor.adapters(),
        :ash_reactor_extended,
        AshPPlan.Reactor.Adapters.AshReactorExtended
      )

    adapter =
      Enum.find_value(adapters, :__unknown_adapter__, fn {id, _} ->
        if Atom.to_string(id) == params["adapter"], do: id
      end)

    all_ops = adapters |> Enum.flat_map(fn {_, m} -> m.ops() end) |> Enum.uniq()
    op = Enum.find(all_ops, :__unknown_op__, &(Atom.to_string(&1) == params["op"]))

    opts =
      if Map.has_key?(params, "available?"),
        do: [available?: params["available?"] == true],
        else: []

    realization = %AshPPlan.Realization{
      capability: "mirror_sim",
      provider: "mirror_sim",
      binding: %{adapter: adapter, op: op},
      options: []
    }

    case PlanReactor.step_for(realization, [adapters: adapters] ++ opts) do
      {:ok, {mod, kw}} ->
        {:ok, %{"ok" => true, "module" => inspect(mod), "options" => render(Map.new(kw))}}

      {:error, err} ->
        {:refuse, Map.get(err, :reason, :error), err}
    end
  end

  defp outcome(params) do
    value = params["value"]

    term =
      case params["kind"] do
        "ok" -> {:ok, value}
        "ok3" -> {:ok, value, Reactor.Builder.new()}
        "halted" -> {:halted, Reactor.Builder.new()}
        "error" -> {:error, value}
        _ -> {:unrecognized, value}
      end

    obs = ReactorOutcome.observe(term)

    {:ok,
     %{
       "state" => Atom.to_string(ReactorOutcome.state(term)),
       "observe_state" => Atom.to_string(obs.state),
       "observe_keys" => obs |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
       "value" => render(Map.get(obs, :value)),
       "reason" => render(Map.get(obs, :reason))
     }}
  end

  defp inherit(params) do
    authorities = Model.authorities()
    to_auth = fn name -> Enum.find(authorities, :bogus, &(Atom.to_string(&1) == name)) end
    parent_authority = to_auth.(params["parent_authority"])

    parent = %{
      task: "parent",
      subject: "sha256:mirror-sim",
      workflow: "mirror-sim",
      capability: "File.Read",
      properties: [],
      authority: parent_authority,
      iri: "urn:mirror-sim:parent",
      parent: nil
    }

    context =
      case params["child_authority"] do
        nil -> %{}
        name -> %{@key => %{authority: to_auth.(name)}}
      end

    child = %Reactor.Step{name: :kid, ref: :kid, impl: {OkStep, []}, context: context}

    case PlanReactor.inherit(parent, child) do
      {:ok, step} ->
        id = PlanReactor.identity_of(step)

        {:ok,
         %{
           "task" => id.task,
           "iri" => id.iri,
           "authority" => Atom.to_string(id.authority),
           "parent" => id.parent
         }}

      {:error, err} ->
        {:refuse, Map.get(err, :reason, :error), err}
    end
  end

  defp run_file(params) do
    content = params["content"]

    if is_binary(content) do
      dir =
        Path.join(System.tmp_dir!(), "mirror_sim_reactor_#{System.unique_integer([:positive])}")

      sub = Path.join(dir, "sub")
      source = Path.join(sub, "a.txt")
      copy = Path.join(sub, "b.txt")

      try do
        result = file_reactor(sub, source, copy, content)

        case result do
          {:ok, res} ->
            body =
              outcome_json(res)
              |> Map.merge(%{
                "source_exists" => File.exists?(source),
                "source_content" => File.read(source) |> elem_ok(),
                "copy_exists" => File.exists?(copy)
              })

            {:ok, body}

          {:error, err} ->
            {:refuse, Map.get(err, :reason, :error), err}
        end
      after
        File.rm_rf(dir)
      end
    else
      {:refuse, "invalid_content", "content must be a string"}
    end
  end

  defp elem_ok({:ok, v}), do: v
  defp elem_ok(_), do: nil

  defp file_reactor(sub, source, copy, content) do
    b = Reactor.Builder

    with {:ok, {mk, mkkw}} <- resolve(:reactor_file, :file_mkdir, []),
         {:ok, {wr, wrkw}} <- resolve(:reactor_file, :file_write, []),
         {:ok, {rd, rdkw}} <- resolve(:reactor_file, :file_read, []),
         {:ok, {cp, cpkw}} <- resolve(:reactor_file, :file_copy, []),
         {:ok, {rm, rmkw}} <- resolve(:reactor_file, :file_delete, []),
         {:ok, r} <- b.add_step(b.new(), :mkdir, {mk, mkkw}, [Argument.from_value(:path, sub)]),
         {:ok, r} <-
           b.add_step(r, :write, {wr, wrkw}, [
             Argument.from_result(:path, :mkdir, fn _ -> source end),
             Argument.from_value(:content, content)
           ]),
         {:ok, r} <-
           b.add_step(r, :read, {rd, rdkw}, [
             Argument.from_result(:path, :write, fn _ -> source end)
           ]),
         {:ok, r} <-
           b.add_step(r, :copy, {cp, cpkw}, [
             Argument.from_result(:source, :read, fn _ -> source end),
             Argument.from_value(:target, copy)
           ]),
         {:ok, r} <-
           b.add_step(r, :rm, {rm, rmkw}, [Argument.from_result(:path, :copy, fn _ -> copy end)]),
         {:ok, r} <-
           b.add_step(r, :report, CollectStep, [
             Argument.from_result(:written, :write, fn w -> %{changed: w.changed?} end),
             Argument.from_result(:read, :read),
             Argument.from_result(:removed, :rm, fn x -> %{changed: x.changed?} end)
           ]),
         {:ok, r} <- b.return(r, :report) do
      {:ok, Reactor.run(r, %{}, %{}, async?: false)}
    else
      {:error, err} -> {:error, wrap_error(err)}
    end
  end

  defp run_req(params) do
    url = params["url"]
    method = params["method"] || "get"

    cond do
      not is_binary(url) ->
        {:refuse, "invalid_url", "url must be a string"}

      URI.parse(url).host not in @loopback ->
        {:refuse, "non_loopback_url", "mirror sim only reaches loopback upstreams"}

      not Map.has_key?(@req_ops, method) ->
        {:refuse, "unknown_method", method}

      true ->
        op = Map.fetch!(@req_ops, method)

        args =
          [Argument.from_value(:url, url), Argument.from_value(:retry, false)] ++
            if(op in @body_ops and Map.has_key?(params, "json"),
              do: [Argument.from_value(:json, params["json"])],
              else: []
            )

        case run_step(:reactor_req, op, [], args) do
          {:ok, {:ok, %Req.Response{} = resp}} ->
            {:ok,
             %{
               "state" => "succeeded",
               "status" => resp.status,
               "body" => render(resp.body),
               "content_type" => resp |> Req.Response.get_header("content-type") |> List.first()
             }}

          {:ok, res} ->
            {:ok, outcome_json(res)}

          {:error, err} ->
            {:refuse, Map.get(err, :reason, :error), err}
        end
    end
  end

  defp run_process do
    b = Reactor.Builder
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

    try do
      with {:ok, {st, stkw}} <- resolve(:reactor_process, :process_start, []),
           {:ok, {ct, ctkw}} <- resolve(:reactor_process, :process_count, []),
           {:ok, {tm, tmkw}} <- resolve(:reactor_process, :process_terminate, []),
           {:ok, r} <-
             b.add_step(b.new(), :start, {st, stkw}, [
               Argument.from_value(:supervisor, sup),
               Argument.from_value(:child_spec, {SimWorker, []})
             ]),
           {:ok, r} <-
             b.add_step(r, :count, {ct, ctkw}, [
               Argument.from_result(:supervisor, :start, fn _ -> sup end)
             ]),
           {:ok, r} <-
             b.add_step(r, :terminate, {tm, tmkw}, [
               Argument.from_result(:supervisor, :count, fn _ -> sup end),
               Argument.from_value(:child_id, SimWorker)
             ]),
           {:ok, r} <-
             b.add_step(r, :count_after, {ct, ctkw}, [
               Argument.from_result(:supervisor, :terminate, fn _ -> sup end)
             ]),
           {:ok, r} <-
             b.add_step(r, :report, CollectStep, [
               Argument.from_result(:started, :start, fn s ->
                 %{id: inspect(s.id), started: s.started?}
               end),
               Argument.from_result(:count_before, :count),
               Argument.from_result(:terminated, :terminate),
               Argument.from_result(:count_after, :count_after)
             ]),
           {:ok, r} <- b.return(r, :report) do
        {:ok, outcome_json(Reactor.run(r, %{}, %{}, async?: false))}
      else
        {:error, err} ->
          err = wrap_error(err)
          {:refuse, Map.get(err, :reason, :error), err}
      end
    after
      Supervisor.stop(sup)
    end
  end

  defp run_telemetry(params) do
    case Map.fetch(@telemetry_names, params["name"]) do
      {:ok, name} ->
        id = {__MODULE__, make_ref()}

        :ok =
          :telemetry.attach(
            id,
            [:ash_pplan, :observation, name],
            &__MODULE__.forward_event/4,
            self()
          )

        try do
          case run_step(:local, :observation_telemetry, [name: name], [
                 Argument.from_value(:payload, params["payload"])
               ]) do
            {:ok, res} ->
              {:ok, Map.put(outcome_json(res), "emitted", drain_events([]))}

            {:error, err} ->
              {:refuse, Map.get(err, :reason, :error), err}
          end
        after
          :telemetry.detach(id)
        end

      :error ->
        {:refuse, "unknown_telemetry_name", params["name"]}
    end
  end

  @doc false
  def forward_event(event, measurements, metadata, pid),
    do: send(pid, {:sim_telemetry, event, measurements, metadata})

  defp drain_events(acc) do
    receive do
      {:sim_telemetry, event, _meas, meta} ->
        drain_events([
          %{
            "event" => Enum.map(event, &Atom.to_string/1),
            "arguments" => render(Map.get(meta, :arguments))
          }
          | acc
        ])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp run_wakeup(params) do
    offset = int(params["offset_ms"])
    advance = int(params["advance_ms"])
    t0 = ~U[2030-01-01 00:00:00Z]
    agent = Clock.use_test_clock(t0)

    try do
      at = Clock.add(t0, offset)
      args = [Argument.from_value(:wake_at, at)]

      with {:ok, first} <- run_step(:local, :scheduling_wakeup, [name: :sim_wake], args),
           _ <- Clock.advance(advance),
           {:ok, second} <- run_step(:local, :scheduling_wakeup, [name: :sim_wake], args) do
        {:ok,
         %{
           "before" => outcome_json(first),
           "after" => outcome_json(second),
           "now" => DateTime.to_iso8601(Clock.now()),
           "wake_at" => DateTime.to_iso8601(at)
         }}
      else
        {:error, err} -> {:refuse, Map.get(err, :reason, :error), err}
      end
    after
      Clock.reset()
      Agent.stop(agent)
    end
  end

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0

  defp run_enriched(params) do
    workflow = params["workflow"] || "mirror-sim-enriched"
    fail? = params["fail"] == true

    if is_binary(workflow) and workflow =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/ do
      b = Reactor.Builder
      obs = String.to_atom(Subject.correspondence(workflow, :observe).reactor)
      bld = String.to_atom(Subject.correspondence(workflow, :build).reactor)
      second = if fail?, do: FailStep, else: OkStep

      with {:ok, model} <-
             Model.new(
               name: workflow,
               goal: "close",
               tasks: [
                 [id: :observe, capability: "File.Read", authority: :observe],
                 [id: :build, capability: "File.Write", after: [:observe], authority: :construct]
               ]
             ),
           {:ok, r} <- b.add_step(b.new(), obs, OkStep, []),
           {:ok, r} <- b.add_step(r, bld, second, observed: {:result, obs}),
           {:ok, r} <- b.return(r, bld),
           {:ok, r} <- PlanReactor.enrich(r, model),
           {:ok, r} <- PlanReactor.add_middleware(r, [Observation]) do
        {:ok, collector} = Observation.Collector.start()

        try do
          res = Reactor.run(r, %{}, %{}, async?: false)
          events = Observation.Collector.events(collector)
          {:ok, enriched_body(model, res, events)}
        after
          Observation.Collector.stop(collector)
        end
      else
        {:error, err} -> {:refuse, "enrich_refused", err}
      end
    else
      {:refuse, "invalid_workflow", "workflow must match [A-Za-z0-9_-]{1,64}"}
    end
  end

  defp enriched_body(model, res, events) do
    subject = Subject.bind(model).id

    steps =
      for {[:ash_pplan, :observation, :step, phase], _, meta} <- events do
        %{
          "phase" => Atom.to_string(phase),
          "task" => meta.task,
          "subject_id" => meta.subject_id,
          "evidence_subject" => meta.evidence.subject_id,
          "activity" => meta.evidence.activity
        }
      end

    runs =
      for {[:ash_pplan, :observation, :run, phase], _, meta} <- events do
        %{
          "phase" => Atom.to_string(phase),
          "subject_id" => meta.subject_id,
          "status" => Atom.to_string(meta.receipt.status),
          "prov_activity" => String.contains?(meta.prov, "prov#Activity"),
          "outcome_digest" => render(meta.receipt.outcome_digest)
        }
      end

    outcome_json(res)
    |> Map.merge(%{
      "subject" => subject,
      "steps" => steps,
      "runs" => runs,
      "ledger_events" => length(Observation.ledger_events(%{}, subject))
    })
  end

  defp run_identity_missing do
    b = Reactor.Builder

    with {:ok, r} <- b.add_step(b.new(), :only, OkStep, []),
         {:ok, r} <- b.return(r, :only),
         {:ok, r} <- PlanReactor.add_middleware(r, [AshPPlan.Reactor.Middleware.Identity]) do
      {:ok, outcome_json(Reactor.run(r, %{}, %{}, async?: false))}
    else
      {:error, err} -> {:refuse, "build_failed", err}
    end
  end

  # ---------------------------------------------------------------- probes / handlers

  @doc "Command handler: echo the arguments."
  @spec echo(map()) :: {:ok, map()}
  def echo(arguments), do: {:ok, arguments}

  @doc "Command handler: always fails."
  @spec boom(map()) :: {:error, atom()}
  def boom(_arguments), do: {:error, :boom}

  @doc "Await probe: `{:ok, :up}` when `:ready` is true, else `:pending`."
  @spec probe(map()) :: {:ok, :up} | :pending
  def probe(%{ready: true}), do: {:ok, :up}
  def probe(_arguments), do: :pending

  # ---------------------------------------------------------------- reactor plumbing

  defp resolve(adapter, op, op_opts) do
    realization = %AshPPlan.Realization{
      capability: "mirror_sim",
      provider: "mirror_sim",
      binding: %{adapter: adapter, op: op},
      options: op_opts
    }

    PlanReactor.step_for(realization)
  end

  # Resolve + build + run a one-step reactor. {:ok, reactor_result} | {:error, map}.
  defp run_step(adapter, op, op_opts, args) do
    b = Reactor.Builder

    with {:ok, {mod, kw}} <- resolve(adapter, op, op_opts),
         {:ok, r} <- b.add_step(b.new(), :only, {mod, kw}, args),
         {:ok, r} <- b.return(r, :only) do
      {:ok, Reactor.run(r, %{}, %{}, async?: false)}
    else
      {:error, err} -> {:error, wrap_error(err)}
    end
  end

  defp single(adapter, op, op_opts, args) do
    case run_step(adapter, op, op_opts, args) do
      {:ok, res} -> {:ok, outcome_json(res)}
      {:error, err} -> {:refuse, Map.get(err, :reason, :error), err}
    end
  end

  defp wrap_error(%{reason: _} = err) when not is_struct(err), do: err
  defp wrap_error(other), do: %{reason: :build_failed, error: other}

  defp outcome_json(res) do
    base = %{"state" => Atom.to_string(ReactorOutcome.state(res))}

    case res do
      {:ok, value} -> Map.put(base, "value", render(value))
      {:error, err} -> Map.put(base, "reason", render(err))
      _ -> base
    end
  end

  defp safe(conn, fun) do
    case fun.() do
      {:ok, map} -> Json.send_json(conn, 200, map)
      {:refuse, term, reason} -> Json.refuse(conn, term, reason)
    end
  rescue
    e -> Json.refuse(conn, "internal_refusal", Exception.message(e))
  catch
    kind, value -> Json.refuse(conn, "internal_#{kind}", value)
  end

  # JSON-safe rendering of arbitrary terms.
  defp render(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp render(%_{} = struct), do: inspect(struct, limit: 200, printable_limit: 1000)

  defp render(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {render_key(k), render(v)} end)

  defp render(list) when is_list(list), do: Enum.map(list, &render/1)
  defp render(tuple) when is_tuple(tuple), do: inspect(tuple, limit: 50, printable_limit: 500)
  defp render(nil), do: nil
  defp render(bool) when is_boolean(bool), do: bool
  defp render(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp render(num) when is_number(num), do: num

  defp render(bin) when is_binary(bin),
    do: if(String.valid?(bin), do: bin, else: inspect(bin, limit: 50))

  defp render(other), do: inspect(other, limit: 50)

  defp render_key(k) when is_binary(k), do: k
  defp render_key(k) when is_atom(k) or is_number(k), do: to_string(k)
  defp render_key(k), do: inspect(k)
end
