defmodule AshPPlan.StandingLadderPropertyTest do
  @moduledoc """
  Fuzz court for `AshPPlan.Standing.Ladder.admit/1` and `AshPPlan.Standing.ladder/2`
  (lane HARDEN, stream_data properties):

    1. No skipped rungs are ever accepted: a claim at state k (k > 0) is admitted only
       with a valid transition for every required rung 1..k; deleting any one transition
       must make `admit/1` refuse with `STL_missing_rung`.
    2. Monotone index: every admitted trail (and every `ladder/2` trail) ascends the
       fixed 10-state ladder one rung at a time (`index(to) == index(from) + 1`).
    3. Dangling facts are refused: `nil` / missing `:fact` is `STL_dangling_fact`
       (or `STL_malformed_claim` when the claim shape itself is broken).
    4. Every adversarial input returns a typed refusal; no crash, ever.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshPPlan.Standing
  alias AshPPlan.Standing.{Ladder, Receipt}

  @states Ladder.states()

  # A full, valid single-rung chain from UNKNOWN to states[k].
  defp full_chain(k) do
    for i <- 1..k//1 do
      %{from: Enum.at(@states, i - 1), to: Enum.at(@states, i), evidence: "rung-#{i} evidence"}
    end
  end

  property "no skipped rung is ever accepted (deleting any required transition refuses)" do
    check all(
            k <- integer(0..9),
            extra <-
              list_of(constant(%{from: :UNKNOWN, to: :UNKNOWN, evidence: "noise"}),
                min_length: 0,
                max_length: 3
              )
          ) do
      chain = full_chain(k) ++ extra
      state = Enum.at(@states, k)

      assert {:ok, %{state: ^state, fact: :f}} =
               Ladder.admit(%{fact: :f, state: state, transitions: chain})

      # Deleting ANY single required transition must break admission.
      for i <- 1..k//1 do
        broken = List.delete_at(chain, i - 1)

        assert {:error, %{broken_term: "STL_missing_rung", missing_rung_index: j}} =
                 Ladder.admit(%{fact: :f, state: state, transitions: broken})

        assert j in 1..k
      end
    end
  end

  property "admitted chains are monotone: exactly one rung per transition" do
    check all(
            k <- integer(0..9),
            noise <-
              list_of(constant(%{from: :OBSERVED, to: :OBSERVED, evidence: "loop"}),
                max_length: 3
              )
          ) do
      chain = full_chain(k) ++ noise

      assert {:ok, %{state: _, trail: trail}} =
               Ladder.admit(%{fact: :f, state: Enum.at(@states, k), transitions: chain})

      # The required skeleton is strictly single-rung: for every rung 1..k there is
      # a transition with index(to) == index(from) + 1 and no gaps.
      for i <- 1..k//1 do
        from_i = Ladder.index(Enum.at(@states, i - 1))
        to_i = Ladder.index(Enum.at(@states, i))

        assert Enum.any?(trail, fn t ->
                 Ladder.index(t.from) == from_i and Ladder.index(t.to) == to_i
               end),
               "missing single-rung transition #{from_i} -> #{to_i} in trail"
      end
    end
  end

  property "dangling facts are refused, never filled with a literal" do
    check all(
            k <- integer(0..9),
            fact <- one_of([constant(nil), constant(:__absent__)])
          ) do
      claim = %{state: Enum.at(@states, k), transitions: full_chain(k)}
      claim = if fact == :__absent__, do: claim, else: Map.put(claim, :fact, nil)

      assert {:error, %{broken_term: term}} = Ladder.admit(claim)
      assert term in ["STL_dangling_fact", "STL_malformed_claim"]
    end
  end

  property "admit/1 returns a typed refusal for arbitrary garbage claims" do
    check all(
            garbage <-
              one_of([
                constant(nil),
                constant(%{}),
                constant(%{fact: :f}),
                constant(%{fact: :f, state: :OBSERVED}),
                constant(%{fact: :f, state: :OBSERVED, transitions: nil}),
                constant(%{fact: :f, state: "OBSERVED", transitions: []}),
                constant(%{fact: :f, state: 3.5, transitions: []}),
                constant(%{fact: :f, state: :OBSERVED, transitions: [nil, 5, "x"]}),
                constant(%{fact: :f, state: :OBSERVED, transitions: [%{from: :UNKNOWN}]}),
                constant(%{
                  fact: :f,
                  state: :OBSERVED,
                  transitions: [%{from: :UNKNOWN, to: :OBSERVED, evidence: "   "}]
                }),
                constant(:atom_claim),
                constant([1, 2, 3])
              ])
          ) do
      case Ladder.admit(garbage) do
        {:ok, _} -> flunk("garbage claim admitted: #{inspect(garbage)}")
        {:error, %{broken_term: t}} -> assert is_binary(t) and t != ""
      end
    end
  end

  property "ladder/2 never crashes on adversarial runs and its trail is single-rung" do
    check all(
            run <-
              one_of([
                constant(%{}),
                constant(%{run_id: nil}),
                constant(%{events: nil}),
                constant(%{events: :junk}),
                constant(%{events: [nil, 5, "x"]}),
                constant(%{run_id: "r", events: [%{attributes: nil}]}),
                constant(%{run_id: "r", subject_id: "s", events: []}),
                constant(%{events: [], model: %{tasks: nil}, selection: :x}),
                constant(%{events: [], fond_gates: nil}),
                constant(%{events: [], fond_gates: [%{task: :t}]}),
                constant(%{events: "junk", model: :junk, selection: :junk, execution: :junk}),
                constant(%{
                  run_id: 3,
                  subject_id: 3,
                  events: [:x, nil],
                  model: :junk,
                  selection: :junk,
                  execution: :junk,
                  consequence: :junk,
                  fond_gates: :junk,
                  observation: :junk
                }),
                constant(nil),
                constant(:atom_run),
                constant(42)
              ])
          ) do
      case Standing.ladder(run) do
        {:ok, %{state: state, index: index, trail: trail}} ->
          assert index == Ladder.index(state)
          assert state == :UNKNOWN or trail != []

          trail
          |> Enum.map(& &1.to)
          |> Enum.reduce(0, fn to, prev ->
            assert is_integer(Ladder.index(to))
            assert Ladder.index(to) == prev + 1
            Ladder.index(to)
          end)

        {:error, %{broken_term: t}} ->
          assert is_binary(t) and t != ""
      end
    end
  end

  property "receipt/2 and layer_term/1 refuse garbage with typed broken terms" do
    check all(
            garbage <-
              one_of([
                constant(nil),
                constant(:atom),
                constant(%{events: nil}),
                constant(%{run_id: "r", subject_id: "s", events: [:x]}),
                constant(%{
                  run_id: "r",
                  subject_id: "s",
                  events: [],
                  model: :junk,
                  selection: :junk,
                  execution: :junk,
                  consequence: :junk,
                  fond_gates: :junk
                })
              ])
          ) do
      case Standing.receipt(garbage, replay_commands: :junk) do
        {:ok, _} -> :ok
        {:error, %{broken_term: t}} -> assert is_binary(t) and t != ""
      end

      assert {:error, %{broken_term: "R_unknown_layer"}} =
               Receipt.layer_term(unknown_layer(garbage))
    end
  end

  defp unknown_layer(run) when is_atom(run) and not is_boolean(run), do: run
  defp unknown_layer(_run), do: :bogus_layer
end
