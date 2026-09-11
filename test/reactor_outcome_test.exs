defmodule AshPPlan.ReactorOutcomeTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ReactorOutcome

  test "classifies Reactor public outcomes without changing them" do
    assert ReactorOutcome.state({:ok, :value}) == :succeeded
    assert ReactorOutcome.state({:ok, :value, :reactor}) == :succeeded
    assert ReactorOutcome.state({:halted, :reactor}) == :halted
    assert ReactorOutcome.state({:error, :boom}) == :failed
    assert ReactorOutcome.state(:unexpected) == :unknown

    assert ReactorOutcome.observe({:error, :boom}) == %{state: :failed, reason: :boom}
  end
end
