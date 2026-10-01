defmodule AshPPlan.Reactor.Durable.UnwindTest do
  @moduledoc """
  Court: `AshPPlan.Reactor.Durable.Unwind` takes back standing checkpoints from the store's
  impl+args snapshots. Real `Store.Ets`, real `Reactor.Step` undo callbacks, no mocks.

  Anti-vacuity mutation: dropping the `Enum.sort_by(& &1.seq, :desc)` in Unwind flips the
  newest-first order test; dropping `claim_undo` fails the racing test (each step undone more than
  once); dropping identity seeding fails the Identity test.

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Key, Store.Ets, Unwind}
  alias AshPPlan.Workflow.{Model, Subject}

  @log :unwind_court_log
  @id_key AshPPlan.Reactor.context_key()

  defmodule UndoStep do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(_a, _c, _o), do: {:ok, :done}

    @impl true
    def undo(value, args, context, opts) do
      name = Keyword.fetch!(opts, :name)
      log = Keyword.fetch!(opts, :log)

      n =
        Agent.get_and_update(log, fn s ->
          {Map.get(s.calls, name, 0) + 1,
           put_in(s, [:calls, name], Map.get(s.calls, name, 0) + 1)}
        end)

      case Keyword.get(opts, :mode, :ok) do
        :ok ->
          Agent.update(
            log,
            &%{
              &1
              | order: &1.order ++ [{name, value, args, Map.get(context, :ash_pplan_workflow)}]
            }
          )

          :ok

        :flaky ->
          if Agent.get(log, & &1.fixed?) do
            Agent.update(log, &%{&1 | order: &1.order ++ [{name, value, args, nil}]})
            :ok
          else
            {:error, :still_broken}
          end

        :retry_twice ->
          if n <= 2 do
            :retry
          else
            Agent.update(log, &%{&1 | order: &1.order ++ [{name, value, args, nil}]})
            :ok
          end

        :retry_forever ->
          {:retry, :never}

        :slow ->
          Process.sleep(30)
          Agent.update(log, &%{&1 | order: &1.order ++ [{name, value, args, nil}]})
          :ok
      end
    end
  end

  defmodule NoUndoStep do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(_a, _c, _o), do: {:ok, :done}
  end

  setup do
    {:ok, log} = Agent.start_link(fn -> %{order: [], calls: %{}, fixed?: false} end, name: @log)
    {:ok, store} = Ets.start_link([])
    on_exit(fn -> if Process.alive?(log), do: Agent.stop(log) end)
    {:ok, store: store, log: log}
  end

  defp identity_ctx, do: %{@id_key => %{subject: "sha256:court", workflow: :court}}

  defp run!(store, id, extra \\ %{}) do
    {:ok, _} = Ets.start_run(store, %{id: id, context: Map.merge(identity_ctx(), extra)})
    id
  end

  defp stand(store, id, name, opts \\ [], mod \\ UndoStep) do
    opts = if mod == UndoStep, do: Keyword.merge([name: name, log: @log], opts), else: opts

    {:ok, cp} =
      Ets.record(store, id, Key.for_name(name), Key.label(name), {:out, name}, %{
        impl: {mod, opts},
        args: %{who: name}
      })

    cp
  end

  defp order, do: Agent.get(@log, & &1.order) |> Enum.map(&elem(&1, 0))
  defp calls(name), do: Agent.get(@log, &Map.get(&1.calls, name, 0))

  test "takes back every checkpoint newest first, with the snapshotted output and args", %{
    store: s
  } do
    id = run!(s, "r1")
    for n <- [:a, :b, :c], do: stand(s, id, n)

    assert {:ok, []} = Unwind.run(s, id)
    assert order() == [:c, :b, :a]
    assert Ets.standing(s, id) == []

    [{:c, {:out, :c}, %{who: :c}, _} | _] = Agent.get(@log, & &1.order)
  end

  test "a failed undo leaves its checkpoint standing; the next pass resumes from marks", %{
    store: s
  } do
    id = run!(s, "r2")
    stand(s, id, :a)
    stand(s, id, :b, mode: :flaky)
    stand(s, id, :c)

    assert {:error, [{:undo_failed, label_b, :still_broken}]} = Unwind.run(s, id)
    assert label_b == Key.label(:b)
    assert order() == [:c, :a]
    assert [%{label: ^label_b}] = Ets.standing(s, id)

    Agent.update(@log, &%{&1 | fixed?: true})
    assert {:ok, []} = Unwind.run(s, id)
    # c and a were not undone a second time
    assert order() == [:c, :a, :b]
    assert calls(:c) == 1 and calls(:a) == 1
  end

  test "resumes after a crash mid-rollback: marked checkpoints are not undone twice", %{store: s} do
    id = run!(s, "r3")
    for n <- [:a, :b, :c], do: stand(s, id, n)
    # a prior rollback claimed :c, finished it, then died
    assert {:ok, _} =
             Ets.claim_undo(s, id, Key.for_name(:c), AshPPlan.Reactor.Durable.Clock.now())

    assert {:ok, []} = Unwind.run(s, id)
    assert order() == [:b, :a]
  end

  test "racing rollbacks undo each step exactly once", %{store: s} do
    id = run!(s, "r4")
    for n <- [:a, :b, :c, :d], do: stand(s, id, n, mode: :slow)

    1..8
    |> Enum.map(fn _ -> Task.async(fn -> Unwind.run(s, id) end) end)
    |> Task.await_many(10_000)
    |> Enum.each(&assert(match?({:ok, _}, &1)))

    assert Enum.sort(order()) == [:a, :b, :c, :d]
    for n <- [:a, :b, :c, :d], do: assert(calls(n) == 1)
  end

  test "retries a retrying undo and gives up after 5, leaving it standing", %{store: s} do
    id = run!(s, "r5")
    stand(s, id, :twice, mode: :retry_twice)
    stand(s, id, :forever, mode: :retry_forever)

    assert {:error, [{:undo_retries_exceeded, label}]} = Unwind.run(s, id)
    assert label == Key.label(:forever)
    assert calls(:forever) == 5
    assert calls(:twice) == 3
    assert [%{label: ^label}] = Ets.standing(s, id)
  end

  test "a step with no undo stays standing; an unresolvable impl is reported, not raised", %{
    store: s
  } do
    id = run!(s, "r6")
    stand(s, id, :keeps, [], NoUndoStep)
    {:ok, _} = Ets.record(s, id, Key.for_name(:ghost), "ghost", :x, %{impl: nil, args: nil})
    stand(s, id, :undone)

    assert {:ok, ["ghost"]} = Unwind.run(s, id)
    assert order() == [:undone]
    labels = Ets.standing(s, id) |> Enum.map(& &1.label) |> Enum.sort()
    assert labels == ["ghost", Key.label(:keeps)] |> Enum.sort()
  end

  test "children generated at run time (map/switch) undo from the stored snapshot alone", %{
    store: s
  } do
    id = run!(s, "r7")
    child = {:map_el, :items, 3}
    stand(s, id, child, name: child, log: @log)
    assert {:ok, []} = Unwind.run(s, id)
    assert [{^child, {:out, ^child}, %{who: ^child}, _}] = Agent.get(@log, & &1.order)
  end

  test "the Identity middleware context reaches undo (seeded from the enriched model)", %{
    store: s
  } do
    {:ok, model} =
      Model.new(
        name: "unwind-identity",
        goal: "g",
        tasks: [[id: :observe, capability: "File.Read", authority: :observe]]
      )

    step = Subject.correspondence(model.name, :observe).reactor
    {:ok, r} = Reactor.Builder.add_step(Reactor.Builder.new(), step, NoUndoStep, [])
    {:ok, r} = Reactor.Builder.return(r, step)
    {:ok, enriched} = AshPPlan.Reactor.enrich(r, model)
    assert AshPPlan.Reactor.Middleware.Identity in Enum.map(enriched.middleware, & &1)

    {:ok, _} = Ets.start_run(s, %{id: "r8", model: model, context: %{}})
    stand(s, "r8", :a)
    assert {:ok, []} = Unwind.run(s, "r8", context: enriched.context)

    [{:a, _, _, identity}] = Agent.get(@log, & &1.order)
    assert identity.subject == Subject.bind(model).id
    assert identity.bound_subject == identity.subject
  end

  test "anti-vacuity: with no workflow identity anywhere, undo is refused and nothing is undone",
       %{store: s} do
    {:ok, _} = Ets.start_run(s, %{id: "r9", context: %{}})
    stand(s, "r9", :a)

    assert {:error, [{:middleware_failed, %{reason: :missing_workflow_identity}}]} =
             Unwind.run(s, "r9")

    assert order() == []
    assert [_] = Ets.standing(s, "r9")
  end

  test "unknown run is a typed error", %{store: s} do
    assert {:error, [{:no_such_run, "nope"}]} = Unwind.run(s, "nope")
  end
end
