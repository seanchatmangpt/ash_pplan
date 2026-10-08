defmodule AshPPlan.Courts.PackGateWitnessCourtTest do
  @moduledoc """
  Qualification court for the ECO-SEMANTIC-GATE-WITNESS adoption
  (`docs/jira/ECO-SEMANTIC-GATE-WITNESS.md`, verdict ADOPT).

  Subject: `priv/ggen/semantic-gate-witness/` — a fail-closed
  gate<->witness court (pack semantic-gate-witness-court-pack 26.9.30,
  vendored at marketplace pin 29c579082aefe57eda5695d13cd4edb76cb82b31)
  over two real gates copied from the runtime overlay
  (`06-receipt.rq`, `08-refusal.rq`), each with a positive and a REFUSING
  witness (`require_fail = true`). Real state, Chicago-style: the court
  binary and the rdflib runner execute as real subprocesses and the
  assertions run against the JSON receipts they emit.

  Falsifiers held here:
    * every seeded gate has both a pass and a fail witness, and the
      refusing witness actually refuses (exactly-one-gate law) — standing
      ALIVE with every fail expectation qualified;
    * deleting a witness file (in a tmp copy of the surface) turns the
      court red with a typed `missing_fail` / `missing_pass` error — the
      court cannot pass while a gate silently carries no evidence.
  """

  use ExUnit.Case, async: false

  @repo Path.expand("../..", __DIR__)
  @surface Path.join(@repo, "priv/ggen/semantic-gate-witness")
  @vendored_pack Path.join(@repo, "priv/ggen/vendor/semantic-gate-witness-court-pack")
  # Re-pin receipt 2026-10-08 (lane pplan-repin): marketplace moved
  # ba21c22a -> 29c579082aefe57eda5695d13cd4edb76cb82b31 (v26.10.8 bump,
  # fast-forward ancestor check green); semantic-gate-witness-court-pack
  # surfaces byte-identical across the move (git diff ba21c22a 29c57908 --
  # packs/semantic-gate-witness-court-pack is empty), so this court's pin
  # moves with the lock, not the bytes.
  @pinned_marketplace_sha "29c579082aefe57eda5695d13cd4edb76cb82b31"
  @gates ["06-receipt", "08-refusal"]

  # The court binary and the runner are byte-identical projections of the
  # vendored pack templates (the pack's own contract-test law, enforced
  # consumer-side so template drift cannot pass silently).
  test "court binary and runner are byte-identical projections of the vendored pack" do
    for {projected, template} <- [
          {Path.join(@surface, "generated/semantic_gate_witness_court.py"),
           Path.join(@vendored_pack, "templates/semantic-gate-witness-court.py.tera")},
          {Path.join(@surface, "runners/semantic_runner.py"),
           Path.join(@vendored_pack, "templates/semantic-runner.py.tera")}
        ] do
      assert File.read!(projected) == File.read!(template),
             "#{projected} drifted from #{template}"
    end
  end

  test "vendored pack is locked at the pinned marketplace sha" do
    {out, 0} = System.cmd("git", ["-C", "/Users/sac/ggen-marketplace", "rev-parse", "HEAD"])
    assert String.trim(out) == @pinned_marketplace_sha

    lock =
      File.read!(Path.join(@repo, "priv/ggen/vendor/PACKS.lock.json"))
      |> Jason.decode!()

    pack = Enum.find(lock["packs"], &(&1["name"] == "semantic-gate-witness-court-pack"))
    assert pack, "semantic-gate-witness-court-pack missing from PACKS.lock.json"
    assert lock["source_git_sha"] == @pinned_marketplace_sha
  end

  test "court is ALIVE: every gate has pass+fail witnesses and the refusing witness refuses" do
    {out, 0} = run_court(@surface)

    receipt = Jason.decode!(out)
    assert receipt["standing"] == "ALIVE"
    assert receipt["errors"] == []
    assert receipt["gate_count"] == 2
    assert receipt["pass_witness_count"] == 2
    assert receipt["fail_witness_count"] == 2
    assert receipt["runner_executed"] == true

    keys = Enum.map(receipt["cases"], & &1["key"])
    assert Enum.sort(keys) == @gates

    # Refusing witness actually refuses: each gate's fail expectation ran
    # under the rdflib runner and was observed (exit 0 = expectation seen).
    for case <- receipt["cases"] do
      fail_execs = Enum.filter(case["executions"], &(&1["expectation"] == "fail"))
      assert length(fail_execs) == 1, "gate #{case["key"]} missing fail execution"

      for exec <- fail_execs do
        assert exec["qualified"] == true
        assert exec["exit_code"] == 0
        assert exec["stdout"] =~ ~s("observed": "fail")
      end
    end
  end

  test "receipt is deterministic (sorted-key JSON, sha256 identities)" do
    {out1, 0} = run_court(@surface)
    {out2, 0} = run_court(@surface)
    assert out1 == out2
    receipt = Jason.decode!(out1)

    for case <- receipt["cases"] do
      assert case["gate_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/

      for exec <- case["executions"],
          do: assert(exec["witness_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/)
    end
  end

  # Anti-vacuity: the court cannot pass while a gate carries no negative
  # evidence. Deleting a fail witness in a tmp copy must turn the court red
  # with a typed missing_fail refusal — fail-closed, not a silent pass.
  test "anti-vacuity: deleting a fail witness (tmp copy) turns the court red" do
    tmp = Path.join(System.tmp_dir!(), "gate-witness-court-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.cp_r!(@surface, tmp)

    File.rm!(Path.join(tmp, "witnesses/fail/06-receipt.ttl"))

    {out, 1} = run_court(tmp)
    receipt = Jason.decode!(out)
    assert receipt["standing"] == "REFUSED"
    assert %{"kind" => "missing_fail", "keys" => ["06-receipt"]} in receipt["errors"]
    File.rm_rf!(tmp)
  end

  # Same law on the positive side: a gate with no pass witness is refused.
  test "anti-vacuity: deleting a pass witness (tmp copy) turns the court red" do
    tmp = Path.join(System.tmp_dir!(), "gate-witness-court-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.cp_r!(@surface, tmp)

    File.rm!(Path.join(tmp, "witnesses/pass/08-refusal.ttl"))

    {out, 1} = run_court(tmp)
    receipt = Jason.decode!(out)
    assert receipt["standing"] == "REFUSED"
    assert %{"kind" => "missing_pass", "keys" => ["08-refusal"]} in receipt["errors"]
    File.rm_rf!(tmp)
  end

  # Orphan law: witness files whose stem matches no gate are refused, so
  # evidence for removed gates cannot linger unqualified.
  test "anti-vacuity: an orphan witness (tmp copy) turns the court red" do
    tmp = Path.join(System.tmp_dir!(), "gate-witness-court-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.cp_r!(@surface, tmp)

    File.write!(
      Path.join(tmp, "witnesses/fail/999-orphan.ttl"),
      "@prefix rt: <https://ggen.dev/ontology/runtime-integration#> .\nrt:x a rt:Integration .\n"
    )

    {out, 1} = run_court(tmp)
    receipt = Jason.decode!(out)
    assert receipt["standing"] == "REFUSED"
    assert %{"kind" => "orphan_fail", "keys" => ["999-orphan"]} in receipt["errors"]
    File.rm_rf!(tmp)
  end

  defp run_court(root) do
    court = Path.join(root, "generated/semantic_gate_witness_court.py")
    runner = Path.join(root, "runners/semantic_runner.py")

    args = [
      court,
      root,
      "--runner",
      "python3 #{runner} --gate {gate} --witness {witness} --expectation {expectation}"
    ]

    System.cmd("python3", args, cd: @repo)
  end
end
