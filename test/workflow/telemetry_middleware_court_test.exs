defmodule AshPPlan.Workflow.TelemetryMiddlewareCourtTest do
  @moduledoc """
  Court: the GENERATED `AshPPlan.Reactor.Middleware.Telemetry`
  (priv/ggen/ash-pplan-reactor-mw-pack) fires around real step executions on a
  real Reactor run, with zero step-definition changes (the no-touch-step-definitions
  property, asserted structurally and by a real diff of step sources).
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Middleware.Telemetry
  alias AshPPlan.Workflow.{Model, Subject}

  # Real telemetry sink (Chicago: real collaborator, not a mock) -- an Agent plus
  # real :telemetry handlers, updated synchronously in the handler (no races),
  # mirroring Observation.Collector.
  defmodule Sink do
    @moduledoc false
    use Agent

    def start do
      {:ok, pid} = Agent.start_link(fn -> [] end)
      id = {__MODULE__, pid}

      :telemetry.attach_many(id, Telemetry.events(), &__MODULE__.handle/4, pid)
      pid
    end

    def events(pid), do: Agent.get(pid, &Enum.reverse/1)

    def stop(pid) do
      :telemetry.detach({__MODULE__, pid})
      Agent.stop(pid)
    end

    def handle(event, meas, meta, pid) do
      if Process.alive?(pid), do: Agent.update(pid, &[{event, meas, meta} | &1])
    end
  end

  defmodule Ok do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(_a, _c, _o), do: {:ok, :done}
  end

  defmodule Boom do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(_a, _c, _o), do: {:error, :boom}
  end

  defmodule SlowOk do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_a, _c, _o) do
      Process.sleep(5)
      {:ok, :done}
    end
  end

  defmodule SlowBoom do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_a, _c, _o) do
      Process.sleep(5)
      {:error, :slow_boom}
    end
  end

  defp model(name) do
    {:ok, m} =
      Model.new(
        name: name,
        goal: "close",
        tasks: [
          [id: :observe, capability: "File.Read", authority: :observe],
          [id: :build, capability: "File.Write", after: [:observe], authority: :construct]
        ]
      )

    m
  end

  defp reactor(second, workflow) do
    obs = String.to_atom(Subject.correspondence(workflow, :observe).reactor)
    bld = String.to_atom(Subject.correspondence(workflow, :build).reactor)
    {:ok, r} = Reactor.Builder.add_step(Reactor.Builder.new(), obs, Ok, [])
    {:ok, r} = Reactor.Builder.add_step(r, bld, second, observed: {:result, obs})
    {:ok, r} = Reactor.Builder.return(r, bld)
    r
  end

  defp run(name, second, async? \\ false) do
    m = model(name)
    {:ok, r} = AshPPlan.Reactor.enrich(reactor(second, name), m)
    sink = Sink.start()
    res = Reactor.run(r, %{}, %{}, async?: async?)
    evs = Sink.events(sink)
    Sink.stop(sink)
    {m, res, evs}
  end

  test "middleware fires around every step and the run" do
    {_m, {:ok, :done}, evs} = run("tm-ok", Ok)

    steps =
      for {[:ash_pplan, :reactor, :step, p], _, meta} <- evs do
        {p, meta.step}
      end

    freq = steps |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()
    assert freq[:start] == 2
    assert freq[:stop] == 2

    stop_events =
      for {[:ash_pplan, :reactor, :step, :stop], meas, meta} <- evs, do: {meas, meta}

    assert length(stop_events) == 2

    for {meas, meta} <- stop_events do
      assert is_integer(meas.duration) and meas.duration >= 0
      assert is_integer(meta.duration) and meta.duration >= 0
      assert meas.duration == meta.duration
      assert is_integer(meas.system_time)
    end

    assert Enum.any?(evs, &match?({[:ash_pplan, :reactor, :run, :start], _, _}, &1))
    assert Enum.any?(evs, &match?({[:ash_pplan, :reactor, :run, :stop], _, _}, &1))
  end

  test "failing step emits :error step event and run :error; steps untouched" do
    step_files = Path.wildcard("lib/ash_pplan/reactor/steps/**/*.ex")
    before = Map.new(step_files, &{&1, File.stat!(&1).size})

    {_m, res, evs} = run("tm-boom", Boom)

    assert {:error, _} = res

    error_events =
      for {[:ash_pplan, :reactor, :step, :error], meas, meta} <- evs, do: {meas, meta}

    assert [{meas, meta}] = error_events
    assert is_integer(meas.duration) and meas.duration >= 0
    assert is_integer(meta.duration) and meta.duration >= 0
    assert meas.duration == meta.duration

    assert Enum.any?(evs, &match?({[:ash_pplan, :reactor, :run, :error], _, _}, &1))

    after_map = Map.new(step_files, &{&1, File.stat!(&1).size})
    assert before == after_map
  end

  test "step :stop and :error track real elapsed monotonic duration (sync and async) with zero process residue" do
    for async? <- [false, true] do
      {_m, {:ok, :done}, ok_evs} = run("tm-slow-ok-#{async?}", SlowOk, async?)
      bld_ok = String.to_atom(Subject.correspondence("tm-slow-ok-#{async?}", :build).reactor)

      [{stop_meas, stop_meta}] =
        for {[:ash_pplan, :reactor, :step, :stop], meas, %{step: ^bld_ok} = meta} <- ok_evs,
            do: {meas, meta}

      assert stop_meas.duration == stop_meta.duration
      assert System.convert_time_unit(stop_meta.duration, :native, :millisecond) >= 4

      {_m, {:error, _}, err_evs} = run("tm-slow-err-#{async?}", SlowBoom, async?)
      bld_err = String.to_atom(Subject.correspondence("tm-slow-err-#{async?}", :build).reactor)

      [{err_meas, err_meta}] =
        for {[:ash_pplan, :reactor, :step, :error], meas, %{step: ^bld_err} = meta} <- err_evs,
            do: {meas, meta}

      assert err_meas.duration == err_meta.duration
      assert System.convert_time_unit(err_meta.duration, :native, :millisecond) >= 4
    end

    leaked =
      Process.get()
      |> Enum.filter(fn
        {{Telemetry, :step_started, _}, _} -> true
        _ -> false
      end)

    assert leaked == []

    sink = Sink.start()
    assert :ok == Telemetry.event({:run_complete, :ok}, %{name: :unstarted_step}, %{})
    assert :ok == Telemetry.event({:run_error, :boom}, %{name: :unstarted_step}, %{})
    unstarted = Sink.events(sink)
    Sink.stop(sink)

    assert [
             {[:ash_pplan, :reactor, :step, :stop], %{duration: 0}, %{duration: 0}},
             {[:ash_pplan, :reactor, :step, :error], %{duration: 0}, %{duration: 0}}
           ] = unstarted
  end
end
