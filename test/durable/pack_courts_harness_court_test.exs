defmodule AshPPlan.Reactor.Durable.PackCourtsHarnessCourtTest do
  @moduledoc """
  Court over the cross-contract courts harness itself (ECO-SAGA-COMPENSATE,
  draft 3.2/4.1): `bin/runtime-contract-courts` must exit 0 with all 86
  cross-contract courts zero-row over the pack's positive fixture, the four
  pack admission gates zero-row over the consumer overlay ontology, and BOTH
  anti-vacuity legs witnessed. The negative-fixture mutation leg must exit
  non-zero and name the leaked integrations — a court set that passes the leak
  fixture detects nothing and is retired.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "bin/runtime-contract-courts")
  @pack Path.expand("~/ggen-marketplace/packs/ash-runtime-integration-contract-pack")

  @negative_fixture Path.join(@pack, "tests/cross-contract-negative.ttl")

  @tag timeout: 900_000
  test "harness exits 0: 86 courts zero-row, gates green, anti-vacuity witnessed" do
    {out, 0} = System.cmd(@script, [], cd: @root, stderr_to_stdout: true)

    assert out =~ "86 cross-contract courts"
    assert out =~ "positive fixture: 86 courts zero-row"
    assert out =~ "gates: 4 gates zero-row over the overlay ontology"
    assert out =~ "anti-vacuity: all 5 documented leaks caught"
    assert out =~ "gate-04 mutation: caught"
    assert out =~ "GREEN"
  end

  @tag timeout: 900_000
  test "negative-fixture mutation: the court set fires and names the leaks (anti-vacuity)" do
    {out, status} =
      System.cmd(@script, ["--fixture", @negative_fixture], cd: @root, stderr_to_stdout: true)

    # a court set that passes the leak fixture detects nothing: non-zero is the
    # pass condition of this mutation leg.
    refute status == 0
    assert out =~ "cross-contract courts"
    assert out =~ "FAIL queries/"

    # each documented leak individual is named in a failing court's rows
    for leak <- ["authorityLeak", "retryLeak", "tenantCacheLeak", "apiLeak", "reactorLeak"] do
      assert out =~ leak,
             "no court in the harness output fires for the #{leak} leak fixture:\n#{out}"
    end
  end
end
