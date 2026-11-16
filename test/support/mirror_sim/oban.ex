defmodule AshPPlan.MirrorSim.Oban do
  @moduledoc """
  Mirror-sim area `/oban/*`: drives the real `AshPPlan.Oban` projection and the
  real `AshPPlan.Action.Run` refusal boundary over HTTP.

  Subjects are restricted to an allowlist of fixture resources (no atom minting
  from request input). Terms are rendered to JSON by `jsonable/1`; the parity
  court compares the wire body against `jsonable/1` of the direct call.
  """
  use Plug.Router

  alias AshPPlan.MirrorSim.Json

  @resources %{
    "AshPPlan.ObanIntegrationResource" => AshPPlan.ObanIntegrationResource,
    "AshPPlan.DescriptorFixtures.PlainResource" => AshPPlan.DescriptorFixtures.PlainResource
  }

  @units %{
    "second" => :second,
    "seconds" => :seconds,
    "minute" => :minute,
    "minutes" => :minutes,
    "hour" => :hour,
    "hours" => :hours,
    "day" => :day,
    "days" => :days,
    "week" => :week,
    "weeks" => :weeks
  }

  plug(:match)
  plug(:dispatch)

  @doc "Routes mounted by this area."
  @spec surfaces() :: [map()]
  def surfaces do
    [
      %{module: AshPPlan.Oban, fun: :describe_resource, arity: 1, route: "/oban/describe"},
      %{module: AshPPlan.Oban, fun: :activations, arity: 1, route: "/oban/activations"},
      %{module: AshPPlan.Oban, fun: :capabilities, arity: 1, route: "/oban/capabilities"},
      %{module: AshPPlan.Oban, fun: :fetch_activation, arity: 2, route: "/oban/activation"},
      %{module: AshPPlan.Oban, fun: :construct_trigger, arity: 3, route: "/oban/construct"},
      %{module: AshPPlan.Oban, fun: :observation, arity: 1, route: "/oban/observation"},
      %{module: AshPPlan.Action.Run, fun: :run, arity: 3, route: "/oban/run"}
    ]
  end

  @doc "Default fixture resource name."
  @spec default_resource() :: String.t()
  def default_resource, do: "AshPPlan.ObanIntegrationResource"

  @doc """
  Render any term as JSON-safe data: atoms and structs become strings, tuples
  become lists, maps get string keys.
  """
  @spec jsonable(term()) :: term()
  def jsonable(nil), do: nil
  def jsonable(v) when is_boolean(v) or is_number(v) or is_binary(v), do: v
  def jsonable(v) when is_atom(v), do: Atom.to_string(v)
  def jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)
  def jsonable(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&jsonable/1)

  def jsonable(%_{} = v), do: inspect(v, limit: 30)

  def jsonable(v) when is_map(v),
    do: Map.new(v, fn {k, val} -> {key(k), jsonable(val)} end)

  def jsonable(v), do: inspect(v, limit: 30)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  get "/describe" do
    with_resource(conn, fn r -> result(conn, AshPPlan.Oban.describe_resource(r)) end)
  end

  get "/activations" do
    with_resource(conn, fn r -> result(conn, AshPPlan.Oban.activations(r)) end)
  end

  get "/capabilities" do
    with_resource(conn, fn r -> result(conn, AshPPlan.Oban.capabilities(r)) end)
  end

  get "/activation" do
    with_resource(conn, fn r ->
      case activation_name(r, conn.params["name"]) do
        {:ok, name} ->
          result(conn, AshPPlan.Oban.fetch_activation(r, name))

        :error ->
          result(
            conn,
            {:error, %{reason: :unknown_ash_oban_activation, name: conn.params["name"]}}
          )
      end
    end)
  end

  post "/construct" do
    with_resource(conn, fn r ->
      trigger = conn.params["trigger"]

      case activation_name(r, trigger) do
        {:ok, name} ->
          record = struct(r, id: Ash.UUID.generate(), processed: false)

          case AshPPlan.Oban.construct_trigger(record, name) do
            {:ok, %Ecto.Changeset{} = cs} -> Json.send_json(conn, 200, %{"ok" => job_summary(cs)})
            other -> result(conn, other)
          end

        :error ->
          record = struct(r, id: Ash.UUID.generate())
          result(conn, AshPPlan.Oban.construct_trigger(record, :__unknown_trigger__))
      end
    end)
  end

  post "/observation" do
    case to_term(conn.params["kind"], conn.params["value"]) do
      {:ok, term} -> Json.send_json(conn, 200, jsonable(AshPPlan.Oban.observation(term)))
      :error -> Json.refuse(conn, "unknown_observation_kind", inspect(conn.params["kind"]))
    end
  end

  post "/run" do
    params = conn.params
    opts = run_opts(params["opts"])
    args = run_args(params["arguments"])

    case AshPPlan.Action.Run.run(%{arguments: args}, opts, %{}) do
      {:error, %AshPPlan.Action.Run.Refusal{} = e} ->
        Json.refuse(conn, e.reason, e.details)

      {:error, other} ->
        Json.refuse(conn, "action_error", inspect(other, limit: 20))

      {:ok, v} ->
        Json.send_json(conn, 200, %{"ok" => jsonable(v)})
    end
  end

  match _ do
    Json.refuse(conn, "unknown_route", "no oban route #{conn.method} #{conn.request_path}", 404)
  end

  # --- helpers ---

  defp with_resource(conn, fun) do
    name = conn.params["resource"] || default_resource()

    case Map.fetch(@resources, name) do
      {:ok, r} -> fun.(r)
      :error -> Json.refuse(conn, "unknown_resource", name)
    end
  end

  defp result(conn, {:ok, value}), do: Json.send_json(conn, 200, %{"ok" => jsonable(value)})

  defp result(conn, {:error, %{reason: reason} = err}),
    do: Json.refuse(conn, reason, jsonable(Map.delete(err, :reason)) |> Json.encode!())

  defp result(conn, {:error, other}), do: Json.refuse(conn, "error", inspect(other, limit: 20))

  # Names resolve only against the resource's real activations (no atom minting).
  defp activation_name(resource, name) when is_binary(name) do
    case AshPPlan.Oban.activations(resource) do
      {:ok, acts} ->
        case Enum.find(acts, &(Atom.to_string(&1.name) == name)) do
          nil -> :error
          a -> {:ok, a.name}
        end

      _ ->
        :error
    end
  end

  defp activation_name(_resource, _), do: :error

  defp job_summary(%Ecto.Changeset{} = cs) do
    %{
      "valid" => cs.valid?,
      "inserted" => not is_nil(cs.action),
      "worker" => jsonable(Ecto.Changeset.get_field(cs, :worker)),
      "queue" => jsonable(Ecto.Changeset.get_field(cs, :queue)),
      "max_attempts" => Ecto.Changeset.get_field(cs, :max_attempts),
      "args" => jsonable(Ecto.Changeset.get_field(cs, :args))
    }
  end

  defp to_term("ok", _), do: {:ok, :ok}
  defp to_term("ok_value", v), do: {:ok, {:ok, jsonable(v)}}
  defp to_term("snooze", s) when is_integer(s), do: {:ok, {:snooze, s}}

  defp to_term("snooze", [amount, unit]) when is_integer(amount) and is_binary(unit) do
    case Map.fetch(@units, unit) do
      {:ok, u} -> {:ok, {:snooze, {amount, u}}}
      :error -> {:ok, {:snooze, {amount, unit}}}
    end
  end

  defp to_term("cancel", v), do: {:ok, {:cancel, v}}
  defp to_term("discard", nil), do: {:ok, :discard}
  defp to_term("discard", v), do: {:ok, {:discard, v}}
  defp to_term("error", v), do: {:ok, {:error, v}}
  defp to_term("other", v), do: {:ok, v}
  defp to_term(_, _), do: :error

  defp run_opts(%{} = o) do
    []
    |> maybe_put(:plans, o["plans"])
    |> maybe_put(:handlers, if(o["handlers"] == true, do: %{}, else: nil))
    |> maybe_put(:allow_halt?, o["allow_halt?"])
  end

  defp run_opts(_), do: []

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp run_args(%{} = a) do
    Enum.reduce(a, %{}, fn
      {"plan_iri", v}, acc -> Map.put(acc, :plan_iri, v)
      {"input", v}, acc -> Map.put(acc, :input, v)
      {"handlers", v}, acc -> Map.put(acc, :handlers, v)
      _, acc -> acc
    end)
  end

  defp run_args(_), do: %{}
end
