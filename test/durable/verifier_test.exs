defmodule AshPPlan.Reactor.Durable.VerifierTest do
  @moduledoc """
  Court: a durable wait step nested inside `group`/`around`/`recurse`/`compose` is refused
  loudly before the run starts; the same step at the top level, or a nesting composite holding
  only ordinary steps, is admitted.

  Anti-vacuity mutation: make `Verifier.check/2` ignore `composite` (always pass) -> the
  refusal tests fail; make it refuse every Await -> the top-level admit test fails.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.{Run, Verifier}
  alias AshPPlan.Reactor.Durable.Steps.{Await, Poll}

  defmodule Plain do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(_a, _c, _o), do: {:ok, :plain}
  end

  defp step(name, impl), do: %Reactor.Step{name: name, impl: impl, arguments: []}
  defp reactor(steps), do: %{Reactor.Builder.new() | steps: steps}
  defp await, do: step(:wait, {Await, [signal: "go", timeout: nil]})

  for {composite, mod} <- [
        group: Reactor.Step.Group,
        around: Reactor.Step.Around,
        recurse: Reactor.Step.Recurse,
        compose: Reactor.Step.Compose
      ] do
    test "an Await inside #{composite} is refused" do
      nested = [await()]
      outer = step(unquote(composite), {unquote(mod), steps: nested})

      assert {:error,
              %{
                reason: :durable_step_in_nesting_composite,
                composite: unquote(composite),
                step: :wait
              }} =
               Verifier.verify(reactor([outer]))
    end
  end

  test "a Poll nested two levels down inside a group is refused" do
    poll = step(:poll, {Poll, [until: {Kernel, :is_nil, []}, every: 10]})
    inner = step(:inner_group, {Reactor.Step.Group, steps: [poll]})
    outer = step(:group, {Reactor.Step.Group, steps: [inner]})

    assert {:error, %{reason: :durable_step_in_nesting_composite}} =
             Verifier.verify(reactor([outer]))
  end

  test "a refusal is found through a Checkpointed decoration too" do
    outer = step(:group, {Reactor.Step.Group, steps: [await()]})
    decorated = Run.decorate(reactor([outer]), %{store: self(), run_id: "v", checkpoints: %{}})
    assert {:error, %{reason: :durable_step_in_nesting_composite}} = Verifier.verify(decorated)
  end

  test "a top-level Await and a composite of ordinary steps are admitted" do
    assert :ok = Verifier.verify(reactor([await()]))
    group = step(:group, {Reactor.Step.Group, steps: [step(:p, {Plain, []})]})
    assert :ok = Verifier.verify(reactor([group, await()]))
  end
end
