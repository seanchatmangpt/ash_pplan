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

  def load(path) do
    data = path |> File.read!() |> JSON.decode!()

    %{
      path: path,
      name: data["name"],
      mode: String.to_existing_atom(data["mode"]),
      transitions: decode_transitions(data["transitions"]),
      goals: Enum.map(data["goals"], &String.to_atom/1),
      policy:
        Map.new(data["policy"], fn {state, action} ->
          {String.to_atom(state), String.to_atom(action)}
        end),
      initial: String.to_atom(data["initial"]),
      expected: String.to_existing_atom(data["expected"]),
      failure_class: decode_optional_atom(data["failure_class"]),
      falsifier: data["falsifier"]
    }
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
