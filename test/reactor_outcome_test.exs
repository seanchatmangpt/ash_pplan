defmodule AshPPlan.ReactorOutcomeTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ReactorOutcome
  alias AshPPlan.ReactorOutcomeFixtures.{Fails, Halts, Succeeds}

  @moduletag :capture_log

  test "classifies Reactor public outcomes without changing them" do
    assert ReactorOutcome.state({:ok, :value}) == :succeeded
    assert ReactorOutcome.state({:ok, :value, :reactor}) == :succeeded
    assert ReactorOutcome.state({:halted, :reactor}) == :halted
    assert ReactorOutcome.state({:error, :boom}) == :failed
    assert ReactorOutcome.state(:unexpected) == :unknown

    assert ReactorOutcome.observe({:error, :boom}) == %{state: :failed, reason: :boom}
  end

  test "observes a real successful Reactor.run" do
    result = Reactor.run(Succeeds, %{value: 21})
    assert {:ok, 42} = result

    assert ReactorOutcome.state(result) == :succeeded
    assert ReactorOutcome.observe(result) == %{state: :succeeded, value: 42}
  end

  test "observes a real successful Reactor.run that returns the reactor" do
    result = Reactor.run(Succeeds, %{value: 2}, %{}, fully_reversible?: true)
    assert {:ok, 4, %Reactor{}} = result

    assert ReactorOutcome.state(result) == :succeeded
    assert %{state: :succeeded, value: 4, reactor: %Reactor{}} = ReactorOutcome.observe(result)
  end

  test "observes a genuinely halted Reactor.run" do
    result = Reactor.run(Halts, %{})
    assert {:halted, %Reactor{state: :halted} = reactor} = result

    assert ReactorOutcome.state(result) == :halted
    assert ReactorOutcome.observe(result) == %{state: :halted, reactor: reactor}
  end

  test "observes a real failed Reactor.run" do
    result = Reactor.run(Fails, %{})
    assert {:error, reason} = result

    assert ReactorOutcome.state(result) == :failed
    assert ReactorOutcome.observe(result) == %{state: :failed, reason: reason}
  end
end
