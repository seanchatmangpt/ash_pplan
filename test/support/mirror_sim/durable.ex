defmodule AshPPlan.MirrorSim.Durable.Host do
  @moduledoc """
  Owns the real collaborators behind the mirror-sim durable routes: one `Store.Ets`, one
  `AshPPlan.Test.Effects` counter and one `LeaseMonitor`, plus the lease-holder processes the
  wire can spawn and kill. Started lazily (unlinked from the request process) and stopped by
  `reset/0`; `terminate/2` stops every child synchronously so names are free on return.
  """
  use GenServer

  @store :mirror_sim_durable_store
  @fx :mirror_sim_durable_effects
  @lease :mirror_sim_durable_lease

  def store, do: @store
  def fx, do: @fx
  def lease, do: @lease

  @spec ensure() :: :ok
  def ensure do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @spec reset() :: :ok
  def reset do
    if Process.whereis(__MODULE__), do: GenServer.stop(__MODULE__)
    ensure()
  end

  @spec new_holder() :: String.t()
  def new_holder, do: GenServer.call(__MODULE__, :new_holder)

  @spec holder(String.t()) :: pid() | nil
  def holder(name), do: GenServer.call(__MODULE__, {:holder, name})

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, store} = AshPPlan.Reactor.Durable.Store.Ets.start_link(name: @store)
    {:ok, fx} = AshPPlan.Test.Effects.start_link(name: @fx)
    {:ok, lease} = AshPPlan.Reactor.Durable.LeaseMonitor.start_link(name: @lease)
    {:ok, %{store: store, fx: fx, lease: lease, holders: %{}, n: 0}}
  end

  @impl true
  def handle_call(:new_holder, _from, s) do
    n = s.n + 1
    name = "h#{n}"
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    {:reply, name, %{s | n: n, holders: Map.put(s.holders, name, pid)}}
  end

  def handle_call({:holder, name}, _from, s), do: {:reply, Map.get(s.holders, name), s}

  @impl true
  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    Enum.each(s.holders, fn {_, pid} -> Process.exit(pid, :kill) end)
    if Process.alive?(s.lease), do: GenServer.stop(s.lease)
    if Process.alive?(s.fx), do: Agent.stop(s.fx)
    if Process.alive?(s.store), do: GenServer.stop(s.store)
    :ok
  end
end

