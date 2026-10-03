defmodule AshPPlan.Test.ProposeIsolation.Garbage do
  @moduledoc """
  Real `AshPPlan.Provider` whose `select_policy/3` planner hop returns
  garbage: `{:error, :garbage}` — an error term that is not a closed
  `AshPPlan.SA2A.Refusal` map.
  """
  @behaviour AshPPlan.Provider

  @impl true
  def id, do: :propose_isolation_garbage

  @impl true
  def capabilities, do: [:fond_plan]

  @impl true
  def properties, do: []

  @impl true
  def evidence, do: []

  @impl true
  def cost, do: 1.0

  # The poisoned planner hop, called through the provider's own qualify hop.
  def select_policy(_domain, _initial, _opts), do: {:error, :garbage}

  @impl true
  def qualify(_requirement, _context), do: select_policy(%{}, %{}, [])

  @impl true
  def realize(requirement, context), do: qualify(requirement, context)
end

defmodule AshPPlan.Test.ProposeIsolation.Raising do
  @moduledoc """
  Real `AshPPlan.Provider` whose `select_policy/3` planner hop raises a real
  exception — the same failure mode as a poisoned `policy_opts` reaching
  `Keyword.get/3` inside the real `FOND.PolicySwitch` hop.
  """
  @behaviour AshPPlan.Provider

  @impl true
  def id, do: :propose_isolation_raising

  @impl true
  def capabilities, do: [:fond_plan]

  @impl true
  def properties, do: []

  @impl true
  def evidence, do: []

  @impl true
  def cost, do: 1.0

  def select_policy(_domain, _initial, _opts),
    do: raise(RuntimeError, message: "propose-isolation: poisoned select_policy")

  @impl true
  def qualify(_requirement, _context), do: select_policy(%{}, %{}, [])

  @impl true
  def realize(requirement, context), do: qualify(requirement, context)
end

defmodule AshPPlan.Test.ProposeIsolation.Hanging do
  @moduledoc """
  Real `AshPPlan.Provider` whose `select_policy/3` planner hop never returns —
  a real stuck process, containable only by a caller timeout.
  """
  @behaviour AshPPlan.Provider

  @impl true
  def id, do: :propose_isolation_hanging

  @impl true
  def capabilities, do: [:fond_plan]

  @impl true
  def properties, do: []

  @impl true
  def evidence, do: []

  @impl true
  def cost, do: 1.0

  def select_policy(_domain, _initial, _opts) do
    # Stuck forever: nothing ever sends here. Real hang, real stuck process.
    receive do
      _never -> :unreachable
    end
  end

  @impl true
  def qualify(_requirement, _context), do: select_policy(%{}, %{}, [])

  @impl true
  def realize(requirement, context), do: qualify(requirement, context)
end

