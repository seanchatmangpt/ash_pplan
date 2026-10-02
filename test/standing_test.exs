defmodule AshPPlan.StandingTest do
  @moduledoc """
  Court for the `AshPPlan.Standing` library API over pure evidence (no mocks, no collaborators
  needed: the inputs are the evidence structs themselves).

  Covers: the verdict truth table (`verdict/3`), each layer's refusal, the receipt's five fields
  validated against the DfCM receipt schema (`~/.claude/dfcm/receipt.schema.json` when present,
  else the vendored copy under the standing pack, used as test data only), the broken term on
  refusal, and the receipt validator's refusals (each missing field names `R_missing_<field>`,
  a DO ceiling is refused).

  Anti-vacuity: the sealed-ledger digest changes when one ledger event changes, a tampered chain
  fails `Chain.verify/1`, and the schema validator itself rejects a receipt with a mutated
  field (a validator that accepts everything cannot pass the mutation test).
  """
  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Standing
  alias AshPPlan.Standing.{Chain, Receipt}

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  @model %{
    tasks: [
      %{id: :admit, depends_on: []},
      %{id: :pay, depends_on: [:admit]},
      %{id: :ship, depends_on: [:pay]}
    ]
  }
  @selection %{admit: :p1, pay: :p2, ship: :p3}
  @gates [%{task: "pay", admit: ["authorized"], successors: ["ship"]}]

  defp event(task, seq, provider, outcome \\ nil) do
    %Event{
      id: "run:r1/#{task}",
      activity: "task_succeeded",
      timestamp: ~U[2026-10-01 00:00:00Z],
      objects: [{"WorkflowRun", "run:r1", "run"}],
      attributes: %{task: task, seq: seq, provider: provider, outcome: outcome},
      subject_id: "subject-1"
    }
  end

  defp events(pay_outcome \\ "authorized") do
    [event("admit", 1, "p1"), event("pay", 2, "p2", pay_outcome), event("ship", 3, "p3")]
  end

  defp run(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "r1",
        repo: "ash_pplan",
        head: @head,
        base: @base,
        events: events(),
        model: @model,
        selection: @selection,
        fond_gates: @gates,
        execution: {%{pay: 1}, %{pay: 1}},
        consequence: [order_fulfilled: true, one_shipment: true],
        observation: %{shipments: 1}
      },
      overrides
    )
  end

  defp cmds, do: [%{cmd: "mix test test/standing_test.exs", cwd: File.cwd!(), exit: 0}]

  # ---- verdicts ----

  test "verdict/3 is the conjunction of the three layers, broken layers in order" do
    assert Standing.verdict(:ok, :ok, :ok) == :alive
    assert Standing.verdict({:error, 1}, :ok, :ok) == {:lost, [:plan_correct]}

    assert Standing.verdict(:ok, {:error, 1}, {:error, 2}) ==
             {:lost, [:execution_correct, :observed_consequence_correct]}

    assert Standing.verdict({:error, 1}, {:error, 2}, {:error, 3}) ==
             {:lost, Standing.layers()}
  end

  test "a conforming run is alive" do
    assert Standing.standing(run()) == :alive
  end

  test "each layer refuses its own falsifier and only its own" do
    wrong_provider = run(%{events: [event("admit", 1, "other") | tl(events())]})

    assert {:error, {:provider_not_selected, "admit", "other", :p1}} =
             Standing.plan_correct(wrong_provider)

    assert Standing.standing(wrong_provider) == {:lost, [:plan_correct]}

    reordered = run(%{events: [event("pay", 1, "p2", "authorized"), event("admit", 2, "p1")]})
    assert {:error, {:dependency_order, "pay"}} = Standing.plan_correct(reordered)

    outside = run(%{events: [event("ghost", 1, nil)]})
    assert {:error, {:task_outside_model, "ghost"}} = Standing.plan_correct(outside)

    declined_then_ship = run(%{events: events("declined")})

    assert {:error, {:inadmissible_path, :pay, "declined"}} =
             Standing.plan_correct(declined_then_ship)

    twice = run(%{execution: {%{pay: 2}, %{pay: 1}}})
    assert Standing.standing(twice) == {:lost, [:execution_correct]}

    no_shipment = run(%{consequence: [order_fulfilled: true, one_shipment: false]})
    assert {:error, [:one_shipment]} = Standing.observed_consequence_correct(no_shipment)
    assert Standing.standing(no_shipment) == {:lost, [:observed_consequence_correct]}
  end

  test "a run without evidence is refused, not vacuously alive" do
    assert {:lost, layers} = Standing.standing(%{})
    assert layers == Standing.layers()
  end

  # ---- receipt ----

  test "receipt: five fields, ALIVE, valid against the receipt schema" do
    assert {:ok, receipt} = Standing.receipt(run(), replay_commands: cmds())

    assert receipt.identity == %{
             subject: "subject-1",
             run_id: "r1",
             repo: "ash_pplan",
             subject_sha: @head,
             base_sha: @base
           }

    assert receipt.authority == %{ceiling: "CONSTRUCT", grant: "NONE", actor: "ash_pplan"}
    assert receipt.consequence.remote_effects == ["order_fulfilled=true", "one_shipment=true"]
    assert receipt.consequence.observed == %{shipments: 1}
    assert receipt.replay.ledger_digest =~ ~r/^[0-9a-f]{64}$/
    assert receipt.replay.evidence.ocel2_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert receipt.replay.evidence.ex4pm in ["valid", "invalid", "unsupported"]
    assert receipt.standing.value == "ALIVE"
    refute Map.has_key?(receipt.standing, :broken_term)

    assert [] == schema_errors(full(receipt))
  end

  test "receipt of a refused run carries the broken term and is schema-valid" do
    bad = run(%{execution: {%{pay: 2}, %{pay: 1}}})
    assert {:ok, receipt} = Standing.receipt(bad, replay_commands: cmds())
    assert receipt.standing.value == "REFUSED(execution_correct)"
    assert receipt.standing.broken_term == "mu_unlawful"
    assert [] == schema_errors(full(receipt))
  end

  test "each missing field is refused with its R_missing term" do
    assert {:error, %{broken_term: "R_missing_identity"}} =
             Standing.receipt(run(%{run_id: nil}), replay_commands: cmds())

    assert {:error, %{broken_term: "R_missing_authority", reason: {:do_ceiling_unleased, "DO"}}} =
             Standing.receipt(run(), replay_commands: cmds(), ceiling: "DO")

    assert {:error, %{broken_term: "R_missing_consequence"}} =
             Standing.receipt(run(%{consequence: nil}), replay_commands: cmds())

    assert {:error, %{broken_term: "R_missing_replay"}} = Standing.receipt(run())

    assert {:error, %{broken_term: "R_missing_replay"}} =
             Standing.receipt(run(%{events: [], subject_id: "subject-1"}),
               replay_commands: cmds()
             )

    assert {:error, %{broken_term: "R_missing_standing"}} =
             Receipt.validate(%Receipt{
               identity: %{subject: "s", run_id: "r"},
               authority: %{ceiling: "CONSTRUCT", grant: "NONE", actor: "a"},
               consequence: %{commits: [], files_changed: [], remote_effects: []},
               replay: %{commands: cmds(), ledger_digest: "d"}
             })
  end

  test "evidence: false drops the process-evidence digest" do
    assert {:ok, receipt} = Standing.receipt(run(), replay_commands: cmds(), evidence: false)
    assert receipt.replay.evidence == %{}
  end

  # ---- anti-vacuity ----

  test "the ledger digest binds the events: change one event, the digest changes" do
    {:ok, a} = Standing.receipt(run(), replay_commands: cmds())

    changed =
      run(%{
        events:
          [event("admit", 1, "p1") | tl(events())]
          |> List.update_at(2, &%{&1 | id: "run:r1/other"})
      })

    {:ok, b} = Standing.receipt(changed, replay_commands: cmds())
    refute a.replay.ledger_digest == b.replay.ledger_digest
  end

  test "Chain: pending/outcome/seal discipline and tamper detection" do
    {:ok, c} = Chain.append_pending([], "p1", "s", "act")

    assert {:error, :outcome_without_pending} =
             Chain.append_outcome(c, "o1", "ALIVE", "s", "other")

    assert {:error, :unpaired_pending} = Chain.seal(c, "seal", "ALIVE", "s")
    {:ok, c} = Chain.append_outcome(c, "o1", "ALIVE", "s", "act")
    {:ok, c} = Chain.seal(c, "seal", "ALIVE", "s")
    assert Chain.verify(c)
    assert {:error, :sealed} = Chain.append_pending(c, "p2", "s", "act")

    tampered = List.update_at(c, 1, &%{&1 | standing: "REFUSED"})
    refute Chain.verify(tampered)
  end

  # ---- adopted gates: seal-once + parent-hash closure (evidence-standing-pack) ----

  defp sealed_chain do
    {:ok, c} = Chain.append_pending([], "p1", "s", "act")
    {:ok, c} = Chain.append_outcome(c, "o1", "ALIVE", "s", "act")
    {:ok, c} = Chain.seal(c, "seal", "ALIVE", "s")
    c
  end

  test "gate seal-once: every append path refuses after the seal" do
    c = sealed_chain()
    assert Chain.verify(c)
    assert {:error, :sealed} = Chain.append_pending(c, "p2", "s", "act")
    assert {:error, :sealed} = Chain.append_outcome(c, "o2", "ALIVE", "s", "act")
    assert {:error, :already_sealed} = Chain.seal(c, "seal-2", "ALIVE", "s")
  end

  test "gate seal-once: a hand-built double-seal chain fails verify even bypassing the API" do
    c = sealed_chain()
    second_seal = %{c |> List.last() |> Map.put(:entry_id, "seal-2") | hash: nil}

    forged =
      second_seal
      |> Map.put(:parent_hash, Chain.head(c))
      |> Map.put(:hash, Chain.digest(Chain.canonical(second_seal)))

    refute Chain.verify(c ++ [forged])
  end

  test "gate parent-hash closure: every entry's parent is the previous head, root is genesis" do
    c = sealed_chain()
    assert hd(c).parent_hash == Chain.genesis()

    for [prev, next] <- Enum.chunk_every(c, 2, 1, :discard) do
      assert next.parent_hash == prev.hash
    end
  end

  test "gate parent-hash closure: a self-consistent chain with a broken link fails verify" do
    c = sealed_chain()

    # forge: recompute every hash over a chain whose seal points at a bogus parent,
    # so hash recomputation alone cannot catch it -- only the parent==prev check can
    forged =
      List.update_at(c, 2, fn seal ->
        e = %{seal | parent_hash: String.duplicate("d", 64)}
        Map.put(e, :hash, Chain.digest(Chain.canonical(e)))
      end)

    assert Chain.digest(Chain.canonical(List.last(forged))) == Chain.head(forged),
           "precondition: every forged hash is self-consistent"

    refute Chain.verify(forged)
  end

  test "gate parent-hash closure: tampering any entry fails verify (parent-hash byte, seal subject)" do
    c = sealed_chain()

    # break one byte of a middle entry's parent hash
    tampered_ref = List.update_at(c, 1, &%{&1 | parent_hash: String.duplicate("0", 64)})
    refute Chain.verify(tampered_ref)

    # flip the seal entry's subject: recompute binds it, verify must refuse
    tampered_seal = List.update_at(c, 2, &%{&1 | subject: "s2"})
    refute Chain.verify(tampered_seal)

    # every entry's stored hash is bound to its canonical bytes, so any edit flips verify
    tampered_mid = List.update_at(c, 0, &%{&1 | action: "act2"})
    refute Chain.verify(tampered_mid)

    # any one-byte field edit anywhere propagates: flip the seal entry's subject
    tampered_seal = List.update_at(c, 2, &%{&1 | subject: "s2"})
    refute Chain.verify(tampered_seal)
  end

  test "the schema validator rejects mutated receipts" do
    {:ok, receipt} = Standing.receipt(run(), replay_commands: cmds())
    good = full(receipt)
    assert [] == schema_errors(good)

    refute [] == schema_errors(put_in(good, ["identity", "subject_sha"], "not-a-sha"))
    refute [] == schema_errors(put_in(good, ["authority", "ceiling"], "ROOT"))
    refute [] == schema_errors(put_in(good, ["standing", "value"], "MAYBE"))
    refute [] == schema_errors(Map.delete(good, "replay"))

    refused = put_in(good, ["standing", "value"], "REFUSED(plan_correct)")
    refute [] == schema_errors(refused), "REFUSED without broken_term must fail the schema"
  end

  # ---- ladder ----

  alias AshPPlan.Standing.Ladder

  test "a fully evidenced run climbs to VERIFIED with a single-rung audit trail" do
    assert {:ok, %{state: :VERIFIED, index: 9, trail: trail}} = Standing.ladder(run(), replay_commands: cmds())
    assert Enum.map(trail, & &1.to) == Ladder.states() |> tl()
    assert Enum.map(trail, & &1.order) == Enum.to_list(1..9)

    assert Enum.all?(trail, fn t ->
             is_binary(t.evidence) and t.evidence != ""
           end)

    assert hd(trail) == %{from: :UNKNOWN, to: :OBSERVED, evidence: "process_evidence events=3", order: 1}
    assert List.last(trail).evidence =~ ~r/ocel2_sha256 [0-9a-f]{64}$/
  end

  test "each rung is exactly one step from the previous trail entry" do
    {:ok, %{trail: trail}} = Standing.ladder(run(), replay_commands: cmds())

    for {t, i} <- Enum.with_index(trail, 1) do
      expected_from = if i == 1, do: :UNKNOWN, else: Enum.at(trail, i - 2).to
      assert t.from == expected_from
      assert Ladder.index(t.to) == Ladder.index(t.from) + 1
    end
  end

  test "promotion stops at the first rung not derivable from real inputs" do
    # No consequence checks: CANDIDATE is not derivable, so promotion stops at DERIVED.
    assert {:ok, %{state: :DERIVED, index: 3, trail: trail}} = Standing.ladder(run(%{consequence: nil}))
    assert length(trail) == 3

    # Empty events: not even OBSERVED.
    assert {:ok, %{state: :UNKNOWN, index: 0, trail: []}} =
             Standing.ladder(run(%{events: [], subject_id: "subject-1"}))

    # A refused execution stops the climb at VALIDATED.
    twice = run(%{execution: {%{pay: 2}, %{pay: 1}}})
    assert {:ok, %{state: :VALIDATED, index: 2}} = Standing.ladder(twice)
  end

  test "an illegal transition is refused by the ladder law (no skipped rungs)" do
    skip =
      Ladder.admit(%{
        fact: "run:r1",
        state: :ADMITTED,
        transitions: [
          %{from: :UNKNOWN, to: :OBSERVED, evidence: "3 events"},
          %{from: :OBSERVED, to: :ADMITTED, evidence: "skipped eight rungs"}
        ]
      })

    assert {:error, %{broken_term: "STL_missing_rung", missing_rung_index: 2}} = skip
  end

  test "the ladder law refuses an empty evidence reference and a dangling fact" do
    assert {:error, %{broken_term: "STL_missing_rung", missing_rung_index: 1}} =
             Ladder.admit(%{
               fact: "run:r1",
               state: :OBSERVED,
               transitions: [%{from: :UNKNOWN, to: :OBSERVED, evidence: " "}]
             })

    assert {:error, %{broken_term: "STL_dangling_fact"}} =
             Ladder.admit(%{fact: nil, state: :UNKNOWN, transitions: []})

    assert {:error, %{broken_term: "STL_unknown_state"}} = Ladder.index(:ALIVE)
  end

  test "the derived trail re-admits under the ladder law when it reaches ADMITTED" do
    {:ok, %{trail: trail}} = Standing.ladder(run(), replay_commands: cmds())

    transitions = Enum.map(trail, &Map.take(&1, [:from, :to, :evidence]))

    assert {:ok, %{state: :ADMITTED}} =
             Ladder.admit(%{fact: "run:r1", state: :ADMITTED, transitions: transitions})
  end

  # ---- schema support ----

  defp full(receipt) do
    Map.merge(Receipt.to_map(receipt), %{
      "work_order_id" => "wo-1",
      "origin_authority" => %{"ceiling" => "CONSTRUCT", "grant" => "NONE", "actor" => "ash_pplan"},
      "provider" => %{"name" => "ash_pplan_standing"},
      "provider_execution_id" => "r1"
    })
  end

  defp schema do
    home = Path.expand("~/.claude/dfcm/receipt.schema.json")

    vendored =
      Path.join(
        File.cwd!(),
        "priv/ggen/ash-pplan-standing-pack/qualification-receipt.schema.json"
      )

    if(File.exists?(home), do: home, else: vendored) |> File.read!() |> Jason.decode!()
  end

  defp schema_errors(doc), do: validate(schema(), doc, "$")

  # Minimal JSON-schema subset: type, required, properties, items, enum, pattern, minLength,
  # minItems, allOf/if/then (the constructs receipt.schema.json uses).
  defp validate(s, v, path) do
    List.flatten([
      type_errors(s["type"], v, path),
      enum_errors(s["enum"], v, path),
      pattern_errors(s["pattern"], v, path),
      min_length_errors(s["minLength"], v, path),
      min_items_errors(s["minItems"], v, path),
      required_errors(s["required"], v, path),
      property_errors(s["properties"], v, path),
      item_errors(s["items"], v, path),
      Enum.map(s["allOf"] || [], &conditional(&1, v, path))
    ])
  end

  defp type_errors("object", v, _) when is_map(v), do: []
  defp type_errors("array", v, _) when is_list(v), do: []
  defp type_errors("string", v, _) when is_binary(v), do: []
  defp type_errors("integer", v, _) when is_integer(v), do: []
  defp type_errors(nil, _, _), do: []
  defp type_errors(t, _, path), do: ["#{path}: not a #{t}"]

  defp enum_errors(nil, _, _), do: []

  defp enum_errors(e, v, path),
    do: if(v in e, do: [], else: ["#{path}: #{inspect(v)} not in enum"])

  defp pattern_errors(p, v, path) when is_binary(p) and is_binary(v),
    do: if(Regex.match?(Regex.compile!(p), v), do: [], else: ["#{path}: #{inspect(v)} !~ #{p}"])

  defp pattern_errors(_, _, _), do: []

  defp min_length_errors(n, v, path) when is_integer(n) and is_binary(v),
    do: if(String.length(v) >= n, do: [], else: ["#{path}: too short"])

  defp min_length_errors(_, _, _), do: []

  defp min_items_errors(n, v, path) when is_integer(n) and is_list(v),
    do: if(length(v) >= n, do: [], else: ["#{path}: too few items"])

  defp min_items_errors(_, _, _), do: []

  defp required_errors(req, v, path) when is_list(req) and is_map(v),
    do: for(k <- req, not Map.has_key?(v, k), do: "#{path}: missing #{k}")

  defp required_errors(_, _, _), do: []

  defp property_errors(props, v, path) when is_map(props) and is_map(v),
    do: for({k, sub} <- props, Map.has_key?(v, k), do: validate(sub, v[k], path <> "." <> k))

  defp property_errors(_, _, _), do: []

  defp item_errors(sub, v, path) when is_map(sub) and is_list(v),
    do: v |> Enum.with_index() |> Enum.map(fn {x, i} -> validate(sub, x, "#{path}[#{i}]") end)

  defp item_errors(_, _, _), do: []

  defp conditional(%{"if" => c, "then" => t}, v, path) do
    if validate(c, v, path) == [], do: validate(t, v, path), else: []
  end

  defp conditional(_, _, _), do: []
end
