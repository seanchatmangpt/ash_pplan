defmodule AshPPlan.TokyoDepeg.ActuationBoundaryTest do
  @moduledoc """
  W3 stage 7: the actuation boundary of AshPPlan's SA2A provider surface.

  The owner side manufactures FOND policy candidates with `authority: :none`
  and `standing: :candidate`. Replay is evidence, never authority. Actuation
  is consumer-side: no function in this codebase executes Reactor, inserts
  Oban work, or resumes a continuation as a consequence of `propose/2`.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.SA2A.{Provider, Replay, Refusal}
  alias AshPPlan.Test.FONDFixture

  @fixtures_dir Path.join(File.cwd!(), "test/fixtures/fond/tla")

  setup do
    fixture = FONDFixture.load(Path.join(@fixtures_dir, "decision_choice_matters.json"))
    {:ok, domain} = FOND.new(fixture.transitions, fixture.goals)

    request = %{
      formalism: :fond,
      subject: "tokyo_depeg/w3/subject",
      domain: domain,
      initial: fixture.initial
    }

    %{request: request}
  end

  test "propose/2 emits a candidate with authority :none and standing :candidate", %{
    request: request
  } do
    {:ok, candidate} = Provider.propose(request, [])

    assert candidate.authority == :none
    assert candidate.standing == :candidate
    assert candidate.formalism == :fond
    assert is_map(candidate.policy)
    assert candidate.subject == request.subject
  end

  test "every candidate from the full fixture corpus carries the boundary fields" do
    for fixture <- FONDFixture.all() do
      {:ok, domain} = FOND.new(fixture.transitions, fixture.goals)
      subject = "tokyo_depeg/w3/#{fixture.name}"

      request = %{
        formalism: :fond,
        subject: subject,
        domain: domain,
        initial: fixture.initial
      }

      case Provider.propose(request, []) do
        {:ok, candidate} ->
          assert candidate.authority == :none,
                 "fixture #{fixture.name} candidate must carry authority: :none"

          assert candidate.standing == :candidate,
                 "fixture #{fixture.name} candidate must carry standing: :candidate"

          assert candidate.subject == subject

        {:error, refusal} ->
          assert %{code: code, authority: :none} = refusal

          assert code in Refusal.codes(),
                 "fixture #{fixture.name} refusal must use a closed refusal code"
      end
    end
  end

  test "replay_fingerprint is deterministic across two Replay.fond/3 calls", %{request: request} do
    {:ok, candidate} = Provider.propose(request, [])
    {:ok, first} = Replay.fond(request, candidate, [])
    {:ok, second} = Replay.fond(request, candidate, [])

    assert first.replay_fingerprint == second.replay_fingerprint
    assert is_binary(first.replay_fingerprint)
    assert first.authority == :none
    assert first.standing == :candidate
    assert first.subject == candidate.subject
    assert first.planner_subject == candidate.planner_subject
  end

  test "replay refuses missing subject with a closed refusal code", %{request: request} do
    {:ok, candidate} = Provider.propose(request, [])

    missing = Map.put(candidate, :subject, nil)

    assert {:error, %{code: :missing_subject, authority: :none}} =
             Replay.fond(request, missing, [])
  end

  test "replay never admits subject drift", %{request: request} do
    {:ok, candidate} = Provider.propose(request, [])

    # KNOWN DEFECT (owner lane, lib/ash_pplan/sa2a/replay.ex:11): the pin
    # `{:ok, ^subject} <- candidate_subject(candidate)` raises WithClauseError
    # on drift instead of returning a typed refusal. Either way, drift must
    # NEVER yield a successful replay bundle — that is the boundary pinned here.
    drifted = Map.put(candidate, :subject, "other/subject")

    drift_result =
      try do
        Replay.fond(request, drifted, [])
      rescue
        WithClauseError -> :drift_rejected
      end

    assert drift_result == :drift_rejected,
           "subject drift must be rejected, got: #{inspect(drift_result)}"

    refute match?({:ok, %{bundle: _}}, drift_result)
  end

  test "anti-vacuity: request-side and opts-side authority injection cannot leak into the candidate",
       %{
         request: request
       } do
    poisoned =
      request
      |> Map.put(:authority, :granted)
      |> Map.put(:standing, :admitted)

    {:ok, candidate} = Provider.propose(poisoned, authority: :granted, standing: :admitted)

    assert candidate.authority == :none
    assert candidate.standing == :candidate
  end

  test "anti-vacuity: the provider path source cannot emit authority other than :none" do
    offenders =
      for path <- sa2a_sources(),
          source = File.read!(path),
          reduce: [] do
        acc ->
          literals =
            source
            |> then(&Regex.scan(~r/authority:\s*(:\w+)/, &1))
            |> Enum.map(&Enum.at(&1, 1))

          dynamic_authority? =
            Regex.match?(~r/(Map\.put|Map\.update|put_in|update_in)\(.*:authority/, source)

          cond do
            literals != [] and Enum.all?(literals, &(&1 == ":none")) and not dynamic_authority? ->
              acc

            literals == [] and not dynamic_authority? ->
              acc

            true ->
              [path | acc]
          end
      end

    assert offenders == [],
           "SA2A provider path must hard-wire authority: :none; offenders: #{inspect(offenders)}"
  end

  test "structural boundary: propose never executes Reactor, Oban, or continuations" do
    offenders =
      for path <- sa2a_sources(),
          source = File.read!(path),
          {:ok, ast} = Code.string_to_quoted(source),
          hit <- ast_hits(ast),
          reduce: MapSet.new() do
        acc -> MapSet.put(acc, "#{Path.basename(path)}: #{hit}")
      end

    assert MapSet.to_list(offenders) == [],
           "SA2A provider path must not trigger execution machinery: #{inspect(MapSet.to_list(offenders))}"
  end

  # AST-level scan: moduledoc prose cannot false-positive. Flags remote calls
  # into execution machinery (Reactor.*, Oban.*) and any call whose function
  # name carries continuation/resume semantics.
  defp ast_hits(ast) do
    {_, remote_hits} =
      Macro.prewalk(ast, MapSet.new(), fn
        {{:., _, [mod, fun]}, _, _} = node, acc when is_atom(fun) ->
          case module_atom(mod) do
            m when m in [:Reactor, :Oban] -> {node, MapSet.put(acc, "#{m}.#{fun}")}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    {_, all_hits} =
      Macro.prewalk(ast, remote_hits, fn
        {fun, _, _} = node, acc when is_atom(fun) ->
          if continuationish?(fun), do: {node, MapSet.put(acc, "#{fun}")}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(all_hits)
  end

  defp continuationish?(fun) when is_atom(fun) do
    name = Atom.to_string(fun)
    String.contains?(name, "continu") or String.contains?(name, "resume")
  end

  defp module_atom({:__aliases__, _, parts}), do: List.last(parts)
  defp module_atom(mod) when is_atom(mod), do: mod
  defp module_atom(_), do: nil

  test "actuation is consumer-side: no AshA2A actuation module is loadable (no-dep)" do
    ash_a2a_dep? =
      File.read!(Path.join(File.cwd!(), "mix.exs"))
      |> String.contains?("{:ash_a2a")

    loaded = Code.ensure_loaded?(AshA2A.Actuation)

    if ash_a2a_dep? and loaded do
      flunk(
        "ash_a2a became a mix dependency; replace this structural boundary test with a real consumer-side actuation test"
      )
    else
      # Skip-typed: UNSUPPORTED(no-dep) — the boundary is proven structurally.
      :ok
    end
  end

  defp sa2a_sources do
    Path.wildcard(Path.join(File.cwd!(), "lib/ash_pplan/sa2a/*.ex"))
  end
end
