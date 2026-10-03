defmodule AshPPlan.Stress.FONDProposeStormTest do
  @moduledoc """
  Concurrency storm over the real FOND provider surface: 64 processes x 50
  proposals each through the real `AshPPlan.SA2A.Provider.propose/2` (FOND)
  over the full fixture corpus (`test/support/fond_fixture.ex` reading every
  `test/fixtures/fond/tla/*.json`), concurrently, mixing valid requests with
  malformed ones.

  Courts:

    1. every valid proposal returns `{:ok, candidate}` with
       `authority: :none`, `standing: :candidate` and a `planner_subject`;
    2. determinism: for identical inputs the `planner_subject` is identical
       across all processes (per-fixture subject set collapses to one element);
    3. every malformed request returns a closed `{:error, refusal}` whose
       `code` is one of `AshPPlan.SA2A.Refusal.codes/0` and whose
       `authority: :none` — missing subject/domain/initial and unsupported
       formalism all classify, none crash;
    4. zero crashes: no call raises, no process exits abnormally;
    5. total latency bounded: the whole storm completes under the 600s
       module timeout; throughput and latency tails print to stdout via
       `mix test test/stress/fond_propose_storm_test.exs`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.SA2A.{Provider, Refusal}
  alias AshPPlan.Test.FONDFixture

  @moduletag :stress
  @moduletag timeout: 600_000

  @processes 64
  @per_process 50
  @codes Refusal.codes()

  setup do
    fixtures = FONDFixture.all()
    assert length(fixtures) > 0, "fixture corpus must not be empty"

    %{fixtures: fixtures}
  end

  test "64x50 propose storm: valid admitted, malformed refused, deterministic subjects" do
    fixtures = FONDFixture.all()
    codes = @codes

    parent = self()

    t0 = System.monotonic_time(:millisecond)

    pids =
      for pid_n <- 1..@processes do
        spawn_link(fn ->
          send(parent, {:lane_done, pid_n, run_lane(fixtures, codes)})
        end)
      end

    lanes =
      for _ <- pids do
        receive do
          {:lane_done, _n, result} -> result
        end
      end

    wall_ms = System.monotonic_time(:millisecond) - t0

    # ---- court 4: every lane finished normally (spawn_link would have killed
    # the test on an untrapped crash, so reaching here already proves zero
    # crashes at the lane level; per-call classifications are asserted below)
    assert length(lanes) == @processes

    %{valid: valid, malformed: malformed, crashes: crashes, subjects: subject_sets} =
      Enum.reduce(lanes, %{valid: [], malformed: [], crashes: [], subjects: %{}}, fn lane, acc ->
        %{
          acc
          | valid: acc.valid ++ lane.valid,
            malformed: acc.malformed ++ lane.malformed,
            crashes: acc.crashes ++ lane.crashes,
            subjects: Map.merge(acc.subjects, lane.subjects, fn _k, a, b -> a ++ b end)
        }
      end)

    assert crashes == [], "zero crashes expected, got: #{inspect(crashes, limit: 10)}"
    total = @processes * @per_process
    assert length(valid) + length(malformed) == total

    # ---- court 1: every valid proposal is a candidate with no authority
    assert length(valid) == div(total, 5) * 4
    assert Enum.all?(valid, fn c ->
             match?({:ok, %{authority: :none, standing: :candidate}}, c.result) and
               is_map_key(c.result |> elem(1), :planner_subject)
           end)

    # ---- court 2: planner_subject deterministic for identical inputs across
    # all 64 processes
    for {fixture_name, subjects} <- subject_sets do
      uniq = Enum.uniq(subjects)
      assert uniq == [hd(uniq)],
             "planner_subject not deterministic for #{fixture_name}: #{inspect(uniq, limit: 5)}"
    end

    # ---- court 3: every malformed request is a closed refusal
    assert length(malformed) == div(total, 5)
    assert Enum.all?(malformed, fn m ->
             case m.result do
               {:error, %{code: code, authority: :none}} -> code in codes
               _ -> false
             end
           end)

    # every malformed class actually exercised
    seen_codes = malformed |> Enum.map(& &1.result.code) |> Enum.uniq() |> Enum.sort()
    assert :missing_domain in seen_codes
    assert :missing_initial in seen_codes
    assert :missing_subject in seen_codes
    assert :unsupported_formalism in seen_codes

    # ---- court 5: latency + throughput report
    latencies = Enum.map(valid ++ malformed, & &1.ms) |> Enum.sort()
    total_ops = length(latencies)
    q = fn p -> Enum.at(latencies, min(total_ops - 1, trunc(p * total_ops))) end
    max_ms = List.last(latencies)

    IO.puts("""
    [fond_propose_storm]
      processes=#{@processes} per_process=#{@per_process} total=#{total_ops}
      valid=#{length(valid)} malformed=#{length(malformed)} crashes=#{length(crashes)}
      wall_ms=#{wall_ms}
      throughput=#{Float.round(total_ops / (wall_ms / 1000), 1)} ops/s
      latency_ms: p50=#{q.(0.50)} p90=#{q.(0.90)} p99=#{q.(0.99)} max=#{max_ms}
    """)

    assert wall_ms < 600_000, "storm exceeded the 600s module bound: #{wall_ms}ms"
  end

  # Each lane: 50 proposals. Index cycle of 5: 4 valid (round-robin over the
  # fixture corpus) + 1 malformed (rotating through the 4 malformed classes).
  defp run_lane(fixtures, _codes) do
    n = length(fixtures)
    canonical = Enum.find(fixtures, &(&1.mode == :strong_cyclic)) || hd(fixtures)

    Enum.reduce(0..(@per_process - 1), fresh_lane(), fn i, acc ->
      result =
        if rem(i, 5) == 4 do
          malformed_call(rem(div(i, 5), 4), canonical)
        else
          fixture = Enum.at(fixtures, rem(i, n))
          valid_call(fixture)
        end

      case result do
        {:ok, {:ok, %{planner_subject: subject}}, ms} ->
          name = fixture_name(result.fixture)

          %{
            acc
            | valid: [%{result: elem(result, 1), ms: ms} | acc.valid],
              subjects: Map.update(acc.subjects, name, [subject], &[subject | &1])
          }

        {:ok, {:error, _} = refusal, ms} ->
          %{acc | malformed: [%{result: refusal, ms: ms} | acc.malformed]}

        {:crash, reason, _ms} ->
          %{acc | crashes: [%{reason: reason} | acc.crashes]}
      end
    end)
    |> update_in([Access.key!(:valid), Access.all()], & &1)
    |> then(&%{&1 | valid: Enum.reverse(&1.valid), malformed: Enum.reverse(&1.malformed)})
  end

  defp valid_call(fixture) do
    request = %{subject: subject_for(fixture), formalism: :fond, domain: fixture.transitions,
                initial: fixture.initial}

    timed(fn -> Provider.propose(request, policy_opts: []) end)
    |> Map.put(:fixture, fixture.name)
  end

  defp malformed_call(class, fixture) do
    request =
      case class do
        0 -> %{subject: "malformed-#{System.unique_integer()}", formalism: :fond, initial: fixture.initial}
        1 -> %{subject: "malformed-#{System.unique_integer()}", formalism: :fond, domain: fixture.transitions}
        2 -> %{formalism: :fond, domain: fixture.transitions, initial: fixture.initial}
        3 -> %{subject: "malformed-#{System.unique_integer()}", formalism: :pddl, domain: fixture.transitions}
      end

    timed(fn -> Provider.propose(request, []) end)
    |> Map.put(:fixture, :malformed)
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      {:ok, result, System.monotonic_time(:millisecond) - t0}
    rescue
      e -> {:crash, {:rescue, e, __STACKTRACE__}, System.monotonic_time(:millisecond) - t0}
    catch
      :exit, reason -> {:crash, {:exit, reason}, System.monotonic_time(:millisecond) - t0}
    end
  end

  defp fixture_name(%{fixture: name}) when is_binary(name), do: String.to_atom(name)

  defp subject_for(fixture), do: "storm-#{fixture.name}"

  defp fresh_lane do
    %{valid: [], malformed: [], crashes: [], subjects: %{}}
  end
end
