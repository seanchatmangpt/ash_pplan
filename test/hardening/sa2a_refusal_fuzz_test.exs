defmodule AshPPlan.Test.Hardening.SA2ARefusalFuzzTest do
  @moduledoc """
  Refusal fuzz court over the SA2A thin waist (lib/ash_pplan/sa2a/).

  Law under test: the SA2A surface never raises on hostile input and always
  returns either `{:ok, candidate}` with `authority: :none, standing:
  :candidate` or `{:error, refusal}` whose `code` is one of the closed
  `AshPPlan.SA2A.Refusal.codes/0`.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.{Capability, Provider, Refusal, Replay, SubjectGuard}

  @codes MapSet.new(Refusal.codes())

  # ---- hostile corpus -------------------------------------------------

  @garbage_atoms [:bogus, :"with spaces", :PoWl, :FOND, :powlx]

  @deep_map Enum.reduce(1..200, %{leaf: :x}, fn _i, acc -> %{nested: acc} end)

  @hostile_terms [
    nil,
    0,
    -1,
    1.5,
    "",
    "x",
    String.duplicate("a", 100_000),
    <<0, 1, 2, 255>>,
    [],
    [1, 2, 3],
    %{},
    %{a: %{b: %{c: %{d: :e}}}},
    @deep_map,
    {:tuple, :with, :atoms},
    # an anonymous fun cannot be escaped into an attribute; a remote fun is the
    # same hostile "callable" class and is escapable
    &String.length/1
  ]

  # make_ref()/self() are runtime-only terms (references and compiler PIDs cannot be
  # escaped into a module attribute), so the hostile corpus is materialized per call.
  defp hostile_terms, do: [self(), make_ref() | @hostile_terms]

  # the guard admits atom/binary identity terms; maps are a separate request
  # shape and binaries are legitimate subjects, so both are excluded
  defp non_subject_terms,
    do:
      Enum.reject(
        hostile_terms(),
        &(is_map(&1) or is_binary(&1) or is_atom(&1))
      )

  defp refute_ok(result, context) do
    case result do
      {:ok, candidate} ->
        assert candidate.authority == :none, "authority must be :none (#{context})"
        assert candidate.standing == :candidate, "standing must be :candidate (#{context})"

      {:error, refusal} ->
        assert is_map(refusal), "refusal must be a map (#{context})"
        assert refusal.authority == :none, "refusal authority must be :none (#{context})"
        assert refusal.code in @codes, "closed code required, got #{inspect(refusal.code)}"

      other ->
        flunk("expected {:ok, _} or {:error, _}, got #{inspect(other)} (#{context})")
    end
  end

  describe "Provider.propose/2" do
    test "unknown formalisms are refused with a closed code" do
      for formalism <- @garbage_atoms do
        result = Provider.propose(%{formalism: formalism}, [])
        refute_ok(result, "formalism #{inspect(formalism)}")

        assert match?({:error, %{code: :unsupported_formalism}}, result),
               "expected unsupported_formalism for #{inspect(formalism)}"
      end
    end

    test "every hostile request term returns, never raises" do
      for term <- hostile_terms() do
        refute_ok(
          Provider.propose(%{formalism: term}, []),
          "request #{inspect(term, limit: :infinity)}"
        )

        refute_ok(Provider.propose(%{subject: term, formalism: :fond}, []), "subject garbage")
      end
    end

    test "deeply nested maps and huge binaries do not raise" do
      refute_ok(
        Provider.propose(
          %{formalism: :fond, subject: :s, domain: @deep_map, initial: @deep_map},
          []
        ),
        "deep maps"
      )

      refute_ok(
        Provider.propose(
          %{
            formalism: :powl,
            subject: :s,
            plan_iri: String.duplicate("iri/", 10_000)
          },
          []
        ),
        "huge plan_iri"
      )
    end

    test "garbage opts never raise" do
      req = %{formalism: :fond, subject: :s, domain: :nope, initial: :nope}

      for opts <- [nil, :garbage, %{}, [1, 2, 3], [{{:x, :y}, :z}], "kw"] do
        refute_ok(Provider.propose(req, opts), "opts #{inspect(opts, limit: :infinity)}")
      end
    end
  end

  describe "Replay.fond/3" do
    test "every hostile request/candidate pair returns, never raises" do
      for term <- hostile_terms() do
        refute_ok(
          Replay.fond(%{subject: :s, domain: :d, initial: :i}, term, []),
          "candidate #{inspect(term, limit: :infinity)}"
        )

        refute_ok(
          Replay.fond(term, %{subject: :s}, []),
          "request #{inspect(term, limit: :infinity)}"
        )
      end
    end

    test "mismatched candidate subject is refused, not a WithClauseError" do
      assert {:error, %{code: code}} =
               Replay.fond(%{subject: :s, domain: :d, initial: :i}, %{subject: :other}, [])

      assert code in @codes
    end

    test "candidate missing policy/mode keys is refused, not KeyError" do
      result =
        Replay.fond(%{subject: :s}, %AshPPlan.FOND{states: %{}, transitions: %{}, goals: []}, [])

      assert match?({:error, _}, result)
    end

    test "non-FOND domain is refused, not FunctionClauseError" do
      result =
        Replay.fond(
          %{subject: :s, domain: %{not: :a_fond}, initial: :i},
          %{subject: :s, policy: :p, mode: :strong},
          []
        )

      assert {:error, %{code: :planner_refused}} = result
    end

    test "garbage opts never raise" do
      for opts <- [nil, :garbage, [1, 2, 3]] do
        result =
          Replay.fond(
            %{subject: :s, domain: :d, initial: :i},
            %{subject: :s, policy: :p, mode: :strong},
            opts
          )

        refute_ok(result, "opts #{inspect(opts, limit: :infinity)}")
      end
    end
  end

  describe "Refusal.new/1" do
    test "closed codes always carry authority: :none" do
      for code <- Refusal.codes() do
        refute = Refusal.new(code)
        assert %{code: ^code, detail: nil, authority: :none} = refute
      end
    end

    test "rejects non-closed codes by guard, never mints an open refusal" do
      # Refusal.new is a constructor with a guard; the closed-set law lives in
      # the guard. Anything else in the surface must map into the closed set.
      for code <- [:nope, "fond", nil, 42] do
        assert_raise FunctionClauseError, fn -> Refusal.new(code) end
      end
    end

    test "hostile details do not escape the closed shape" do
      for term <- hostile_terms() do
        refute = Refusal.new(:planner_refused, term)
        assert %{code: :planner_refused, authority: :none} = refute
      end
    end
  end

  describe "SubjectGuard" do
    test "nil and garbage subjects are refused with :missing_subject" do
      assert {:error, %{code: :missing_subject, authority: :none}} =
               SubjectGuard.fetch(%{subject: nil})

      # the guard's contract: a subject is an atom (non-nil) or binary
      # identity term; every other term is refused, never admitted
      for term <- non_subject_terms() do
        assert {:error, %{code: :missing_subject, authority: :none}} =
                 SubjectGuard.fetch(%{subject: term})
      end
    end

    test "non-map requests are refused" do
      for term <- non_subject_terms() do
        assert {:error, %{code: :missing_subject}} = SubjectGuard.fetch(term)
      end
    end

    test "preserve detects subject drift and never grants authority" do
      assert {:error, %{code: :planner_refused, authority: :none}} =
               SubjectGuard.preserve(:s, %{subject: :drifted})
    end
  end

  describe "Capability" do
    test "unknown formalisms are not supported" do
      for term <- @garbage_atoms ++ Enum.take(hostile_terms(), 8) do
        refute Capability.supports?(term), "#{inspect(term)} must not be supported"
      end
    end

    test "descriptors only exist for supported formalisms and carry no authority" do
      for formalism <- Capability.supported() do
        d = Capability.descriptor(formalism)
        assert d.authority == :none and d.do == false
      end

      assert_raise FunctionClauseError, fn -> Capability.descriptor(:bogus) end
    end
  end

  test "PolicyCandidate.powl never raises on hostile terms" do
    for term <- hostile_terms() do
      refute_ok(
        Provider.propose(%{formalism: :powl, subject: :s, plan_iri: term}, []),
        "plan_iri #{inspect(term, limit: :infinity)}"
      )
    end
  end
end
