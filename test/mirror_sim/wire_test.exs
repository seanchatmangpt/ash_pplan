defmodule AshPPlan.MirrorSim.WireTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.{Server, Wire}
  alias AshPPlan.RuntimeContract.ExactSubject

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    start_supervised!({Wire.Ledger, []})

    pid =
      start_supervised!(%{
        id: :wire_sim_server,
        start: {Server, :start_link, [[port: 0]]}
      })

    {:ok, base: String.trim_trailing(Server.base_url(pid), "/")}
  end

  defp request(:get, url, _body),
    do: :httpc.request(:get, {to_charlist(url), []}, [], body_format: :binary)

  defp request(:post, url, body),
    do:
      :httpc.request(:post, {to_charlist(url), [], ~c"application/json", body}, [],
        body_format: :binary
      )

  defp call(method, base, path, body \\ "") do
    {:ok, {{_, status, _}, _h, resp}} = request(method, base <> path, body)
    {status, Jason.decode(resp)}
  end

  defp post(base, path, term) when is_binary(term), do: call(:post, base, path, term)
  defp post(base, path, term), do: call(:post, base, path, Jason.encode!(term))

  defp state(base) do
    {200, {:ok, s}} = call(:get, base, "/wire/state")
    s
  end

  defp subject,
    do: %{
      "repo" => ExactSubject.identity().repo,
      "base" => ExactSubject.identity().base,
      "head" => ExactSubject.identity().head
    }

  defp valid(key),
    do: %{
      "subject" => subject(),
      "authority" => %{"action" => "CONSTRUCT", "policy" => "p"},
      "replay_key" => key,
      "action" => "CONSTRUCT",
      "result" => "ok"
    }

  defp assert_refused(res, term) do
    assert {422, {:ok, %{"refused" => true, "broken_term" => bt, "reason" => r}}} = res
    assert is_binary(r)
    if term, do: assert(bt == term, "expected #{term}, got #{bt}")
    bt
  end

  test "valid commit is admitted and readable back", %{base: base} do
    assert {201, {:ok, %{"replay_key" => "k1", "digest" => d}}} =
             post(base, "/wire/commit", valid("k1"))

    assert is_binary(d)
    assert state(base)["keys"] == ["k1"]
  end

  test "malformed, non-object, and oversized payloads refuse without state change", %{base: base} do
    before = state(base)
    post(base, "/wire/commit", Jason.encode!(valid("keep")))
    kept = state(base)
    assert kept["count"] == before["count"] + 1

    # Unparseable JSON is refused by the router's parser stage with its own 400.
    assert {400, {:ok, %{"refused" => true, "broken_term" => "malformed_json"}}} =
             post(base, "/wire/commit", "{not json")

    # Empty body parses to %{} and is refused by the handler for lacking a replay key.
    assert_refused(post(base, "/wire/commit", ""), "missing_replay_key")

    for body <- ["[]", "42", "null", "\"s\""],
        do: assert_refused(post(base, "/wire/commit", body), "not_object")

    huge = Jason.encode!(Map.put(valid("big"), "result", String.duplicate("x", 200_000)))
    assert_refused(post(base, "/wire/commit", huge), "payload_too_large")

    assert state(base) == kept
  end

  test "duplicate and replayed commits refuse; first receipt unchanged", %{base: base} do
    assert {201, {:ok, first}} = post(base, "/wire/commit", valid("dup"))
    changed = Map.put(valid("dup"), "result", "other")
    assert_refused(post(base, "/wire/commit", changed), "duplicate_replay_key")
    assert_refused(post(base, "/wire/commit", valid("dup")), "duplicate_replay_key")
    assert {200, {:ok, again}} = post(base, "/wire/replay", %{"replay_key" => "dup"})
    assert again == first
    assert state(base)["count"] == 1
  end

  test "reordered: replay before commit refuses, then succeeds after commit", %{base: base} do
    assert_refused(post(base, "/wire/replay", %{"replay_key" => "late"}), "unknown_replay_key")
    assert state(base)["count"] == 0
    assert {201, _} = post(base, "/wire/commit", valid("late"))

    assert {200, {:ok, %{"replay_key" => "late"}}} =
             post(base, "/wire/replay", %{"replay_key" => "late"})
  end

  test "replay without key refuses typed", %{base: base} do
    assert_refused(post(base, "/wire/replay", %{}), "missing_replay_key")
    assert_refused(post(base, "/wire/replay", %{"replay_key" => nil}), "missing_replay_key")
  end

  test "forged subjects refuse; ledger empty", %{base: base} do
    id = subject()

    forged = [
      Map.put(id, "head", String.duplicate("0", 40)),
      Map.put(id, "base", "deadbeef"),
      Map.put(id, "repo", "other_repo"),
      Map.delete(id, "head"),
      Map.put(id, "head", 7),
      "ash_pplan",
      nil,
      []
    ]

    for {s, i} <- Enum.with_index(forged) do
      body = Map.put(valid("f#{i}"), "subject", s)
      assert_refused(post(base, "/wire/commit", body), "subject_not_exact")
    end

    assert_refused(
      post(base, "/wire/commit", Map.delete(valid("nosub"), "subject")),
      "subject_not_exact"
    )

    assert state(base)["count"] == 0
  end

  test "missing or wrong authority refuses; ledger empty", %{base: base} do
    cases = [
      Map.delete(valid("a0"), "authority"),
      Map.put(valid("a1"), "authority", %{}),
      Map.put(valid("a2"), "authority", %{"action" => "CONSTRUCT"}),
      Map.put(valid("a3"), "authority", %{"action" => "CONSTRUCT", "policy" => nil}),
      Map.put(valid("a4"), "authority", %{"action" => "DO", "policy" => "p"}),
      Map.put(valid("a5"), "authority", %{"action" => "construct", "policy" => "p"}),
      Map.put(valid("a6"), "authority", "CONSTRUCT"),
      Map.put(valid("a7"), "authority", %{"action" => nil, "policy" => "p"})
    ]

    for c <- cases, do: assert_refused(post(base, "/wire/commit", c), "authority")
    assert state(base)["count"] == 0
  end

  test "missing replay_key refuses", %{base: base} do
    assert_refused(
      post(base, "/wire/commit", Map.delete(valid("x"), "replay_key")),
      "missing_replay_key"
    )

    assert_refused(
      post(base, "/wire/commit", Map.put(valid("x"), "replay_key", "")),
      "missing_replay_key"
    )

    assert_refused(
      post(base, "/wire/commit", Map.put(valid("x"), "replay_key", 5)),
      "missing_replay_key"
    )

    assert state(base)["count"] == 0
  end

  test "tampered receipts refuse verification; untampered verifies", %{base: base} do
    assert {201, {:ok, receipt}} = post(base, "/wire/commit", valid("t1"))

    assert {200, {:ok, %{"verified" => true}}} =
             post(base, "/wire/verify", %{"receipt" => receipt})

    tampers = [
      Map.put(receipt, "result", "forged"),
      Map.put(receipt, "action", "DO"),
      put_in(receipt, ["subject", "head"], String.duplicate("f", 40)),
      Map.put(receipt, "digest", String.duplicate("0", 64))
    ]

    for t <- tampers,
        do: assert_refused(post(base, "/wire/verify", %{"receipt" => t}), "tampered_receipt")

    assert_refused(
      post(base, "/wire/verify", %{"receipt" => %{"replay_key" => "ghost"}}),
      "unknown_replay_key"
    )

    assert_refused(post(base, "/wire/verify", %{"receipt" => "x"}), "not_object")
    assert_refused(post(base, "/wire/verify", %{}), "not_object")

    assert {200, {:ok, stored}} = post(base, "/wire/replay", %{"replay_key" => "t1"})
    assert stored == receipt
    assert state(base)["count"] == 1
  end

  test "duplicated JSON keys: parser picks one deterministically; only valid subject admitted",
       %{base: base} do
    # Which duplicate wins is decided by the router's Jason decode (not asserted here);
    # the court pins the consequence: sending both orders, exactly one order can be
    # admitted, it records the valid subject, and the forged-winning order is refused.
    good = Jason.encode!(subject())
    bad = Jason.encode!(Map.put(subject(), "head", "forged"))
    tail = ~s("authority":{"action":"CONSTRUCT","policy":"p"},"action":"CONSTRUCT","result":"ok"})

    good_first = ~s({"subject":#{good},"subject":#{bad},"replay_key":"dk1",) <> tail
    good_last = ~s({"subject":#{bad},"subject":#{good},"replay_key":"dk2",) <> tail

    r1 = post(base, "/wire/commit", good_first)
    r2 = post(base, "/wire/commit", good_last)

    statuses = Enum.sort([elem(r1, 0), elem(r2, 0)])
    assert statuses == [201, 422]

    {admitted_key, refused} =
      case {r1, r2} do
        {{201, _}, refused} -> {"dk1", refused}
        {refused, {201, _}} -> {"dk2", refused}
      end

    assert_refused(refused, "subject_not_exact")
    assert state(base)["keys"] == [admitted_key]

    assert {200, {:ok, %{"subject" => stored}}} =
             post(base, "/wire/replay", %{"replay_key" => admitted_key})

    assert stored == subject()
  end

  test "unknown route is typed, not 500", %{base: base} do
    assert {404, {:ok, %{"refused" => true, "broken_term" => "no_route"}}} =
             post(base, "/wire/nope", %{})
  end

  test "seeded fuzz: every mutated payload refuses typed, ledger unchanged", %{base: base} do
    assert {201, _} = post(base, "/wire/commit", valid("anchor"))
    before = state(base)

    {cases, _} =
      Enum.map_reduce(1..60, :rand.seed_s(:exsss, {18, 18, 18}), fn i, st ->
        {pick, st} = :rand.uniform_s(5, st)
        {n, st} = :rand.uniform_s(64, st)

        case pick do
          1 ->
            {junk, st} = :rand.bytes_s(n, st)
            {<<0xFF>> <> junk, st}

          2 ->
            {h, st} = :rand.bytes_s(20, st)
            s = Map.put(subject(), "head", Base.encode16(h, case: :lower))
            {Jason.encode!(Map.put(valid("z#{i}"), "subject", s)), st}

          3 ->
            {a, st} = :rand.bytes_s(n, st)
            act = Base.encode16(a)

            {Jason.encode!(
               Map.put(valid("z#{i}"), "authority", %{"action" => act, "policy" => "p"})
             ), st}

          4 ->
            {Jason.encode!(valid("anchor")), st}

          5 ->
            {Jason.encode!(Map.put(valid("z#{i}"), "replay_key", nil)), st}
        end
      end)

    for body <- cases do
      assert {status, {:ok, %{"refused" => true, "broken_term" => bt}}} =
               post(base, "/wire/commit", body)

      assert status in [400, 422]
      assert is_binary(bt)
    end

    assert state(base) == before
  end
end