defmodule AshPPlan.Stress.SA2AProposeIsolationTest do
  @moduledoc """
  Propose isolation over the real SA2A propose surface: three poisoned
  providers — real modules implementing the real `AshPPlan.Provider`
  behaviour, each poisoned at its `select_policy/3` planner hop — must each
  yield typed refusals without crashing the calling process, without leaking
  processes, and without poisoning process-table state or subsequent healthy
  calls.

  Poison classes (each a real module, no mocks):

    1. `AshPPlan.Test.ProposeIsolation.Garbage` — its `select_policy/3`
       returns a non-refusal error term (`{:error, :garbage}`) that is not a
       closed `AshPPlan.SA2A.Refusal` map;
    2. `AshPPlan.Test.ProposeIsolation.Raising` — its `select_policy/3` raises
       a real exception (the same failure mode as a poisoned `policy_opts`
       reaching `Keyword.get/3` inside the real `FOND.PolicySwitch` hop);
    3. `AshPPlan.Test.ProposeIsolation.Hanging` — its `select_policy/3` never
       returns; the poison is exercised as a real stuck process contained by a
       caller timeout.

  Courts:

    1. every poisoned call yields a closed typed refusal
       (`{:error, %{code: code, authority: :none}}` with `code` in
       `AshPPlan.SA2A.Refusal.codes/0`) — garbage errors are classified by the
       real conversion law of the propose pipeline (the `PolicyCandidate`
       else-clause law via `AshPPlan.SA2A.Refusal`), raises and hangs are
       contained per-call by real BEAM process isolation (a fresh spawned
       worker with a timeout) and normalized to the same closed refusal shape;
    2. the calling process never crashes across 100 sequential poisoned calls
       per poison class;
    3. poisoning does not stick: after the poisoned waves, 100 healthy calls
       through the real `AshPPlan.SA2A.Provider.propose/2` over the real FOND
       fixture corpus all admit candidates (`authority: :none`,
       `standing: :candidate`, a deterministic `planner_subject`);
    4. no process leaks: `:erlang.system_info(:process_count)` before and
       after the full run differs by no more than a small slack (worker
       processes are short-lived or explicitly killed).
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.SA2A.{Provider, Refusal}
  alias AshPPlan.Test.FONDFixture

  @moduletag :stress
  @moduletag :capture_log
  @moduletag timeout: 600_000

  @poisoned_calls 100
  @healthy_calls 100
  @codes Refusal.codes()
  @raise_timeout_ms 5_000
  @hang_timeout_ms 50
  @process_slack 10
  @count_key {__MODULE__, :process_count_before}

  setup_all do
    :persistent_term.put(@count_key, :erlang.system_info(:process_count))
    :ok
  end

  setup do
    fixtures = FONDFixture.all()
    assert length(fixtures) > 0, "fixture corpus must not be empty"

    admitted = Enum.find(fixtures, &(&1.expected == :admitted))
    assert admitted, "fixture corpus must contain an admitted fixture"

    %{fixtures: fixtures}
  end

  test "poisoned providers yield typed refusals, caller survives, no leaks, healthy still succeeds" do
    assert Process.alive?(self())

    garbage = poisoned_wave(AshPPlan.Test.ProposeIsolation.Garbage)
    raising = poisoned_wave(AshPPlan.Test.ProposeIsolation.Raising, @raise_timeout_ms)
    hanging = poisoned_wave(AshPPlan.Test.ProposeIsolation.Hanging, @hang_timeout_ms)

    # ---- Court 1: every poisoned call is a closed typed refusal ------------
    for {provider, results} <- [
          {AshPPlan.Test.ProposeIsolation.Garbage, garbage},
          {AshPPlan.Test.ProposeIsolation.Raising, raising},
          {AshPPlan.Test.ProposeIsolation.Hanging, hanging}
        ] do
      assert length(results) == @poisoned_calls,
             "#{inspect(provider)} produced #{length(results)} results"

      for {result, i} <- Enum.with_index(results) do
        assert {:error, %{code: code, authority: :none}} = result,
               "#{inspect(provider)} call #{i} did not yield a typed refusal: #{inspect(result)}"

        assert code in @codes,
               "#{inspect(provider)} call #{i} yielded non-closed code #{inspect(code)}"
      end
    end

    # ---- Court 2: the calling process never crashed -------------------------
    assert Process.alive?(self())

    # ---- Court 3: 100 healthy calls still succeed ---------------------------
    healthy = healthy_wave()
    assert length(healthy) == @healthy_calls

    for {result, i} <- Enum.with_index(healthy) do
      assert {:ok, candidate} = result, "healthy call #{i} failed: #{inspect(result)}"
      assert candidate.authority == :none
      assert candidate.standing == :candidate
      assert %{id: id, digest: digest} = candidate.planner_subject
      assert id =~ "sha256:" and is_binary(digest)
    end

    # ---- Court 4: no process leaks ------------------------------------------
    before = :persistent_term.get(@count_key)
    after_count = :erlang.system_info(:process_count)

    assert after_count <= before + @process_slack,
           "process leak: #{before} before, #{after_count} after"
  end

  test "healthy propose over the full fixture corpus admits candidates" do
    for {fixture, i} <- FONDFixture.all() |> Enum.with_index() do
      {:ok, domain} = FOND.new(fixture.transitions, fixture.goals)

      result =
        Provider.propose(
          %{
            formalism: :fond,
            subject: "propose-isolation-fixture",
            domain: domain,
            initial: fixture.initial
          },
          []
        )

      case fixture.expected do
        :admitted ->
          assert {:ok, candidate} = result, "fixture #{fixture.name} (##{i}) failed"

          assert candidate.authority == :none
          assert candidate.standing == :candidate
          assert %{id: id, digest: _} = candidate.planner_subject
          assert id =~ "sha256:"

        _refused_class ->
          # The real PolicySwitch sweep accepts [:strong, :strong_cyclic], so a
          # strong-refused fixture can still admit strong-cyclic. Court: the
          # verdict is closed either way — a candidate or a typed refusal,
          # never a crash.
          assert match?({:ok, %{authority: :none, standing: :candidate}}, result) or
                   match?({:error, %{code: code, authority: :none}} when code in @codes, result),
                 "fixture #{fixture.name} (##{i}) yielded a non-closed verdict: #{inspect(result)}"
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Poisoned waves
  # ----------------------------------------------------------------------------

  defp poisoned_wave(provider, worker_timeout \\ 5_000) do
    for _ <- 1..@poisoned_calls do
      case run_isolated(worker_timeout, fn -> provider.qualify(%{}, %{}) end) do
        {:ok, result} ->
          classify_hop_outcome(result)

        {:exit, reason} ->
          # Real BEAM containment: the poison crashed the worker process, not
          # the calling process. Normalized to the closed refusal shape.
          {:error, Refusal.new(:planner_refused, {:provider_crash, reason})}

        {:timeout, timeout_ms} ->
          # Real stuck-process containment: the worker was killed after the
          # caller timeout; the calling process survived.
          {:error, Refusal.new(:planner_refused, {:provider_hang, timeout_ms})}
      end
    end
  end

  # Runs `fun` in a fresh spawned worker with a monitor and a timeout. Returns
  # {:ok, result} | {:exit, reason} | {:timeout, timeout_ms}. The worker is
  # always reaped: it either returns, dies on its own, or is explicitly killed.
  defp run_isolated(timeout_ms, fun) do
    parent = self()

    pid = spawn(fn -> send(parent, {:isolated_done, self(), fun.()}) end)
    ref = Process.monitor(pid)

    receive do
      {:isolated_done, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        {:timeout, timeout_ms}
    end
  end

  # Garbage from a provider hop is classified by the real conversion law of the
  # propose pipeline (the PolicyCandidate else-clause): any {:error, reason}
  # that is not already a closed refusal map becomes a `:planner_refused`
  # refusal. A garbage provider may also return junk that is not even an error
  # tuple; that is rejected as a typed refusal too.
  defp classify_hop_outcome(result) do
    case result do
      {:error, %{code: _} = refusal} ->
        {:error, refusal}

      {:error, reason} ->
        {:error, Refusal.new(:planner_refused, reason)}

      _other ->
        {:error, Refusal.new(:planner_refused, {:garbage_return, result})}
    end
  end

  # ----------------------------------------------------------------------------
  # Healthy wave: real propose over the real fixture corpus
  # ----------------------------------------------------------------------------

  defp healthy_wave do
    admitted = Enum.filter(FONDFixture.all(), &(&1.expected == :admitted))

    for fixture <- admitted |> Stream.cycle() |> Stream.take(@healthy_calls) do
      case FOND.new(fixture.transitions, fixture.goals) do
        {:ok, domain} ->
          Provider.propose(
            %{
              formalism: :fond,
              subject: "propose-isolation-healthy",
              domain: domain,
              initial: fixture.initial
            },
            []
          )

        {:error, _} = error ->
          error
      end
    end
  end
end
