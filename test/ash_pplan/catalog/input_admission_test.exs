defmodule AshPPlan.Catalog.InputAdmissionTest do
  @moduledoc """
  Chicago court for `AshPPlan.Catalog.InputAdmission`: every law has an
  admitting row and a refusing row. A law whose refusing row cannot produce a
  violation is a vacuous court and this file fails.

  Mutation note (which clause removal flips which test):

    * delete `admit_var(name, :absent, ...)` required branch -> `required_missing` refuse row
    * delete `type_ok?(:integer ...)` -> `type integer` refuse row (and admit row crashes)
    * delete byte_size/regex guard in `type_ok?(:uuid ...)` -> `type uuid` refuse row
    * delete `"true"/"false"` from `type_ok?(:boolean ...)` -> `type boolean string` admit row
    * delete `check_min` first clause -> `min` refuse row
    * delete `check_max` first clause -> `max` refuse row
    * delete `check_pattern` first clause -> `pattern string` / `pattern regex` refuse rows
    * delete `check_enum` first clause -> `enum` refuse row
    * delete `check_has_value` first clause -> `has_value` refuse row
    * delete `fetch_atom` -> `atom keys` admit row (reads as required_missing)
    * delete `Enum.sort_by` in `admit/3` -> `multiple violations ordered` test
    * delete `raise Refused` in `admit!/3` -> `admit! raises` test
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Catalog.InputAdmission
  alias AshPPlan.Catalog.InputAdmission.Refused

  doctest InputAdmission

  @step "https://w3id.org/ash-pplan#EmailIngestStep"
  @uuid "123e4567-e89b-12d3-a456-426614174000"

  # {name, spec, admitting_input, refusing_input, expected_violation}
  @table [
    {"required_missing", %{"a" => %{type: :string, required: true}}, %{"a" => "x"}, %{},
     %{var: "a", law: :required_missing, got: nil}},
    {"type integer", %{"n" => %{type: :integer}}, %{"n" => 3}, %{"n" => "3"},
     %{var: "n", law: :type, got: "3"}},
    {"type string", %{"s" => %{type: :string}}, %{"s" => "hi"}, %{"s" => 7},
     %{var: "s", law: :type, got: 7}},
    {"type uuid", %{"id" => %{type: :uuid}}, %{"id" => @uuid},
     %{"id" => "123e4567-e89b-12d3-a456-42661417400g"},
     %{var: "id", law: :type, got: "123e4567-e89b-12d3-a456-42661417400g"}},
    {"type uuid length", %{"id" => %{type: :uuid}}, %{"id" => @uuid}, %{"id" => "123e4567"},
     %{var: "id", law: :type, got: "123e4567"}},
    {"type boolean literal", %{"b" => %{type: :boolean}}, %{"b" => false}, %{"b" => "yes"},
     %{var: "b", law: :type, got: "yes"}},
    {"type boolean string", %{"b" => %{type: :boolean}}, %{"b" => "true"}, %{"b" => 1},
     %{var: "b", law: :type, got: 1}},
    {"type enum", %{"e" => %{type: :enum, values: ["a", "b"]}}, %{"e" => "a"}, %{"e" => 1},
     %{var: "e", law: :type, got: 1}},
    {"min", %{"n" => %{type: :integer, min: 2}}, %{"n" => 2}, %{"n" => 1},
     %{var: "n", law: :min, got: 1}},
    {"max", %{"n" => %{type: :integer, max: 2}}, %{"n" => 2}, %{"n" => 3},
     %{var: "n", law: :max, got: 3}},
    {"pattern string", %{"c" => %{type: :string, pattern: "^[A-Z]{3}$"}}, %{"c" => "ABC"},
     %{"c" => "abc"}, %{var: "c", law: :pattern, got: "abc"}},
    {"pattern regex", %{"c" => %{type: :string, pattern: ~r/^\d+$/}}, %{"c" => "42"},
     %{"c" => "4x"}, %{var: "c", law: :pattern, got: "4x"}},
    {"enum", %{"m" => %{type: :enum, values: ["fast", "slow"]}}, %{"m" => "fast"},
     %{"m" => "medium"}, %{var: "m", law: :enum, got: "medium"}},
    {"has_value", %{"k" => %{type: :string, has_value: "intake"}}, %{"k" => "intake"},
     %{"k" => "other"}, %{var: "k", law: :has_value, got: "other"}}
  ]

  for {name, spec, admit_input, refuse_input, violation} <- @table do
    @spec_row spec
    @admit_input admit_input
    @refuse_input refuse_input
    @violation violation
    @row_name name

    test "law #{name}: admits" do
      assert :ok == InputAdmission.admit(@step, @admit_input, @spec_row)
    end

    test "law #{name}: refuses" do
      assert {:error, {:input_refused, violations}} =
               InputAdmission.admit(@step, @refuse_input, @spec_row)

      assert @violation in violations
      refute violations == [], "court for #{@row_name} could not refuse: VACUOUS"
    end
  end

  test "atom keys are accepted" do
    spec = %{"count" => %{type: :integer, required: true}}
    assert :ok == InputAdmission.admit(@step, %{count: 1}, spec)
  end

  test "unknown atom-named variable is absent, not minted" do
    spec = %{"definitely_not_an_existing_atom_zz9" => %{type: :integer, required: true}}

    assert {:error, {:input_refused, [%{law: :required_missing}]}} =
             InputAdmission.admit(@step, %{}, spec)
  end

  test "optional absent variable admits" do
    assert :ok == InputAdmission.admit(@step, %{}, %{"x" => %{type: :integer}})
  end

  test "boolean string normalizes before has_value" do
    spec = %{"b" => %{type: :boolean, has_value: true}}
    assert :ok == InputAdmission.admit(@step, %{"b" => "true"}, spec)

    assert {:error, {:input_refused, [%{var: "b", law: :has_value, got: false}]}} =
             InputAdmission.admit(@step, %{"b" => "false"}, spec)
  end

  test "enum accepts atom value against string values" do
    spec = %{"m" => %{type: :enum, values: ["fast"]}}
    assert :ok == InputAdmission.admit(@step, %{"m" => :fast}, spec)
  end

  test "multiple violations ordered by var name, all laws reported" do
    spec = %{
      "z" => %{type: :integer, required: true},
      "a" => %{type: :integer, min: 5, max: 3}
    }

    assert {:error, {:input_refused, violations}} = InputAdmission.admit(@step, %{"a" => 4}, spec)

    assert violations == [
             %{var: "a", law: :min, got: 4},
             %{var: "a", law: :max, got: 4},
             %{var: "z", law: :required_missing, got: nil}
           ]
  end

  test "type violation short-circuits the other laws" do
    spec = %{"n" => %{type: :integer, min: 10}}

    assert {:error, {:input_refused, [%{var: "n", law: :type, got: "x"}]}} =
             InputAdmission.admit(@step, %{"n" => "x"}, spec)
  end

  test "admit! returns :ok on admission" do
    assert :ok == InputAdmission.admit!(@step, %{"n" => 1}, %{"n" => %{type: :integer}})
  end

  test "admit! raises Refused carrying step and violations" do
    spec = %{"n" => %{type: :integer, required: true}}

    err = assert_raise Refused, fn -> InputAdmission.admit!(@step, %{}, spec) end
    assert err.step_iri == @step
    assert err.violations == [%{var: "n", law: :required_missing, got: nil}]
    assert Exception.message(err) =~ "n:required_missing"
  end
end
