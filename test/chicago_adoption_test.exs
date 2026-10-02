defmodule AshPPlan.ChicagoAdoptionTest do
  @moduledoc """
  Sabotage / negative-witness suite for the three top un-falsified surfaces,
  adapted from `chicago-tdd-tools-pack` (see `notes/chicago-adoption.md` for
  attribution and the gap analysis).

  Pack pattern, ported: each negative witness is a REAL broken implementation
  (production source with one mechanical break, compiled in-process) or a REAL
  corrupted input (a genuinely corrupt file, a genuinely hand-edited template),
  and every test asserts the DETECTION -- the court fires on the sabotage --
  not merely that the sabotage happened. No mocks anywhere.

  Surfaces (gaps -- not duplicating `test/durable/mutations/`, the store
  conformance mutant court, or `manufacture_test.exs`'s script-level hand-edit
  mutation):

    1. `Engine.wake/3` label honesty (terminal `:ended`, unknown `:not_found`)
       -- production source sabotage drops the terminal clause.
    2. `Store.Dets` -- a corrupted DETS file must fail closed at start,
       persistence must survive a real hard kill, and a production source
       sabotage stripping the claim compare-and-set must be detected.
    3. The projection regeneration court's byte-comparison detection path --
       a genuinely hand-edited template copy must be caught by the same
       comparison the court relies on.
  """

  use ExUnit.Case, async: false

  import AshPPlan.Test.Chicago, only: [sabotage_source!: 3, assert_detected!: 4]

  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Store.Ets

  @root File.cwd!()

  # ── Surface 1: Engine.wake label honesty ────────────────────────────────

  describe "engine wake negative witnesses" do
    defp terminal_run(store, id) do
      {:ok, _} = Ets.start_run(store, %{id: id})
      {:ok, _} = Ets.transition(store, id, [:pending], :completed, %{})
      Ets.get_run(store, id)
    end

    defp wake_honesty(mod) do
      {:ok, store} = Ets.start_link()

      # unknown run -> :not_found
      if apply(mod, :wake, [store, "chicago-nope"]) != :not_found, do: throw(:unknown_not_refused)

      # terminal run -> :ended, status untouched
      terminal_run(store, "chicago-done")
      if apply(mod, :wake, [store, "chicago-done"]) != :ended, do: throw(:terminal_label_wrong)
      if Ets.get_run(store, "chicago-done").status != :completed, do: throw(:terminal_moved)

      # a run with an unconsumed signal, parked :waiting -> wakes to :pending
      {:ok, _} = Ets.deliver_signal(store, "chicago-parked", "go", 1)
      {:ok, _} = Ets.start_run(store, %{id: "chicago-parked"})
      {:ok, _} = Ets.transition(store, "chicago-parked", [:pending], :waiting, %{})
      if apply(mod, :wake, [store, "chicago-parked"]) != :ok, do: throw(:parked_wake_failed)
      if Ets.get_run(store, "chicago-parked").status != :pending, do: throw(:parked_stuck)

      :pass
    catch
      reason -> {:failed, reason}
    end

    test "wake is honest about terminal and unknown runs; sabotaged wake is detected" do
      engine_source = "lib/ash_pplan/reactor/durable/engine.ex"

      mutant =
        sabotage_source!(engine_source, "AshPPlan.Reactor.Durable.Mutation.Chicago.EngineWake", [
          # Mechanical break: the terminal clause never fires, so a terminal run
          # falls through the cond and wake lies ":ok" instead of ":ended".
          {"          Status.terminal?(s) ->\n            :ended",
           "          false ->\n            :ended"}
        ])

      assert :detected ==
               assert_detected!(
                 "engine.wake terminal honesty",
                 Engine,
                 [{"wake terminal clause disabled", mutant}],
                 &wake_honesty/1
               )
    end
  end

  # ── Surface 2: Dets persistence + corrupted input ────────────────────────

  describe "dets store persistence negative witnesses" do
    defp dets_path do
      Path.join(
        System.tmp_dir!(),
        "chicago_dets_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )
    end

    defp persistence_survives_hard_kill?(mod) do
      path = dets_path()

      {:ok, pid} = mod.start_link(path: path)
      {:ok, _} = mod.start_run(pid, %{id: "chicago-kill"})
      # Unlink before the kill so the test process is not taken down with it.
      true = Process.unlink(pid)
      Process.exit(pid, :kill)
      wait_until_dead(pid)

      # Restart on the same path: a store told "start_run succeeded" before the
      # kill must still know the run afterwards.
      result =
        case mod.start_link(path: path) do
          {:ok, pid2} ->
            survived = match?(%{id: "chicago-kill"}, mod.get_run(pid2, "chicago-kill"))
            true = Process.unlink(pid2)
            if Process.alive?(pid2), do: GenServer.stop(pid2, :normal)
            if survived, do: :pass, else: {:failed, :run_lost_after_restart}

          {:error, reason} ->
            {:failed, {:restart_failed, reason}}
        end

      File.rm(path)
      result
    end

    defp claim_is_exclusive?(mod) do
      path = dets_path()
      now = DateTime.utc_now()

      result =
        case mod.start_link(path: path) do
          {:ok, pid} ->
            {:ok, _} = mod.start_run(pid, %{id: "chicago-claim"})
            {:ok, _} = mod.claim(pid, "chicago-claim", "attempt-a", 30_000, now)

            ok? =
              match?({:ok, _}, mod.claim(pid, "chicago-claim", "attempt-b", 30_000, now))

            true = Process.unlink(pid)
            if Process.alive?(pid), do: GenServer.stop(pid, :normal)
            if ok?, do: {:failed, :second_claim_won}, else: :pass

          {:error, reason} ->
            {:failed, {:start_failed, reason}}
        end

      File.rm(path)
      result
    end

    defp wait_until_dead(pid) do
      if Process.alive?(pid) do
        Process.sleep(10)
        wait_until_dead(pid)
      end
    end

    test "a corrupted DETS file fails closed at start (real corrupted input)" do
      path = dets_path()
      File.write!(path, <<0, 23, 9, "not-a-dets-file-at-all">>)

      Process.flag(:trap_exit, true)

      result = Dets.start_link(path: path)

      exit_signal =
        receive do
          {:EXIT, _pid, reason} -> {:EXIT, reason}
        after
          0 -> nil
        end

      assert match?({:error, {:dets_open_failed, _}}, result) or
               match?({:EXIT, {:dets_open_failed, _}}, exit_signal),
             "corrupted DETS file did not fail closed: result=#{inspect(result)} " <>
               "exit=#{inspect(exit_signal)}"

      on_exit(fn -> File.rm(path) end)
    end

    test "persistence survives a hard kill (real kill, real restart)" do
      assert persistence_survives_hard_kill?(Dets) == :pass
    end

    test "claim exclusivity holds; a store with the claim CAS stripped is detected" do
      dets_source = "lib/ash_pplan/reactor/durable/store/dets.ex"

      mutant =
        sabotage_source!(dets_source, "AshPPlan.Reactor.Durable.Mutation.Chicago.StoreDets", [
          # Mechanical break: the claim compare-and-set never refuses.
          {"        if claimable?(rec, claimer, lookup(st.tab, {:lease, id}, nil), now) do",
           "        if true do"}
        ])

      assert :detected ==
               assert_detected!(
                 "dets claim exclusivity",
                 Dets,
                 [{"claim CAS stripped", mutant}],
                 &claim_is_exclusive?/1
               )
    end
  end

  # ── Surface 3: regeneration court detection path ─────────────────────────

  @pack_template "priv/ggen/ash-pplan-pack/templates/projection_catalog.ex.eex"
  @checked_in "lib/ash_pplan/generated/projection_catalog.ex"

  describe "ggen regeneration drift court negative witness" do
    @tag timeout: 300_000
    test "the court's byte comparison fires on a genuinely hand-edited template" do
      scratch = Path.join(@root, "tmp/chicago_adoption")
      File.rm_rf!(scratch)
      honest_dir = Path.join(scratch, "honest")
      sabotaged_dir = Path.join(scratch, "sabotaged")
      File.mkdir_p!(honest_dir)
      File.mkdir_p!(sabotaged_dir)

      on_exit(fn -> File.rm_rf!(scratch) end)

      honest_out = sync_into(honest_dir, @pack_template)

      assert normalize(honest_out) == normalize(checked_in_path()),
             "honest regeneration control failed -- the court's baseline is broken"

      sabotaged_template = Path.join(sabotaged_dir, "projection_catalog.ex.eex")

      File.write!(
        sabotaged_template,
        File.read!(Path.join(@root, @pack_template)) <> "\n# chicago sabotage: hand edit\n"
      )

      sabotaged_out = sync_into(sabotaged_dir, sabotaged_template)

      refute normalize(sabotaged_out) == normalize(checked_in_path()),
             "a hand-edited template regenerated byte-identically -- the court is vacuous"
    end
  end

  defp sync_into(manifest_dir, template) do
    output = Path.join(manifest_dir, "projection_catalog.ex")

    Mix.Task.reenable("ggen_igniter.sync")

    Mix.Task.run("ggen_igniter.sync", [
      "--pack-dir",
      Path.join(@root, "priv/ggen/ash-pplan-pack"),
      "--template",
      template,
      "--engine",
      "oxigraph",
      "--out",
      output,
      "--manifest-dir",
      manifest_dir,
      "--verify-cwd",
      @root
    ])

    assert File.regular?(output)
    output
  end

  defp checked_in_path, do: Path.join(@root, @checked_in)

  defp normalize(path) do
    path |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()
  end
end
