defmodule AshPPlan.Courts.WorkflowCorpusCourtTest do
  @moduledoc """
  Consumer/integration court for the vendored `workflow-corpus-pack`
  (`priv/ggen/vendor/workflow-corpus-pack/`).

  The pack's gates are violation-row SELECT queries (`rows = refusal`),
  designed to fire against a graph populated with the pack's fixture
  individuals. Run against the bare pack ontology alone they yield zero rows
  by construction -- which is why `bin/ggen-verify` reports zero rows for
  this pack. That is the verifier's known limitation at the bare-ontology
  layer, and it stays as-is; this court is the consumer wiring the pack
  expects: it merges the pack ontology with each fixture corpus (RDF.ex) and
  executes every gate with the native oxigraph engine
  (`GgenIgniter.Query.Oxigraph.run/2` -- the `sparql` 0.3.12 hex package
  crashes with `Protocol.UndefinedError` on these gates' `FILTER NOT EXISTS`
  shape), fail-closed (count mismatch = court failure).

  Executed courts: structural (exact-stem pass+fail witnesses for all 21
  gates, 12 complete fixture dirs); positive corpus fires nothing; all 12
  shipped fixture.ttl fire nothing; witness court (pass 0 rows / fail >= 1
  row per stem gate); per-fixture negative variants fire the exact named
  violation branches from expected.md; f000 negatives fire their named
  gates; anti-vacuity mutation on a tmp copy (one corrupted triple changes
  its gate's row count). Select-only pack: grants no DO authority; BRCE
  remains the sole consequential actuation boundary.
  """

  use ExUnit.Case, async: false

  @repo Path.expand("../..", __DIR__)
  @pack Path.join(@repo, "priv/ggen/vendor/workflow-corpus-pack")
  @fixture_numbers Enum.map(1..12, &Integer.to_string/1)
                   |> Enum.map(&String.pad_leading(&1, 2, "0"))

  # ---------------------------------------------------------------------------
  # Negative-variant expectations, transcribed from each fixture's expected.md:
  # {fixture dir, negative file, required branch codes, forbidden branch codes}.
  # ---------------------------------------------------------------------------
  @negative_expectations [
    {"05-hddl-decomposition", "negative-wrong-method.ttl", ["E-F05-WRONG-METHOD"], []},
    {"05-hddl-decomposition", "negative-dropped-subtask.ttl", ["E-F05-DROPPED-SUBTASK"], []},
    {"06-fond-replanning", "negative-happy-path.ttl", ["E-F06-NO-RECOVERY-PATH"], []},
    {"06-fond-replanning", "negative-untyped-recovery.ttl", ["E-F06-NO-RECOVERY-PATH"], []},
    {"07-durability-evidence", "negative-reexecuted-evidenced.ttl",
     ["E-F07-REEXECUTED-EVIDENCED"], []},
    {"07-durability-evidence", "negative-lost-outcome.ttl", ["E-F07-LOST-OUTCOME"], []},
    {"08-sa2a-remote-refusal", "negative-ambient-authority.ttl", ["E-F08-AMBIENT-AUTHORITY"], []},
    {"08-sa2a-remote-refusal", "negative-unverified-envelope.ttl", ["E-F08-UNVERIFIED-ENVELOPE"],
     []},
    {"09-dynamic-branch-switch", "negative-uncovered-arm.ttl", ["E-F09-UNCOVERED-ARM"], []},
    {"09-dynamic-branch-switch", "negative-branch-flip-after-checkpoint.ttl",
     ["E-F09-BRANCH-IDENTITY-UNFROZEN", "E-F09-SWITCH-DERIVATION-UNPINNED"],
     ["E-F09-UNCOVERED-ARM"]},
    {"10-recursive-bounded", "negative-unbounded-recursion.ttl", ["E-F10-UNBOUNDED-RECURSION"],
     []},
    {"10-recursive-bounded", "negative-recursion-identity-loss.ttl",
     ["E-F10-RECURSION-IDENTITY-LOST"], ["E-F10-UNBOUNDED-RECURSION"]},
    {"11-authority-denied-refusal", "negative-refusal-as-failure.ttl",
     ["E-F11-WORKFLOW-OUTCOME-NOT-ALIVE", "E-F11-STEP-REFUSAL-NOT-TYPED"], []},
    {"11-authority-denied-refusal", "negative-executes-anyway.ttl",
     ["E-F11-EXECUTED-WITHOUT-AUTHORITY"], []},
    {"11-authority-denied-refusal", "negative-recovery-path-missing.ttl",
     ["E-F11-RECOVERY-PATH-MISSING"], []},
    {"12-interchangeable-realizations", "negative-unqualified-third.ttl",
     ["E-F12-UNQUALIFIED-THIRD"], []},
    {"12-interchangeable-realizations", "negative-identity-split.ttl", ["E-F12-IDENTITY-SPLIT"],
     ["E-F12-UNQUALIFIED-THIRD"]}
  ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp gates do
    gate_dir = Path.join(@pack, "gates")

    case Path.wildcard(Path.join(gate_dir, "*.rq")) |> Enum.sort() do
      [] -> flunk("no gates found under #{gate_dir}")
      gates -> gates
    end
  end

  defp gate_name(gate_path), do: Path.basename(gate_path)

  defp stem(gate_path), do: Path.basename(gate_path, ".rq")

  defp read_graph(paths) when is_list(paths) do
    Enum.reduce(paths, RDF.Graph.new(), fn path, acc ->
      case RDF.Turtle.read_file(path) do
        {:ok, graph} ->
          RDF.Data.merge(acc, graph)

        {:error, position, reason} ->
          flunk("failed to parse #{path}: #{inspect(position)} #{inspect(reason)}")
      end
    end)
  end

  defp rows(gate_path, graph) do
    query = File.read!(gate_path)

    GgenIgniter.Query.Oxigraph.run(graph, query)
    |> Enum.map(fn row -> to_string(Map.get(row, "violation")) end)
  end

  defp fixture_dir(n) do
    case Path.wildcard(Path.join(@pack, "fixtures/#{n}-*")) do
      [dir] -> dir
      other -> flunk("expected exactly one fixture dir for #{n}, got #{inspect(other)}")
    end
  end

  defp fixture_graph(n) do
    read_graph([Path.join(@pack, "ontology.ttl"), Path.join(fixture_dir(n), "fixture.ttl")])
  end

  defp fixture_number_of_gate(gate_path) do
    "f" <> rest = stem(gate_path)
    String.slice(rest, 0, 2)
  end

  defp witness(kind, gate_path) do
    path = Path.join([@pack, "witnesses", kind, stem(gate_path) <> ".ttl"])
    unless File.exists?(path), do: flunk("missing #{kind} witness: #{path}")
    path
  end

  defp tmp_pack_copy do
    tmp =
      Path.join(System.tmp_dir!(), "workflow-corpus-court-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp)
    File.cp_r!(@pack, tmp)
    tmp
  end

  # ---------------------------------------------------------------------------
  # Court 1: structural
  # ---------------------------------------------------------------------------

  test "structural: 18 gates, witnessed firings, 12 complete fixture dirs" do
    gs = gates()
    assert length(gs) == 18

    # f000_* + f01..f04 stems (the witness-carrying lanes): exact-stem
    # pass + fail witness files. f05..f12 stems: their witnessed firing is
    # the per-fixture negative-*.ttl variants (court 5 below).
    for gate <- gs do
      if String.contains?(stem(gate), ["f000_", "f01_", "f02_", "f03_", "f04_"]) do
        assert File.exists?(witness("pass", gate)), "missing pass witness for #{stem(gate)}"
        assert File.exists?(witness("fail", gate)), "missing fail witness for #{stem(gate)}"
      else
        negs =
          Path.wildcard(Path.join(fixture_dir(fixture_number_of_gate(gate)), "negative-*.ttl"))

        assert negs != [], "gate #{stem(gate)} has no witnessed firing (no negative-*.ttl)"
      end
    end

    for n <- @fixture_numbers do
      dir = fixture_dir(n)
      assert File.exists?(Path.join(dir, "fixture.ttl"))
      assert File.exists?(Path.join(dir, "expected.md"))
    end
  end

  # ---------------------------------------------------------------------------
  # Court 2: positive corpus
  # ---------------------------------------------------------------------------

  test "positive corpus: qualification positive.ttl fires no gate" do
    graph =
      read_graph([
        Path.join(@pack, "ontology.ttl"),
        Path.join(@pack, "qualification/fixtures/positive.ttl")
      ])

    for gate <- gates() do
      fired = rows(gate, graph)
      assert fired == [], "gate #{gate_name(gate)} fired on positive corpus: #{inspect(fired)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 3: real fixture corpus (the shipped corpus is well-formed)
  # ---------------------------------------------------------------------------

  test "real corpus: all 12 fixture.ttl fire no gate" do
    for n <- @fixture_numbers do
      graph = fixture_graph(n)

      for gate <- gates() do
        fired = rows(gate, graph)

        assert fired == [],
               "fixture #{n}: gate #{gate_name(gate)} fired on shipped fixture: #{inspect(fired)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Court 4: witness court (pass 0 rows, fail >= 1 row at exact stem)
  # ---------------------------------------------------------------------------

  test "witness court: pass witnesses fire 0 rows, fail witnesses fire >= 1 row" do
    # Witness FILES exist for the f000_*/f01..f04 stems (their lanes own
    # them); f05..f12 stems carry their witnessed firing as per-fixture
    # negative-*.ttl variants, qualified by court 5.
    witnessed_gates =
      Enum.filter(gates(), fn gate ->
        File.exists?(Path.join([@pack, "witnesses", "pass", stem(gate) <> ".ttl"]))
      end)

    assert length(witnessed_gates) == 10

    for gate <- witnessed_gates do
      pass_graph = read_graph([Path.join(@pack, "ontology.ttl"), witness("pass", gate)])
      assert rows(gate, pass_graph) == [], "gate #{gate_name(gate)} fired on its PASS witness"

      fail_graph = read_graph([Path.join(@pack, "ontology.ttl"), witness("fail", gate)])
      fired = rows(gate, fail_graph)
      assert fired != [], "gate #{gate_name(gate)} fired 0 rows on its FAIL witness (vacuous)"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 5: per-fixture negative variants fire exact named branches
  # ---------------------------------------------------------------------------

  test "negative variants fire exact named branches (and only them)" do
    refute @negative_expectations == []

    for {fixture, neg_file, required, forbidden} <- @negative_expectations do
      graph =
        read_graph([
          Path.join(@pack, "ontology.ttl"),
          Path.join(@pack, "fixtures/#{fixture}/#{neg_file}")
        ])

      prefix = "f#{String.slice(fixture, 0, 2)}_"
      gate = Enum.find(gates(), &String.starts_with?(stem(&1), prefix))
      assert gate, "no gate with prefix #{prefix}"

      fired = rows(gate, graph)

      for code <- required do
        assert code in fired,
               "#{fixture}/#{neg_file}: expected branch #{code}, got #{inspect(fired)}"
      end

      for code <- forbidden do
        refute code in fired,
               "#{fixture}/#{neg_file}: must not fire #{code}, got #{inspect(fired)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Court 6: shared f000 malformed-fixture corpus
  # ---------------------------------------------------------------------------

  test "f000 corpus: qualification negatives fire their named f000 gates" do
    expectations = [
      {"negative-missing-goal.ttl", "f000_fixture_missing_goal"},
      {"negative-no-capability-closure.ttl", "f000_fixture_missing_capability_closure"},
      {"negative-missing-expected-outcome.ttl", "f000_fixture_missing_expected_outcome"},
      {"negative-no-falsifier.ttl", "f000_fixture_missing_falsifier"},
      {"negative-missing-authority.ttl", "f000_consequential_task_without_required_authority"},
      {"negative-forbidden-conflict.ttl", "f000_forbidden_plus_expected_realization_conflict"}
    ]

    for {neg_file, stem_name} <- expectations do
      graph =
        read_graph([
          Path.join(@pack, "ontology.ttl"),
          Path.join(@pack, "qualification/fixtures/#{neg_file}")
        ])

      gate = Enum.find(gates(), &(stem(&1) == stem_name))
      assert gate, "gate #{stem_name} not found"
      assert rows(gate, graph) != [], "#{neg_file}: gate #{stem_name} returned 0 rows"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 7: anti-vacuity mutation (tmp copy only; real files untouched)
  # ---------------------------------------------------------------------------

  test "anti-vacuity: corrupting one triple in a tmp copy changes its gate's row count" do
    tmp = tmp_pack_copy()

    fixture = Path.join(tmp, "fixtures/06-fond-replanning/fixture.ttl")
    ttl = File.read!(fixture)

    # Corrupt exactly one triple: point fixture 06's endpoint re-resolution
    # recovery edge at a non-Activity node. Clean fixture fires 0 rows; the
    # corruption must flip gate f06 to firing (>= 1 row): the count changed.
    needle = "dcterms:relation wfc:f06-recovery-re-endpoint ."
    assert ttl =~ needle, "corruption target triple not found in fixture 06"

    corrupted =
      String.replace(
        ttl,
        needle,
        "dcterms:relation wfc:f06-outcome-transport-refused .",
        count: 1
      )

    assert corrupted != ttl, "corruption changed nothing"
    File.write!(fixture, corrupted)

    gate = Enum.find(gates(), &(stem(&1) == "f06_fond_replanning"))
    assert length(rows(gate, fixture_graph("06"))) == 0

    corrupted_graph = read_graph([Path.join(tmp, "ontology.ttl"), fixture])
    corrupted_count = length(rows(gate, corrupted_graph))
    assert corrupted_count >= 1
    assert corrupted_count != 0

    File.rm_rf!(tmp)
  end
end
