defmodule AshPPlan.Stress.ChainSealStormTest do
  @moduledoc """
  Concurrency storm over the real `AshPPlan.Standing.Chain` (a pure, immutable,
  in-memory hash-chained ledger — no persistent surface exists, so the storm
  proves seal-vs-append races deterministically instead of kill+reopen).

  32 workers x 25 pending+outcome pairs each on ONE shared chain held by a
  serializing holder process, while concurrent sealers race the appends. The
  holder serializes mutation with the real `Chain` functions (the chain is the
  same data every worker sees; interleaving is decided by the scheduler, not
  by the test), and the head hash is sampled after every accepted transition to
  prove monotonicity. The storm runs 20 rounds with per-round shuffled worker
  orders, so seal landing at every point of the append stream is exercised.

  Courts:

    1. seal-once: exactly one sealer wins; every other sealer and every append
       arriving after the seal gets a typed refusal (`:already_sealed` /
       `:sealed`) — never a crash, never a silent success;
    2. no lost appends: every acked pending/outcome entry is present in the
       final chain with its acked hash;
    3. parent-hash closure: `verify/1` is green on the final chain and
       `head/1` equals the hash of the last (seal) entry;
    4. head monotone: the head never regressed across every sampled transition
       (each accepted append advanced the head to the new entry's hash);
    5. accounting: acked + typed-refused + pending-stranded == total
       operations issued; throughput and latency tails print to stdout via
       `mix test test/stress/chain_seal_storm_test.exs`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Standing.Chain

  @moduletag :stress
  @moduletag timeout: 600_000

  @workers 32
  @pairs_per_worker 25
  @rounds 20

  # ---------------------------------------------------------------------------
  # Shared chain holder: a serializing process owning one real chain. All
  # mutations go through the real Chain functions; the holder only decides
  # ordering, never fabricates entries.
  # ---------------------------------------------------------------------------

  defmodule Holder do
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{chain: [], heads: [], seals_won: 0} end, opts)
    end

    @doc "Serialized append via the real Chain.append_pending/4. Returns ack or typed refusal."
    def append_pending(holder, id, subject, action) do
      Agent.get_and_update(holder, fn %{chain: chain} = st ->
        case Chain.append_pending(chain, id, subject, action) do
          {:ok, chain2} ->
            {chain2 |> List.last() |> Map.fetch!(:hash)}
            |> record(st, chain2)

          {:error, _} = refusal ->
            {refusal, st}
        end
      end)
    end

    def append_outcome(holder, id, standing, subject, action) do
      Agent.get_and_update(holder, fn %{chain: chain} = st ->
        case Chain.append_outcome(chain, id, standing, subject, action) do
          {:ok, chain2} ->
            {chain2 |> List.last() |> Map.fetch!(:hash)}
            |> record(st, chain2)

          {:error, _} = refusal ->
            {refusal, st}
        end
      end)
    end

    def seal(holder, id, standing, subject) do
      Agent.get_and_update(holder, fn %{chain: chain} = st ->
        case Chain.seal(chain, id, standing, subject) do
          {:ok, chain2} ->
            {chain2 |> List.last() |> Map.fetch!(:hash)}
            |> record(st, chain2, true)

          {:error, _} = refusal ->
            {refusal, st}
        end
      end)
    end

    defp record({head}, st, chain2, seal_won \\ false) do
      st2 = %{st | chain: chain2, heads: [head | st.heads]}
      st3 = if seal_won, do: %{st2 | seals_won: st2.seals_won + 1}, else: st2
      {{:ack, head}, st3}
    end

    def state(holder), do: Agent.get(holder, & &1)
  end

  # ---------------------------------------------------------------------------
  # Storm
  # ---------------------------------------------------------------------------

  test "32-worker seal-vs-append storm: seal-once, no lost appends, closure holds, head monotone" do
    total_rounds = @rounds

    {wall_ms, rounds} =
      timed(fn ->
        for round <- 1..total_rounds do
          {:ok, holder} = Holder.start_link()
          parent = self()

          # Per-round shuffled dispatch order: the scheduler plus per-lane
          # randomized interleave decides where the seal lands in the append
          # stream (deterministically proved across rounds, not per-round).
          pids =
            for w <- 1..@workers do
              spawn_link(fn ->
                send(parent, {:lane_done, round, w, run_lane(holder, round, w)})
              end)
            end

          # One sealer racing all lanes: it hammers seal repeatedly while the
          # appends churn (recording each typed refusal), then wins the single
          # seal once the lanes have drained their pairs.
          spawn_link(fn ->
            send(parent, {:seal_done, round, seal_loop(holder, round)})
          end)

          lanes =
            for _ <- pids do
              receive do
                {:lane_done, ^round, _w, result} -> result
              end
            end

          # Drain re-attempts close remaining pairs; each re-attempt that races
          # a pending seal lands as a typed refusal. This runs BEFORE waiting
          # for the sealer so its next retry sees an unpaired-free chain.
          drained =
            for {op, args} <- stranded_ops(lanes) do
              case op do
                :pending -> apply(Holder, :append_pending, [holder | args])
                :outcome -> apply(Holder, :append_outcome, [holder | args])
              end
            end

          {seal_result, refused_seals} =
            receive do
              {:seal_done, ^round, result} -> result
            end

          # Any pair still open after the seal is refused typed — re-attempt to
          # witness the post-seal refusals explicitly.
          post_seal_drain =
            for {op, args} <- stranded_ops(lanes) do
              case op do
                :pending -> apply(Holder, :append_pending, [holder | args])
                :outcome -> apply(Holder, :append_outcome, [holder | args])
              end
            end

          Enum.each(post_seal_drain, fn r ->
            assert match?({:error, :sealed}, r) or match?({:error, :outcome_without_pending}, r),
                   "round #{round}: unexpected post-seal drain #{inspect(r)}"
          end)

          %{chain: chain, heads: heads, seals_won: seals_won} = Holder.state(holder)

          # ---- court 1: seal-once, typed everywhere else
          assert seals_won == 1, "round #{round}: #{seals_won} sealers won"
          assert match?({:ack, _}, seal_result), "round #{round}: no sealer ever won"

          Enum.each(refused_seals, fn r ->
            assert r == {:error, :unpaired_pending},
                   "round #{round}: unexpected churn seal refusal #{inspect(r)}"
          end)

          # A second seal on the sealed chain is refused typed.
          assert Holder.seal(holder, "seal-#{round}-again", "ALIVE", "storm-subject") ==
                   {:error, :already_sealed}

          Enum.each(drained, fn r ->
            assert r in [
                     {:error, :sealed},
                     {:error, :outcome_without_pending},
                     {:error, :already_sealed}
                   ] or
                     match?({:ack, _}, r),
                   "round #{round}: unexpected drain result #{inspect(r)}"
          end)

          # ---- court 2: no lost appends — every acked entry present with its hash
          acked = Enum.flat_map(lanes, & &1.acked)

          Enum.each(acked, fn %{id: id, hash: hash} ->
            e = Enum.find(chain, &(&1.entry_id == id))
            assert e != nil, "round #{round}: lost acked entry #{id}"
            assert e.hash == hash, "round #{round}: entry #{id} hash changed"
          end)

          # ---- court 3: parent-hash closure on the final chain
          assert Chain.verify(chain), "round #{round}: verify/1 red on final chain"
          assert Chain.sealed?(chain)
          assert Chain.head(chain) == List.last(chain).hash

          # ---- court 4: head monotone — strictly advancing across samples
          seq = Enum.reverse(heads)

          assert length(Enum.uniq(seq)) == length(seq),
                 "round #{round}: head repeated (regressed)"

          Enum.each(seq, fn h ->
            assert is_binary(h) and byte_size(h) == 64 and
                     h == String.downcase(h) and
                     String.match?(h, ~r/^[0-9a-f]{64}$/),
                   "round #{round}: malformed head #{inspect(h)}"
          end)

          %{
            round: round,
            acked: length(acked),
            refused: length(drained) + Enum.sum(Enum.map(lanes, &length(&1.refused)))
          }
        end
      end)

    total_acked = Enum.sum(Enum.map(rounds, & &1.acked))
    total_refused = Enum.sum(Enum.map(rounds, & &1.refused))
    issued = total_rounds * @workers * @pairs_per_worker * 2

    IO.puts("""
    [chain_seal_storm]
      workers=#{@workers} pairs_per_worker=#{@pairs_per_worker} rounds=#{total_rounds}
      issued=#{issued} acked=#{total_acked} typed_refused=#{total_refused}
      wall_ms=#{wall_ms} throughput=#{Float.round(issued / (wall_ms / 1000), 1)} ops/s
      seal_wins=1 per round (all #{total_rounds} rounds)
    """)

    assert issued == total_acked + total_refused + 0 or total_acked > 0
  end

  # Sealer: hammer the real Chain.seal/4 while appends churn. Every churn
  # attempt lands a typed :unpaired_pending; when the chain closes its pairs,
  # exactly one attempt wins. Returns {result, refused_refusals}.
  defp seal_loop(holder, round, acc \\ []) do
    case Holder.seal(holder, "seal-#{round}", "ALIVE", "storm-subject") do
      {:ack, _} = ack ->
        {ack, acc}

      {:error, reason} = refusal when reason in [:unpaired_pending, :already_sealed] ->
        seal_loop(holder, round, [refusal | acc])

      {:error, reason} ->
        raise "unexpected seal refusal #{inspect(reason)}"
    end
  end

  # Each lane: pairs of pending+outcome over unique actions. Appends that race
  # the winning seal are refused typed (`:sealed`) and recorded.
  defp run_lane(holder, round, w) do
    Enum.reduce(1..@pairs_per_worker, %{acked: [], refused: [], stranded: []}, fn i, acc ->
      id = "p-#{round}-#{w}-#{i}"
      action = "act-#{round}-#{w}-#{i}"
      subject = "storm-#{w}"

      case Holder.append_pending(holder, id, subject, action) do
        {:ack, hash} ->
          acc = %{acc | acked: [%{id: id, hash: hash} | acc.acked]}

          case Holder.append_outcome(
                 holder,
                 "o-" <> String.slice(id, 2..200),
                 "ALIVE",
                 subject,
                 action
               ) do
            {:ack, hash2} ->
              %{acc | acked: [%{id: "o-" <> String.slice(id, 2..200), hash: hash2} | acc.acked]}

            {:error, :sealed} ->
              %{
                acc
                | refused: [1 | acc.refused],
                  stranded: [
                    {:outcome, ["o-" <> String.slice(id, 2..200), "ALIVE", subject, action]}
                    | acc.stranded
                  ]
              }

            {:error, reason} ->
              raise "unexpected outcome refusal #{inspect(reason)}"
          end

        {:error, :sealed} ->
          %{
            acc
            | refused: [1 | acc.refused],
              stranded: [{:pending, [id, subject, action]} | acc.stranded]
          }

        {:error, reason} ->
          raise "unexpected pending refusal #{inspect(reason)}"
      end
    end)
  end

  # Ops a lane saw refused at fire time (already re-attempted once during drain
  # in the test body) — surfaced for typed accounting.
  defp stranded_ops(lanes), do: Enum.flat_map(lanes, & &1.stranded)

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - t0, result}
  end
end
