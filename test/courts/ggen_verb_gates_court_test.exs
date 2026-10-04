defmodule GgenVerbGatesCourtTest do
  @moduledoc """
  ERRC G3 — court pinning ggen's unused law/capability verbs as real checks
  (ggen 26.9.28).

  ## Baselines pinned (fixtures/law_export_baseline.txt)

  - `law export --format json` on `ontology.ttl` (no rules): 1272 triples
    (1274 with the marker rule's 2 derived), BLAKE3 graph_hash
    `3c66d6b1...` — deterministic canonical output. Re-pinned 2026-10-04
    (2nd) after the statusgen landing grew the root ontology 1043 -> 1274
    triples (+231: 1 st:Machine + 9 st:State + 30 st:Transition, the
    st:RunStatusMachine block; integration-ledger-2026-10-04 Addendum 6).
    Prior pin (1043 triples, `22a708e3aa38dd4e...`; itself grown from the
    811-triple R2-era pin `2054e8716b81a76e...`).
  - `law derive` with the court's one marker rule: rules_loaded=1, derived=2.
  - `law explain` on the same rule: non-empty derived_triples diff, with the
    rule-attributed triple list.
  - `capability list --format json`: exactly 7 registry surfaces
    (mcp, compliance-soc2, web, devops, data-science, startup,
    enterprise-backend) — the RA2-pinned surface list as drift baseline.

  ## Fail-closed

  Every ggen invocation pattern-matches on exit code 0 and parses its JSON —
  a nonzero exit or unparseable output fails the court. Anti-vacuity: a
  deliberately mutated scratch ontology must produce a DIFFERENT export
  graph_hash, and a broken ontology must make `law export` exit nonzero, so
  the court cannot pass while the verb is silently inert.

  ## Manifest note

  The repo-root ggen.toml is unparseable by ggen 26.9.28 ([FM-CONFIG-002],
  see law_validate_parity_court_test.exs), so — like the parity court — this
  court materializes its own scratch manifest under tmp/ and copies
  ontology.ttl into it. The export baseline is against the verbatim
  ontology.ttl bytes read at court start.
  """

  use ExUnit.Case, async: false

  @repo File.cwd!()
  @ontology Path.join(@repo, "ontology.ttl")
  @baseline Path.join(@repo, "test/courts/fixtures/law_export_baseline.txt")

  @marker_rule """
  @prefix ap: <https://w3id.org/ash-pplan#> .
  @prefix pplan: <http://purl.org/net/p-plan#> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

  { ?s a pplan:Step } => { ?s ap:g3CourtMarker "g3" } .
  """

  @capability_surfaces ~w(mcp compliance-soc2 web devops data-science startup enterprise-backend)

  setup do
    scratch = Path.join(@repo, "tmp/g3-ggen-verb-court-#{System.system_time(:native)}")
    File.mkdir_p!(Path.join(scratch, "templates"))

    canonical = File.read!(@ontology)
    File.write!(Path.join(scratch, "ontology.ttl"), canonical)
    File.write!(Path.join(scratch, "law.n3"), @marker_rule)

    manifest = """
    [project]
    name = "ash_pplan_g3_verb_court"

    [templates]
    dir = "templates"

    [law]
    rules = ["law.n3"]

    [ontology]
    source = "ontology.ttl"
    """

    File.write!(Path.join(scratch, "ggen.toml"), manifest)
    on_exit(fn -> File.rm_rf!(scratch) end)

    %{scratch: scratch, canonical: canonical, baseline: read_baseline()}
  end

  describe "law export determinism + BLAKE3 baseline" do
    @tag :g3_verb_court
    test "export is deterministic and matches the pinned graph_hash", ctx do
      {out1, 0} = ggen(ctx.scratch, ["law", "export", "--format", "json"])
      {out2, 0} = ggen(ctx.scratch, ["law", "export", "--format", "json"])

      j1 = parse_json!(out1, "law export run 1")
      j2 = parse_json!(out2, "law export run 2")

      assert j1 == j2, "law export is not deterministic run-to-run"

      assert j1["graph_hash"] == ctx.baseline["graph_hash"],
             "law export BLAKE3 state hash drifted from baseline " <>
               "(expected #{ctx.baseline["graph_hash"]}, got #{j1["graph_hash"]})"

      assert j1["triples"] == String.to_integer(ctx.baseline["triples"])
      assert j1["ntriples"] != "" and is_binary(j1["ntriples"])
    end

    @tag :g3_verb_court
    test "anti-vacuity: mutated ontology changes the export hash; broken ontology exits nonzero",
         ctx do
      {out, 0} = ggen(ctx.scratch, ["law", "export", "--format", "json"])
      reference_hash = parse_json!(out, "law export reference")["graph_hash"]

      # Mutation: one extra triple on a fresh scratch copy.
      mutated = Path.join(@repo, "tmp/g3-mutated-#{System.system_time(:native)}")
      File.mkdir_p!(Path.join(mutated, "templates"))
      on_exit(fn -> File.rm_rf!(mutated) end)

      File.write!(
        Path.join(mutated, "ontology.ttl"),
        ctx.canonical <>
          "\n<https://w3id.org/ash-pplan#G3MutationProbe> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <https://w3id.org/ash-pplan#Capability> .\n"
      )

      File.write!(Path.join(mutated, "law.n3"), @marker_rule)

      File.write!(Path.join(mutated, "ggen.toml"), """
      [project]
      name = "ash_pplan_g3_mutated"
      [templates]
      dir = "templates"
      [law]
      rules = ["law.n3"]
      [ontology]
      source = "ontology.ttl"
      """)

      {mut_out, 0} = ggen(mutated, ["law", "export", "--format", "json"])
      mutated_hash = parse_json!(mut_out, "law export mutated")["graph_hash"]

      refute mutated_hash == reference_hash,
             "anti-vacuity: mutating ontology.ttl did NOT change the export hash"

      refute mutated_hash == ctx.baseline["graph_hash"],
             "mutated hash collided with the pinned baseline"

      # Fail-closed: an unparseable ontology must make the verb exit nonzero.
      broken = Path.join(@repo, "tmp/g3-broken-#{System.system_time(:native)}")
      File.mkdir_p!(Path.join(broken, "templates"))
      on_exit(fn -> File.rm_rf!(broken) end)
      File.write!(Path.join(broken, "ontology.ttl"), "<this is not turtle")

      File.write!(Path.join(broken, "ggen.toml"), """
      [project]
      name = "ash_pplan_g3_broken"
      [templates]
      dir = "templates"
      [ontology]
      source = "ontology.ttl"
      """)

      {_err, code} = ggen_raw(broken, ["law", "export", "--format", "json"])
      refute code == 0, "fail-closed: broken ontology did not fail law export"
    end
  end

  describe "law derive stability baseline" do
    @tag :g3_verb_court
    test "derived-triple count is stable and matches the pinned baseline", ctx do
      {out1, 0} = ggen(ctx.scratch, ["law", "derive", "--format", "json"])
      {out2, 0} = ggen(ctx.scratch, ["law", "derive", "--format", "json"])

      j1 = parse_json!(out1, "law derive run 1")
      j2 = parse_json!(out2, "law derive run 2")

      assert j1 == j2, "law derive is not deterministic run-to-run"
      assert j1["rules_loaded"] == String.to_integer(ctx.baseline["rules_loaded"])

      assert j1["derived"] == String.to_integer(ctx.baseline["derived"]),
             "derived-triple count drifted from baseline #{ctx.baseline["derived"]}"

      assert j1["derived"] > 0, "marker rule derived zero triples (vacuous law config)"
    end
  end

  describe "law explain non-empty explanation" do
    @tag :g3_verb_court
    test "explain reports the rule and its full derived-triple diff", ctx do
      {out, 0} = ggen(ctx.scratch, ["law", "explain", "--format", "json"])
      j = parse_json!(out, "law explain")

      assert j["rules_loaded"] > 0, "law explain saw zero rules"
      assert j["rules_per_file"]["law.n3"] == 1
      derived = j["derived_triples"]
      assert is_list(derived) and derived != [], "law explain produced an empty explanation"

      assert Enum.all?(derived, &String.contains?(&1, "g3CourtMarker")),
             "every derived triple must carry the marker predicate, got: #{inspect(derived)}"

      assert j["derived"] == String.to_integer(ctx.baseline["derived"])
    end
  end

  describe "capability list registry surface (drift baseline)" do
    @tag :g3_verb_court
    test "registry parses and matches the pinned 7-surface list", _ctx do
      {out, 0} = ggen(@repo, ["capability", "list", "--format", "json"])
      j = parse_json!(out, "capability list")

      assert j["total"] == length(@capability_surfaces)
      ids = Enum.map(j["capabilities"], & &1["id"]) |> Enum.sort()

      assert ids == Enum.sort(@capability_surfaces),
             "capability registry surface drifted from the RA2 baseline " <>
               "(expected #{Enum.join(@capability_surfaces, ", ")}, got #{Enum.join(ids, ", ")})"

      assert Enum.all?(j["capabilities"], &(is_binary(&1["name"]) and &1["name"] != ""))
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp read_baseline do
    @baseline
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  # Runs ggen with stderr discarded so JSON stdout stays parseable.
  defp ggen(cwd, args) do
    {out, code} = ggen_raw(cwd, args)
    {out, code}
  end

  defp ggen_raw(cwd, args) do
    System.cmd("/usr/bin/env", ["ggen" | args],
      cd: cwd,
      env: %{"NO_COLOR" => "1"},
      stderr_to_stdout: false
    )
  end

  defp parse_json!(out, what) do
    case Jason.decode(out) do
      {:ok, j} when is_map(j) ->
        j

      other ->
        flunk(
          "#{what}: unparseable JSON output (fail-closed): #{inspect(other)} :: #{inspect(String.slice(out, 0, 300))}"
        )
    end
  end
end
