defmodule AshPPlan.Reactor.Durable.PortableTest do
  @moduledoc """
  Court for the ETF portability gate. Anti-vacuity: each runtime-only term (pid, ref, port,
  local closure) is refused at depth, and a gate that always returned true fails these.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Portable

  test "plain data and external funs are portable" do
    assert Portable.portable?(%{a: [1, {:b, "c"}], d: &String.upcase/1})
    assert {:ok, blob} = Portable.encode(%{k: [1, 2, 3]})
    assert {:ok, %{k: [1, 2, 3]}} = Portable.decode(blob)
  end

  test "runtime identities are refused at any depth" do
    local = fn -> :x end

    for bad <- [
          self(),
          make_ref(),
          local,
          %{nested: [{:ok, self()}]},
          %{self() => 1},
          [1 | make_ref()]
        ] do
      refute Portable.portable?(bad)
      assert {:error, :non_portable_runtime_term} = Portable.check(bad)
      assert {:error, :non_portable_runtime_term} = Portable.encode(bad)
    end
  end

  test "an external fun naming a missing function is refused" do
    refute Portable.portable?(Function.capture(NoSuch.Module, :nope, 1))
  end

  test "decode refuses a blob that smuggles a pid and garbage" do
    forged = :erlang.term_to_binary(%{p: self()})
    assert {:error, :non_portable_runtime_term} = Portable.decode(forged)
    assert {:error, :invalid_payload} = Portable.decode("not etf")
    assert {:error, :invalid_payload} = Portable.decode(:nope)
  end
end
