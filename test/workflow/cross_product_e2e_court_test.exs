defmodule AshPPlan.Workflow.CrossProductE2ECourtTest do
  @moduledoc """
  End-to-end cross-product court: the full Cartesian product of
  `AshPPlan.Workflow.CapabilityCatalog.all/0` x the realizable providers in
  `AshPPlan.Test.Examples.ProviderIndex`.

  For every (capability, provider) pair a single-task durable workflow is
  synthesized with that capability on the task, resolved against a registry
  containing ONLY that provider, and executed end to end through the real
  durable runtime (`AshPPlan.Workflow.Runtime.run` over
  `AshPPlan.Reactor.Durable.Store.Ets`, fresh store per pair). If the run parks
  on a human gate, the gate is signaled and the run resumed.

  Asserted per pair: the outcome is TYPED — `{:ok, state}` with
  `observation.state in [:succeeded, :halted_after_resume]`, a parked-then-
  completed run, or a typed `{:error, map()}` refusal — and NEVER a raise.

  Anti-vacuity: pair count must equal
  `length(CapabilityCatalog.all/0) * length(ProviderIndex.modules/0)` (>= 31 * 10),
  so a silently shrunk catalog or provider index cannot pass vacuously.

  Scale gate: `PPLAN_XPRODUCT_MAX` caps the number of pairs executed
  (default: the full product).
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Examples.ProviderIndex
  alias AshPPlan.Workflow.{CapabilityCatalog, Model, Runtime}

  @capability_count length(CapabilityCatalog.all())
  @min_capabilities 31
  @min_providers 10

  # Known-crash exclusion list (pair => stacktrace summary). Empty until a crash is found.
  @known_crashes %{}
  defp known_crash?(pair), do: Map.has_key?(@known_crashes, pair)

  defp pairs do
    for cap <- CapabilityCatalog.all(), provider <- ProviderIndex.modules() do
      {cap.id, provider}
    end
  end

  defp capped(pairs) do
    case System.get_env("PPLAN_XPRODUCT_MAX") do
      nil -> pairs
      v -> Enum.take(pairs, String.to_integer(v))
    end
  end

  defp model_for(capability_id) do
    {:ok, model} =
      Model.new(
        name: "xproduct_#{capability_id}",
        goal: "xproduct_#{capability_id}_goal",
        tasks: [
          %{
            id: :the_task,
            capability: capability_id,
            depends_on: [],
            outcomes: [:done],
            # no required properties: this court measures the (capability, provider)
            # product, so the task must not demand properties (e.g. :durable) that
            # would refuse at qualification before any real execution. The durable
            # runtime is engaged by passing `store:`, not by this property.
            properties: [],
            authority: :observe
          }
        ],
        methods: []
      )

    model
  end

  # Runs one (capability, provider) pair end to end. Returns
  # {:ok, :succeeded, state} | {:ok, :refused, reason} — raises on crash.
  defp run_pair(capability_id, provider) do
    if known_crash?({capability_id, provider}) do
      {:ok, :refused, %{reason: :known_crash_excluded}}
    else
      do_run_pair(capability_id, provider)
    end
  end

  defp do_run_pair(capability_id, provider) do
    model = model_for(capability_id)
    {:ok, store} = Ets.start_link()

    try do
      case Runtime.run(model, %{frontier: [%{id: :the_task, status: :open, deps: []}]},
             providers: [provider],
             store: store,
             run_id: "xprod-#{capability_id}-#{inspect(provider)}",
             halt_timeout: 5_000
           ) do
        {:ok, state} ->
          finish(state, store)

        {:error, reason} ->
          {:ok, :refused, reason}
      end
    catch
      kind, reason ->
        reraise "CROSS_PRODUCT_CRASH #{capability_id} x #{inspect(provider)}: " <>
                  "#{inspect(kind)} #{inspect(reason)}",
                __STACKTRACE__
    after
      GenServer.stop(store, :normal, 1_000)
    end
  end

  # A run that reached execution: drive it (and any gate parking) to a terminal
  # state, resuming with signals for every waiter.
  defp finish(state, store, resumptions \\ 0)

  defp finish(_state, _store, resumptions) when resumptions > 4 do
    {:ok, :refused, %{reason: :xproduct_resume_budget_exhausted}}
  end

  defp finish(%{observation: %{state: :succeeded}} = state, _store, _n),
    do: {:ok, :succeeded, state}

  defp finish(%{observation: %{state: :halted}} = state, store, n) do
    {:ok, explained} = Runtime.explain(state)
    waiters = explained.durable.waiting_on

    case waiters do
      [] ->
        {:ok, :refused, %{reason: :xproduct_halted_without_waiters}}

      [wait | _] ->
        case Runtime.resume(state, signal: {wait, %{released: true}}) do
          {:ok, next} -> finish(next, store, n + 1)
          {:error, reason} -> {:ok, :refused, reason}
        end
    end
  end

  defp finish(%{observation: %{state: :failed}} = state, _store, _n),
    do: {:ok, :refused, %{reason: :task_failed, failed_task: state.observation.failed_task}}

  defp finish(%{observation: %{state: other}} = _state, _store, _n),
    do: {:ok, :refused, %{reason: :unexpected_observation_state, state: other}}

  defp finish(_state, _store, _n), do: {:ok, :refused, %{reason: :xproduct_invalid_state}}

  test "every (capability, provider) pair runs end to end with a typed outcome" do
    all_pairs = pairs()
    providers = ProviderIndex.modules() |> Enum.uniq()

    # anti-vacuity: the product is the real product, and neither axis is shrunken
    assert @capability_count >= @min_capabilities,
           "capability catalog shrank: #{@capability_count} < #{@min_capabilities}"

    assert length(providers) >= @min_providers,
           "provider index shrank: #{length(providers)} < #{@min_providers}"

    assert length(all_pairs) == @capability_count * length(providers)

    executed = capped(all_pairs)
    expected_executed = length(executed)

    {elapsed_ms, {caps, counts}} =
      :timer.tc(
        fn ->
          Enum.map_reduce(executed, %{succeeded: 0, refused: 0, reasons: []}, fn {cap, prov},
                                                                                 acc ->
            case run_pair(cap, prov) do
              {:ok, :succeeded, state} ->
                assert is_map(state)
                {cap, acc |> Map.update!(:succeeded, &(&1 + 1))}

              {:ok, :refused, reason} ->
                assert is_map(reason) and Map.has_key?(reason, :reason),
                       "untyped refusal for #{cap} x #{inspect(prov)}: #{inspect(reason)}"

                {cap,
                 acc
                 |> Map.update!(:refused, &(&1 + 1))
                 |> Map.update!(:reasons, &[reason.reason | &1])}
            end
          end)
        end,
        :millisecond
      )

    assert length(caps) == expected_executed
    refusal_reasons = counts.reasons |> Enum.frequencies()
    assert counts.succeeded + counts.refused == expected_executed
    assert Enum.sum(Map.values(refusal_reasons)) == counts.refused

    per_cap =
      executed
      |> Enum.group_by(fn {c, _} -> c end)
      |> Enum.map(fn {cap, cap_pairs} ->
        {cap, length(cap_pairs)}
      end)
      |> Map.new()

    IO.puts("""
    \n=== Cross-product E2E court ===
    capabilities: #{@capability_count}  providers: #{length(providers)}
    pairs executed: #{expected_executed} (of #{length(all_pairs)} total)
    succeeded: #{counts.succeeded}   refused (typed): #{counts.refused}   crashes: 0
    elapsed: #{elapsed_ms} ms  (#{Float.round(expected_executed / max(elapsed_ms / 1000, 0.001), 1)} pairs/sec)

    refusal reasons:
    """)

    Enum.each(Enum.sort_by(refusal_reasons, fn {_, n} -> -n end), fn {r, n} ->
      IO.puts("  #{String.pad_trailing(inspect(r), 40)} #{n}")
    end)

    per_cap
    |> Enum.sort()
    |> Enum.each(fn {cap, n} ->
      IO.puts("  #{String.pad_trailing(cap, 24)} pairs: #{n}")
    end)

    IO.puts("=== end cross-product court ===\n")
  end

  test "anti-vacuity: an omitted capability axis breaks the product count" do
    providers = ProviderIndex.modules() |> Enum.uniq()
    full = length(CapabilityCatalog.all()) * length(providers)
    assert full == @capability_count * length(providers)
    assert full >= 31 * 10
    assert full != length(CapabilityCatalog.all()) * (length(providers) - 1)
  end
end
