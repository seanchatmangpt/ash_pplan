defmodule AshPPlan.MirrorSim.CoverageTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.{Coverage, Server}

  doctest AshPPlan.MirrorSim.Coverage

  @kd %{id: "KD-01", surface: "B.*", divergence: "d", evidence: "e", close: "c"}

  test "classify yields pass, divergence, and loud missing" do
    inv = [{A, :f, 1}, {A, :g, 0}, {B, :h, 2}]
    r = Coverage.classify(inv, [{A, :f, 1}], [@kd])
    assert Enum.map(r.cells, & &1.status) == [:pass, :missing, :divergence]
    assert Enum.at(r.cells, 2).kd == "KD-01"
  end

  test "court flips: removing the mirror surface and the KD turns cells missing" do
    inv = [{A, :f, 1}, {B, :h, 2}]
    assert Enum.all?(Coverage.classify(inv, [{A, :f, 1}], [@kd]).cells, &(&1.status != :missing))
    r = Coverage.classify(inv, [], [])
    assert Enum.all?(r.cells, &(&1.status == :missing))
  end

  test "exact-arity KD covers only that arity" do
    kd = %{@kd | surface: "`A.f/1`"} |> Map.update!(:surface, &String.replace(&1, "`", ""))
    r = Coverage.classify([{A, :f, 1}, {A, :f, 2}], [], [kd])
    assert Enum.map(r.cells, & &1.status) == [:divergence, :missing]
  end

  test "mirror name/N covers default-arg arities M <= N only" do
    r = Coverage.classify([{A, :f, 2}, {A, :f, 3}, {A, :f, 4}], [{A, :f, 3}], [])
    assert Enum.map(r.cells, & &1.status) == [:pass, :pass, :missing]
  end

  test "hidden-doc exported function is not phantom" do
    # Elixir.Kernel is outside AshPPlan; a real exported AshPPlan fun is never phantom
    {m, f, a} = hd(Coverage.inventory())
    assert Coverage.classify([], [{m, f, a}], []).phantoms == []
  end

  test "inventory is scoped to lib/" do
    refute Enum.any?(Coverage.inventory(), fn {m, _, _} ->
             s = inspect(m)
             String.starts_with?(s, "AshPPlan.Examples") or String.contains?(s, "ProcessWorker")
           end)
  end

  test "KD row with blank evidence does not register" do
    text = """
    | KD-01 | `A.f/1` | differs |  | later |
    | KD-02 | `A.g/1` | differs | receipt | later |
    """

    {valid, invalid} = Coverage.parse_register(text)
    assert Enum.map(valid, & &1.id) == ["KD-02"]
    assert Enum.map(invalid, & &1.id) == ["KD-01"]
  end

  test "phantom mirror surface in the AshPPlan namespace is flagged" do
    r = Coverage.classify([], [{AshPPlan.NoSuchModule, :x, 0}], [])
    assert r.phantoms == [{AshPPlan.NoSuchModule, :x, 0}]
  end

  test "inventory is derived mechanically and non-empty" do
    inv = Coverage.inventory()
    assert inv != []
    assert Enum.all?(inv, fn {m, f, a} -> function_exported?(m, f, a) end)

    refute Enum.any?(inv, fn {m, _, _} ->
             String.starts_with?(inspect(m), "AshPPlan.MirrorSim")
           end)
  end

  test "wire report equals direct report" do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, pid} = Server.start_link(port: 0)
    url = String.to_charlist(Server.base_url(pid) <> "/coverage/report")

    {:ok, {{_, 200, _}, _h, body}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    {:ok, wire} = Jason.decode(body)
    direct = Coverage.report()

    assert wire["total"] == direct.total
    assert wire["missing"] == direct.missing
    assert wire["pass"] == direct.pass
    assert wire["divergence"] == direct.divergence
    assert wire["ok"] == direct.ok
  end

  test "unknown coverage route is a typed refusal, not 500" do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, pid} = Server.start_link(port: 0)
    url = String.to_charlist(Server.base_url(pid) <> "/coverage/nope")

    {:ok, {{_, 404, _}, _h, body}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert {:ok, %{"refused" => true, "broken_term" => "unknown_route"}} = Jason.decode(body)
  end
end
