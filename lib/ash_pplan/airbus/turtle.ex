defmodule AshPPlan.Airbus.Turtle do
  @moduledoc """
  Minimal Turtle (RDF 1.1) ingest for the Airbus parity pipeline.

  The Airbus-side transpiler (`scripts/airbus_to_pplan.py`, lane A1) emits
  `ap:` / `p-plan:` Turtle; this module parses it into a native
  `AshPPlan.FOND` domain so corpus parity runs against the real transpiled
  graph, never a hand-copied topology.

  Supported subset: `@prefix` directives, IRIs, prefixed names, `a`, string
  literals with escapes plus optional `@lang` / `^^datatype`, numeric and
  boolean literals, `,` `;` `.` grouping, and `#` comments. Blank-node
  property lists `[]` and collections `( ... )` are refused with a typed
  error. Predicates are matched by IRI local name, so any prefix binding of
  the `ap:` vocabulary is admitted.

  Render only: no authority is granted (ceiling `:construct`).
  """

  alias AshPPlan.FOND

  @type term_t ::
          {:iri, String.t()} | {:literal, String.t(), String.t() | nil, String.t() | nil}

  @type t :: %{prefixes: %{String.t() => String.t()}, triples: [{term_t(), term_t(), term_t()}]}

  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  @modes ~w(strong strong_cyclic)

  @state_action_locals ~w(hasAction action transition)
  @action_outcome_locals ~w(hasOutcome outcome successor has_successor)
  @goal_subject_locals ~w(goal isGoal goalState)
  @goal_object_locals ~w(goal goals goalState hasGoal hasGoalState goalStates)
  @initial_subject_locals ~w(initial isInitial initialState)
  @initial_object_locals ~w(initial initialState hasInitialState initialStates)

  @spec parse(String.t()) :: {:ok, t()} | {:error, map()}
  def parse(text) when is_binary(text) do
    with {:ok, tokens} <- tokenize(String.to_charlist(text)) do
      parse_statements(tokens, %{}, [])
    end
  end

  @doc """
  Builds a native `AshPPlan.FOND` domain from the parsed graph.

  Vocabulary (matched by IRI local name, aliases admitted):

    * state -> action: `ap:hasAction` / `ap:action` / `ap:transition`
    * action -> outcome states: `ap:hasOutcome` / `ap:outcome` / `ap:successor`
    * goal: `<state> ap:goal "true"` or `<x> ap:goal(s)/hasGoal(State) <state>`
    * initial: `<state> ap:initial "true"` or `<x> ap:initialState <state>`
    * mode: `<x> ap:mode "strong" | "strong_cyclic"` (default `:strong_cyclic`)

  States and actions are reduced to their IRI local names so the ingested
  domain speaks the same identifier vocabulary as the oracle daemon.
  """
  @spec to_fond_domain(t(), keyword()) ::
          {:ok, %{domain: FOND.t(), initial: String.t(), mode: :strong | :strong_cyclic}}
          | {:error, map()}
  def to_fond_domain(graph, opts \\ [])

  def to_fond_domain(%{triples: triples} = _graph, _opts) do
    init_acc = %{edges: %{}, outcomes: %{}, goals: MapSet.new(), initial: [], mode: nil}

    acc =
      Enum.reduce(triples, init_acc, fn {s, p, o}, acc ->
        pl = local_name(p)

        cond do
          pl in @state_action_locals ->
            update_in(acc, [Access.key!(:edges), Access.key!(name(s))], fn
              nil -> %{name(o) => []}
              m -> Map.put_new(m, name(o), [])
            end)

          pl in @action_outcome_locals ->
            update_in(acc, [Access.key!(:outcomes), Access.key!(name(s))], fn
              nil -> [name(o)]
              l -> [name(o) | l]
            end)

          pl in @goal_subject_locals and literal_true?(o) ->
            %{acc | goals: MapSet.put(acc.goals, name(s))}

          pl in @goal_object_locals and match?({:iri, _}, o) ->
            %{acc | goals: MapSet.put(acc.goals, name(o))}

          pl in @initial_subject_locals and literal_true?(o) ->
            %{acc | initial: [name(s)]}

          pl in @initial_object_locals and match?({:iri, _}, o) ->
            %{acc | initial: [name(o)]}

          pl == "mode" and match?({:literal, _, _, _}, o) ->
            %{acc | mode: elem(o, 1)}

          true ->
            acc
        end
      end)

    with :ok <- validate_transitions(acc),
         {:ok, initial} <- validate_initial(acc),
         {:ok, mode} <- validate_mode(acc.mode) do
      transitions = build_transitions(acc.edges, acc.outcomes)
      states = collect_states(transitions, acc)
      transitions = Map.merge(empty_action_map(states), transitions)

      case FOND.new(transitions, MapSet.to_list(acc.goals)) do
        {:ok, domain} ->
          {:ok, %{domain: domain, initial: initial, mode: mode}}

        {:error, reason} ->
          {:error, %{reason: :fond_domain_refused, stage: :fond_new, detail: reason}}
      end
    end
  end

  def to_fond_domain(other, _opts), do: {:error, %{reason: :not_a_turtle_graph, value: other}}

  # -- ingest helpers ---------------------------------------------------------

  defp literal_true?({:literal, v, _, _}) when v in ~w(true 1), do: true
  defp literal_true?(_), do: false

  defp validate_transitions(%{edges: edges, outcomes: outcomes}) do
    cond do
      edges == %{} ->
        {:error, %{reason: :no_transitions_in_graph}}

      true ->
        missing =
          edges
          |> Enum.flat_map(fn {_state, actions} -> Map.keys(actions) end)
          |> Enum.reject(&Map.has_key?(outcomes, &1))

        if missing == [] do
          :ok
        else
          {:error, %{reason: :action_without_outcomes, actions: Enum.sort(missing)}}
        end
    end
  end

  defp validate_initial(%{initial: [initial]}), do: {:ok, initial}
  defp validate_initial(%{initial: []}), do: {:error, %{reason: :no_initial_state}}

  defp validate_initial(%{initial: list}),
    do: {:error, %{reason: :multiple_initial_states, states: list}}

  defp validate_mode(nil), do: {:ok, :strong_cyclic}
  defp validate_mode(m) when m in @modes, do: {:ok, String.to_atom(m)}
  defp validate_mode(m), do: {:error, %{reason: :invalid_mode, mode: m}}

  defp build_transitions(edges, outcomes) do
    Map.new(edges, fn {state, actions} ->
      {state, Map.new(actions, fn {action, []} -> {action, Map.fetch!(outcomes, action)} end)}
    end)
  end

  defp collect_states(transitions, %{goals: goals, initial: initial}) do
    transition_states =
      transitions
      |> Enum.flat_map(fn {s, actions} ->
        [s | Enum.flat_map(actions, fn {_a, succs} -> succs end)]
      end)
      |> MapSet.new()

    MapSet.union(transition_states, goals)
    |> MapSet.union(MapSet.new(initial))
  end

  defp empty_action_map(states), do: Map.new(states, fn s -> {s, %{}} end)

  defp name({:iri, iri}), do: local_name(iri)

  defp local_name(iri) when is_binary(iri) do
    iri |> String.split(["#", "/"]) |> List.last()
  end

  # -- tokenizer --------------------------------------------------------------

  defp tokenize(cl), do: tok(cl, [], 1)

  defp tok([], acc, _line), do: {:ok, Enum.reverse(acc)}

  defp tok([c | rest], acc, line) when c in [?\s, ?\t, ?\r, ?\n],
    do: tok(rest, acc, if(c == ?\n, do: line + 1, else: line))

  defp tok([?# | rest], acc, line), do: tok(skip_comment(rest), acc, line)

  defp tok([?< | rest], acc, line), do: collect_iri(rest, [], acc, line)

  defp tok([?\" | rest], acc, line), do: collect_string(rest, [], acc, line, line)

  defp tok([?@ | rest], acc, line), do: collect_at_word(rest, [], acc, line)

  defp tok([?^, ?^ | rest], acc, line), do: tok(rest, [{:dtype, line} | acc], line)

  defp tok([c | rest], acc, line) when c in ?0..?9 or c == ?-,
    do: collect_number(rest, [c], acc, line)

  defp tok([c | rest], acc, line) when c in ?a..?z or c in ?A..?Z or c == ?_,
    do: collect_pn(rest, [c], acc, line)

  defp tok([?\; | rest], acc, line), do: tok(rest, [{:semi, line} | acc], line)
  defp tok([?, | rest], acc, line), do: tok(rest, [{:comma, line} | acc], line)
  defp tok([?\. | rest], acc, line), do: tok(rest, [{:dot, line} | acc], line)
  defp tok([?[ | rest], acc, line), do: tok(rest, [{:lbracket, line} | acc], line)
  defp tok([?] | rest], acc, line), do: tok(rest, [{:rbracket, line} | acc], line)

  defp tok([c | _rest], _acc, line) when c == ?(,
    do: {:error, %{reason: :unsupported_turtle_feature, feature: :collection, line: line}}

  defp tok([c | _rest], _acc, line),
    do: {:error, %{reason: :unexpected_character, char: <<c>>, line: line}}

  defp skip_comment([?\n | rest]), do: rest
  defp skip_comment([]), do: []
  defp skip_comment([_ | rest]), do: skip_comment(rest)

  defp collect_iri([?> | rest], chars, acc, line) do
    iri = chars |> Enum.reverse() |> List.to_string()
    tok(rest, [{:iri, iri, line} | acc], line)
  end

  defp collect_iri([], _, _, line), do: {:error, %{reason: :unterminated_iri, line: line}}

  defp collect_iri([c | rest], chars, acc, line), do: collect_iri(rest, [c | chars], acc, line)

  defp collect_at_word(rest, chars, acc, line) do
    {word, rest2} = collect_word(rest, chars)
    tok(rest2, [{:at, List.to_string(Enum.reverse(word))} | acc], line)
  end

  defp collect_word([c | rest], chars) when c in ?a..?z or c in ?A..?Z,
    do: collect_word(rest, [c | chars])

  defp collect_word(rest, chars), do: {chars, rest}

  defp collect_string([?\\, esc | rest], chars, acc, line, line0)
       when esc in [?", ?\\, ?n, ?r, ?t] do
    collect_string(rest, [escape_char(esc) | chars], acc, line, line0)
  end

  defp collect_string([?\" | rest], chars, acc, line, line0) do
    s = chars |> Enum.reverse() |> List.to_string()
    tok(rest, [{:string, s, line0} | acc], line)
  end

  defp collect_string([], _, _, line, _line0),
    do: {:error, %{reason: :unterminated_string, line: line}}

  defp collect_string([c | rest], chars, acc, line, line0),
    do: collect_string(rest, [c | chars], acc, line, line0)

  defp escape_char(?n), do: ?\n
  defp escape_char(?r), do: ?\r
  defp escape_char(?t), do: ?\t
  defp escape_char(other), do: other

  defp collect_number([c | rest], chars, acc, line)
       when c in ?0..?9 or c in [?., ?-, ?+, ?e, ?E],
       do: collect_number(rest, [c | chars], acc, line)

  defp collect_number(rest, chars, acc, line) do
    s = chars |> Enum.reverse() |> List.to_string()
    tok(rest, [{:number, s, line} | acc], line)
  end

  defp collect_pn(rest, first, acc, line) do
    {word_chars, rest1} = collect_name_chars(rest, [first])
    word = List.to_string(Enum.reverse(word_chars))

    case rest1 do
      [?: | rest2] ->
        {local_chars, rest3} = collect_name_chars(rest2, [])
        local = List.to_string(Enum.reverse(local_chars))
        tok(rest3, [{:pname, word, local, line} | acc], line)

      _ ->
        cond do
          word in ~w(true false) -> tok(rest1, [{:bool, word, line} | acc], line)
          word == "a" -> tok(rest1, [{:a, line} | acc], line)
          true -> {:error, %{reason: :unexpected_word, word: word, line: line}}
        end
    end
  end

  # A dot is admitted inside a name only when followed by another name char,
  # so statement-terminating dots are never consumed (Turtle local names may
  # not end with a dot).

  defguardp is_name_char(c)
            when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?-]

  defp collect_name_chars([c | rest], chars) when is_name_char(c),
    do: collect_name_chars(rest, [c | chars])

  defp collect_name_chars([?. | [c2 | _] = rest2], chars) when is_name_char(c2),
    do: collect_name_chars(rest2, [?. | chars])

  defp collect_name_chars([?.], chars), do: {chars, [?.]}
  defp collect_name_chars(rest, chars), do: {chars, rest}

  # -- statement parser -------------------------------------------------------

  defp parse_statements([], prefixes, triples),
    do: {:ok, %{prefixes: prefixes, triples: Enum.reverse(triples)}}

  defp parse_statements(
         [{:at, "prefix"}, {:pname, pfx, "", _}, {:iri, iri, _} | rest],
         prefixes,
         triples
       ) do
    parse_statements(maybe_dot(rest), Map.put(prefixes, pfx, iri), triples)
  end

  defp parse_statements([{:at, "base"}, {:iri, iri, _} | rest], prefixes, triples) do
    parse_statements(maybe_dot(rest), Map.put(prefixes, "/", iri), triples)
  end

  defp parse_statements([tok | rest], prefixes, triples)
       when elem(tok, 0) in [:iri, :pname] do
    with {:iri, _} = subject <- resolve_term(tok, prefixes),
         {:ok, rest2, acc} <- predicate_object_list(rest, subject, prefixes, []) do
      case rest2 do
        [{:dot, _} | rest3] -> parse_statements(rest3, prefixes, Enum.reverse(acc, triples))
        _ -> {:error, %{reason: :missing_statement_dot}}
      end
    end
  end

  defp parse_statements([tok | _], _prefixes, _triples) do
    {:error, %{reason: :unexpected_statement_start, token: elem(tok, 0)}}
  end

  defp maybe_dot([{:dot, _} | rest]), do: rest
  defp maybe_dot(rest), do: rest

  defp resolve_term({:iri, s, _}, _prefixes), do: {:iri, s}

  defp resolve_term({:pname, pfx, local, _}, prefixes) do
    case Map.fetch(prefixes, pfx) do
      {:ok, base} -> {:iri, base <> local}
      :error -> {:error, %{reason: :unbound_prefix, prefix: pfx}}
    end
  end

  defp predicate_object_list(tokens, subject, prefixes, acc)
       when elem(hd(tokens), 0) in [:a, :iri, :pname] do
    [verb_tok | rest] = tokens

    p =
      case verb_tok do
        {:a, _} -> {:iri, @rdf_type}
        _ -> resolve_term(verb_tok, prefixes)
      end

    object_list(rest, subject, p, prefixes, acc)
  end

  defp predicate_object_list([tok | _], _subject, _prefixes, _acc) do
    {:error, %{reason: :unexpected_verb, token: elem(tok, 0)}}
  end

  defp object_list(tokens, subject, p, prefixes, acc) do
    case object_term(tokens, prefixes) do
      {:ok, term, rest} ->
        acc2 = [{subject, p, term} | acc]

        case rest do
          [{:comma, _} | rest2] -> object_list(rest2, subject, p, prefixes, acc2)
          [{:semi, _} | rest2] -> after_semi(rest2, subject, prefixes, acc2)
          _ -> {:ok, rest, acc2}
        end

      {:error, _} = err ->
        err
    end
  end

  defp after_semi(tokens, subject, prefixes, acc) do
    case tokens do
      [{:dot, _} | _] ->
        {:ok, tokens, acc}

      [tok | _] when elem(tok, 0) in [:a, :iri, :pname] ->
        predicate_object_list(tokens, subject, prefixes, acc)

      _ ->
        {:error, %{reason: :unexpected_after_semicolon}}
    end
  end

  defp object_term([{:iri, s, _} | rest], _prefixes), do: {:ok, {:iri, s}, rest}

  defp object_term([{:pname, _, _, _} = tok | rest], prefixes) do
    case resolve_term(tok, prefixes) do
      {:iri, _} = term -> {:ok, term, rest}
      {:error, _} = err -> err
    end
  end

  defp object_term([{:string, s, _} | rest], prefixes) do
    case literal_extras(rest, prefixes) do
      {{d, lang}, rest2} -> {:ok, {:literal, s, d, lang}, rest2}
      {:error, _} = err -> err
    end
  end

  defp object_term([{:number, s, _} | rest], _prefixes),
    do: {:ok, {:literal, s, "http://www.w3.org/2001/XMLSchema#decimal", nil}, rest}

  defp object_term([{:bool, s, _} | rest], _prefixes),
    do: {:ok, {:literal, s, "http://www.w3.org/2001/XMLSchema#boolean", nil}, rest}

  defp object_term([{:lbracket, line} | _], _prefixes),
    do:
      {:error,
       %{reason: :unsupported_turtle_feature, feature: :blank_node_property_list, line: line}}

  defp object_term([tok | _], _prefixes),
    do: {:error, %{reason: :unexpected_object, token: elem(tok, 0)}}

  defp literal_extras([{:dtype, _}, {:iri, d, _} | rest], _prefixes), do: {{d, nil}, rest}

  defp literal_extras([{:dtype, _}, {:pname, _, _, _} = p | rest], prefixes) do
    case resolve_term(p, prefixes) do
      {:iri, d} -> {{d, nil}, rest}
      {:error, _} = err -> err
    end
  end

  defp literal_extras([{:at, lang} | rest], _prefixes) when lang not in ~w(prefix base),
    do: {{nil, lang}, rest}

  defp literal_extras(rest, _prefixes), do: {{nil, nil}, rest}
end
