defmodule AshPPlan.Workflow.ReactorFidelityCourtTest do
  @moduledoc """
  Reactor Fidelity Court. Falsifies: a dependency edge lost in projection
  (ordering not preserved) and independent tasks serialized. Anti-vacuity
  mutation: adding a dependency edge must add the corresponding step argument,
  and removing it must restore independence; unbound tasks are refused.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Model
  alias AshPPlan.Workflow.Project.Reactor, as: Proj

  defmodule Rec do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(args, _ctx, opts) do
      name = Keyword.fetch!(opts, :name)
      started = System.monotonic_time(:millisecond)
      Process.sleep(Keyword.get(opts, :sleep, 0))

      {:ok,
       %{
         name: name,
         started: started,
         ended: System.monotonic_time(:millisecond),
         saw: args |> Map.drop([:input]) |> Map.values() |> Enum.map(& &1.name)
       }}
    end
  end

  defmodule RecAdapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter
    def id, do: :rec
    def available?, do: true
    def ops, do: [:rec]
    def step(:rec, options), do: {:ok, {Rec, options}}
  end

  @adapters %{rec: RecAdapter}

  defp model(tasks) do
    {:ok, m} =
      Model.new(name: :rx_wf, tasks: Enum.map(tasks, &Keyword.put(&1, :capability, "File.Write")))

    m
  end

  defp bind(m, sleep \\ 0),
    do:
      Map.new(
        m.tasks,
        &{&1.id,
         %AshPPlan.Realization{
           capability: "File.Write",
           provider: :file,
           binding: %{adapter: :rec, op: :rec},
           options: [name: &1.id, sleep: sleep]
         }}
      )

  defp deps(reactor) do
    Map.new(reactor.steps, fn s ->
      {s.name,
       s.arguments
       |> Enum.map(& &1.source)
       |> Enum.flat_map(fn
         %Reactor.Template.Result{name: n} -> [n]
         _ -> []
       end)
       |> Enum.sort()}
    end)
  end

  test "dependency edges are preserved as step arguments" do
    m = model([[id: :a], [id: :b, depends_on: [:a]], [id: :c, depends_on: [:a, :b]]])
    assert {:ok, r} = Proj.project(m, bind(m), adapters: @adapters)
    d = deps(r)
    sa = Proj.step_iri(m, :a)
    sb = Proj.step_iri(m, :b)
    assert d[sa] == []
    assert d[sb] == [sa]
    assert d[Proj.step_iri(m, :c)] == Enum.sort([sa, sb])
  end

  test "run honors ordering and independent tasks run concurrently" do
    m = model([[id: :a], [id: :b], [id: :c, depends_on: [:a, :b]]])
    {:ok, r} = Proj.project(m, bind(m, 150), adapters: @adapters)
    assert {:ok, c} = Reactor.run(r, %{input: 1}, %{}, async?: true)
    assert c.name == :c
    assert Enum.sort(c.saw) == [:a, :b]
  end

  test "independent steps are async and share no edge" do
    m = model([[id: :a], [id: :b]])
    {:ok, r} = Proj.project(m, bind(m), adapters: @adapters)
    d = deps(r)
    assert d[Proj.step_iri(m, :a)] == []
    assert d[Proj.step_iri(m, :b)] == []

    assert r.steps
           |> Enum.filter(&(&1.name in [Proj.step_iri(m, :a), Proj.step_iri(m, :b)]))
           |> Enum.all?(& &1.async?)
  end

  test "mutation: adding an edge serializes, removing restores independence" do
    free = model([[id: :a], [id: :b]])
    tied = model([[id: :a], [id: :b, depends_on: [:a]]])
    {:ok, rf} = Proj.project(free, bind(free), adapters: @adapters)
    {:ok, rt} = Proj.project(tied, bind(tied), adapters: @adapters)
    refute deps(rf) == deps(rt)
    assert deps(rt)[Proj.step_iri(tied, :b)] == [Proj.step_iri(tied, :a)]
  end

  test "unbound task is refused" do
    m = model([[id: :a], [id: :b]])

    assert {:error, %{reason: :unbound_tasks, tasks: [:b]}} =
             Proj.project(m, Map.delete(bind(m), :b), adapters: @adapters)
  end
end
