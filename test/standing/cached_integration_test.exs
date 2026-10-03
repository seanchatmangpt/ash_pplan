defmodule AshPPlan.Standing.CachedIntegrationTest do
  @moduledoc """
  Integration court for `AshPPlan.Standing.receipt_cached/2` against the real
  `Standing.receipt/2` call shapes used by the repo's courts:

    1. the ALIVE five-field receipt shape (`test/standing_test.exs`),
    2. the REFUSED receipt shape (execution layer broken),
    3. the `{:error, %{broken_term: ...}}` refusal shape (missing identity).

  Byte identity is asserted between `receipt/2` and `receipt_cached/2` on each
  shape (first call, cache miss; and a second call, cache hit). Plus the
  staleness falsifier: events appended between two `receipt_cached/2` calls
  change the evidence identity, so the second call recomputes and returns a
  different receipt (different ledger digest) — never the stale one.

  No mocks: the evidence structs are the real collaborators.
  """

  # non-async: setup calls Cached.clear() on the single global receipt-cache
  # ETS table; async runs wipe entries out from under the exact-size eviction
  # courts (receipt_cached_test / cached_adversarial_test) and flake them.
  use ExUnit.Case, async: false

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  setup do
    Cached.clear()
    :ok
  end

  # Call shape 1: the conforming ALIVE run from test/standing_test.exs.
  defp alive_run do
    %{
      run_id: "r-alive",
      repo: "ash_pplan",
      head: @head,
      base: @base,
      events: [
        event("admit", 1, "p1"),
        event("pay", 2, "p2", "authorized"),
        event("ship", 3, "p3")
      ],
      model: %{
        tasks: [
          %{id: :admit, depends_on: []},
          %{id: :pay, depends_on: [:admit]},
          %{id: :ship, depends_on: [:pay]}
        ]
      },
      selection: %{admit: :p1, pay: :p2, ship: :p3},
      fond_gates: [%{task: "pay", admit: ["authorized"], successors: ["ship"]}],
      execution: {%{pay: 1}, %{pay: 1}},
      consequence: [order_fulfilled: true, one_shipment: true],
      observation: %{shipments: 1}
    }
  end

  # Call shape 2: the refused run (execution layer broken) from test/standing_test.exs.
  defp refused_run do
    %{alive_run() | run_id: "r-refused", execution: {%{pay: 2}, %{pay: 1}}}
  end

  # Call shape 3: the identity-less run (R_missing_identity) from test/standing_test.exs.
  defp identityless_run do
    %{alive_run() | run_id: nil}
  end

  # Call shape 1 with one task executed after the original three: appending
  # this event changes the evidence, so the receipt must change with it.
  defp with_appended_event(run) do
    %{
      run
      | events:
          run.events ++
            [
              event("audit", 4, "p4")
            ],
        model: %{
          tasks: run.model.tasks ++ [%{id: :audit, depends_on: [:ship]}]
        },
        selection: Map.put(run.selection, :audit, :p4),
        observation: %{shipments: 1, audited: true}
    }
  end

  defp event(task, seq, provider, outcome \\ nil) do
    %Event{
      id: "run:r1/#{task}",
      activity: "task_succeeded",
      timestamp: ~U[2026-10-01 00:00:00Z],
      objects: [{"WorkflowRun", "run:r1", "run"}],
      attributes: %{task: task, seq: seq, provider: provider, outcome: outcome},
      subject_id: "subject-1"
    }
  end

  defp cmds,
    do: [%{cmd: "mix test test/standing/cached_integration_test.exs", cwd: File.cwd!(), exit: 0}]

  test "call shape 1 (ALIVE): receipt_cached is byte-identical to receipt/2, miss and hit" do
    run = alive_run()
    opts = [replay_commands: cmds()]

    assert {:ok, direct} = Standing.receipt(run, opts)
    assert direct.standing.value == "ALIVE"

    assert {:ok, first} = Standing.receipt_cached(run, opts)
    assert first == direct

    # cache hit must reproduce the same receipt, not a mutated one
    assert {:ok, second} = Standing.receipt_cached(run, opts)
    assert second == direct
  end

  test "call shape 2 (REFUSED receipt): cached refusal is byte-identical to receipt/2" do
    run = refused_run()
    opts = [replay_commands: cmds()]

    assert {:ok, direct} = Standing.receipt(run, opts)
    assert direct.standing.value == "REFUSED(execution_correct)"

    assert {:ok, first} = Standing.receipt_cached(run, opts)
    assert first == direct

    assert {:ok, second} = Standing.receipt_cached(run, opts)
    assert second == direct
  end

  test "call shape 3 (error refusal): cached error is byte-identical to receipt/2" do
    run = identityless_run()
    opts = [replay_commands: cmds()]

    assert {:error, direct} = Standing.receipt(run, opts)
    assert direct.broken_term == "R_missing_identity"

    assert {:error, first} = Standing.receipt_cached(run, opts)
    assert first == direct

    assert {:error, second} = Standing.receipt_cached(run, opts)
    assert second == direct
  end

  test "staleness falsifier: events appended between calls yield a different receipt" do
    opts = [replay_commands: cmds()]
    run = alive_run()

    {:ok, before} = Standing.receipt_cached(run, opts)

    grown = with_appended_event(run)
    assert {:ok, grown_receipt} = Standing.receipt_cached(grown, opts)

    # different evidence -> different identity -> recomputed, not stale
    refute before.replay.ledger_digest == grown_receipt.replay.ledger_digest
    refute before == grown_receipt
    assert grown_receipt.consequence.observed == %{shipments: 1, audited: true}

    # the grown receipt equals a fresh receipt/2 over the grown run
    assert {:ok, fresh} = Standing.receipt(grown, opts)
    assert grown_receipt == fresh

    # and the original key is untouched
    assert {:ok, again} = Standing.receipt_cached(run, opts)
    assert again == before
  end
end
