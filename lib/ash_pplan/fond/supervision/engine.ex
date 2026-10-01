defmodule AshPPlan.FOND.Supervision.Engine do
  alias AshPPlan.FOND.Supervision.{
    AuthorityGuard,
    Portfolio,
    Receipt,
    Reselector,
    State,
    Transition
  }

  def new(d, i, cs), do: %State{domain: d, initial: i, candidates: Portfolio.normalize(cs)}

  def select(%State{} = s) do
    cs = Enum.reject(s.candidates, fn c -> AuthorityGuard.check(c.metadata) != :ok end)

    case Reselector.select(s.domain, s.initial, cs, s.excluded) do
      {:ok, c, bad} ->
        n = Transition.select(s, c, bad)
        {{:ok, c, Receipt.selection(c, bad, s.excluded)}, n}

      {:error, r, bad} ->
        {{:error, r, Receipt.refusal(r)}, %{s | refused: bad}}
    end
  end

  def observe(%State{selected: nil} = s, o),
    do: {{:error, :no_selected_policy}, Transition.observe(s, o)}

  def observe(%State{} = s, o) do
    n = s |> Transition.observe(o) |> Transition.exclude(s.selected.id)
    {{:ok, :reselect}, n}
  end
end
