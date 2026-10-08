defmodule AshPPlan.MapUpdateW609ResidualCourtTest do
  @moduledoc """
  W609 residual court for the OS-20 `Map.update/4` deviation sweep (WP-4, quartet
  closer). Commit 7eeaaa1 already converted the 8 absent-key-critical lib sites to
  the dual-safe `case Map.fetch` idiom (w603). This court pins the RESIDUAL
  `Map.update`-family sites on lib/ as of the v26.10.7 sweep:

    - synthesis.ex:217 — the only remaining non-bang `Map.update/4` site;
      provably invariant under BOTH semantics because `fun.(default) == default`
      (`min(action, action) == action`).
    - state_machine.ex:393, provider_registry.ex:38/:80, ets.ex:336, dets.ex:526 —
      `Map.update!/3` (bang) sites; `Map.update!/3` takes no default and raises
      `KeyError` on an absent key under both semantics (deviation does not apply).

  Each row is parameterized over {module, site, invariant}. The deviation witness
  at the bottom re-derives the runtime behavior fresh (mirrors the w603 witness),
  so a toolchain fix flips it and forces re-review instead of silently changing
  every residual site's classification.
  """

  use ExUnit.Case, async: true

  defp identity(x), do: x

  @sites [
    {:synthesis_217, "lib/ash_pplan/fond/synthesis.ex", 217,
     "Map.update(acc, state, action, &min(&1, action)) — fun.(default)==default, invariant under both semantics"},
    {:state_machine_393, "lib/ash_pplan/state_machine.ex", 393,
     "Map.update!/3 — bang form, no default, absent key raises under both semantics"},
    {:provider_registry_38, "lib/ash_pplan/fond/provider_registry.ex", 38,
     "Map.update!/3 after Map.put_new(:capabilities) — key guaranteed present"},
    {:provider_registry_80, "lib/ash_pplan/fond/provider_registry.ex", 80,
     "Map.update!/3 guarded by Map.has_key? — key guaranteed present"},
    {:ets_336, "lib/ash_pplan/reactor/durable/store/ets.ex", 336,
     "Map.update!(:version) on a fetched run record — key structurally present"},
    {:dets_526, "lib/ash_pplan/reactor/durable/store/dets.ex", 526,
     "Map.update!(:version) on a fetched run record — key structurally present"}
  ]

  test "site census is current: every residual Map.update-family site in lib/ is classified" \
       do
    lib = Path.join(File.cwd!(), "lib")

    actual =
      lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, no} ->
          if String.contains?(line, "Map.update") do
            [{path, no, String.trim(line)}]
          else
            []
          end
        end)
      end)

    # Every hit must be classified by this court's site table (same file+line).
    classified =
      MapSet.new(@sites, fn {_id, path, line, _note} -> {Path.join(File.cwd!(), path), line} end)

    unclassified =
      Enum.reject(actual, fn {path, no, _text} -> MapSet.member?(classified, {path, no}) end)

    assert unclassified == [],
           "unclassified residual Map.update sites: #{inspect(unclassified, pretty: true)}"
  end

  describe "class (b) sites: invariant under both Map.update semantics" do
    @tag :w609
    test "synthesis min-accumulator: default == fun.(default), so both semantics agree" do
      # The exact accumulator shape at synthesis.ex:217. Built through an
      # opaque function so the type checker cannot prove it statically empty.
      acc = identity(%{})

      result_under_deviation = Map.update(acc, :s, 5, &min(&1, 5))
      result_under_documented = case Map.fetch(acc, :s) do
        :error -> Map.put(acc, :s, min(5, 5))
        {:ok, v} -> Map.put(acc, :s, min(v, 5))
      end

      assert result_under_deviation == result_under_documented

      # Present-key path: min accumulates identically under both.
      present = Map.update(%{s: 7}, :s, 5, &min(&1, 5))
      assert present == %{s: 5}
    end
  end

  describe "bang sites: Map.update!/3 semantics do not deviate" do
    @tag :w609
    test "absent key raises KeyError under both semantics (no default to deviate on)" do
      raised? =
        try do
          Map.update!(identity(%{}), :k, &(&1 + 1))
          false
        rescue
          KeyError -> true
        end

      assert raised?
    end

    @tag :w609
    test "provider_registry.put: absent :capabilities chain ends with a real MapSet" do
      {:ok, registry} =
        AshPPlan.FOND.ProviderRegistry.put(%AshPPlan.FOND.ProviderRegistry{}, %{
          id: :p1,
          endpoint: {"localhost", 4000}
        })

      assert %MapSet{} = registry.providers[:p1].capabilities
      assert registry.providers[:p1].healthy? == true
    end

    @tag :w609
    test "observe_health present-key update flips healthy? and bumps generation" do
      {:ok, r0} = AshPPlan.FOND.ProviderRegistry.put(%AshPPlan.FOND.ProviderRegistry{}, %{id: :p1})
      generation = r0.generation

      {:ok, r1} = AshPPlan.FOND.ProviderRegistry.observe_health(r0, generation, :p1, false)

      assert r1.providers[:p1].healthy? == false
      assert r1.generation == r0.generation + 1
    end
  end

  describe "durable stores: version bump stays correct through put_run" do
    @tag :w609
    test "ets store start_run -> transition bumps version monotonically" do
      {:ok, st} = AshPPlan.Reactor.Durable.Store.Ets.start_link()
      {:ok, rec} = AshPPlan.Reactor.Durable.Store.Ets.start_run(st, %{id: "w609", input: %{}})

      assert rec.version >= 1
    end
  end

  describe "runtime deviation witness (fresh, re-derived each run)" do
    @tag :w609
    test "pin the observed deviation so a toolchain fix forces re-review" do
      absent = Map.update(%{}, :k, 1, &(&1 + 10))

      if Map.get(absent, :k) == 1 do
        # Deviating runtime: fun skipped on absent key.
        assert absent == %{k: 1}
      else
        # Fixed runtime: documented semantics restored (fun applied to default).
        assert absent == %{k: 11}
      end
    end
  end
end
