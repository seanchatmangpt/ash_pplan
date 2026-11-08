defmodule AshPPlan.ObligationTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Obligation

  test "mints content-addressed obligation ticket with deterministic digest" do
    run_id = "run-#{System.unique_integer([:positive])}"
    step_name = :dispatch_sms
    intent = :notify_contractor
    payload = %{phone: "+15551234567", message: "NTE offer $450 trade hours"}

    obl = Obligation.mint(run_id, step_name, intent, payload, metadata: %{priority: :high})

    assert String.starts_with?(obl.id, "obl-")
    assert String.starts_with?(obl.digest, "sha256:")
    assert obl.run_id == run_id
    assert obl.step_name == step_name
    assert obl.intent == intent
    assert obl.payload == payload
    assert obl.metadata == %{priority: :high}

    # Verify digest invariance
    assert Obligation.verify_digest(obl) == true

    # Tampered payload fails verification
    tampered = %{obl | payload: Map.put(payload, :extra, "tampered")}
    assert Obligation.verify_digest(tampered) == false
  end
end
