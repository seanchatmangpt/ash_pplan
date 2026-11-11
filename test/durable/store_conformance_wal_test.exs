defmodule AshPPlan.Reactor.Durable.StoreConformanceWalTest do
  @moduledoc """
  Court: `Store.Wal` against the generated Store conformance suite
  (`AshPPlan.Test.StoreConformance`). Each law runs against a fresh WAL file in the
  OS temp dir; the index is hydrated by replaying frames on open, so these laws also
  exercise the replay path.
  """
  use AshPPlan.Test.StoreConformance,
    store: AshPPlan.Reactor.Durable.Store.Wal,
    case: [async: false],
    start: fn ->
      path = Path.join(System.tmp_dir!(), "wal-conf-#{System.unique_integer([:positive])}.log")
      {:ok, wal} = AshPPlan.Reactor.Durable.Store.Wal.open(path)

      on_exit(fn ->
        AshPPlan.Reactor.Durable.Store.Wal.close(wal)
        File.rm(path)
      end)

      {:ok, wal}
    end
end
