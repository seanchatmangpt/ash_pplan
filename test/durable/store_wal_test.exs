defmodule AshPPlan.Reactor.Durable.StoreWalTest do
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Store.Wal

  setup do
    tmp_path = Path.join(System.tmp_dir!(), "wal_test_#{System.unique_integer([:positive])}.wal")
    {:ok, wal} = Wal.open(tmp_path)

    on_exit(fn ->
      Wal.close(wal)
      File.rm(tmp_path)
    end)

    %{wal: wal, path: tmp_path}
  end

  test "starts run, claims, records checkpoint and hydrates from disk", %{wal: wal, path: path} do
    run_id = "wal-run-#{System.unique_integer([:positive])}"
    attrs = %{id: run_id, inputs: %{x: 1}}

    assert {:ok, record} = Wal.start_run(wal, attrs)
    assert record.id == run_id

    now = DateTime.utc_now()
    assert {:ok, claimed} = Wal.claim(wal, run_id, self(), 10_000, now)
    assert claimed.claimed_by == self()

    assert {:ok, cp} = Wal.record(wal, run_id, "step_1", "Step 1", {:val, 42}, %{tag: :test})
    assert cp.output == {:val, 42}
    assert {:ok, standing_cp} = Wal.claim_undo(wal, run_id, "step_1", now)
    assert standing_cp.output == {:val, 42}

    # Close and reopen from disk (rehydration)
    Wal.close(wal)
    {:ok, rehydrated} = Wal.open(path)

    assert rehydrated_run = Wal.get_run(rehydrated, run_id)
    assert rehydrated_run.id == run_id
    assert {:ok, standing_cp2} = Wal.claim_undo(rehydrated, run_id, "step_1", now)
    assert standing_cp2.output == {:val, 42}

    Wal.close(rehydrated)
  end
end
