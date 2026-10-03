defmodule AshPPlan.Test.FONDFixture do
  @moduledoc false

  @root Path.expand("../fixtures/fond/tla", __DIR__)

  def all do
    @root
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load/1)
  end

  # Jason, not stdlib JSON: JSON only exists from Elixir 1.18 and mix.exs declares ~> 1.17.
  def load(path) do
    data = path |> File.read!() |> Jason.decode!()

    %{
      path: path,
      name: data["name"],
      mode: ensure_atom(data["mode"]),
      transitions: decode_transitions(data["transitions"]),
      goals: Enum.map(data["goals"], &String.to_atom/1),
      policy:
        Map.new(data["policy"], fn {state, action} ->
          {String.to_atom(state), String.to_atom(action)}
        end),
      initial: String.to_atom(data["initial"]),
      expected: ensure_atom(data["expected"]),
      failure_class: decode_optional_atom(data["failure_class"]),
      falsifier: data["falsifier"]
    }
  end

  # Scoped runs (e.g. `mix test test/tokyo_depeg/`) load only part of the
  # suite, so atoms that full-suite runs take for granted (:strong_cyclic,
  # :admitted, ...) may not exist yet in the VM. Prefer the existing atom;
  # fall back to minting it rather than crashing the scoped gate.
  defp ensure_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> String.to_atom(s)
  end

  defp decode_transitions(transitions) do
    Map.new(transitions, fn {state, actions} ->
      {String.to_atom(state),
       Map.new(actions, fn {action, outcomes} ->
         {String.to_atom(action), Enum.map(outcomes, &String.to_atom/1)}
       end)}
    end)
  end

  defp decode_optional_atom(nil), do: nil
  defp decode_optional_atom(value), do: String.to_atom(value)
end
