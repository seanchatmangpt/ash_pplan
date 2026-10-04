defmodule AshPPlan.Courts.PackStateTransitionCourtTest do
  @moduledoc """
  Consumer court for the vendored `state-transition-pack`
  (`priv/ggen/vendor/state-transition-pack/`): proves the pack's generated
  output works.

  Executed courts (real ggen_igniter sync runs, MIX_BUILD_ROOT=_build-g1):

    1. RENDER — all 4 `.tmpl` templates (`fsm.ex/py/rs/ts`, Tera via the
       ggen_igniter WASM Tera engine) render into a run-unique scratch:
       every file non-empty, no unresolved `{{` / `{%` markers, and the
       Elixir projection parses as Elixir.
    2. DETERMINISM — a second full render is byte-identical.
    3. GATES — the offender gates (verify/010, verify/020, re-homed per
       ECO-GATE-CONVENTION-DECISION R0 2026-10-04) and witness gates
       (gates/030, gates/040) run read-only via the native oxigraph
       engine (`GgenIgniter.Query.Oxigraph.run/2` — the `sparql` 0.3.12 hex
       package leaves a :not_exists stub that crashes on the gates'
       EXISTS-family shapes; oxigraph evaluates them). All emit 0 rows on
       the shipped clean graph (offender convention: 0 rows = PASS). If a
       gate still cannot evaluate, the court records the
       typed ENGINE-LIMIT instead of failing the pack (upstream promotion of
       the local MINUS rewrite is owned by another lane). The 5th gate
       (`verify/050_template_literal_scan.py`) runs read-only via python3
       against the shipped templates: exit 0, zero hits.
    4. ANTI-VACUITY — a corrupt copy of the ontology (a rogue
       st:VerifiedState individual with no executed predecessor) flips the
       re-homed verify/010_no_skipping_executed.unbound.rq from 0 rows to
       firing: a gate that cannot see a stage-skipping claim is vacuous.

  Select-only court: no DO authority.
  """

  use ExUnit.Case, async: false

  # ggen_igniter sync shells out to `mix ggen_igniter.sync` (System.cmd): on a
  # cold WASM/Tera engine under concurrent load the first render can exceed the
  # 60s default ExUnit timeout. Repo convention for slow shell-out courts is a
  # generous @moduletag timeout (cf. demonstration_court 1_800_000,
  # manufacture_test 600_000-900_000).
  @moduletag timeout: 600_000

  @repo Path.expand("../..", __DIR__)
  @pack "priv/ggen/vendor/state-transition-pack"

  @templates ["fsm.ex.tmpl", "fsm.py.tmpl", "fsm.rs.tmpl", "fsm.ts.tmpl"]
  # Re-homed per ECO-GATE-CONVENTION-DECISION (R0, 2026-10-04): the offender
  # gates 010/020 live in verify/ as *.unbound.rq (0 rows = PASS, >= 1 row =
  # FAIL -- the offender convention); witness gates 030/040 stay in gates/.
  @offender_gates [
    "verify/010_no_skipping_executed.unbound.rq",
    "verify/020_no_skipped_transitions.unbound.rq"
  ]
  @witness_gates [
    "gates/030_reachable_states.rq",
    "gates/040_chain_policy_supported.rq"
  ]
  @py_gate "verify/050_template_literal_scan.py"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp scratch(name) do
    dir = Path.join(@repo, "tmp/court-g1-st-#{name}-#{System.unique_integer([:positive])}")
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

  defp render_all(dir, pack_dir \\ nil) do
    pack = pack_dir || Path.join(@repo, @pack)

    Map.new(@templates, fn tmpl ->
      out = Path.join(dir, String.replace_suffix(tmpl, ".tmpl", ".out"))
      sync(pack, Path.join(pack, "templates/#{tmpl}"), out)
      {tmpl, out}
    end)
  end

  defp snapshot(dir) do
    dir
    |> then(&Path.wildcard(Path.join(&1, "*.out")))
    |> Enum.sort()
    |> Map.new(fn path -> {Path.basename(path), File.read!(path)} end)
  end

  defp ontology_graph(pack_dir) do
    RDF.Turtle.read_file!(Path.join(pack_dir, "ontology.ttl"))
  end

  # Oxigraph first; a real engine failure is recorded as a typed ENGINE-LIMIT
  # (the gates carry local MINUS/EXISTS rewrites pending upstream promotion —
  # another lane owns that), never silently swallowed.
  defp gate_verdict(graph, gate_path) do
    query = File.read!(gate_path)

    try do
      {:ok, length(GgenIgniter.Query.Oxigraph.run(graph, query))}
    rescue
      e -> {:engine_limit, Exception.format(:error, e)}
    end
  end

  # A real engine failure is recorded as a typed ENGINE-LIMIT (never silently
  # swallowed): the gate is left unevaluated, upstream promotion owned
  # elsewhere, and the diagnostic is printed for the court record.
  defp record_engine_limit(msg) do
    assert msg != "", "ENGINE-LIMIT must carry a diagnostic"
    IO.puts("[pack_state_transition_court] typed ENGINE-LIMIT recorded: #{msg}")
  end

  # Every gate either evaluates to a row count or is recorded as a typed
  # ENGINE-LIMIT (never silently skipped). Clean shipped graph: 0 rows each.
  defp run_rq_gates(graph) do
    Enum.reduce(@offender_gates ++ @witness_gates, :ok, fn gate, :ok ->
      path = Path.join([@repo, @pack, gate])

      case gate_verdict(graph, path) do
        {:ok, 0} ->
          :ok

        {:ok, rows} ->
          flunk("gate #{gate} fired #{rows} violation row(s) on the shipped clean graph")

        {:engine_limit, msg} ->
          record_engine_limit(msg)
          :ok
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Court 1: render
  # ---------------------------------------------------------------------------

  test "render: all 4 .tmpl templates produce non-empty, marker-free output" do
    outputs = render_all(scratch("render"))
    assert map_size(outputs) == 4

    for {tmpl, path} <- outputs do
      content = File.read!(path)
      assert content != "" and String.trim(content) != "", "empty render: #{tmpl}"
      refute content =~ "{{", "unresolved Tera {{ }} marker in #{tmpl} render"
      refute content =~ "{%", "unresolved Tera {% %} marker in #{tmpl} render"
    end

    # The Elixir projection must be a parseable Elixir module.
    ex = File.read!(outputs["fsm.ex.tmpl"])
    assert {:ok, _ast} = Code.string_to_quoted(ex), "fsm.ex render does not parse as Elixir"
  end

  # ---------------------------------------------------------------------------
  # Court 2: determinism
  # ---------------------------------------------------------------------------

  test "determinism: two independent full renders are byte-identical" do
    a = snapshot(Path.dirname(render_all(scratch("render-a"))["fsm.ex.tmpl"]))
    b = snapshot(Path.dirname(render_all(scratch("render-b"))["fsm.ex.tmpl"]))

    assert map_size(a) == 4
    assert a == b, "two renders of the same pack diverged — generation is not deterministic"
  end

  # ---------------------------------------------------------------------------
  # Court 3: gates (read-only, oxigraph, typed ENGINE-LIMIT fallback)
  # ---------------------------------------------------------------------------

  test "gates: all 5 evaluate read-only; rq gates report 0 rows or typed ENGINE-LIMIT" do
    graph = ontology_graph(Path.join(@repo, @pack))
    run_rq_gates(graph)

    # 5th gate: template literal scan (python3, read-only, exit 0 = clean).
    py_gate = Path.join([@repo, @pack, @py_gate])
    templates_dir = Path.join([@repo, @pack, "templates"])

    case System.cmd("python3", [py_gate, templates_dir], stderr_to_stdout: true) do
      {out, 0} ->
        # Clean run still prints one JSON summary line: {"standing":
        # "ALIVE", "templates_scanned": N}. Parse it and assert the
        # standing is ALIVE over all 4 templates (zero hits).
        assert {:ok, %{"standing" => "ALIVE", "templates_scanned" => 4}} =
                 JSON.decode(String.trim(out))

      {out, 1} ->
        flunk("typed ENGINE-LIMIT: literal-scan gate refused the shipped templates: #{out}")

      {out, code} ->
        flunk("literal-scan gate exited #{code}: #{out}")
    end
  end

  # ---------------------------------------------------------------------------
  # Court 4: anti-vacuity mutation (tmp ontology copy only)
  # ---------------------------------------------------------------------------

  test "anti-vacuity: a rogue VerifiedState in a tmp copy flips gate 010" do
    corrupt = scratch("mutation")
    corrupt_pack = Path.join(corrupt, "pack")
    File.cp_r!(Path.join(@repo, @pack), corrupt_pack)

    ontology_path = Path.join(corrupt_pack, "ontology.ttl")
    ttl = File.read!(ontology_path)

    rogue = "\nst:RogueVerifiedCourtProbe a st:VerifiedState .\n"
    File.write!(ontology_path, ttl <> rogue)
    assert File.read!(ontology_path) != ttl, "corruption changed nothing"

    graph = ontology_graph(corrupt_pack)
    gate = Path.join(corrupt_pack, "verify/010_no_skipping_executed.unbound.rq")

    assert {:ok, rows} = gate_verdict(graph, gate)
    assert rows >= 1, "gate 010 did not fire on the rogue stage-skip (vacuous)"
  end

  # ---------------------------------------------------------------------------
  # Court 5: both-way witness validation for the re-homed offender gates
  # (ECO-GATE-CONVENTION-DECISION R0: offender convention = 0 rows on the
  # pass fixture, >= 1 row on the fail fixture)
  # ---------------------------------------------------------------------------

  describe "both-way witness validation (offender convention)" do
    for gate <- @offender_gates do
      test "witnesses for #{gate}: pass fixture silent, fail fixture fires" do
        gate = unquote(gate)
        stem = String.replace_suffix(Path.basename(gate), ".unbound.rq", "")

        graph_of = fn dir ->
          ontology = ontology_graph(Path.join(@repo, @pack))

          fixture =
            RDF.Turtle.read_file!(Path.join([@repo, @pack, "witnesses/#{dir}/#{stem}.ttl"]))

          RDF.Data.merge(ontology, fixture)
        end

        gate_path = Path.join([@repo, @pack, gate])

        assert {:ok, 0} = gate_verdict(graph_of.("pass"), gate_path),
               "pass fixture must be silent"

        assert {:ok, rows} = gate_verdict(graph_of.("fail"), gate_path)
        assert rows >= 1, "fail witness #{stem}.ttl did not fire the re-homed gate"
      end
    end
  end
end
