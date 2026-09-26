defmodule AshPPlan.FONDTLAHardeningTest do
  @moduledoc """
  Boundary, adversarial and replay falsifiers for `AshPPlan.FOND.to_tla/4`.

  The rendered module is re-read by `AshPPlan.Test.TLAReader`, an independent
  in-process checker that sees only the TLA+ text, and its verdict must equal
  `AshPPlan.FOND.validate_policy/4` on the hand corpus and on a seeded random
  corpus. Where the pinned TLC jar is present the random corpus is also sent to
  TLC. No collaborator is replaced by a double.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.Test.{FONDCorpus, TLAReader, TLCCourt}

  @modes [:strong, :strong_cyclic]
  @random_count 400

  defp domain!(transitions, goals) do
    {:ok, domain} = FOND.new(transitions, goals)
    domain
  end

  defp elixir_verdict(domain, policy, initial, mode) do
    case FOND.validate_policy(domain, policy, initial, mode) do
      {:ok, _report} -> :admitted
      {:error, _refusal} -> :refused
    end
  end

  defp render!(domain, policy, initial, mode) do
    {:ok, rendered} = FOND.to_tla(domain, policy, initial, mode)
    rendered
  end

  describe "independent reader court (no JVM needed)" do
    test "reader verdict == validate_policy == expectation on every corpus case and mode" do
      for {name, {transitions, goals, policy, initial, expected}} <- FONDCorpus.cases(),
          mode <- @modes do
        domain = domain!(transitions, goals)
        elixir = elixir_verdict(domain, policy, initial, mode)
        reader = TLAReader.check!(render!(domain, policy, initial, mode))

        assert elixir == expected[mode], "#{name} #{mode}"
        assert reader.verdict == elixir, "#{name} #{mode}: reader=#{inspect(reader)}"
      end
    end

    test "reader verdict == validate_policy on #{@random_count} seeded random domains, both modes" do
      results =
        for {transitions, goals, policy, initial} <- FONDCorpus.random(@random_count),
            mode <- @modes do
          domain = domain!(transitions, goals)
          elixir = elixir_verdict(domain, policy, initial, mode)
          reader = TLAReader.check!(render!(domain, policy, initial, mode))

          assert reader.verdict == elixir,
                 "disagreement #{mode}: elixir=#{elixir} reader=#{inspect(reader)}\n" <>
                   inspect({transitions, goals, policy, initial})

          {mode, elixir, reader.kind}
        end

      # the random corpus is non-degenerate: both verdicts and both refusal
      # kinds occur in both modes
      for mode <- @modes do
        kinds = for {^mode, _v, kind} <- results, uniq: true, do: kind
        assert Enum.sort(kinds) == [:deadlock, :liveness, :no_error], "#{mode}: #{inspect(kinds)}"
      end
    end

    test "random corpus is replayable: same seed, same domains; other seed, other domains" do
      assert FONDCorpus.random(50) == FONDCorpus.random(50)
      refute FONDCorpus.random(50) == FONDCorpus.random(50, {9, 9, 9})
    end
  end

  describe "anti-vacuity: the reader sees the rendered artifact, not the domain" do
    setup do
      retry =
        domain!(%{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}}, [:succeeded])

      two =
        domain!(%{s0: %{try: [:s0, :s1]}, s1: %{try: [:s0, :done]}, done: %{}}, [:done])

      %{retry: retry, two: two}
    end

    test "deleting SF fairness flips the strong_cyclic retry case to a liveness refusal",
         %{retry: retry} do
      rendered = render!(retry, %{pending: :attempt}, :pending, :strong_cyclic)
      assert %{verdict: :admitted} = TLAReader.check!(rendered)

      mutated =
        Regex.replace(
          ~r/Fairness ==\n(  \/\\ SF_vars\([A-Z0-9_]+\)\n)+/,
          rendered.module,
          "Fairness == TRUE\n"
        )

      refute mutated == rendered.module
      assert %{verdict: :refused, kind: :liveness} = TLAReader.check!(mutated)
    end

    test "weakening SF to WF is refused on the two-state retry but not on the self-loop retry",
         %{retry: retry, two: two} do
      two_rendered = render!(two, %{s0: :try, s1: :try}, :s0, :strong_cyclic)
      weak_two = String.replace(two_rendered.module, "SF_vars(", "WF_vars(")
      assert %{verdict: :refused, kind: :liveness} = TLAReader.check!(weak_two)

      # a single-state cycle keeps the exit branch continuously enabled, so WF suffices
      retry_rendered = render!(retry, %{pending: :attempt}, :pending, :strong_cyclic)
      weak_retry = String.replace(retry_rendered.module, "SF_vars(", "WF_vars(")
      assert %{verdict: :admitted} = TLAReader.check!(weak_retry)
    end

    test "tick' = tick turns a retry self-loop into stuttering and wrongly admits strong",
         %{retry: retry} do
      rendered = render!(retry, %{pending: :attempt}, :pending, :strong)
      assert %{verdict: :refused, kind: :liveness} = TLAReader.check!(rendered)

      mutated = String.replace(rendered.module, "tick' = 1 - tick", "tick' = tick")
      assert %{verdict: :admitted} = TLAReader.check!(mutated)
    end

    test "dropping the dead-end outcome branch from its action wrongly admits" do
      domain =
        domain!(%{pending: %{attempt: [:pending, :broken]}, broken: %{}, succeeded: %{}}, [
          :succeeded
        ])

      rendered = render!(domain, %{pending: :attempt}, :pending, :strong_cyclic)
      assert %{verdict: :refused} = TLAReader.check!(rendered)

      # broken=s0 pending=s1 succeeded=s2; B_1_1 -> s0 (broken), B_1_2 -> s1 (retry)
      assert rendered.module =~ "A_1 ==\n  \\/ B_1_1\n  \\/ B_1_2\n"
      dropped = String.replace(rendered.module, "A_1 ==\n  \\/ B_1_1\n", "A_1 ==\n")
      # the only remaining branch is the retry self-loop, which never reaches the goal
      assert %{verdict: :refused, kind: :liveness} = TLAReader.check!(dropped)

      retargeted = String.replace(rendered.module, ~s(state' = "s0"), ~s(state' = "s2"))
      assert %{verdict: :admitted} = TLAReader.check!(retargeted)
    end

    test "any line outside the rendered fragment raises instead of producing a verdict",
         %{retry: retry} do
      rendered = render!(retry, %{pending: :attempt}, :pending, :strong)

      for broken <- [
            String.replace(rendered.module, "Init ==", "Init ==="),
            String.replace(rendered.module, "Next ==\n", "Next == \n"),
            rendered.module <> "Extra == TRUE\n",
            String.replace(rendered.module, ~s(Goals == {"s1"}), ~s(Goals == {"s9"})),
            String.replace(rendered.module, "  \\/ Done\n", "")
          ] do
        refute broken == rendered.module
        assert_raise RuntimeError, fn -> TLAReader.check!(broken) end
      end
    end
  end

  describe "adversarial inputs to the renderer" do
    test "reserved words, standard modules, fairness prefixes and rendered identifiers are refused as module names" do
      domain = domain!(%{pending: %{attempt: [:succeeded]}, succeeded: %{}}, [:succeeded])

      for name <-
            ~w(MODULE EXTENDS TRUE UNCHANGED Naturals TLC FiniteSets Spec Next Init Done
               Fairness state vars WF_x SF_retry A_0 B_1_2) do
        assert {:error, %{reason: :invalid_tla_module_name, module_name: ^name}} =
                 FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong, module_name: name),
               name
      end

      for name <- ~w(A_x Bx_1 NextStep FONDPolicy Retry2) do
        assert {:ok, %{module_name: ^name}} =
                 FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong, module_name: name)
      end

      for bad <- ["", "has space", "1lead", "\u00DCmlaut", :atom, nil, 42] do
        assert {:error, %{reason: :invalid_tla_module_name}} =
                 FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong, module_name: bad)
      end
    end

    test "hostile state terms render a printable-ASCII module that cannot open or close a comment" do
      hostile = [
        "line\u2028sep",
        "para\u2029sep",
        "tab\tand\u0000nul",
        "caf\u00E9",
        "(* open",
        "close *)",
        "---- MODULE Evil ----",
        String.duplicate("=", 80),
        <<255, 0, 1>>,
        {:tuple, "\r\n", [1, 2, 3]}
      ]

      goal = :done
      transitions = Map.new(hostile, fn s -> {s, %{step: [goal]}} end) |> Map.put(goal, %{})
      domain = domain!(transitions, [goal])
      policy = Map.new(hostile, &{&1, :step})

      for initial <- hostile, mode <- @modes do
        {:ok, rendered} = FOND.to_tla(domain, policy, initial, mode)

        assert rendered.module =~ ~r/\A[\x20-\x7E\n]*\z/,
               "non-printable byte for #{inspect(initial)}"

        comments =
          rendered.module |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "\\*"))

        refute Enum.any?(comments, &(&1 =~ "(*" or &1 =~ "*)"))

        # the hostile text never escapes the comment table into the model
        assert %{verdict: :admitted} = TLAReader.check!(rendered)
        assert elixir_verdict(domain, policy, initial, mode) == :admitted
      end
    end

    test "state terms that differ only by numeric type stay distinct states" do
      domain = domain!(%{1 => %{go: [1.0]}, 1.0 => %{go: [:g]}, :g => %{}}, [:g])
      {:ok, rendered} = FOND.to_tla(domain, %{1 => :go, 1.0 => :go}, 1, :strong)
      assert map_size(rendered.state_names) == 3
      assert rendered.state_names |> Map.values() |> Enum.uniq() |> length() == 3

      assert TLAReader.check!(rendered).verdict ==
               elixir_verdict(domain, %{1 => :go, 1.0 => :go}, 1, :strong)
    end

    test "policy decisions on goal states and on states outside the domain are inert" do
      domain = domain!(%{pending: %{attempt: [:done]}, done: %{redo: [:pending]}}, [:done])
      base = render!(domain, %{pending: :attempt}, :pending, :strong)
      noisy = render!(domain, %{pending: :attempt, done: :redo, ghost: :haunt}, :pending, :strong)

      strip = fn m -> m |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "\\*")) end
      assert strip.(base.module) == strip.(noisy.module)
      assert base.branches == noisy.branches
    end

    test "keyword options that are not a module name are ignored; non-list opts are refused" do
      domain = domain!(%{pending: %{attempt: [:succeeded]}, succeeded: %{}}, [:succeeded])

      assert {:ok, %{module_name: "FONDPolicy"}} =
               FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong, unknown: 1)

      assert {:error, %{reason: :invalid_policy_request}} =
               FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong, %{module_name: "X"})

      assert {:error, %{reason: :invalid_policy_request}} =
               FOND.to_tla(%{not: :a_domain}, %{pending: :attempt}, :pending, :strong)
    end
  end

  describe "replay: byte-identical rendering" do
    # Pinned digests of the canonical retry model. Any change to the rendered
    # text (encoding, fairness, comments) must update these deliberately.
    @pins %{
      strong: "ae853c99e7afb6e840bb9337c82bd3790cf0684cb7f943fb4002e798055542fa",
      strong_cyclic: "049f78cdd4daf3f3726f6573b9957c48f5e25a442d001f763c82c44901019997"
    }

    test "rendered module + cfg digests are pinned and stable across repeated renders" do
      domain =
        domain!(%{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}}, [:succeeded])

      for mode <- @modes do
        digests =
          for _ <- 1..3, uniq: true do
            r = render!(domain, %{pending: :attempt}, :pending, mode)

            :crypto.hash(:sha256, r.module <> "\n--cfg--\n" <> r.cfg)
            |> Base.encode16(case: :lower)
          end

        assert [digest] = digests
        assert digest == @pins[mode], "#{mode} digest drifted: #{digest}"
      end
    end
  end

  describe "TLC court fail-closed classification (real TLC 1.7.4 message shapes)" do
    test "a verdict needs both TLC's exit code and its message on its own line" do
      ok = "TLC2 Version 2.19\nModel checking completed. No error has been found.\n"
      dead = "Error: Deadlock reached.\nThe behavior up to this point is:\n"
      live = "@!@!@STARTMSG 2116:1 @!@!@\nTemporal properties were violated.\n"

      assert %{verdict: :admitted, kind: :no_error} = TLCCourt.classify!(ok, 0)
      assert %{verdict: :refused, kind: :deadlock} = TLCCourt.classify!(dead, 11)
      assert %{verdict: :refused, kind: :liveness} = TLCCourt.classify!(live, 13)

      for {output, status} <- [
            {ok, 12},
            {dead, 13},
            {live, 11},
            {dead, 0},
            {"", 0},
            {"Parse error: \\* s0 = \"Deadlock reached.\" quoted", 11},
            {"Invariant TypeOK is violated.\nDeadlock reached. was in a comment", 12},
            {"Temporal properties were violated. (echoed inside a trace line)", 13}
          ] do
        assert_raise RuntimeError, ~r/no classifiable verdict/, fn ->
          TLCCourt.classify!(output, status)
        end
      end
    end

    @tag :tmp_dir
    test "a present jar with another digest is a court error, never a skip", %{tmp_dir: dir} do
      forged = Path.join(dir, "tla2tools.jar")
      File.write!(forged, "not the pinned tla2tools jar")

      assert_raise RuntimeError, ~r/tla2tools digest mismatch/, fn ->
        TLCCourt.verify_jar!(forged)
      end
    end
  end

  describe "CI makes the TLC court mandatory" do
    test "CI fetches the exact jar TLCCourt admits, checks its digest, and requires the court" do
      ci = Path.expand("../.github/workflows/ci.yml", __DIR__) |> File.read!()

      assert ci =~ "releases/download/v1.7.4/tla2tools.jar"
      assert ci =~ TLCCourt.jar_sha256() <> "  "
      assert ci =~ "sha256sum --check --strict"
      assert ci =~ ".cache/autofde-lab/tla2tools/1.7.4"
      assert ci =~ ~r/ASH_PPLAN_REQUIRE_TLC: '1'\n\s+run: mix check/
    end
  end

  describe "TLC differential court on the seeded random corpus" do
    case TLCCourt.availability() do
      :ok -> @describetag :tlc
      {:unavailable, reason} -> @describetag skip: "TLC court unavailable: " <> reason
    end

    test "TLC verdict == reader verdict == validate_policy on 40 random domains, both modes" do
      for {transitions, goals, policy, initial} <- FONDCorpus.random(40, {7, 11, 13}),
          mode <- @modes do
        domain = domain!(transitions, goals)
        rendered = render!(domain, policy, initial, mode)
        elixir = elixir_verdict(domain, policy, initial, mode)
        reader = TLAReader.check!(rendered)
        tlc = TLCCourt.check!(rendered)

        assert {tlc.verdict, reader.verdict} == {elixir, elixir},
               "#{mode}: elixir=#{elixir} reader=#{inspect(reader)} tlc=#{tlc.kind}\n" <>
                 rendered.module
      end
    end
  end
end
