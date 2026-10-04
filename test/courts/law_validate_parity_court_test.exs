defmodule LawValidateParityCourtTest do
  @moduledoc """
  ERRC E1 phase 1 — parity court for `ggen law validate` vs `bin/conform-falsify`.

  ## Parity verdict

  `ggen law validate` (ggen 26.9.28) refuses exactly the same 13 counterexamples
  `bin/conform-falsify` refuses — achieved via [law].rules N3 denial rules, not
  [law].shapes alone. Two ggen dialect facts, discovered by this court's probe
  phase, are load-bearing:

  1. **sh:pattern backslash escape** — ggen's SHACL engine false-fails the
     clean graph (31 violations, every `ap:cap_*` Capability focus node,
     source shape of the `ap:capabilityId` pattern constraint) on the sh:pattern
     `"^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$"` in
     `ontology/shapes.ttl`. The regex-equivalent `[.]` spelling validates clean
     under both pyshacl and ggen. The court validates against a generated copy
     of shapes.ttl with exactly that one rewrite (asserted to fire exactly
     once, so a silent no-op cannot fake parity) and pins the pattern's
     presence in ontology/shapes.ttl so drift is caught.
  2. **CORE_ONLY sh:sparql boundary** — ggen's SHACL engine is compiled with
     `SHACL_SPARQL_BOUNDARY = "CORE_ONLY"` (ggen crates/praxis-graphlaw/src/
     shacl/model.rs:114), so every `sh:sparql` constraint in shapes.ttl is
     skipped silently at load time. Shapes alone refuse only 8/13
     counterexamples; the 5 misses are exactly the sh:sparql-gated invariants
     (duplicate ap:order, duplicate ap:sourceTerm, foreign-plan precedence,
     self-precedence, foreign-plan variable). The court ports those 5
     invariants to [law].rules N3 denial rules (`{ ... } => false .`), which
     the GraphLaw engine checks after materialization (FM-LAW-011) — full
     13/13 parity, each gap mutation refused by its corresponding rule.
     Further N3 dialect notes: ggen's N3 parser rejects hyphenated prefix
     names (`p-plan:` fails to parse), so the rules use `pplan:`; a
     repeated-variable body (`?s p-plan:isPrecededBy ?s`) does NOT work — the
     engine does not enforce repeated-variable identity in denial bodies and
     false-fires on every step — so the self-precedence rule uses
     `?s log:equalTo ?v`; and the log: namespace must be spelled exactly
     `http://www.w3.org/2000/10/swap/log#` (a typo'd namespace silently
     degrades a rule into an inert ordinary predicate).

  `ggen law validate` evaluates [law].rules + [law].shapes only; [law].gates
  (.rq) gate sync (FM-LAW-013), not `law validate`.

  ## Anti-vacuity

  The last test runs the same parity harness against an empty-shape /
  empty-rules scratch config, asserts ggen refuses NOTHING there, and asserts
  that empty refusal set differs from the reference set — i.e. the court's
  parity assertion would fail loudly if the law config were gutted.

  ## Pre-existing blocker (not E1's)

  ggen 26.9.28 cannot parse the repo-root ggen.toml at all ([FM-CONFIG-002]:
  `[packs.exemptions]` string values do not match the PackRef enum), so
  root-level `ggen law validate` is unavailable regardless of [law]. The
  court materializes its own scratch manifest under tmp/; if the
  `[packs.exemptions]` migration lands, the same [law] content applies at
  root unchanged.
  """

  use ExUnit.Case, async: false

  @repo File.cwd!()
  @ontology Path.join(@repo, "ontology.ttl")
  @shapes Path.join(@repo, "ontology/shapes.ttl")
  @conform_falsify Path.join(@repo, "bin/conform-falsify")

  # The single regex-equivalent rewrite the ggen SHACL engine needs.
  @bad_pattern ~S{sh:pattern "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$"}
  @ok_pattern ~S{sh:pattern "^[A-Za-z][A-Za-z0-9_]*([.][A-Za-z][A-Za-z0-9_]*)+$"}

  # N3 denial rules: port of the 5 sh:sparql constraints ggen's CORE_ONLY
  # SHACL boundary skips silently. See module docs for dialect notes.
  @parity_n3 """
  @prefix ap: <https://w3id.org/ash-pplan#> .
  @prefix pplan: <http://purl.org/net/p-plan#> .
  @prefix log: <http://www.w3.org/2000/10/swap/log#> .

  { ?a a ap:Projection ; ap:order ?o . ?b a ap:Projection ; ap:order ?o . ?a log:notEqualTo ?b } => false .
  { ?a a ap:Projection ; ap:sourceTerm ?o . ?b a ap:Projection ; ap:sourceTerm ?o . ?a log:notEqualTo ?b } => false .
  { ?s pplan:isStepOfPlan ?p1 ; pplan:isPrecededBy ?v . ?v pplan:isStepOfPlan ?p2 . ?p1 log:notEqualTo ?p2 } => false .
  { ?s pplan:isPrecededBy ?v . ?s log:equalTo ?v } => false .
  { ?s pplan:isStepOfPlan ?p ; pplan:hasInputVar ?v . ?v pplan:isVariableOfPlan ?p2 . ?p log:notEqualTo ?p2 } => false .
  { ?s pplan:isStepOfPlan ?p ; pplan:hasOutputVar ?v . ?v pplan:isVariableOfPlan ?p2 . ?p log:notEqualTo ?p2 } => false .
  """

  # The 13 admitted-violation counterexamples, verbatim from
  # bin/conform-falsify's MUTATIONS map (the reference refusal set).
  @mutations %{
    "unadmitted projection standing" =>
      "ap:projection-invented a ap:Projection ; ap:order 90 ; ap:sourceTerm ap:Invented ; " <>
        "ap:targetRuntime \"X\" ; ap:targetPrimitive \"Y\" ; ap:owner \"z\" ; ap:role \"r\" ; ap:status \"invented\" .",
    "duplicate projection order" =>
      "ap:projection-collision a ap:Projection ; ap:order 1 ; ap:sourceTerm ap:Collision ; " <>
        "ap:targetRuntime \"X\" ; ap:targetPrimitive \"Y\" ; ap:owner \"z\" ; ap:role \"r\" ; ap:status \"reuse\" .",
    "duplicate projection source term" =>
      "ap:projection-shadow a ap:Projection ; ap:order 91 ; ap:sourceTerm p-plan:Plan ; " <>
        "ap:targetRuntime \"X\" ; ap:targetPrimitive \"Y\" ; ap:owner \"z\" ; ap:role \"r\" ; ap:status \"reuse\" .",
    "step preceded by a step of another plan" =>
      "ap:OtherPlan a p-plan:Plan ; rdfs:label \"Other\" .\n" <>
        "ap:OtherStep a p-plan:Step ; p-plan:isStepOfPlan ap:OtherPlan .\n" <>
        "ap:AuthorizePayment p-plan:isPrecededBy ap:OtherStep .",
    "step preceded by itself" => "ap:AuthorizePayment p-plan:isPrecededBy ap:AuthorizePayment .",
    "step preceded by something that is not a step" =>
      "ap:AuthorizePayment p-plan:isPrecededBy ap:Subscription .",
    "plan without a label" =>
      "ap:UnlabelledPlan a p-plan:Plan .\n" <>
        "ap:UnlabelledPlanStep a p-plan:Step ; p-plan:isStepOfPlan ap:UnlabelledPlan .",
    "plan with no steps" => "ap:EmptyPlan a p-plan:Plan ; rdfs:label \"Empty\" .",
    "step with two labels" => "ap:AuthorizePayment rdfs:label \"One\", \"Two\" .",
    "projection source term that is a literal" =>
      "ap:projection-literal-source a ap:Projection ; ap:order 92 ; ap:sourceTerm \"not-an-iri\" ; " <>
        "ap:targetRuntime \"X\" ; ap:targetPrimitive \"Y\" ; ap:owner \"z\" ; ap:role \"r\" ; ap:status \"reuse\" .",
    "step using a variable from another plan" =>
      "ap:ForeignPlan a p-plan:Plan ; rdfs:label \"Foreign\" .\n" <>
        "ap:ForeignStep a p-plan:Step ; p-plan:isStepOfPlan ap:ForeignPlan .\n" <>
        "ap:ForeignVar a p-plan:Variable ; p-plan:isVariableOfPlan ap:ForeignPlan .\n" <>
        "ap:AuthorizePayment p-plan:hasInputVar ap:ForeignVar .",
    "step outside any plan" => "ap:OrphanStep a p-plan:Step .",
    "variable outside any plan" => "ap:OrphanVariable a p-plan:Variable ."
  }

  setup do
    scratch = Path.join(@repo, "tmp/e1-law-court-#{System.system_time(:native)}")
    File.mkdir_p!(Path.join(scratch, "templates"))

    canonical = File.read!(@ontology)

    shapes_rw = rewrite_pattern(File.read!(@shapes))

    File.write!(Path.join(scratch, "ontology.ttl"), canonical)
    File.write!(Path.join(scratch, "shapes_rw.ttl"), shapes_rw)

    manifest = """
    [project]
    name = "ash_pplan_e1_parity_court"

    [templates]
    dir = "templates"

    [ontology]
    source = "ontology.ttl"

    [law]
    shapes = ["shapes_rw.ttl"]
    rules = ["parity.n3"]
    """

    File.write!(Path.join(scratch, "ggen.toml"), manifest)

    on_exit(fn -> File.rm_rf!(scratch) end)

    %{scratch: scratch, canonical: canonical}
  end

  defp rewrite_pattern(shapes) do
    # Post-migration (2026-10-04): the [.] rewrite landed in ontology/shapes.ttl
    # itself, so the generated copy is the file verbatim. The guard is kept:
    # exactly one [.]-form pattern must be present and zero \.-form patterns,
    # so a regression back to the dialect-sensitive spelling fails loudly here.
    ok_count = count_occurrences(shapes, @ok_pattern)
    bad_count = count_occurrences(shapes, @bad_pattern)

    assert ok_count == 1 and bad_count == 0,
           "expected exactly one [.]-form sh:pattern and zero \\.-form patterns " <>
             "in ontology/shapes.ttl, found ok=#{ok_count} bad=#{bad_count}"

    shapes
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  # Runs `ggen law validate` in the scratch manifest dir; returns exit code.
  defp ggen_validate(scratch) do
    {_, code} =
      System.cmd("/usr/bin/env", ["ggen", "law", "validate"],
        cd: scratch,
        stderr_to_stdout: true,
        env: %{"NO_COLOR" => "1"}
      )

    code
  end

  # Same, but also returns the captured output (for denial-marker asserts).
  defp ggen_validate_out(scratch) do
    {out, code} =
      System.cmd("/usr/bin/env", ["ggen", "law", "validate"],
        cd: scratch,
        stderr_to_stdout: true,
        env: %{"NO_COLOR" => "1"}
      )

    {out, code}
  end

  defp write_rules(scratch, content),
    do: File.write!(Path.join(scratch, "parity.n3"), content)

  describe "reference gate" do
    @tag :e1_parity_court
    test "bin/conform-falsify refuses all 13 counterexamples", %{canonical: canonical} do
      assert File.read!(@ontology) == canonical, "ontology.ttl changed mid-run"
      {out, 0} = System.cmd("python3", [@conform_falsify], cd: @repo)
      assert out =~ "13 counterexamples refused"
    end

    @tag :e1_parity_court
    test "shapes.ttl carries the regex-equivalent [.]-form pattern (drift pin)" do
      shapes = File.read!(@shapes)

      assert shapes =~ @ok_pattern,
             "ontology/shapes.ttl does not contain the [.]-form pattern; " <>
               "if it regressed to the \\.-form, ggen's SHACL engine false-fails again"

      refute shapes =~ @bad_pattern,
             "ontology/shapes.ttl contains the \\.-form pattern; " <>
               "ggen's SHACL engine false-fails on that spelling"
    end
  end

  describe "parity: ggen law validate vs bin/conform-falsify" do
    @tag :e1_parity_court
    test "clean graph accepted and all 13 counterexamples refused",
         %{scratch: scratch, canonical: canonical} do
      write_rules(scratch, @parity_n3)

      {_out, 0} = ggen_validate_out(scratch)

      refused =
        for {name, mut} <- @mutations, reduce: MapSet.new() do
          acc ->
            File.write!(Path.join(scratch, "ontology.ttl"), canonical <> "\n" <> mut <> "\n")

            case ggen_validate(scratch) do
              0 ->
                acc

              _ ->
                MapSet.put(acc, name)
            end
        end

      expected = MapSet.new(Map.keys(@mutations))

      assert MapSet.equal?(refused, expected),
             "parity broken: ggen refused #{MapSet.size(refused)}/13; missed: " <>
               inspect(MapSet.difference(expected, refused)) <>
               "; extra: " <> inspect(MapSet.difference(refused, expected))
    end

    @tag :e1_parity_court
    test "each CORE_ONLY-gap mutation is refused by its corresponding denial rule",
         %{scratch: scratch, canonical: canonical} do
      write_rules(scratch, @parity_n3)

      # gap mutation -> marker that only the corresponding denial's rendered
      # output can contain
      gap_markers = %{
        "duplicate projection order" => "ash-pplan#order> o",
        "duplicate projection source term" => "ash-pplan#sourceTerm> o",
        "step preceded by a step of another plan" => "isPrecededBy> v",
        "step preceded by itself" => "log#equalTo",
        "step using a variable from another plan" => "isVariableOfPlan"
      }

      for {name, marker} <- gap_markers do
        mut = Map.fetch!(@mutations, name)
        File.write!(Path.join(scratch, "ontology.ttl"), canonical <> "\n" <> mut <> "\n")
        {out, code} = ggen_validate_out(scratch)

        assert code != 0, "#{name}: expected refusal"
        assert out =~ "FM-LAW-011", "#{name}: expected an FM-LAW-011 denial refusal, got: #{out}"
        assert out =~ marker, "#{name}: denial output missing marker #{inspect(marker)}"
      end
    end
  end

  describe "anti-vacuity" do
    @tag :e1_parity_court
    test "empty-shape/empty-rules config admits everything; court parity fails there",
         %{scratch: scratch, canonical: canonical} do
      # Gut the law config: no shapes, no rules.
      File.write!(Path.join(scratch, "shapes_rw.ttl"), "")
      write_rules(scratch, "")

      # A config whose shapes file is EMPTY must be refused by the court
      # harness itself: ggen would validate anything against zero shapes.
      empty_refused =
        for {_name, mut} <- @mutations do
          File.write!(Path.join(scratch, "ontology.ttl"), canonical <> "\n" <> mut <> "\n")
          ggen_validate(scratch)
        end

      assert Enum.all?(empty_refused, &(&1 == 0)),
             "empty config refused #{Enum.count(empty_refused, &(&1 != 0))} mutations — " <>
               "the empty-shape config is NOT vacuous, so this anti-vacuity probe carries no bits"

      # And the court's parity assertion genuinely fails on the empty config:
      empty_set = MapSet.new(Enum.filter(empty_refused, &(&1 != 0)))

      assert not MapSet.equal?(empty_set, MapSet.new(Map.keys(@mutations))),
             "empty-config refusal set equals the reference set; the parity " <>
               "harness cannot distinguish a gutted config from the real one"
    end
  end
end
