# SPDX-License-Identifier: MIT
#
# Tokyo depeg HARDEN lane: crash-path, refusal-vocabulary closure, and
# mutant-witness anti-vacuity hardening for the tokyo_depeg courts.

defmodule AshPPlan.TokyoDepeg.HardeningTest do
  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.Refusal
  alias AshPPlan.Test.Chicago
  alias AshPPlan.Test.TokyoDepeg.{BrokenFence, Canonical, Refusals}

  # ------------------------------------------------------------------
  # 1. Crash paths: garbage order payloads and non-JSON terms
  # ------------------------------------------------------------------

  describe "canonicalizer crash paths" do
    test "the non-finite guard covers both infinities and NaN (source pin)" do
      # OTP 27+ / Elixir 1.19 cannot CONSTRUCT a non-finite float (arithmetic
      # raises, bit-syntax float patterns refuse NaN bits), so these guards are
      # defense-in-depth against floats arriving from NIF boundaries. The
      # regression being pinned: the guard used to match only "Infinity", so a
      # negative infinity fell through and canonicalized to garbage.
      source = File.read!(Path.join(File.cwd!(), "test/support/tokyo_depeg/canonical.ex"))

      assert source =~ ~s("Infinity" ->)
      assert source =~ ~s("-Infinity" ->)
      assert source =~ ~s("NaN" ->)

      assert Regex.match?(
               ~r/raise\(ArgumentError, "JCS cannot canonicalize (infinity|NaN)"\)/,
               source
             )
    end

    test "float boundary payloads canonicalize deterministically without crashing" do
      corpus = [
        1.7976931348623157e308,
        -1.7976931348623157e308,
        5.0e-324,
        -5.0e-324,
        0.0,
        -0.0,
        2.2250738585072014e-308
      ]

      for f <- corpus do
        s = Canonical.canonical_string(%{"x" => f})
        assert s == Canonical.canonical_string(%{"x" => f}), "unstable at #{f}: #{s}"
        refute s =~ "Infinity"
        refute s =~ "NaN"
      end

      # JCS: -0.0 and 0.0 erase to the same identity
      assert Canonical.identity(%{"x" => 0.0}) == Canonical.identity(%{"x" => -0.0})
    end

    test "atoms and tuples as payload values are refused with a typed error, not a crash" do
      assert_raise ArgumentError, ~r/not JSON-shaped/, fn ->
        Canonical.canonical_string(%{"side" => :sell})
      end

      assert_raise ArgumentError, ~r/not JSON-shaped/, fn ->
        Canonical.canonical_string(%{"leg" => {:buy, 100}})
      end
    end

    test "structs are refused as UNSUPPORTED(canonicalizer-scope)" do
      assert_raise ArgumentError, ~r/UNSUPPORTED\(canonicalizer-scope\)/, fn ->
        Canonical.canonical_string(%{"ts" => ~D[2026-10-03]})
      end
    end

    test "non-string/atom/integer map keys raise the typed ArgumentError, not FunctionClauseError" do
      assert_raise ArgumentError, ~r/binary, atom, or integer map keys/, fn ->
        Canonical.canonical_string(%{{1, 2} => "x"})
      end

      assert_raise ArgumentError, ~r/binary, atom, or integer map keys/, fn ->
        Canonical.canonical_string(%{self() => "x"})
      end
    end

    test "distinct map keys that canonicalize to the same JSON key are refused (identity collision)" do
      assert_raise ArgumentError, ~r/key collision/, fn ->
        Canonical.canonical_string(%{"a" => 1, a: 2})
      end

      assert_raise ArgumentError, ~r/key collision/, fn ->
        Canonical.canonical_string(%{1 => "x", "1" => "y"})
      end
    end

    test "invalid UTF-8 binary payloads are refused" do
      assert_raise ArgumentError, ~r/valid UTF-8/, fn ->
        Canonical.canonical_string(%{"raw" => <<0xFF, 0xFE>>})
      end
    end

    test "identity of empty payloads: all empty forms are deterministic and pairwise distinct" do
      # `nil` is a legal payload (canonicalizes to `null`) and must hash stably.
      assert Canonical.identity(nil) == Canonical.identity(nil)

      empties = [nil, false, "", [], %{}]

      assert empties |> Enum.map(&Canonical.identity/1) |> Enum.uniq() |> length() ==
               length(empties),
             "empty payload forms must not collide on one identity"
    end

    test "a nil order payload and an empty order object mint DIFFERENT identities" do
      # identity of empty payloads: "absent" (null) vs "present but empty" ({})
      # must never converge, or a dropped payload would replay an empty order.
      assert Canonical.identity(nil) != Canonical.identity(%{})
      assert Canonical.identity(nil) != Canonical.identity([])
      assert Canonical.identity(%{}) != Canonical.identity([])
    end
  end

  # ------------------------------------------------------------------
  # 2. Refusal vocabulary: one closed set, no drift
  # ------------------------------------------------------------------

  describe "refusal vocabulary closure" do
    test "the closed set is a set (no duplicate members) and non-empty" do
      codes = Refusals.codes()
      assert length(codes) > 0
      assert length(Enum.uniq(codes)) == length(codes)
    end

    test "every family is represented and family/1 partitions the set" do
      assert Enum.all?(Refusals.codes(), &Refusals.in?/1)

      assert %{:alignment => true, :revocation => true, :burn_in => true, :sa2a => true} =
               Map.new(Refusals.codes(), fn c -> {Refusals.family(c), true} end)

      # a member belongs to exactly one family
      assert Refusals.family(:empty_model) == :alignment
      assert Refusals.family("REFUSED_AUTHORITY_REVOKED") == :revocation
      assert Refusals.family(:missing_subject) == :sa2a
    end

    test "SA2A production codes stay inside the closed set (drift guard against lib growth)" do
      for code <- Refusal.codes() do
        assert Refusals.in?(code),
               "SA2A.Refusal added #{inspect(code)} without registering it in " <>
                 "test/support/tokyo_depeg/refusals.ex"
      end
    end

    test "every {:refused, _} verdict atom on the tokyo surface is in the closed set (source scan)" do
      offenders =
        for path <- tokyo_sources(),
            source = File.read!(path),
            match = Regex.scan(~r/\{:refused,\s*:(\w+)/, source),
            [_ = _, atom] <- match,
            atom = String.to_atom(atom),
            not Refusals.in?(atom),
            reduce: [] do
          acc -> ["#{path}: #{inspect(atom)}" | acc]
        end

      assert offenders == [],
             "refusal atoms outside the closed vocabulary: #{inspect(offenders)}"
    end

    test "every REFUSED_* string literal on the tokyo surface is in the closed set (source scan)" do
      offenders =
        for path <- tokyo_sources(),
            source = File.read!(path),
            match = Regex.scan(~r/"(REFUSED_[A-Z_]+)"/, source),
            [_ = _, s] <- match,
            not Refusals.in?(s),
            reduce: [] do
          acc -> ["#{path}: #{s}" | acc]
        end

      assert offenders == [],
             "refusal strings outside the closed vocabulary: #{inspect(offenders)}"
    end

    test "the open-class catch-all is NOT a member of the closed set" do
      catch_all = "REFUSED(class=anything)"
      refute Refusals.in?(catch_all)
      assert Refusals.family(catch_all) == nil
    end
  end

  # ------------------------------------------------------------------
  # 3. Mutant witnesses: two independent sabotage forms, both detected
  # ------------------------------------------------------------------

  describe "fencing mutant witnesses" do
    @n 200

    defp order_id(payload), do: "tdb-hard-" <> String.slice(Canonical.identity(payload), 0, 32)

    # The property the fencing court holds: exactly one executor across the barrage.
    defp property do
      fn subject ->
        case subject.run_barrage.(@n, order_id(%{"ts" => "hardening"})) do
          :pass -> :pass
          {:fail, _} -> {:fail, :fencing}
        end
      end
    end

    test "the real check-then-act mutant is DETECTED (first sabotage form)" do
      Chicago.assert_detected!(
        "claim-CAS exactly-once (hardening)",
        correct_cas_subject(),
        [
          {"naive check-then-act dedup (no CAS)",
           %{
             run_barrage: fn n, id ->
               BrokenFence.run_barrage(n, id, :"bfa_dedup_#{System.unique_integer([:positive])}")
             end
           }}
        ],
        property()
      )
    end

    test "the write-before-check mutant is DETECTED (second sabotage form, deterministic over-execution)" do
      Chicago.assert_detected!(
        "claim-CAS exactly-once (hardening)",
        correct_cas_subject(),
        [
          {"write-before-check dedup (act before claim)",
           %{
             run_barrage: fn n, id ->
               BrokenFence.run_barrage(
                 n,
                 id,
                 :"bfb_dedup_#{System.unique_integer([:positive])}",
                 :write_before_check
               )
             end
           }}
        ],
        property()
      )
    end

    test "the write-before-check mutant deterministically over-executes (not a timing artifact)" do
      # The first sabotage form can, on a quiet machine, accidentally pass.
      # The second form cannot: every task claims before checking, so
      # `executed == n` on every run.
      {:fail, executed} =
        BrokenFence.run_barrage(
          @n,
          order_id(%{"ts" => "wbc"}),
          :"wbc1_#{System.unique_integer([:positive])}",
          :write_before_check
        )

      assert executed > 1

      assert {:fail, ^executed} =
               BrokenFence.run_barrage(
                 @n,
                 order_id(%{"ts" => "wbc"}),
                 :"wbc2_#{System.unique_integer([:positive])}",
                 :write_before_check
               ),
             "over-execution must be deterministic across runs and tables"
    end
  end

  # The production-shaped subject, Chicago-real: a TRUE atomic claim using
  # `:ets.insert_new/2` (compare-and-swap). This is the same atomicity class the
  # durable Engine's `Store.Ets.claim/5` lease provides.
  defp correct_cas_subject do
    %{
      run_barrage: fn n, id ->
        table = :"hard_cas_dedup_#{System.unique_integer([:positive])}"
        :ets.new(table, [:named_table, :public, :set])

        results =
          1..n
          |> Enum.map(fn i ->
            Task.async(fn ->
              if :ets.insert_new(table, {id, self()}) do
                {:ok, :executor}
              else
                {:ok, :replay}
              end
            end)
          end)
          |> Task.await_many(30_000)

        execs = Enum.count(results, &match?({:ok, :executor}, &1))
        if execs == 1, do: :pass, else: {:fail, execs}
      end
    }
  end

  defp tokyo_sources do
    # the surface's refusal emitter in lib, judged by the revocation courts
    Path.wildcard(Path.join(File.cwd!(), "test/tokyo_depeg/*.exs")) ++
      Path.wildcard(Path.join(File.cwd!(), "test/support/tokyo_depeg/*.ex")) ++
      [Path.join(File.cwd!(), "lib/ash_pplan/sa2a/refusal.ex")]
  end
end
