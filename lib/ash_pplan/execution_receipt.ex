defmodule AshPPlan.ExecutionReceipt do
  @moduledoc """
  PROV-style observation of one semantic plan execution.

  This is evidence about an observed Reactor outcome. It is not a durable
  continuation checkpoint and grants no actuation authority.
  """

  @enforce_keys [
    :plan_iri,
    :run_id,
    :status,
    :started_at,
    :finished_at,
    :duration_us,
    :outcome_digest
  ]
  defstruct [
    :plan_iri,
    :run_id,
    :status,
    :started_at,
    :finished_at,
    :duration_us,
    :outcome_digest
  ]

  @type status :: :succeeded | :halted | :failed
  @type t :: %__MODULE__{
          plan_iri: String.t(),
          run_id: any(),
          status: status(),
          started_at: DateTime.t(),
          finished_at: DateTime.t(),
          duration_us: non_neg_integer(),
          outcome_digest: String.t()
        }

  @doc false
  def observe(plan_iri, run_id, outcome, started_at, started_mono) do
    finished_at = DateTime.utc_now()
    duration_us = System.monotonic_time(:microsecond) - started_mono

    %__MODULE__{
      plan_iri: plan_iri,
      run_id: run_id,
      status: status(outcome),
      started_at: started_at,
      finished_at: finished_at,
      duration_us: max(duration_us, 0),
      outcome_digest: digest(outcome)
    }
  end

  defp status({:ok, _result}), do: :succeeded
  defp status({:ok, _result, _reactor}), do: :succeeded
  defp status({:halted, _reactor}), do: :halted
  defp status({:error, _reason}), do: :failed
  defp status(_outcome), do: :failed

  defp digest({:ok, result}), do: hash({:ok, result})
  defp digest({:ok, result, _reactor}), do: hash({:ok, result})
  defp digest({:halted, reactor}), do: hash({:halted, reactor.state, Map.keys(reactor.intermediate_results)})
  defp digest({:error, reason}), do: hash({:error, inspect(reason, limit: :infinity)})
  defp digest(other), do: hash({:unknown, inspect(other, limit: :infinity)})

  defp hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