defmodule AshPPlan.MirrorSim.Durable do
  @moduledoc """
  Mirror-sim routes for `AshPPlan.Reactor.Durable.*`, mounted at `/durable/*` (paths here are
  relative to the mount). Every route drives the real `Engine`, `Store.Ets`, `Unwind`,
  `Counterfactual`, `LedgerOCEL`, `LeaseMonitor`, `Portable`, `Verifier` and the test `Clock`.
  Runs use `AshPPlan.Test.DurableFx` (the test adapter must be installed by the caller via
  `DurableFx.install_adapter!/0`). Typed refusals are HTTP 422
  `{"refused":true,"broken_term":...,"reason":...}`; no route answers 500 on bad input.
  """
  use Plug.Router

  alias AshPPlan.Reactor.Durable.{
    Clock,
    Counterfactual,
    Engine,
    LeaseMonitor,
    LedgerOCEL,
    Portable,
    Run,
    Unwind,
    Verifier
  }

  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.MirrorSim.Durable.Host
  alias AshPPlan.Test.{DurableFx, Effects}

  plug(:parse_body)
  plug(:match)
  plug(:dispatch)

  @sm [store_module: Ets]

  @doc "Surfaces mirrored by this area."
  def surfaces do
    [
      {Engine, :start, 3, "/durable/runs"},
      {Engine, :fetch, 3, "/durable/runs/:id"},
      {Engine, :attempt, 3, "/durable/runs/:id/attempt"},
      {Engine, :signal, 5, "/durable/runs/:id/signal"},
      {Engine, :cancel, 3, "/durable/runs/:id/cancel"},
      {Engine, :wake, 3, "/durable/runs/:id/wake"},
      {Engine, :runnable?, 4, "/durable/runs/:id/runnable"},
      {Engine, :steps, 3, "/durable/runs/:id/steps"},
      {Ets, :claim, 5, "/durable/runs/:id/claim"},
      {Unwind, :run, 3, "/durable/runs/:id/unwind"},
      {Verifier, :verify, 1, "/durable/runs/:id/verify"},
      {LedgerOCEL, :export, 3, "/durable/runs/:id/ocel"},
      {LedgerOCEL, :digest, 3, "/durable/runs/:id/ocel"},
      {Counterfactual, :replay, 3, "/durable/runs/:id/counterfactual"},
      {Counterfactual, :ledger_digest, 3, "/durable/runs/:id/ledger_digest"},
      {Clock, :advance, 1, "/durable/clock/advance"},
      {LeaseMonitor, :claim, 3, "/durable/lease/claim"},
      {LeaseMonitor, :heartbeat, 3, "/durable/lease/heartbeat"},
      {LeaseMonitor, :release, 3, "/durable/lease/release"},
      {LeaseMonitor, :status, 2, "/durable/lease/status"},
      {Portable, :portable?, 1, "/durable/portable/check"},
      {Portable, :encode, 1, "/durable/portable/check"}
    ]
    |> Enum.map(fn {m, f, a, r} -> %{module: m, fun: f, arity: a, route: r} end)
  end

  # ---- body parsing ---------------------------------------------------------------------

  def parse_body(conn, _opts) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", conn} ->
        Plug.Conn.assign(conn, :body, %{})

      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, %{} = map} -> Plug.Conn.assign(conn, :body, map)
          _ -> conn |> refuse("bad_json", "body is not a JSON object") |> Plug.Conn.halt()
        end

      _ ->
        conn |> refuse("bad_body", "unreadable body") |> Plug.Conn.halt()
    end
  end

  # ---- runs -----------------------------------------------------------------------------

  post "/runs" do
    safe(conn, fn ->
      case body(conn)["id"] do
        id when is_binary(id) and id != "" ->
          {:ok, rec} = Engine.start(Host.store(), DurableFx.attrs(id, effects: Host.fx()), @sm)
          reply(conn, 200, %{"run" => summary(rec)})

        other ->
          refuse(conn, "bad_id", other)
      end
    end)
  end

  get "/runs/:id" do
    safe(conn, fn ->
      case Engine.fetch(Host.store(), id(conn), @sm) do
        nil -> refuse(conn, "no_such_run", id(conn))
        rec -> reply(conn, 200, %{"run" => summary(rec)})
      end
    end)
  end

  post "/runs/:id/attempt" do
    safe(conn, fn ->
      b = body(conn)
      opts = @sm ++ attempt_opts(b)
      reply(conn, 200, outcome(Engine.attempt(Host.store(), id(conn), opts)))
    end)
  end

  post "/runs/:id/signal" do
    safe(conn, fn ->
      b = body(conn)
      name = b["name"] || DurableFx.signal_name()

      case Engine.signal(Host.store(), id(conn), name, b["payload"], @sm) do
        {:ok, _} -> reply(conn, 200, %{"delivered" => true})
        {:error, reason} -> refuse(conn, "signal_refused", reason)
      end
    end)
  end

  post "/runs/:id/cancel" do
    safe(conn, fn ->
      case Engine.cancel(Host.store(), id(conn), @sm) do
        {:ok, rec} -> reply(conn, 200, %{"run" => summary(rec)})
        {:error, reason} -> refuse(conn, "cancel_refused", reason)
      end
    end)
  end

  post "/runs/:id/wake" do
    safe(conn, fn ->
      reply(conn, 200, outcome(Engine.wake(Host.store(), id(conn), @sm)))
    end)
  end

  get "/runs/:id/runnable" do
    safe(conn, fn ->
      case Engine.fetch(Host.store(), id(conn), @sm) do
        nil ->
          refuse(conn, "no_such_run", id(conn))

        rec ->
          now = Clock.now()

          reply(conn, 200, %{
            "runnable" => Engine.runnable?(Host.store(), rec, now, @sm),
            "in_runnable_set" => id(conn) in Engine.runnable(Host.store(), now, @sm)
          })
      end
    end)
  end

  get "/runs/:id/steps" do
    safe(conn, fn ->
      steps = Engine.steps(Host.store(), id(conn), @sm)
      reply(conn, 200, %{"steps" => Enum.map(steps, & &1.label)})
    end)
  end

  post "/runs/:id/claim" do
    safe(conn, fn ->
      b = body(conn)
      claimer = b["claimer"] || "wire-claimer"
      lease = b["lease_ms"] || Engine.lease_ms()

      case Ets.claim(Host.store(), id(conn), claimer, lease, Clock.now()) do
        {:ok, rec} -> reply(conn, 200, %{"claimed" => true, "run" => summary(rec)})
        :taken -> refuse(conn, "claim_taken", id(conn))
      end
    end)
  end

  post "/runs/:id/unwind" do
    safe(conn, fn ->
      case Unwind.run(Host.store(), id(conn), @sm) do
        {:ok, unresolved} -> reply(conn, 200, %{"unresolved" => enc(unresolved)})
        {:error, errors} -> refuse(conn, "unwind_failed", errors)
      end
    end)
  end

  get "/runs/:id/verify" do
    safe(conn, fn ->
      with %{} = rec <- Engine.fetch(Host.store(), id(conn), @sm),
           {:ok, reactor} <- Run.reactor_for(rec) do
        case Verifier.verify(reactor) do
          :ok -> reply(conn, 200, %{"verified" => true})
          {:error, detail} -> refuse(conn, "verifier_refused", detail)
        end
      else
        nil -> refuse(conn, "no_such_run", id(conn))
        {:error, reason} -> refuse(conn, "reactor_unbuildable", reason)
      end
    end)
  end

  get "/runs/:id/ocel" do
    safe(conn, fn ->
      with {:ok, json} <- LedgerOCEL.export(Host.store(), id(conn), @sm),
           {:ok, digest} <- LedgerOCEL.digest(Host.store(), id(conn), @sm) do
        reply(conn, 200, %{"digest" => digest, "bytes" => byte_size(json), "ocel" => json})
      else
        {:error, detail} -> refuse(conn, "ocel_refused", detail)
      end
    end)
  end

  get "/runs/:id/ledger_digest" do
    safe(conn, fn ->
      digest = Counterfactual.ledger_digest(Host.store(), id(conn), @sm)
      reply(conn, 200, %{"digest" => Base.encode16(digest, case: :lower)})
    end)
  end

  post "/runs/:id/counterfactual" do
    safe(conn, fn ->
      with {:ok, change} <- decode_change(body(conn)["change"] || %{}) do
        case Counterfactual.replay(Host.store(), id(conn), @sm ++ [change: change]) do
          {:ok, r} -> reply(conn, 200, %{"replay" => replay_summary(r)})
          {:error, %{reason: reason} = detail} -> refuse(conn, to_string(reason), detail)
        end
      else
        {:error, detail} -> refuse(conn, "invalid_change", detail)
      end
    end)
  end

  # ---- clock / effects ------------------------------------------------------------------

  post "/clock/advance" do
    safe(conn, fn ->
      case body(conn)["ms"] do
        ms when is_integer(ms) and ms >= 0 ->
          now = Clock.advance(ms)
          reply(conn, 200, %{"now" => DateTime.to_iso8601(now)})

        other ->
          refuse(conn, "bad_ms", other)
      end
    end)
  end

  get "/effects" do
    safe(conn, fn -> reply(conn, 200, %{"counts" => enc(Effects.all(Host.fx()))}) end)
  end

  post "/effects/fail_after" do
    safe(conn, fn ->
      b = body(conn)

      case {b["effect"], b["n"]} do
        {e, n} when e in ["admit", "authorize", "commit"] and is_integer(n) and n >= 0 ->
          :ok = Effects.fail_after(Host.fx(), String.to_existing_atom(e), n)
          reply(conn, 200, %{"armed" => true})

        other ->
          refuse(conn, "bad_effect", other)
      end
    end)
  end

  # ---- lease monitor --------------------------------------------------------------------

  post "/lease/holders" do
    safe(conn, fn -> reply(conn, 200, %{"holder" => Host.new_holder()}) end)
  end

  post "/lease/claim" do
    lease_call(conn, fn run, pid -> LeaseMonitor.claim(Host.lease(), run, pid) end)
  end

  post "/lease/heartbeat" do
    lease_call(conn, fn run, pid -> LeaseMonitor.heartbeat(Host.lease(), run, pid) end)
  end

  post "/lease/release" do
    lease_call(conn, fn run, pid -> LeaseMonitor.release(Host.lease(), run, pid) end)
  end

  post "/lease/kill" do
    safe(conn, fn ->
      case Host.holder(to_string(body(conn)["holder"])) do
        nil ->
          refuse(conn, "no_such_holder", body(conn)["holder"])

        pid ->
          Process.exit(pid, :kill)
          reply(conn, 200, %{"killed" => true})
      end
    end)
  end

  get "/lease/status" do
    safe(conn, fn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case LeaseMonitor.status(Host.lease(), conn.query_params["run_id"] || "") do
        :vacant -> reply(conn, 200, %{"status" => "vacant"})
        {:held, _pid, epoch} -> reply(conn, 200, %{"status" => "held", "epoch" => epoch})
      end
    end)
  end

  # ---- portable -------------------------------------------------------------------------

  post "/portable/check" do
    safe(conn, fn ->
      b = body(conn)

      term =
        case b["probe"] do
          "pid" -> %{runtime: self()}
          "fun" -> %{runtime: fn -> :ok end}
          _ -> b["term"]
        end

      case Portable.encode(term) do
        {:ok, blob} ->
          {:ok, back} = Portable.decode(blob)

          reply(conn, 200, %{
            "portable" => Portable.portable?(term),
            "bytes" => byte_size(blob),
            "roundtrip" => back == term
          })

        {:error, reason} ->
          refuse(conn, to_string(reason), %{"portable" => Portable.portable?(term)})
      end
    end)
  end

  match _ do
    refuse(conn, "unknown_route", conn.request_path, 404)
  end

  # ---- helpers --------------------------------------------------------------------------

  defp lease_call(conn, fun) do
    safe(conn, fn ->
      b = body(conn)

      case Host.holder(to_string(b["holder"])) do
        nil ->
          refuse(conn, "no_such_holder", b["holder"])

        pid ->
          case fun.(to_string(b["run_id"]), pid) do
            {:ok, epoch} -> reply(conn, 200, %{"ok" => true, "epoch" => epoch})
            :ok -> reply(conn, 200, %{"ok" => true})
            {:error, reason} -> refuse(conn, lease_term(reason), reason)
          end
      end
    end)
  end

  defp lease_term({:claimed, _, _}), do: "claimed"
  defp lease_term(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp lease_term(_), do: "lease_refused"

  defp id(conn), do: conn.path_params["id"]

  defp body(conn) do
    case conn.assigns[:body] do
      %{} = m -> m
      _ -> %{}
    end
  end

  defp attempt_opts(b) do
    []
    |> maybe(:claimer, b["claimer"])
    |> maybe(:lease_ms, b["lease_ms"])
  end

  defp maybe(opts, _k, nil), do: opts
  defp maybe(opts, k, v), do: Keyword.put(opts, k, v)

  defp decode_change(change) when is_map(change) do
    Enum.reduce_while(change, {:ok, %{}}, fn
      {"outputs", outs}, {:ok, acc} when is_map(outs) ->
        case atom_keys(outs) do
          {:ok, m} -> {:cont, {:ok, Map.put(acc, :outputs, m)}}
          {:error, _} = e -> {:halt, e}
        end

      {k, _}, _ ->
        {:halt, {:error, {:unsupported_change, k}}}
    end)
  end

  defp decode_change(other), do: {:error, {:bad_change, enc(other)}}

  defp atom_keys(map) do
    {:ok, Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)}
  rescue
    ArgumentError -> {:error, {:unknown_task, Map.keys(map)}}
  end

  defp replay_summary(r) do
    d = r.diff

    %{
      "empty" => d.empty?,
      "tasks_reexecuted" => enc(d.tasks_reexecuted),
      "outcome" => enc(d.outcome),
      "standing" => enc(d.standing),
      "result_changed" => d.result.changed?,
      "events" => %{
        "added" => enc(d.events.added),
        "removed" => enc(d.events.removed),
        "changed" => length(d.events.changed)
      },
      "untouched" => r.untouched?,
      "original_status" => enc(r.original.status),
      "counterfactual_status" => enc(r.counterfactual.status)
    }
  end

  defp summary(rec) do
    %{
      "id" => Map.get(rec, :id),
      "status" => enc(Map.get(rec, :status)),
      "result" => enc(Map.get(rec, :result)),
      "error" => enc(Map.get(rec, :error)),
      "claimed_by" => enc(Map.get(rec, :claimed_by)),
      "lease_until" => enc(Map.get(rec, :lease_until))
    }
  end

  defp outcome(o) when is_atom(o), do: %{"outcome" => Atom.to_string(o)}

  defp outcome({tag, detail}) when is_atom(tag),
    do: %{"outcome" => Atom.to_string(tag), "detail" => enc(detail)}

  defp outcome(other), do: %{"outcome" => "unknown", "detail" => enc(other)}

  @doc false
  def enc(nil), do: nil
  def enc(v) when is_boolean(v) or is_number(v), do: v
  def enc(v) when is_atom(v), do: Atom.to_string(v)
  def enc(v) when is_binary(v), do: if(String.valid?(v), do: v, else: inspect(v))
  def enc(%DateTime{} = v), do: DateTime.to_iso8601(v)
  def enc(%_{} = v), do: inspect(v, limit: 50)
  def enc(v) when is_list(v), do: Enum.map(v, &enc/1)
  def enc(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&enc/1)
  def enc(v) when is_map(v), do: Map.new(v, fn {k, x} -> {key(k), enc(x)} end)
  def enc(v), do: inspect(v, limit: 50)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  defp safe(conn, fun) do
    Host.ensure()
    fun.()
  rescue
    e -> refuse(conn, "exception", Exception.message(e))
  catch
    :exit, reason -> refuse(conn, "exit", inspect(reason))
  end

  defp reply(conn, status, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(map))
  end

  defp refuse(conn, term, reason, status \\ 422) do
    reply(conn, status, %{
      "refused" => true,
      "broken_term" => to_string(term),
      "reason" => enc(reason)
    })
  end
end
