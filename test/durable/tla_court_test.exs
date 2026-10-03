defmodule AshPPlan.Durable.TLACourtTest do
  @moduledoc """
  Court: the durable claim/lease, attempt, park, signal, wake, cancel/unwind protocol as a
  generated TLA+ model (`priv/tla/durable/DurableProtocol.{tla,cfg}`, emitted by
  `bin/manufacture-durable-tla` from `priv/ggen/ash-pplan-durable-tla-pack/ontology.ttl`).

  Invariants: ClaimExclusive, NoDoubleEffect (invariants); TerminalAbsorbing,
  CancelNeverOverwritten, NoLostWakeup (temporal properties).

  Always-on structural court (no JVM needed): the committed artifacts equal what the pack
  renders today is checked by the pack's own `--verify-cwd` sync; here every ontology guard and
  property must appear in the module/cfg, and each guard-dropping mutant must differ from the
  original exactly at that guard line.

  TLC court (pinned jar, `AshPPlan.Test.TLCCourt`): the original spec must be admitted and each
  mutant must be REFUSED with a named invariant/property violation. Under
  `ASH_PPLAN_REQUIRE_TLC=1` an unavailable checker raises; locally it is a named skip.
  The TLC classifier fails closed on unknown output, so an invariant violation (exit 12) is
  recognised here by the explicit TLC message, not by `classify!/2`.

  Anti-vacuity: the mutants are the negative controls. If the original spec were checked with
  no invariants in its cfg, the mutants would be admitted and `mutant is refused` would fail.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Test.TLCCourt

  @dir Path.expand("../../priv/tla/durable", __DIR__)
  @module File.read!(Path.join(@dir, "DurableProtocol.tla"))
  @cfg File.read!(Path.join(@dir, "DurableProtocol.cfg"))

  @invariants ~w(ClaimExclusive NoDoubleEffect)
  @properties ~w(TerminalAbsorbing CancelNeverOverwritten NoLostWakeup)

  # guard id => invariant/property its removal must violate
  @mutations %{
    "claim_free" => "ClaimExclusive",
    "record_once" => "NoDoubleEffect",
    "settle_from" => "CancelNeverOverwritten|TerminalAbsorbing"
  }

  def mutate(module, guard_id) do
    re = ~r/^  \/\\ .* \\\* guard:#{guard_id}$/m
    assert Regex.match?(re, module), "guard #{guard_id} absent"
    Regex.replace(re, module, "  /\\ TRUE \\* guard:#{guard_id}")
  end

  test "every invariant and property is defined in the module and named in the cfg" do
    for name <- @invariants ++ @properties do
      assert @module =~ ~r/^#{name} ==/m, "#{name} undefined"
    end

    for name <- @invariants, do: assert(@cfg =~ "INVARIANT #{name}")
    for name <- @properties, do: assert(@cfg =~ "PROPERTY #{name}")
    assert @cfg =~ "SPECIFICATION Spec"
    assert @module =~ "WF_vars(Claim(w))"
  end

  test "the protocol actions cover claim, attempt, park, signal, wake, cancel and unwind" do
    for a <- ~w(Deliver Claim RecordA RecordB Complete Park Cancel Rollback Release) do
      assert @module =~ ~r/^#{a}(\(w\))? ==/m, "action #{a} missing"
    end
  end

  test "each guard-dropping mutant differs from the spec only at that guard" do
    for {guard, _inv} <- @mutations do
      mutant = mutate(@module, guard)
      refute mutant == @module
      orig = String.split(@module, "\n")
      mut = String.split(mutant, "\n")
      diff = Enum.zip(orig, mut) |> Enum.reject(fn {a, b} -> a == b end)
      assert diff != []
      assert Enum.all?(diff, fn {a, b} -> a =~ "guard:#{guard}" and b =~ "/\\ TRUE" end)
    end
  end

  describe "TLC" do
    case TLCCourt.availability() do
      :ok -> :ok
      {:unavailable, reason} -> @describetag skip: "TLC court unavailable: " <> reason
    end

    defp check(module, cfg) do
      TLCCourt.verify_jar!()

      dir =
        Path.join(
          System.tmp_dir!(),
          "durable_tla_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
        )

      File.mkdir_p!(dir)

      try do
        File.write!(Path.join(dir, "DurableProtocol.tla"), module)
        File.write!(Path.join(dir, "DurableProtocol.cfg"), cfg)

        System.cmd(
          "java",
          [
            "-XX:+UseSerialGC",
            "-Xmx512m",
            "-cp",
            TLCCourt.jar_path(),
            "tlc2.TLC",
            "-workers",
            "1",
            "-nowarning",
            "-metadir",
            Path.join(dir, "states"),
            "-config",
            "DurableProtocol.cfg",
            "DurableProtocol.tla"
          ],
          cd: dir,
          stderr_to_stdout: true
        )
      after
        File.rm_rf!(dir)
      end
    end

    test "the original spec holds all invariants and properties" do
      {out, status} = check(@module, @cfg)
      assert status == 0, out
      assert out =~ "Model checking completed. No error has been found."
    end

    for {guard, invariant} <- @mutations do
      test "mutant dropping #{guard} is refused (#{invariant})" do
        {out, status} = check(mutate(@module, unquote(guard)), @cfg)
        assert status != 0, "mutant admitted:\n" <> out
        assert out =~ Regex.compile!(unquote(invariant)), out
      end
    end
  end
end
