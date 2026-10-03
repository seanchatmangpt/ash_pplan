defmodule AshPPlan.Test.TokyoDepeg.RevocationSupport do
  @moduledoc """
  Hand-written irreducible residue for the Tokyo flash-depeg W3 stages 5-6 courts
  (revocation + receipt). Real collaborators only: the real durable Engine over a real
  Ets store, the real `AshPPlan.Standing` surface, the real `LedgerOCEL` exporter. No
  mocks.

  Evidence plumbing shared by the courts:

    * `evidence_events/3` - projects the real standing checkpoints of an engine run into
      `ProcessEvidence` events, bound to the workflow subject, so `AshPPlan.Standing`
      judges the run the engine actually executed.
    * `selection/0` - the provider selection the spine's bindings actually name.
    * `digest_fold/1` + `sabotage/1` - the anti-vacuity witness for tamper detection: the
      same fold `LedgerOCEL.digest/3` uses, applied to a mutated copy of the evidence, must
      move - otherwise "flips under tamper" could pass on a digest that ignores content.
    * `refusal_class/1` - the scenario's refusal-class mapping (the tdb ontology's refusal
      classes projected onto the engine's typed refusals).
  """

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Reactor.Durable.LedgerOCEL
  alias AshPPlan.Test.DurableFx

  @doc """
  The scenario's workflow subject: the NY fund account under ECB freeze, as a real
  content-addressed subject (`sha256:` over the account identifier) - the shape the
  identity middleware admits.
  """
  @spec subject() :: String.t()
  def subject do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, "tdb:ny-fund:acct-1"), case: :lower)
  end

  @doc """
  The mid-burn authority flip: the ECB freeze token, presented as the authority of the
  next mutation attempt. `Engine.attempt/3` gates every attempt's authority through
  `PolicyDriver.admit/1`; a frozen authority is refused before the claim, before any
  effect.
  """
  @spec ecb_freeze() :: {:ecb_freeze, String.t(), String.t()}
  def ecb_freeze, do: {:ecb_freeze, "ECB/2026/revocation-1", subject()}

  @doc """
  Project the real standing checkpoints of an engine run into evidence events. Every
  checkpoint must name a model task; an unmapped checkpoint is a raise, not a guess.
  """
  @spec evidence_events(term(), String.t(), String.t()) :: {:ok, [Event.t()]} | {:error, map()}
  def evidence_events(store, run_id, subject) do
    with {:ok, ocel} <- LedgerOCEL.events(store, run_id) do
      task_ids = Enum.map(DurableFx.model().tasks, & &1.id)

      events =
        ocel
        |> Enum.filter(&(&1.activity == "task_succeeded"))
        |> Enum.map(fn e ->
          task =
            Enum.find(task_ids, fn id ->
              String.contains?(e.attributes.task, to_string(id))
            end) ||
              raise "no model task for checkpoint label #{inspect(e.attributes.task)}"

          %Event{
            id: e.id,
            activity: e.activity,
            timestamp: e.timestamp,
            objects: e.objects,
            attributes: %{
              task: to_string(task),
              seq: e.attributes.seq,
              provider: nil,
              outcome: nil,
              output_digest: to_string(e.attributes.output_digest)
            },
            subject_id: e.subject_id || subject
          }
        end)

      {:ok, events}
    end
  end

  @doc "The provider selection the spine's bindings actually name."
  @spec selection() :: %{String.t() => String.t()}
  def selection do
    DurableFx.bindings()
    |> Map.new(fn {task, r} -> {to_string(task), to_string(r.provider)} end)
  end

  @doc "The repo's real HEAD SHA, read from git."
  @spec head() :: String.t()
  def head do
    {out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: File.cwd!(), stderr_to_stdout: true)
    String.trim_trailing(out)
  end

  @doc "The repo's real base for this wave: HEAD itself (single-checkout burn-in)."
  @spec base() :: String.t()
  def base, do: head()

  @doc """
  Anti-vacuity witness for tamper detection: the same fold `LedgerOCEL.digest/3` uses, so
  a court can prove the digest covers event content (a mutated attribute must move it) -
  otherwise "flips under tamper" could pass on a digest that ignores content.
  """
  @spec digest_fold([Event.t()]) :: String.t()
  def digest_fold(events) do
    events
    |> Enum.map(&{&1.id, &1.activity, &1.attributes})
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The tamper: flip one evidence event's `output_digest`. Returns the mutated copy; the
  input is never mutated.
  """
  @spec sabotage([Event.t()]) :: [Event.t()]
  def sabotage([first | rest]) do
    [%{first | attributes: Map.update!(first.attributes, :output_digest, &("0" <> &1))} | rest]
  end

  def sabotage([]), do: []

  @doc """
  The tdb refusal classes projected onto the engine's typed refusals. The mid-burn ECB
  freeze presents a frozen authority token; `Engine.attempt/3` refuses before the claim
  with `{:refused, {:inadmissible_policy, {:not_a_driver, freeze_token}}}`.
  """
  @spec refusal_class(term()) :: String.t() | nil
  def refusal_class({:refused, {:inadmissible_policy, {:not_a_driver, {:ecb_freeze, _, _}}}}),
    do: "REFUSED_AUTHORITY_REVOKED"

  def refusal_class({:error, %{reason: :no_such_run}}), do: "REFUSED_NO_SUCH_RUN"

  def refusal_class({:refused, other}), do: "REFUSED(class=#{inspect(other)})"

  def refusal_class(_), do: nil
end
