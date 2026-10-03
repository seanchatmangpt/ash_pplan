defmodule AshPPlan.Standing.SjBridgeCourtTest do
  @moduledoc """
  SjBridge Court. Falsifies: a bridge map whose standing value falls outside the
  closed receipt vocabulary, a terminal predicate wider than the exact `BLOCKED`
  singleton, family mixing (an sj status doubling as a ladder rung or vice
  versa), a trail that the ladder's own admission gate would refuse, and the
  core law that a status never lifts a rung (`ALIVE` over an unevidenced run
  keeps rung `:UNKNOWN`). Anti-vacuity mutations: an unknown status base, a bare
  `REFUSED`, and an unknown layer must each be refused with their named reason;
  a standing map that Receipt.validate/1 would reject cannot pass.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Standing.{Ladder, Receipt}
  alias AshPPlan.Standing.SjBridge

  @statuses [
    "ALIVE",
    "BLOCKED",
    "BUILD_BROKEN",
    "PARTIAL_ALIVE",
    "REFUSED",
    "UNKNOWN",
    "UNSUPPORTED"
  ]

  # ---- real inputs for map/3 (no collaborators to fake: the run IS the evidence) ----

  @model %{
    tasks: [
      %{id: :admit, depends_on: []},
      %{id: :pay, depends_on: [:admit]},
      %{id: :ship, depends_on: [:pay]}
    ]
  }
  @selection %{admit: :p1, pay: :p2, ship: :p3}

  defp event(task, seq, provider) do
    %Event{
      id: "run:r1/#{task}",
      activity: "task_succeeded",
      timestamp: ~U[2026-10-01 00:00:00Z],
      objects: [{"WorkflowRun", "run:r1", "run"}],
      attributes: %{task: task, seq: seq, provider: provider, outcome: nil},
      subject_id: "subject-1"
    }
  end

  defp evidenced_run do
    %{
      run_id: "r1",
      repo: "ash_pplan",
      head: String.duplicate("a", 40),
      base: String.duplicate("b", 40),
      events: [event("admit", 1, "p1"), event("pay", 2, "p2"), event("ship", 3, "p3")],
      model: @model,
      selection: @selection,
      execution: {%{pay: 1}, %{pay: 1}},
      consequence: [order_fulfilled: true],
      observation: %{shipments: 1}
    }
  end

  defp cmds,
    do: [%{cmd: "mix test test/standing/sj_bridge_court_test.exs", cwd: File.cwd!(), exit: 0}]

  # ---- statuses / terminal ----

  test "statuses/0 is the 7 closed bases, alphabetical" do
    assert SjBridge.statuses() == @statuses
    assert SjBridge.statuses() == Enum.sort(SjBridge.statuses())
    assert @statuses == Receipt.standings()
  end

  test "terminal? is exactly the BLOCKED singleton" do
    for s <- SjBridge.statuses() do
      assert SjBridge.terminal?(s) == (s == "BLOCKED")
    end

    refute SjBridge.terminal?("ALIVE")
    assert SjBridge.terminal_outcomes() == ["BLOCKED"]
  end

  # ---- map/2: value family ----

  # `REFUSED` never maps bare (that is the requires-layers refusal), so the
  # all-status loops substitute its layered form.
  defp value("REFUSED"), do: "REFUSED(plan_correct)"
  defp value(s), do: s

  test "all 7 statuses map ok; value base is in Receipt.standings/0" do
    for s <- SjBridge.statuses() do
      assert {:ok, m} = SjBridge.map(value(s), [])

      assert %{
               status: status,
               base: base,
               layers: layers,
               standing: %{
                 value: standing_value,
                 derived_from: derived_from,
                 broken_term: broken_term
               },
               terminal?: terminal?
             } = m

      assert status == value(s)

      assert base == s
      assert base in Receipt.standings()
      assert layers == if(s == "REFUSED", do: [:plan_correct], else: [])

      if s == "REFUSED" do
        assert standing_value == "REFUSED(plan_correct)"
        assert broken_term == Receipt.layer_term(:plan_correct)
      else
        assert standing_value == s
        assert broken_term == nil
      end

      assert derived_from == "sj closed vocabulary #{base}"
      assert derived_from != ""
      assert terminal? == (s == "BLOCKED")
    end
  end

  test "REFUSED renders with its layers and the first layer's broken term" do
    assert {:ok, m} = SjBridge.map("REFUSED(plan_correct, execution_correct)", [])

    assert m.layers == [:plan_correct, :execution_correct]
    assert m.standing.value == "REFUSED(plan_correct,execution_correct)"
    assert m.standing.broken_term == Receipt.layer_term(:plan_correct)
    assert m.standing.derived_from == "sj closed vocabulary REFUSED"
  end

  # ---- family disjointness ----

  test "two-family disjointness: no status string is a ladder atom; only UNKNOWN shares a name" do
    ladder_names = Enum.map(Ladder.states(), &to_string/1)

    for s <- SjBridge.statuses() do
      refute s in Ladder.states(), "status #{inspect(s)} must never be a ladder atom"
    end

    assert MapSet.difference(MapSet.new(SjBridge.statuses()), MapSet.new(ladder_names)) ==
             MapSet.new([
               "ALIVE",
               "BLOCKED",
               "BUILD_BROKEN",
               "PARTIAL_ALIVE",
               "REFUSED",
               "UNSUPPORTED"
             ])

    # The single name overlap is the shared anchor UNKNOWN — still disjoint as
    # a term (string vs atom), never interchangeable.
    assert "UNKNOWN" in ladder_names
  end

  # ---- map/3: rung family ----

  test "map/3 rung, index and trail come from Standing.ladder/2 over a fully evidenced run" do
    for s <- SjBridge.statuses() do
      assert {:ok, m} = SjBridge.map(value(s), evidenced_run(), replay_commands: cmds())

      assert is_atom(m.rung) and m.rung in Ladder.states()
      assert m.index == Ladder.index(m.rung)
      assert is_list(m.trail)
      assert m.standing.derived_from == "standing ladder #{m.rung} (index #{m.index})"

      # The status family and the rung family stay visibly separate: the value
      # family standing keeps its closed-vocabulary derivation even when the
      # rung outruns or underruns it.
      assert m.standing.value == s or String.starts_with?(m.standing.value, "REFUSED(")
    end
  end

  test "every map/3 trail re-admits under Ladder.admit/1" do
    for s <- SjBridge.statuses() do
      {:ok, m} = SjBridge.map(value(s), evidenced_run(), replay_commands: cmds())
      claim = %{fact: s, state: m.rung, transitions: m.trail}
      assert {:ok, %{fact: ^s, state: rung}} = Ladder.admit(claim)
      assert rung == m.rung
    end
  end

  test "law: ALIVE over an unevidenced run keeps rung UNKNOWN — mismatch is visible data" do
    assert {:ok, m} = SjBridge.map("ALIVE", %{}, [])

    assert m.standing.value == "ALIVE"
    assert m.rung == :UNKNOWN
    assert m.index == 0
    assert m.trail == []

    assert {:ok, %{state: :UNKNOWN}} =
             Ladder.admit(%{fact: "ALIVE", state: m.rung, transitions: m.trail})
  end

  # ---- mutations ----

  test "mutation: an unknown status base is refused" do
    assert {:error, %{reason: :sj_unknown_status, value: "ALMOST"}} = SjBridge.map("ALMOST", [])
    assert {:error, %{reason: :sj_unknown_status, value: "alive"}} = SjBridge.map("alive", [])
  end

  test "mutation: bare REFUSED is refused" do
    assert {:error, %{reason: :sj_refused_requires_layers, value: "REFUSED"}} =
             SjBridge.map("REFUSED", [])
  end

  test "mutation: REFUSED() (empty layers) is the bare form and is refused" do
    assert {:error, %{reason: :sj_refused_requires_layers, value: "REFUSED()"}} =
             SjBridge.map("REFUSED()", [])
  end

  test "mutation: an unknown layer is refused" do
    assert {:error, %{reason: :sj_unknown_layer, value: "REFUSED(nope)", layer: "nope"}} =
             SjBridge.map("REFUSED(nope)", [])
  end

  test "a layered non-REFUSED status parses its layers but renders direct" do
    assert {:ok, m} = SjBridge.map("ALIVE(plan_correct)", [])
    assert m.base == "ALIVE"
    assert m.layers == [:plan_correct]
    assert m.standing.value == "ALIVE"
  end

  # ---- receipt legality ----

  test "standing maps are legal Receipt standing fields" do
    for s <- SjBridge.statuses() do
      {:ok, m} = SjBridge.map(value(s), evidenced_run(), replay_commands: cmds())

      receipt =
        Receipt.new(%{
          identity: %{run_id: "r1", subject: "subject-1"},
          authority: %{ceiling: "CONSTRUCT", grant: "NONE", actor: "ash_pplan"},
          consequence: %{commits: [], files_changed: [], remote_effects: ["x=true"]},
          replay: %{commands: cmds(), ledger_digest: "d"},
          standing: m.standing
        })

      assert :ok = Receipt.validate(receipt)
    end
  end

  test "a REFUSED standing map with layers is also receipt-legal" do
    {:ok, m} = SjBridge.map("REFUSED(plan_correct)", [])

    receipt =
      Receipt.new(%{
        identity: %{run_id: "r1", subject: "subject-1"},
        authority: %{ceiling: "CONSTRUCT", grant: "NONE", actor: "ash_pplan"},
        consequence: %{commits: [], files_changed: [], remote_effects: []},
        replay: %{commands: cmds(), ledger_digest: "d"},
        standing: m.standing
      })

    assert :ok = Receipt.validate(receipt)
  end
end
