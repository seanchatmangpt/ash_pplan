defmodule AshPPlan.MirrorSim.MutationTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.Mutation

  @sample """
  defmodule Sample do
    def eq(x), do: x == 1
    def ok(x) when is_integer(x), do: {:ok, x}
    def other(_), do: :error
  end
  """

  setup do
    {out, 0} = System.cmd("mktemp", ["-d", "-t", "mirror_mut_test"])
    root = String.trim(out)
    lib = Path.join(root, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, "sample.ex"), @sample)
    on_exit(fn -> File.rm_rf(root) end)
    Mutation.reset()
    {:ok, lib: lib}
  end

  defp spec(op, i \\ 0), do: %{file: "sample.ex", operator: op, index: i}

  test "every operator has a site in the sample and marks the shim" do
    for op <- Mutation.operators() do
      assert {:ok, out, line} = Mutation.apply_site(@sample, op, 0)
      assert out =~ "# SHIM-COURT: #{op}"
      assert line >= 1
      assert out != @sample
    end
  end

  test "court that flips is KILLED; restore byte-exact; real file untouched", %{lib: lib} do
    before_sha = Mutation.sha(Path.join(lib, "sample.ex"))
    r = Mutation.run(spec(:flip_comparison), "grep -q '==' lib/sample.ex", lib_dir: lib)

    assert r.status == :killed
    assert r.before_exit == 0 and r.after_exit != 0
    assert r.restore == :ok and r.real_unchanged
    assert r.verdict == :PASS
    assert Mutation.sha(Path.join(lib, "sample.ex")) == before_sha
  end

  test "court that cannot flip SURVIVES and is FAIL", %{lib: lib} do
    r = Mutation.run(spec(:nil_return), "true", lib_dir: lib)
    assert r.status == :survived
    assert r.verdict == :FAIL
  end

  test "court red before the shim is a skip", %{lib: lib} do
    r = Mutation.run(spec(:swap_atom), "false", lib_dir: lib)
    assert r.status == :skip
    assert r.reason == :court_red_before_shim
  end

  test "missing site, bad operator, escaping path are skips", %{lib: lib} do
    assert %{status: :skip, reason: :no_site} =
             Mutation.run(spec(:swap_atom, 99), "true", lib_dir: lib)

    assert %{status: :skip, reason: :unknown_operator} =
             Mutation.run(spec(:bogus), "true", lib_dir: lib)

    assert %{status: :skip, reason: :bad_file} =
             Mutation.run(%{file: "../etc/passwd", operator: :swap_atom, index: 0}, "true",
               lib_dir: lib
             )
  end

  test "self-check proves restore detection is not vacuous" do
    assert Mutation.self_check() == :ok
  end

  test "restore_check refuses a corrupted restore on a real temp copy", %{lib: lib} do
    baseline = Mutation.tree_hashes(lib)
    assert Mutation.restore_check(lib, baseline) == :ok
    File.write!(Path.join(lib, "sample.ex"), @sample <> "\n")
    assert Mutation.restore_check(lib, baseline) == {:error, :restore_mismatch}
  end

  test "court_cmd allows repo test paths only and never the mutation court itself" do
    assert {:ok, _} = Mutation.court_cmd("test/foo_test.exs")
    assert :error = Mutation.court_cmd("../x_test.exs")
    assert :error = Mutation.court_cmd("rm -rf /")
    assert :error = Mutation.court_cmd("test/mirror_sim/mutation_test.exs")
  end

  describe "wire" do
    setup do
      {:ok, _} = Application.ensure_all_started(:inets)
      {:ok, pid} = Bandit.start_link(plug: Mutation, port: 0, startup_log: false)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      {:ok, base: "http://127.0.0.1:#{port}"}
    end

    defp http(method, url, body \\ nil) do
      req =
        case body do
          nil -> {String.to_charlist(url), []}
          b -> {String.to_charlist(url), [], ~c"application/json", Jason.encode!(b)}
        end

      {:ok, {{_, code, _}, _h, resp}} = :httpc.request(method, req, [], [])
      {code, Jason.decode!(List.to_string(resp))}
    end

    test "GET /mutants lists real-lib mutants read-only", %{base: base} do
      {code, body} = http(:get, base <> "/mutants?limit=5")
      assert code == 200
      assert body["count"] == 5

      assert Enum.all?(
               body["mutants"],
               &(&1["operator"] in Enum.map(Mutation.operators(), fn o -> Atom.to_string(o) end))
             )
    end

    test "bad operator and bad court are typed 422 refusals", %{base: base} do
      assert {422, %{"refused" => true, "broken_term" => "unknown_operator"}} =
               http(:get, base <> "/mutants?operator=bogus")

      assert {422, %{"refused" => true, "broken_term" => "bad_court"}} =
               http(:post, base <> "/run", %{
                 "file" => "x.ex",
                 "operator" => "swap_atom",
                 "court" => "rm -rf /"
               })

      assert {422, %{"refused" => true, "broken_term" => "unknown_operator"}} =
               http(:post, base <> "/run", %{"operator" => "nope"})
    end

    test "GET /report aggregates", %{base: base} do
      assert {200,
              %{"total" => 0, "verdict" => "PASS", "summary" => "MUTANTS killed=0 survived=0"}} =
               http(:get, base <> "/report")
    end
  end
end
