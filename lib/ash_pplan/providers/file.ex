defmodule AshPPlan.Providers.File do
  @moduledoc """
  Filesystem realizations via reactor_file.

  Capabilities: #{inspect(~w(File.Read File.Write File.Copy File.Delete File.Mkdir))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(File.Read File.Write File.Copy File.Delete File.Mkdir)
  @properties [:compensable]
  @evidence [:file_stat]
  @table %{
    "File.Read" => {Reactor.File.Step.ReadFile, []},
    "File.Write" => {Reactor.File.Step.WriteFile, revert_on_undo?: true},
    "File.Copy" => {Reactor.File.Step.Cp, revert_on_undo?: true},
    "File.Delete" => {Reactor.File.Step.Rm, revert_on_undo?: true},
    "File.Mkdir" => {Reactor.File.Step.MkdirP, revert_on_undo?: true}
  }

  @impl true
  def id, do: :file
  @impl true
  def capabilities, do: @capabilities
  @impl true
  def properties, do: @properties
  @impl true
  def evidence, do: @evidence
  @impl true
  def cost, do: 1

  @impl true
  def qualify(requirement, context),
    do: Common.qualify(requirement, context, @capabilities, @properties, @evidence)

  @impl true
  def realize(requirement, context) do
    with :ok <- qualify(requirement, context) do
      Common.realize(requirement, id(), @table)
    end
  end
end
