defmodule AshPPlan.Workflow.RegistryTest do
  @moduledoc """
  Court: provider resolution honors semantic compatibility, execution
  properties, evidence, authority ceiling, availability, and cost-then-id order.

  Anti-vacuity: each filter is broken by a requirement it must reject.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Providers.Registry

  defmodule Base do
    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour AshPPlan.Provider
        @o opts
        def id, do: @o[:id]
        def capabilities, do: Keyword.get(@o, :caps, ["File.Write"])
        def properties, do: Keyword.get(@o, :props, [])
        def evidence, do: Keyword.get(@o, :evidence, [])
        def cost, do: Keyword.get(@o, :cost, 1)
        def qualify(_r, _c), do: Keyword.get(@o, :qualify, :ok)

        def realize(_r, _c),
          do: Keyword.get(@o, :realize, {:ok, %{step: __MODULE__, options: [], provider: id()}})
      end
    end
  end

  defmodule Cheap, do: use(Base, id: :cheap, cost: 1, props: [:durable], evidence: [:hash])

  defmodule Dear,
    do: use(Base, id: :dear, cost: 5, props: [:durable, :resumable], evidence: [:hash, :log])

  defmodule TieA, do: use(Base, id: :a_tie, cost: 3)
  defmodule TieB, do: use(Base, id: :b_tie, cost: 3)
  defmodule Down, do: use(Base, id: :down, cost: 0, qualify: {:error, :offline})
  defmodule Other, do: use(Base, id: :other, cost: 0, caps: ["Network.Fetch"])
  defmodule BadRealize, do: use(Base, id: :bad, cost: 0, realize: {:error, :boom})

  defp req(extra \\ %{}), do: Map.merge(%{capability: "File.Write"}, extra)

  test "lowest cost wins among qualified" do
    reg = Registry.new([Dear, Cheap])
    assert {:ok, %{provider: Cheap, candidates: [Cheap, Dear]}} = Registry.resolve(reg, req())
  end

  test "equal cost ordered by id" do
    reg = Registry.new([TieB, TieA])
    assert {:ok, %{provider: TieA}} = Registry.resolve(reg, req())
  end

  test "property support filters; mutation: dropping requirement changes winner" do
    reg = Registry.new([Cheap, Dear])

    assert {:ok, %{provider: Dear, rejected: [{Cheap, {:missing_properties, [:resumable]}}]}} =
             Registry.resolve(reg, req(%{properties: [:resumable]}))

    assert {:ok, %{provider: Cheap}} = Registry.resolve(reg, req())
  end

  test "evidence support filters" do
    reg = Registry.new([Cheap, Dear])
    assert {:ok, %{provider: Dear}} = Registry.resolve(reg, req(%{evidence: [:log]}))
  end

  test "unavailable and semantically incompatible providers are rejected with reasons" do
    reg = Registry.new([Down, Other, Cheap])
    assert {:ok, %{provider: Cheap, rejected: rejected}} = Registry.resolve(reg, req())
    assert {Down, {:unavailable, :offline}} in rejected
    assert {Other, :capability_unsupported} in rejected
  end

  test "failed realize falls through to the next candidate" do
    reg = Registry.new([BadRealize, Cheap])

    assert {:ok, %{provider: Cheap, rejected: [{BadRealize, {:realize_failed, :boom}}]}} =
             Registry.resolve(reg, req())
  end

  test "authority: :do is refused and ceiling is enforced" do
    reg = Registry.new([Cheap])

    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(reg, req(%{authority: :do}))

    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(reg, req(), %{ceiling: :do})

    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(reg, req(%{authority: :construct}), %{ceiling: :observe})

    assert {:ok, _} = Registry.resolve(reg, req(%{authority: :observe}), %{ceiling: :observe})
  end

  test "invalid capability is a typed refusal" do
    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(Registry.new([Cheap]), %{capability: "Bogus"})
  end

  test "register and seal bump generation; default/0 is a registry" do
    reg = Registry.new([Cheap])
    reg2 = Registry.register(reg, Dear)
    assert reg2.generation == reg.generation + 1
    assert Registry.providers(reg2) == [Cheap, Dear]
    assert %Registry{} = Registry.default()
  end
end
