defmodule AshPPlan.Hardening.FondPolicyFuzzTest do
  @moduledoc """
  P2a fuzz court for `AshPPlan.FOND` — the planning fence's policy-validation
  surface (`new/2`, `check/1`, `validate_policy/4`). No fuzz coverage existed
  for this surface: the fond* tests are fixed-case. Laws (seeded deterministic
  sweeps; no stream_data in deps, same idiom as the sibling courts):

    1. `new/2` is total: every (transitions, goals) pair from the garbage corpus
       returns `{:ok, %AshPPlan.FOND{}}` or `{:error, map}` with an atom reason —
       never a raise. Empty outcome lists are refused
       (`:empty_nondeterministic_outcome`): an action with no outcome must not
       admit as a vacuous success.
    2. Normalization closure: every domain `new/2` admits satisfies `check/1`
       with `:ok`; hand-built `%AshPPlan.FOND{}` structs that bypass `new/2` are
       refused with the exact `:invalid_domain` details.
    3. `validate_policy/4` is total: garbage domain/policy/initial/mode always
       returns a tagged result, never a raise, and policy defects carry their
       exact typed reasons.
    4. Mode lattice: on the canonical retry-cycle domain the same policy is
       `:not_strong` yet `:strong_cyclic`-valid, and a `:strong`-valid policy is
       also `:strong_cyclic`-valid.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND

  @states [:a, :b, :c, :done]
  @actions [:go, :retry]

  # Built at runtime: the corpus intentionally includes pids/refs/funs, which
  # cannot be escaped into module attributes.
  defp transition_garbage do
    [
      nil,
      :atom,
      42,
      1.5,
      "x",
      "",
      <<0, 255>>,
      [],
      [:a],
      {:t},
      self(),
      make_ref(),
      fn -> :ok end,
      # a struct is a map: must refuse per-entry, not raise
      MapSet.new([:a]),
      %{a: :not_a_map},
      %{a: %{x: :not_a_list}},
      %{a: %{x: nil}},
      %{a: %{x: []}},
      # duplicate outcomes are normalized away, so this pair admits
      %{a: %{x: [:done, :done]}}
    ]
  end

  defp goal_garbage, do: [nil, :atom, 42, "goals", %{}, {:t}, self()]

  defp seed, do: {2026, 1_000_000, 300_000}

  defp rng do
    :rand.seed(:exsss, seed())
    fn n -> :rand.uniform(n) end
  end

  defp pick(r, pool), do: Enum.at(pool, r.(length(pool)) - 1)

  defp random_domain(r) do
    transitions =
      for s <- @states, r.(2) == 1, into: %{} do
        actions =
          for a <- @actions, r.(2) == 1, into: %{} do
            outcomes = Enum.uniq(for _ <- 1..r.(3), do: pick(r, @states))
            {a, outcomes}
          end

        actions = if map_size(actions) == 0, do: %{go: [hd(@states)]}, else: actions
        {s, actions}
      end

    transitions = if map_size(transitions) == 0, do: %{a: %{go: [:done]}}, else: transitions
    goals = Enum.filter(@states, fn _s -> r.(2) == 1 end)
    {:ok, domain} = FOND.new(transitions, goals)
    domain
  end

  # -- law 1: new/2 totality + anti-vacuity -------------------------------------------------

  test "new/2 is total over the garbage corpus — typed result, never a raise" do
    for transitions <- transition_garbage(), goals <- goal_garbage() do
      result = FOND.new(transitions, goals)

      typed_refusal? =
        match?({:error, %{reason: _}}, result) and
          case result do
            {:error, %{reason: r}} -> is_atom(r)
            _ -> false
          end

      assert match?({:ok, %FOND{}}, result) or typed_refusal?,
             "new(#{inspect(transitions, limit: 3)}, #{inspect(goals, limit: 3)}) " <>
               "went off-contract: #{inspect(result, limit: 5)}"
    end
  end

  test "empty outcome lists are refused, not admitted as vacuous success" do
    assert {:error, %{reason: :empty_nondeterministic_outcome, state: :a, action: :x}} =
             FOND.new(%{a: %{x: []}}, [])

    assert {:error, %{reason: :invalid_nondeterministic_outcomes, state: :a, action: :x}} =
             FOND.new(%{a: %{x: :not_a_list}}, [])

    assert {:error, %{reason: :invalid_actions, state: :a, actions: :not_a_map}} =
             FOND.new(%{a: :not_a_map}, [])

    assert {:error, %{reason: :invalid_goals, goals: :nope}} = FOND.new(%{}, :nope)

    assert {:error, %{reason: :invalid_transition_relation}} = FOND.new(:not_a_map, [])
  end

  # -- law 2: normalization closure (new/2 admits exactly what check/1 accepts) -------------

  test "every domain new/2 admits satisfies check/1, and actions/outcomes stay total" do
    r = rng()
    garbage_terms = [nil, :atom, 42, "s", {:t}, %{}]

    for _ <- 1..50 do
      domain = random_domain(r)
      assert FOND.check(domain) == :ok

      for term <- garbage_terms do
        assert is_list(FOND.actions(domain, term))
        assert FOND.outcomes(domain, term, term) == []
      end
    end
  end

  test "check/1 refuses hand-built structs that bypass new/2 with exact details" do
    assert {:error, %{reason: :invalid_domain, detail: :not_a_fond_domain}} = FOND.check(:garbage)

    assert {:error, %{reason: :invalid_domain, detail: :not_a_fond_domain}} =
             FOND.check(%FOND{states: %{}, goals: MapSet.new(), transitions: %{}})

    # goals not normalized to a MapSet
    assert {:error, %{reason: :invalid_domain, detail: :not_a_fond_domain}} =
             FOND.check(%FOND{states: MapSet.new([:a]), goals: [], transitions: %{}})

    # duplicate outcomes survive: the relation is not in new/2's normalized form
    dup = %FOND{
      states: MapSet.new([:a, :done]),
      goals: MapSet.new([:done]),
      transitions: %{a: %{go: [:done, :done]}, done: %{}}
    }

    assert {:error, %{reason: :invalid_domain, detail: :unnormalized_transitions}} =
             FOND.check(dup)

    # an outcome state is missing from the declared state set
    undeclared = %FOND{
      states: MapSet.new([:a]),
      goals: MapSet.new([]),
      transitions: %{a: %{go: [:done]}}
    }

    assert {:error, %{reason: :invalid_domain, detail: :undeclared_states, states: [:done]}} =
             FOND.check(undeclared)

    # a well-formed hand-built domain passes: check is exactly new/2's shape guard
    good = %FOND{
      states: MapSet.new([:a, :done]),
      goals: MapSet.new([:done]),
      transitions: %{a: %{go: [:done]}, done: %{}}
    }

    assert :ok = FOND.check(good)
  end

  # -- law 3: validate_policy/4 totality + typed defect reasons ------------------------------

  test "validate_policy/4 is total over a valid domain x garbage policies/initials/modes" do
    r = rng()
    domain = random_domain(r)
    real_states = MapSet.to_list(domain.states)

    policies = [nil, :atom, 42, "p", [], {:t}, MapSet.new([:x]), %{nope: :go}, %{missing: :go}]
    initials = [nil, :atom, 42, "i", {:t} | real_states]
    modes = [:strong, :strong_cyclic, :bogus, nil, 42, "strong"]

    for policy <- policies, initial <- initials, mode <- modes do
      result = FOND.validate_policy(domain, policy, initial, mode)

      assert match?({:ok, %{semantics: _}}, result) or
               match?({:error, %{reason: reason}} when is_atom(reason), result),
             "validate_policy(#{inspect(policy, limit: 2)}, #{inspect(initial)}, " <>
               "#{inspect(mode)}) went off-contract: #{inspect(result, limit: 5)}"
    end
  end

  test "validate_policy/4 over garbage domains is a typed refusal, never a raise" do
    domains = [
      nil,
      :atom,
      42,
      "d",
      [],
      {:t},
      %{},
      %FOND{states: %{}, goals: MapSet.new(), transitions: %{}},
      %{states: [], goals: [], transitions: %{}}
    ]

    for domain <- domains do
      result = FOND.validate_policy(domain, %{a: :go}, :a, :strong_cyclic)

      assert match?({:error, %{reason: _}}, result) and
               (case result do
                  {:error, %{reason: r}} -> is_atom(r)
                  _ -> false
                end),
             "validate_policy(#{inspect(domain, limit: 3)}, ...) went off-contract: " <>
               inspect(result, limit: 5)
    end
  end

  test "policy defects carry their exact typed reasons" do
    {:ok, domain} = FOND.new(%{pending: %{attempt: [:done]}, done: %{}}, [:done])

    assert {:error, %{reason: :missing_policy_action, state: :pending}} =
             FOND.validate_policy(domain, %{}, :pending, :strong)

    assert {:error, %{reason: :unavailable_policy_action, state: :pending, action: :bogus}} =
             FOND.validate_policy(domain, %{pending: :bogus}, :pending, :strong)

    assert {:error, %{reason: :unknown_policy_states, states: [:nope]}} =
             FOND.validate_policy(domain, %{nope: :attempt}, :pending, :strong)

    assert {:error, %{reason: :unknown_initial_state, state: :nope}} =
             FOND.validate_policy(domain, %{pending: :attempt}, :nope, :strong)

    assert {:error, %{reason: :invalid_policy_request}} =
             FOND.validate_policy(domain, %{pending: :attempt}, :pending, :bogus)

    assert {:error, %{reason: :invalid_policy_request}} =
             FOND.validate_policy(:garbage, %{pending: :attempt}, :pending, :strong)
  end

  # -- law 4: mode lattice on the canonical retry cycle ---------------------------------------

  test "retry cycle is :not_strong yet :strong_cyclic-valid under the same policy" do
    {:ok, cycle} = FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])
    policy = %{pending: :attempt}

    assert {:error, %{reason: :not_strong}} =
             FOND.validate_policy(cycle, policy, :pending, :strong)

    assert {:ok, report} = FOND.validate_policy(cycle, policy, :pending, :strong_cyclic)
    assert report.semantics == :strong_cyclic
    assert report.reachable_states == [:done, :pending]
    assert report.reachable_count == 2
    assert report.ignored_policy_states == []
  end

  test "a strong-valid policy is also strong_cyclic-valid" do
    {:ok, straight} = FOND.new(%{pending: %{attempt: [:done]}, done: %{}}, [:done])
    policy = %{pending: :attempt}

    assert {:ok, _} = FOND.validate_policy(straight, policy, :pending, :strong)
    assert {:ok, _} = FOND.validate_policy(straight, policy, :pending, :strong_cyclic)
  end

  # -- determinism ----------------------------------------------------------------------------

  test "seed reproducibility: same seed twice gives identical domain/check stream" do
    run = fn ->
      r = rng()

      for _ <- 1..50 do
        domain = random_domain(r)
        FOND.check(domain)
      end
    end

    assert run.() == run.()
  end
end
