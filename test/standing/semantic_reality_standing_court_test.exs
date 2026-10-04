defmodule AshPPlan.Standing.SemanticRealityCourtTest do
  @moduledoc """
  Pins the README's standing semantics to real behavior (Chicago: real runs,
  real receipts, no mocks):

    * the three-layer verdict (`AshPPlan.Standing.verdict/3`),
    * the five required receipt fields (identity/authority/consequence/replay/standing),
    * the 9-value standing vocabulary including ALIVE/BLOCKED/COMPENSATED,
    * `AshPPlan.Standing.Receipt.validate/1` typed broken terms.

  Anti-vacuity: a receipt missing every required field yields a validate/1 error
  naming each missing field (one field at a time, since validate names the first
  failing field in ontology order), and ALIVE is admitted only with all five
  fields present — never vacuously.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Receipt

  Code.require_file("standing_fixtures.exs", __DIR__)

  # ---- three-layer verdict ----

  describe "Standing.verdict/3" do
    test "all three layers ok is :alive" do
      assert Standing.verdict(:ok, :ok, :ok) == :alive
    end

    test "each broken layer is named, in layer order" do
      layers = Standing.layers()
      assert layers == [:plan_correct, :execution_correct, :observed_consequence_correct]

      for layer <- layers do
        args =
          Enum.map(layers, fn l -> if l == layer, do: {:error, :x}, else: :ok end)

        assert apply(&Standing.verdict/3, args) == {:lost, [layer]}
      end
    end

    test "multiple broken layers are reported together in layer order" do
      assert Standing.verdict({:error, :a}, :ok, {:error, :c}) ==
               {:lost,
                [
                  :plan_correct,
                  :observed_consequence_correct
                ]}

      assert Standing.verdict({:error, :a}, {:error, :b}, {:error, :c}) ==
               {:lost,
                [
                  :plan_correct,
                  :execution_correct,
                  :observed_consequence_correct
                ]}
    end

    test "non-:ok values count as broken, not just {:error, _}" do
      assert Standing.verdict(nil, :ok, :ok) == {:lost, [:plan_correct]}
      assert Standing.verdict(:ok, false, :ok) == {:lost, [:execution_correct]}
    end
  end

  # ---- five required fields ----

  describe "Receipt five required fields" do
    test "field list is exactly identity/authority/consequence/replay/standing in ontology order" do
      assert Receipt.fields() == ["identity", "authority", "consequence", "replay", "standing"]
    end

    test "a receipt missing every required field yields an error naming each field" do
      # validate/1 names the FIRST failing field in ontology order, so the
      # anti-vacuity check drops exactly one field at a time and requires the
      # error to name that field's broken term.
      broken_terms = %{
        "identity" => "R_missing_identity",
        "authority" => "R_missing_authority",
        "consequence" => "R_missing_consequence",
        "replay" => "R_missing_replay",
        "standing" => "R_missing_standing"
      }

      for field <- Receipt.fields() do
        receipt =
          struct(Receipt, Enum.map(Receipt.fields(), &{String.to_atom(&1), complete_field(&1)}))
          |> struct(Enum.map([field], fn f -> {String.to_atom(f), nil} end))

        assert match?(%Receipt{}, receipt)
        assert {:error, %{broken_term: term, field: ^field}} = Receipt.validate(receipt)
        assert term == Map.fetch!(broken_terms, field)
      end

      # And the fully empty receipt (every field nil) fails too, starting at identity.
      assert {:error, %{broken_term: "R_missing_identity", field: "identity"}} =
               Receipt.validate(%Receipt{})
    end

    test "present fields with empty required keys are not vacuously valid" do
      # identity present but without run_id/subject
      r =
        Receipt.new(%{
          identity: %{},
          authority: authority(),
          consequence: consequence(),
          replay: replay(),
          standing: standing("ALIVE")
        })

      assert {:error,
              %{
                broken_term: "R_missing_identity",
                field: "identity",
                reason: {:missing_keys, missing_keys}
              }} =
               Receipt.validate(r)

      assert Enum.sort(missing_keys) == ["run_id", "subject"]

      # replay with no command (identity complete so validate reaches replay)
      r2 = %{valid_receipt([]) | replay: %{commands: [], ledger_digest: "d"}}

      assert {:error, %{broken_term: "R_missing_replay", reason: :no_replay_command}} =
               Receipt.validate(r2)
    end

    test "a non-map field is refused, not coerced" do
      r = %Receipt{
        identity: "not-a-map",
        authority: authority(),
        consequence: consequence(),
        replay: replay(),
        standing: standing("ALIVE")
      }

      assert {:error, %{broken_term: "R_missing_identity", reason: {:not_a_map, "identity"}}} =
               Receipt.validate(r)
    end
  end

  # ---- 9-value standings vocabulary ----

  describe "standings ladder vocabulary" do
    test "exactly nine standings, including ALIVE, BLOCKED and COMPENSATED" do
      standings = Receipt.standings()
      assert length(standings) == 9

      for s <- ["ALIVE", "BLOCKED", "COMPENSATED"] do
        assert s in standings
      end

      assert Enum.sort(standings) ==
               Enum.sort([
                 "ALIVE",
                 "BLOCKED",
                 "BUILD_BROKEN",
                 "COMPENSATED",
                 "COMPENSATION_FAILED",
                 "PARTIAL_ALIVE",
                 "REFUSED",
                 "UNKNOWN",
                 "UNSUPPORTED"
               ])
    end

    test "each of the nine standings validates as a receipt standing value" do
      for s <- Receipt.standings() do
        r = valid_receipt(standing: standing(s))
        assert Receipt.validate(r) == :ok, "standing #{s} should validate"
      end
    end

    test "an unknown standing value is refused as unknown_standing" do
      r = valid_receipt(standing: standing("FUTURE_STATE"))

      assert {:error,
              %{broken_term: "R_missing_standing", reason: {:unknown_standing, "FUTURE_STATE"}}} =
               Receipt.validate(r)
    end

    test "REFUSED with a parenthesized layer list is an admissible standing value" do
      r = valid_receipt(standing: standing("REFUSED(plan_correct)"))
      assert Receipt.validate(r) == :ok
    end
  end

  # ---- typed broken terms ----

  describe "Receipt.validate/1 typed broken terms" do
    test "DO ceiling is refused as R_missing_authority (do_ceiling_unleased)" do
      r = valid_receipt(authority: %{actor: "a", ceiling: "DO", grant: "WRITE"})

      assert {:error,
              %{
                broken_term: "R_missing_authority",
                field: "authority",
                reason: {:do_ceiling_unleased, "DO"}
              }} = Receipt.validate(r)
    end

    test "safe ceilings CONSTRUCT/OBSERVE/SELECT validate; unknown ceiling refused" do
      for ceiling <- Receipt.safe_ceilings() do
        assert Receipt.validate(
                 valid_receipt(authority: %{actor: "a", ceiling: ceiling, grant: "NONE"})
               ) == :ok
      end

      assert {:error, %{reason: {:unknown_ceiling, "READ_WRITE"}}} =
               Receipt.validate(
                 valid_receipt(authority: %{actor: "a", ceiling: "READ_WRITE", grant: "NONE"})
               )
    end

    test "layer_term maps the three layers to their ontology terms and refuses unknown layers" do
      assert Receipt.layer_term(:plan_correct) == "mu_on_O"
      assert Receipt.layer_term(:execution_correct) == "mu_unlawful"
      assert Receipt.layer_term(:observed_consequence_correct) == "R_missing_consequence"
      assert {:error, %{broken_term: "R_unknown_layer"}} = Receipt.layer_term(:vibes)
      assert {:error, %{broken_term: "R_unknown_layer"}} = Receipt.layer_term("no-such-layer")
    end
  end

  # ---- real end-to-end: Standing.receipt/2 over a real evidenced run ----

  describe "Standing.receipt/2 end to end" do
    test "an evidenced alive run yields a validating five-field ALIVE receipt" do
      run = AshPPlan.Standing.Fixtures.run(3, "src-alive")

      assert Standing.standing(run) == :alive

      assert {:ok, receipt} = Standing.receipt(run, AshPPlan.Standing.Fixtures.opts())
      assert %Receipt{} = receipt

      for field <- Receipt.fields() do
        assert Map.fetch!(receipt, String.to_atom(field)) != nil, "field #{field} must be present"
      end

      assert Receipt.validate(receipt) == :ok
      assert receipt.standing.value == "ALIVE"
      assert receipt.standing.derived_from =~ "ledger"
      assert receipt.identity.run_id == "src-alive"
      assert receipt.identity.subject == "subject-1"
      assert receipt.authority.ceiling == "CONSTRUCT"
      assert receipt.replay.ledger_digest
      assert receipt.replay.commands != []
    end

    test "a run with a broken layer is REFUSED with the layer's typed broken term" do
      # Break layer 3: a named consequence check observes false over real post-state.
      run =
        AshPPlan.Standing.Fixtures.run(3, "src-lost")
        |> Map.put(:consequence, chain_complete: false)

      assert {:lost, [:observed_consequence_correct]} = Standing.standing(run)

      assert {:ok, receipt} = Standing.receipt(run, AshPPlan.Standing.Fixtures.opts())
      assert receipt.standing.value == "REFUSED(observed_consequence_correct)"
      assert receipt.standing.broken_term == "R_missing_consequence"

      assert {:error, %{broken_term: "R_missing_standing"}} =
               Receipt.validate(%{receipt | standing: nil})
    end

    test "ALIVE requires all five fields: dropping any one field breaks the receipt" do
      run = AshPPlan.Standing.Fixtures.run(2, "src-five")
      {:ok, receipt} = Standing.receipt(run, AshPPlan.Standing.Fixtures.opts())

      for field <- Receipt.fields() do
        stripped = Map.put(receipt, String.to_atom(field), nil)
        assert {:error, %{broken_term: term, field: ^field}} = Receipt.validate(stripped)
        assert term == "R_missing_#{field}"

        # The unstripped receipt is :ok — so the failure above is caused by the
        # missing field alone, never vacuously true.
        assert Receipt.validate(receipt) == :ok
      end
    end
  end

  # ---- helpers ----

  defp authority, do: %{actor: "ash_pplan", ceiling: "CONSTRUCT", grant: "NONE"}

  defp consequence, do: %{commits: [], files_changed: [], remote_effects: ["checks=all"]}

  defp replay,
    do: %{commands: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}], ledger_digest: "digest-1"}

  defp standing(value), do: %{value: value, derived_from: "court test"}

  defp complete_field("identity"),
    do: %{run_id: "r1", subject: "s1", repo: "ash_pplan", subject_sha: String.duplicate("a", 40)}

  defp complete_field("authority"), do: authority()
  defp complete_field("consequence"), do: consequence()
  defp complete_field("replay"), do: replay()
  defp complete_field("standing"), do: standing("ALIVE")

  defp valid_receipt(overrides) do
    base = %{
      identity: complete_field("identity"),
      authority: authority(),
      consequence: consequence(),
      replay: replay(),
      standing: standing("ALIVE")
    }

    Receipt.new(Map.merge(base, Map.new(overrides)))
  end
end
