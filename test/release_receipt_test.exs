defmodule AshPPlan.ReleaseReceiptTest do
  @moduledoc """
  `planning/ship_v26_9_6.hddl` makes `observed` and `receipted` release goals.
  These prove the release receipt is real evidence about an exact head rather
  than a restatement of the version string.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.ReleaseReceipt

  @root Path.expand("..", __DIR__)
  @head String.duplicate("a", 40)

  test "the receipt identifies the packaged release and exact Git head" do
    receipt = ReleaseReceipt.observe(@head)

    assert receipt.release == AshPPlan.version()
    assert receipt.head == @head
    assert receipt.digest =~ ~r/^[0-9a-f]{64}$/
  end

  test "the receipt refuses an unbound or malformed Git identity" do
    invalid_heads = [
      "",
      "HEAD",
      "unknown",
      String.duplicate("a", 39),
      String.duplicate("g", 40)
    ]

    for invalid <- invalid_heads do
      assert_raise ArgumentError, fn -> ReleaseReceipt.observe(invalid) end
    end
  end

  test "the receipt observes every semantic/manufactured input the release gate depends on" do
    observed = ReleaseReceipt.sources() |> Map.keys() |> Enum.sort()

    assert observed == [
             "ecosystem.lock.toml",
             "lib/ash_pplan/generated/plan_catalog.ex",
             "lib/ash_pplan/generated/projection_catalog.ex",
             "ontology.ttl",
             "ontology/shapes.ttl"
           ]
  end

  test "every observed digest matches the file on this head" do
    for {name, digest} <- ReleaseReceipt.sources() do
      on_disk =
        @root
        |> Path.join(name)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert digest == on_disk, "#{name} changed since compilation; the receipt is stale"
    end
  end

  test "CI checks out the exact candidate head before observing it" do
    ci = @root |> Path.join(".github/workflows/ci.yml") |> File.read!()

    assert ci =~ "ref: ${{ github.event.pull_request.head.sha || github.sha }}"
  end

  describe "content addressing" do
    test "the same head digests identically" do
      assert ReleaseReceipt.observe(@head).digest == ReleaseReceipt.observe(@head).digest
    end

    test "a different Git head changes the receipt" do
      sources = Enum.sort(ReleaseReceipt.sources())

      refute ReleaseReceipt.digest(@head, AshPPlan.version(), sources) ==
               ReleaseReceipt.digest(String.duplicate("b", 40), AshPPlan.version(), sources)
    end

    test "a change to any single observed source changes the receipt" do
      sources = Enum.sort(ReleaseReceipt.sources())
      baseline = ReleaseReceipt.digest(@head, AshPPlan.version(), sources)

      for {name, _digest} <- sources do
        mutated = Enum.map(sources, fn {n, d} -> if n == name, do: {n, "00"}, else: {n, d} end)

        refute ReleaseReceipt.digest(@head, AshPPlan.version(), mutated) == baseline,
               "changing #{name} did not change the release digest"
      end
    end

    test "a different release identity digests differently" do
      sources = Enum.sort(ReleaseReceipt.sources())

      refute ReleaseReceipt.digest(@head, AshPPlan.version(), sources) ==
               ReleaseReceipt.digest(@head, AshPPlan.version() <> "-next", sources)
    end

    test "the digest algorithm itself is pinned" do
      assert ReleaseReceipt.digest(@head, "26.9.7", [{"a", "00"}, {"b", "11"}]) ==
               "bd1b6e9444c22cae8c968fe1d3080bb2a942e4d851fa4300f3ec2c4ce956da2e"
    end

    test "source ordering is not part of the identity" do
      sources = Enum.sort(ReleaseReceipt.sources())

      assert ReleaseReceipt.digest(@head, AshPPlan.version(), sources) ==
               ReleaseReceipt.digest(@head, AshPPlan.version(), Enum.reverse(sources))
    end
  end

  test "the rendered receipt carries the head, release, digest and every source" do
    receipt = ReleaseReceipt.observe(@head)
    json = ReleaseReceipt.to_json(receipt)

    assert json =~ ~s("release": "#{receipt.release}")
    assert json =~ ~s("head": "#{receipt.head}")
    assert json =~ ~s("digest": "#{receipt.digest}")

    for {name, digest} <- receipt.sources do
      assert json =~ ~s("#{name}": "#{digest}")
    end
  end

  test "a receipt grants no actuation authority" do
    receipt = ReleaseReceipt.observe(@head)

    assert Map.keys(receipt) |> Enum.sort() == [:__struct__, :digest, :head, :release, :sources]
  end
end
