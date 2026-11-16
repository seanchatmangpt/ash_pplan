defmodule AshPPlan.MirrorSim.MutantsCoreTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.MutantsCore

  @root File.cwd!()

  defp count(haystack, needle) do
    haystack |> :binary.matches(needle) |> length()
  end

  test "catalog has at least 40 mutants with unique ids and the engine spec shape" do
    catalog = MutantsCore.catalog()
    assert length(catalog) >= 40
    ids = Enum.map(catalog, & &1.id)
    assert ids == Enum.uniq(ids)

    for m <- catalog do
      for key <- [:id, :file, :anchor, :replacement, :court, :expected_kill] do
        assert Map.has_key?(m, key), "#{m.id} missing #{key}"
      end

      assert m.expected_kill in [:killed, :probable]
      assert m.anchor != m.replacement, "#{m.id} is an identity mutation"
    end
  end

  test "every anchor occurs exactly once in its on-disk source file" do
    for m <- MutantsCore.catalog() do
      source = File.read!(Path.join(@root, m.file))
      n = count(source, m.anchor)
      assert n == 1, "#{m.id}: anchor occurs #{n} times in #{m.file} (need exactly 1)"
    end
  end

  test "every killing court file exists on disk" do
    for m <- MutantsCore.catalog() do
      assert File.regular?(Path.join(@root, m.court)), "#{m.id}: missing court #{m.court}"
    end
  end

  test "every mutated file is under lib/ and exists" do
    for file <- MutantsCore.files() do
      assert String.starts_with?(file, "lib/ash_pplan/")
      assert File.regular?(Path.join(@root, file))
    end
  end

  test "every mutant changes the source it targets (replacement is not already present at anchor)" do
    for m <- MutantsCore.catalog() do
      source = File.read!(Path.join(@root, m.file))
      mutated = String.replace(source, m.anchor, m.replacement, global: false)
      assert mutated != source, "#{m.id}: mutation left source byte-identical"
    end
  end
end
