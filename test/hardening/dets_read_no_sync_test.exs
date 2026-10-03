defmodule AshPPlan.Reactor.Durable.Store.DetsReadNoSyncCourt do
  @moduledoc """
  Regression court for the DETS wedge fix.

  Three laws:

    1. Read-only store ops (get_run/list_runs/checkpoints/standing/pending_signal/
       get_waiter/waiters/signals) complete WITHOUT `:dets.sync`. Proven two ways:
       (a) a source-level check that `@read_msgs` exactly covers every read-only
       `handle_call` clause — a clause is read-only iff its body mutates nothing,
       transitively through the known mutation helpers — and (b) a behavioral probe:
       kill the store mid read-burst; the file must reopen inside the bounded repair
       window, i.e. reads never widened it.
    2. Bounded call contract: a wedged/unresponsive store surfaces as
       `{:timeout, {GenServer, :call, _}}` within `@call_timeout_ms`, never an
       `:infinity` hang. Simulated with a manual GenServer that never replies.
    3. Write durability unchanged: a write+sync survives a hard kill (single cycle).
  """

  alias AshPPlan.Reactor.Durable.Store.Dets

  use ExUnit.Case, async: true

  @t0 ~U[2026-01-01 00:00:00.000Z]

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "ash_pplan_read_no_sync_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
    )
  end

  defp t0, do: @t0

  # -- source introspection -----------------------------------------------------------------

  defp dets_source, do: Dets.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()

  defp dets_ast do
    src = dets_source()
    assert File.exists?(src), "DETS source not found at #{src}"
    assert {:ok, ast} = src |> File.read!() |> Code.string_to_quoted()
    ast
  end

  # The @read_msgs list literal, extracted from the module source AST.
  defp source_read_msgs do
    {_, value} =
      Macro.prewalk(dets_ast(), nil, fn
        {:@, _, [{:read_msgs, _, [value]}]} = node, nil -> {node, value}
        node, acc -> {node, acc}
      end)

    assert value != nil, "@read_msgs assignment not found in Dets source"

    {_, atoms} =
      Macro.prewalk(value, [], fn
        atom, acc when is_atom(atom) -> {atom, [atom | acc]}
        node, acc -> {node, acc}
      end)

    atoms |> Enum.reverse() |> Enum.uniq()
  end

  @mutating_remote [:insert, :delete, :match_delete, :insert_new]
  @mutating_local [:next, :put_run, :insert_cp, :insert_waiter]

  # Every `defp do_call(msg_pattern, st)` clause as {msg_name, mutates?}. A clause
  # mutates iff its body contains a :dets mutation call or a mutation-helper call.
  defp clause_classification do
    {_, clauses} =
      Macro.prewalk(dets_ast(), [], fn
        {:defp, _, [{:do_call, _, [head | _]} | body]} = node, acc ->
          msg =
            case head do
              msg when is_atom(msg) -> msg
              {msg, _} when is_atom(msg) -> msg
              {:{}, _, [msg | _]} when is_atom(msg) -> msg
              {msg, _, _} when is_atom(msg) -> msg
            end

          {_, mutates?} =
            Macro.prewalk(body, false, fn
              {{:., _, [:dets, fun]}, _, _}, _ when fun in @mutating_remote ->
                {nil, true}

              {fun, _, args}, acc when fun in @mutating_local and is_list(args) ->
                {{fun, args}, true}

              node2, acc ->
                {node2, acc}
            end)

          {node, [{msg, mutates?} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(clauses)
  end

  # -- law 1a: source-level @read_msgs coverage ---------------------------------------------

  describe "law 1a: source-level read_msgs coverage" do
    test "@read_msgs exactly covers every read-only handle_call clause" do
      read_msgs = MapSet.new(source_read_msgs())
      assert MapSet.size(read_msgs) > 0

      expected =
        MapSet.new([
          :get_run,
          :list_runs,
          :checkpoints,
          :standing,
          :pending_signal,
          :get_waiter,
          :waiters,
          :signals
        ])

      assert read_msgs == expected, "@read_msgs drifted: #{inspect(MapSet.to_list(read_msgs))}"

      clauses = clause_classification()
      refute clauses == [], "no do_call clauses found - source parse is broken"

      assert length(clauses) == length(Enum.uniq(Enum.map(clauses, &elem(&1, 0)))),
             "a do_call head was matched twice - parse is unsound"

      for {msg, mutates?} <- clauses do
        if mutates? do
          refute msg in read_msgs,
                 "mutating clause #{inspect(msg)} is in @read_msgs - it would skip :dets.sync"
        else
          assert msg in read_msgs,
                 "read-only clause #{inspect(msg)} missing from @read_msgs - it would pay :dets.sync"
        end
      end
    end
  end

  # -- law 1b: behavioral probe ---------------------------------------------------------------

  describe "law 1b: read-burst kill probe" do
    test "kill mid read-burst: reopen lands inside the bounded repair window" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      Process.flag(:trap_exit, true)

      # seed a real table so the read burst has mass
      {:ok, s} = Dets.start_link(path: path)
      {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{}})

      for n <- 1..50, do: {:ok, _} = Dets.deliver_signal(s, "r1", "go#{n}", n)

      # one owner per path: hand the file over cleanly before the burst store opens it
      GenServer.stop(s, :normal)

      # read burst against the reopened store, killed mid-burst: if any read paid a
      # full-table :dets.sync, the killed file's churn widens the reopen window
      {:ok, s2} = Dets.start_link(path: path)

      parent = self()

      readers =
        for n <- 1..8 do
          spawn(fn ->
            # the burst is expected to be cut off by the kill: any exit/raise in the loop
            # (noproc after the store dies, badmatch on a partial reply) is the probe
            # landing, not a failure - the court asserts on reopen, not on reader liveness
            try do
              for k <- 1..300 do
                {:ok, _} = Dets.get_run(s2, "r1")
                {:ok, _} = Dets.deliver_signal(s2, "r1", "burst#{n}-#{k}", k)
                _ = Dets.signals(s2, "r1")
                _ = Dets.waiters(s2, "r1")
                _ = Dets.list_runs(s2)
                _ = Dets.checkpoints(s2, "r1")
              end
            rescue
              _ -> :ok
            catch
              :exit, _ -> :ok
            end

            send(parent, {:reader_done, n})
          end)
        end

      # let the burst get into flight, then kill without terminate/final sync
      Process.sleep(100)
      Process.unlink(s2)
      down = Process.monitor(s2)
      Process.exit(s2, :kill)
      assert_receive {:DOWN, ^down, :process, ^s2, :killed}

      for pid <- readers, do: Process.exit(pid, :kill)

      # the probe: reopen must succeed fast (bounded retry window), not wedge
      {reopen_us, {:ok, s3}} = :timer.tc(fn -> Dets.start_link(path: path) end)

      assert reopen_us < 10_000_000,
             "reopen took #{div(reopen_us, 1000)}ms - read-burst kill widened the repair window"

      assert %AshPPlan.Reactor.Durable.Record{} = Dets.get_run(s3, "r1")
      GenServer.stop(s3, :normal)
    end
  end

  # -- law 2: bounded call contract ---------------------------------------------------------

  defmodule WedgedStore do
    @moduledoc "Manual GenServer that accepts every call and never replies - a wedge."
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl GenServer
    def init(:ok), do: {:ok, %{}}

    @impl GenServer
    def handle_call(_msg, _from, st), do: {:noreply, st}
  end

  describe "law 2: bounded call contract" do
    @tag timeout: 180_000
    test "a wedged store exits the caller with {:timeout, {GenServer, :call, _}} - never :infinity" do
      {:ok, wedged} = WedgedStore.start_link()

      timeout_ms =
        dets_ast()
        |> then(fn ast ->
          {_, value} =
            Macro.prewalk(ast, nil, fn
              {:@, _, [{:call_timeout_ms, _, [value]}]} = node, nil -> {node, value}
              node, acc -> {node, acc}
            end)

          assert value != nil, "@call_timeout_ms not found in Dets source"
          {ms, []} = Code.eval_quoted(value)
          ms
        end)

      assert is_integer(timeout_ms) and timeout_ms > 0

      test_pid = self()

      caller =
        spawn(fn ->
          reason =
            try do
              Dets.get_run(wedged, "r1")
              :no_exit
            catch
              :exit, r -> r
            end

          send(test_pid, {:wedge_exit, reason})
        end)

      # the caller is blocked, not crashed, at half the bound: the wait is finite and
      # bounded by exactly @call_timeout_ms, not an instant error and not :infinity
      Process.sleep(div(timeout_ms, 2))
      assert Process.alive?(caller), "caller exited before half the bound - contract broke early"

      # the typed wedge exit: {:timeout, {GenServer, :call, _}}, carrying the exact call
      assert_receive {:wedge_exit, {:timeout, {GenServer, :call, payload}}},
                     timeout_ms + 15_000

      assert inspect(payload) =~ ":get_run"

      GenServer.stop(wedged, :normal)
    end
  end

  # -- law 3: write durability unchanged ------------------------------------------------------

  describe "law 3: write durability" do
    test "write + sync survives a hard kill (single cycle)" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      Process.flag(:trap_exit, true)

      {:ok, s} = Dets.start_link(path: path)
      t0 = t0()

      {:ok, rec} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{a: 1}})
      {:ok, cp} = Dets.record(s, "r1", "k1", "one", 42, %{})
      {:ok, sig} = Dets.deliver_signal(s, "r1", "go", :payload)
      _ = {rec, cp}

      Process.unlink(s)
      down = Process.monitor(s)
      Process.exit(s, :kill)
      assert_receive {:DOWN, ^down, :process, ^s, :killed}

      {:ok, s2} = Dets.start_link(path: path)

      assert %AshPPlan.Reactor.Durable.Record{bindings: %{a: 1}} = Dets.get_run(s2, "r1")
      assert %AshPPlan.Reactor.Durable.Checkpoint{output: 42} = Dets.checkpoints(s2, "r1")["k1"]
      assert Dets.pending_signal(s2, "r1", "go").id == sig.id

      # seq continuity: reopened writes never reuse a pre-kill id
      {:ok, sig2} = Dets.deliver_signal(s2, "r1", "go", 2)
      assert sig2.seq > sig.seq and sig2.id > sig.seq

      GenServer.stop(s2, :normal)
    end
  end
end
