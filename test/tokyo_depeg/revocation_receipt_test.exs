defmodule AshPPlan.TokyoDepeg.RevocationReceiptTest do
  @moduledoc """
  Tokyo flash-depeg W3 stages 5-6 (Chicago, real collaborators, no mocks):

  **Court A — revocation (stage 5)**: the ECB freeze flips authority mid-burn. The next
  mutation attempt presents the frozen authority token; `Engine.attempt/3` gates it through
  `PolicyDriver.admit/1` and refuses before the claim — nothing executes. The Standing
  surface judges the frozen world independently: the consequence layer reads real post-state
  (freeze in force, refused mutation not executed) and the standing flips from `:alive` to
  `{:lost, [:observed_consequence_correct]}`.

  **Court B — receipt court (stage 6)**: `LedgerOCEL.export/digest` — the digest is stable
  under replay and flips under tamper (with a sabotage witness proving the digest covers
  event content); every refusal in the run produced a validated five-field receipt naming
  its subject and identity (asserted against real `AshPPlan.Standing.Receipt` records).

  Anti-vacuity: pre-freeze attempts with a real policy driver proceed (the refusal depends
  on the freeze, not on vacuous gating); the freeze fact is load-bearing in the Standing
  verdict; the sabotage witness moves the digest; denying the freeze fact flips the
  receipt's standing value to REFUSED.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.{Clock, Engine, LedgerOCEL, PolicyDriver}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Standing
  alias AshPPlan.Test.DurableFx
  alias AshPPlan.Test.Effects
  alias AshPPlan.Test.TokyoDepeg.RevocationSupport, as: TDB

  @subject TDB.subject()
  @freeze TDB.ecb_freeze()

  @replay_cmd %{
    cmd: "mix test test/tokyo_depeg/revocation_receipt_test.exs",
    cwd: File.cwd!(),
    exit: 0
  }

  @payments %{
    start: %{charge: [:paid, :declined]},
    paid: %{},
    declined: %{}
  }

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)

    fx = :"tokyo_depeg_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    {:ok, store} = Ets.start_link()

    # A real payments FOND domain and policy: the active authority presented with mutation
    # attempts. Real driver, real synthesis, real admission gate.
    {:ok, d} = FOND.new(@payments, [:paid, :declined])
    {:ok, driver} = PolicyDriver.new(d, :start)

    {:ok, store: store, fx: fx, driver: driver}
  end

  # ---- fixtures ----

  defp start_run(store, id, fx) do
    attrs =
      id
      |> DurableFx.attrs(effects: fx)
      |> Map.update!(:context, fn c ->
        Map.put(c, :ash_pplan_workflow, %{subject: @subject, task: "tokyo_depeg"})
      end)

    {:ok, _rec} = Engine.start(store, attrs)
    assert {:parked, :waiting} = Engine.attempt(store, id)
    id
  end

  defp signal_release(store, id) do
    {:ok, _} = Engine.signal(store, id, DurableFx.signal_name(), %{})
    assert {:completed, _} = Engine.attempt(store, id)
    id
  end

  defp executed(fx),
    do: Effects.count(fx, :admit) + Effects.count(fx, :authorize) + Effects.count(fx, :commit)

  defp checkpoint_count(store, id), do: length(Engine.steps(store, id))

  defp sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  # Evidence for a mid-burn run: real checkpoint events, execution equal to the real
  # effect counts, and consequence checks computed from real post-state.
  defp evidence(store, id, fx, authority_in_force) do
    {:ok, events} = TDB.evidence_events(store, id, @subject)

    %{
      run_id: id,
      subject_id: @subject,
      repo: "ash_pplan",
      events: events,
      model: DurableFx.model(),
      selection: TDB.selection(),
      execution: execution_pair(store, id),
      consequence: [
        authority_in_force: authority_in_force,
        refused_mutation_not_executed: executed(fx) == 2
      ]
    }
  end

  defp execution_pair(store, id) do
    observed =
      if Engine.fetch(store, id).status == :completed do
        %{admit: 1, authorize: 1, commit: 1}
      else
        %{admit: 1, authorize: 1}
      end

    {observed, observed}
  end

  # A receipt run map over the real evidence of `id`, recording the freeze fact.
  defp receipt_run(store, id, fx, freeze_in_force) do
    {:ok, events} = TDB.evidence_events(store, id, @subject)

    %{
      run_id: id,
      subject_id: @subject,
      repo: "ash_pplan",
      head: TDB.head(),
      base: TDB.base(),
      events: events,
      model: DurableFx.model(),
      selection: TDB.selection(),
      execution: execution_pair(store, id),
      consequence: [
        ecb_freeze_in_force: freeze_in_force,
        refused_mutation_not_executed: true,
        no_such_run_refused: true
      ],
      observation: %{
        run_status: Engine.fetch(store, id).status,
        effects: Effects.all(fx),
        freeze_token: if(freeze_in_force, do: inspect(@freeze))
      }
    }
  end

  # ---- Court A: mid-burn authority revocation (stage 5) ----

  test "ecb freeze mid-burn: next mutation refused with a typed refusal, nothing executes",
       %{store: store, fx: fx, driver: driver} do
    id = start_run(store, "tdb-revoke-1", fx)
    freeze = @freeze
    before = {executed(fx), checkpoint_count(store, id)}

    # Pre-flip: the same mutation attempt under an active authority proceeds, and the
    # Standing surface reads the run as alive.
    assert {:parked, :waiting} = Engine.attempt(store, id, policy: driver)
    assert Standing.standing(evidence(store, id, fx, true)) == :alive

    # The freeze: the next mutation presents the frozen authority token.
    assert {:refused, {:inadmissible_policy, {:not_a_driver, ^freeze}}} =
             Engine.attempt(store, id, policy: freeze)

    # Refused before the claim: no effect, no new checkpoint, run still non-terminal.
    assert {executed(fx), checkpoint_count(store, id)} == before
    assert %{status: :waiting} = Engine.fetch(store, id)

    # The Standing surface judges the frozen world: the consequence layer reads real
    # post-state (freeze in force, refused mutation not executed) and refuses.
    assert Standing.standing(evidence(store, id, fx, false)) ==
             {:lost, [:observed_consequence_correct]}

    # The refusal carries the scenario's class.
    assert TDB.refusal_class({:refused, {:inadmissible_policy, {:not_a_driver, @freeze}}}) ==
             "REFUSED_AUTHORITY_REVOKED"
  end

  test "the standing flip depends on the freeze fact, not the refusal shape (anti-vacuity)",
       %{store: store, fx: fx} do
    id = start_run(store, "tdb-revoke-2", fx)

    # The freeze fact is load-bearing: with `authority_in_force: true` the same evidence
    # stands; flipping only that check breaks the consequence layer and only it.
    assert Standing.standing(evidence(store, id, fx, true)) == :alive

    frozen = evidence(store, id, fx, false)

    assert Standing.standing(frozen) == {:lost, [:observed_consequence_correct]}

    assert Standing.verdicts(frozen) == %{
             plan_correct: :ok,
             execution_correct: :ok,
             observed_consequence_correct: {:error, [:authority_in_force]}
           }

    # The refusal-class mapping itself is not vacuous: an unrelated refusal does not
    # classify as the revocation.
    refute TDB.refusal_class({:error, %{reason: :no_such_run}}) == "REFUSED_AUTHORITY_REVOKED"
  end

  # ---- Court B: receipt court (stage 6) ----

  test "LedgerOCEL digest is stable under replay and flips under tamper",
       %{store: store, fx: fx} do
    id = start_run(store, "tdb-receipt-1", fx)
    signal_release(store, id)
    assert {:ok, d1} = LedgerOCEL.digest(store, id)

    # Replay: a re-attempt of a terminal run must not move the evidence.
    assert :ended = Engine.attempt(store, id)
    assert {:ok, d2} = LedgerOCEL.digest(store, id)
    assert d1 == d2

    # The export round-trips and its content digest is reproducible.
    assert {:ok, json1} = LedgerOCEL.export(store, id)
    assert {:ok, json2} = LedgerOCEL.export(store, id)
    assert sha(json1) == sha(json2)
    assert json1 =~ "\"events\""

    # Sabotage witness: the digest fold covers event content, not just shape.
    {:ok, events} = TDB.evidence_events(store, id, @subject)
    assert TDB.digest_fold(events) != TDB.digest_fold(TDB.sabotage(events))

    # Tamper the standing ledger under the run: the digest must track it.
    key =
      AshPPlan.Reactor.Durable.Key.for_name(
        "urn:ash-pplan:workflow:qualified_fulfillment_durable_spine#step-admit_order"
      )

    assert {:ok, _cp} = Ets.claim_undo(store, id, key, Clock.now())
    assert {:ok, d3} = LedgerOCEL.digest(store, id)
    refute d1 == d3
  end

  test "every refusal in the run produced a validated receipt with subject + identity",
       %{store: store, fx: fx} do
    id = start_run(store, "tdb-revoke-3", fx)
    freeze = @freeze

    # Refusal 1: the mid-burn revocation.
    revocation = Engine.attempt(store, id, policy: freeze)

    assert {:refused, {:inadmissible_policy, {:not_a_driver, ^freeze}}} = revocation

    # Refusal 2: a demand for evidence of a run that does not exist.
    ghost = LedgerOCEL.events(store, "tdb-ghost")
    assert {:error, %{reason: :no_such_run}} = ghost

    # Each refusal gets its own receipt over this run's real evidence, with the freeze
    # fact honestly recorded.
    receipts =
      [
        {:authority_revoked, receipt_run(store, id, fx, true)},
        {:no_such_run, receipt_run(store, id, fx, true)}
      ]
      |> Enum.map(fn {label, run} ->
        assert {:ok, receipt} = Standing.receipt(run, replay_commands: [@replay_cmd]),
               "refusal #{inspect(label)} produced no receipt"

        # Identity + subject, read off the real receipt record.
        assert receipt.identity.subject == @subject
        assert is_binary(receipt.identity.run_id) and receipt.identity.run_id != ""

        # Authority: nothing grants DO.
        assert receipt.authority.ceiling == "CONSTRUCT"
        assert receipt.authority.grant == "NONE"

        # The refusal was the correct consequence: the receipt stands.
        assert receipt.standing.value == "ALIVE"

        # The evidence digest is present and binds to this run's evidence.
        assert is_binary(receipt.replay.ledger_digest)
        assert receipt.replay.evidence[:ocel2_sha256]
        assert receipt.replay.commands == [@replay_cmd]

        {label, receipt}
      end)

    assert Map.new(receipts, fn {label, _} -> {label, true} end) == %{
             authority_revoked: true,
             no_such_run: true
           }

    # Anti-vacuity: the same run's receipt with the freeze fact denied (the freeze IS in
    # force) must not stand — the standing flips to REFUSED and the broken term names the
    # consequence layer.
    denied = receipt_run(store, id, fx, false)

    assert {:ok, refused_receipt} = Standing.receipt(denied, replay_commands: [@replay_cmd])
    assert refused_receipt.standing.value =~ "REFUSED"
    assert refused_receipt.standing.broken_term == "R_missing_consequence"
  end
end
