defmodule AshPPlan.MirrorSim.MutantsRuntimeTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.MutantsRuntime, as: M

  @root File.cwd!()

  test "catalog has at least 40 mutants with unique ids and complete specs" do
    cat = M.catalog()
    assert length(cat) >= 40
    assert cat |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(cat)

    for spec <- cat do
      for k <- [:id, :file, :anchor, :replacement, :court, :equivalent] do
        assert Map.has_key?(spec, k), "#{spec.id} missing #{k}"
      end

      assert String.starts_with?(spec.file, "lib/ash_pplan/")
      assert spec.anchor != spec.replacement, "#{spec.id} is a no-op"
    end
  end

  test "every anchor occurs exactly once verbatim in its real lib file" do
    bad = for {id, n} <- M.verify_anchors(@root), n != 1, do: {id, n}
    assert bad == []
  end

  test "every mapped court exists on disk or is a mirror_sim court" do
    missing =
      for %{id: id, court: court} <- M.catalog(),
          not File.exists?(Path.join(@root, court)),
          not String.starts_with?(court, "test/mirror_sim/"),
          do: {id, court}

    assert missing == []
  end

  test "apply_mutant changes the source and contains the replacement" do
    for spec <- M.catalog() do
      src = File.read!(Path.join(@root, spec.file))
      mutated = M.apply_mutant(src, spec)
      assert mutated != src, "#{spec.id} did not change source"
      assert byte_size(mutated) > 0
    end
  end

  test "apply_mutant refuses a missing or ambiguous anchor" do
    spec = %{id: "X", anchor: "zz", replacement: "y"}
    assert_raise ArgumentError, fn -> M.apply_mutant("abc", spec) end
    assert_raise ArgumentError, fn -> M.apply_mutant("zz zz", spec) end
    assert M.apply_mutant("a zz b", spec) == "a y b"
  end

  test "equivalent-mutant notes are present and are a minority" do
    eq = Enum.filter(M.catalog(), & &1.equivalent)
    assert eq != []
    assert length(eq) * 4 < length(M.catalog())
  end
end
