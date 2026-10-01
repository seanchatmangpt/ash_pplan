defmodule AshPPlan.Examples.UltraCode.Steps do
  @moduledoc """
  Real local Reactor steps for the UltraCode example workflow
  (observe -> select -> execute -> integrate -> verify) plus two real provider
  implementations for the `Agent.Execute` capability: a cheap `:flaky` provider
  whose step always fails, and a costlier `:steady` fallback.

  A frontier is a list of items `%{id, status: :open | :closed, deps: [id]}`.
  Steps read their input leniently: the workflow input is `%{frontier: [...]}`
  and upstream results are maps merged by key, whatever argument names the
  projection chose. No step grants DO authority.
  """

  @doc """
  Merge the workflow `:input` map with predecessor results; predecessor results
  (arguments in key order) win over the original input.
  """
  @spec upstream(map()) :: map()
  def upstream(arguments) do
    base =
      case Map.get(arguments, :input) do
        %{} = m -> m
        _ -> %{}
      end

    arguments
    |> Map.delete(:input)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(base, fn
      {_k, %{} = m}, acc when not is_struct(m) -> Map.merge(acc, m)
      _, acc -> acc
    end)
  end

  defmodule Observe do
    @moduledoc "Observe the frontier: the open items."
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      ctx = AshPPlan.Examples.UltraCode.Steps.upstream(arguments)
      frontier = Map.get(ctx, :frontier, [])
      {:ok, %{frontier: frontier, open: for(i <- frontier, i.status == :open, do: i.id)}}
    end
  end

  defmodule Select do
    @moduledoc "Select the first open item whose dependencies are all closed."
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      %{frontier: frontier} = AshPPlan.Examples.UltraCode.Steps.upstream(arguments)
      closed = for i <- frontier, i.status == :closed, into: MapSet.new(), do: i.id

      case Enum.find(
             frontier,
             &(&1.status == :open and Enum.all?(&1.deps, fn d -> d in closed end))
           ) do
        nil -> {:error, :nothing_selectable}
        item -> {:ok, %{frontier: frontier, selected: item.id}}
      end
    end
  end

  defmodule Execute do
    @moduledoc "Execute the selected item: deterministic digest of its id. `fail?: true` always fails."
    use Reactor.Step

    @impl true
    def run(arguments, _context, options) do
      if Keyword.get(options, :fail?, false) do
        {:error, {:executor_failed, Keyword.get(options, :executor, :unknown)}}
      else
        %{frontier: frontier, selected: id} =
          AshPPlan.Examples.UltraCode.Steps.upstream(arguments)

        digest = :crypto.hash(:sha256, to_string(id)) |> Base.encode16(case: :lower)

        {:ok,
         %{
           frontier: frontier,
           selected: id,
           result: %{id: id, digest: digest, executor: Keyword.get(options, :executor, :steady)}
         }}
      end
    end
  end

  defmodule Integrate do
    @moduledoc "Integrate the result: close the selected item in the frontier."
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      %{frontier: frontier, selected: id, result: result} =
        AshPPlan.Examples.UltraCode.Steps.upstream(arguments)

      frontier =
        Enum.map(frontier, fn i -> if i.id == id, do: %{i | status: :closed}, else: i end)

      {:ok, %{frontier: frontier, selected: id, result: result}}
    end
  end

  defmodule Verify do
    @moduledoc "Verify: the item is closed and its digest recomputes."
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      %{frontier: frontier, selected: id, result: result} =
        AshPPlan.Examples.UltraCode.Steps.upstream(arguments)

      closed? = Enum.any?(frontier, &(&1.id == id and &1.status == :closed))
      expected = :crypto.hash(:sha256, to_string(id)) |> Base.encode16(case: :lower)

      if closed? and result.digest == expected do
        {:ok,
         %{
           verified: true,
           closed: id,
           open: for(i <- frontier, i.status == :open, do: i.id),
           executor: result.executor
         }}
      else
        {:error, {:verification_failed, id}}
      end
    end
  end

  defmodule Record do
    @moduledoc "Evidence.Record: passes upstream results through with a content digest."
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      upstream = AshPPlan.Examples.UltraCode.Steps.upstream(arguments)
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(upstream, [:deterministic]))
      {:ok, Map.put(upstream, :evidence_digest, Base.encode16(digest, case: :lower))}
    end
  end

  defmodule CheckAuthority do
    @moduledoc "Authority.Check: admits only ceilings at or below :construct; never grants DO."
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      upstream = AshPPlan.Examples.UltraCode.Steps.upstream(arguments)

      case Map.get(upstream, :authority, :construct) do
        ceiling when ceiling in [:observe, :select, :construct] ->
          {:ok, Map.put(upstream, :authority_ceiling, ceiling)}

        other ->
          {:error, {:authority_exceeds_ceiling, other}}
      end
    end
  end

  defmodule Providers do
    @moduledoc false

    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour AshPPlan.Provider
        @opts opts

        @impl true
        def id, do: @opts[:id]
        @impl true
        def capabilities, do: @opts[:capabilities]
        @impl true
        def properties, do: []
        @impl true
        def evidence, do: []
        @impl true
        def cost, do: @opts[:cost]
        @impl true
        def qualify(_requirement, _context), do: :ok

        @impl true
        def realize(%{capability: cap}, _context) do
          case Map.fetch(@opts[:table], cap) do
            {:ok, {op, options}} ->
              {:ok,
               %AshPPlan.Realization{
                 capability: cap,
                 provider: id(),
                 binding: %{adapter: :ultracode, op: op},
                 options: options
               }}

            :error ->
              {:error, {:unsupported_capability, cap}}
          end
        end
      end
    end
  end

  defmodule Local do
    @moduledoc "Steady local provider: realizes every UltraCode capability."
    use AshPPlan.Examples.UltraCode.Steps.Providers,
      id: :ultracode_local,
      cost: 2,
      capabilities: ~w(Work.Observe Work.Select Agent.Execute Work.Integrate Verification.Check),
      table: %{
        "Work.Observe" => {:work_observe, []},
        "Work.Select" => {:work_select, []},
        "Agent.Execute" => {:agent_execute, [executor: :steady]},
        "Work.Integrate" => {:work_integrate, []},
        "Verification.Check" => {:verification_check, []}
      }
  end

  defmodule Flaky do
    @moduledoc "Cheap provider for Agent.Execute whose step always fails; sealing it must leave Local lawful."
    use AshPPlan.Examples.UltraCode.Steps.Providers,
      id: :ultracode_flaky,
      cost: 1,
      capabilities: ~w(Agent.Execute),
      table: %{"Agent.Execute" => {:agent_execute, [fail?: true, executor: :flaky]}}
  end

  @doc "The UltraCode workflow description accepted by `AshPPlan.Workflow.Model.new/1`."
  @spec workflow() :: keyword()
  def workflow do
    [
      name: :ultracode,
      goal: :close_frontier,
      tasks: [
        [id: :observe, capability: "Work.Observe", authority: :observe],
        [id: :select, capability: "Work.Select", after: [:observe], authority: :observe],
        [
          id: :execute,
          capability: "Agent.Execute",
          after: [:select],
          authority: :construct,
          outcomes: [:success, :failure]
        ],
        [id: :integrate, capability: "Work.Integrate", after: [:execute], authority: :construct],
        [id: :verify, capability: "Verification.Check", after: [:integrate], authority: :observe]
      ]
    ]
  end
end
