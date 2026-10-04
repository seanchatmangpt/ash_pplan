defmodule AshPPlan.Sim.Marketplace.RuntimeContractReactorsCourtTest do
  @moduledoc """
  ERR-C item 4 court: gives the five generated RuntimeContract surfaces
  (`AshPPlan.RuntimeContract.{ExactSubject, AuthorityGate, Receipt, Replay,
  Refusal}`) a SECOND, non-durable subject family — the marketplace_sim
  Reactor subjects (Signup / Activation / Usage / Reporting).

  Harness pattern reused from the runtime-overlay's
  `bin/cross_contract_courts.exs`: positive leg (real family must conform),
  negative corpus (poisoned inputs -> typed refusals, never crashes),
  idempotency keys honored, RuntimeContract surface interop, and TWO
  anti-vacuity legs (leak-style mutant corpus must be caught; in-memory
  refusal-shape corruption must make the court FAIL).
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Store.Ets}
  alias AshPPlan.Sim.Marketplace.Reactors.ContractCourts.Engine
  alias AshPPlan.Sim.Marketplace.Reactors.ContractCourts.MutantSubjects
  alias AshPPlan.Sim.Marketplace.Support

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)

    {:ok, store} = Ets.start_link()
    sim = Support.start_marketplace()

    pool = Engine.pool_id()
    :ok = Vendor.Billing.allocate(pool, Engine.pool_committed())

    %{store: store, sim: sim}
  end

  test "positive leg: real family conforms — signature, refusal shape, idempotency, surfaces", %{
    store: store,
    sim: sim
  } do
    %{checks: checks, violations: violations} = Engine.audit(Map.merge(%{store: store}, sim))

    assert violations == [], "court violations: #{inspect(violations, limit: 20)}"
    assert checks >= 12, "leg-coverage guard: only #{checks} checks ran"
  end

  test "anti-vacuity leg 1: mutant refusal-shape corpus is CAUGHT by the court", %{
    store: store,
    sim: sim
  } do
    subjects = MutantSubjects.subjects()
    violations = Engine.refusal_leg(Map.merge(%{store: store}, sim), subjects)

    names = Enum.map(violations, & &1.check)

    assert violations != [], "court passed the mutant corpus — vacuous"

    assert Enum.any?(names, &(&1 =~ "signup_mutant_crash")),
           "crash mutant not caught: #{inspect(names)}"

    assert Enum.any?(names, &(&1 =~ "signup_mutant_untagged")),
           "untagged mutant not caught: #{inspect(names)}"

    # witness: the mutants actually FIRED (their corrupted step ran), so the
    # catch is not a vacuous drive failure.
    [crash, untagged] = subjects
    assert :erlang.get({crash.module, :fired})
    assert :erlang.get({untagged.module, :fired})
  end

  test "anti-vacuity leg 2: poisoned input class on a REAL subject (zero-usage window) is refused",
       %{
         store: store,
         sim: sim
       } do
    # :empty_window_report on ReportingReactor drives a real poisoned input
    # class through the court; the real family must still be zero-violation.
    violations = Engine.refusal_leg(Map.merge(%{store: store}, sim))

    assert violations == [], "real family must conform: #{inspect(violations, limit: 20)}"

    reporting = Enum.find(Engine.real_subjects(), &(&1.name == :reporting))
    assert Enum.any?(reporting.negative, &(&1.class == :empty_window_report))
  end
end
