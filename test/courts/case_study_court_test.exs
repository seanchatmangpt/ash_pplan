defmodule AshPPlan.Courts.CaseStudyCourtTest do
  @moduledoc """
  Court for the case-study evidence chain's timing-sensitive step
  (`bin/case-study` step 3, `bin/case-study-step-soak`).

  Pins the deterministic contract of `bin/case-study-step-soak`:

    * a small-but-sufficient soak deadline (2s >= measured warm cycle cost
      ~0.3-0.6s) yields a clean PASS with a real measured cycle count;
    * a deadline shrunk below the measured minimum (0s < one cycle) is a
      typed refusal (`SOAK_VERDICT=SOAK_TOO_SHORT`, exit 3) emitted
      immediately — not a hang and not a silent pass (anti-vacuity: the
      refusal fires BEFORE any mix test runs, proven by elapsed time).

  Chicago-school: real subprocess, real fleet soak test, real exit codes.
  No mocks.
  """

  use ExUnit.Case, async: false

  @script Path.join([__DIR__, "..", "..", "bin", "case-study-step-soak"])

  @tag timeout: 300_000
  test "soak step at a small-but-sufficient deadline (2s) completes with a typed PASS" do
    {out, rc} = run_step(%{"SOAK_SECONDS" => "2"})

    assert rc == 0, "expected exit 0 at SOAK_SECONDS=2, got #{rc}\n#{out}"

    verdict_line = last_verdict(out)

    assert verdict_line =~ ~r/SOAK_VERDICT=(PASS|SOAK_FLAKE_RETRIED)/,
           "expected a passing verdict at SOAK_SECONDS=2, got: #{verdict_line}"

    assert verdict_line =~ ~r/cycles=([1-9][0-9]*) ms=([0-9]+)/,
           "verdict must carry the measured cycle count and duration: #{verdict_line}"

    # measured duration must cover at least one full poll cycle of real work
    [_, ms] = Regex.run(~r/cycles=[0-9]+ ms=([0-9]+)/, verdict_line)
    assert String.to_integer(ms) > 0, "measured soak duration must be > 0: #{verdict_line}"
  end

  @tag timeout: 60_000
  test "anti-vacuity: deadline shrunk below the measured minimum is a typed refusal, not a hang" do
    t0 = System.monotonic_time(:millisecond)
    {out, rc} = run_step(%{"SOAK_SECONDS" => "0"})
    elapsed = System.monotonic_time(:millisecond) - t0

    assert rc == 3, "expected typed-refusal exit 3, got #{rc}\n#{out}"
    assert last_verdict(out) == "SOAK_VERDICT=SOAK_TOO_SHORT soak_seconds=0 cycles=0 ms=0"

    # refusal fired before any soak ran: a cold `mix test` boot alone takes
    # seconds; an immediate typed refusal proves nothing was executed
    assert elapsed < 5_000, "refusal took #{elapsed}ms — the step ran instead of refusing"
  end

  defp run_step(env) do
    case System.cmd("bash", [@script], env: env, stderr_to_stdout: true) do
      {out, rc} -> {out, rc}
    end
  end

  defp last_verdict(out) do
    out
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "SOAK_VERDICT="))
    |> List.last()
    |> String.trim()
  end
end
