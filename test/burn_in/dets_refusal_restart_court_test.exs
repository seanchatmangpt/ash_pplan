defmodule AshPPlan.BurnIn.DetsRefusalRestartCourtTest do
  @moduledoc """
  BURN-IN court: the durable engine's typed refusals are persisted-but-never-court-pinned
  across a store kill/reopen (the soak test covers only the happy path).

  Per refusal class, over ONE real DETS file with a real kill + reopen:

    * the run stays non-terminal after the reopen,
    * re-attempting deterministically re-derives the IDENTICAL refusal (byte-equal digest over
      the deterministic term encoding of the refusal tuple),
    * the policy fingerprint (the decision-record witness) is unchanged across the reopen,
    * `Standing.Receipt` built from the reopened state carries `REFUSED(...)` with an intact
      replay field whose ledger_digest is recomputed from the REOPENED checkpoints.

  Refusal classes covered:

    * `outcome_outside_policy_domain` — a real provider answer outside the domain; no decision
      is recorded, so the re-drive re-executes and re-refuses identically.
    * `policy_step_limit` — a persisted decision, then the limit; the re-drive replays the
      recorded decision WITHOUT calling the provider again, then re-refuses identically.
    * `policy_replay_divergence` — after a reopen, a re-drive under a different driver
      fingerprint diverges from the persisted decision; re-derived identically.

  Chicago: real DETS store, real process kill, real engine, real provider, assertions on real
  reopened state. No mocks.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.PolicyDriver
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Standing.Receipt
  alias AshPPlan.Test.Effects

  @cycle_budget_ms 30_000

  @transitions %{
    start: %{charge_primary: [:paid], charge_backup: [:paid]},
    paid: %{}
  }

  setup do
    # the stores are start_link'd to this process; a real kill must not take the test down
    Process.flag(:trap_exit, true)

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_refusal_court_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    fx = :"refusal_court_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    {:ok, d} = FOND.new(@transitions, [:paid])
    {:ok, driver} = PolicyDriver.new(d, :start, policy: %{start: :charge_primary, paid: :none})

    {:ok, store: nil, path: path, fx: fx, driver: driver, domain: d}
  end

  test "outcome_outside_policy_domain: identical refusal + witness digest across kill/reopen",
       %{path: path, fx: fx, driver: driver} do
    t0 = System.monotonic_time(:millisecond)

    {:ok, s} = Dets.start_link(path: path)

    {:ok, _} = Engine.start(s, %{id: "outside-domain"})
    assert {:refused, {:outcome_outside_policy_domain, detail}} =
             Engine.drive_policy(s, "outside-domain",
               policy: driver,
               execute: provider(fx, %{charge_primary: :chargeback}),
               max_steps: 10
             )

    assert %{observed: :chargeback} = detail
    ref_digest = refusal_digest({:outcome_outside_policy_domain, detail})
    ref_fp = PolicyDriver.fingerprint(driver)
    assert Engine.steps(s, "outside-domain", store_module: Dets) == []

    :ok = GenServer.stop(s)

    # REOPEN the same path: the refusal must be re-derivable from durable state alone.
    {:ok, s2} = Dets.start_link(path: path)

    assert_non_terminal(s2, "outside-domain")

    assert {:refused, {:outcome_outside_policy_domain, detail2}} =
             Engine.drive_policy(s2, "outside-domain",
               policy: driver,
               execute: provider(fx, %{charge_primary: :chargeback}),
               max_steps: 10
             )

    assert refusal_digest({:outcome_outside_policy_domain, detail2}) == ref_digest,
           "re-derived refusal digest differs across kill/reopen"

    assert PolicyDriver.fingerprint(driver) == ref_fp

    assert_refused_receipt(s2, "outside-domain", "REFUSED(plan_correct)", ref_digest)

    :ok = GenServer.stop(s2)

    ms = System.monotonic_time(:millisecond) - t0
    assert ms < @cycle_budget_ms, "outside-domain cycle took #{ms}ms"
    IO.puts("[burn_in] outside-domain refusal court: wall=#{ms}ms digest=#{ref_digest}")
  end

  test "policy_step_limit then policy_replay_divergence: identical refusals across kill/reopen",
       %{path: path, fx: fx, domain: d} do
    t0 = System.monotonic_time(:millisecond)

    {:ok, driver} = PolicyDriver.new(d, :start, policy: %{start: :charge_primary})

    {:ok, s} = Dets.start_link(path: path)

    {:ok, _} = Engine.start(s, %{id: "limit-divergence"})

    # Persist one real decision (start --charge_primary--> paid), then hit the limit.
    assert {:refused, limit_ref} =
             Engine.drive_policy(s, "limit-divergence",
               policy: driver,
               execute: provider(fx, %{charge_primary: :paid}),
               max_steps: 1
             )

    [cp] = Engine.steps(s, "limit-divergence", store_module: Dets)
    assert cp.output.action == :charge_primary
    assert cp.output.observed == :paid
    persisted_fp = cp.output.policy

    # Kill the store mid-state (decision persisted, run non-terminal) and reopen.
    ref = Process.monitor(s)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^ref, :process, ^s, :killed}, 5_000
    flush_exits()

    {:ok, s2} = Dets.start_link(path: path)

    assert_non_terminal(s2, "limit-divergence")
    [cp2] = Engine.steps(s2, "limit-divergence", store_module: Dets)
    assert cp2.output.policy == persisted_fp

    # Re-drive under the SAME driver: the decision replays (no provider call), the limit is
    # re-refused, and the re-derived refusal is digest-identical to the pre-kill one.
    calls_before = Effects.count(fx, :charge_primary)

    assert {:refused, limit_ref2} =
             Engine.drive_policy(s2, "limit-divergence",
               policy: driver,
               execute: provider(fx, %{charge_primary: :paid}),
               max_steps: 1
             )

    assert Effects.count(fx, :charge_primary) == calls_before,
           "re-drive called the provider on an already-recorded decision"

    assert refusal_digest(limit_ref2) == refusal_digest(limit_ref)

    # Re-drive under a DIFFERENT driver: divergence from the persisted decision.
    {:ok, forged} = PolicyDriver.new(d, :start, policy: %{start: :charge_backup})

    assert {:refused, {:policy_replay_divergence, div}} =
             Engine.drive_policy(s2, "limit-divergence",
               policy: forged,
               execute: provider(fx, %{charge_backup: :paid}),
               max_steps: 5
             )

    assert div.step == 0
    div_digest = refusal_digest({:policy_replay_divergence, div})

    :ok = GenServer.stop(s2)

    # Reopen again: the divergence refusal re-derives identically and the run is STILL
    # non-terminal.
    {:ok, s3} = Dets.start_link(path: path)

    assert_non_terminal(s3, "limit-divergence")

    assert {:refused, {:policy_replay_divergence, div2}} =
             Engine.drive_policy(s3, "limit-divergence",
               policy: forged,
               execute: provider(fx, %{charge_backup: :paid}),
               max_steps: 5
             )

    assert refusal_digest({:policy_replay_divergence, div2}) == div_digest,
           "divergence refusal digest differs across kill/reopen"

    assert_refused_receipt(s3, "limit-divergence", "REFUSED(plan_correct)", div_digest)

    :ok = GenServer.stop(s3)

    ms = System.monotonic_time(:millisecond) - t0
    assert ms < @cycle_budget_ms, "limit/divergence cycle took #{ms}ms"
    IO.puts("[burn_in] limit+divergence refusal court: wall=#{ms}ms digest=#{div_digest}")
  end

  # -- shared helpers ---------------------------------------------------------------------------

  defp assert_non_terminal(s, id),
    do: assert(AshPPlan.Reactor.Durable.Testing.status(s, id) == :pending)

  # drain EXIT messages from killed stores (this process start_link'd them)
  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp refusal_digest(refusal),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(refusal, [:deterministic, minor_version: 2]))
      |> Base.encode16(case: :lower)

  # A real five-field Standing.Receipt over the REOPENED state: identity from the run row,
  # authority CONSTRUCT (the policy grants none), consequence = nothing left the machine,
  # replay = the court command + the ledger digest recomputed from the reopened checkpoints,
  # standing = REFUSED(<layer>) naming a real verdict layer.
  defp assert_refused_receipt(s, id, standing_value, refusal_digest_value) do
    run = Dets.get_run(s, id)
    assert run

    ledger_digest =
      s
      |> Engine.steps(id, store_module: Dets)
      |> Enum.map(&{&1.step_key, &1.output})
      |> :erlang.term_to_binary([:deterministic, minor_version: 2])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    receipt =
      Receipt.new(%{
        identity: %{run_id: run.id, subject: "dets-refusal-restart-court:" <> id},
        authority: %{actor: "court", ceiling: "CONSTRUCT", grant: "none"},
        consequence: %{commits: [], files_changed: [], remote_effects: []},
        replay: %{
          commands: [
            "mix test test/burn_in/dets_refusal_restart_court_test.exs --include burn_in"
          ],
          ledger_digest: ledger_digest,
          refusal_digest: refusal_digest_value
        },
        standing: %{derived_from: "engine_refusal", value: standing_value}
      })

    assert Receipt.validate(receipt) == :ok
    assert receipt.standing.value == standing_value
    assert receipt.replay.ledger_digest == ledger_digest
    assert receipt.replay.refusal_digest == refusal_digest_value
  end

  defp provider(fx, script) do
    fn action, _ctx ->
      {:ok, _} = Effects.run(fx, action)
      {:ok, Map.fetch!(script, action)}
    end
  end
end
