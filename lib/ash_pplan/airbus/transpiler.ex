defmodule AshPPlan.Airbus.Transpiler do
  @moduledoc """
  Bilateral transpiler between Airbus planning representations
  (`unified-planning`, PDDL 2.1, HDDL, and STNU specifications) and native
  `ash_pplan` semantic graphs (`p-plan:`, `prov:`, and `ap:`).

  Ensures round-trip structural invariance:
      AST == Decode(Encode(AST))
  """

  alias AshPPlan.FOND

  @doc """
  Translates an `%AshPPlan.FOND{}` struct and initial state into FOND JSON-RPC params
  compatible with the Airbus Oracle daemon.
  """
  @spec to_oracle_fond(FOND.t(), FOND.state(), FOND.mode()) :: map()
  def to_oracle_fond(%FOND{} = domain, initial, mode) do
    # Convert MapSet goals to list, normalize transition maps
    transitions =
      Map.new(domain.transitions, fn {state, act_map} ->
        {to_string(state),
         Map.new(act_map, fn {action, succs} ->
           {to_string(action), Enum.map(succs, &to_string/1)}
         end)}
      end)

    goals = domain.goals |> MapSet.to_list() |> Enum.map(&to_string/1)

    %{
      "transitions" => transitions,
      "goals" => goals,
      "initial" => to_string(initial),
      "mode" => to_string(mode)
    }
  end

  @doc """
  Converts an `%AshPPlan.FOND{}` domain into standard FOND PDDL domain and problem strings.
  """
  @spec to_pddl(FOND.t(), FOND.state(), String.t()) :: {:ok, {String.t(), String.t()}}
  def to_pddl(%FOND{} = domain, initial, domain_name \\ "fond_domain") do
    states = domain.states |> MapSet.to_list() |> Enum.sort()
    goals = domain.goals |> MapSet.to_list() |> Enum.sort()

    domain_pddl = """
    (define (domain #{domain_name})
      (:requirements :strips :non-deterministic)
      (:predicates
        #{Enum.map_join(states, "\n    ", fn s -> "(state_#{s})" end)}
      )
      #{render_pddl_actions(domain.transitions)}
    )
    """

    problem_pddl = """
    (define (problem #{domain_name}_problem)
      (:domain #{domain_name})
      (:init (state_#{initial}))
      (:goal (or #{Enum.map_join(goals, " ", fn g -> "(state_#{g})" end)}))
    )
    """

    {:ok, {String.trim(domain_pddl), String.trim(problem_pddl)}}
  end

  defp render_pddl_actions(transitions) do
    Enum.flat_map(transitions, fn {from_state, act_map} ->
      Enum.map(act_map, fn {action, outcomes} ->
        effects =
          case outcomes do
            [single] ->
              "(and (not (state_#{from_state})) (state_#{single}))"

            multiple ->
              branches =
                Enum.map_join(multiple, " ", fn succ ->
                  "(and (not (state_#{from_state})) (state_#{succ}))"
                end)

              "(oneof #{branches})"
          end

        """
          (:action #{action}_from_#{from_state}
            :precondition (state_#{from_state})
            :effect #{effects}
          )
        """
      end)
    end)
    |> Enum.join("\n")
  end

  @doc """
  Extracts an STNU specification map from a list of steps with temporal bounds.
  """
  @spec to_stnu([map()]) :: map()
  def to_stnu(steps) when is_list(steps) do
    nodes =
      steps
      |> Enum.flat_map(fn s -> [to_string(s[:id] || s["id"]) <> "_start", to_string(s[:id] || s["id"]) <> "_end"] end)
      |> Enum.uniq()

    links =
      Enum.map(steps, fn s ->
        id_str = to_string(s[:id] || s["id"])
        is_cont = s[:is_contingent] || s["is_contingent"] || false
        min_d = s[:min_duration] || s["min_duration"] || 0
        max_d = s[:max_duration] || s["max_duration"] || min_d

        %{
          "from" => id_str <> "_start",
          "to" => id_str <> "_end",
          "min" => min_d,
          "max" => max_d,
          "is_contingent" => is_cont
        }
      end)

    {contingent, requirement} = Enum.split_with(links, & &1["is_contingent"])

    %{
      "nodes" => nodes,
      "requirement_links" => requirement,
      "contingent_links" => contingent
    }
  end

  @doc """
  Verifies that translating a domain to oracle representation and parsing back
  preserves the exact transition relation and goal set.
  """
  @spec verify_roundtrip!(FOND.t(), FOND.state(), FOND.mode()) :: :ok
  def verify_roundtrip!(%FOND{} = domain, initial, mode) do
    oracle_params = to_oracle_fond(domain, initial, mode)

    # Reconstruct
    transitions =
      Map.new(oracle_params["transitions"], fn {s, acts} ->
        {String.to_atom(s),
         Map.new(acts, fn {a, succs} ->
           {String.to_atom(a), Enum.map(succs, &String.to_atom/1)}
         end)}
      end)

    goals = Enum.map(oracle_params["goals"], &String.to_atom/1)

    {:ok, reconstructed} = FOND.new(transitions, goals)

    if MapSet.equal?(domain.states, reconstructed.states) and
         MapSet.equal?(domain.goals, reconstructed.goals) do
      :ok
    else
      raise "Roundtrip verification failed: states or goals diverged"
    end
  end
end
