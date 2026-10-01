defmodule AshPPlan.Reactor.Durable.Mutations.PolicyDriverAdmitMutationTest do
  @moduledoc """
  Anti-vacuity mutation for the `PolicyDriver` admission court
  (`test/durable/policy_driver_test.exs`).

  Production property under test: `PolicyDriver.new/3` gates every policy with
  `AshPPlan.validate_policy/4` (via `admit/1`), so a hand-supplied inadmissible policy is a typed
  `{:error, {:inadmissible_policy, _}}` refusal, never an accepted driver.

  Mutation: compile a copy of the production `PolicyDriver` source with `admit/1` returning
  `:ok` unconditionally, under the module name `Mutation.PolicyDriver`. The same property is run
  against BOTH modules: production refuses the inadmissible policy, the mutated copy accepts it
  and returns a usable driver — so the court's inadmissible-policy assertion is non-vacuous.

  No mocks: real `AshPPlan.FOND` domain, real `validate_policy/4`; the mutated module is the
  production source with one mechanical break.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.PolicyDriver

  @source_path "lib/ash_pplan/reactor/durable/policy_driver.ex"

  @transitions %{
    start: %{
      charge_primary: [:paid, :primary_unavailable, :declined],
      charge_backup: [:paid, :declined]
    },
    primary_unavailable: %{charge_backup: [:paid, :declined]},
    paid: %{},
    declined: %{}
  }

  defp domain do
    {:ok, d} = FOND.new(@transitions, [:paid, :declined])
    d
  end

  defp compile_mutated! do
    source = File.read!(Path.join(File.cwd!(), @source_path))

    # Mechanical break: admit/1 accepts anything.
    mutated =
      source
      |> String.replace(
        "AshPPlan.Reactor.Durable.PolicyDriver",
        "AshPPlan.Reactor.Durable.Mutation.PolicyDriver"
      )
      |> String.replace(
        "def admit(%__MODULE__{domain: d, policy: p, initial: i, mode: m}) do",
        "def admit(%__MODULE__{}) do\n    :ok\n  end\n  def admit_unused(%__MODULE__{domain: d, policy: p, initial: i, mode: m}) do"
      )

    assert mutated != source, "the mutation needle no longer matches the production source"

    Code.compile_string(mutated)
  end

  @inadmissible %{start: :no_such_action, primary_unavailable: :charge_backup}

  test "control: production new/3 refuses an inadmissible policy" do
    Code.put_compiler_option(:ignore_module_conflict, true)

    assert {:error, {:inadmissible_policy, _}} =
             PolicyDriver.new(domain(), :start, policy: @inadmissible)

    assert {:error, {:inadmissible_policy, _}} = PolicyDriver.new(domain(), :start, policy: %{})
  end

  test "MUTATION (admit/1 unconditional :ok): the inadmissible policy is accepted as a driver" do
    Code.put_compiler_option(:ignore_module_conflict, true)
    compile_mutated!()
    mod = AshPPlan.Reactor.Durable.Mutation.PolicyDriver

    assert {:ok, driver} = mod.new(domain(), :start, policy: @inadmissible)
    assert driver.__struct__ == mod
    # the mutated admit/1 waves the same broken driver through
    assert :ok = mod.admit(%{driver | policy: %{}})
  end
end
