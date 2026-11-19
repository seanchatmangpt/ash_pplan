defmodule AshPPlan.Session.BridgeTest do
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Engine, Store.Dets}
  alias AshPPlan.Session.Bridge

  @opts [store_module: Dets]

  @moduletag :tmp_dir

  defp open(dir, id \\ :store_a),
    do: start_supervised!(Supervisor.child_spec({Dets, path: Path.join(dir, "session.dets")}, id: id))

  test "a parked session survives a store restart and resumes on signal", %{tmp_dir: dir} do
    store = open(dir)
    {:ok, rec} = Engine.start(store, %{id: "sess-1"}, @opts)
    assert {:ok, %{status: :waiting, parked?: true, waiting_on: ["step_up"]}} =
             Bridge.park(store, rec.id, "step_up", @opts)

    :ok = stop_supervised(:store_a)
    store2 = open(dir, :store_b)

    assert {:ok, %{status: :waiting, parked?: true, waiting_on: ["step_up"]}} =
             Bridge.hydrate(store2, "sess-1", @opts)

    assert {:ok, %{status: :pending}} = Bridge.signal(store2, "sess-1", "step_up", %{ok: true}, @opts)
    assert Dets.get_run(store2, "sess-1").status == :pending
  end

  test "signalling a never-parked run is a typed error and writes nothing", %{tmp_dir: dir} do
    store = open(dir)
    {:ok, _} = Engine.start(store, %{id: "sess-2"}, @opts)
    before = Dets.get_run(store, "sess-2")
    before_sigs = Dets.signals(store, "sess-2")

    assert {:error, :not_parked} = Bridge.signal(store, "sess-2", "step_up", %{}, @opts)
    assert {:error, :no_such_run} = Bridge.signal(store, "ghost", "step_up", %{}, @opts)

    assert :erlang.term_to_binary(Dets.get_run(store, "sess-2")) == :erlang.term_to_binary(before)
    assert Dets.signals(store, "sess-2") == before_sigs
  end

  test "the same signal twice yields one resume and a typed refusal", %{tmp_dir: dir} do
    store = open(dir)
    {:ok, _} = Engine.start(store, %{id: "sess-3"}, @opts)
    {:ok, _} = Bridge.park(store, "sess-3", "step_up", @opts)

    assert {:ok, %{status: :pending}} = Bridge.signal(store, "sess-3", "step_up", 1, @opts)
    assert {:error, :duplicate_signal} = Bridge.signal(store, "sess-3", "step_up", 1, @opts)

    assert [_one] = Enum.filter(Dets.signals(store, "sess-3"), &(&1.name == "step_up"))
  end
end
