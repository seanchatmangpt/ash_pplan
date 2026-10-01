defmodule AshPPlan.Workflow.CapabilityIndependenceCourtTest do
  @moduledoc """
  Capability Independence Court. Falsifies: "swapping a qualified provider
  changes the workflow Model or Subject". Resolution output must differ only in
  the realization; Model.canonical and Subject binding stay byte-identical.

  Anti-vacuity: a workflow whose capability is changed DOES change identity,
  and the two providers' realizations really differ.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Providers.Registry
  alias AshPPlan.Workflow.{Model, Subject}

  defmodule P1 do
    @behaviour AshPPlan.Provider
    def id, do: :p1
    def capabilities, do: ["File.Write"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 1
    def qualify(_, _), do: :ok
    def realize(_, _), do: {:ok, %{step: P1, options: [mode: :one], provider: :p1}}
  end

  defmodule P2 do
    @behaviour AshPPlan.Provider
    def id, do: :p2
    def capabilities, do: ["File.Write"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 2
    def qualify(_, _), do: :ok
    def realize(_, _), do: {:ok, %{step: P2, options: [mode: :two], provider: :p2}}
  end

  defp model(cap) do
    {:ok, m} = Model.new(name: :indep, tasks: [%{id: :write, capability: cap}])
    m
  end

  defp resolve_all(model, reg) do
    for t <- model.tasks, do: Registry.resolve(reg, %{capability: t.capability})
  end

  test "swapping provider leaves Model canonical form unchanged" do
    m = model("File.Write")
    before_canon = Model.canonical(m)
    [{:ok, a}] = resolve_all(m, Registry.new([P1, P2]))
    [{:ok, b}] = resolve_all(m, Registry.new([P2]))

    assert a.provider == P1 and b.provider == P2
    assert a.realization != b.realization
    assert Model.canonical(m) == before_canon
  end

  test "Subject identity is independent of the selected provider" do
    m = model("File.Write")
    s1 = Subject.bind(m)
    _ = resolve_all(m, Registry.new([P1]))
    _ = resolve_all(m, Registry.new([P2]))
    assert Subject.bind(m) == s1
  end

  test "anti-vacuity: changing the capability changes identity" do
    refute Model.canonical(model("File.Write")) == Model.canonical(model("File.Read"))
  end
end
