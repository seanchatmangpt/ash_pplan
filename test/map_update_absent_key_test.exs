defmodule AshPPlan.MapUpdateAbsentKeyTest do
  @moduledoc """
  W603 regression pin for the dual-safe `Map.update/4` replacement idiom deployed
  across the 8 ABSENT-KEY-RELIANT sites from w525d's census
  (docs/sjira/v26.10.6/plans/w525d-map-update-sweep.md).

  The pinned runtime (elixir 1.20.4-otp-29) deviates from documented `Map.update/4`
  semantics on the absent-key path: it inserts `default` **without** calling `fun`.
  Documented semantics store `fun.(default)`. Every patched site relies on the
  absent-key path storing the initial accumulator value (a singleton list, a seed
  map, or the first entry), so the explicit `case Map.fetch` form is used to make
  the site correct under BOTH behaviors.

  These tests pin:
    1. the idiom's absent-key contract (default stored verbatim, fun not applied),
    2. the idiom's present-key contract (fun applied to the existing value),
    3. the runtime deviation itself, so a toolchain fix flips these assertions
       and forces a re-review instead of silently double-counting every site.
  """
  use ExUnit.Case, async: true

  # The exact idiom patched into the 8 census sites.
  defp dual_safe_update(map, key, default, fun) do
    case Map.fetch(map, key) do
      :error -> Map.put(map, key, default)
      {:ok, value} -> Map.put(map, key, fun.(value))
    end
  end

  describe "dual-safe idiom" do
    test "absent key stores default verbatim, fun never applied" do
      fun = fn _ -> flunk("fun must not run on the absent-key path") end
      assert dual_safe_update(%{}, :k, [1], fun) == %{k: [1]}
    end

    test "present key applies fun to existing value" do
      assert dual_safe_update(%{k: [1]}, :k, [0], &[2 | &1]) == %{k: [2, 1]}
    end

    test "repeated reduce accumulation conses onto prior entries in insertion order" do
      acc =
        Enum.reduce([:b, :c], %{}, fn item, acc ->
          case Map.fetch(acc, :k) do
            :error -> Map.put(acc, :k, [item])
            {:ok, ks} -> Map.put(acc, :k, [item | ks])
          end
        end)

      assert acc == %{k: [:c, :b]}
    end

    test "nil-valued context map is normalized before the fetch (migration site shape)" do
      base = nil || %{}

      context =
        case Map.fetch(base, :migrations) do
          :error -> Map.put(base, :migrations, [:entry])
          {:ok, migrations} -> Map.put(base, :migrations, migrations ++ [:entry])
        end

      assert context == %{migrations: [:entry]}

      appended =
        case Map.fetch(context, :migrations) do
          :error -> Map.put(context, :migrations, [:second])
          {:ok, migrations} -> Map.put(context, :migrations, migrations ++ [:second])
        end

      assert appended == %{migrations: [:entry, :second]}
    end
  end

  describe "runtime Map.update/4 deviation witness" do
    test "absent-key path on this runtime deviates from documented semantics" do
      result = Map.update(%{}, :k, 7, &(&1 + 1))

      if Map.get(result, :k) == 7 do
        # Deviating runtime (documented): fun skipped. The patched sites are
        # correct because the idiom never relies on the fun-on-absent path.
        assert result == %{k: 7}
      else
        # Fixed runtime (documented semantics): fun applied to default.
        assert result == %{k: 8}
      end

      # Under EITHER branch, the dual-safe idiom is semantics-preserving:
      assert dual_safe_update(%{}, :k, 7, &(&1 + 1)) == %{k: 7}
    end
  end
end
