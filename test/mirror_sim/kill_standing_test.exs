defmodule AshPPlan.MirrorSim.KillStandingTest do
  @moduledoc """
  Kills the surviving mirror-sim mutants of `AshPPlan.Standing` and `AshPPlan.Obligation`
  (STD-07/10/11/15/17/18, OBL-01/03/04). Real modules, final-state assertions only.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Obligation
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Standing
  alias AshPPlan.Standing.Chain

  @model %{
    tasks: [
      %{id: :admit, depends_on: []},
      %{id: :pay, depends_on: [:admit]},
      %{id: :ship, depends_on: [:pay]}
    ]
  }
  @selection %{admit: :p1, pay: :p2, ship: :p3}

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

  defp events do
    [event("admit", 1, "p1"), event("pay", 2, "p2", "authorized"), event("ship", 3, "p3")]
  end

  defp run(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "r1",
        repo: "ash_pplan",
        head: String.duplicate("a", 40),
        base: String.duplicate("b", 40),
        events: events(),
        model: @model,
        selection: @selection,
        fond_gates: [],
        execution: {%{pay: 1}, %{pay: 1}},
        consequence: [order_fulfilled: true],
        observation: %{shipments: 1}
      },
      overrides
    )
  end

  defp cmds, do: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}]

  # STD-07: `:error -> true` => `false` in dependency_after?. A dependency with no
  # executed event must be refused; the mutant lets the plan through (:ok).
  test "STD-07 a task whose dependency never executed is refused as dependency_order" do
    r = run(%{events: [event("pay", 1, "p2", "authorized")]})
    assert Standing.plan_correct(r) == {:error, {:dependency_order, "pay"}}
  end

  # STD-10: Enum.sort_by(events, seq) => events. Events listed out of seq order but with
  # correct seq numbers are a lawful plan; the mutant positions by list order and refuses.
  test "STD-10 events are ordered by seq, not by list order" do
    shuffled = [event("pay", 2, "p2", "authorized"), event("admit", 1, "p1")]
    assert Standing.plan_correct(run(%{events: shuffled})) == :ok
  end

  # STD-11: seal standing forced to "ALIVE". The refused run's ledger digest must equal the
  # chain head sealed with REFUSED and differ from the ALIVE-sealed head.
  test "STD-11 a refused run seals its ledger with REFUSED" do
    bad = run(%{execution: {%{pay: 2}, %{pay: 1}}})
    assert {:ok, receipt} = Standing.receipt(bad, replay_commands: cmds())
    assert receipt.standing.value == "REFUSED(execution_correct)"

    pairs = Enum.map(bad.events, &{&1.id, &1.attributes.task})
    {:ok, refused} = Chain.build_sealed(pairs, "seal", "REFUSED", "subject-1")
    {:ok, alive} = Chain.build_sealed(pairs, "seal", "ALIVE", "subject-1")

    assert receipt.replay.ledger_digest == Chain.head(refused)
    refute receipt.replay.ledger_digest == Chain.head(alive)
  end

  # STD-15: "sha256:" prefix dropped from the OCEL digest.
  test "STD-15 ocel2 evidence digest is sha256-prefixed and equals the real export hash" do
    assert {:ok, receipt} = Standing.receipt(run(), replay_commands: cmds())
    {:ok, json} = ProcessEvidence.export(run().events, :ocel2_json)
    expected = "sha256:" <> Base.encode16(:crypto.hash(:sha256, json), case: :lower)

    assert receipt.replay.evidence.ocel2_sha256 == expected
    assert String.starts_with?(receipt.replay.evidence.ocel2_sha256, "sha256:")
  end

  # STD-17: observed?/1 accepts an empty map. An empty observation must stop the ladder at
  # MANUFACTURED; the mutant climbs to VERIFIED.
  test "STD-17 an empty observation does not actuate" do
    assert {:ok, %{state: :MANUFACTURED, index: 7}} =
             Standing.ladder(run(%{observation: %{}}), replay_commands: cmds())

    assert {:ok, %{state: :VERIFIED}} = Standing.ladder(run(), replay_commands: cmds())
  end

  # STD-18: VALIDATED rung forced true. A run with a wrong-provider plan (execution and
  # consequence fine) must halt at OBSERVED; the mutant keeps climbing past VALIDATED.
  test "STD-18 a plan-incorrect run does not reach VALIDATED" do
    bad_plan = run(%{events: [event("admit", 1, "other") | tl(events())]})

    assert {:error, {:provider_not_selected, "admit", "other", :p1}} =
             Standing.plan_correct(bad_plan)

    assert {:ok, %{state: :OBSERVED, index: 1, trail: [%{to: :OBSERVED}]}} =
             Standing.ladder(bad_plan, replay_commands: cmds())
  end

  # OBL-01: id uses 16 hex chars of the digest, not 8.
  test "OBL-01 obligation id is obl- plus the first 16 hex chars of the digest" do
    o = Obligation.mint("run-1", :step, :send, %{a: 1})
    "sha256:" <> hex = o.digest

    assert o.id == "obl-" <> binary_part(hex, 0, 16)
    assert String.length(o.id) == 20
  end

  # OBL-03: verification replaced by `true`. A tampered payload must fail verification.
  test "OBL-03 a tampered obligation payload fails verify_digest" do
    o = Obligation.mint("run-1", :step, :send, %{amount: 1})
    assert Obligation.verify_digest(o)
    refute Obligation.verify_digest(%{o | payload: %{amount: 999}})
  end

  # OBL-04: fallback clause `false` => `true`. Malformed input must not verify.
  test "OBL-04 malformed obligations never verify" do
    o = Obligation.mint("run-1", :step, :send, %{amount: 1})
    refute Obligation.verify_digest(%{o | digest: "md5:abc"})
    refute Obligation.verify_digest(%{not: :an_obligation})
    refute Obligation.verify_digest(nil)
  end
end
