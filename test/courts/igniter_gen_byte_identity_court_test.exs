defmodule AshPPlan.Courts.IgniterGenByteIdentityCourtTest do
  @moduledoc """
  ERRC item 10 (test-only form): byte-identity court for the igniter-pack
  generator surface (`priv/ggen/ash-pplan-igniter-pack`).

  Until now the igniter pack's drift was caught only by runtime behaviour
  (the generated `mix ash_pplan.gen.workflow` task is exercised elsewhere);
  nothing asserted that the generator still manufactures its committed
  projection. This court closes that with three probes, all in-test — no new
  bin wiring:

    1. **Determinism**: the same template, ontology, and engine rendered
       twice into two independent output paths yield byte-identical files.
    2. **Diff-stability**: a render matches the committed projection
       (`lib/mix/tasks/ash_pplan.gen.workflow.ex`) under the same
       `Code.format_string!/1` normalization every other regeneration court
       in this repo uses (`test/manufacture_test.exs`).
    3. **Anti-vacuity**: mutating the variable-substitution input (the
       ontology's `ig:taskName` fact, in a tmp copy of the pack) makes the
       render diverge from the pristine render — proving the render is
       data-dependent, not a fixed string.

  Plus a read-only SPARQL probe: every `gates/*.rq` in the pack runs against
  the pack ontology via RDF.ex/SPARQL.ex and must return non-zero rows.
  """

  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @pack "priv/ggen/ash-pplan-igniter-pack"
  @template "gen_workflow_task.ex.eex"
  @checked_in Path.expand("../../lib/mix/tasks/ash_pplan.gen.workflow.ex", __DIR__)
  @ontology Path.join([@root, @pack, "ontology.ttl"])

  # ggen_igniter refuses any --out that resolves outside the authorized
  # project root, so the renders land in an ignored scratch tree inside the
  # project (same pattern as test/manufacture_test.exs). Run-unique: two
  # suites sharing one manifest dir would contend on the ggen_igniter sync
  # lock and time each other out.
  setup_all do
    scratch =
      Path.expand("../../tmp/igniter_gen_court", __DIR__)
      |> Path.join("run-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}")

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(Path.expand("../../tmp/igniter_gen_court", __DIR__)) end)
    {:ok, scratch: scratch}
  end

  defp render!(scratch, subdir, pack_dir, template_name) do
    recipe_scratch = Path.join(scratch, subdir)
    File.mkdir_p!(recipe_scratch)
    output = Path.join(recipe_scratch, "out.ex")

    Mix.Task.reenable("ggen_igniter.sync")

    Mix.Task.run("ggen_igniter.sync", [
      "--pack-dir",
      pack_dir,
      "--template",
      Path.join([pack_dir, "templates", template_name]),
      "--engine",
      "oxigraph",
      "--out",
      output,
      "--manifest-dir",
      recipe_scratch,
      "--verify-cwd",
      @root
    ])

    output
  end

  defp normalize(path) do
    path |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()
  end

  @tag timeout: 900_000
  test "render is deterministic: two renders of the same inputs are byte-identical", %{
    scratch: scratch
  } do
    out1 = render!(scratch, "determinism_a", @pack, @template)
    out2 = render!(scratch, "determinism_b", @pack, @template)

    assert File.read!(out1) == File.read!(out2),
           "two renders of #{template_label()} diverged — the generator is not deterministic"

    assert File.read!(out1) != "",
           "render produced an empty file"
  end

  @tag timeout: 900_000
  test "render is diff-stable against the committed generated task", %{scratch: scratch} do
    out = render!(scratch, "stability", @pack, @template)

    assert normalize(out) == normalize(@checked_in),
           "#{template_label()} no longer manufactures " <>
             Path.relative_to(@checked_in, @root) <>
             " (format-normalized comparison, per test/manufacture_test.exs convention)"
  end

  @tag timeout: 900_000
  test "anti-vacuity: mutating the ontology task-name binding changes the render", %{
    scratch: scratch
  } do
    pristine = render!(scratch, "mutation_pristine", @pack, @template)

    # Tmp copy of the pack with the ig:taskName fact hand-mutated.
    mutated_pack = Path.join(scratch, "mutated-pack")
    File.cp_r!(Path.join(@root, @pack), mutated_pack)

    ontology_path = Path.join(mutated_pack, "ontology.ttl")

    ontology = File.read!(ontology_path)

    mutated =
      String.replace(
        ontology,
        ~s(ig:taskName "ash_pplan.gen.workflow"),
        ~s(ig:taskName "ash_pplan.gen.workflow_mutated"),
        global: false
      )

    assert mutated != ontology,
           "the mutation did not apply — ig:taskName fact text drifted"

    File.write!(ontology_path, mutated)

    diverged =
      render!(scratch, "mutation_diverged", Path.relative_to(mutated_pack, @root), @template)

    assert File.read!(diverged) != File.read!(pristine),
           "mutating the ig:taskName ontology fact did NOT change the render — " <>
             "the generator would pass byte-identity courts on a fixed string"
  end

  test "pack SPARQL gates run read-only against the ontology and return non-zero rows" do
    graph = RDF.Turtle.read_file!(@ontology)
    gates = Path.wildcard(Path.join([@root, @pack, "gates", "*.rq"]))

    assert gates != [], "no SPARQL gates found in #{@pack}/gates"

    for gate <- gates do
      query = File.read!(gate)

      case SPARQL.execute_query(graph, query) do
        %SPARQL.Query.Result{} = result ->
          rows = Enum.to_list(result)
          assert rows != [], "#{Path.relative_to(gate, @root)} returned zero rows"

        other ->
          flunk("#{Path.relative_to(gate, @root)} did not execute: #{inspect(other)}")
      end
    end
  end

  defp template_label, do: "#{@pack}/templates/#{@template}"
end
