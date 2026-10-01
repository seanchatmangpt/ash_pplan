defmodule AshPPlan.ReactorOutcomeFixtures.Succeeds do
  @moduledoc "Reactor that completes with a value."

  use Reactor

  input(:value)

  step :double do
    argument :value, input(:value)
    run fn %{value: value}, _context -> {:ok, value * 2} end
  end

  return :double
end

defmodule AshPPlan.ReactorOutcomeFixtures.Halts do
  @moduledoc "Reactor whose only step halts, so `Reactor.run/4` returns `{:halted, reactor}`."

  use Reactor

  step :pause do
    run fn _arguments, _context -> {:halt, :awaiting_approval} end
  end

  return :pause
end

defmodule AshPPlan.ReactorOutcomeFixtures.Fails do
  @moduledoc "Reactor whose only step fails without retry."

  use Reactor

  step :explode do
    max_retries 0
    run fn _arguments, _context -> {:error, :boom} end
  end

  return :explode
end
