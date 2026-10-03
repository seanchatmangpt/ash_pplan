defmodule AshPPlan.Standing.VocabularyTest do
  @moduledoc """
  Court for the 2026-10-03 receipt-schema-diff adoption
  (notes/receipt-schema-diff-2026-10-03.md, migration steps a+b): the closed standing
  vocabulary is the 9-value set with COMPENSATED/COMPENSATION_FAILED, the receipt struct
  admits both new values, and the schema's standing regex plus its broken_term-required
  allOf (COMPENSATION_FAILED must carry broken_term, mu_unlawful per the ggen_igniter
  mapping) admit exactly the same values. Anti-vacuity: an unknown value is refused by
  both the struct and the schema.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Standing.Receipt

  test "closed vocabulary is the 9-value set" do
    assert Receipt.standings() == [
             "ALIVE",
             "BLOCKED",
             "BUILD_BROKEN",
             "COMPENSATED",
             "COMPENSATION_FAILED",
             "PARTIAL_ALIVE",
             "REFUSED",
             "UNKNOWN",
             "UNSUPPORTED"
           ]
  end

  test "receipt struct admits COMPENSATED and COMPENSATION_FAILED standing values" do
    for value <- ["COMPENSATED", "COMPENSATION_FAILED"] do
      receipt =
        Receipt.new(%{
          "identity" => %{"subject" => "s", "run_id" => "r1"},
          "authority" => %{"ceiling" => "CONSTRUCT", "grant" => "NONE", "actor" => "ash_pplan"},
          "consequence" => %{"commits" => [], "files_changed" => [], "remote_effects" => []},
          "replay" => %{
            "commands" => [%{"cmd" => "true", "cwd" => "/tmp", "exit" => 0}],
            "ledger_digest" => String.duplicate("0", 64)
          },
          "standing" => %{"value" => value, "derived_from" => "court"}
        })

      assert :ok == Receipt.validate(receipt),
             "standing value #{value} should validate on the receipt struct"
    end
  end

  test "schema regex and broken_term allOf match the struct vocabulary" do
    schema = schema()

    assert schema["$id"] == "https://chatmangpt.com/schema/receipt/v2"

    regex =
      schema["properties"]["standing"]["properties"]["value"]["pattern"]

    {:ok, re} = Regex.compile(regex)

    for value <- Receipt.standings() do
      # the schema regex requires REFUSED to carry its layer suffix; the struct's
      # standings/0 lists the bare base
      wire = if value == "REFUSED", do: "REFUSED(plan_correct)", else: value
      assert Regex.match?(re, wire), "schema regex must admit #{value} (wire form #{wire})"
    end

    refute Regex.match?(re, "PARTIALLY_ALIVE")
    refute Regex.match?(re, "compensated")

    all_of = schema["properties"]["standing"]["allOf"]

    broken_term_required =
      Enum.find_value(all_of, fn cond ->
        if cond["then"]["required"] == ["broken_term"],
          do: cond["if"]["properties"]["value"]["pattern"],
          else: nil
      end)

    assert broken_term_required, "schema keeps the broken_term-required allOf"
    {:ok, bt_re} = Regex.compile(broken_term_required)

    for value <- ["BLOCKED", "BUILD_BROKEN", "REFUSED", "COMPENSATION_FAILED"] do
      assert Regex.match?(bt_re, value), "broken_term allOf must bind #{value}"
    end

    for value <- ["ALIVE", "PARTIAL_ALIVE", "COMPENSATED", "UNKNOWN", "UNSUPPORTED"] do
      refute Regex.match?(bt_re, value), "broken_term allOf must not bind #{value}"
    end
  end

  defp schema do
    Path.join(
      File.cwd!(),
      "priv/ggen/ash-pplan-standing-pack/qualification-receipt.schema.json"
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
