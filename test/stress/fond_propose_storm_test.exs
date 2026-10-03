defmodule AshPPlan.Stress.FONDProposeStormTest do
  @moduledoc """
  Concurrency storm over the real FOND provider surface: 64 processes x 50
  proposals each through the real `AshPPlan.SA2A.Provider.propose/2` (FOND)
  over the full fixture corpus (`test/support/fond_fixture.ex` reading every
  `test/fixtures/fond/tla/*.json`), concurrently, mixing valid requests with
  malformed ones.

  Courts:

    1. every well-formed proposal over a solvable fixture returns
       `{:ok, candidate}` with `authority: :none`, `standing: :candidate` and
       a `planner_subject`; well-formed proposals over refused-class fixtures
       are expected `:planner_refused` closed refusals (still `authority:
       :none`);
    2. determinism: `planner_subject` identical across all 64 processes for
       identical inputs (per-fixture subject set collapses to one element);
    3. every malformed request returns a closed `{:error, refusal}` whose
       `code` is one of `AshPPlan.SA2A.Refusal.codes/0` with `authority:
       :none` — missing subject/domain/initial and unsupported formalism all
       classify, none crash;
    4. zero crashes: no call raises or exits;
    5. latency bounded: the whole storm completes under the 600s module
       timeout; throughput and latency tails print to stdout via
       `mix test test/stress/fond_propose_storm_test.exs`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.SA2A.{Provider, Refusal}
  alias AshPPlan.Test.FONDFixture

  @moduletag :stress
  @moduletag timeout: 600_000

  @processes 64
  @per_process 50
  @codes Refusal.codes()
  @fixtures_dir Path.join(File.cwd!(), "test/fixtures/fond/tla")

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
          send(parent, {:lane_done, pid_n, run_lane(fixtures)})
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
    # the test on an untrapped crash, so reaching here proves zero lane
    # crashes; per-call crashes are collected explicitly below)
    assert length(lanes) == @processes

    acc =
      Enum.reduce(lanes, fresh_lane(), fn lane, acc ->
        %{
          acc
          | valid: acc.valid ++ lane.valid,
            refused_wellformed: acc.refused_wellformed ++ lane.refused_wellformed,
            malformed: acc.malformed ++ lane.malformed,
            crashes: acc.crashes ++ lane.crashes,
            subjects: Map.merge(acc.subjects, lane.subjects, fn _k, a, b -> Enum.uniq(a ++ b) end)
        }
      end)

    %{
      valid: valid,
      refused_wellformed: refused_wf,
      malformed: malformed,
      crashes: crashes,
      subjects: subject_sets
    } = acc

    total = @processes * @per_process
    assert crashes == [], "zero crashes expected, got: #{inspect(crashes, limit: 10)}"

    assert length(valid) + length(refused_wf) + length(malformed) == total
    # well-formed = 4/5 of the storm
    assert length(valid) + length(refused_wf) == div(total, 5) * 4
    assert length(malformed) == div(total, 5)

    # ---- court 1: candidates over solvable fixtures carry no authority
    assert Enum.all?(valid, fn c ->
             case c.result do
               %{authority: :none, standing: :candidate, planner_subject: s} ->
                 not is_nil(s)

               _ ->
                 false
             end
           end)

    # ---- court 2: planner_subject deterministic across all 64 processes
    for {fixture_name, subjects} <- subject_sets do
      uniq = Enum.uniq(subjects)

      assert uniq == [hd(uniq)],
             "planner_subject not deterministic for #{fixture_name}: #{inspect(uniq, limit: 5)}"
    end

    # well-formed refusals: exactly :planner_refused closed refusals
    assert Enum.all?(refused_wf, fn r ->
             case r.result do
               {:error, %{code: :planner_refused, authority: :none}} -> true
               _ -> false
             end
           end)

    # ---- court 3: every malformed request is a closed refusal
    assert Enum.all?(malformed, fn m ->
             case m.result do
               {:error, %{code: code, authority: :none}} -> code in codes
               _ -> false
             end
           end)

    # every malformed class actually exercised
    seen_codes =
      malformed
      |> Enum.map(fn m ->
        case m.result do
          {:error, %{code: code}} -> code
          other -> other
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert seen_codes ==
             Enum.sort([
               :missing_domain,
               :missing_initial,
               :missing_subject,
               :unsupported_formalism
             ])

    # ---- court 5: latency + throughput report
    latencies = Enum.map(valid ++ refused_wf ++ malformed, & &1.ms) |> Enum.sort()
    n = length(latencies)
    q = fn p -> Enum.at(latencies, min(n - 1, trunc(p * n))) end
    max_ms = List.last(latencies)

    IO.puts("""
    [fond_propose_storm]
      processes=#{@processes} per_process=#{@per_process} total=#{n}
      valid=#{length(valid)} wellformed_refused=#{length(refused_wf)} malformed=#{length(malformed)} crashes=#{length(crashes)}
      wall_ms=#{wall_ms}
      throughput=#{Float.round(n / (wall_ms / 1000), 1)} ops/s
      latency_ms: p50=#{q.(0.50)} p90=#{q.(0.90)} p99=#{q.(0.99)} max=#{max_ms}
    """)

    assert wall_ms < 600_000, "storm exceeded the 600s module bound: #{wall_ms}ms"
  end

  # Each lane: 50 proposals. Index cycle of 5: 4 well-formed (round-robin over
  # the fixture corpus) + 1 malformed (rotating through the 4 malformed classes).
  defp run_lane(fixtures) do
    n = length(fixtures)
    canonical = Enum.find(fixtures, &(&1.mode == :strong_cyclic)) || hd(fixtures)

    Enum.reduce(0..(@per_process - 1), fresh_lane(), fn i, acc ->
      case call(i, fixtures, n, canonical) do
        {:ok_result, candidate, ms, name} ->
          %{
            acc
            | valid: [%{result: candidate, ms: ms} | acc.valid],
              subjects:
                Map.put(
                  acc.subjects,
                  name,
                  [candidate.planner_subject | Map.get(acc.subjects, name, [])]
                )
          }

        {:wellformed_refused, refusal, ms} ->
          %{acc | refused_wellformed: [%{result: refusal, ms: ms} | acc.refused_wellformed]}

        {:malformed, refusal, ms} ->
          %{acc | malformed: [%{result: refusal, ms: ms} | acc.malformed]}

        {:crash, reason, _ms} ->
          %{acc | crashes: [%{reason: reason} | acc.crashes]}
      end
    end)
    |> then(
      &%{
        &1
        | valid: Enum.reverse(&1.valid),
          refused_wellformed: Enum.reverse(&1.refused_wellformed),
          malformed: Enum.reverse(&1.malformed)
      }
    )
  end

  defp call(i, fixtures, n, _canonical) do
    # same sequence in every lane -> identical inputs across processes
    if rem(i, 5) == 4 do
      malformed_call(rem(div(i, 5), 4))
    else
      wellformed_call(Enum.at(fixtures, rem(i, n)))
    end
  end

  # A single well-formed request over one fixture, classified by the fixture's
  # own expected verdict. Using one canonical fixture per lane keeps
  # "identical inputs across processes" exact: every lane proposes the same
  # domain+initial and must mint the same planner_subject.
  defp wellformed_call(fixture) do
    with {:ok, domain} <- FOND.new(fixture.transitions, fixture.goals) do
      request = %{
        subject: "storm-#{fixture.name}",
        formalism: :fond,
        domain: domain,
        initial: fixture.initial
      }

      case timed(fn -> Provider.propose(request, []) end) do
        {:ok, {:ok, candidate}, ms} ->
          {:ok_result, candidate, ms, String.to_atom(fixture.name)}

        {:ok, {:error, %{code: :planner_refused}} = refusal, ms} ->
          if solvable?(fixture) do
            {:crash, {:unexpected_refusal_of_solvable_fixture, fixture.name, refusal}, ms}
          else
            {:wellformed_refused, refusal, ms}
          end

        {:ok, other, ms} ->
          {:crash, {:unexpected_result, fixture.name, other}, ms}

        crash ->
          crash
      end
    else
      {:error, reason} -> {:crash, {:fond_new_failed, fixture.name, reason}, 0}
    end
  end

  defp malformed_call(class) do
    fixture =
      FONDFixture.load(Path.join(@fixtures_dir, "decision_choice_matters.json"))

    base = fn overrides ->
      Map.merge(%{subject: "malformed-#{System.unique_integer([:positive])}"}, overrides)
    end

    request =
      case class do
        0 ->
          # missing domain
          base.(%{formalism: :fond, initial: fixture.initial})

        1 ->
          # missing initial
          base.(%{formalism: :fond, domain: domain!(fixture)})

        2 ->
          # missing subject
          %{formalism: :fond, domain: domain!(fixture), initial: fixture.initial}

        3 ->
          # unsupported formalism (nil subject also possible; give full valid
          # shape except the formalism)
          %{
            subject: "malformed-#{System.unique_integer([:positive])}",
            formalism: :pddl,
            domain: domain!(fixture),
            initial: fixture.initial
          }
      end

    case timed(fn -> Provider.propose(request, []) end) do
      {:ok, result, ms} -> {:malformed, result, ms}
      crash -> crash
    end
  end

  defp solvable?(fixture) do
    case fixture.expected do
      :refused -> false
      %{strong_cyclic: :admitted} -> true
      _ -> false
    end
  end

  defp domain!(fixture) do
    case FOND.new(fixture.transitions, fixture.goals) do
      {:ok, domain} -> domain
      {:error, reason} -> raise "fixture #{fixture.name} not buildable: #{inspect(reason)}"
    end
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      {:ok, result, System.monotonic_time(:millisecond) - t0}
    rescue
      e -> {:crash, {:rescue, e}, System.monotonic_time(:millisecond) - t0}
    catch
      :exit, reason -> {:crash, {:exit, reason}, System.monotonic_time(:millisecond) - t0}
    end
  end

  defp fresh_lane do
    %{valid: [], refused_wellformed: [], malformed: [], crashes: [], subjects: %{}}
  end
end
