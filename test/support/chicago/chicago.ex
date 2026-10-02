defmodule AshPPlan.Test.Chicago do
  @moduledoc """
  Sabotage / negative-witness helpers adapted from `chicago-tdd-tools-pack`
  (~/ggen-marketplace/packs/chicago-tdd-tools-pack).

  The pack's pattern (its ontology `ctt:` individuals and `run_boundary_spec`
  dispatch) is: one reusable, real dispatch function; each negative-witness
  case is a REAL broken implementation or REAL corrupted input (never a mock);
  and the test asserts the DETECTION (the spec fails), not merely that the
  sabotage happened. This module ports that shape to in-process Elixir:

    * `sabotage_source!/3` - read the real production source, apply mechanical
      breaks (asserting every needle still matches, so a refactored source
      fails loudly instead of silently un-sabotaging), and compile the mutated
      copy in-process under a `Mutation.Chicago.*` name. This is the in-process
      analogue of the pack spawning the real binary: the mutant is a real
      compilable implementation, not a stub.
    * `assert_detected!/4` - run one property against the production module and
      against every sabotage; the production subject must pass, every sabotage
      must FAIL. The returned value is the detection receipt.

  Chicago discipline: no mocks. Every subject is a real module compiled from
  real source, every corrupted input is a real file, every property runs the
  real collaborators.
  """

  import ExUnit.Assertions

  @doc """
  Compile a sabotaged copy of the production source at `relative_path`.

  `breaks` is a list of `{needle, replacement}` pairs applied in order; every
  needle must occur exactly in the current source or the assertion fails (a
  silent no-op sabotage is itself a defect). The original `defmodule` name is
  renamed to `as` before compilation. Returns the mutated module atom.
  """
  @spec sabotage_source!(String.t(), String.t(), [{String.t(), String.t()}]) :: module()
  def sabotage_source!(relative_path, as, breaks) do
    source = File.read!(Path.expand(relative_path, File.cwd!()))

    mutated =
      Enum.reduce(breaks, source, fn {needle, replacement}, acc ->
        assert String.contains?(acc, needle),
               "sabotage needle no longer matches #{relative_path}: #{inspect(needle)}"

        String.replace(acc, needle, replacement, global: false)
      end)

    assert mutated != source, "sabotage produced no change to #{relative_path}"

    mutated = rename_module(mutated, as)

    Code.compile_string(mutated)

    # Module atoms carry BEAM's "Elixir." prefix; a bare String.to_atom of an
    # alias-looking string produces a DIFFERENT atom and the module is
    # unreachable through it.
    String.to_atom("Elixir." <> as)
  end

  @doc """
  Negative-witness assertion in the pack's `BoundarySpec` shape: one property,
  run against the real subject (must pass) and against every sabotage (must
  FAIL). Returns `:detected` -- the receipt -- or raises naming the vacuous
  court.
  """
  @spec assert_detected!(String.t(), term(), [{String.t(), term()}], (term() -> :pass | term())) ::
          :detected
  def assert_detected!(name, subject, sabotages, property) when is_function(property, 1) do
    assert property.(subject) == :pass,
           "#{name}: production subject must pass the property"

    for {label, sabotage} <- sabotages do
      result = property.(sabotage)

      assert result != :pass,
             "#{name}: sabotage #{inspect(label)} was NOT detected -- the court is vacuous " <>
               "(mutant satisfied the same property as production)"
    end

    :detected
  end

  defp rename_module(source, as) do
    case Regex.run(~r/defmodule\s+([A-Za-z0-9._]+)/, source) do
      [_, original] ->
        String.replace(source, "defmodule #{original} do", "defmodule #{as} do")

      nil ->
        flunk("no defmodule found in sabotaged source")
    end
  end
end
