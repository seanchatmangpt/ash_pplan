defmodule AshPPlan.Courts.PackAshExtCourtTest do
  @moduledoc """
  Consumer court for the vendored `ash-extension-core-pack`
  (`priv/ggen/vendor/ash-extension-core-pack/`): proves the pack's generated
  output works, with the existing adoption as the golden evidence.

  Executed courts (real ggen_igniter sync runs, MIX_BUILD_ROOT=_build-g1):

    1. RENDER + BYTE-IDENTITY — the adapter template
       (`templates/ash_reactor_extended_adapter.ex.eex`) rendered into a
       run-unique scratch must byte-match the committed
       `lib/ash_pplan/reactor/adapters/ash_reactor_extended.ex` modulo
       `mix format`. That committed adapter is the pack's existing adoption
       proof: the render regenerates it exactly.
    2. PARSE + DETERMINISM — the render parses as Elixir; a second render is
       byte-identical.
    3. GATES — all 5 contract gates run read-only via the native oxigraph
       engine against the shipped ontology; each is offender-reporting
       (rows = violations), and the shipped graph is clean (0 rows each).
    4. ANTI-VACUITY — a corrupt copy of the ontology (the closed
       `aex:extensionTarget` enum broken to `"bogus_target"`) flips gate 010
       from 0 rows to firing: a gate that cannot see corruption is vacuous.

  Select-only court: no DO authority.
  """

  use ExUnit.Case, async: false

  @repo Path.expand("../..", __DIR__)
  @pack "priv/ggen/vendor/ash-extension-core-pack"
  @adapter_template "templates/ash_reactor_extended_adapter.ex.eex"
  @committed_adapter "lib/ash_pplan/reactor/adapters/ash_reactor_extended.ex"

  @gates [
    "gates/010_required_extension_contract.rq",
    "gates/020_schema_field_contract.rq",
    "gates/030_entity_identifier_contract.rq",
    "gates/040_codegen_callback_contract.rq",
    "gates/050_projection_isolation_contract.rq"
  ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp scratch(name) do
    dir = Path.join(@repo, "tmp/court-g1-ashext-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp sync(pack_dir, template_rel, out_path) do
    args = [
      "ggen_igniter.sync",
      "--pack-dir",
      pack_dir,
      "--template",
      template_rel,
      "--out",
      out_path
    ]

    case System.cmd("mix", args, cd: @repo, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> flunk("mix #{Enum.join(args, " ")} exited #{code}:\n#{out}")
    end
  end

  defp render_adapter(dir, pack_dir \\ nil) do
    pack = pack_dir || Path.join(@repo, @pack)
    out = Path.join(dir, "ash_reactor_extended.ex")
    sync(pack, Path.join(pack, @adapter_template), out)
    out
  end

  defp format_in_place!(path) do
    case System.cmd("mix", ["format", path], cd: @repo, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> flunk("mix format #{path} exited #{code}:\n#{out}")
    end
  end

  defp ontology_graph(pack_dir) do
    RDF.Turtle.read_file!(Path.join(pack_dir, "ontology.ttl"))
  end

  defp gate_rows(graph, gate_path) do
    {:ok, length(GgenIgniter.Query.Oxigraph.run(graph, File.read!(gate_path)))}
  end

  # ---------------------------------------------------------------------------
  # Court 1: render + byte-identity with the committed adoption
  # ---------------------------------------------------------------------------

  test "render: adapter byte-matches the committed adoption modulo mix format" do
    dir = scratch("render")
    out = render_adapter(dir)

    content = File.read!(out)
    assert content != "" and String.trim(content) != ""

    assert {:ok, _ast} = Code.string_to_quoted(content),
           "rendered adapter does not parse as Elixir"

    committed_path = Path.join(@repo, @committed_adapter)
    raw_equal = content == File.read!(committed_path)

    unless raw_equal do
      format_in_place!(out)

      assert File.read!(out) == File.read!(committed_path),
             "rendered adapter does not match committed #{@committed_adapter} " <>
               "even after mix format — adoption identity broken"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 2: determinism
  # ---------------------------------------------------------------------------

  test "determinism: two independent renders are byte-identical" do
    a = File.read!(render_adapter(scratch("render-a")))
    b = File.read!(render_adapter(scratch("render-b")))
    assert a == b, "two renders of the adapter diverged"
  end

  # ---------------------------------------------------------------------------
  # Court 3: gates (read-only, row counts recorded)
  # ---------------------------------------------------------------------------

  test "gates: all 5 contract gates report 0 violation rows via oxigraph" do
    graph = ontology_graph(Path.join(@repo, @pack))

    counts =
      for gate <- @gates, into: %{} do
        assert {:ok, rows} = gate_rows(graph, Path.join([@repo, @pack, gate]))
        {gate, rows}
      end

    # Offender-reporting contracts: shipped graph is clean.
    for {gate, rows} <- counts do
      assert rows == 0, "gate #{gate} fired #{rows} violation row(s) on the shipped graph"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 4: anti-vacuity mutation (tmp ontology copy only)
  # ---------------------------------------------------------------------------

  test "anti-vacuity: breaking the extensionTarget enum in a tmp copy flips gate 010" do
    corrupt = scratch("mutation")
    corrupt_pack = Path.join(corrupt, "pack")
    File.cp_r!(Path.join(@repo, @pack), corrupt_pack)

    ontology_path = Path.join(corrupt_pack, "ontology.ttl")
    ttl = File.read!(ontology_path)
    needle = ~s(aex:extensionTarget "resource" ;)

    assert ttl =~ needle, "corruption target triple not found in pack ontology"

    corrupted = String.replace(ttl, needle, ~s(aex:extensionTarget "bogus_target" ;), count: 1)
    assert corrupted != ttl, "corruption changed nothing"
    File.write!(ontology_path, corrupted)

    graph = ontology_graph(corrupt_pack)
    gate = Path.join(corrupt_pack, "gates/010_required_extension_contract.rq")

    assert {:ok, rows} = gate_rows(graph, gate)
    assert rows >= 1, "gate 010 did not fire on the enum corruption (vacuous)"
  end
end
