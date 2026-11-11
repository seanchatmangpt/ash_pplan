defmodule F8ScratchTest do
  use ExUnit.Case, async: false
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Reactor.Durable.Store.Wal
  alias AshPPlan.Reactor.Durable.Unwind

  @key AshPPlan.Reactor.context_key()

  defmodule Step do
    @behaviour Reactor.Step
    def run(_a, _o, _c), do: {:ok, :ran}
    def can?(_s, :undo), do: true
    def can?(_s, _), do: false

    def undo(_out, _args, ctx, _o) do
      IO.puts("UNDO name=#{inspect(ctx[:current_step] && ctx.current_step.name)}")
      :ok
    end
  end

  test "order debug" do
    {:ok, ets} = Ets.start_link()
    {:ok, wal} = Wal.open("/tmp/f8o-#{System.unique_integer([:positive])}.wal")

    for {tag, mod, store} <- [{"ets", Ets, ets}, {"wal", Wal, wal}] do
      run = "o-#{tag}"

      {:ok, _} = mod.start_run(store, %{id: run, context: %{@key => %{subject: "sha256:x"}}})

      for {k, i} <- [{"x1", 1}, {"x2", 2}, {"x3", 3}] do
        {:ok, _} =
          mod.record(store, run, k, inspect(k), {:out, i}, %{
            impl: {Step, []},
            name: String.to_atom(k),
            args: %{k: k}
          })
      end

      IO.puts("== #{tag} ==")

      res =
        Unwind.run(store, run,
          context: %{@key => %{subject: "sha256:x", workflow: "d"}},
          store_module: mod
        )

      IO.inspect(res, label: "#{tag} unwind")

      IO.inspect(mod.standing(store, run) |> Enum.map(& &1.step_key),
        label: "#{tag} standing-after"
      )
    end
  end
end
