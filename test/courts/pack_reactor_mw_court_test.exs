defmodule AshPPlan.Courts.PackReactorMwCourtTest do
  @moduledoc """
  Consumer court for `priv/ggen/ash-pplan-reactor-mw-pack` (Reactor middleware
  telemetry pack, v26.10.3).

  Executed courts (real ggen_igniter sync runs):

    1. RENDER — the pack's one code template
       (`templates/telemetry_middleware.ex.eex`, for_each over
       aexmw:TelemetryMiddlewareSpec rows) renders via a real
       `mix ggen_igniter.sync` into a run-unique scratch dir under `tmp/`:
       1 module (`ash_pplan_reactor_middleware.ex` =
       AshPPlan.Reactor.Middleware.Telemetry), non-empty, with the GENERATED
       provenance header, parsing as Elixir.
    2. DETERMINISM — a second full render into a second scratch is
       byte-identical (same file set, same bytes).
    3. GATES — the pack's 1 gate (`gates/010_middleware.rq`, the middleware
       spec completeness gate) runs read-only via the native oxigraph engine
       (`GgenIgniter.Query.Oxigraph.run/2`) against the shipped ontology;
       exact row count recorded and asserted (positive-firing gate: 1 row).
    4. ANTI-VACUITY — a corrupt copy of the pack (the single
       aexmw:TelemetryMiddleware individual stripped of its
       aexmw:TelemetryMiddlewareSpec class membership) provably changes the
       outputs: gate 010 drops 1 -> 0 rows and the re-render is a typed
       refusal (the template's query binds nothing). A court that admits its
       own corruption is vacuous.

  The rendered middleware module's EXECUTION stays consumer-side (it is
  compiled and wired via AshPPlan.Reactor.add_middleware/2); this court
  proves rendering + gate firing, not middleware execution. Select-only
  court: no DO authority.
  """

  use ExUnit.Case, async: false

  @repo Path.expand("../..", __DIR__)
  @pack "priv/ggen/ash-pplan-reactor-mw-pack"
  @template "templates/telemetry_middleware.ex.eex"

  @gates [
    {"gates/010_middleware.rq", 1}
  ]

  @out_template "<%= event_root %>_<%= segment %>_middleware.ex"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp scratch(name) do
    dir =
      Path.join(@repo, "tmp/court-reactor-mw-#{name}-#{System.unique_integer([:positive])}")

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

    sync(pack, Path.join(pack, @template), Path.join(dir, @out_template))
    dir
  end

  defp rendered_files(dir), do: Path.wildcard(Path.join(dir, "**/*.ex")) |> Enum.sort()

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
    length(GgenIgniter.Query.Oxigraph.run(graph, query))
  end

  # ---------------------------------------------------------------------------
  # Court 1: render
  # ---------------------------------------------------------------------------

  test "render: 1 telemetry middleware module, non-empty, parseable Elixir" do
    dir = render_dir("render")
    files = rendered_files(dir)

    assert length(files) == 1,
           "expected 1 middleware module, got #{length(files)}: #{inspect(files)}"

    assert Path.basename(hd(files)) == "ash_pplan_reactor_middleware.ex"

    for file <- files do
      content = File.read!(file)
      assert content != "" and String.trim(content) != "", "empty render: #{file}"
      assert content =~ "GENERATED from", "missing provenance header: #{file}"
      parse_check!(file)
    end
  end

  # ---------------------------------------------------------------------------
  # Court 2: determinism
  # ---------------------------------------------------------------------------

  test "determinism: two independent full renders are byte-identical" do
    a = snapshot(render_dir("render-a"))
    b = snapshot(render_dir("render-b"))

    assert map_size(a) == 1
    assert a == b, "two renders of the same pack diverged — generation is not deterministic"
  end

  # ---------------------------------------------------------------------------
  # Court 3: gates (read-only, row counts recorded)
  # ---------------------------------------------------------------------------

  test "gates: the middleware spec completeness gate fires 1 row via oxigraph" do
    graph = ontology_graph(Path.join(@repo, @pack))

    for {gate, expected} <- @gates do
      rows = gate_rows(graph, gate)
      assert rows == expected, "gate #{gate}: expected #{expected} rows, got #{rows}"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 4: anti-vacuity mutation (tmp pack copy only)
  # ---------------------------------------------------------------------------

  test "anti-vacuity: corrupting the TelemetryMiddleware spec in a tmp pack copy changes gate + render output" do
    baseline = snapshot(render_dir("mutation-baseline"))

    # Corrupt a tmp copy: strip the individual's spec class membership.
    corrupt = scratch("mutation-corrupt-pack")
    corrupt_pack = Path.join(corrupt, "pack")
    File.cp_r!(Path.join(@repo, @pack), corrupt_pack)

    ontology_path = Path.join(corrupt_pack, "ontology.ttl")
    ttl = File.read!(ontology_path)
    needle = "aexmw:TelemetryMiddleware a aexmw:TelemetryMiddlewareSpec ;"

    assert ttl =~ needle, "corruption target triple not found in pack ontology"

    corrupted =
      String.replace(ttl, needle, "aexmw:TelemetryMiddleware a aexmw:NotASpec ;", count: 1)

    assert corrupted != ttl, "corruption changed nothing"
    File.write!(ontology_path, corrupted)

    # (a) GATE SENSITIVITY: 010_middleware drops 1 -> 0 on the corrupted graph.
    graph = ontology_graph(corrupt_pack)

    assert 0 = gate_rows(graph, "gates/010_middleware.rq", corrupt_pack),
           "gate 010_middleware did not see the corruption (vacuous)"

    # (b) RENDER SENSITIVITY: with the spec row gone, the template's `mw`
    # query binds nothing and ggen_igniter.sync REFUSES (undefined template
    # variables) instead of emitting a module — a typed refusal, not silence.
    refuse_args = [
      "ggen_igniter.sync",
      "--pack-dir",
      corrupt_pack,
      "--template",
      Path.join(corrupt_pack, @template),
      "--out",
      Path.join(corrupt, @out_template)
    ]

    {refuse_out, refuse_code} =
      System.cmd("mix", refuse_args, cd: @repo, stderr_to_stdout: true)

    assert refuse_code != 0,
           "corrupted render still succeeded (render is vacuous):\n#{refuse_out}"

    assert map_size(baseline) == 1
  end
end
