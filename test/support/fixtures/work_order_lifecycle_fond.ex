defmodule AshPPlan.Test.WorkOrderLifecycleFOND do
  @moduledoc """
  Pure-data FOND fixture for the NatFac work-order lifecycle (ARD Tier 2 §3).

  Seven stages, intake -> dispatch -> arrival -> approval -> verification ->
  settlement -> closed, with three nondeterministic actions:

    * `fanout`  from `:intake`            -> `:dispatched` | `:no_show` (retry loop)
    * `quote`   from `:arrived`           -> `:quoted_within_nte` | `:over_nte`
                                             (`:over_nte` -> `:exception` -> bidding fallback)
    * `request_approval` from `:quoted_within_nte`
                                          -> `:approved` | `:approval_delayed` (await loop)

  Every other action is deterministic. `:closed` is the only goal.

  `mutations/0` returns named variants of the transition relation whose only
  difference from `transitions/0` is the bidding fallback edge, so a court can
  prove the edge is load-bearing rather than decorative.
  """

  alias AshPPlan.FOND

  @stages [:intake, :dispatch, :arrival, :approval, :verification, :settlement, :closed]

  @goal :closed
  @initial :intake

  @transitions %{
    # stage 1: intake -- vendor fan-out may be accepted or produce a no-show
    intake: %{fanout: [:dispatched, :no_show]},
    no_show: %{retry: [:intake]},
    # stage 2: dispatch
    dispatched: %{arrive: [:arrived]},
    # stage 3: arrival -- the quote may land within or over the NTE
    arrived: %{quote: [:quoted_within_nte, :over_nte]},
    over_nte: %{raise_exception: [:exception]},
    # bidding fallback: the exception path re-enters the approval stage
    exception: %{bidding: [:quoted_within_nte]},
    # stage 4: approval -- may be granted or delayed; delay awaits and retries
    quoted_within_nte: %{request_approval: [:approved, :approval_delayed]},
    approval_delayed: %{await: [:quoted_within_nte]},
    # stage 5: verification
    approved: %{verify: [:verified]},
    # stage 6: settlement
    verified: %{settle: [:settled]},
    # stage 7: closed
    settled: %{close: [:closed]},
    closed: %{}
  }

  @doc "The seven lifecycle stage names, in order."
  def stages, do: @stages

  @doc "Initial state of the lifecycle."
  def initial, do: @initial

  @doc "The single goal state."
  def goal, do: @goal

  @doc "The intact transition relation."
  def transitions, do: @transitions

  @doc "Builds the intact domain through `AshPPlan.FOND.new/2`."
  def domain do
    {:ok, domain} = FOND.new(@transitions, [@goal])
    domain
  end

  @doc """
  The one strong-cyclic policy this domain admits: every non-goal state has
  exactly one action, so synthesis has no choice and the pinned value is the
  only lawful answer.
  """
  def expected_policy do
    %{
      intake: :fanout,
      no_show: :retry,
      dispatched: :arrive,
      arrived: :quote,
      over_nte: :raise_exception,
      exception: :bidding,
      quoted_within_nte: :request_approval,
      approval_delayed: :await,
      approved: :verify,
      verified: :settle,
      settled: :close
    }
  end

  @doc """
  Named mutations of the bidding fallback edge, each built through
  `AshPPlan.FOND.new/2`:

    * `:bidding_removed` -- `:exception` has no actions (dead end).
    * `:bidding_stalls`  -- `:exception` keeps one action, `stall`, whose only
      outcome is `:exception` itself (closed loop with no goal path).
  """
  def mutations do
    %{
      bidding_removed: mutate(%{exception: %{}}),
      bidding_stalls: mutate(%{exception: %{stall: [:exception]}})
    }
  end

  defp mutate(overrides) do
    {:ok, domain} = FOND.new(Map.merge(@transitions, overrides), [@goal])
    domain
  end
end
