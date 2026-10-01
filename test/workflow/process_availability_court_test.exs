defmodule AshPPlan.ProcessAvailabilityCourtTest do
  @moduledoc """
  Court: `reactor_process` is dev/test-only, so its absence must surface as a
  typed UNSUPPORTED, never a crash. Anti-vacuity mutation: with availability
  forced true the same realization resolves, so the court's refusal is caused
  by availability and not by an unconditionally failing path.
  """
  use ExUnit.Case, async: true
  alias AshPPlan.{Realization, Reactor}

  defp real(op),
    do: %Realization{
      capability: "Process.Start",
      provider: :process,
      binding: %{adapter: :reactor_process, op: op}
    }

  test "absent implementation yields UNSUPPORTED" do
    assert {:error,
            %{
              reason: :unsupported,
              adapter: :reactor_process,
              detail: :implementation_unavailable
            }} =
             Reactor.step_for(real(:process_start), available?: false)
  end

  test "mutation: available implementation resolves (court is not vacuous)" do
    assert {:ok, {Elixir.Reactor.Process.Step.StartChild, _}} =
             Reactor.step_for(real(:process_start), available?: true)
  end

  test "adapter reports availability from the module's presence" do
    assert Reactor.Adapters.ReactorProcess.available?() ==
             Code.ensure_loaded?(Elixir.Reactor.Process.Step.StartChild)
  end
end
