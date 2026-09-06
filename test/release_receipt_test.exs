defmodule AshPPlan.ReleaseReceiptTest do
  @moduledoc """
  `planning/ship_v26_9_6.hddl` makes `observed` and `receipted` release goals.
  These prove the release receipt is real evidence about an exact head rather
  than a restatement of the version string.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.ReleaseReceipt

  @root Path.expand("..", __DIR__)

  test "the receipt identifies the packaged release" do
    receipt = ReleaseReceipt.observe()

    assert receipt.release == AshPPlan.version()
    assert receipt.digest =~ ~r/^[0-9a-f]{64}$/
  end

  test "the receipt observes every input the release gate depends on" do
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

  describe "content addressing" do
    test "the same head digests identically" do
      assert ReleaseReceipt.observe().digest == ReleaseReceipt.observe().digest
    end

    test "a change to any single observed source changes the receipt" do
      sources = Enum.sort(ReleaseReceipt.sources())
      baseline = ReleaseReceipt.digest(AshPPlan.version(), sources)

      for {name, _digest} <- sources do
        mutated = Enum.map(sources, fn {n, d} -> if n == name, do: {n, "00"}, else: {n, d} end)

        refute ReleaseReceipt.digest(AshPPlan.version(), mutated) == baseline,
               "changing #{name} did not change the release digest"
      end
    end

    test "a different release identity digests differently" do
      sources = Enum.sort(ReleaseReceipt.sources())

      refute ReleaseReceipt.digest(AshPPlan.version(), sources) ==
               ReleaseReceipt.digest(AshPPlan.version() <> "-next", sources)
    end

    test "the digest algorithm itself is pinned" do
      # Without a fixed vector, every content-addressing test compares two
      # digests produced by the same code in the same run, which would still
      # agree if the algorithm silently changed.
      assert ReleaseReceipt.digest("26.9.7", [{"a", "00"}, {"b", "11"}]) ==
               "f54f3a20e8a0acce2fd9631d8f63daba1afa661f3557e6fed50d0e39f9fc8562"
    end

    test "source ordering is not part of the identity" do
      sources = Enum.sort(ReleaseReceipt.sources())

      assert ReleaseReceipt.digest(AshPPlan.version(), sources) ==
               ReleaseReceipt.digest(AshPPlan.version(), Enum.reverse(sources))
    end
  end

  test "the rendered receipt carries the release, digest and every source" do
    receipt = ReleaseReceipt.observe()
    json = ReleaseReceipt.to_json(receipt)

    assert json =~ ~s("release": "#{receipt.release}")
    assert json =~ ~s("digest": "#{receipt.digest}")

    for {name, digest} <- receipt.sources do
      assert json =~ ~s("#{name}": "#{digest}")
    end
  end

  test "a receipt grants no actuation authority" do
    receipt = ReleaseReceipt.observe()

    assert Map.keys(receipt) |> Enum.sort() == [:__struct__, :digest, :release, :sources]
  end
end
