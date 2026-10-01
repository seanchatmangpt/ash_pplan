defmodule AshPPlan.Test.QualifiedFulfillmentCollab do
  @moduledoc """
  Starts the real collaborators (payment HTTP server, robot, worker) under one
  test supervisor. Returns handles and a `stop` fun.
  """
  alias AshPPlan.Test.{FulfillmentRobot, FulfillmentWorker, PaymentServer}

  def start(opts \\ []) do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, payment} = PaymentServer.start(Keyword.take(opts, [:mode]))
    counter = :counters.new(1, [])
    worker_name = Keyword.get(opts, :worker_name, FulfillmentWorker)

    {:ok, robot} =
      Supervisor.start_child(sup, %{
        id: :robot,
        start: {FulfillmentRobot, :start_link, [Keyword.take(opts, [:step_ms])]}
      })

    worker_spec = FulfillmentWorker.child_spec(name: worker_name, counter: counter)
    {:ok, worker} = Supervisor.start_child(sup, worker_spec)

    stop = fn ->
      payment.stop.()

      try do
        if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      :ok
    end

    {:ok,
     %{
       payment: payment,
       robot: robot,
       worker: worker,
       worker_name: worker_name,
       supervisor: sup,
       stop: stop
     }}
  end
end
