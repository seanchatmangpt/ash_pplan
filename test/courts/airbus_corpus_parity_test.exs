defmodule AshPPlan.Courts.AirbusCorpusParityTest do
  @moduledoc """
  Corpus-parity court (lane A3): enumerates the Airbus benchmark corpus
  dynamically from `priv/courts/airbus_parity/corpus/` and drives real
  cross-engine parity where a native engine exists, with skip-loud naming for
  every case class the native stack cannot yet ingest.

  Infrastructure decisions follow the `AshPPlan.Test.TLCCourt` pattern:
  compile-time tag decision per infrastructure class, so an absent transpiler
  or daemon skip-louds with a named reason instead of faking a pass.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Test.AirbusOracle, as: Oracle
  alias AshPPlan.Test.AirbusOracle.Client
  alias AshPPlan.Test.AirbusOracle.Provisioner

  describe "corpus census and classification" do
    test "corpus dir exists and is nonempty" do
      assert File.dir?(Oracle.corpus_root()),
             "corpus missing at #{Oracle.corpus_root()}"

      cases = Oracle.corpus_cases()
      assert cases != [], "corpus is empty at #{Oracle.corpus_root()}"
    end

    test "every corpus case is classified into a known kind" do
      cases = Oracle.corpus_cases()

      for case <- cases do
        assert case.kind in [:fond, :stnu, :hddl, :po_pddl],
               "unclassified corpus case: #{inspect(case)}"
      end
    end

    test "corpus contains at least one case per landed kind" do
      kinds = Oracle.corpus_cases() |> Enum.map(& &1.kind) |> Enum.uniq()
      assert :fond in kinds, "no FOND case in corpus"
    end
  end

  describe "FOND transpiler parity" do
    case Oracle.transpiler_available?() do
      true ->
        @describetag :airbus_transpiler

      false ->
        @describetag skip:
                       "SKIP-LOUD: A1 python transpiler scripts/airbus_to_pplan.py not landed — " <>
                         "FOND corpus cases cannot reach a real parity assertion (never fake-pass)"
    end

    test "every FOND corpus case reaches real cross-engine parity" do
      fond_cases = Oracle.fond_cases()
      assert fond_cases != []

      case Provisioner.availability() do
        :ok ->
          :ok

        {:unavailable, reason} ->
          flunk("SKIP-LOUD: oracle daemon unavailable: #{inspect(reason)}")
      end

      results = Enum.map(fond_cases, fn case -> Oracle.assert_parity!(case.name) end)

      assert length(results) == length(fond_cases)

      for result <- results do
        assert Map.has_key?(result, :solvable)
        assert is_boolean(result.solvable)
      end
    end
  end

  describe "oracle corpus checks (daemon-only surfaces)" do
    case Oracle.daemon_bootable?() do
      true ->
        @describetag :airbus_daemon

      false ->
        @describetag skip:
                       "SKIP-LOUD: oracle daemon not bootable (python3 + docker/airbus_oracle/server.py required)"
    end

    setup do
      case Provisioner.availability() do
        :ok ->
          :ok

        {:unavailable, reason} ->
          flunk("SKIP-LOUD: oracle daemon unavailable: #{inspect(reason)}")
      end

      :ok
    end

    test "STNU corpus case reaches a real daemon DC verdict over real transport" do
      stnu =
        Enum.find(Oracle.corpus_cases(), &(&1.kind == :stnu)) ||
          flunk("SKIP-LOUD: no .stnu case in corpus")

      stnu_file = Enum.find(stnu.files, &String.ends_with?(&1, ".stnu"))
      spec = Jason.decode!(File.read!(stnu_file))

      assert {:ok, resp} = Client.call("check_stnu_dc", spec)
      assert is_boolean(resp["dynamically_controllable"])
      assert is_list(resp["conflicts"])
    end

    test "non-FOND corpus cases are classified with typed skip reasons" do
      non_fond = Enum.filter(Oracle.corpus_cases(), &(&1.kind != :fond))
      assert non_fond != []

      for case <- non_fond do
        assert case.kind in [:stnu, :hddl, :po_pddl],
               "non-FOND case #{case.name} has unclassified kind #{inspect(case.kind)}"
      end
    end
  end
end
