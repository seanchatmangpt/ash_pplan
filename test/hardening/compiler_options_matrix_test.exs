defmodule AshPPlan.Hardening.CompilerOptionsMatrixTest do
  @moduledoc """
  P2a fuzz court for `AshPPlan.Compiler`'s OPTION space, randomized on top of
  `compiler_options_hardening_test.exs` (which pins the fixed cases). The law
  under test: every point in the adversarial option/spec matrix yields a typed
  `%AshPPlan.Compiler.Error{}` refusal or a valid reactor — never a raise.

  No stream_data in this repo's deps, so the matrix is a seeded, deterministic
  sweep: reproducible on every run, reproducible in CI.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error

  defmodule MatrixNoopStep do
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :noop}
  end

  @iris [nil, :atom, 42, 1.5, %{}, [], {:t}, "", <<0>>, "ok", true, false]
  @handler_containers [nil, :atom, "m", 42, [], [MatrixNoopStep], {:t}, %{"k" => MatrixNoopStep}]
  @step_iris [nil, 42, :a, "", <<0, 1>>, %{not: :binary}, [:list], {:t, :u}, " ", "urn:x"]
  @preds [nil, :a, 42, "a", %{}, {:t}, [], [:a], [:a | :b], String.to_atom("preds_x")]

  defp seed, do: {1400, 600_000, 900_000}

  defp rng do
    :rand.seed(:exsss, seed())
    fn n -> :rand.uniform(n) end
  end

  defp pick(r, pool), do: Enum.at(pool, r.(length(pool)) - 1)

  defp step_spec(r) do
    %{
      iri: pick(r, @step_iris),
      label: pick(r, [nil, "", :lbl, 42, %{deep: self()}]),
      predecessors: pick(r, @preds),
      inputs: pick(r, [[], nil, [:in], :in, %{a: 1}, ["x" | :y]]),
      outputs: pick(r, [[], nil, [:out], :out]),
      options: pick(r, [[], nil, :opts, [a: 1], %{m: 1}])
    }
  end

  defp handlers_for(steps) do
    r = rng()

    case r.(3) do
      1 -> Map.new(steps, &{&1.iri, MatrixNoopStep})
      2 -> %{}
      _ -> %{"nope" => MatrixNoopStep, extra: MatrixNoopStep}
    end
  end

  defp valid_step(iri, preds) do
    %{iri: iri, label: iri, predecessors: preds, inputs: [], outputs: []}
  end

  defp valid_plan(steps, iri \\ "urn:plan:matrix") do
    %{iri: iri, steps: steps}
  end

  describe "compile/2 randomized matrix" do
    test "every (iri, handlers) pair in the matrix is typed or ok — never a raise" do
      for iri <- @iris, handlers <- @handler_containers do
        result = Compiler.compile(iri, handlers)

        assert match?({:ok, %{}}, result) or match?({:error, %Error{}}, result),
               "compile(#{inspect(iri)}, #{inspect(handlers)}) raised off-contract"

        # unknown plan for any binary/map pair is the only admissible :ok path
        if match?({:ok, _}, result) and not is_binary(iri) do
          flunk("non-binary iri admitted: #{inspect(iri)}")
        end
      end
    end
  end

  describe "compile_spec/2 randomized adversarial specs" do
    test "random garbage step specs never raise" do
      r = rng()

      for _ <- 1..300 do
        steps = for _ <- 1..r.(4), do: step_spec(r)
        plan = valid_plan(steps, pick(r, @iris))
        result = Compiler.compile_spec(plan, handlers_for(steps))

        assert match?({:ok, %{}}, result) or match?({:error, %Error{}}, result),
               "compile_spec raised off-contract for #{inspect(plan)}"
      end
    end

    test "random mixed valid/garbage specs never raise" do
      r = rng()

      for _ <- 1..300 do
        base = [valid_step("urn:s:1", []), valid_step("urn:s:2", ["urn:s:1"])]

        steps =
          for s <- base do
            if r.(2) == 1 do
              s
            else
              %{s | iri: pick(r, @step_iris), predecessors: pick(r, @preds)}
            end
          end

        plan =
          if r.(2) == 1 do
            valid_plan(steps)
          else
            pick(r, [nil, :atom, 42, %{iri: "x"}, %{}, String.to_atom("pl_x")])
          end

        result = Compiler.compile_spec(plan, handlers_for(steps))

        assert match?({:ok, %{}}, result) or match?({:error, %Error{}}, result)
      end
    end

    test "adversarial opts inside step options never leak into a raise" do
      r = rng()

      for _ <- 1..200 do
        step =
          %{
            iri: "urn:s:o",
            label: "urn:s:o",
            predecessors: [],
            inputs: [],
            outputs: [],
            options: pick(r, @preds ++ [[b: {:fun}], ["k" | :v]])
          }

        plan = valid_plan([step])

        assert match?(
                 {:ok, %{}},
                 Compiler.compile_spec(plan, %{"urn:s:o" => MatrixNoopStep})
               ) or
                 match?(
                   {:error, %Error{}},
                   Compiler.compile_spec(plan, %{"urn:s:o" => MatrixNoopStep})
                 )
      end
    end

    test "seed reproducibility: same seed twice gives identical refusal stream" do
      run = fn ->
        r = rng()

        for _ <- 1..50 do
          steps = for _ <- 1..r.(3), do: step_spec(r)
          Compiler.compile_spec(valid_plan(steps), handlers_for(steps))
        end
      end

      assert run.() == run.()
    end
  end
end
