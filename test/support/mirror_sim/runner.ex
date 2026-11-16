defmodule AshPPlan.MirrorSim.Runner do
  @moduledoc """
  Integration runner for the mirror simulation.

  Each court file under `test/mirror_sim/` runs as a real `mix test` OS subprocess
  (the server is booted inside each court by `AshPPlan.MirrorSim.Server`). Files are
  classified into phases by name: `mutants_*` (mutation catalog), `parity*`
  (parity differential), `coverage*` (coverage), everything else (area courts).
  The runner records exit codes, test counts, killed/survived counts and MISSING
  cells, then renders `receipts/mirror-sim-<sha>.md` with a `Standing:` line after
  the H1.

  Pure parts (`classify/1`, `parse_tests/1`, `parse_mutants/1`, `parse_missing/1`,
  `standing/1`, `render/1`) are doctested.
  """

  @type phase :: :area | :parity | :mutants | :coverage
  @type step :: %{
          file: String.t(),
          phase: phase(),
          cmd: String.t(),
          exit: integer(),
          tests: non_neg_integer(),
          failures: non_neg_integer(),
          killed: non_neg_integer(),
          survived: non_neg_integer(),
          missing: [String.t()]
        }

  @standings ~w(ALIVE PARTIAL_ALIVE PASS BLOCKED UNVERIFIED PARTIAL)

  @doc "Closed standing vocabulary."
  @spec standings() :: [String.t()]
  def standings, do: @standings

  @doc """
  Classify a court file path into a phase.

      iex> AshPPlan.MirrorSim.Runner.classify("test/mirror_sim/mutants_core_test.exs")
      :mutants
      iex> AshPPlan.MirrorSim.Runner.classify("test/mirror_sim/parity_test.exs")
      :parity
      iex> AshPPlan.MirrorSim.Runner.classify("test/mirror_sim/coverage_test.exs")
      :coverage
      iex> AshPPlan.MirrorSim.Runner.classify("test/mirror_sim/powl_test.exs")
      :area
  """
  @spec classify(String.t()) :: phase()
  def classify(path) do
    base = Path.basename(path)

    cond do
      String.starts_with?(base, "mutants") -> :mutants
      String.starts_with?(base, "parity") -> :parity
      String.starts_with?(base, "coverage") -> :coverage
      true -> :area
    end
  end

  @doc """
  Parse ExUnit summary output.

      iex> AshPPlan.MirrorSim.Runner.parse_tests("3 doctests, 12 tests, 2 failures")
      {12, 2}
      iex> AshPPlan.MirrorSim.Runner.parse_tests("nothing")
      {0, 0}
  """
  @spec parse_tests(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def parse_tests(out) do
    case Regex.run(~r/(\d+) tests?, (\d+) failures?/, out) do
      [_, t, f] -> {String.to_integer(t), String.to_integer(f)}
      _ -> {0, 0}
    end
  end

  @doc """
  Parse mutation counts from lines like `MUTANTS killed=5 survived=0`
  (summed over all matching lines).

      iex> AshPPlan.MirrorSim.Runner.parse_mutants("MUTANTS killed=5 survived=1\\nMUTANTS killed=2 survived=0")
      {7, 1}
      iex> AshPPlan.MirrorSim.Runner.parse_mutants("none")
      {0, 0}
  """
  @spec parse_mutants(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def parse_mutants(out) do
    ~r/killed=(\d+)\s+survived=(\d+)/
    |> Regex.scan(out)
    |> Enum.reduce({0, 0}, fn [_, k, s], {ak, as} ->
      {ak + String.to_integer(k), as + String.to_integer(s)}
    end)
  end

  @doc """
  Parse `MISSING <cell>` lines.

      iex> AshPPlan.MirrorSim.Runner.parse_missing("ok\\nMISSING Mod.fun/2\\nMISSING Other.x/0")
      ["Mod.fun/2", "Other.x/0"]
  """
  @spec parse_missing(String.t()) :: [String.t()]
  def parse_missing(out) do
    ~r/^\s*MISSING[ :]+(\S.*)$/m
    |> Regex.scan(out)
    |> Enum.map(fn [_, cell] -> String.trim(cell) end)
  end

  @doc """
  Derive standing from steps. Fail-closed: any nonzero exit/failure, survivor or
  MISSING cell is never ALIVE; no steps is UNVERIFIED.

      iex> AshPPlan.MirrorSim.Runner.standing([])
      "UNVERIFIED"
  """
  @spec standing([step()]) :: String.t()
  def standing([]), do: "UNVERIFIED"

  def standing(steps) do
    green = Enum.count(steps, &(&1.exit == 0 and &1.failures == 0))
    survivors = Enum.sum(Enum.map(steps, & &1.survived))
    missing = Enum.flat_map(steps, & &1.missing)
    mutants? = Enum.any?(steps, &(&1.phase == :mutants and &1.killed > 0))

    cond do
      green == 0 -> "BLOCKED"
      green < length(steps) -> "PARTIAL"
      survivors > 0 or missing != [] -> "PARTIAL_ALIVE"
      not mutants? -> "PARTIAL_ALIVE"
      true -> "ALIVE"
    end
  end

  @doc """
  Render the receipt markdown. `meta` needs `:sha` and `:steps`; optional `:at`.
  """
  @spec render(%{sha: String.t(), steps: [step()]}) :: String.t()
  def render(%{sha: sha, steps: steps} = meta) do
    killed = Enum.sum(Enum.map(steps, & &1.killed))
    survived = Enum.sum(Enum.map(steps, & &1.survived))
    missing = steps |> Enum.flat_map(& &1.missing) |> Enum.uniq()

    rows =
      Enum.map_join(steps, "\n", fn s ->
        "| #{s.phase} | `#{s.file}` | `#{s.cmd}` | #{s.exit} | #{s.tests} | #{s.failures} | " <>
          "#{s.killed}/#{s.survived} |"
      end)

    missing_block =
      case missing do
        [] -> "none"
        cells -> Enum.map_join(cells, "\n", &"- MISSING #{&1}")
      end

    """
    # mirror-sim #{sha}

    Standing: #{standing(steps)}

    - Subject SHA: #{sha}
    - Generated: #{Map.get(meta, :at, DateTime.to_iso8601(DateTime.utc_now()))}
    - Mutants killed: #{killed}
    - Mutants survived: #{survived}
    - Steps: #{length(steps)} (#{Enum.count(steps, &(&1.exit == 0))} exit 0)

    ## Commands

    | phase | file | command | exit | tests | failures | killed/survived |
    |---|---|---|---|---|---|---|
    #{rows}

    ## MISSING cells

    #{missing_block}

    ## Replay

    `MIX_ENV=test mix test test/mirror_sim` or `scripts/mirror_sim/run_all.sh`.
    """
  end

  @doc "Current git HEAD (read-only), or `UNKNOWN-SHA`."
  @spec git_sha(String.t()) :: String.t()
  def git_sha(root) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "UNKNOWN-SHA"
    end
  rescue
    _ -> "UNKNOWN-SHA"
  end

  @doc "Run one court file as a `mix test` subprocess."
  @spec run_file(String.t(), String.t()) :: step()
  def run_file(root, file) do
    args = ["test", file]

    {out, code} =
      System.cmd("mix", args, cd: root, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    {tests, failures} = parse_tests(out)
    {killed, survived} = parse_mutants(out)

    %{
      file: file,
      phase: classify(file),
      cmd: "MIX_ENV=test mix " <> Enum.join(args, " "),
      exit: code,
      tests: tests,
      failures: failures,
      killed: killed,
      survived: survived,
      missing: parse_missing(out)
    }
  end

  @doc """
  Run every court under `test/mirror_sim/` (excluding the runner's own test) in phase
  order, write the receipt, and return `{:ok, path, steps}`.
  """
  @spec run(keyword()) :: {:ok, String.t(), [step()]}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    files =
      root
      |> Path.join("test/mirror_sim/*_test.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(Path.basename(&1) == "runner_test.exs"))
      |> Enum.sort_by(&{phase_rank(classify(&1)), &1})

    steps = Enum.map(files, &run_file(root, &1))
    write_receipt(root, steps)
  end

  @doc "Write `receipts/mirror-sim-<sha>.md` under `root` for the given steps."
  @spec write_receipt(String.t(), [step()]) :: {:ok, String.t(), [step()]}
  def write_receipt(root, steps) do
    sha = git_sha(root)
    dir = Path.join(root, "receipts")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mirror-sim-#{sha}.md")
    File.write!(path, render(%{sha: sha, steps: steps}))
    {:ok, path, steps}
  end

  defp phase_rank(:area), do: 0
  defp phase_rank(:parity), do: 1
  defp phase_rank(:mutants), do: 2
  defp phase_rank(:coverage), do: 3
end
