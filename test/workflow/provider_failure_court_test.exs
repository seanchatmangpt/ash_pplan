defmodule AshPPlan.Workflow.ProviderFailureCourtTest do
  @moduledoc """
  Provider Failure Court. Falsifies: "a failed provider crashes resolution or
  stays selectable". Sealing drops it and the next lawful provider is chosen;
  with none left the result is a typed refusal, never a raise.

  Anti-vacuity: without sealing, the failed provider is still selected.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Providers.Registry

  defmodule Prime do
    @behaviour AshPPlan.Provider
    def id, do: :prime
    def capabilities, do: ["Process.Run"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 1
    def qualify(_, _), do: :ok
    def realize(_, _), do: {:ok, %{step: Prime, options: [], provider: :prime}}
  end

  defmodule Backup do
    @behaviour AshPPlan.Provider
    def id, do: :backup
    def capabilities, do: ["Process.Run"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 2
    def qualify(_, _), do: :ok
    def realize(_, _), do: {:ok, %{step: Backup, options: [], provider: :backup}}
  end

  defmodule Raiser do
    @behaviour AshPPlan.Provider
    def id, do: :raiser
    def capabilities, do: ["Process.Run"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 0
    def qualify(_, _), do: :ok
    def realize(_, _), do: raise("kaboom")
  end

  @req %{capability: "Process.Run"}

  test "sealing the failed provider selects the next lawful one" do
    reg = Registry.new([Prime, Backup])
    assert {:ok, %{provider: Prime}} = Registry.resolve(reg, @req)

    sealed = Registry.seal(reg, Prime)
    assert sealed.generation == reg.generation + 1
    assert Registry.providers(sealed) == [Backup]
    assert {:ok, %{provider: Backup}} = Registry.resolve(sealed, @req)
  end

  test "anti-vacuity: unsealed failed provider is still selected" do
    assert {:ok, %{provider: Prime}} = Registry.resolve(Registry.new([Prime, Backup]), @req)
  end

  test "none left yields typed refusal, not a crash" do
    reg = Registry.new([Prime]) |> Registry.seal(Prime)
    assert {:error, %{reason: :no_qualified_provider, rejected: []}} = Registry.resolve(reg, @req)
    assert {:error, %{reason: :no_qualified_provider}} = Registry.resolve(Registry.new([]), @req)
  end

  test "a raising realize is contained and falls through" do
    reg = Registry.new([Raiser, Backup])

    assert {:ok,
            %{provider: Backup, rejected: [{Raiser, {:realize_failed, {:raised, "kaboom"}}}]}} =
             Registry.resolve(reg, @req)
  end

  test "sealing an unknown provider is a no-op" do
    reg = Registry.new([Prime])
    assert Registry.seal(reg, Backup) == reg
  end
end
