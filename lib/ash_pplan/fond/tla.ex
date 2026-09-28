defmodule AshPPlan.FOND.TLA do
  @moduledoc """
  TLA+ projection of a FOND domain under a candidate policy.

  The projection is render-only (authority `NONE`, ceiling `CONSTRUCT`): it
  produces a TLA+ module and a TLC configuration and never runs a model checker
  or actuates anything. It exists so the verdict of
  `AshPPlan.FOND.validate_policy/4` can be cross-examined by an independent
  checker (TLC) over the same abstraction.

  ## Rendered model

    * `state` — the FOND state. Every domain state is encoded as the TLA+
      string `"s<i>"` where `i` is its index in Erlang term order; the module
      header carries the `"s<i>" = inspect(term)` table as comments.
    * `tick` — a bit flipped by every policy step. Without it a self-loop
      outcome (`pending -> pending`) would be a TLA+ stuttering step and no
      fairness condition could distinguish "retry" from "do nothing".
    * one action `A_<i>` per `(state, policy action)` for every non-goal state
      whose policy decision is an admitted domain action. `A_<i>` is the
      disjunction of one branch action `B_<i>_<k>` per nondeterministic outcome.
    * `Done` — goal states are absorbing (`UNCHANGED vars`), matching the
      validator, which never consults the policy at a goal.
    * `Goal` — `state \\in {goal states}`; the checked property is
      `GoalReached == <>Goal`.

  A reachable non-goal state without a policy decision, or whose decision is not
  an admitted action, has no enabled action and is reported by TLC as a
  deadlock — the same refusal the validator reports as
  `:missing_policy_action` / `:unavailable_policy_action`.

  ## Modes

    * `:strong` — `Fairness == TRUE`: no fairness over outcome choice. The spec
      carries only `Progress == WF_vars(Next)` (the executor keeps acting instead
      of stuttering forever), so any reachable cycle among non-goal states is a
      counterexample to `<>Goal`.
    * `:strong_cyclic` — `Fairness` is the conjunction of `SF_vars(B_<i>_<k>)`
      over every outcome branch: an outcome enabled infinitely often is
      eventually taken. That is exactly the fairness assumption under which
      strong-cyclic policies guarantee the goal.
  """

  @module_name "FONDPolicy"

  @type rendered :: %{
          module_name: String.t(),
          module: String.t(),
          cfg: String.t(),
          mode: AshPPlan.FOND.mode(),
          initial: String.t(),
          state_names: %{optional(term()) => String.t()},
          branches: [String.t()]
        }

  @doc """
  Renders `domain × policy × initial` as a TLA+ module and TLC config.

  Options:

    * `:module_name` — TLA+ module name (default `"FONDPolicy"`); must be a
      TLA+ identifier. The TLC config file must be saved as `<name>.cfg` next to
      `<name>.tla`.
  """
  @spec render(AshPPlan.FOND.t(), AshPPlan.FOND.policy(), term(), AshPPlan.FOND.mode(), keyword()) ::
          {:ok, rendered()} | {:error, map()}
  def render(domain, policy, initial, mode, opts \\ [])

  def render(%AshPPlan.FOND{} = domain, policy, initial, mode, opts)
      when is_map(policy) and mode in [:strong, :strong_cyclic] and is_list(opts) do
    module_name = Keyword.get(opts, :module_name, @module_name)

    cond do
      not valid_identifier?(module_name) ->
        {:error, %{reason: :invalid_tla_module_name, module_name: module_name}}

      not MapSet.member?(domain.states, initial) ->
        {:error, %{reason: :unknown_initial_state, state: initial}}

      true ->
        {:ok, do_render(domain, policy, initial, mode, module_name)}
    end
  end

  def render(_domain, policy, initial, mode, opts),
    do:
      {:error,
       %{
         reason: :invalid_policy_request,
         policy: policy,
         initial: initial,
         mode: mode,
         opts: opts
       }}

  defp do_render(domain, policy, initial, mode, module_name) do
    states = Enum.sort(domain.states)
    names = states |> Enum.with_index() |> Map.new(fn {state, i} -> {state, "s#{i}"} end)

    actions =
      states
      |> Enum.with_index()
      |> Enum.flat_map(fn {state, i} -> policy_action(domain, policy, names, state, i) end)

    branches = Enum.flat_map(actions, fn action -> Enum.map(action.branches, & &1.name) end)

    module =
      [
        header(module_name, mode, states, names, policy),
        "EXTENDS Naturals\n\nVARIABLES state, tick\n\nvars == <<state, tick>>\n",
        "States == #{set(Enum.map(states, &names[&1]))}\n",
        "Goals == #{set(domain.goals |> Enum.sort() |> Enum.map(&names[&1]))}\n",
        "Goal == state \\in Goals\n",
        "TypeOK == state \\in States /\\ tick \\in {0, 1}\n",
        "Init == state = #{tla_string(names[initial])} /\\ tick = 0\n",
        Enum.map(actions, &render_action/1),
        "Done == state \\in Goals /\\ UNCHANGED vars\n",
        "Next ==\n" <> disjunction(Enum.map(actions, & &1.name) ++ ["Done"]) <> "\n",
        "Progress == WF_vars(Next)\n",
        fairness(mode, branches),
        "Spec == Init /\\ [][Next]_vars /\\ Progress /\\ Fairness\n",
        "GoalReached == <>Goal\n",
        String.duplicate("=", 77) <> "\n"
      ]
      |> List.flatten()
      |> Enum.join("\n")

    %{
      module_name: module_name,
      module: module,
      cfg: "SPECIFICATION Spec\nINVARIANT TypeOK\nPROPERTY GoalReached\n",
      mode: mode,
      initial: names[initial],
      state_names: names,
      branches: branches
    }
  end

  # A goal state is absorbing; a state without a decision, or with a decision
  # that is not an admitted domain action, renders no action (TLC deadlock).
  defp policy_action(domain, policy, names, state, i) do
    with false <- MapSet.member?(domain.goals, state),
         {:ok, action} <- Map.fetch(policy, state),
         [_ | _] = outcomes <- AshPPlan.FOND.outcomes(domain, state, action) do
      branches =
        outcomes
        |> Enum.with_index(1)
        |> Enum.map(fn {outcome, k} ->
          %{name: "B_#{i}_#{k}", from: names[state], to: names[outcome], outcome: outcome}
        end)

      [%{name: "A_#{i}", state: state, action: action, from: names[state], branches: branches}]
    else
      _ -> []
    end
  end

  defp render_action(action) do
    branch_defs =
      Enum.map(action.branches, fn branch ->
        "\\* outcome #{comment(branch.outcome)}\n" <>
          "#{branch.name} == state = #{tla_string(branch.from)} /\\ state' = #{tla_string(branch.to)}" <>
          " /\\ tick' = 1 - tick\n"
      end)

    [
      "\\* policy: #{comment(action.state)} -> #{comment(action.action)}\n",
      Enum.join(branch_defs, "\n"),
      "\n#{action.name} ==\n" <> disjunction(Enum.map(action.branches, & &1.name)) <> "\n"
    ]
    |> Enum.join()
  end

  defp fairness(:strong, _branches),
    do: "\\* strong: no fairness over nondeterministic outcomes\nFairness == TRUE\n"

  defp fairness(:strong_cyclic, []),
    do: "\\* strong_cyclic: no reachable outcome branches\nFairness == TRUE\n"

  defp fairness(:strong_cyclic, branches) do
    "\\* strong_cyclic: every outcome enabled infinitely often is eventually taken\n" <>
      "Fairness ==\n" <>
      Enum.map_join(branches, "\n", &"  /\\ SF_vars(#{&1})") <> "\n"
  end

  defp header(module_name, mode, states, names, policy) do
    dashes = String.duplicate("-", 4)

    table =
      Enum.map_join(states, "\n", fn state ->
        decision =
          case Map.fetch(policy, state) do
            {:ok, action} -> " policy=" <> comment(action)
            :error -> ""
          end

        "\\*   #{tla_string(names[state])} = #{comment(state)}#{decision}"
      end)

    [
      "#{dashes} MODULE #{module_name} #{dashes}\n",
      "\\* Generated by AshPPlan.FOND.to_tla/4 (authority NONE, ceiling CONSTRUCT).\n",
      "\\* mode: #{mode}\n",
      "\\* states:\n",
      table,
      "\n"
    ]
    |> Enum.join()
  end

  defp disjunction(names), do: Enum.map_join(names, "\n", &"  \\/ #{&1}")

  defp set([]), do: "{}"
  defp set(names), do: "{" <> Enum.map_join(names, ", ", &tla_string/1) <> "}"

  defp tla_string(name), do: ~s("#{name}")

  # Comment text is restricted to printable ASCII: line breaks, control and
  # non-ASCII characters (including U+2028/U+2029) are escaped as `\u{..}`, and
  # block-comment delimiters are split so a state term can never open or close
  # a TLA+ comment.
  defp comment(term) do
    term
    |> inspect(limit: 20, printable_limit: 80)
    |> String.replace(~r/[^\x20-\x7E]/u, fn char ->
      "\\u{" <> (char |> String.to_charlist() |> hd() |> Integer.to_string(16)) <> "}"
    end)
    |> String.replace("(*", "( *")
    |> String.replace("*)", "* )")
  end

  # TLA+ reserved words, standard modules, `WF_`/`SF_` fairness prefixes and the
  # identifiers this renderer defines are refused as module names: each would
  # make the module unparseable or shadow a definition the court depends on.
  @reserved_words ~w(
    ACTION ASSUME ASSUMPTION AXIOM BOOLEAN BY CASE CHOOSE CONSTANT CONSTANTS
    COROLLARY DEF DEFINE DEFS DOMAIN ELSE ENABLED EXCEPT EXTENDS FALSE HAVE HIDE
    IF IN INSTANCE LAMBDA LEMMA LET LOCAL MODULE NEW OBVIOUS OMITTED ONLY OTHER
    PICK PROOF PROPOSITION PROVE QED RECURSIVE STATE STRING SUBSET SUFFICES
    TAKE TEMPORAL THEN THEOREM TRUE UNCHANGED UNION USE VARIABLE VARIABLES
    WITH WITNESS
  )
  @standard_modules ~w(Naturals Integers Reals Sequences FiniteSets Bags TLC
                       TLCExt RealTime Randomization Json Nat Int Real Seq)
  @rendered_identifiers ~w(vars state tick States Goals Goal TypeOK Init Done
                           Next Progress Fairness Spec GoalReached)

  @doc false
  def reserved_module_names, do: @reserved_words ++ @standard_modules ++ @rendered_identifiers

  defp valid_identifier?(name) when is_binary(name) do
    Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_]*\z/, name) and
      not Regex.match?(~r/\A(WF_|SF_|A_\d+\z|B_\d+_\d+\z)/, name) and
      name not in reserved_module_names()
  end

  defp valid_identifier?(_name), do: false
end
