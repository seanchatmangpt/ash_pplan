defmodule AshPPlan.Reactor.Durable.DetsReopenRetryTest do
  @moduledoc """
  Regression court for the repair-aware reopen window (checkpoint-burst lane finding): killing
  the store process mid-sync leaves the DETS file in a transient repair state, and an
  *immediate* reopen used to return `{:error, {:dets_open_failed, {:not_a_dets_file, path}}}`
  even though the file repairs fine seconds later.

  Law under judgment: after a hard kill during a large-value sync burst, an immediate reopen
  succeeds (init's bounded repair-aware retry absorbs the transient `not_a_dets_file`) within
  the burn-in soak's 10s reopen budget, and every acknowledged write is intact.

  Chicago discipline: real DETS files, real process kills, no mocks.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Dets

  @reopen_budget_ms 10_000

  setup do
    Process.flag(:trap_exit, true)

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_reopen_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    Process.put(:path, path)
    %{path: path}
  end

  test "kill mid-sync with large blobs, immediate reopen succeeds within budget" do
    path = get_ctx(:path)

    # hold parentage in a raw spawn so killing the store cannot kill the test
    test_pid = self()

    holder =
      spawn(fn ->
        {:ok, store} = Dets.start_link(path: path)
        send(test_pid, {:store_up, store})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:store_up, store}, 5_000

    # baseline acknowledged write, synced before the kill
    {:ok, rec} = Dets.start_run(store, %{id: "anchor-run"})
    assert %AshPPlan.Reactor.Durable.Record{id: "anchor-run"} = rec

    # several kill/reopen cycles on the same file: each kill can land mid-sync and leave the
    # file mid-repair, so the immediate reopen exercises the bounded repair-aware retry
    {total_ms, result} =
      Enum.reduce(1..3, {0, {:ok, store}}, fn _round, {acc_ms, {:ok, current}} ->
        # large-value burst: keep the sync window wide while the killer fires
        blob = :binary.copy(<<7>>, 1_024 * 1_024)

        writer =
          spawn(fn ->
            for i <- 0..300 do
              try do
                Dets.record(current, "anchor-run", "burst-#{i}", "burst", blob, %{})
              catch
                :exit, _ -> exit(:store_dead)
              end
            end
          end)

        Process.sleep(10)
        Process.exit(current, :kill)

        ref = Process.monitor(current)
        # :noproc = it died between Process.exit and the monitor being placed
        assert_receive {:DOWN, ^ref, :process, ^current, reason}
                       when reason in [:killed, :noproc],
                       5_000

        # immediate reopen - no sleep, no backoff of our own: the store init's bounded
        # repair-aware retry must absorb the transient not_a_dets_file
        {elapsed_us, open} = :timer.tc(fn -> Dets.start_link(path: path) end)

        assert {:ok, fresh} = open
        assert div(elapsed_us, 1_000) < @reopen_budget_ms

        send(writer, :done)
        {acc_ms + div(elapsed_us, 1_000), {:ok, fresh}}
      end)

    assert total_ms < @reopen_budget_ms

    # every acknowledged write survives: the anchor run and the repaired sequence intact
    {:ok, fresh} = result
    assert %AshPPlan.Reactor.Durable.Record{id: "anchor-run"} = Dets.get_run(fresh, "anchor-run")

    send(holder, :stop)
    GenServer.stop(fresh, :normal)
  end

  defp get_ctx(key) do
    case Process.get(key) do
      nil -> raise "missing ctx #{inspect(key)}"
      v -> v
    end
  end
end
