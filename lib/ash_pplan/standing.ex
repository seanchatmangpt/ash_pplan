defmodule AshPPlan.Standing do
  @moduledoc """
  Standing of one workflow run, as a library API:

      Standing = PlanCorrect and ExecutionCorrect and ObservedConsequenceCorrect

  Three verdict layers, each a reading of evidence or real state, never of a step's own claim:

    * `plan_correct/1` reads process-evidence events (`AshPPlan.ProcessEvidence.Event`): every
      executed task belongs to the model, ran after its dependencies, was executed by the
      provider the plan selected, and the executed outcome path is admissible under the FOND
      gates (`fond_gates`: a gate task whose outcome is not admitted must have no successor).
    * `execution_correct/1` compares an observed effect map with the wanted one (exactly once
      each); the caller reads the effect counters and collaborators, this module judges.
    * `observed_consequence_correct/1` judges named boolean checks over real post-state.

  `verdict/3` combines three layer verdicts; `standing/1` evaluates a run; `receipt/2` produces
  the five-field receipt `AshPPlan.Standing.Receipt` (identity, authority, consequence, replay,
  standing) with a hash-chained ledger digest (`AshPPlan.Standing.Chain`) and, by default, the
  OCEL 2.0 JSON digest and the guarded ex4pm validation of the run's process evidence.

  A run is a map:

    * `:events` - process-evidence events; `:model`, `:selection` (task id => provider);
      `:fond_gates` (list of `%{task:, admit: [outcome], successors: [task]}`, default `[]`)
    * `:execution` - `{observed, wanted}`; `:consequence` - keyword/list of `{name, boolean}`
    * `:run_id`, `:subject_id` (default: the events' subject), `:head`/`:base` (exact git SHAs,
      optional), `:repo`, `:observation` (post-state map recorded in the receipt)

  Nothing here grants DO authority: the receipt's authority ceiling is `CONSTRUCT` unless the
  caller names a lower one, and a `DO` ceiling is refused by the receipt validator.
  """

  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.AshEx4pm
  alias AshPPlan.Standing.{Chain, Ladder, Receipt}

  @layers [:plan_correct, :execution_correct, :observed_consequence_correct]

  @type verdict :: :ok | {:error, term()}
  @type result :: :alive | {:lost, [atom()]}

  @doc "The three verdict layers, in order."
  @spec layers() :: [atom()]
  def layers, do: @layers

  @doc "Combine three layer verdicts: `:alive`, or `{:lost, broken_layers}` in layer order."
  @spec verdict(verdict(), verdict(), verdict()) :: result()
  def verdict(plan, execution, consequence) do
    broken =
      for {layer, v} <- Enum.zip(@layers, [plan, execution, consequence]), v != :ok, do: layer

    if broken == [], do: :alive, else: {:lost, broken}
  end

  @doc "All three layer verdicts of a run as a map."
  @spec verdicts(map()) :: %{atom() => verdict()}
  def verdicts(run) do
    %{
      plan_correct: plan_correct(run),
      execution_correct: execution_correct(run),
      observed_consequence_correct: observed_consequence_correct(run)
    }
  end

  @doc "Standing of a run: `:alive` or `{:lost, broken_layers}`."
  @spec standing(map()) :: result()
  def standing(run) do
    v = verdicts(run)
    verdict(v.plan_correct, v.execution_correct, v.observed_consequence_correct)
  end

  # ---- ladder ----

  @doc """
  The run's position on the 10-state evidentiary standing ladder
  (`AshPPlan.Standing.Ladder`, adopted from `ggen-marketplace/packs/standing-ladder-pack`),
  with the single-rung audit trail. Each rung is admitted only when derivable
  from real inputs -- no decorative states:

    * `UNKNOWN` - the run itself (always)
    * `OBSERVED` - process-evidence events are present
    * `VALIDATED` - the plan layer passes (`plan_correct/1` = `:ok`)
    * `DERIVED` - the execution layer passes (observed == wanted)
    * `CANDIDATE` - named consequence checks are present
    * `EXPERIMENTALLY_SUPPORTED` - the consequence layer passes
    * `ADMITTED` - `standing/1` = `:alive`
    * `MANUFACTURED` - `receipt/2` forms and validates
    * `ACTUATED` - a non-empty observed post-state is recorded (`run[:observation]`)
    * `VERIFIED` - the validated receipt carries the OCEL 2.0 evidence digest

  Returns `{:ok, %{state:, index:, trail:}}` where `trail` is one
  `%{from:, to:, evidence:, order:}` map per single-rung promotion, each with a
  non-empty evidence reference derived from the input that justified the rung.
  Promotion stops at the first rung not derivable from the run's inputs.
  """
  @spec ladder(map(), keyword()) ::
          {:ok, %{state: Ladder.state(), index: non_neg_integer(), trail: [map()]}}
  def ladder(run, opts \\ []) do
    events = Map.get(run, :events, [])
    v = verdicts(run)

    receipt_result =
      if Map.get(run, :run_id) && subject_id(run, events),
        do: receipt(run, opts),
        else: {:error, :no_identity}

    receipt_ok? = match?({:ok, _}, receipt_result)
    alive? = standing(run) == :alive

    rungs = [
      {:UNKNOWN, true, "run declared"},
      {:OBSERVED, events != [], "process_evidence events=#{length(events)}"},
      {:VALIDATED, v.plan_correct == :ok, "plan_correct=ok"},
      {:DERIVED, v.execution_correct == :ok, "execution_correct=ok"},
      {:CANDIDATE, is_list(run[:consequence]) and run[:consequence] != [],
       "consequence checks=#{consequence_count(run)}"},
      {:EXPERIMENTALLY_SUPPORTED, v.observed_consequence_correct == :ok,
       "observed_consequence_correct=ok"},
      {:ADMITTED, alive?, "standing=ALIVE"},
      {:MANUFACTURED, receipt_ok?, "receipt validated=true"},
      {:ACTUATED, receipt_ok? and observed?(run),
       "observation recorded in receipt consequence.observed"},
      {:VERIFIED, receipt_ok? and observed?(run) and evidence_digest(receipt_result) != nil,
       "ocel2_sha256 #{evidence_digest(receipt_result) || "absent"}"}
    ]

    {state, index, trail} = promote(rungs)
    {:ok, %{state: state, index: index, trail: trail}}
  end

  # Walk the rungs in order; the first non-derivable rung stops promotion at the
  # previous state (UNKNOWN is always derivable, so the trail is never empty).
  defp promote(rungs) do
    Enum.reduce_while(rungs, {:UNKNOWN, 0, []}, fn {state, derivable?, evidence},
                                                   {_, _, trail} = acc ->
      cond do
        # UNKNOWN is the anchor state, not a promotion: it emits no transition.
        state == :UNKNOWN and derivable? ->
          {:cont, acc}

        derivable? ->
          from = if trail == [], do: :UNKNOWN, else: List.last(trail).to

          {:cont,
           {state, Ladder.index(state),
            trail ++ [%{from: from, to: state, evidence: evidence, order: length(trail) + 1}]}}

        true ->
          {:halt, acc}
      end
    end)
  end

  defp consequence_count(%{consequence: checks}) when is_list(checks), do: length(checks)
  defp consequence_count(_), do: 0

  defp observed?(%{observation: o}), do: is_map(o) and map_size(o) > 0
  defp observed?(_), do: false

  defp evidence_digest({:ok, receipt}),
    do: receipt.replay.evidence[:ocel2_sha256]

  defp evidence_digest(_), do: nil

  # ---- layer 1: plan ----

  @doc "Plan layer over `run.events`, `run.model`, `run.selection`, `run.fond_gates`."
  @spec plan_correct(map()) :: verdict()
  def plan_correct(%{events: events, model: model, selection: selection} = run) do
    tasks = Map.new(model.tasks, &{to_string(&1.id), &1})
    ordered = Enum.sort_by(events, & &1.attributes.seq)
    position = ordered |> Enum.with_index() |> Map.new(fn {e, i} -> {e.attributes.task, i} end)

    cond do
      bad = Enum.find(ordered, &(not Map.has_key?(tasks, &1.attributes.task))) ->
        {:error, {:task_outside_model, bad.attributes.task}}

      bad = Enum.find(ordered, &wrong_provider?(&1, selection)) ->
        {:error,
         {:provider_not_selected, bad.attributes.task, bad.attributes.provider,
          selection[String.to_existing_atom(bad.attributes.task)]}}

      bad = Enum.find(ordered, &dependency_after?(&1, tasks, position)) ->
        {:error, {:dependency_order, bad.attributes.task}}

      true ->
        fond_admissible(ordered, Map.get(run, :fond_gates, []))
    end
  end

  def plan_correct(_run), do: {:error, :plan_evidence_missing}

  @doc "Plan layer over explicit events and a context holding `:model`, `:selection`."
  @spec plan_correct([ProcessEvidence.Event.t()], map()) :: verdict()
  def plan_correct(events, ctx), do: plan_correct(Map.put(ctx, :events, events))

  defp wrong_provider?(%{attributes: %{task: task, provider: provider}}, selection) do
    provider != nil and provider != to_string(selection[String.to_existing_atom(task)])
  end

  defp dependency_after?(%{attributes: %{task: task}}, tasks, position) do
    Enum.any?(tasks[task].depends_on, fn dep ->
      case Map.fetch(position, to_string(dep)) do
        {:ok, p} -> p > Map.fetch!(position, task)
        :error -> true
      end
    end)
  end

  # FOND: a gate task's outcome set is nondeterministic; only an admitted outcome has successors.
  defp fond_admissible(events, gates) do
    Enum.find_value(gates, :ok, fn %{task: task, admit: admit, successors: successors} ->
      gate = Enum.find(events, &(&1.attributes.task == to_string(task)))
      admit = Enum.map(admit, &to_string/1)
      successors = Enum.map(successors, &to_string/1)

      if gate != nil and gate.attributes.outcome not in admit and
           Enum.any?(events, &(&1.attributes.task in successors)) do
        {:error, {:inadmissible_path, task_atom(task), gate.attributes.outcome}}
      end
    end)
  end

  defp task_atom(task) when is_atom(task), do: task
  defp task_atom(task), do: String.to_existing_atom(task)

  # ---- layer 2: execution ----

  @doc "Execution layer: `run.execution` is `{observed, wanted}`; equal means exactly as wanted."
  @spec execution_correct(map() | {term(), term()}) :: verdict()
  def execution_correct({observed, wanted}),
    do: if(observed == wanted, do: :ok, else: {:error, {observed, wanted}})

  def execution_correct(%{execution: {_, _} = pair}), do: execution_correct(pair)
  def execution_correct(_run), do: {:error, :execution_evidence_missing}

  # ---- layer 3: observed consequence ----

  @doc "Consequence layer over named boolean checks of real post-state; fails with the names."
  @spec observed_consequence_correct(map() | [{atom(), boolean()}]) :: verdict()
  def observed_consequence_correct(%{consequence: checks}),
    do: observed_consequence_correct(checks)

  def observed_consequence_correct(checks) when is_list(checks) do
    case for({name, false} <- checks, do: name) do
      [] -> :ok
      failed -> {:error, failed}
    end
  end

  def observed_consequence_correct(_run), do: {:error, :consequence_evidence_missing}

  # ---- receipt ----

  @doc """
  Build and validate the receipt of a run.

  Returns `{:ok, %AshPPlan.Standing.Receipt{}}` or `{:error, %{broken_term:, field:, reason:}}`
  when a field cannot be formed (a missing field is never filled with a literal). Options:
  `:actor` (default `"ash_pplan"`), `:ceiling` (default `"CONSTRUCT"`), `:grant` (default
  `"NONE"`), `:replay_commands` (list of `%{cmd:, cwd:, exit:}`; required), `:evidence`
  (default `true`: add the OCEL 2.0 JSON sha256 and the guarded ex4pm validation status).
  """
  @spec receipt(map(), keyword()) :: {:ok, Receipt.t()} | {:error, map()}
  def receipt(run, opts \\ []) do
    v = verdicts(run)
    result = verdict(v.plan_correct, v.execution_correct, v.observed_consequence_correct)
    events = Map.get(run, :events, [])
    {ledger_digest, ledger_ok?} = ledger_digest(run, events, result)

    receipt =
      Receipt.new(%{
        identity: identity(run, events),
        authority: %{
          ceiling: Keyword.get(opts, :ceiling, "CONSTRUCT"),
          grant: Keyword.get(opts, :grant, "NONE"),
          actor: Keyword.get(opts, :actor, "ash_pplan")
        },
        consequence: consequence(run),
        replay: replay(run, events, ledger_digest, ledger_ok?, opts),
        standing: standing_field(result, ledger_digest, run)
      })

    with :ok <- Receipt.validate(receipt), do: {:ok, receipt}
  end

  defp subject_id(run, events) do
    Map.get(run, :subject_id) || Enum.find_value(events, & &1.subject_id)
  end

  defp identity(run, events) do
    case {subject_id(run, events), Map.get(run, :run_id)} do
      {nil, _} ->
        nil

      {_, nil} ->
        nil

      {subject, run_id} ->
        %{subject: subject, run_id: run_id}
        |> put_if(:repo, run[:repo])
        |> put_if(:subject_sha, run[:head])
        |> put_if(:base_sha, run[:base])
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp consequence(%{consequence: checks} = run) when is_list(checks) do
    %{
      commits: [],
      files_changed: [],
      remote_effects: Enum.map(checks, fn {name, ok?} -> "#{name}=#{ok?}" end),
      observed: Map.get(run, :observation, %{})
    }
  end

  defp consequence(_run), do: nil

  defp standing_field(result, digest, run) do
    anchor = Map.get(run, :head) || "unanchored"

    case result do
      :alive ->
        %{value: "ALIVE", derived_from: "ledger #{digest} at #{anchor}"}

      {:lost, [first | _] = broken} ->
        %{
          value: "REFUSED(#{Enum.join(broken, ",")})",
          derived_from: "ledger #{digest} at #{anchor}",
          broken_term: Receipt.layer_term(first)
        }
    end
  end

  # One pending + one outcome per executed event, then a seal; the digest is the seal's hash.
  defp ledger_digest(run, events, result) do
    subject = to_string(subject_id(run, events) || "")
    final = if result == :alive, do: "ALIVE", else: "REFUSED"

    built =
      Enum.reduce_while(events, {:ok, []}, fn e, {:ok, chain} ->
        task = to_string(e.attributes.task)
        id = "#{e.id}"

        with {:ok, c} <- Chain.append_pending(chain, "p:" <> id, subject, task),
             {:ok, c} <- Chain.append_outcome(c, "o:" <> id, "ALIVE", subject, task) do
          {:cont, {:ok, c}}
        else
          error -> {:halt, error}
        end
      end)

    with {:ok, chain} <- built,
         {:ok, chain} <- Chain.seal(chain, "seal", final, subject) do
      {Chain.head(chain), events != [] and Chain.verify(chain)}
    else
      _ -> {nil, false}
    end
  end

  defp replay(_run, _events, _digest, false, _opts), do: nil

  defp replay(_run, events, digest, true, opts) do
    case Keyword.get(opts, :replay_commands, []) do
      [] ->
        nil

      commands ->
        %{
          commands: commands,
          ledger_digest: digest,
          ledger_algorithm: Chain.algorithm(),
          evidence: if(Keyword.get(opts, :evidence, true), do: evidence(events), else: %{})
        }
    end
  end

  # OCEL 2.0 JSON digest (pure) plus the ex4pm envelope validation when ex4pm is loadable.
  defp evidence(events) do
    ocel =
      case ProcessEvidence.export(events, :ocel2_json) do
        {:ok, json} -> %{ocel2_sha256: :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)}
        {:error, _} -> %{}
      end

    Map.put(ocel, :ex4pm, ex4pm_status(events))
  end

  defp ex4pm_status(events) do
    if Code.ensure_loaded?(AshEx4pm) and AshEx4pm.available?() do
      case AshEx4pm.validate(events) do
        {:ok, _} -> "valid"
        _ -> "invalid"
      end
    else
      "unsupported"
    end
  end
end
