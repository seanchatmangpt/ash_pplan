Code.require_file("test/support/durable/effects.ex")
Code.require_file("test/durable/lane_b_fixture.exs")

defmodule AshPPlan.Reactor.Durable.EngineWalTest do
  use ExUnit.Case, async: false

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Store.Wal}
  alias AshPPlan.Test.Effects

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)

    fx_name = :"fx_wal_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx_name)

    tmp_path =
      Path.join(System.tmp_dir!(), "engine_wal_#{System.unique_integer([:positive])}.wal")

    {:ok, wal} = Wal.open(tmp_path)

    on_exit(fn ->
      Wal.close(wal)
      File.rm(tmp_path)
    end)

    %{wal: wal, fx: fx_name}
  end

  test "Engine runs end-to-end using Store.Wal backend", %{wal: wal, fx: fx} do
    run_id = "engine-wal-#{System.unique_integer([:positive])}"
    attrs = LaneBFx.attrs(run_id, fx)

    assert {:ok, record} = Engine.start(wal, attrs, store_module: Wal)
    assert record.id == run_id

    # Execute attempt via Engine
    outcome = Engine.attempt(wal, run_id, store_module: Wal)
    assert {:completed, _result} = outcome

    # Verify status committed in WAL
    updated = Wal.get_run(wal, run_id)
    assert updated.status == :completed

    # Effects ran as expected
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, integrate: 1, verify: 1}
  end
end
