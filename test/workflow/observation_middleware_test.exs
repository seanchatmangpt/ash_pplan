defmodule AshPPlan.Workflow.ObservationMiddlewareTest do
  @moduledoc """
  Court: `AshPPlan.Reactor.Middleware.Observation` on a real two-step Reactor run emits
  telemetry, log lines and ProcessEvidence events that all resolve to the model's subject, plus
  a PROV receipt on completion. Anti-vacuity: an un-enriched reactor yields no step
  observations, a failing step emits `:error`, and the observed subject changes with the model.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshPPlan.ProcessEvidence
  alias AshPPlan.Reactor.Middleware.Observation
  alias AshPPlan.Reactor.Middleware.Observation.Collector
  alias AshPPlan.Workflow.{Model, Subject}

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

  defp reactor(second) do
    {:ok, r} = Reactor.Builder.add_step(Reactor.Builder.new(), :observe, Ok, [])
    {:ok, r} = Reactor.Builder.add_step(r, :build, second, observed: {:result, :observe})
    {:ok, r} = Reactor.Builder.return(r, :build)
    r
  end

  defp run(name, second) do
    m = model(name)
    {:ok, r} = AshPPlan.Reactor.enrich(reactor(second), m)
    {:ok, r} = AshPPlan.Reactor.add_middleware(r, [Observation])
    {:ok, c} = Collector.start()
    log = capture_log(fn -> send(self(), {:res, Reactor.run(r, %{}, %{}, async?: false)}) end)
    res = receive do: ({:res, x} -> x)
    evs = Collector.events(c)
    Collector.stop(c)
    {m, res, evs, log}
  end

  test "every step observation resolves to the model subject; run emits PROV" do
    {m, res, evs, log} = run("obs-ok", Ok)
    subject = Subject.bind(m).id
    assert {:ok, :done} = res

    steps = for {[:ash_pplan, :observation, :step, p], _, meta} <- evs, do: {p, meta}
    assert Enum.map(steps, &elem(&1, 0)) |> Enum.sort() == [:start, :start, :stop, :stop]

    for {_p, meta} <- steps do
      assert meta.subject_id == subject
      assert meta.evidence.subject_id == subject
    end

    assert Enum.map(steps, fn {_, m} -> m.task end) |> Enum.uniq() |> Enum.sort() == [
             "build",
             "observe"
           ]

    [{_, _, run_meta}] = for {[:ash_pplan, :observation, :run, :stop], _, _} = e <- evs, do: e
    assert run_meta.subject_id == subject
    assert run_meta.receipt.status == :succeeded
    assert run_meta.prov =~ "prov#Activity"

    events =
      for {_, _, %{evidence: e}} <-
            Enum.filter(evs, fn {_, _, m} -> Map.has_key?(m, :evidence) end),
          do: e

    assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json)
    assert json =~ subject
    assert log =~ "ash_pplan.step phase=start task=observe subject=#{subject}"
  end

  test "failing step emits :error and run :error" do
    {_m, res, evs, log} = run("obs-fail", Boom)
    assert {:error, _} = res

    assert Enum.any?(
             evs,
             &match?({[:ash_pplan, :observation, :step, :error], _, %{task: "build"}}, &1)
           )

    assert Enum.any?(evs, &match?({[:ash_pplan, :observation, :run, :error], _, _}, &1))
    assert log =~ "phase=error"
  end

  test "anti-vacuity: different model gives different subject; un-enriched emits no step events" do
    {m1, _, e1, _} = run("obs-a", Ok)
    {m2, _, e2, _} = run("obs-b", Ok)
    refute Subject.bind(m1).id == Subject.bind(m2).id
    [{_, _, a}] = Enum.filter(e1, &match?({[_, _, :run, :stop], _, _}, &1))
    [{_, _, b}] = Enum.filter(e2, &match?({[_, _, :run, :stop], _, _}, &1))
    refute a.subject_id == b.subject_id

    {:ok, bare} = Reactor.Builder.add_middleware(reactor(Ok), Observation)
    {:ok, c} = Collector.start()
    capture_log(fn -> Reactor.run(bare, %{}, %{}, async?: false) end)
    assert Collector.events(c) == []
    Collector.stop(c)
  end
end
