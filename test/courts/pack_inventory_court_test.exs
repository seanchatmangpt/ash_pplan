defmodule AshPPlan.Courts.PackInventoryCourtTest do
  @moduledoc """
  Pack-inventory court: closes the ggen.toml <-> disk drift channel.

  Every directory under priv/ggen/ (and its vendor/ subtree) that carries a
  pack marker (pack.toml or ontology.ttl) must be either:

  1. declared as a `[packs.*]` entry in ggen.toml whose `path` exists on disk, or
  2. listed in `ggen.exemptions.toml` (sidecar) with a one-line reason (e.g.
     vendor-synced packs consumed via priv/ggen/vendor/sync.sh, never a
     manufacture surface). The sidecar exists because ggen's PackRef enum
     (Path | Git) cannot parse a string-valued [packs.exemptions] table —
     it failed with [FM-CONFIG-002] and blocked every root-level ggen command.

  Anti-vacuity: the predicate functions are tested on synthetic inventories,
  and a real temporary fake-pack directory (mutation + restore) must flip the
  court red.

  Born from ERR-C item 9: reactor-mw-pack and ash-pplan-runtime-overlay sat on
  disk with no ggen.toml entry and nothing failed.
  """

  use ExUnit.Case, async: true

  @ggen_toml "ggen.toml"
  @exemptions_toml "ggen.exemptions.toml"
  @pack_root "priv/ggen"

  # ---------------------------------------------------------------------------
  # Pure predicates (anti-vacuity targets)
  # ---------------------------------------------------------------------------

  @doc "True if the dir carries a pack marker: pack.toml or ontology.ttl."
  def pack_marker?(dir) do
    File.exists?(Path.join(dir, "pack.toml")) or File.exists?(Path.join(dir, "ontology.ttl"))
  end

  @doc """
  Untracked pack dirs: on-disk markers minus declared paths minus exempted
  basenames.
  """
  def untracked(disk, declared_paths, exempted_basenames) do
    disk
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(declared_paths))
    |> MapSet.reject(fn path -> Path.basename(path) in exempted_basenames end)
  end

  @doc "Dead entries: declared [packs.*] paths with no on-disk marker."
  def dead_entries(declared_paths, disk) do
    MapSet.difference(MapSet.new(declared_paths), MapSet.new(disk))
  end

  # ---------------------------------------------------------------------------
  # Real inventory
  # ---------------------------------------------------------------------------

  defp read_toml, do: Toml.decode!(File.read!(@ggen_toml))

  defp packs_section do
    packs_map = Map.get(read_toml(), "packs", %{})

    exemptions =
      case File.exists?(@exemptions_toml) do
        true -> Toml.decode!(File.read!(@exemptions_toml))
        false -> %{}
      end

    {packs_map, exemptions}
  end

  defp on_disk_packs(root \\ @pack_root) do
    roots = [root, Path.join(root, "vendor")]

    roots
    |> Enum.flat_map(fn dir ->
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)

        {:error, _} ->
          []
      end
    end)
    |> Enum.filter(&pack_marker?/1)
    |> Enum.sort()
  end

  # -- the court --------------------------------------------------------------

  test "every on-disk pack dir has a ggen.toml entry or an explicit exemption" do
    {packs, exemptions} = packs_section()

    declared_paths = Enum.map(packs, fn {_name, p} -> Map.fetch!(p, "path") end)
    exempted = Map.keys(exemptions)

    disk = on_disk_packs()
    assert disk != [], "sanity: priv/ggen must contain at least one pack"

    untracked = untracked(disk, declared_paths, exempted)

    assert untracked == MapSet.new(),
           """
           Untracked pack dirs (on disk, no [packs.*] entry, no ggen.exemptions.toml reason):
             #{untracked |> Enum.sort() |> Enum.join("\n  ")}
           Add a [packs.<name>] entry (path = ...) or a ggen.exemptions.toml line with a reason.
           """
  end

  test "every ggen.toml [packs.*] entry points at an existing pack dir" do
    {packs, _exemptions} = packs_section()
    disk = on_disk_packs()

    refute packs == %{}, "sanity: ggen.toml must declare packs"

    dead = dead_entries(Enum.map(packs, fn {_n, p} -> Map.fetch!(p, "path") end), disk)

    assert dead == MapSet.new(),
           "Dead [packs.*] entries (path missing on disk or carries no pack.toml/ontology.ttl): #{inspect(Enum.sort(dead))}"
  end

  test "every exemption names a real on-disk pack dir and carries a non-empty reason" do
    {_packs, exemptions} = packs_section()
    disk_basenames = on_disk_packs() |> Enum.map(&Path.basename/1) |> MapSet.new()

    assert map_size(exemptions) > 0, "sanity: exemptions list must not be empty"

    for {name, reason} <- exemptions do
      assert name in disk_basenames,
             "Exemption #{inspect(name)} names no on-disk pack dir"

      assert is_binary(reason) and String.trim(reason) != "",
             "Exemption #{inspect(name)} has no one-line reason"
    end
  end

  # -- anti-vacuity: mutation + restore ---------------------------------------
  # The mutation runs against a tmp root (same shape as priv/ggen) so the fake
  # pack never leaks into the concurrent async tests scanning the real tree.

  describe "anti-vacuity" do
    test "a fake pack dir flips the court red, and restores green" do
      fake_root = Path.join(System.tmp_dir!(), "packinv-court-#{System.unique_integer()}")
      File.mkdir_p!(Path.join(fake_root, "vendor"))

      File.mkdir_p!(Path.join(fake_root, "ash-pplan-pack"))
      File.write!(Path.join([fake_root, "ash-pplan-pack", "ontology.ttl"]), "# probe\n")

      assert on_disk_packs(fake_root) == [Path.join(fake_root, "ash-pplan-pack")]

      # no entries, no exemptions -> red
      assert untracked(on_disk_packs(fake_root), [], []) != MapSet.new()

      # fake pack appears -> red
      fake = Path.join(fake_root, "court-antivacuity-fake-pack")
      File.mkdir_p!(fake)
      File.write!(Path.join(fake, "pack.toml"), "[pack]\nname = \"probe\"\n")

      assert pack_marker?(fake)
      assert Path.join(fake_root, "court-antivacuity-fake-pack") in on_disk_packs(fake_root)

      assert untracked(on_disk_packs(fake_root), [Path.join(fake_root, "ash-pplan-pack")], []) !=
               MapSet.new()

      # exemption suppresses -> green again
      assert untracked(on_disk_packs(fake_root), [Path.join(fake_root, "ash-pplan-pack")], [
               "court-antivacuity-fake-pack"
             ]) == MapSet.new()

      # restore
      File.rm_rf!(fake_root)
      refute File.exists?(fake_root)
      assert on_disk_packs(@pack_root) != []
    end

    test "dropping a declared entry flips the court red (simulated on the parsed map)" do
      {packs, exemptions} = packs_section()
      disk = on_disk_packs()
      exempted = Map.keys(exemptions)

      assert match?([{name, _} | _] when is_binary(name), Enum.sort(packs))
      [{dropped_name, dropped} | _rest] = Enum.sort(packs)

      reduced =
        Enum.sort(packs)
        |> tl()
        |> Map.new(fn {n, p} -> {n, p} end)

      reduced_declared = Enum.map(reduced, fn {_n, p} -> Map.fetch!(p, "path") end)

      assert untracked(disk, reduced_declared, exempted) != MapSet.new(),
             "dropping #{inspect(dropped["path"])} (#{dropped_name}) from the entry set must surface it as untracked"

      # sanity: the full entry set stays green (symmetric check)
      full_declared = Enum.map(packs, fn {_n, p} -> Map.fetch!(p, "path") end)
      assert untracked(disk, full_declared, exempted) == MapSet.new()
    end

    test "predicates behave on synthetic inventories" do
      inv = ["priv/ggen/a", "priv/ggen/b"]

      assert untracked(inv, ["priv/ggen/a"], []) == MapSet.new(["priv/ggen/b"])
      assert untracked(inv, ["priv/ggen/a"], ["b"]) == MapSet.new()

      assert dead_entries(["priv/ggen/a", "priv/ggen/gone"], inv) ==
               MapSet.new(["priv/ggen/gone"])

      refute pack_marker?("/tmp")
    end
  end
end
