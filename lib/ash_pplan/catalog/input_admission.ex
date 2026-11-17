defmodule AshPPlan.Catalog.InputAdmission do
  @moduledoc """
  Runtime court that admits a step's bound inputs against typed variable laws.

  The generated catalog (`AshPPlan.Catalog.Plan`) carries bare input IRIs and
  `AshPPlan.Compiler` checks topology only. This module is the missing runtime
  half: given a `spec` describing each variable's laws, `admit/3` either returns
  `:ok` or a typed refusal listing every violated law. It is pure: no process
  state, no side effects, string patterns compiled once per call.

  ## Laws

    * `:required_missing` — `required: true` and the variable is absent
    * `:type` — value does not match `:integer | :string | :uuid | :boolean | :enum`
    * `:min` / `:max` — integer bounds, inclusive
    * `:pattern` — string does not match the regex
    * `:enum` — value not in `values`
    * `:has_value` — value does not equal `has_value`

  Input keys may be strings or atoms; spec keys are strings.

  ## Examples

      iex> spec = %{"count" => %{type: :integer, required: true, min: 1, max: 10}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{"count" => 5}, spec)
      :ok

      iex> spec = %{"count" => %{type: :integer, required: true, min: 1, max: 10}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{count: 11}, spec)
      {:error, {:input_refused, [%{var: "count", law: :max, got: 11}]}}

      iex> spec = %{"id" => %{type: :uuid, required: true}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{}, spec)
      {:error, {:input_refused, [%{var: "id", law: :required_missing, got: nil}]}}

      iex> spec = %{"id" => %{type: :uuid}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{"id" => "not-a-uuid"}, spec)
      {:error, {:input_refused, [%{var: "id", law: :type, got: "not-a-uuid"}]}}

      iex> spec = %{"ok" => %{type: :boolean}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{"ok" => "true"}, spec)
      :ok

      iex> spec = %{"mode" => %{type: :enum, values: ["fast", "slow"]}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{"mode" => "medium"}, spec)
      {:error, {:input_refused, [%{var: "mode", law: :enum, got: "medium"}]}}

      iex> spec = %{"code" => %{type: :string, pattern: "^[A-Z]{3}$"}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{"code" => "abc"}, spec)
      {:error, {:input_refused, [%{var: "code", law: :pattern, got: "abc"}]}}

      iex> spec = %{"kind" => %{type: :string, has_value: "intake"}}
      iex> AshPPlan.Catalog.InputAdmission.admit("step", %{"kind" => "intake"}, spec)
      :ok

  """

  defmodule Refused do
    @moduledoc "Raised by `AshPPlan.Catalog.InputAdmission.admit!/3` on refusal."
    defexception [:step_iri, :violations]

    @impl true
    def message(%{step_iri: step_iri, violations: violations}) do
      laws = Enum.map_join(violations, ", ", fn %{var: v, law: l} -> "#{v}:#{l}" end)
      "input refused for step #{step_iri}: #{laws}"
    end
  end

  @type var_type :: :integer | :string | :uuid | :boolean | :enum

  @type var_spec :: %{
          required(:type) => var_type(),
          optional(:required) => boolean(),
          optional(:min) => integer() | nil,
          optional(:max) => integer() | nil,
          optional(:pattern) => Regex.t() | String.t() | nil,
          optional(:values) => [String.t()] | nil,
          optional(:has_value) => term() | nil
        }

  @type spec :: %{optional(String.t()) => var_spec()}

  @type law :: :required_missing | :type | :min | :max | :pattern | :enum | :has_value

  @type violation :: %{var: String.t(), law: law(), got: term()}

  @uuid_pattern ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @doc """
  Admits `input` for `step_iri` against `spec`.

  Returns `:ok` or `{:error, {:input_refused, violations}}`. Violations are
  ordered by spec variable name so the refusal is deterministic.

      iex> AshPPlan.Catalog.InputAdmission.admit("s", %{}, %{})
      :ok

      iex> spec = %{"n" => %{type: :integer, min: 0}}
      iex> AshPPlan.Catalog.InputAdmission.admit("s", %{"n" => "3"}, spec)
      {:error, {:input_refused, [%{var: "n", law: :type, got: "3"}]}}

  """
  @spec admit(String.t(), map(), spec()) :: :ok | {:error, {:input_refused, [violation()]}}
  def admit(step_iri, input, spec) when is_binary(step_iri) and is_map(input) and is_map(spec) do
    violations =
      spec
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.flat_map(fn {name, var_spec} -> admit_var(name, fetch(input, name), var_spec) end)

    case violations do
      [] -> :ok
      violations -> {:error, {:input_refused, violations}}
    end
  end

  @doc """
  Like `admit/3` but raises `AshPPlan.Catalog.InputAdmission.Refused`.

      iex> AshPPlan.Catalog.InputAdmission.admit!("s", %{"n" => 1}, %{"n" => %{type: :integer}})
      :ok

      iex> try do
      ...>   AshPPlan.Catalog.InputAdmission.admit!("s", %{}, %{"n" => %{type: :integer, required: true}})
      ...> rescue
      ...>   e in AshPPlan.Catalog.InputAdmission.Refused -> e.violations
      ...> end
      [%{var: "n", law: :required_missing, got: nil}]

  """
  @spec admit!(String.t(), map(), spec()) :: :ok
  def admit!(step_iri, input, spec) do
    case admit(step_iri, input, spec) do
      :ok ->
        :ok

      {:error, {:input_refused, violations}} ->
        raise Refused, step_iri: step_iri, violations: violations
    end
  end

  # -- variable laws -------------------------------------------------------

  defp admit_var(name, :absent, var_spec) do
    if Map.get(var_spec, :required, false),
      do: [violation(name, :required_missing, nil)],
      else: []
  end

  defp admit_var(name, {:present, value}, var_spec) do
    case type_ok?(Map.fetch!(var_spec, :type), value, var_spec) do
      false ->
        [violation(name, :type, value)]

      true ->
        value = normalize(Map.fetch!(var_spec, :type), value)

        [
          check_min(var_spec, value),
          check_max(var_spec, value),
          check_pattern(var_spec, value),
          check_enum(var_spec, value),
          check_has_value(var_spec, value)
        ]
        |> Enum.flat_map(fn
          :ok -> []
          {:violation, law, got} -> [violation(name, law, got)]
        end)
    end
  end

  defp type_ok?(:integer, v, _), do: is_integer(v)
  defp type_ok?(:string, v, _), do: is_binary(v)

  defp type_ok?(:uuid, v, _),
    do: is_binary(v) and byte_size(v) == 36 and Regex.match?(@uuid_pattern, v)

  defp type_ok?(:boolean, v, _), do: v in [true, false, "true", "false"]
  defp type_ok?(:enum, v, _), do: is_binary(v) or is_atom(v)

  defp normalize(:boolean, "true"), do: true
  defp normalize(:boolean, "false"), do: false
  defp normalize(:enum, v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp normalize(_, v), do: v

  defp check_min(%{min: min}, v) when is_integer(min) and is_integer(v) and v < min,
    do: {:violation, :min, v}

  defp check_min(_, _), do: :ok

  defp check_max(%{max: max}, v) when is_integer(max) and is_integer(v) and v > max,
    do: {:violation, :max, v}

  defp check_max(_, _), do: :ok

  defp check_pattern(%{pattern: pattern}, v) when not is_nil(pattern) and is_binary(v) do
    if Regex.match?(compile_pattern(pattern), v), do: :ok, else: {:violation, :pattern, v}
  end

  defp check_pattern(_, _), do: :ok

  defp check_enum(%{values: values}, v) when is_list(values) do
    if v in values, do: :ok, else: {:violation, :enum, v}
  end

  defp check_enum(_, _), do: :ok

  defp check_has_value(%{has_value: expected}, v) when not is_nil(expected) do
    if v == expected, do: :ok, else: {:violation, :has_value, v}
  end

  defp check_has_value(_, _), do: :ok

  defp compile_pattern(%Regex{} = re), do: re
  defp compile_pattern(source) when is_binary(source), do: Regex.compile!(source)

  defp violation(var, law, got), do: %{var: var, law: law, got: got}

  # -- key access (string or atom keys) --------------------------------------

  defp fetch(input, name) do
    if Map.has_key?(input, name),
      do: {:present, Map.fetch!(input, name)},
      else: fetch_atom(input, name)
  end

  defp fetch_atom(input, name) do
    # String.to_existing_atom avoids minting atoms from untrusted input.
    key = String.to_existing_atom(name)
    if Map.has_key?(input, key), do: {:present, Map.fetch!(input, key)}, else: :absent
  rescue
    ArgumentError -> :absent
  end
end
