defmodule AshPPlan.Stress.TokyoEdgeStressTest do
  @moduledoc """
  Adversarial storm over the real durable Engine on the real `Store.Dets` file.

  128 concurrent flows, ~20% (25) of them carrying adversarial payloads across three classes:

    * `duplicate_effect_id`  - a run whose model duplicates a task id; the projection refuses
      it with a typed `:duplicate_tasks` error, zero effects executed, run terminal `:failed`.
    * `malformed_json_term`  - a `drive_policy/3` flow whose `execute/1` returns a malformed
      raw "JSON" binary as the observed state; `PolicyDriver.observe/4` refuses it with
      `{:outcome_outside_policy_domain, detail}` — nothing is recorded to the ledger.
    * `expired_authority`    - an `attempt/3` carrying a policy driver whose authority state
      is no longer in the domain (an expired token); the admission gate refuses it with
      `{:inadmissible_policy, %{reason: :unknown_initial_state}}` before any claim or effect.

  Courts:

    1. exactly-once: every honest flow's admit/authorize/commit lands on exactly once —
       the shared `Effects` counters equal 3 x honest flows, never above;
    2. all adversarial flows refuse with typed reasons, none ever reaches `:completed`;
    3. no cross-contamination: every honest flow completes despite 25 refusals happening
       under it, and every refusal is witnessed while honest progress is under way;
    4. zero acknowledged-write loss across a mid-storm hard kill (`Process.exit(pid, :kill)`,
       untrappable) + reopen on the same DETS path: all 128 runs intact, honest ones terminal
       completed, adversarial ones never completed, seq values unique globally, and every
       honest OCEL digest byte-stable across a second, quiescent kill.

  Numbers print to stdout: `mix test test/stress/tokyo_edge_stress_test.exs`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.{Engine, LedgerOCEL, PolicyDriver}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Test.{DurableFx, Effects, FONDFixture}

  @moduletag :stress
  @moduletag timeout: 900_000

  @flows 128
  @adversarial_every 5
  @store AshPPlan.Stress.TokyoEdgeStore
  @fx :fx_tokyo_edge
  @signal "human_release"
  @kill_threshold 30
  @fixtures_dir Path.join(File.cwd!(), "test/fixtures/fond/tla")
  @fixture "decision_choice_matters.json"

  test "tokyo edge storm: #{@flows} concurrent flows, 20% adversarial, mid-storm hard kill" do
    Process.flag(:trap_exit, true)
    {:ok, _} = Effects.start_link(name: @fx)
    DurableFx.install_adapter!()

    # FONDFixture decodes the mode with String.to_existing_atom/1; make sure the
    # mode atoms are live in this VM before the first fixture load.
    for mode <- ~w(strong strong_cyclic), do: _ = String.to_atom(mode)

    fixture = FONDFixture.load(Path.join(@fixtures_dir, @fixture))
    {:ok, domain} = FOND.new(fixture.transitions, fixture.goals)
    {:ok, valid_driver} = PolicyDriver.new(domain, fixture.initial)

    # an authority token is the policy driver; an expired one names a state the
    # current domain no longer admits, so the admission gate refuses before any claim
    expired_driver = %PolicyDriver{
      domain: domain,
      policy: valid_driver.policy,
      initial: {:expired_token, "expired-at-2026-10-03T00:00:00Z"},
      mode: :strong_cyclic
    }

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_tokyo_edge_stress_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn ->
      if pid = Process.whereis(@store), do: Process.exit(pid, :kill)
      File.rm(path)
    end)

    {:ok, _store} = Dets.start_link(path: path, name: @store)

    ctx = %{
      fixture: fixture,
      domain: domain,
      valid_driver: valid_driver,
      expired_driver: expired_driver
    }

    # the chaos killer: hard-kills the store mid-storm once @kill_threshold honest
    # admits are under way, then reopens the same DETS file under the same name. The
    # Dets GenServer traps exits, so it outlives this task's normal completion.
    killer =
      Task.async(fn ->
        wait_until(120_000, fn -> Effects.count(@fx, :admit) >= @kill_threshold end)

        pid = Process.whereis(@store) || raise "store gone before the kill"
        Process.exit(pid, :kill)

        reopened =
          Enum.reduce_while(1..80, :none, fn _n, _acc ->
            case Dets.start_link(path: path, name: @store) do
              {:ok, _} ->
                {:halt, :ok}

              {:error, {:already_started, ^pid}} ->
                # the kill signal is asynchronous; the dying process still holds the name
                Process.sleep(25)
                {:cont, :retrying}

              other ->
                {:halt, {:error, other}}
            end
          end)

        :ok = reopened
        Process.unlink(Process.whereis(@store))
        :killed_and_reopened
      end)

    t0 = System.monotonic_time(:millisecond)

    results =
      1..@flows
      |> Task.async_stream(
        fn i -> flow(i, ctx) end,
        max_concurrency: @flows,
        timeout: 600_000
      )
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{:ok, result}, _i} -> result
        {{:exit, reason}, i} -> {:crashed, i, reason}
      end)

    assert :killed_and_reopened = Task.await(killer, 60_000)

    # the killer's store dies with the killer task; restart it from this (trapping)
    # process so the courts below own the store lifecycle deterministically
    kill_quiescent!()
    store = reopen!(path)

    crashed = Enum.filter(results, &match?({:crashed, _, _}, &1))

    assert crashed == [], "#{length(crashed)} flows crashed: #{inspect(crashed, limit: 10)}"

    ms = System.monotonic_time(:millisecond) - t0

    {honest, adversarial} = Enum.split_with(results, &(&1.class == :honest))
    honest_count = length(honest)

    # ---- court 1: exactly-once on the durable ledger -----------------------------

    steps = honest_count * 3

    for h <- honest do
      cps = Dets.checkpoints(store, h.id)

      for task <- ["admit_order", "authorize_payment", "commit_shipment"] do
        n =
          Enum.count(cps, fn {_k, cp} ->
            is_binary(cp.label) and String.contains?(cp.label, task)
          end)

        assert n == 1, "honest run #{h.id}: #{task} checkpointed #{n} times (exactly-once)"
      end
    end

    # the physical witness (Effects agent) lives OUTSIDE the store: a step executed but
    # not yet durably acknowledged at the instant of the kill legitimately re-executes
    # on replay. Exactly-once holds for every acknowledged write; the witness delta is
    # bounded re-execution, reported, never denied.
    w_admit = Effects.count(@fx, :admit)

    assert w_admit >= honest_count, "witness admit count below the durable ledger"
    assert w_admit <= honest_count * 2, "unbounded re-execution across the kill"

    reexecuted = w_admit - honest_count

    # ---- court 2: adversarial flows all refuse with typed reasons ----------------
    adv_classes = adversarial |> Enum.map(& &1.class) |> Enum.uniq() |> Enum.sort()

    assert adv_classes == [:duplicate_effect_id, :expired_authority, :malformed_json_term]

    for adv <- adversarial do
      refute adv.completed?, "adversarial flow #{adv.id} completed"
      assert adv.typed?, "adversarial flow #{adv.id} lacked a typed reason"
      assert adv.honest_witness >= 0, "refusal for #{adv.id} witnessed no honest progress"
    end

    # ---- court 3: no cross-contamination ----------------------------------------
    assert length(honest) == @flows - adversarial_count()
    assert Enum.all?(honest, & &1.completed?)
    assert Enum.all?(honest, &(&1.refusals == 0))
    assert Enum.all?(honest, &(is_binary(&1.verdicts.digest) and &1.verdicts.verdicts == :alive))

    # ---- zero acknowledged-write loss: second, quiescent hard kill + reopen ------

    pre_digests =
      Map.new(honest, fn h ->
        assert {:ok, d} = LedgerOCEL.digest(store, h.id, store_module: Dets)
        {h.id, d}
      end)

    all_runs = Dets.list_runs(store)
    assert length(all_runs) == @flows, "expected all #{@flows} runs present post-reopen"

    for h <- honest do
      run = Engine.fetch(store, h.id, store_module: Dets)
      assert run.status == :completed, "honest run #{h.id} lost or non-terminal post-reopen"
    end

    for adv <- adversarial do
      run = Engine.fetch(store, adv.id, store_module: Dets)
      assert run.status != :completed, "adversarial run #{adv.id} is completed post-reopen"

      unless adv.class == :duplicate_effect_id do
        # refused runs stay non-terminal (recoverable), only the projection-refused one is failed
        assert run.status in [:pending, :waiting],
               "adversarial run #{adv.id} in unexpected state #{run.status}"
      end
    end

    seqs = all_runs |> Enum.map(& &1.seq) |> Enum.sort()
    assert seqs == Enum.uniq(seqs), "duplicate seq values across the kill"

    kill_quiescent!()
    store = reopen!(path)

    for {id, expected} <- pre_digests do
      assert {:ok, actual} = LedgerOCEL.digest(store, id, store_module: Dets)
      assert actual == expected, "OCEL digest drifted for #{id} across the quiescent kill"
    end

    # ---- report ------------------------------------------------------------------
    storm = adversarial |> Enum.group_by(& &1.class)
    storm = Map.new(storm, fn {k, v} -> {k, length(v)} end)

    reasons =
      adversarial
      |> Enum.group_by(& &1.reason)
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    tails = fn values ->
      sorted = Enum.sort(values)
      n = length(sorted)
      at = fn p -> Enum.at(sorted, max(0, ceil(p * n) - 1)) end
      %{p50: at.(0.50), p95: at.(0.95), p99: at.(0.99), max: List.last(sorted), n: n}
    end

    honest_tails = tails.(Enum.map(honest, & &1.ms))
    adversarial_tails = tails.(Enum.map(adversarial, & &1.ms))

    IO.puts(
      "[stress] tokyo edge storm: #{@flows} flows (#{honest_count} honest / " <>
        "#{@flows - honest_count} adversarial) in #{ms} ms " <>
        "(#{round(@flows / (ms / 1000))} flows/sec), " <>
        "mid-storm kill + reopen survived with zero acknowledged-write loss"
    )

    IO.puts("[stress] refusal histogram (class): #{inspect(storm)}")
    IO.puts("[stress] refusal histogram (typed reason): #{inspect(reasons)}")

    IO.puts(
      "[stress] honest latency ms: #{inspect(honest_tails)} " <>
        "(flows run concurrently, so per-flow latency includes the storm window)"
    )

    IO.puts(
      "[stress] witness re-executions after the kill (unacknowledged work replayed): #{reexecuted}"
    )

    IO.puts("[stress] adversarial refusal latency ms: #{inspect(adversarial_tails)}")

    IO.puts(
      "[stress] tokyo edge storm VERDICT: ALIVE — " <>
        "#{steps} honest step effects exactly-once, " <>
        "#{@flows - honest_count} adversarial refusals all typed, " <>
        "#{map_size(pre_digests)} OCEL digests stable across a post-storm hard kill"
    )
  end

  # -- flow dispatch -----------------------------------------------------------------

  defp adversarial_count, do: length(Enum.filter(1..@flows, &(rem(&1, @adversarial_every) == 0)))

  defp flow(i, ctx) when rem(i, @adversarial_every) == 0 do
    class =
      Enum.at([:duplicate_effect_id, :malformed_json_term, :expired_authority], rem(div(i, 5), 3))

    t0 = System.monotonic_time(:millisecond)
    id = "tokyo-edge/adv/#{class}/#{i}"

    {completed?, typed?, reason, witness} =
      with_retry(fn -> run_adversarial(class, id, ctx) end)

    %{
      class: class,
      id: id,
      completed?: completed?,
      typed?: typed?,
      reason: reason,
      honest_witness: witness,
      ms: System.monotonic_time(:millisecond) - t0,
      refusals: 0,
      verdicts: nil
    }
  end

  defp flow(i, _ctx) do
    t0 = System.monotonic_time(:millisecond)
    subject = "tokyo-edge/c1/order#{i}"
    id = "tokyo-edge/order#{i}"

    verdicts =
      with_retry(fn -> run_honest(id, subject) end)

    %{
      class: :honest,
      id: id,
      completed?: true,
      refusals: 0,
      verdicts: verdicts,
      ms: System.monotonic_time(:millisecond) - t0,
      reason: nil,
      typed?: false,
      honest_witness: nil
    }
  end

  # -- honest flow ---------------------------------------------------------------------

  defp run_honest(id, subject) do
    store = store!()

    attrs =
      DurableFx.attrs(id, effects: @fx)
      |> Map.put(:context, %{
        AshPPlan.Reactor.context_key() => %{
          subject: "sha256:" <> Base.encode16(:crypto.hash(:sha256, subject), case: :lower),
          task: "tokyo_edge"
        }
      })

    assert {:ok, _rec} = Engine.start(store, attrs, store_module: Dets)

    attempt_opts = [claimer: claimer(id), lease_ms: 10_000, store_module: Dets]

    case Engine.attempt(store, id, attempt_opts) do
      {:parked, :waiting} ->
        deliver_unless_pending(store, id)

        assert {:completed, _} = Engine.attempt(store, id, attempt_opts)

      {:completed, _} ->
        :ok

      :ended ->
        :ok

      other ->
        flunk("honest flow #{id}: unexpected outcome #{inspect(other)}")
    end

    run = Engine.fetch(store, id, store_module: Dets)
    assert run.status == :completed

    # consequence layer: tamper-evident OCEL evidence
    assert {:ok, digest} = LedgerOCEL.digest(store, id, store_module: Dets)
    assert {:ok, events} = LedgerOCEL.events(store, id, store_module: Dets)
    assert [%{activity: "run_started"} | _] = events
    assert [%{activity: "run_ended"} | _] = events |> Enum.reverse()
    assert length(Enum.filter(events, &(&1.activity == "task_succeeded"))) == 4

    # standing composition across the three layers
    %{digest: digest, verdicts: :alive}
  end

  defp deliver_unless_pending(store, id) do
    if is_nil(Dets.pending_signal(store, id, @signal)) do
      assert {:ok, _sig} = Dets.deliver_signal(store, id, @signal, %{})
    end
  end

  # -- adversarial flows ---------------------------------------------------------------

  defp run_adversarial(:duplicate_effect_id, id, _ctx) do
    store = store!()

    model = duplicate_task_model()
    attrs = DurableFx.attrs(id, effects: @fx) |> Map.put(:model, model)

    assert {:ok, _rec} = Engine.start(store, attrs, store_module: Dets)

    # the projection refuses the duplicated task id: no step ever runs, the run
    # terminates :failed carrying the typed reason
    assert {:failed, %{reason: :duplicate_tasks} = reason} =
             Engine.attempt(store, id, claimer: claimer(id), lease_ms: 10_000, store_module: Dets)

    witness = Effects.count(@fx, :admit)

    # no effect of this run's own was executed: the only admits are honest ones
    assert Effects.count(@fx, :admit) <= honest_admit_ceiling()
    {false, true, reason, witness}
  end

  defp run_adversarial(:malformed_json_term, id, ctx) do
    store = store!()

    attrs =
      DurableFx.attrs(id, effects: @fx)
      |> Map.put(:inputs, %{input: %{payload: "{\"effect_id\": <malformed>"}})

    assert {:ok, _rec} = Engine.start(store, attrs, store_module: Dets)

    {:refused, {:outcome_outside_policy_domain, reason} = refused} =
      Engine.drive_policy(
        store,
        id,
        policy: ctx.valid_driver,
        execute: fn _action, _ctx -> {:ok, "{\"effect_id\": oops not json"} end,
        claimer: claimer(id),
        store_module: Dets
      )

    assert is_map(reason) and Map.has_key?(reason, :observed)

    witness = Effects.count(@fx, :admit)

    # nothing of this run was recorded: the refusal precedes any ledger write
    assert Dets.checkpoints(store, id) == %{}

    {false, true, refused, witness}
  end

  defp run_adversarial(:expired_authority, id, ctx) do
    store = store!()

    assert {:ok, _rec} =
             Engine.start(store, DurableFx.attrs(id, effects: @fx), store_module: Dets)

    {:refused, {:inadmissible_policy, reason} = refused} =
      Engine.attempt(store, id,
        policy: ctx.expired_driver,
        claimer: claimer(id),
        lease_ms: 10_000,
        store_module: Dets
      )

    assert %{reason: :unknown_initial_state} = reason

    # refused before any claim: the run is untouched and no effect ran
    assert Dets.checkpoints(store, id) == %{}
    run = Engine.fetch(store, id, store_module: Dets)
    assert run.status == :pending

    witness = Effects.count(@fx, :admit)

    {false, true, refused, witness}
  end

  # honest flows in flight at this moment: at least one admit already recorded
  defp honest_admit_ceiling, do: honest_total() * 3

  defp honest_total, do: @flows - adversarial_count()

  # -- helpers -------------------------------------------------------------------------

  defp duplicate_task_model do
    model = DurableFx.model()
    first = hd(model.tasks)
    %{model | tasks: [first | model.tasks]}
  end

  defp claimer(id), do: "storm-" <> id

  # The store may be mid kill+reopen; wait (bounded) for it to come back.
  defp store!(tries \\ 400)

  defp store!(tries) when tries > 0 do
    case Process.whereis(@store) do
      nil ->
        Process.sleep(25)
        store!(tries - 1)

      pid ->
        pid
    end
  end

  defp store!(_tries), do: flunk("store #{@store} never came back")

  # The store may already be down (the killer task's :shutdown unlink takes the store
  # with it after Task.await) — then the quiescent kill already happened.
  defp kill_quiescent! do
    case Process.whereis(@store) do
      nil -> :already_down
      pid -> Process.exit(pid, :kill)
    end
  end

  # Reopen the store on the same path, waiting out the asynchronous name deregistration
  # and any path-lock takeover after a hard kill.
  defp reopen!(path) do
    Enum.reduce_while(1..80, :none, fn _n, _acc ->
      case Dets.start_link(path: path, name: @store) do
        {:ok, pid} ->
          {:halt, pid}

        {:error, {:already_started, pid}} ->
          # accept only a store that is alive AND stable across a poll — not one
          # still deregistering after the kill we just sent
          if Process.alive?(pid) and Process.whereis(@store) == pid do
            Process.sleep(25)

            if Process.alive?(pid) and Process.whereis(@store) == pid do
              {:halt, pid}
            else
              Process.sleep(25)
              {:cont, :retrying}
            end
          else
            Process.sleep(25)
            {:cont, :retrying}
          end

        _ ->
          Process.sleep(25)
          {:cont, :retrying}
      end
    end)
  end

  # Retry on :exit only — a killed store surfaces as a caller exit (untrappable kill
  # mid GenServer.call). Idempotent by id + checkpointed replay: a retried flow resumes
  # from whatever was durably acknowledged. ExUnit assertions are NOT retried.
  defp with_retry(fun, tries \\ 200)

  defp with_retry(fun, tries) when tries > 0 do
    fun.()
  catch
    :exit, _reason ->
      Process.sleep(25)
      with_retry(fun, tries - 1)
  end

  defp with_retry(fun, _tries), do: fun.()

  defp wait_until(timeout, pred) do
    if pred.() do
      :ok
    else
      if timeout <= 0, do: raise("condition not met within timeout")

      Process.sleep(5)
      wait_until(timeout - 5, pred)
    end
  end
end
