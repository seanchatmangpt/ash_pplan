defmodule AshPPlan.Hardening.ReceiptsFuzzTest do
  @moduledoc """
  HARDEN fuzz court: ExecutionReceipt and ReleaseReceipt under garbage input.

  Law under test:
    - digests never crash and never hang (deterministic term hashing)
    - unknown outcome shapes observe as `:unknown`, never asserted failures
    - ReleaseReceipt head validation is a typed refusal (ArgumentError)
    - projections (to_rdf / to_json) never leak raw control bytes or invalid UTF-8
  """

  use ExUnit.Case, async: true

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.ReleaseReceipt

  @now ~U[2026-10-03 00:00:00Z]

  defp observe_outcome(outcome) do
    ExecutionReceipt.observe("urn:ex:plan", :run_1, outcome, @now, System.monotonic_time())
  end

  describe "observe/5 garbage outcome shapes" do
    test "unmatched shapes observe as :unknown without crashing" do
      for garbage <- [
            nil,
            :ok,
            :error,
            {:ok},
            {:ok, :a, :b, :c},
            {"ok", 1},
            %{__struct__: Foo, status: :pending},
            3.14,
            [list: :outcome]
          ] do
        receipt = observe_outcome(garbage)
        assert receipt.status == :unknown
        assert is_binary(receipt.outcome_digest)
        assert String.length(receipt.outcome_digest) == 64
      end
    end

    test "unknown-status digest is deterministic and shape-distinguishing" do
      assert observe_outcome(nil).outcome_digest == observe_outcome(nil).outcome_digest
      assert observe_outcome(nil).outcome_digest != observe_outcome({:ok}).outcome_digest

      assert observe_outcome(%{__struct__: Foo, status: :a}).outcome_digest ==
               observe_outcome(%{__struct__: Foo, status: :a}).outcome_digest
    end

    test "cyclic map in a succeeded outcome does not hang or crash" do
      cyclic = %{}
      cyclic = Map.put(cyclic, :self, cyclic)
      cyclic = Map.put(cyclic, :list, [cyclic, cyclic])

      receipt = observe_outcome({:ok, cyclic})

      assert receipt.status == :succeeded
      assert String.length(receipt.outcome_digest) == 64
      # Cycles collapse to a placeholder, so a self-referential term still has
      # a stable content address.
      assert receipt.outcome_digest == observe_outcome({:ok, cyclic}).outcome_digest
    end

    test "cyclic map in a failed outcome does not hang or crash" do
      reason = %{__struct__: RuntimeError, message: "boom", cyclic: nil}
      reason = Map.put(reason, :cyclic, reason)

      receipt = observe_outcome({:error, reason})

      assert receipt.status == :failed
      assert String.length(receipt.outcome_digest) == 64
    end

    test "halted outcome with a well-formed reactor digests intermediate results" do
      reactor = %{
        state: :suspended,
        intermediate_results: %{"b" => 2, "a" => 1}
      }

      receipt = observe_outcome({:halted, reactor})

      assert receipt.status == :halted
      a = receipt.outcome_digest
      assert a == observe_outcome({:halted, reactor}).outcome_digest

      reordered = %{state: :suspended, intermediate_results: %{"a" => 1, "b" => 2}}
      assert a == observe_outcome({:halted, reordered}).outcome_digest

      changed = %{state: :suspended, intermediate_results: %{"a" => 9, "b" => 2}}
      assert a != observe_outcome({:halted, changed}).outcome_digest
    end

    test "halted outcome with a garbage reactor does not crash" do
      for garbage <- [nil, %{}, %{state: :suspended}, "not-a-reactor", 42] do
        receipt = observe_outcome({:halted, garbage})
        assert receipt.status == :halted
        assert String.length(receipt.outcome_digest) == 64
      end
    end

    test "huge binary result digests without crashing" do
      blob = :binary.copy(<<0>>, 5 * 1024 * 1024)
      receipt = observe_outcome({:ok, blob})
      assert receipt.status == :succeeded
      assert String.length(receipt.outcome_digest) == 64

      other = :binary.copy(<<1>>, 5 * 1024 * 1024)
      assert receipt.outcome_digest != observe_outcome({:ok, other}).outcome_digest
    end

    test "invalid UTF-8 binaries in results digest deterministically" do
      bad = {:ok, <<0xFF, 0xFE, 0x80, "partial">>}
      receipt = observe_outcome(bad)
      assert receipt.outcome_digest == observe_outcome(bad).outcome_digest
    end

    test "unhashable terms (funs, refs, pids) canonicalize to stable digests" do
      outcome = {:ok, %{fun: fn x -> x end, ref: make_ref(), pid: self()}}
      a = observe_outcome(outcome).outcome_digest
      b = observe_outcome(outcome).outcome_digest
      assert a == b
    end

    test "keyword-list-like maps with mixed key types digest without crashing" do
      receipt = observe_outcome({:ok, %{1 => :a, :a => 1, "s" => 2.5}})
      assert String.length(receipt.outcome_digest) == 64
    end
  end

  describe "run_identifier/1 garbage run ids" do
    test "any term renders to a valid, non-crashing string" do
      garbage = [
        1,
        -2,
        3.5,
        :atom,
        "utf8 ✓",
        <<0xFF, 0xFE>>,
        {:tuple, 1},
        [1, 2, 3],
        %{map: true},
        self(),
        make_ref(),
        fn -> :ok end
      ]

      for run_id <- garbage do
        id = ExecutionReceipt.run_identifier(run_id)
        assert is_binary(id)
        assert String.valid?(id)
      end
    end
  end

  describe "to_rdf/1 under hostile field values" do
    test "arbitrary atom status serializes as its name" do
      receipt = %ExecutionReceipt{
        plan_iri: "urn:ex:p",
        run_id: :r1,
        status: :whatever_unknown_atom,
        started_at: @now,
        finished_at: @now,
        duration_us: 0,
        outcome_digest: String.duplicate("ab", 32)
      }

      rdf = ExecutionReceipt.to_rdf(receipt)
      assert rdf =~ ~s("whatever_unknown_atom")
    end

    test "hostile run_id / plan_iri bytes are escaped, output stays one-triple-per-line" do
      receipt = %ExecutionReceipt{
        plan_iri: "urn:ex:p\"<>{}|^`\\",
        run_id: "line1\nline2 \"quoted\"",
        status: :succeeded,
        started_at: @now,
        finished_at: @now,
        duration_us: 1,
        outcome_digest: String.duplicate("0", 64)
      }

      rdf = ExecutionReceipt.to_rdf(receipt)
      lines = String.split(rdf, "\n", trim: true)
      assert length(lines) == 11

      for line <- lines do
        assert String.ends_with?(line, " .")
        refute line =~ ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/
      end
    end
  end

  describe "ReleaseReceipt typed refusals" do
    @head40 String.duplicate("a", 40)

    test "valid 40- and 64-hex heads are accepted" do
      assert %ReleaseReceipt{} = ReleaseReceipt.observe(@head40)
      assert %ReleaseReceipt{} = ReleaseReceipt.observe(String.duplicate("b", 64))
    end

    test "garbage heads raise a typed ArgumentError" do
      for bad <- [
            nil,
            42,
            :main,
            "",
            "HEAD",
            String.duplicate("a", 39),
            String.duplicate("a", 41),
            String.upcase(@head40),
            String.duplicate("g", 40),
            @head40 <> "\n",
            %{head: @head40}
          ] do
        assert_raise ArgumentError, fn -> ReleaseReceipt.observe(bad) end
      end
    end

    test "digest/3 validates the head the same way" do
      assert_raise ArgumentError, fn ->
        ReleaseReceipt.digest("not-a-sha", "26.9.6", [{"a.ttl", "00"}])
      end

      digest = ReleaseReceipt.digest(@head40, "26.9.6", [])
      assert String.length(digest) == 64
    end

    test "digest/3 is order-independent over sources and binds the head" do
      d1 = ReleaseReceipt.digest(@head40, "v", [{"a", "1"}, {"b", "2"}])
      d2 = ReleaseReceipt.digest(@head40, "v", [{"b", "2"}, {"a", "1"}])
      assert d1 == d2
      assert d1 != ReleaseReceipt.digest(String.duplicate("c", 40), "v", [{"a", "1"}, {"b", "2"}])
      assert d1 != ReleaseReceipt.digest(@head40, "w", [{"a", "1"}, {"b", "2"}])
    end

    test "to_json is deterministic and stays valid under source reordering" do
      receipt = ReleaseReceipt.observe(@head40)
      assert receipt.digest == ReleaseReceipt.observe(@head40).digest
      assert ReleaseReceipt.to_json(receipt) == ReleaseReceipt.to_json(receipt)
      assert ReleaseReceipt.to_json(receipt) =~ ~s("head": "#{@head40}")
    end
  end
end
