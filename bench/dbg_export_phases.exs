alias AshPPlan.Reactor.Durable.{Store.Ets, LedgerOCEL}

{:ok, pid} = Ets.start_link()
{:ok, _} = Ets.start_run(pid, %{id: "p", status: :pending})

for i <- 1..100_000, do: Ets.record(pid, "p", "step-#{i}", "step", {:out, i}, %{i: i})
{:ok, _} = Ets.transition(pid, "p", :any, :completed, %{})
{:ok, evs} = LedgerOCEL.events(pid, "p")

:erlang.garbage_collect()

{t1, _} =
  :timer.tc(fn ->
    Enum.flat_map_reduce(evs, %MapSet{}, fn e, seen ->
      Enum.reduce(e.objects, {[], seen}, fn {_t, id, _q} = o, {acc, seen} ->
        if MapSet.member?(seen, id), do: {acc, seen}, else: {[o | acc], MapSet.put(seen, id)}
      end)
    end)
  end)

:erlang.garbage_collect()

{t2, _} =
  :timer.tc(fn -> Enum.sort(Enum.map(1..200_000, &{"Step", "step:step-#{&1}", "step"})) end)

:erlang.garbage_collect()

{t3, _} =
  :timer.tc(fn ->
    Enum.map(evs, fn e ->
      %{
        "id" => e.id,
        "type" => e.activity,
        "time" => DateTime.to_iso8601(e.timestamp),
        "attributes" =>
          Enum.map(Map.put(e.attributes, :subject_id, e.subject_id), fn {k, v} ->
            %{"name" => to_string(k), "value" => to_string(v)}
          end),
        "relationships" =>
          Enum.map(e.objects, fn {_t, id, q} -> %{"objectId" => id, "qualifier" => q} end)
      }
    end)
  end)

:erlang.garbage_collect()

{t4, _} =
  :timer.tc(fn -> Jason.encode!(%{"events" => Enum.map(evs, fn e -> %{"id" => e.id} end)}) end)

IO.puts("dedup=#{t1}us  sort200k=#{t2}us  docbuild=#{t3}us  jason=#{t4}us")
GenServer.stop(pid)
