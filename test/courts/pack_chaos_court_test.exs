defmodule AshPPlan.Courts.PackChaosCourtTest do
  @moduledoc """
  Consumer court for the vendored `ash-pplan-chaos-pack`
  (`priv/ggen/vendor/ash-pplan-chaos-pack/`): proves the pack's generated
  output actually works, not just that its gates parse.

  Executed courts (real ggen_igniter sync runs, MIX_BUILD_ROOT=_build-g1):

    1. RENDER — both templates (`invariant_property.exs.eex`, for_each over
       acp:Invariant rows; `kill_phase.exs.eex`, for_each over acp:KillPhase
       rows) render via a real `mix ggen_igniter.sync` into a run-unique
       scratch under `tmp/`: 6 invariant suites + 4 kill suites, every file
       non-empty and a parseable Elixir AST.
    2. DETERMINISM — a second full render into a second scratch is
       byte-identical (same file set, same bytes).
    3. GATES — all 3 gates run read-only via the native oxigraph engine
       (`GgenIgniter.Query.Oxigraph.run/2`) against the shipped ontology;
       exact row counts recorded and asserted (positive-firing gates:
       1 / 6 / 4 rows).
    4. ANTI-VACUITY — a corrupt copy of the pack (one acp:Invariant
       individual stripped of its class membership) provably changes the
       outputs: gate 020 drops to 5 rows and the re-render produces a
       different file set. A court that admits its own corruption is
       vacuous.

  The rendered suites' EXECUTION stays consumer-side (they alias the
  consumer's Generators/Harness/Invariants/Sabotage modules, which only a
  consumer has) — this court proves rendering + gate firing, not suite
  execution. Select-only court: no DO authority.
  """

  use ExUnit.Case, async: false

  @repo Path.expand("../..", __DIR__)
  @pack "priv/ggen/vendor/ash-pplan-chaos-pack"
  @invariant_template "templates/invariant_property.exs.eex"
  @kill_template "templates/kill_phase.exs.eex"

  @gates [
    {"gates/010_harness.rq", 1},
    {"gates/020_invariants.rq", 6},
    {"gates/030_kill_phases.rq", 4}
  ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp scratch(name) do
    dir = Path.join(@repo, "tmp/court-g1-chaos-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp sync(pack_dir, template_rel, out_template) do
    args = [
      "ggen_igniter.sync",
      "--pack-dir",
      pack_dir,
      "--template",
      template_rel,
      "--out",
      out_template
    ]

    case System.cmd("mix", args, cd: @repo, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> flunk("mix #{Enum.join(args, " ")} exited #{code}:\n#{out}")
    end
  end

  defp render_dir(name, pack_dir \\ nil) do
    dir = scratch(name)
    pack = pack_dir || Path.join(@repo, @pack)

    sync(
      pack,
      Path.join(pack, @invariant_template),
      Path.join(dir, "<%= invariantId %>_property_test.exs")
    )

    sync(pack, Path.join(pack, @kill_template), Path.join(dir, "kill_<%= phaseId %>_test.exs"))
    dir
  end

  defp rendered_files(dir), do: Path.wildcard(Path.join(dir, "**/*.exs")) |> Enum.sort()

  defp snapshot(dir) do
    Map.new(rendered_files(dir), fn path ->
      {Path.relative_to(path, dir), File.read!(path)}
    end)
  end

  defp parse_check!(path) do
    case Code.string_to_quoted(File.read!(path)) do
      {:ok, ast} ->
        ast

      {:error, reason} ->
        flunk("rendered file does not parse as Elixir: #{path}\n#{inspect(reason)}")
    end
  end

  defp ontology_graph(pack_dir) do
    RDF.Turtle.read_file!(Path.join(pack_dir, "ontology.ttl"))
  end

  defp gate_rows(graph, gate_rel, pack_dir \\ nil) do
    path =
      if pack_dir, do: Path.join(pack_dir, gate_rel), else: Path.join([@repo, @pack, gate_rel])

    query = File.read!(path)

    {:ok, length(GgenIgniter.Query.Oxigraph.run(graph, query))}
  end

  # ---------------------------------------------------------------------------
  # Court 1: render
  # ---------------------------------------------------------------------------

  # Each render leg spawns real `mix ggen_igniter.sync` subprocesses (one per
  # template per scratch); under a loaded lane-fanned machine the default 60s
  # ExUnit timeout trips mid-render. Same 600s ceiling the protocol court
  # (pack_protocol_court_test.exs) already carries for identical legs.
  @tag timeout: 600_000
  test "render: 6 invariant suites + 4 kill suites, non-empty, parseable Elixir" do
    dir = render_dir("render")
    files = rendered_files(dir)

    assert length(files) == 10,
           "expected 6 invariant + 4 kill suites, got #{length(files)}: #{inspect(files)}"

    assert length(Path.wildcard(Path.join(dir, "*_property_test.exs"))) == 6
    assert length(Path.wildcard(Path.join(dir, "kill_*_test.exs"))) == 4

    for file <- files do
      content = File.read!(file)
      assert content != "" and String.trim(content) != "", "empty render: #{file}"
      assert content =~ "# GENERATED by ggen_igniter", "missing provenance header: #{file}"
      parse_check!(file)
    end
  end

  # ---------------------------------------------------------------------------
  # Court 2: determinism
  # ---------------------------------------------------------------------------

  @tag timeout: 600_000
  test "determinism: two independent full renders are byte-identical" do
    a = snapshot(render_dir("render-a"))
    b = snapshot(render_dir("render-b"))

    assert map_size(a) == 10
    assert a == b, "two renders of the same pack diverged — generation is not deterministic"
  end

  # ---------------------------------------------------------------------------
  # Court 3: gates (read-only, row counts recorded)
  # ---------------------------------------------------------------------------

  test "gates: all 3 fire non-empty row counts via oxigraph" do
    graph = ontology_graph(Path.join(@repo, @pack))

    for {gate, expected} <- @gates do
      assert {:ok, rows} = gate_rows(graph, gate)
      assert rows == expected, "gate #{gate}: expected #{expected} rows, got #{rows}"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 4: anti-vacuity mutation (tmp pack copy only)
  # ---------------------------------------------------------------------------

  @tag timeout: 600_000
  test "anti-vacuity: corrupting one Invariant in a tmp pack copy changes gate + render output" do
    # Fresh full render as the baseline snapshot.
    baseline = snapshot(render_dir("mutation-baseline"))

    # Corrupt a tmp copy: strip one invariant individual's class membership.
    corrupt = scratch("mutation-corrupt-pack")
    corrupt_pack = Path.join(corrupt, "pack")
    File.cp_r!(Path.join(@repo, @pack), corrupt_pack)

    ontology_path = Path.join(corrupt_pack, "ontology.ttl")
    ttl = File.read!(ontology_path)
    needle = "acp:at_most_once a acp:Invariant ;"

    assert ttl =~ needle, "corruption target triple not found in pack ontology"

    corrupted = String.replace(ttl, needle, "acp:at_most_once a acp:NotAnInvariant ;", count: 1)
    assert corrupted != ttl, "corruption changed nothing"
    File.write!(ontology_path, corrupted)

    # (a) GATE SENSITIVITY: 020_invariants drops 6 -> 5 on the corrupted graph.
    graph = ontology_graph(corrupt_pack)

    assert {:ok, 5} = gate_rows(graph, "gates/020_invariants.rq", corrupt_pack),
           "gate 020_invariants did not see the corruption (vacuous)"

    # (b) RENDER SENSITIVITY: re-render from the corrupted pack copy; the
    # invariant file set must lose at_most_once and never gain the killed row.
    sync(
      corrupt_pack,
      Path.join(corrupt_pack, @invariant_template),
      Path.join(corrupt, "<%= invariantId %>_property_test.exs")
    )

    mutated_files = Path.wildcard(Path.join(corrupt, "*_property_test.exs")) |> Enum.sort()

    baseline_files =
      baseline |> Map.keys() |> Enum.filter(&String.ends_with?(&1, "_property_test.exs"))

    refute "at_most_once_property_test.exs" in Enum.map(mutated_files, &Path.basename/1),
           "corrupted render still produced the stripped invariant's suite (render is vacuous)"

    assert length(mutated_files) == length(baseline_files) - 1
  end
end
