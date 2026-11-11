defmodule AshPPlan.Test.AirbusOracle do
  @moduledoc """
  Corpus-parity runbook for the Airbus deliberation stack (lane A3).

  `assert_parity!/2` runs one FOND corpus case end to end: the A1 transpiler
  (`scripts/airbus_to_pplan.py <corpus_file>`) emits `ap:`/`p-plan:` Turtle,
  `AshPPlan.Airbus.Turtle` ingests it into a native `AshPPlan.FOND` domain,
  the BEAM synthesizer and the A2 oracle daemon solve it independently, and
  the verdicts are asserted equal (solvable?, winning-region set equality,
  per-state policy map).

  Missing infrastructure raises with a named reason — a skip is decided by the
  court (skip-loud with reason), never by a silent fake pass.
  """

  alias AshPPlan.Airbus.{Turtle, Transpiler}
  alias AshPPlan.FOND.Synthesis
  alias AshPPlan.Test.AirbusOracle.{Assertions, Client}

  import ExUnit.Assertions, only: [assert: 2]

  @doc "Corpus root (env-overridable via AIRBUS_PARITY_CORPUS_ROOT)."
  def corpus_root do
    System.get_env("AIRBUS_PARITY_CORPUS_ROOT") ||
      Path.join(app_root(), "priv/courts/airbus_parity/corpus")
  end

  @doc """
  Enumerates the corpus dynamically (no hardcoded filenames), grouping files
  by basename stem and classifying each case by kind.
  """
  def corpus_cases do
    case File.ls(corpus_root()) do
      {:ok, files} -> Enum.map(group_by_stem(files), &new_case/1)
      {:error, _} -> []
    end
  end

  defp group_by_stem(files) do
    Enum.group_by(files, fn name ->
      name |> String.split(".") |> List.first()
    end)
  end

  defp new_case({stem, names}) do
    case_files = names |> Enum.sort() |> Enum.map(&Path.join(corpus_root(), &1))

    %{name: stem, kind: classify(case_files), files: case_files}
  end

  defp classify(case_files) do
    if Enum.any?(case_files, &String.contains?(Path.basename(&1), ".fond.")),
      do: :fond,
      else: classify_other(case_files)
  end

  defp classify_other(case_files) do
    basename = case_files |> List.first() |> Path.basename()

    cond do
      String.ends_with?(basename, ".stnu") -> :stnu
      String.ends_with?(basename, ".hddl") -> :hddl
      String.contains?(basename, ".po.pddl") -> :po_pddl
      true -> :unknown
    end
  end

  @doc "FOND corpus cases (the kind `assert_parity!/2` runs)."
  def fond_cases do
    corpus_cases() |> Enum.filter(&(&1.kind == :fond))
  end

  @doc "Path of the A1 python transpiler."
  def transpiler_script, do: Path.join(app_root(), "scripts/airbus_to_pplan.py")

  @doc "True when the A1 transpiler script has landed."
  def transpiler_available?, do: File.regular?(transpiler_script())

  @doc "True when the oracle daemon could be booted locally (python3 + server.py)."
  def daemon_bootable? do
    System.find_executable("python3") != nil and
      File.regular?(Path.join(app_root(), "docker/airbus_oracle/server.py"))
  end

  @doc """
  Transpiles one FOND corpus case to Turtle and ingests it natively.

  Returns `{:ok, %{domain:, initial:, mode:, turtle:}}`; raises with a named
  reason when the transpiler has not landed, exits non-zero, or the Turtle
  fails to ingest.
  """
  def transpile_case!(case_name) when is_binary(case_name) do
    fond_file = case_fond_file!(case_name)

    unless transpiler_available?() do
      raise "AIRBUS PARITY SKIP: A1 python transpiler absent at #{transpiler_script()} — " <>
              "case #{case_name} cannot reach a real parity assertion"
    end

    {turtle, exit_code} =
      System.cmd("python3", [transpiler_script(), fond_file], stderr_to_stdout: true)

    if exit_code != 0 do
      raise "AIRBUS PARITY ERROR: transpiler failed for #{case_name} (exit #{exit_code}): " <>
              String.slice(turtle, 0, 400)
    end

    with {:ok, graph} <- Turtle.parse(turtle),
         {:ok, ingested} <- Turtle.to_fond_domain(graph) do
      {:ok, Map.put(ingested, :turtle, turtle)}
    else
      {:error, reason} ->
        raise "AIRBUS PARITY ERROR: Turtle ingest failed for #{case_name}: #{inspect(reason)}"
    end
  end

  defp case_fond_file!(case_name) do
    case =
      case Enum.find(corpus_cases(), &(&1.name == case_name)) do
        nil -> raise "AIRBUS PARITY ERROR: corpus case #{case_name} not found in #{corpus_root()}"
        c -> c
      end

    case Enum.find(case.files, &String.contains?(Path.basename(&1), ".fond.")) do
      nil -> raise "AIRBUS PARITY ERROR: corpus case #{case_name} has no .fond. file"
      path -> path
    end
  end

  @doc """
  Runs one FOND corpus case to a real cross-engine parity assertion.

  Raises on any divergence: solvable? mismatch, winning-region set
  difference, or per-state policy divergence. Returns a receipt map.
  """
  def assert_parity!(case_name, opts \\ []) when is_binary(case_name) do
    {:ok, ingested} = transpile_case!(case_name)
    domain = ingested.domain
    initial = ingested.initial
    mode = ingested.mode

    native =
      case Synthesis.synthesize(domain, initial, mode) do
        {:ok, policy} ->
          {:solvable, policy}

        {:error, {:unsolvable, ^mode, witness}} ->
          {:unsolvable, witness}

        other ->
          raise "AIRBUS PARITY ERROR: unexpected native synthesis result: #{inspect(other)}"
      end

    {:ok, native_solvable_set} = Synthesis.solvable_states(domain, mode)

    oracle_params = Transpiler.to_oracle_fond(domain, initial, mode)
    {:ok, oracle} = Client.call("solve_fond", oracle_params, opts)

    native_solvable? = native |> elem(0) == :solvable
    oracle_solvable? = oracle["solvable"] == true

    assert native_solvable? == oracle_solvable?,
           "SOLVABILITY DIVERGENCE for #{case_name}: native=#{native_solvable?} " <>
             "oracle=#{oracle_solvable?}"

    Assertions.assert_winning_region_parity(
      MapSet.new(oracle["winning_region"] || []),
      native_solvable_set
    )

    detail =
      case native do
        {:solvable, policy} ->
          Assertions.assert_policy_parity(oracle["policy"], policy, domain)
          %{policy_states: map_size(policy)}

        {:unsolvable, witness} ->
          Assertions.assert_witness_parity(List.wrap(oracle["witness"] || []), List.wrap(witness))
          %{witness_states: length(List.wrap(witness))}
      end

    Map.merge(
      %{
        case: case_name,
        solvable: native_solvable?,
        winning_region: MapSet.size(native_solvable_set),
        mode: mode
      },
      detail
    )
  end

  defp app_root, do: Path.expand("../..", __DIR__)
end
