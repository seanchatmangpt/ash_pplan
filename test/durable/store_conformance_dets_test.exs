defmodule AshPPlan.Reactor.Durable.StoreConformanceDetsTest do
  @moduledoc """
  Court: `Store.Dets` against the generated Store conformance suite.
  """
  use AshPPlan.Test.StoreConformance,
    store: AshPPlan.Reactor.Durable.Store.Dets,
    start: fn ->
      path =
        Path.join(
          System.tmp_dir!(),
          "ash_pplan_conf_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
        )

      ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
      AshPPlan.Reactor.Durable.Store.Dets.start_link(path: path)
    end
end

defmodule AshPPlan.Reactor.Durable.StoreConformanceAntiVacuityTest do
  @moduledoc """
  Anti-vacuity court for the generated conformance suite. Each mutant is a hand-written real
  `Store` implementation that delegates to `Store.Ets` and breaks exactly one law. The suite must
  (1) pass on the unmodified store, (2) fail the targeted law on the mutant, and (3) leave every
  law not implicated by the mutation passing for at least one mutant, so a suite that fails
  everything (or nothing) is rejected. It also pins the ontology to the real behaviour:
  the generated callback list equals `Store.behaviour_info(:callbacks)`.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.{Checkpoint, Store}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.StoreConformance, as: Conf

  defmodule Mutant do
    @moduledoc false
    # Builds a Store module delegating to Ets with `overrides` (a quoted body of defs).
    defmacro __using__(_) do
      quote do
        @behaviour AshPPlan.Reactor.Durable.Store
        alias AshPPlan.Reactor.Durable.Store.Ets
        defdelegate start_run(s, a), to: Ets
        defdelegate get_run(s, i), to: Ets
        defdelegate list_runs(s), to: Ets
        defdelegate transition(s, i, f, t, a), to: Ets
        defdelegate claim(s, i, c, l, n), to: Ets
        defdelegate release_claim(s, i, c), to: Ets
        defdelegate checkpoints(s, i), to: Ets
        defdelegate standing(s, i), to: Ets
        defdelegate snapshot(s, i), to: Ets
        defdelegate record(s, i, k, l, o, m), to: Ets
        defdelegate claim_undo(s, i, k, n), to: Ets
        defdelegate release_undo(s, i, k), to: Ets
        defdelegate deliver_signal(s, i, n, p), to: Ets
        defdelegate pending_signal(s, i, n), to: Ets
        defdelegate consume_signal(s, sid, n), to: Ets
        defdelegate park(s, i, n, k, d, o), to: Ets
        defdelegate get_waiter(s, i, n), to: Ets
        defdelegate waiters(s, i), to: Ets
        defdelegate release(s, i, n), to: Ets
        defdelegate release_all(s, i), to: Ets
        defdelegate signals(s, i), to: Ets
        defoverridable AshPPlan.Reactor.Durable.Store.behaviour_info(:callbacks)
      end
    end
  end

  defmodule ClaimAlways do
    @moduledoc false
    use Mutant

    def claim(s, id, claimer, lease, now) do
      case Ets.claim(s, id, claimer, lease, now) do
        :taken -> {:ok, Ets.get_run(s, id)}
        ok -> ok
      end
    end
  end

  defmodule RecordReturnsCaller do
    @moduledoc false
    use Mutant

    def record(s, id, key, label, output, meta) do
      case Ets.record(s, id, key, label, output, meta) do
        {:ok, cp} -> {:ok, %{cp | output: output}}
        other -> other
      end
    end
  end

  defmodule ConsumeAlways do
    @moduledoc false
    use Mutant

    def consume_signal(s, sid, now) do
      case Ets.consume_signal(s, sid, now) do
        :taken ->
          s
          |> Ets.list_runs()
          |> Enum.flat_map(&Ets.signals(s, &1.id))
          |> Enum.find(&(&1.id == sid))
          |> case do
            nil -> :taken
            sig -> {:ok, sig}
          end

        ok ->
          ok
      end
    end
  end

  defmodule TransitionUnguarded do
    @moduledoc false
    use Mutant
    def transition(s, id, _from, to, attrs), do: Ets.transition(s, id, :any, to, attrs)
  end

  defmodule ParkAlwaysOverwrites do
    @moduledoc false
    use Mutant

    def park(s, id, name, kind, deadline, _opts),
      do: Ets.park(s, id, name, kind, deadline, overwrite: true)
  end

  defmodule TerminalAcceptsCheckpoints do
    @moduledoc false
    use Mutant

    def record(s, id, key, label, output, meta) do
      case Ets.record(s, id, key, label, output, meta) do
        {:error, :terminal} ->
          {:ok, %Checkpoint{run_id: id, step_key: key, label: label, output: output}}

        other ->
          other
      end
    end
  end

  defmodule StandingReversed do
    @moduledoc false
    use Mutant
    def standing(s, id), do: s |> Ets.standing(id) |> Enum.reverse()
  end

  defmodule UndoRepeatable do
    @moduledoc false
    use Mutant

    def claim_undo(s, id, key, now) do
      case Ets.claim_undo(s, id, key, now) do
        :taken ->
          case Ets.checkpoints(s, id) do
            %{^key => cp} -> {:ok, cp}
            _ -> :taken
          end

        ok ->
          ok
      end
    end
  end

  defmodule ReleaseClaimAnyone do
    @moduledoc false
    use Mutant

    def release_claim(s, id, _claimer) do
      case Ets.get_run(s, id) do
        nil -> :ok
        run -> Ets.release_claim(s, id, run.claimed_by)
      end
    end
  end

  defmodule StartRunOverwrites do
    @moduledoc false
    use Mutant

    def start_run(s, attrs) do
      case Ets.start_run(s, attrs) do
        {:error, :exists} -> {:ok, Ets.get_run(s, attrs.id)}
        ok -> ok
      end
    end
  end

  defmodule ReleaseAllEverything do
    @moduledoc false
    use Mutant

    def release_all(s, id) do
      for r <- Ets.list_runs(s), do: Ets.release_all(s, r.id)
      _ = id
      :ok
    end
  end

  @mutants [
    {ClaimAlways, ["claim_lease", "claim_exclusive_concurrent"]},
    {RecordReturnsCaller, ["record_insert_or_adopt", "record_concurrent_adopts"]},
    {ConsumeAlways, ["signals_fifo_consume_once", "consume_concurrent"]},
    {TransitionUnguarded, ["transition_guarded"]},
    {ParkAlwaysOverwrites, ["park_deadline_once"]},
    {TerminalAcceptsCheckpoints, ["terminal_refuses_checkpoints"]},
    {StandingReversed, ["standing_ordered_by_seq"]},
    {UndoRepeatable, ["undo_once"]},
    {ReleaseClaimAnyone, ["release_claim_owner_only"]},
    {StartRunOverwrites, ["start_run_exclusive"]},
    {ReleaseAllEverything, ["release_idempotent"]}
  ]

  defp start, do: Ets.start_link()

  defp failed(mod),
    do: for({id, {:error, _}} <- Conf.run(mod, &start/0), do: id)

  test "the unmodified store passes every law" do
    assert Enum.all?(Conf.run(Ets, &start/0), &match?({_, :ok}, &1))
  end

  for {mod, expected} <- @mutants do
    test "mutant #{inspect(mod)} fails #{inspect(expected)}" do
      failed = failed(unquote(mod))

      for id <- unquote(expected) do
        assert id in failed,
               "#{inspect(unquote(mod))} was not caught by law #{id}: #{inspect(failed)}"
      end
    end
  end

  test "every law is killed by at least one mutant" do
    killed = @mutants |> Enum.flat_map(fn {m, _} -> failed(m) end) |> MapSet.new()
    all = MapSet.new(Enum.map(Conf.laws(), & &1.id))
    assert MapSet.difference(all, killed) == MapSet.new()
  end

  test "a store that only returns :ok / nil fails most of the suite" do
    defmodule Hollow do
      @moduledoc false
      @behaviour AshPPlan.Reactor.Durable.Store
      def start_run(_, _), do: {:ok, %AshPPlan.Reactor.Durable.Record{id: "r1"}}
      def get_run(_, _), do: nil
      def list_runs(_), do: []
      def transition(_, _, _, _, _), do: {:error, :not_found}
      def claim(_, _, _, _, _), do: :taken
      def release_claim(_, _, _), do: :ok
      def checkpoints(_, _), do: %{}
      def standing(_, _), do: []
      def record(_, _, _, _, _, _), do: {:error, :terminal}
      def claim_undo(_, _, _, _), do: :taken
      def release_undo(_, _, _), do: :ok
      def deliver_signal(_, _, _, _), do: {:error, :nope}
      def pending_signal(_, _, _), do: nil
      def consume_signal(_, _, _), do: :taken
      def park(_, _, _, _, _, _), do: {:error, :nope}
      def get_waiter(_, _, _), do: nil
      def waiters(_, _), do: []
      def release(_, _, _), do: :ok
      def release_all(_, _), do: :ok
      def signals(_, _), do: []
    end

    results = Conf.run(Hollow, fn -> {:ok, :hollow} end)
    assert length(Enum.filter(results, &match?({_, {:error, _}}, &1))) == length(results)
  end

  test "ontology callbacks equal the Store behaviour's callbacks" do
    declared = Enum.sort(Conf.callbacks())
    real = Enum.sort(Store.behaviour_info(:callbacks))
    assert declared == real
  end

  test "every callback is covered by at least one law" do
    covered = Conf.laws() |> Enum.flat_map(& &1.covers) |> MapSet.new()

    assert MapSet.new(Enum.map(Conf.callbacks(), &elem(&1, 0)), &Atom.to_string/1)
           |> MapSet.difference(covered) == MapSet.new()
  end
end
