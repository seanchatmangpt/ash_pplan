defmodule AshPPlan.Durable.ProtocolCourtTest do
  @moduledoc """
  Consumer-side differential court for the vendored
  ash-pplan-protocol-court-pack adoption (ECO-PROTOCOL-COURT).

  The pack renders ALL court surfaces from ONE protocol ontology
  (`priv/ggen/generated/protocol-court/`, emitted by
  `bin/manufacture-protocol-court` from
  `priv/ggen/vendor/ash-pplan-protocol-court-pack/`, sha256-locked by
  `priv/ggen/vendor/sync.sh` at the pinned marketplace sha):

    1. `JobLeaseProtocol.tla` + `JobLeaseProtocol.cfg` — the TLA+/TLC surface
    2. `stateright/model.rs` — the Stateright differential model (same rows)
    3. `JobLeaseProtocol_transitions.exs` — the Elixir transition table (same rows)

  Court legs:

    * cross-projection vocabulary agreement (always on): every status,
      transition pair, guard, property and declared mutant rendered into the
      TLA+ module must be byte-identical to what the Stateright model and the
      transition table carry — a disagreement between the checkers' projections
      is a court failure, not a modeling drift;
    * native tla-rs court (pinned binary, `AshPPlan.Test.NativeTLA`): the
      original spec is ADMITTED with real explored-state evidence, and every
      declared mutant (`pcp:Mutant` rows: claim_free, record_once) is REFUSED
      with a named invariant/property counterexample — a mutant with no
      counterexample is an admission failure (anti-vacuity). Mirrors
      `test/durable/native_tla_court_test.exs`; like that court, the two
      `[...]_vars`-subscripted temporal properties are excluded from the native
      cfg (tla-rs v0.11.1 cannot parse them) and remain pinned by the
      structural vocabulary legs + the pack cfg below;
    * Stateright witness court (cargo, dependency-free scratch build, mirrors
      `bin/durable-stateright`): the embedded vocabulary test compiles and
      passes — verdict agreement with the tla-rs court on the same rows.

  Checker availability semantics mirror `AshPPlan.Test.NativeTLA`: optional
  locally (named skip), mandatory under `ASH_PPLAN_REQUIRE_TLA=1`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Test.NativeTLA

  @root Path.expand("../..", __DIR__)
  @dir Path.join(@root, "priv/ggen/generated/protocol-court")
  @module_path Path.join(@dir, "JobLeaseProtocol.tla")
  @module File.read!(@module_path)
  @pack_cfg File.read!(Path.join(@dir, "JobLeaseProtocol.cfg"))
  @model_rs File.read!(Path.join(@dir, "stateright/model.rs"))
  @transitions_path Path.join(@dir, "JobLeaseProtocol_transitions.exs")
  @pack_ontology File.read!(
                   Path.join(@root, "priv/ggen/vendor/ash-pplan-protocol-court-pack/ontology.ttl")
                 )

  # tla-rs v0.11.1 cannot parse `[...]_vars` subscripted box properties (see
  # test/durable/native_tla_court_test.exs), so the native cfg carries the
  # invariant core + the leads-to property only.
  @native_cfg """
  SPECIFICATION Spec
  CONSTANTS Workers = {w1, w2}
  INVARIANT TypeOK
  INVARIANT ClaimExclusive
  INVARIANT NoDoubleEffect
  PROPERTY NoLostWakeup
  """

  # guard id => invariant/property whose counterexample must name the guard's failure
  @mutants %{
    "claim_free" => "ClaimExclusive",
    "record_once" => "NoDoubleEffect"
  }

  # ---- extraction helpers (real files, no mocks) ----------------------------

  defp rs_list(name) do
    re = ~r/pub const #{name}: &\[&str\] = &\[(.*?)\];/s

    case Regex.run(re, @model_rs, capture: :all_but_first) do
      [body] ->
        body
        |> String.replace("\"", "")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        flunk("model.rs is missing pub const #{name}")
    end
  end

  defp rs_guards do
    re = ~r/pub const GUARDS: &\[\(&str, &\[&str\]\)\] = &\[(.*?)\n\];/s

    case Regex.run(re, @model_rs, capture: :all_but_first) do
      [body] ->
        Regex.scan(~r/\("(\w+)", &\[(.*?)\]\)/s, body, capture: :all_but_first)
        |> Map.new(fn [action, guards] ->
          {action,
           guards
           |> String.replace("\"", "")
           |> String.split(",")
           |> Enum.map(&String.trim/1)
           |> Enum.reject(&(&1 == ""))}
        end)

      _ ->
        flunk("model.rs is missing pub const GUARDS")
    end
  end

  defp tla_set(name) do
    case Regex.run(~r/#{name} == \{(.*)\}/m, @module, capture: :all_but_first) do
      [body] ->
        body
        |> String.replace("\"", "")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.sort()

      _ ->
        flunk("TLA module is missing the #{name} definition")
    end
  end

  defp tla_guard_ids do
    Regex.scan(~r/\\\* guard:(\w+)/m, @module, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> MapSet.new()
  end

  defp ontology_statuses do
    Regex.scan(~r/pcp:s_(\w+) a pcp:State/, @pack_ontology, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ontology_transition_pairs do
    Regex.scan(
      ~r/pcp:t_\w+ a pcp:Transition ; pcp:machine pcp:runMachine ; pcp:from pcp:s_(\w+) ; pcp:to pcp:s_(\w+)/,
      @pack_ontology,
      capture: :all_but_first
    )
    |> Enum.map(&List.to_tuple/1)
    |> MapSet.new()
  end

  defp ontology_guards do
    Regex.scan(
      ~r/a pcp:Guard ; pcp:ofAction pcp:a_(\w+) ; pcp:guardId "(\w+)"/,
      @pack_ontology,
      capture: :all_but_first
    )
    |> Enum.map(fn [action, gid] -> {action, gid} end)
    |> Map.new(fn pair -> {pair, true} end)
    |> Map.keys()
    |> Enum.sort()
  end

  defp ontology_properties do
    Regex.scan(
      ~r/pcp:p_\w+ a pcp:Property ; pcp:machine pcp:runMachine ; rdfs:label "(\w+)"/,
      @pack_ontology,
      capture: :all_but_first
    )
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  defp ontology_mutants do
    Regex.scan(~r/pcp:mutantId "(\w+)"/, @pack_ontology, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  defp mutate(module, guard_id) do
    re = ~r/^  \/\\ .* \\\* guard:#{guard_id}$/m
    assert Regex.match?(re, module), "guard #{guard_id} absent from the generated module"
    Regex.replace(re, module, "  /\\ TRUE \\* guard:#{guard_id}")
  end

  # ---- leg 1: cross-projection vocabulary agreement (differential leg) ------

  describe "cross-projection vocabulary agreement" do
    test "statuses agree across ontology, TLA module, Stateright model and transition table" do
      onto = ontology_statuses()
      assert onto != [], "pack ontology declares no pcp:State rows"

      tla_statuses = tla_set("Statuses")
      assert Enum.sort(tla_statuses) == onto

      [rs_statuses, rs_terminal, rs_parked, rs_forward] =
        [
          Enum.sort(rs_list("STATUSES")),
          Enum.sort(rs_list("TERMINAL")),
          Enum.sort(rs_list("PARKED")),
          Enum.sort(rs_list("FORWARD"))
        ]

      assert rs_statuses == onto
      assert rs_terminal == tla_set("Terminal")
      assert rs_parked == tla_set("Parked")
      assert rs_forward == tla_set("Forward")

      {table, _} = Code.eval_file(@transitions_path)
      assert table[:protocol] == "JobLeaseProtocol"
      assert Enum.sort(Enum.map(table[:statuses], &to_string/1)) == onto
      assert Enum.sort(Enum.map(table[:terminal], &to_string/1)) == tla_set("Terminal")

      # every rendered status is declared by a pack ontology row
      for status <- onto do
        assert @pack_ontology =~ "pcp:s_#{status} a pcp:State"
      end
    end

    test "transition pairs agree between the ontology and the rendered table" do
      {table, _} = Code.eval_file(@transitions_path)

      onto_pairs =
        ontology_transition_pairs()
        |> Enum.map(fn {from, to} -> {String.to_atom(from), String.to_atom(to)} end)
        |> MapSet.new()

      table_pairs =
        table[:transitions]
        |> Enum.map(& &1)
        |> MapSet.new()

      assert onto_pairs == table_pairs,
             "transition pairs disagree between pack ontology and rendered table " <>
               "(onto-only: #{inspect(MapSet.difference(onto_pairs, table_pairs) |> MapSet.to_list())}, " <>
               "table-only: #{inspect(MapSet.difference(table_pairs, onto_pairs) |> MapSet.to_list())})"

      assert MapSet.size(onto_pairs) > 0
    end

    test "guards, properties and declared mutants agree across all projections" do
      onto_guards = ontology_guards()
      assert onto_guards != [], "pack ontology declares no pcp:Guard rows"

      rs = rs_guards()

      # ontology guard set == model.rs per-action guard set
      rs_pairs =
        rs
        |> Enum.flat_map(fn {action, gids} -> Enum.map(gids, &{action, &1}) end)
        |> Enum.sort()

      assert rs_pairs == onto_guards

      # every guard annotation present in the TLA module belongs to the
      # ontology set, and every ontology guard is annotated in the module
      annotated = tla_guard_ids()
      onto_gids = onto_guards |> Enum.map(&elem(&1, 1)) |> MapSet.new()

      assert MapSet.equal?(annotated, onto_gids),
             "guard annotations in the module disagree with the ontology: " <>
               "annotated-only=#{inspect(MapSet.difference(annotated, onto_gids) |> MapSet.to_list())} " <>
               "ontology-only=#{inspect(MapSet.difference(onto_gids, annotated) |> MapSet.to_list())}"

      # properties: identical set in ontology, model.rs and the module body
      onto_props = ontology_properties()
      assert onto_props == Enum.sort(rs_list("PROPERTIES"))

      for p <- onto_props do
        assert @module =~ ~r/^#{p} == /m, "property #{p} missing from the TLA module"
      end

      # the pack cfg carries the temporal properties the native cfg must skip
      assert @pack_cfg =~ "PROPERTY TerminalAbsorbing"
      assert @pack_cfg =~ "PROPERTY CancelNeverOverwritten"

      # mutants: ontology pcp:Mutant rows == model.rs MUTANT_GUARD_DROPS,
      # and the court's own mutation table covers exactly the declared set
      # (a declared mutant with no court leg is an uncovered contract)
      onto_mutants = ontology_mutants()
      assert onto_mutants == Enum.sort(rs_list("MUTANT_GUARD_DROPS"))

      assert Enum.sort(Map.keys(@mutants)) == onto_mutants,
             "court mutation table does not cover exactly the declared mutants"

      for gid <- onto_mutants do
        assert MapSet.member?(annotated, gid)
      end
    end
  end

  # ---- leg 2: native tla-rs differential court ------------------------------

  describe "native tla-rs differential court" do
    test "original spec admitted with explored-state evidence" do
      case NativeTLA.availability() do
        :ok ->
          result = NativeTLA.check_string!("JobLeaseProtocol", @module, @native_cfg)
          assert result.verdict == :admitted
          assert result.kind == :no_error
          assert is_integer(result.stats.states) and result.stats.states > 0

          IO.puts("""
          [protocol-court] tla-rs v#{NativeTLA.version()} admitted JobLeaseProtocol
          [protocol-court] states: #{result.stats.states}, transitions: #{result.stats.transitions}, depth: #{result.stats.depth}
          """)

        {:unavailable, reason} ->
          IO.puts("[protocol-court] SKIP native court: #{reason}")
          assert true
      end
    end

    test "every declared mutant is refused with a counterexample (anti-vacuity)" do
      case NativeTLA.availability() do
        :ok ->
          for {gid, expected} <- @mutants do
            mutated = mutate(@module, gid)
            refute mutated == @module, "mutation of #{gid} produced identical bytes"

            result = NativeTLA.check_string!("JobLeaseProtocol", mutated, @native_cfg)

            assert result.verdict == :refused,
                   "mutant #{gid} was admitted — the differential court requires a counterexample"

            assert result.kind == :counterexample

            assert result.output =~ expected,
                   "mutant #{gid} counterexample does not name #{expected}"

            IO.puts(
              "[protocol-court] mutant #{gid} refused: #{expected} counterexample witnessed"
            )
          end

        {:unavailable, reason} ->
          IO.puts("[protocol-court] SKIP native court: #{reason}")
          assert true
      end
    end
  end

  # ---- leg 3: Stateright vocabulary witness (cargo) -------------------------

  test "Stateright witness: model.rs compiles and its vocabulary test passes" do
    cargo = System.find_executable("cargo")

    if cargo do
      scratch =
        Path.join(
          @root,
          "tmp/protocol-court-stateright-diff-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(scratch, "src"))

      File.write!(Path.join(scratch, "Cargo.toml"), """
      [package]
      name = "protocol-court-diff"
      version = "0.0.0"
      edition = "2021"

      # The `stateright` crate is intentionally absent (scope note mirrors
      # bin/durable-stateright): the witness compiles dependency-free.
      [workspace]
      """)

      File.write!(Path.join(scratch, "src/lib.rs"), @model_rs)

      on_exit(fn -> File.rm_rf!(scratch) end)

      {out, status} =
        System.cmd(cargo, ["test"], cd: scratch, stderr_to_stdout: true, env: [{"NO_COLOR", "1"}])

      assert status == 0, "cargo test failed on the generated model:\n#{out}"
      assert out =~ "test result: ok"

      IO.puts("[protocol-court] stateright witness: vocabulary test green (cargo)")
    else
      IO.puts("[protocol-court] SKIP stateright witness: cargo not on PATH")
      assert true
    end
  end
end
