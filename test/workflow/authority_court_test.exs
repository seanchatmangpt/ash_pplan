defmodule AshPPlan.Workflow.AuthorityCourtTest do
  @moduledoc """
  Authority Court. Falsifies: a valid plan granting authority, and `:do` (or
  any unknown authority) being admitted. Anti-vacuity mutations: a task with
  `:do` poisons an otherwise valid model, and the court must refuse it.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Authority, Model}

  defp model(auths) do
    tasks =
      auths
      |> Enum.with_index()
      |> Enum.map(fn {a, i} -> [id: :"t#{i}", capability: "Work.Select", authority: a] end)

    {:ok, m} = Model.new(name: :auth_wf, tasks: tasks)
    m
  end

  test "valid planning grants no authority" do
    assert Authority.granted(model([:construct, :observe])) == []
  end

  test "admit returns the highest declared ceiling" do
    assert {:ok, :construct} = Authority.admit(model([:observe, :construct, :select]))
    assert {:ok, :select} = Authority.admit(model([:observe, :select]))
    assert {:ok, :observe} = Authority.admit(model([]))
  end

  test "admits atoms and lists" do
    for a <- [:observe, :select, :construct], do: assert({:ok, ^a} = Authority.admit(a))
    assert {:ok, :select} = Authority.admit([:observe, :select])
  end

  test "DO is refused with a typed error" do
    assert {:error, %{reason: :authority_ceiling, authority: :do, max: :construct}} =
             Authority.admit(:do)

    assert {:error, %{reason: :authority_ceiling, authority: :do, task: :t1}} =
             Authority.admit(model([:construct, :do]))
  end

  test "unknown authority and non-atoms are refused" do
    assert {:error, %{reason: :authority_ceiling}} = Authority.admit(:root)
    assert {:error, %{reason: :authority_ceiling}} = Authority.admit("construct")
    assert {:error, %{reason: :authority_ceiling}} = Authority.admit([:observe, :actuate])
  end

  test "all refused tasks are reported" do
    {:error, e} = Authority.admit(model([:do, :construct, :do]))
    assert Enum.map(e.refused, & &1.task) == [:t0, :t2]
  end

  test "mutation: poisoning one task flips an admitted model to refused" do
    ok = model([:construct, :select])
    assert {:ok, _} = Authority.admit(ok)
    poisoned = %{ok | tasks: Enum.map(ok.tasks, &%{&1 | authority: :do})}
    assert {:error, %{reason: :authority_ceiling}} = Authority.admit(poisoned)
  end
end
