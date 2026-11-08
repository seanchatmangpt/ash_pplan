defmodule AshPPlan.Obligation do
  @moduledoc """
  Actuation Obligation Ticket.

  In the Chicago Deliberation Engine (`ash_pplan`), steps never perform network I/O
  or physical external actuation directly. Instead, steps requiring external side-effects
  (e.g., dispatching an SMS, wiring funds, submitting an order) mint a content-addressed
  Actuation Obligation Ticket and transition into a parked wait state (`Steps.Await`).

  The ticket is consumed and actuated by the Copilot & Perception Membrane (`ash_a2a`),
  which holds the cryptographic enclaves, hardware attestations, and sovereign actors.
  """

  @enforce_keys [:id, :run_id, :step_name, :intent, :payload, :digest, :issued_at]
  defstruct [
    :id,
    :run_id,
    :step_name,
    :intent,
    :payload,
    :digest,
    :issued_at,
    :expires_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t(),
          step_name: term(),
          intent: atom(),
          payload: map(),
          digest: String.t(),
          issued_at: integer(),
          expires_at: integer() | nil,
          metadata: map()
        }

  @doc """
  Mints a new content-addressed Actuation Obligation Ticket.
  Derives a deterministic SHA-256 digest from the `{run_id, step_name, intent, payload}` tuple.
  """
  @spec mint(String.t(), term(), atom(), map(), keyword()) :: t()
  def mint(run_id, step_name, intent, payload, opts \\ []) when is_map(payload) do
    binary_repr = :erlang.term_to_binary({run_id, step_name, intent, payload})
    digest = :crypto.hash(:sha256, binary_repr) |> Base.encode16(case: :lower)
    id = "obl-" <> binary_part(digest, 0, 16)

    now = System.system_time(:millisecond)
    expires_at = Keyword.get(opts, :expires_at)
    metadata = Keyword.get(opts, :metadata, %{})

    %__MODULE__{
      id: id,
      run_id: run_id,
      step_name: step_name,
      intent: intent,
      payload: payload,
      digest: "sha256:" <> digest,
      issued_at: now,
      expires_at: expires_at,
      metadata: metadata
    }
  end

  @doc """
  Verifies whether an obligation's content digest matches its payload.
  """
  @spec verify_digest(t()) :: boolean()
  def verify_digest(%__MODULE__{
        run_id: run_id,
        step_name: step_name,
        intent: intent,
        payload: payload,
        digest: "sha256:" <> expected_hash
      }) do
    binary_repr = :erlang.term_to_binary({run_id, step_name, intent, payload})
    actual_hash = :crypto.hash(:sha256, binary_repr) |> Base.encode16(case: :lower)
    actual_hash == expected_hash
  end

  def verify_digest(_), do: false
end
