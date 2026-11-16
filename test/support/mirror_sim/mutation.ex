defmodule AshPPlan.MirrorSim.Mutation do
  @moduledoc """
  Mutation engine for the mirror simulation (shim-court protocol).

  Mutations are applied ONLY to a scratch copy of `lib/` (`mktemp -d`); the real
  source tree is read, hashed, and never written. Protocol per mutant:

      BASELINE (sha256 of scratch tree) -> BEFORE (court must pass)
      -> SHIM (mutation, marked `# SHIM-COURT: <op>`) -> AFTER (court outcome)
      -> RESTORE (scratch tree sha256 byte-exact, fail-closed)

  A mutant is `:killed` when the court passes BEFORE and fails AFTER, `:survived`
  when the court still passes (a court that cannot flip is FAIL), and `:skip`
  when the protocol could not start (court red before the shim, no mutation
  site, bad spec). A restore mismatch yields `:fail`.

  Mounted at `/mutation/*`: `GET /mutants`, `POST /run`, `GET /report`.
  """

  use Plug.Router

  @repo_lib Path.expand("../../../lib", __DIR__)
  @script Path.expand("../../../scripts/mirror_sim/mutate.sh", __DIR__)

  @operators [:flip_comparison, :drop_clause, :swap_atom, :remove_guard, :nil_return]
  @compile_error ~r/\*\* \((CompileError|SyntaxError|TokenMissingError)\)|== Compilation error/

  plug(:match)
  plug(:dispatch)

  @type spec :: %{file: String.t(), operator: atom(), index: non_neg_integer()}

  @doc "Operator catalog."
  @spec operators() :: [atom()]
  def operators, do: @operators

  @doc "Route surfaces for the L01 router."
  @spec surfaces() :: [map()]
  def surfaces do
    [
      %{module: __MODULE__, fun: :mutants, arity: 1, route: "/mutation/mutants"},
      %{module: __MODULE__, fun: :run, arity: 3, route: "/mutation/run"},
      %{module: __MODULE__, fun: :report, arity: 0, route: "/mutation/report"}
    ]
  end

  # ---------------------------------------------------------------- operators

  defp pattern(:flip_comparison), do: ~r/(?<![=!<>])(?:==|!=|>=|<=)(?![=>])/
  defp pattern(:drop_clause), do: ~r/^[ \t]*defp?[ \t][^\n]*,[ \t]*do:[ \t][^\n]*$/m
  defp pattern(:swap_atom), do: ~r/(?<![\w:]):(?:ok|error)\b/
  defp pattern(:remove_guard), do: ~r/[ \t]when [^\n]*?(?=,[ \t]*do:|[ \t]do\b|[ \t]*->)/
  defp pattern(:nil_return), do: ~r/(?<=, do: )(?!nil\b)[^\n]+$/m

  defp replacement(:flip_comparison, "=="), do: "!="
  defp replacement(:flip_comparison, "!="), do: "=="
  defp replacement(:flip_comparison, ">="), do: "<"
  defp replacement(:flip_comparison, "<="), do: ">"
  defp replacement(:swap_atom, ":ok"), do: ":error"
  defp replacement(:swap_atom, ":error"), do: ":ok"
  defp replacement(:drop_clause, _), do: ""
  defp replacement(:remove_guard, _), do: ""
  defp replacement(:nil_return, _), do: "nil"

  @doc """
  Mutation sites of `operator` in `source`: `[{byte_start, byte_len, replacement}]`.

      iex> AshPPlan.MirrorSim.Mutation.sites("a == b", :flip_comparison)
      [{2, 2, "!="}]
  """
  @spec sites(binary(), atom()) :: [{non_neg_integer(), non_neg_integer(), binary()}]
  def sites(source, operator) when operator in @operators do
    operator
    |> pattern()
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{s, l} | _] -> {s, l, replacement(operator, binary_part(source, s, l))} end)
  end

  @doc """
  Apply the `index`-th site of `operator`, marking the line `# SHIM-COURT: <op>`.
  Returns `{:ok, mutated_source, line}` or `:no_site`.

      iex> {:ok, out, 1} = AshPPlan.MirrorSim.Mutation.apply_site("a == b\\n", :flip_comparison, 0)
      iex> out
      "a != b # SHIM-COURT: flip_comparison\\n"
  """
  @spec apply_site(binary(), atom(), non_neg_integer()) ::
          {:ok, binary(), pos_integer()} | :no_site
  def apply_site(source, operator, index) when operator in @operators and index >= 0 do
    case Enum.at(sites(source, operator), index) do
      nil ->
        :no_site

      {s, l, rep} ->
        head = binary_part(source, 0, s)
        tail = binary_part(source, s + l, byte_size(source) - s - l)

        {line_tail, rest} =
          case :binary.split(tail, "\n") do
            [a, b] -> {a, "\n" <> b}
            [a] -> {a, ""}
          end

        line = length(:binary.matches(head, "\n")) + 1
        {:ok, head <> rep <> line_tail <> " # SHIM-COURT: #{operator}" <> rest, line}
    end
  end

  # ---------------------------------------------------------------- listing

  @doc "Enumerate mutants over `lib_dir` (read-only). Opts: `:lib_dir, :file, :operator, :limit`."
  @spec mutants(keyword()) :: [map()]
  def mutants(opts \\ []) do
    lib = Keyword.get(opts, :lib_dir, @repo_lib)
    only_file = Keyword.get(opts, :file)
    only_op = Keyword.get(opts, :operator)
    limit = Keyword.get(opts, :limit, :infinity)

    lib
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, lib))
    |> Enum.filter(&(only_file in [nil, &1]))
    |> Stream.flat_map(fn rel ->
      source = File.read!(Path.join(lib, rel))

      for op <- @operators,
          only_op in [nil, op],
          {{s, _l, _r}, i} <- Enum.with_index(sites(source, op)) do
        line = length(:binary.matches(binary_part(source, 0, s), "\n")) + 1
        %{id: "#{rel}|#{op}|#{i}", file: rel, operator: op, index: i, line: line}
      end
    end)
    |> take(limit)
  end

  defp take(stream, :infinity), do: Enum.to_list(stream)
  defp take(stream, n), do: Enum.take(stream, n)

  # ---------------------------------------------------------------- hashing

  @doc "sha256 (hex) of one file."
  @spec sha(Path.t()) :: String.t()
  def sha(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  @doc "Map of relative path => sha256 for every regular file under `dir`."
  @spec tree_hashes(Path.t()) :: %{String.t() => String.t()}
  def tree_hashes(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, dir), sha(&1)})
  end

  @doc "Fail-closed restore check: current tree must equal `baseline` byte-for-byte."
  @spec restore_check(Path.t(), map()) :: :ok | {:error, :restore_mismatch}
  def restore_check(dir, baseline) do
    if tree_hashes(dir) == baseline, do: :ok, else: {:error, :restore_mismatch}
  end

  @doc """
  Prove restore detection is not vacuous: on a temp copy, a byte-exact restore must
  pass and a corrupted restore must be refused.
  """
  @spec self_check() :: :ok | {:error, term()}
  def self_check do
    dir = mktemp()

    try do
      file = Path.join(dir, "f.ex")
      original = "def a(x), do: x == 1\n"
      File.write!(file, original)
      baseline = tree_hashes(dir)

      {:ok, mutated, _} = apply_site(original, :flip_comparison, 0)
      File.write!(file, mutated)
      mutated_detected = restore_check(dir, baseline) == {:error, :restore_mismatch}

      File.write!(file, original <> " ")
      corrupt_detected = restore_check(dir, baseline) == {:error, :restore_mismatch}

      File.write!(file, original)
      exact_ok = restore_check(dir, baseline) == :ok

      if mutated_detected and corrupt_detected and exact_ok,
        do: :ok,
        else: {:error, {:self_check_vacuous, mutated_detected, corrupt_detected, exact_ok}}
    after
      File.rm_rf(dir)
    end
  end

  # ---------------------------------------------------------------- engine

  @doc """
  Court command for a repo test file, run in the scratch root (see
  `scripts/mirror_sim/mutate.sh`). Returns `{:ok, cmd}` or `:error`.
  """
  @spec court_cmd(String.t()) :: {:ok, String.t()} | :error
  def court_cmd(test_path) when is_binary(test_path) do
    if test_path =~ ~r/\Atest\/[\w\/.\-]+_test\.exs\z/ and not String.contains?(test_path, "..") and
         not String.starts_with?(test_path, "test/mirror_sim/mutation") do
      {:ok, "sh #{@script} court #{test_path}"}
    else
      :error
    end
  end

  @doc """
  Run the shim-court protocol for one mutant against `court_cmd` (a shell command
  executed with cwd = scratch root, env `MIRROR_SCRATCH_LIB`, `MIRROR_REPO_ROOT`).
  Opts: `:lib_dir` (source lib, default repo lib/).
  """
  @spec run(map(), String.t(), keyword()) :: map()
  def run(spec, court_cmd, opts \\ [])

  def run(%{anchor: anchor, replacement: repl} = spec, court_cmd, opts)
      when is_binary(anchor) and is_binary(repl) do
    lib = Keyword.get(opts, :lib_dir, @repo_lib)
    file = Map.get(spec, :file)
    base = %{status: :skip, operator: :anchor, file: file, index: 0, id: Map.get(spec, :id)}

    with {:file, {:ok, rel}} <- {:file, safe_rel(file, lib)},
         {:self, :ok} <- {:self, self_check()} do
      mutate = fn original -> apply_anchor(original, anchor, repl) end
      protocol(%{base | file: rel}, lib, rel, mutate, court_cmd)
    else
      {:file, _} -> Map.put(base, :reason, :bad_file)
      {:self, err} -> %{base | status: :fail} |> Map.put(:reason, inspect(err))
    end
  end

  def run(spec, court_cmd, opts) do
    lib = Keyword.get(opts, :lib_dir, @repo_lib)
    index = Map.get(spec, :index, 0)
    file = Map.get(spec, :file)
    op = Map.get(spec, :operator)
    base = %{status: :skip, operator: op, file: file, index: index}

    with {:op, true} <- {:op, op in @operators},
         {:idx, true} <- {:idx, is_integer(index) and index >= 0},
         {:file, {:ok, rel}} <- {:file, safe_rel(file, lib)},
         {:self, :ok} <- {:self, self_check()} do
      mutate = fn original -> apply_site(original, op, index) end
      protocol(%{base | file: rel}, lib, rel, mutate, court_cmd)
    else
      {:op, _} -> Map.put(base, :reason, :unknown_operator)
      {:idx, _} -> Map.put(base, :reason, :bad_index)
      {:file, _} -> Map.put(base, :reason, :bad_file)
      {:self, err} -> %{base | status: :fail} |> Map.put(:reason, inspect(err))
    end
  end

  defp safe_rel(file, lib) when is_binary(file) do
    with {:ok, rel} <- Path.safe_relative(file),
         true <- File.regular?(Path.join(lib, rel)) do
      {:ok, rel}
    else
      _ -> :error
    end
  end

  defp safe_rel(_, _), do: :error

  defp protocol(base, lib, rel, mutate, court_cmd) do
    scratch = mktemp()
    real_file = Path.join(lib, rel)
    real_sha = sha(real_file)

    try do
      File.cp_r!(lib, Path.join(scratch, "lib"))
      scratch_lib = Path.join(scratch, "lib")
      scratch_file = Path.join(scratch_lib, rel)
      original = File.read!(scratch_file)
      baseline = tree_hashes(scratch_lib)

      {before_code, before_out} = exec(court_cmd, scratch, lib)

      cond do
        before_code != 0 ->
          Map.merge(base, %{
            reason: :court_red_before_shim,
            before_exit: before_code,
            output: tail(before_out)
          })

        true ->
          case mutate.(original) do
            :no_site ->
              Map.merge(base, %{reason: :no_site, before_exit: 0})

            {:ok, mutated, line} ->
              File.write!(scratch_file, mutated)
              shim_sha = sha(scratch_file)
              {after_code, after_out} = exec(court_cmd, scratch, lib)

              File.write!(scratch_file, original)
              restore = restore_check(scratch_lib, baseline)
              real_unchanged = sha(real_file) == real_sha

              status =
                cond do
                  restore != :ok or not real_unchanged -> :fail
                  after_code != 0 -> :killed
                  true -> :survived
                end

              Map.merge(base, %{
                status: status,
                line: line,
                before_exit: 0,
                after_exit: after_code,
                kill_kind: kill_kind(status, after_out),
                baseline_sha: real_sha,
                shim_sha: shim_sha,
                restore: restore,
                real_unchanged: real_unchanged,
                verdict: if(status == :survived, do: :FAIL, else: :PASS),
                output: tail(after_out)
              })
          end
      end
    after
      File.rm_rf(scratch)
    end
  end

  # Anchor mutation: the anchor must occur exactly once (ambiguous/absent => :no_site).
  defp apply_anchor(source, anchor, repl) do
    case :binary.matches(source, anchor) do
      [{start, len}] ->
        mutated =
          binary_part(source, 0, start) <>
            repl <> binary_part(source, start + len, byte_size(source) - start - len)

        line = source |> binary_part(0, start) |> String.split("\n") |> length()
        {:ok, mutated, line}

      _ ->
        :no_site
    end
  end

  defp kill_kind(:killed, out),
    do: if(out =~ @compile_error, do: :compile_error, else: :test_failure)

  defp kill_kind(_, _), do: nil

  # Returns {exit_code, output}. System.cmd/3 returns {output, exit_code}; swapped here.
  # A court exceeding @court_timeout is shut down and reported as exit 124.
  @court_timeout 900_000

  defp exec(cmd, scratch, lib) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", cmd],
          cd: scratch,
          stderr_to_stdout: true,
          env: [
            {"MIRROR_SCRATCH_LIB", Path.join(scratch, "lib")},
            {"MIRROR_REPO_ROOT", Path.dirname(lib)}
          ]
        )
      end)

    case Task.yield(task, @court_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {code, out}
      _ -> {124, "court timeout after #{@court_timeout}ms"}
    end
  end

  @doc """
  One-line summary parsed by the runner.

      iex> AshPPlan.MirrorSim.Mutation.summary_line(%{killed: 3, survived: 1})
      "MUTANTS killed=3 survived=1"
  """
  @spec summary_line(map()) :: String.t()
  def summary_line(%{killed: k, survived: s}), do: "MUTANTS killed=#{k} survived=#{s}"

  defp tail(out) when byte_size(out) > 2000, do: binary_part(out, byte_size(out) - 2000, 2000)
  defp tail(out), do: out

  defp mktemp do
    {out, 0} = System.cmd("mktemp", ["-d", "-t", "mirror_mut"])
    String.trim(out)
  end

  # ---------------------------------------------------------------- report

  @doc "Aggregate recorded results."
  @spec report() :: map()
  def report do
    results = :persistent_term.get({__MODULE__, :results}, [])
    count = fn s -> Enum.count(results, &(&1.status == s)) end
    decided = count.(:killed) + count.(:survived)

    %{
      total: length(results),
      killed: count.(:killed),
      survived: count.(:survived),
      skipped: count.(:skip),
      failed: count.(:fail),
      kill_rate: if(decided == 0, do: nil, else: count.(:killed) / decided),
      verdict: if(count.(:survived) + count.(:fail) == 0, do: :PASS, else: :FAIL),
      results: Enum.map(results, &Map.drop(&1, [:output]))
    }
  end

  @doc "Record a result for `report/0`."
  @spec record(map()) :: :ok
  def record(result) do
    :persistent_term.put({__MODULE__, :results}, [
      result | :persistent_term.get({__MODULE__, :results}, [])
    ])
  end

  @doc "Clear recorded results."
  @spec reset() :: :ok
  def reset do
    :persistent_term.put({__MODULE__, :results}, [])
  end

  # ---------------------------------------------------------------- routes

  get "/mutants" do
    conn = fetch_query_params(conn)
    q = conn.query_params

    opts =
      [file: q["file"], limit: parse_limit(q["limit"])]
      |> Keyword.put(:operator, find_op(q["operator"]))

    if q["operator"] != nil and opts[:operator] == nil do
      refuse(conn, "unknown_operator", "operator must be one of #{inspect(@operators)}")
    else
      list = mutants(opts)
      json(conn, 200, %{operators: @operators, count: length(list), mutants: list})
    end
  end

  post "/run" do
    with {:ok, body} <- body(conn),
         {:op, op} when op != nil <- {:op, find_op(body["operator"])},
         {:idx, idx} when is_integer(idx) and idx >= 0 <- {:idx, Map.get(body, "index", 0)},
         {:court, {:ok, cmd}} <- {:court, court_cmd(body["court"] || "")} do
      result = run(%{file: body["file"], operator: op, index: idx}, cmd)
      record(result)
      json(conn, 200, result)
    else
      {:error, reason} ->
        refuse(conn, "bad_body", reason)

      {:op, _} ->
        refuse(conn, "unknown_operator", "operator must be one of #{inspect(@operators)}")

      {:idx, _} ->
        refuse(conn, "bad_index", "index must be a non-negative integer")

      {:court, _} ->
        refuse(conn, "bad_court", "court must be a repo test path matching test/**/*_test.exs")
    end
  end

  get "/report" do
    r = report()

    if conn |> fetch_query_params() |> Map.get(:query_params) |> Map.get("format") == "text" do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, summary_line(r) <> "\n")
    else
      json(conn, 200, Map.put(r, :summary, summary_line(r)))
    end
  end

  match _ do
    conn
    |> json(404, %{refused: true, broken_term: "unknown_route", reason: "no such mutation route"})
  end

  defp find_op(nil), do: nil
  defp find_op(s) when is_binary(s), do: Enum.find(@operators, &(Atom.to_string(&1) == s))
  defp find_op(_), do: nil

  defp parse_limit(nil), do: :infinity

  defp parse_limit(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> :infinity
    end
  end

  defp body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        with {:ok, raw, _conn} <- read_body(conn),
             {:ok, %{} = map} <- Jason.decode(raw) do
          {:ok, map}
        else
          _ -> {:error, "body must be a JSON object"}
        end

      %{} = map ->
        {:ok, map}
    end
  end

  defp refuse(conn, term, reason),
    do: json(conn, 422, %{refused: true, broken_term: term, reason: reason})

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
