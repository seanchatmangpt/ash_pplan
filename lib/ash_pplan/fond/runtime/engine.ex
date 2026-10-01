defmodule AshPPlan.FOND.Runtime.Engine do
  alias AshPPlan.FOND.Runtime.{Router, Dispatcher, Failure, Policy, Recovery, State}
  def run(g, s, p), do: step(g, State.transition(s, :dispatch), p)

  defp step(g, s, p) do
    case Router.next(g, s.capability, p) do
      {:error, :exhausted} ->
        {:error, State.transition(s, :exhaust), g}

      {:ok, e} ->
        n = s.attempts + 1

        case Dispatcher.dispatch(e, s.input, timeout: p.timeout_ms) do
          {:ok, r} ->
            {:ok, State.transition(%{s | attempts: n}, {:succeed, r}), g}

          {c, r} ->
            f = Failure.new(e.id, c, r, n)
            s = State.transition(%{s | attempts: n}, {:fail, f})
            g = Recovery.apply(g, f)

            if Policy.attempt_allowed?(p, n),
              do: step(g, State.transition(s, :dispatch), p),
              else: {:error, State.transition(s, :exhaust), g}
        end
    end
  end
end
