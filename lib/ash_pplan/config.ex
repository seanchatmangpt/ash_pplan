defmodule AshPPlan.Config do
  @moduledoc """
  Single seam for runtime Application-environment reads of `:ash_pplan`.

  Every runtime config key has one documented fetch here, so the key set is
  auditable and greppable from one place. Semantics are unchanged from the
  former scattered `Application.get_env` sites: reads happen at call time
  (never baked at compile time), because tests and hosts override these keys
  at runtime (`config/test.exs`, `Application.put_env` in suites).

  Graduation notes: `:durable_store_module` and `:durable_halt_timeout` have
  no runtime overrides today and could later graduate to
  `Application.compile_env` if the runtime-override need disappears.
  `:durable_store_module` is fail-closed: an explicit `nil` is refused with
  `{:error, %{reason: :durable_store_unconfigured}}` instead of silently
  falling back to the ETS store.
  `:extra_adapters`, `:extra_capability_families` and
  `:standing_flight_timeout_ms` are overridden at runtime by test suites and
  must stay call-time reads.
  """

  @default_standing_flight_timeout_ms 5_000
  @default_durable_store_module AshPPlan.Reactor.Durable.Store.Ets
  @default_durable_halt_timeout 5_000
  @default_digest_module AshPPlan.Digest.SHA256

  @doc "Adapter id => module map merged over the built-ins by `AshPPlan.Reactor.adapters/0`."
  @spec extra_adapters() :: %{optional(atom()) => module()}
  def extra_adapters,
    do: Map.new(Application.get_env(:ash_pplan, :extra_adapters, %{}))

  @doc "Host-registered capability families appended by `AshPPlan.Capability.families/0`."
  @spec extra_capability_families() :: [atom()]
  def extra_capability_families,
    do: Application.get_env(:ash_pplan, :extra_capability_families, [])

  @doc "Single-flight timeout (ms) for the standing evidence cache. Default `5_000`."
  @spec standing_flight_timeout_ms() :: pos_integer()
  def standing_flight_timeout_ms do
    case Application.get_env(
           :ash_pplan,
           :standing_flight_timeout_ms,
           @default_standing_flight_timeout_ms
         ) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "invalid :standing_flight_timeout_ms: #{inspect(other)}"
    end
  end

  @doc """
  Store module for durable reactor runs. Default `AshPPlan.Reactor.Durable.Store.Ets`.

  Fail-closed: an explicitly-configured `nil` is a misconfiguration, not a
  fallback — it returns `{:error, %{reason: :durable_store_unconfigured}}`
  which `Reactor.Durable.Run.run/3` surfaces as a typed refusal before any
  step executes.
  """
  @spec durable_store_module() ::
          {:ok, module()} | {:error, %{reason: :durable_store_unconfigured}}
  def durable_store_module do
    case Application.get_env(:ash_pplan, :durable_store_module, @default_durable_store_module) do
      nil -> {:error, %{reason: :durable_store_unconfigured}}
      mod -> {:ok, mod}
    end
  end

  @doc "Ms before `Reactor.run/3` halts a durable run. Default `5_000`."
  @spec durable_halt_timeout() :: pos_integer()
  def durable_halt_timeout do
    case Application.get_env(:ash_pplan, :durable_halt_timeout, @default_durable_halt_timeout) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "invalid :durable_halt_timeout: #{inspect(other)}"
    end
  end

  @doc """
  Digest module for step keys, checkpoint output digests, and ledger/counterfactual
  digests. Must implement `hash/1` (binary -> binary). Default
  `AshPPlan.Digest.SHA256` (behavior-identical to the former hardcoded calls).
  """
  @spec digest_module() :: module()
  def digest_module do
    case Application.get_env(:ash_pplan, :digest_module, @default_digest_module) do
      nil -> raise ArgumentError, ":digest_module explicitly set to nil is a misconfiguration"
      mod -> mod
    end
  end
end
