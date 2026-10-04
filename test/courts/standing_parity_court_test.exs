defmodule AshPPlan.StandingParityCourtTest do
  @moduledoc """
  Standing-parity court: the standing ladder law is hand-restated in Elixir
  (`lib/ash_pplan/standing/ladder.ex`, `chain.ex`) while the vendored
  evidence-standing-pack carries the same invariants as SPARQL gates. This
  court makes the drift visible, invariant by invariant.

  ## Overlap table (gate <-> Elixir)

  | gate                              | Elixir counterpart | standing |
  |---|---|---|
  | 020_seal_once.unbound.rq                  | `Chain.verify/1` seal-count clause; `seal/4` `{:error, :already_sealed}` | PARITY |
  | 030_parent_hash_closure.unbound.rq        | `Chain.verify/1` `parent_hash == prev` + `hash == digest(canonical(e))` | PARITY |
  | 060_outcome_requires_pending.unbound.rq   | `append_outcome/5` `:outcome_without_pending`; verify's pending-pairing branch (same action, no double use) | PARITY |
  | 065_standing_only_on_outcome.unbound.rq   | `append_pending/4` forces `@neutral`; verify's pending `standing == @neutral` clause | PARITY |
  | 070_unpaired_pending.unbound.rq           | `seal/4` `{:error, :unpaired_pending}`; verify's seal branch `all seen used` | PARITY |
  | 040_algorithm_supported_set.unbound.rq    | PARTIAL: Elixir compiles in exactly one algorithm (`sha256`) with no runtime negotiation at all; the gate's policy/language dimension has no Elixir counterpart | DRIFT (partial) |
  | 010_no_receipt_no_standing.unbound.rq     | NONE: no Elixir module requires an authorized `es:Receipt` behind a standing claim; `Ladder.admit/1` requires per-rung non-empty evidence refs, a weaker, different invariant | DRIFT |
  | 050_literal_scan.py               | NONE: template-hygiene gate, no Elixir counterpart | DRIFT |

  Elixir-only invariants with no pack gate (drift, other direction):

  | Elixir invariant | pack gate |
  |---|---|
  | `Ladder.admit/1` single-rung transition chain from `:UNKNOWN` (`stl:` vocabulary) | none |
  | `Ladder.index/1` refusal `STL_unknown_state` outside the closed 10-state set | none |
  | failure standings must carry `sg:brokenTerm` (C5 pack, `sg:` vocabulary) | none in the vendor pack |

  The C5 fixtures under `priv/ggen/ash-pplan-standing-pack/verify/fixtures/`
  speak the `sg:`/`stl:` vocabulary of that pack's own gates, NOT the vendor
  pack's `es:` vocabulary, so they do not express the same invariants for these
  gates; this court builds its own fixtures in-test, projected from real
  `AshPPlan.Standing.Chain` output.

  Method: for each parity case the court builds a real Elixir chain (or a
  deliberately corrupted mutation of one), serializes the same entries into the
  vendor pack's `es:` graph, runs each overlapping gate via
  `GgenIgniter.Query.Oxigraph.run/2` over pack ontology + fixture, and asserts
  the gate's flagged set matches the Elixir verdict (`Chain.verify/1`, plus the
  constructor refusals).

  Parity cases: 1 clean + 5 corrupted chains (double seal, parent-hash mismatch,
  orphan outcome, cross-chain pendingRef, non-neutral pending standing, unpaired
  pending at seal), plus Elixir-side typed-refusal witnesses covering the
  "untyped refusal / missing brokenTerm" corruption class the vendor gates do
  not encode.
  """

  use ExUnit.Case, async: true

  @pack Path.expand("priv/ggen/vendor/evidence-standing-pack", File.cwd!())
  @c5_fixtures Path.expand("priv/ggen/ash-pplan-standing-pack/verify/fixtures", File.cwd!())
  @ladder_path Path.expand("lib/ash_pplan/standing/ladder.ex", File.cwd!())
  @c5_gates Path.expand("priv/ggen/ash-pplan-standing-pack/gates", File.cwd!())

  @overlap_gates [
    "020_seal_once.rq",
    "030_parent_hash_closure.rq",
    "060_outcome_requires_pending.rq",
    "065_standing_only_on_outcome.rq",
    "070_unpaired_pending.rq"
  ]

  @drift_gates [
    "010_no_receipt_no_standing.rq",
    "040_algorithm_supported_set.rq",
    "050_literal_scan.py"
  ]

  @elixir_only [
    {"Ladder.admit/1 single-rung transition chain from :UNKNOWN", @ladder_path},
    {"Ladder.index/1 STL_unknown_state refusal outside the closed 10-state set", @ladder_path},
    {"failure standings must carry sg:brokenTerm (C5 pack, sg: vocabulary)", @c5_gates}
  ]

  # Re-homed offender gates carrying both-way witnesses (all but the script
  # gate 050_literal_scan.py, which has no .ttl fixtures).
  @witnessed_gates @overlap_gates ++
                     ["010_no_receipt_no_standing.rq", "040_algorithm_supported_set.rq"]

  # ---------------------------------------------------------------------------
  # Real Elixir chains and their corruptions
  # ---------------------------------------------------------------------------

  defp clean_chain do
    {:ok, chain} =
      AshPPlan.Standing.Chain.build_sealed(
        [{"ev-1", "task-a"}, {"ev-2", "task-b"}],
        "seal-1",
        "ALIVE",
        "subject-1"
      )

    chain
  end

  defp rehash(entry),
    do:
      Map.put(
        entry,
        :hash,
        AshPPlan.Standing.Chain.digest(AshPPlan.Standing.Chain.canonical(entry))
      )

  # After a content mutation, re-thread parent_hash/hash (and any pending_ref
  # that pointed at a now-rehashed entry) so the ONLY broken invariant is the
  # one the case is about. Reference structure is preserved positionally from
  # the ORIGINAL chain. Cases that deliberately break the parent linkage skip
  # this.
  defp relink(original, mutated) do
    hash_to_idx =
      original
      |> Enum.with_index()
      |> Map.new(fn {e, i} -> {e.hash, i} end)

    {rel, _} =
      Enum.map_reduce(mutated, [], fn e, acc ->
        parent =
          case acc do
            [] -> AshPPlan.Standing.Chain.genesis()
            [prev | _] -> prev.hash
          end

        e = Map.put(e, :parent_hash, parent)

        e =
          with true <- e.pending_ref != "",
               idx when is_integer(idx) <- Map.get(hash_to_idx, e.pending_ref) do
            Map.put(e, :pending_ref, Enum.at(Enum.reverse(acc), idx).hash)
          else
            _ -> e
          end

        e = rehash(e)
        {e, [e | acc]}
      end)

    # map_reduce's LIST is already in forward order; only the ACC is reversed.
    rel
  end

  defp corrupted_chain(:double_seal) do
    chain = clean_chain()
    seal = List.last(chain)

    # The duplicate seal threads onto the FIRST seal; only gate 020 may fire.
    second = seal |> Map.put(:entry_id, "seal-2") |> Map.put(:parent_hash, seal.hash) |> rehash()
    chain ++ [second]
  end

  defp corrupted_chain(:parent_hash_mismatch) do
    clean_chain()
    |> List.update_at(1, &Map.put(&1, :parent_hash, String.duplicate("f", 64)))
  end

  # task-b's outcome loses its pending ref. The gate set legitimately co-fires:
  # 060 (orphan outcome) AND 070 (task-b's pending is left unpaired).
  defp corrupted_chain(:outcome_without_pending) do
    original = clean_chain()

    mutated =
      Enum.map(original, fn e ->
        if e.seal or e.action != "task-b",
          do: e,
          else: Map.put(e, :pending_ref, String.duplicate("0", 64))
      end)

    relink(original, mutated)
  end

  defp corrupted_chain(:non_neutral_pending) do
    original = clean_chain()

    mutated =
      Enum.map(original, fn e ->
        if e.phase == "pending", do: Map.put(e, :standing, "ALIVE"), else: e
      end)

    relink(original, mutated)
  end

  # seal/4 refuses :unpaired_pending, so the corruption is built by hand: an
  # extra open pending, then the original seal entry appended by mutation.
  defp corrupted_chain(:unpaired_pending) do
    original = clean_chain()
    unsealed = Enum.drop(original, -1)

    {:ok, with_pending} =
      AshPPlan.Standing.Chain.append_pending(unsealed, "p:ev-3", "subject-1", "task-c")

    relink(original, with_pending ++ [List.last(original)])
  end

  # Cross-chain pending ref: chain B's outcome references chain A's pending
  # hash. The Elixir side sees an unknown pending hash inside chain B.
  defp cross_chain do
    {:ok, a} = AshPPlan.Standing.Chain.build_sealed([{"ev-a", "task-a"}], "seal-a", "ALIVE", "s")
    {:ok, b} = AshPPlan.Standing.Chain.build_sealed([{"ev-b", "task-b"}], "seal-b", "ALIVE", "s")

    pending_a_hash = hd(a).hash

    mutated =
      Enum.map(b, fn e ->
        if e.pending_ref != "" and not e.seal,
          do: Map.put(e, :pending_ref, pending_a_hash),
          else: e
      end)

    {a, relink(b, mutated)}
  end

  # ---------------------------------------------------------------------------
  # es:-graph projection of a chain
  # ---------------------------------------------------------------------------

  @es "https://ggen.dev/ontology/evidence-standing#"
  @ex "http://example.org/parity#"

  defp graph_for_chain(chain, chain_id, overrides \\ %{}) do
    ontology = read_file(Path.join(@pack, "ontology.ttl"))
    ttl = entries_ttl(chain, chain_id, overrides)

    case RDF.Turtle.read_string(ttl) do
      {:ok, g} ->
        RDF.Data.merge(ontology, g)

      {:error, pos, reason} ->
        flunk("fixture turtle parse error at #{inspect(pos)}: #{inspect(reason)}\n#{ttl}")
    end
  end

  defp read_file(path) do
    case RDF.Turtle.read_file(path) do
      {:ok, g} ->
        g

      {:error, pos, reason} ->
        flunk("failed to parse #{path}: #{inspect(pos)} #{inspect(reason)}")
    end
  end

  # Serializes entries with parentEntry/pendingEntry links resolved by hash
  # inside the same chain. `overrides` lets a case point a pending ref at an
  # entry of a DIFFERENT chain (cross-chain corruption).
  defp entries_ttl(chain, chain_id, overrides) do
    by_hash = Map.new(Enum.with_index(chain, fn e, i -> {e.hash, i} end))

    entries =
      chain
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {e, i} -> entry_ttl(e, i, chain_id, by_hash, overrides) end)

    """
    @prefix es: <#{@es}> .
    @prefix ex: <#{@ex}> .

    #{entries}
    """
  end

  defp entry_ttl(e, i, chain_id, by_hash, overrides) do
    lines = [
      "ex:e#{i} a es:ChainEntry",
      ~s(es:chainId "#{chain_id}"),
      "es:chainPolicy es:DefaultChainPolicy",
      ~s(es:entryId "#{e.entry_id}"),
      ~s(es:entrySubject "#{e.subject}"),
      ~s(es:entryAction "#{e.action}"),
      ~s(es:parentHash "#{e.parent_hash}"),
      ~s(es:entryHash "#{e.hash}"),
      "es:entryPhase #{phase_iri(e.phase)}",
      "es:entryStanding #{standing_iri(e.standing)}"
    ]

    lines = if e.seal, do: lines ++ ["es:isSeal true"], else: lines

    lines =
      if i == 0 do
        lines
      else
        lines ++ ["es:parentEntry ex:e#{i - 1}"]
      end

    lines =
      cond do
        Map.has_key?(overrides, e.entry_id) ->
          lines ++ ["es:pendingEntry #{overrides[e.entry_id]}"]

        e.pending_ref != "" and Map.has_key?(by_hash, e.pending_ref) ->
          lines ++ ["es:pendingEntry ex:e#{by_hash[e.pending_ref]}"]

        e.pending_ref != "" ->
          # Deliberately dangling ref: kept as a literal so gate 060 sees a
          # missing pendingEntry.
          lines ++ [~s(es:pendingRef "#{e.pending_ref}")]

        true ->
          lines
      end

    Enum.join(lines, " ;\n") <> " .\n"
  end

  defp phase_iri("pending"), do: "es:PhasePending"
  defp phase_iri("outcome"), do: "es:PhaseOutcome"

  defp standing_iri(standing) do
    case standing do
      "UNKNOWN" -> "es:UNKNOWN"
      "ALIVE" -> "es:ALIVE"
      other -> flunk("no es: individual mapped for standing #{other}")
    end
  end

  # Re-homed per ECO-GATE-CONVENTION-DECISION (R0, 2026-10-04): all offender
  # gates live in verify/ as *.unbound.rq (script gate 050 keeps its name).
  defp gate_path("050_literal_scan.py"), do: Path.join(@pack, "verify/050_literal_scan.py")

  defp gate_path(stem) do
    name = String.replace_suffix(stem, ".rq", "")
    Path.join(@pack, "verify/#{name}.unbound.rq")
  end

  defp gate_rows(gate, graph) do
    query = File.read!(gate_path(gate))
    GgenIgniter.Query.Oxigraph.run(graph, query)
  end

  defp flagged(gate, graph), do: gate_rows(gate, graph) != []

  # ---------------------------------------------------------------------------
  # Court cases
  # ---------------------------------------------------------------------------

  describe "parity: clean chain" do
    @tag :standing_parity
    test "clean sealed chain passes all overlapping gates and Chain.verify/1" do
      chain = clean_chain()
      graph = graph_for_chain(chain, "run-clean")

      assert AshPPlan.Standing.Chain.verify(chain), "Elixir side must accept the clean chain"

      for gate <- @overlap_gates do
        refute flagged(gate, graph), "expected #{gate} to be SILENT on the clean chain"
      end
    end
  end

  describe "parity: corrupted chains" do
    @tag :standing_parity
    test "double seal: gate 020 flags, Elixir verify/1 refuses" do
      chain = corrupted_chain(:double_seal)
      graph = graph_for_chain(chain, "run-2seal")

      refute AshPPlan.Standing.Chain.verify(chain)
      assert flagged("020_seal_once.rq", graph)

      for gate <- @overlap_gates -- ["020_seal_once.rq"] do
        refute flagged(gate, graph), "unexpected #{gate} row"
      end
    end

    @tag :standing_parity
    test "parent-hash mismatch: gate 030 flags, Elixir verify/1 refuses" do
      chain = corrupted_chain(:parent_hash_mismatch)
      graph = graph_for_chain(chain, "run-badparent")

      refute AshPPlan.Standing.Chain.verify(chain)
      assert flagged("030_parent_hash_closure.rq", graph)

      for gate <- @overlap_gates -- ["030_parent_hash_closure.rq"] do
        refute flagged(gate, graph), "unexpected #{gate} row"
      end
    end

    @tag :standing_parity
    test "outcome without pending: gate 060 flags, Elixir refuses via verify/1 and append_outcome/5" do
      chain = corrupted_chain(:outcome_without_pending)
      graph = graph_for_chain(chain, "run-orphan-outcome")

      refute AshPPlan.Standing.Chain.verify(chain)
      assert flagged("060_outcome_requires_pending.rq", graph)

      {:ok, c} = AshPPlan.Standing.Chain.append_pending([], "p1", "s", "task")

      assert {:error, :outcome_without_pending} =
               AshPPlan.Standing.Chain.append_outcome(c, "o1", "ALIVE", "s", "other-task")

      # 070 legitimately co-fires: an orphaned outcome leaves its pending
      # unpaired. Everything else must stay silent.
      for gate <- @overlap_gates -- ["060_outcome_requires_pending.rq", "070_unpaired_pending.rq"] do
        refute flagged(gate, graph), "unexpected #{gate} row"
      end
    end

    @tag :standing_parity
    test "cross-chain pendingRef: gate 060 flags, Elixir verify/1 refuses" do
      {a, b} = cross_chain()
      a_graph = graph_for_chain(a, "chain-a")
      b_graph = graph_for_chain(b, "chain-b", %{"o:ev-b" => "ex:foreign-pending"})

      pending_a = hd(a)

      foreign_ttl = """
      @prefix es: <#{@es}> .
      @prefix ex: <#{@ex}> .
      ex:foreign-pending a es:ChainEntry ; es:chainId "chain-a" ; es:chainPolicy es:DefaultChainPolicy ;
        es:entryId "#{pending_a.entry_id}" ; es:entryPhase es:PhasePending ; es:entryStanding es:UNKNOWN ;
        es:parentHash "#{AshPPlan.Standing.Chain.genesis()}" .
      """

      {:ok, fg} = RDF.Turtle.read_string(foreign_ttl)
      b_graph = RDF.Data.merge(b_graph, fg)

      refute AshPPlan.Standing.Chain.verify(b), "chain B must refuse a pending_ref into chain A"

      assert flagged("060_outcome_requires_pending.rq", b_graph),
             "gate 060 must flag the cross-chain pending ref"

      # 070 legitimately co-fires: chain B's own pending is left unpaired by
      # the foreign reference.
      for gate <- @overlap_gates -- ["060_outcome_requires_pending.rq", "070_unpaired_pending.rq"] do
        refute flagged(gate, b_graph), "unexpected #{gate} row on chain B"
      end

      # Chain A itself remains clean in both worlds.
      assert AshPPlan.Standing.Chain.verify(a)
      for gate <- @overlap_gates, do: refute(flagged(gate, a_graph))
    end

    @tag :standing_parity
    test "non-neutral standing on a pending: gate 065 flags, Elixir verify/1 refuses" do
      chain = corrupted_chain(:non_neutral_pending)
      graph = graph_for_chain(chain, "run-badpending")

      refute AshPPlan.Standing.Chain.verify(chain)
      assert flagged("065_standing_only_on_outcome.rq", graph)

      assert {:error, :sealed} =
               AshPPlan.Standing.Chain.append_pending(clean_chain(), "p-late", "s", "task")

      for gate <- @overlap_gates -- ["065_standing_only_on_outcome.rq"] do
        refute flagged(gate, graph), "unexpected #{gate} row"
      end
    end

    @tag :standing_parity
    test "unpaired pending at seal: gate 070 flags, Elixir seal/4 and verify/1 refuse" do
      chain = corrupted_chain(:unpaired_pending)
      graph = graph_for_chain(chain, "run-unpaired")

      refute AshPPlan.Standing.Chain.verify(chain)
      assert flagged("070_unpaired_pending.rq", graph)

      {:ok, c} = AshPPlan.Standing.Chain.append_pending([], "p1", "s", "task")
      {:ok, c} = AshPPlan.Standing.Chain.append_pending(c, "p2", "s", "task")
      {:ok, c} = AshPPlan.Standing.Chain.append_outcome(c, "o1", "ALIVE", "s", "task")
      assert {:error, :unpaired_pending} = AshPPlan.Standing.Chain.seal(c, "s1", "ALIVE", "s")

      for gate <- @overlap_gates -- ["070_unpaired_pending.rq"] do
        refute flagged(gate, graph), "unexpected #{gate} row"
      end
    end
  end

  describe "anti-vacuity" do
    @tag :standing_parity
    test "flipping the Elixir pending-neutral invariant makes gate and Elixir disagree" do
      # Test-local copy of the 065 invariant (pending carries only the neutral
      # standing) REMOVED from a minimal verify. The fixture graph is unchanged.
      lenient_verify = fn chain ->
        {checks, _} =
          Enum.map_reduce(chain, nil, fn e, prev ->
            parent_ok =
              (prev && e.parent_hash == prev) ||
                e.parent_hash == AshPPlan.Standing.Chain.genesis()

            hash_ok =
              e.hash == AshPPlan.Standing.Chain.digest(AshPPlan.Standing.Chain.canonical(e))

            ref_ok =
              cond do
                e.phase == "pending" -> e.pending_ref == ""
                true -> true
              end

            {parent_ok and hash_ok and ref_ok, e.hash}
          end)

        Enum.all?(checks)
      end

      chain = corrupted_chain(:non_neutral_pending)
      graph = graph_for_chain(chain, "run-antivac")

      gate_refuses = flagged("065_standing_only_on_outcome.rq", graph)
      elixir_refuses = not AshPPlan.Standing.Chain.verify(chain)
      flipped_refuses = not lenient_verify.(chain)

      assert gate_refuses, "gate 065 must flag the corrupted chain"
      assert elixir_refuses, "real Elixir verify/1 must refuse the corrupted chain"

      # With the invariant flipped, gate and (lenient) Elixir side DISAGREE --
      # i.e. the parity assertion would fail, which is exactly what this court
      # exists to catch.
      refute gate_refuses == flipped_refuses,
             "parity held under a flipped invariant -- the court is vacuous"
    end
  end

  # ---------------------------------------------------------------------------
  # Both-way witness validation for the re-homed offender gates
  # (ECO-GATE-CONVENTION-DECISION R0: offender convention = 0 rows on the
  # pass fixture, >= 1 row on the fail fixture)
  # ---------------------------------------------------------------------------

  describe "both-way witness validation (offender convention)" do
    for gate <- @witnessed_gates do
      @tag :standing_parity
      test "witnesses for #{gate}: pass fixture silent, fail fixture fires" do
        stem = String.replace_suffix(unquote(gate), ".rq", "")

        graph_of = fn dir ->
          ontology = read_file(Path.join(@pack, "ontology.ttl"))
          fixture = read_file(Path.join(@pack, "witnesses/#{dir}/#{stem}.ttl"))
          RDF.Data.merge(ontology, fixture)
        end

        assert gate_rows(unquote(gate), graph_of.("pass")) == [],
               "pass witness #{stem}.ttl must be silent"

        assert gate_rows(unquote(gate), graph_of.("fail")) != [],
               "fail witness #{stem}.ttl did not fire the re-homed gate"
      end
    end
  end

  describe "ladder typed refusals (Elixir-only; no vendor gate counterpart -- drift)" do
    @tag :standing_parity
    test "every Ladder refusal carries a broken_term (no untyped refusal / no missing brokenTerm)" do
      alias AshPPlan.Standing.{Ladder, Chain}

      unknown_state = %{
        fact: "f",
        state: :GHOST_STATE,
        transitions: [%{from: :UNKNOWN, to: :GHOST_STATE, evidence: "receipts/x.json"}]
      }

      assert {:error, %{broken_term: "STL_unknown_state"}} = Ladder.admit(unknown_state)

      dangling = %{fact: nil, state: :OBSERVED, transitions: []}
      assert {:error, %{broken_term: "STL_dangling_fact"}} = Ladder.admit(dangling)

      malformed = %{"no" => "ladder claim shape"}
      assert {:error, %{broken_term: "STL_malformed_claim"}} = Ladder.admit(malformed)

      skipped = %{
        fact: "f",
        state: :VALIDATED,
        transitions: [
          %{from: :UNKNOWN, to: :OBSERVED, evidence: "a.json"},
          %{from: :OBSERVED, to: :EXPERIMENTALLY_SUPPORTED, evidence: "b.json"}
        ]
      }

      assert {:error, %{broken_term: "STL_missing_rung", missing_rung_index: 2}} =
               Ladder.admit(skipped)

      # The chain layer's typed refusal classes, witnessed for the same reason.
      assert {:error, :already_sealed} = Chain.seal(clean_chain(), "s2", "ALIVE", "s")
      assert {:error, :bad_phase_or_standing} = Chain.append_outcome([], "o", "GARBAGE", "s", "t")
    end
  end

  describe "documented drift rows" do
    @tag :standing_parity
    test "drift table matches the real files on disk" do
      # Vendor gates with no (full) Elixir counterpart exist on disk.
      for gate <- @drift_gates do
        assert File.exists?(gate_path(gate)), "missing drift-row gate #{gate}"
      end

      # Elixir-only invariants live where the table says they do.
      for {_name, path} <- @elixir_only do
        assert File.exists?(path), "missing drift-row path #{path}"
      end

      # C5 fixtures speak sg:/stl:, not the vendor es: vocabulary -- the reason
      # this court builds its own fixtures.
      c5 = File.read!(Path.join(@c5_fixtures, "violating.ttl"))
      refute c5 =~ @es, "C5 fixtures unexpectedly use the vendor es: vocabulary"
      assert c5 =~ "https://w3id.org/ash-pplan/standing#"
    end

    @tag :standing_parity
    test "partial overlap (gate 040): algorithm set has an Elixir witness, language dimension does not" do
      # Elixir witness for the algorithm half of gate 040: the compiled-in
      # algorithm is sha256 and it really digests. There is no runtime
      # algorithm negotiation at all on the Elixir side (drift, not a bug).
      assert AshPPlan.Standing.Chain.algorithm() == "sha256"
      assert is_binary(AshPPlan.Standing.Chain.digest("x"))

      # The gate half that runs: shipped policy/language pairs are all inside
      # the supported set -- zero rows.
      graph = read_file(Path.join(@pack, "ontology.ttl"))
      refute flagged("040_algorithm_supported_set.rq", graph)

      # The language dimension (a policy targeting a language its algorithm
      # cannot support) has no Elixir counterpart: pure drift, gate-only.
      drift_ttl = """
      @prefix es: <#{@es}> .
      es:BrokenPolicy a es:ChainPolicy ;
        es:hashAlgorithm es:Blake2b256 ;
        es:targetLanguage es:LangEx .
      """

      {:ok, dg} = RDF.Turtle.read_string(drift_ttl)
      assert flagged("040_algorithm_supported_set.rq", RDF.Data.merge(graph, dg))
    end
  end
end
