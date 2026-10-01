defmodule AshPPlan.Reactor.Durable.PolicyDriver do
  @moduledoc """
  A FOND policy the durable engine consults on each observed step outcome.

  The driver is pure data: a `AshPPlan.FOND` domain, the `initial` state, the synthesized (or
  supplied) policy and the `mode`. `new/3` synthesizes a policy with `AshPPlan.synthesize_policy/3`
  when none is given and gates it with `AshPPlan.validate_policy/4`; an inadmissible policy is a
  typed `{:error, {:inadmissible_policy, reason}}`, and `admit/1` re-gates a driver that was built
  by hand, so the engine can refuse before any effect.

  `decide/2` maps a FOND state to the admitted action (or `{:done, state}` at a goal). `observe/4`
  checks an observed successor against the outcomes the domain admits for `state x action`; an
  outcome outside that set is `{:error, {:outcome_outside_policy_domain, detail}}`, never guessed.
  `fingerprint/1` is a content hash of domain, policy, initial and mode, recorded with every
  decision so a replay under a different policy is detected.

  A driver selects structure only: `authority` is `:none` and the ceiling is `:construct`. It
  returns actions as data and never executes one; whatever executes is the caller's, under the
  caller's own authority.
  """

  alias AshPPlan.FOND

  @enforce_keys [:domain, :policy, :initial, :mode]
  defstruct [:domain, :policy, :initial, :mode, authority: :none, ceiling: :construct]

  @type t :: %__MODULE__{
          domain: FOND.t(),
          policy: map(),
          initial: term(),
          mode: FOND.mode(),
          authority: :none,
          ceiling: :construct
        }

  @doc """
  Build a driver. Options: `:mode` (default `:strong_cyclic`), `:policy` (supply one instead of
  synthesizing). Refuses an unsolvable domain or an inadmissible policy with a typed error.
  """
  @spec new(FOND.t(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(domain, initial, opts \\ []) do
    mode = Keyword.get(opts, :mode, :strong_cyclic)

    with {:ok, policy} <- policy(domain, initial, mode, Keyword.get(opts, :policy)) do
      driver = %__MODULE__{domain: domain, policy: policy, initial: initial, mode: mode}
      with :ok <- admit(driver), do: {:ok, driver}
    end
  end

  @doc "Build a driver from a workflow model's outcome topology (`Workflow.Project.FOND`)."
  @spec from_model(AshPPlan.Workflow.Model.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_model(model, opts \\ []) do
    case AshPPlan.Workflow.Project.FOND.project(model, opts) do
      {:ok, %{refusal: nil, domain: domain, initial: initial}} ->
        new(domain, initial, opts)

      {:ok, %{refusal: refusal}} ->
        {:error, {:inadmissible_policy, refusal}}

      {:error, reason} ->
        {:error, {:inadmissible_policy, reason}}
    end
  end

  @doc "Gate the driver's policy with `AshPPlan.validate_policy/4`."
  @spec admit(t() | term()) :: :ok | {:error, {:inadmissible_policy, term()}}
  def admit(%__MODULE__{domain: d, policy: p, initial: i, mode: m}) do
    case AshPPlan.validate_policy(d, p, i, m) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, {:inadmissible_policy, reason}}
    end
  end

  def admit(other), do: {:error, {:inadmissible_policy, {:not_a_driver, other}}}

  @doc "Is `state` a goal state of the domain?"
  @spec goal?(t(), term()) :: boolean()
  def goal?(%__MODULE__{domain: d}, state), do: MapSet.member?(d.goals, state)

  @doc "The policy's action for `state`, or `{:done, state}` at a goal."
  @spec decide(t(), term()) ::
          {:ok, term()} | {:done, term()} | {:error, {:outcome_outside_policy_domain, map()}}
  def decide(%__MODULE__{} = driver, state) do
    cond do
      goal?(driver, state) ->
        {:done, state}

      Map.has_key?(driver.policy, state) ->
        {:ok, Map.fetch!(driver.policy, state)}

      true ->
        {:error, {:outcome_outside_policy_domain, %{state: state, reason: :no_policy_decision}}}
    end
  end

  @doc "Check an observed successor against what the domain admits for `state x action`."
  @spec observe(t(), term(), term(), term()) ::
          {:ok, term()} | {:error, {:outcome_outside_policy_domain, map()}}
  def observe(%__MODULE__{domain: d}, state, action, observed) do
    admitted = FOND.outcomes(d, state, action)

    if observed in admitted do
      {:ok, observed}
    else
      {:error,
       {:outcome_outside_policy_domain,
        %{state: state, action: action, observed: observed, admitted: admitted}}}
    end
  end

  @doc "Content hash of domain, policy, initial state and mode."
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = d) do
    bin =
      :erlang.term_to_binary(
        {d.domain, d.policy, d.initial, d.mode},
        [:deterministic, minor_version: 2]
      )

    :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  end

  defp policy(domain, initial, mode, nil) do
    case AshPPlan.synthesize_policy(domain, initial, mode) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> {:error, {:inadmissible_policy, reason}}
    end
  end

  defp policy(_domain, _initial, _mode, policy) when is_map(policy), do: {:ok, policy}

  defp policy(_domain, _initial, _mode, other),
    do: {:error, {:inadmissible_policy, {:not_a_policy, other}}}
end
