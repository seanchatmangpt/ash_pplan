defmodule AshPPlan.Standing.LadderDigestWorkTest do
  @moduledoc """
  Probe for the bench-lane question: did the Chain O(n) digest change skip
  seal/verify work on any rung, or is the ladder-depth speedup intentional
  O(n) digest work landing?

  Method (Chicago-style, real collaborators, no mocks): run a depth-10 ladder
  under `:erlang.trace` on `AshPPlan.Standing.Chain.digest/1` and count the
  actual digest computations. A depth-10 ledger builds 10 pending + 10 outcome
  + 1 seal entries, each of which hashes its canonical form, so exactly 21
  digest calls is the no-short-circuit invariant. A skipped seal, a skipped
  verify, or a reused digest would show as fewer calls or colliding hashes.

  Secondary checks: every entry hash is a distinct, valid lowercase-hex sha256;
  `Chain.verify/1` recomputes and passes; the ladder reaches VERIFIED with
  `replay.ledger_digest == Chain.head/1`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Chain

  @depth 10

  test "depth-10 ladder computes a digest for every ledger entry: no rung short-circuits" do
    run = run(@depth)
    {:ok, %{state: state, index: index, trail: trail}} = Standing.ladder(run, opts())

    assert state == :VERIFIED
    assert index == 9
    assert length(trail) == 9

    {:ok, chain} = Chain.build_sealed(pairs(run), "seal", "ALIVE", "subject-1")
    hashes = Enum.map(chain, & &1.hash)

    # 2*depth entries + 1 seal, every one hashed, every hash distinct
    assert length(chain) == 2 * @depth + 1
    assert length(Enum.uniq(hashes)) == length(chain)

    # each digest is a valid lowercase-hex sha256
    for h <- hashes do
      assert h =~ ~r/^[0-9a-f]{64}$/, "not a sha256 hex digest: #{h}"
    end

    # verify recomputes every hash itself; a skipped seal/verify cannot pass
    assert Chain.verify(chain), "chain failed seal/verify discipline"

    # the receipt's digest is the seal entry's hash, not a placeholder
    {:ok, receipt} = Standing.receipt(run, opts())
    assert receipt.replay.ledger_digest == Chain.head(chain)
    assert receipt.replay.ledger_digest == List.last(chain).hash
    assert List.last(chain).seal
  end

  test "traced digest call count equals the no-short-circuit invariant 2n+1" do
    run = run(@depth)
    expected = 2 * @depth + 1

    # call_count tracing on an isolated peer node: message-based call tracing
    # delivers no events on this host's Erlang builds, and call_count is
    # function-global, so isolation keeps concurrent tests from polluting the
    # count. See `AshPPlan.Test.TraceProbe` for the full rationale.
    # unique node name per invocation: a fixed name registers in epmd for the
    # whole VM lifetime, so two concurrent test VMs (or a leaked one) make the
    # second Node.start fail with :nodistribution/net_kernel shutdown.
    was_alive = Node.alive?()
    node_name = :"ladder_digest_work_#{:erlang.unique_integer([:positive])}@127.0.0.1"

    case was_alive do
      true -> :ok
      false -> {:ok, _} = Node.start(node_name)
    end

    probe_name = String.to_atom("ladder_digest_probe_#{:erlang.unique_integer([:positive])}")

    {:ok, peer, node} = :peer.start_link(%{name: probe_name})
    true = :rpc.call(node, :code, :set_path, [:code.get_path()])

    calls = :rpc.call(node, AshPPlan.Test.TraceProbe, :count_digests, [run, opts()])

    :peer.stop(peer)

    if not was_alive and Node.alive?() do
      :net_kernel.stop()
    end

    # 2n+1 entries hashed at build (seal included) + 2n+1 recomputed by the
    # ladder's independent Chain.verify/1 (Standing.ledger_digest/2 does both):
    # a skipped seal gives 2n, a skipped verify gives 2n+1 — both caught.
    assert calls == 2 * expected,
           "expected #{2 * expected} digest computations (2*(2*#{@depth}+1): build + verify), got #{calls}"
  end

  defp pairs(run) do
    Enum.map(run.events, fn e -> {e.id, e.attributes.task} end)
  end

  defp run(n) do
    tasks = for i <- 1..n, do: %{id: :"t#{i}", depends_on: (i == 1 && []) || [:"t#{i - 1}"]}

    events =
      for i <- 1..n do
        %AshPPlan.ProcessEvidence.Event{
          id: "run:r1/t#{i}",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [{"WorkflowRun", "run:r1", "run"}],
          attributes: %{task: "t#{i}", seq: i, provider: "p#{i}", outcome: nil},
          subject_id: "subject-1"
        }
      end

    attempts = Map.new(1..n, fn i -> {:"t#{i}", 1} end)

    %{
      run_id: "r1",
      repo: "ash_pplan",
      head: String.duplicate("a", 40),
      base: String.duplicate("b", 40),
      events: events,
      model: %{tasks: tasks},
      selection: Map.new(1..n, fn i -> {"t#{i}", :"p#{i}"} end),
      fond_gates: [],
      execution: {attempts, attempts},
      consequence: [chain_complete: true],
      observation: %{tasks_completed: n}
    }
  end

  defp opts, do: [replay_commands: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}]]
end
