defmodule AshPPlan.Reactor.Durable.WalUnwindSemanticsTest do
  @moduledoc """
  Lane F8 COURT: WAL store's divergent lease/claim semantics vs ETS/DETS.

  Characterizes what IS in `Store.Wal` at test time (A5 may be mid-repair upstream) and
  courts the invariants that must hold on ANY store regardless of repair state:

  1. `mark_undone` durability: an undone mark survives kill + reopen (WAL hydration).
  2. Snapshot fidelity post-reopen: standing/undone partition is correct and matches ETS.
  3. Nearest-first unwind: `Unwind.run` over the WAL store produces the same undo call
     sequence as ETS for an identical checkpoint fixture set (differential).

  Skip-loud protocol: an assertion that would fail only because of A5's in-flight WAL
  repairs is reported loudly (`[SKIP-LOUD F8-...]`) to stderr rather than fake-passed or
  silently dropped. Characterization asserts document divergences that exist by design at
  test time.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Reactor.Durable.Store.Wal
  alias AshPPlan.Reactor.Durable.Unwind

  @identity_key AshPPlan.Reactor.context_key()

  # A minimal undoable Reactor step. The undo effect appends the step name to a
  # `:persistent_term` call-order log keyed by run id, so the differential court can
  # compare WAL vs ETS undo sequences on real stores, no mocks.
  defmodule F8UndoStep do
    @behaviour Reactor.Step

    @impl true
    def run(_args, _opts, _context), do: {:ok, :ran}

    # Without `use Reactor.Step` there is no default can?/2; Unwind's undoable?/1 would
    # rescue the UndefinedFunctionError and silently skip every checkpoint ({:ok, []}).
    def can?(_step, :undo), do: true
    def can?(_step, _capability), do: false

    @impl true
    def undo(_output, _args, context, _options) do
      run_id = context.durable.run_id
      name = context.current_step.name
      key = {:f8_undo_calls, run_id}

      :persistent_term.put(
        key,
        [name | :persistent_term.get(key, [])]
      )

      :ok
    end
  end

  setup do
    path = Path.join(System.tmp_dir!(), "f8_wal_#{System.unique_integer([:positive])}.wal")
    {:ok, wal} = Wal.open(path)
    {:ok, ets} = Ets.start_link()

    on_exit(fn -> File.rm(path) end)

    %{wal: wal, ets: ets, path: path}
  end

  defp seed_run(store_mod, store, tag, steps) do
    run_id = "f8-#{tag}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      store_mod.start_run(store, %{
        id: run_id,
        context: %{@identity_key => %{subject: "sha256:f8"}}
      })

    for {key, name, i} <- steps do
      assert {:ok, _cp} =
               store_mod.record(store, run_id, key, inspect(name), {:out, i}, %{
                 impl: {F8UndoStep, []},
                 name: name,
                 args: %{}
               })
    end

    run_id
  end

  describe "characterization: WAL lease/claim semantics vs ETS (what IS)" do
    @tag :f8_characterization
    test "claim_undo: both stores grant a volatile undo claim; 2nd concurrent claim is :taken; release_undo frees it",
         %{
           ets: ets,
           wal: wal
         } do
      now = DateTime.utc_now()

      for {mod, store} <- [{Ets, ets}, {Wal, wal}] do
        run_id = seed_run(mod, store, "cu", [{"s1", :s1, 1}])

        assert {:ok, _} = mod.claim_undo(store, run_id, "s1", now)
        assert :taken = mod.claim_undo(store, run_id, "s1", now)
        assert :ok = mod.release_undo(store, run_id, "s1")
        assert {:ok, _} = mod.claim_undo(store, run_id, "s1", now)
      end
    end

    @tag :f8_characterization
    test "release_claim: both stores are holder-gated; a non-holder release never clears the claim",
         %{
           ets: ets,
           wal: wal
         } do
      now = DateTime.utc_now()

      for {mod, store, id} <- [
            {Ets, ets, "f8-rel-e-#{System.unique_integer([:positive])}"},
            {Wal, wal, "f8-rel-w-#{System.unique_integer([:positive])}"}
          ] do
        {:ok, _} = mod.start_run(store, %{id: id})
        {:ok, _} = mod.claim(store, id, :holder, 60_000, now)

        # a non-holder release is a no-op (the claim survives).
        :ok = mod.release_claim(store, id, :attacker)
        assert mod.get_run(store, id).claimed_by == :holder

        # the holder's release clears the claim.
        :ok = mod.release_claim(store, id, :holder)
        assert mod.get_run(store, id).claimed_by == nil
      end
    end

    @tag :f8_characterization
    test "renew_claim: both stores require the holder; WAL renewal extends the lease via Clock",
         %{
           ets: ets,
           wal: wal
         } do
      now = DateTime.utc_now()
      wal_id = "f8-ren-#{System.unique_integer([:positive])}"

      {:ok, _} = Wal.start_run(wal, %{id: wal_id})
      {:ok, rec} = Wal.claim(wal, wal_id, :w1, 5_000, now)

      assert {:ok, renewed} = Wal.renew_claim(wal, wal_id, :w1, 60_000)
      assert renewed.lease_until > rec.lease_until

      assert :taken = Wal.renew_claim(wal, wal_id, :not_holder, 60_000)
      assert :taken = Ets.renew_claim(ets, "f8-no-such-run", :w1, 60_000)
    end

    @tag :f8_characterization
    test "record assigns distinct seqs; standing is seq-sorted; WAL parity with ETS ordering", %{
      ets: ets,
      wal: wal
    } do
      steps = [{"q1", :q1, 1}, {"q2", :q2, 2}, {"q3", :q3, 3}]
      run_wal = seed_run(Wal, wal, "seq", steps)
      run_ets = seed_run(Ets, ets, "seqe", steps)

      wal_seqs = wal |> Wal.checkpoints(run_wal) |> Map.values() |> Enum.map(& &1.seq)
      assert length(Enum.uniq(wal_seqs)) == 3
      assert Enum.all?(wal_seqs, &(&1 > 0))

      assert Wal.standing(wal, run_wal) |> Enum.map(& &1.step_key) == ["q1", "q2", "q3"]
      assert Ets.standing(ets, run_ets) |> Enum.map(& &1.step_key) == ["q1", "q2", "q3"]
    end
  end

  describe "invariant court (any store, regardless of repair state)" do
    @tag :f8_persistence
    test "mark_undone persists across kill + reopen (WAL hydration)", %{wal: wal, path: path} do
      run_id = seed_run(Wal, wal, "pers", [{"a", :a, 1}, {"b", :b, 2}, {"c", :c, 3}])

      assert {:ok, cp} = Wal.mark_undone(wal, run_id, "b", DateTime.utc_now())
      assert cp.undone_at

      # kill: close + drop the struct; the in-memory index dies with it.
      :ok = Wal.close(wal)
      assert {:ok, reopened} = Wal.open(path)

      cps = Wal.checkpoints(reopened, run_id)
      assert %{"a" => a, "b" => b, "c" => c} = cps
      assert is_nil(a.undone_at) and is_nil(c.undone_at)
      assert b.undone_at

      # standing/undone partition post-reopen
      assert Wal.standing(reopened, run_id) |> Enum.map(& &1.step_key) |> Enum.sort() == [
               "a",
               "c"
             ]

      Wal.close(reopened)
    end

    @tag :f8_snapshot
    test "snapshot fidelity: WAL hydration reproduces the standing/undone partition, parity with ETS",
         %{
           ets: ets,
           wal: wal,
           path: path
         } do
      steps = [{"k1", :k1, 1}, {"k2", :k2, 2}, {"k3", :k3, 3}, {"k4", :k4, 4}]

      run_wal = seed_run(Wal, wal, "snapw", steps)
      run_ets = seed_run(Ets, ets, "snape", steps)

      for {key, _n, _i} <- Enum.drop(steps, 2) do
        assert {:ok, _} = Wal.mark_undone(wal, run_wal, key, DateTime.utc_now())
        assert {:ok, _} = Ets.mark_undone(ets, run_ets, key, DateTime.utc_now())
      end

      standing_wal = Wal.standing(wal, run_wal) |> Enum.map(& &1.step_key) |> Enum.sort()
      standing_ets = Ets.standing(ets, run_ets) |> Enum.map(& &1.step_key) |> Enum.sort()
      assert standing_wal == standing_ets
      assert standing_wal == ["k1", "k2"]

      assert cps_undone_keys(Wal.checkpoints(wal, run_wal)) == ["k3", "k4"]
      assert cps_undone_keys(Ets.checkpoints(ets, run_ets)) == ["k3", "k4"]

      # reopen fidelity: identical partition after kill+reopen
      :ok = Wal.close(wal)
      assert {:ok, reopened} = Wal.open(path)

      assert Wal.standing(reopened, run_wal) |> Enum.map(& &1.step_key) |> Enum.sort() == [
               "k1",
               "k2"
             ]

      assert cps_undone_keys(Wal.checkpoints(reopened, run_wal)) == ["k3", "k4"]
      Wal.close(reopened)
    end

    @tag :f8_differential
    test "differential unwind: same fixtures, WAL and ETS undo the same set; both nearest-first",
         %{
           ets: ets,
           wal: wal,
           path: path
         } do
      steps = [{"x1", :x1, 1}, {"x2", :x2, 2}, {"x3", :x3, 3}]

      run_wal = seed_run(Wal, wal, "dw", steps)
      run_ets = seed_run(Ets, ets, "de", steps)

      context = %{@identity_key => %{subject: "sha256:f8", workflow: "f8"}}

      assert {:ok, _unresolved} = Unwind.run(wal, run_wal, context: context, store_module: Wal)
      assert {:ok, _} = Unwind.run(ets, run_ets, context: context, store_module: Ets)

      # final state: identical undone sets, both stores fully unwound.
      assert cps_undone_keys(Wal.checkpoints(wal, run_wal)) |> Enum.sort() ==
               cps_undone_keys(Ets.checkpoints(ets, run_ets)) |> Enum.sort()

      assert cps_undone_keys(Wal.checkpoints(wal, run_wal)) |> Enum.sort() == ["x1", "x2", "x3"]
      assert Wal.standing(wal, run_wal) == []
      assert Ets.standing(ets, run_ets) == []

      # call-order log (persistent_term prepends -> reversed to chronological)
      wal_calls = undo_calls(run_wal)
      ets_calls = undo_calls(run_ets)

      assert Enum.sort(wal_calls) == Enum.sort(ets_calls)
      assert Enum.sort(wal_calls) == [:x1, :x2, :x3]

      # nearest-first ordering court: both stores must unwind newest-first (seq desc).
      assert ets_calls == [:x3, :x2, :x1]
      assert wal_calls == [:x3, :x2, :x1]

      # WAL checkpoint seqs survive hydration so the order court holds after reopen too.
      seqs_before = wal |> Wal.checkpoints(run_wal) |> Map.values() |> Enum.map(& &1.seq)

      :ok = Wal.close(wal)
      assert {:ok, reopened} = Wal.open(path)
      assert Wal.standing(reopened, run_wal) == []

      assert Wal.checkpoints(reopened, run_wal) |> Map.values() |> Enum.map(& &1.seq) ==
               seqs_before

      Wal.close(reopened)

      :persistent_term.erase({:f8_undo_calls, run_wal})
      :persistent_term.erase({:f8_undo_calls, run_ets})
    end
  end

  defp undo_calls(run_id) do
    :persistent_term.get({:f8_undo_calls, run_id}, [])
    |> Enum.reverse()
  end

  defp cps_undone_keys(cps),
    do:
      cps
      |> Enum.filter(fn {_k, cp} -> not is_nil(cp.undone_at) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
end
