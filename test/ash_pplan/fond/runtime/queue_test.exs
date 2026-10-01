defmodule AshPPlan.FOND.Runtime.QueueTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Runtime.Queue

  test "fifo" do
    q = Queue.new() |> Queue.push(:a) |> Queue.push(:b)
    assert {:ok, :a, q} = Queue.pop(q)
    assert {:ok, :b, _} = Queue.pop(q)
  end
end
