defmodule AshPPlan.FOND.TLA.JSON do
  @moduledoc """
  Portable JSON-compatible envelope for rendered TLA+ artifacts.
  """

  alias AshPPlan.FOND.TLA.Manifest

  @schema "ash_pplan/fond-tla-json/v1"

  @spec encode_map(map()) :: map()
  def encode_map(rendered) do
    manifest = Manifest.from_rendered(rendered)

    %{
      "schema" => @schema,
      "module_name" => rendered.module_name,
      "mode" => Atom.to_string(rendered.mode),
      "initial" => rendered.initial,
      "module" => rendered.module,
      "cfg" => rendered.cfg,
      "branches" => rendered.branches,
      "manifest" => stringify(manifest)
    }
  end

  @spec decode_map(map()) :: {:ok, map()} | {:error, map()}
  def decode_map(
        %{
          "schema" => @schema,
          "module_name" => name,
          "mode" => mode,
          "module" => module,
          "cfg" => cfg,
          "branches" => branches
        } = input
      )
      when is_binary(name) and is_binary(module) and is_binary(cfg) and is_list(branches) do
    with {:ok, mode} <- parse_mode(mode) do
      rendered = %{
        module_name: name,
        mode: mode,
        initial: input["initial"],
        module: module,
        cfg: cfg,
        branches: branches,
        state_names: %{}
      }

      expected = input["manifest"] || %{}
      actual = stringify(Manifest.from_rendered(rendered))

      if compatible_manifest?(expected, actual) do
        {:ok, rendered}
      else
        {:error, %{reason: :manifest_mismatch, expected: expected, actual: actual}}
      end
    end
  end

  def decode_map(other), do: {:error, %{reason: :invalid_tla_json, value: other}}

  defp parse_mode("strong"), do: {:ok, :strong}
  defp parse_mode("strong_cyclic"), do: {:ok, :strong_cyclic}
  defp parse_mode(other), do: {:error, %{reason: :invalid_mode, mode: other}}

  defp compatible_manifest?(expected, actual) do
    Enum.all?(["module_sha256", "cfg_sha256", "subject_sha256"], fn key ->
      expected[key] == nil or expected[key] == actual[key]
    end)
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
