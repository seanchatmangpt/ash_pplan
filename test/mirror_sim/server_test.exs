defmodule AshPPlan.MirrorSim.ServerTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.Server

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    pid = start_supervised!({Server, port: 0})
    %{base: Server.base_url(pid), pid: pid}
  end

  defp get(base, path, headers \\ []) do
    {:ok, {{_, status, _}, _h, body}} =
      :httpc.request(:get, {String.to_charlist(base <> path), headers}, [], body_format: :binary)

    {status, body}
  end

  defp post(base, path, body) do
    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> path), [], ~c"application/json", body},
        [],
        body_format: :binary
      )

    {status, resp}
  end

  test "boots on an ephemeral real port", %{pid: pid} do
    assert Server.port(pid) > 0
    assert Server.base_url(pid) =~ ~r{^http://127\.0\.0\.1:\d+$}
  end

  test "health 200", %{base: base} do
    {200, body} = get(base, "/health")
    assert %{"status" => "ok"} = Jason.decode!(body)
  end

  test "two-probe identity: unauth /api/health is 401 with bearer message", %{base: base} do
    {401, body} = get(base, "/api/health")
    assert body =~ "missing or invalid Bearer token"
  end

  test "surfaces lists mounted and unmounted areas", %{base: base} do
    {200, body} = get(base, "/surfaces")
    decoded = Jason.decode!(body)
    areas = Enum.map(decoded["mounted"] ++ decoded["unmounted"], & &1["area"])
    assert length(areas) == 16
    assert "dsl" in areas and "coverage" in areas
  end

  test "unknown route is typed 404", %{base: base} do
    {404, body} = get(base, "/nope/at/all")
    assert %{"refused" => true, "broken_term" => "unknown_route"} = Jason.decode!(body)
  end

  test "known but unmounted area is typed 404 refusal or mounted area answers", %{base: base} do
    {status, body} = get(base, "/capability/__no_such_route__")
    assert status in [404, 422]
    assert %{"refused" => true} = Jason.decode!(body)
  end

  test "malformed JSON never 500, typed 400", %{base: base} do
    {status, body} = post(base, "/dsl/anything", "{not json")
    assert status == 400
    assert %{"refused" => true, "broken_term" => "malformed_json"} = Jason.decode!(body)
  end

  test "non-map JSON body on unknown area is typed, not 500", %{base: base} do
    {status, body} = post(base, "/zzz/x", "[1,2,3]")
    assert status == 404
    assert %{"refused" => true} = Jason.decode!(body)
  end

  test "typed 422 helper shape" do
    r = AshPPlan.MirrorSim.Json.refusal(:x, "why")
    assert r == %{"refused" => true, "broken_term" => "x", "reason" => "why"}
  end
end
