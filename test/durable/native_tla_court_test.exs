defmodule AshPPlan.Durable.NativeTLACourtTest do
  @moduledoc """
  JVM-free court over the generated durable TLA+ protocol
  (`priv/tla/durable/DurableProtocol.{tla,cfg}`) using the pinned native checker
  `tla-rs` v0.11.1 (`AshPPlan.Test.NativeTLA`, binary in gitignored `tools/`).

  The original spec must be ADMITTED and three guard-dropping mutants must each be
  REFUSED with a counterexample (anti-vacuity negative controls):

    * `claim_free`  -> ClaimExclusive violated
    * `run_held`    -> ClaimExclusive violated
    * `record_once` -> NoDoubleEffect violated

  tla-rs v0.11.1 cannot parse `[...]_vars` subscripted box properties, so
  `TerminalAbsorbing` / `CancelNeverOverwritten` are covered by the TLC court
  (`test/durable/tla_court_test.exs`, optional, skipped without a JVM) and the native
  court runs the invariant core plus the leads-to property `NoLostWakeup`.

  Reports checker version, binary digest, model digest and explored-state evidence in the
  run output. The older TLC court remains an optional extra check and is never required.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Test.NativeTLA

  @dir Path.expand("../../priv/tla/durable", __DIR__)
  @module_path Path.join(@dir, "DurableProtocol.tla")
  @module File.read!(@module_path)
  @tlc_cfg File.read!(Path.join(@dir, "DurableProtocol.cfg"))

  @native_cfg """
  SPECIFICATION Spec
  CONSTANTS Workers = {w1, w2}
  INVARIANT TypeOK
  INVARIANT ClaimExclusive
  INVARIANT NoDoubleEffect
  PROPERTY NoLostWakeup
  """

  # guard id => invariant/property whose counterexample must name the guard's failure
  @mutants %{
    "claim_free" => "ClaimExclusive",
    "run_held" => "ClaimExclusive",
    "record_once" => "NoDoubleEffect"
  }

  def mutate(module, guard_id) do
    re = ~r/^  \/\\ .* \\\* guard:#{guard_id}$/m
    assert Regex.match?(re, module), "guard #{guard_id} absent from generated module"
    Regex.replace(re, module, "  /\\ TRUE \\* guard:#{guard_id}")
  end

  test "checker availability and pinned digest" do
    case NativeTLA.availability() do
      :ok ->
        assert NativeTLA.verify_binary!() == NativeTLA.binary_sha256()

        IO.puts("""
        [native-tla-court] checker: tla-rs v#{NativeTLA.version()}
        [native-tla-court] binary sha256: #{NativeTLA.binary_sha256()}
        [native-tla-court] model sha256: #{model_digest()}
        """)

      {:unavailable, reason} ->
        IO.puts("[native-tla-court] SKIP: #{reason}")
        :ok
    end
  end

  # If the binary is absent (fresh clone, tools/ not fetched) the court is a named skip,
  # not a failure; under ASH_PPLAN_REQUIRE_TLA=1 availability() raises instead (fail hard).
  test "original protocol is ADMITTED by tla-rs (skip when binary absent)" do
    case NativeTLA.availability() do
      :ok ->
        result = NativeTLA.check_string!("DurableProtocol", @module, @native_cfg)
        assert result.verdict == :admitted, "original spec refused:\n#{result.output}"

        assert result.kind == :no_error
        assert result.stats.states > 0

        IO.puts(
          "[native-tla-court] ADMITTED: #{result.stats.states} states, " <>
            "#{result.stats.transitions} transitions, depth #{result.stats.depth}"
        )

      {:unavailable, reason} ->
        IO.puts("[native-tla-court] SKIP: #{reason}")
        :ok
    end
  end

  test "each guard-dropping mutant yields a counterexample (anti-vacuity)" do
    for {guard, target} <- @mutants do
      case NativeTLA.availability() do
        :ok ->
          mutant = mutate(@module, guard)
          result = NativeTLA.check_string!("DurableProtocol", mutant, @native_cfg)

          assert result.verdict == :refused,
                 "mutant #{guard} was not refused (court would be vacuous):\n#{result.output}"

          assert result.output =~ target,
                 "counterexample for mutant #{guard} does not name #{target}"

          IO.puts(
            "[native-tla-court] mutant #{guard}: REFUSED (#{target}) — counterexample at " <>
              "depth #{result.stats.depth}"
          )

        {:unavailable, reason} ->
          IO.puts("[native-tla-court] SKIP mutants (#{guard}): #{reason}")
          :ok
      end
    end
  end

  test "TLC court remains available as an optional extra and is not required" do
    # The JVM court is optional: no assertion on its availability here, only that the
    # decision function never turns an available checker into a skip, and that the
    # generated cfg still names the properties the native court cannot parse.
    assert AshPPlan.Test.TLCCourt.decide_availability(:ok, nil) == :ok
    assert AshPPlan.Test.TLCCourt.decide_availability(:ok, "1") == :ok
    assert @tlc_cfg =~ "PROPERTY TerminalAbsorbing"
    assert @tlc_cfg =~ "PROPERTY CancelNeverOverwritten"
  end

  @tag :stateright_pending
  @tag skip:
         "stateright differential pending: generated model (priv/tla/durable/stateright/model.rs) not yet cargo-built within lane deadline"
  test "differential check: stateright model agrees with tla-rs verdicts" do
    # stateright differential (cargo-built model from stateright_model.rs.eex) is pending:
    # see priv/ggen/ash-pplan-durable-tla-pack/templates/stateright_model.rs.eex and
    # priv/tla/durable/stateright/. Recorded pending rather than faked green.
    flunk("stateright differential check pending")
  end

  defp model_digest do
    :crypto.hash(:sha256, @module) |> Base.encode16(case: :lower)
  end
end
