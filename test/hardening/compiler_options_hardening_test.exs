defmodule AshPPlan.Hardening.CompilerOptionsHardeningTest do
  @moduledoc """
  HARDEN-lane falsifiers for the compiler's OPTION space: everything a caller
  can pass to `compile/2` and `compile_spec/2` besides step bodies.

  Sweep covers garbage options shapes (unknown plan keys are projection-neutral
  by contract, non-keyword/improper handler option lists, non-map/nil handler
  containers, conflicting or unloaded handler modules), nil opts, the
  predecessor and terminal budgets at the exact documented boundary (16 admits,
  17 refuses), and IR the projection layer should survive (unicode IRIs,
  very-long IRIs). Every malformed input must yield a typed
  `%AshPPlan.Compiler.Error{}` refusal — never a raise.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error

  defmodule NoopStep do
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :noop}
  end

  defp step(iri, predecessors \\ []) do
    %{iri: iri, label: iri, predecessors: predecessors, inputs: [], outputs: []}
  end

  defp plan(steps, iri \\ "urn:plan:options-hardening") do
    %{iri: iri, steps: steps}
  end

  defp handlers(%{steps: steps}), do: Map.new(steps, &{&1.iri, NoopStep})

  defp compile_ok?(result) do
    assert {:ok, reactor} = result
    assert is_map(reactor)
    reactor
  end

  defp refuses_typed?(result, reason) do
    assert {:error, %Error{reason: ^reason}} = result
    true
  end

  # ---------------------------------------------------------------------------
  # compile/2 argument space
  # ---------------------------------------------------------------------------

  describe "compile/2 argument garbage" do
    test "refuses a non-binary plan IRI typed, for every garbage shape" do
      for iri <- [nil, :atom, 42, 1.5, %{}, [], {:tuple}, make_ref()] do
        refuses_typed?(Compiler.compile(iri, %{}), :invalid_compile_arguments)
      end
    end

    test "refuses a non-map handlers container typed" do
      for bad <- [nil, :atom, "map-looking", 42, [NoopStep], {:noop, NoopStep}] do
        refuses_typed?(Compiler.compile("urn:plan:absent", bad), :invalid_compile_arguments)
      end
    end

    test "both arguments garbage at once still refuses typed with per-field flags" do
      assert {:error,
              %Error{
                reason: :invalid_compile_arguments,
                details: %{plan_iri?: false, handlers?: false}
              }} = Compiler.compile(nil, nil)
    end

    test "an unknown plan IRI refuses as unknown_plan, never raises" do
      refuses_typed?(
        Compiler.compile("urn:plan:definitely-not-cataloged", %{any: :map}),
        :unknown_plan
      )
    end

    test "an empty-string plan IRI refuses typed" do
      refuses_typed?(Compiler.compile("", %{}), :unknown_plan)
    end
  end

  # ---------------------------------------------------------------------------
  # compile_spec/2 spec garbage
  # ---------------------------------------------------------------------------

  describe "compile_spec/2 spec garbage" do
    test "refuses a nil spec typed" do
      refuses_typed?(Compiler.compile_spec(nil, %{}), :invalid_plan_spec)
    end

    test "refuses non-map specs of every shape typed" do
      for bad <- [:atom, "binary", 42, 1.5, [step("urn:step:a")], {:tuple, :garbage}, make_ref()] do
        refuses_typed?(Compiler.compile_spec(bad, %{}), :invalid_plan_spec)
      end
    end

    test "refuses a spec with a non-binary iri or non-list steps typed" do
      base = [step("urn:step:a")]

      for plan <- [
            %{iri: nil, steps: base},
            %{iri: 42, steps: base},
            %{iri: "urn:plan:ok", steps: nil},
            %{iri: "urn:plan:ok", steps: :not_a_list},
            %{iri: "urn:plan:ok", steps: %{"urn:step:a" => step("urn:step:a")}}
          ] do
        refuses_typed?(Compiler.compile_spec(plan, %{}), :invalid_plan_spec)
      end
    end

    test "an improper step list refuses typed instead of looping the walk" do
      improper = [step("urn:step:a") | "not-a-list"]

      refuses_typed?(
        Compiler.compile_spec(%{iri: "urn:plan:improper", steps: improper}, %{}),
        :invalid_plan_spec
      )
    end

    test "unknown/extra plan keys are projection-neutral, not refusals" do
      extra =
        plan([step("urn:step:a")])
        |> Map.put(:totally_unknown_option, {:weird, :tuple})
        |> Map.put(:adapter, NoopStep)
        |> Map.put(:options, unknown_key: :value)

      compile_ok?(Compiler.compile_spec(extra, handlers(extra)))
    end

    test "nil opts for both arguments refuses typed, never raises" do
      refuses_typed?(Compiler.compile_spec(nil, nil), :invalid_plan_spec)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler option space
  # ---------------------------------------------------------------------------

  describe "handler option space" do
    test "refuses {module, options} tuples with non-keyword option lists typed" do
      steps = [step("urn:step:a")]
      p = plan(steps)

      for bad_options <- [
            [:not_a_keyword_pair],
            [42, "mixed garbage"],
            [[:nested, :list]],
            [%{not: :keyword}],
            "not-a-list"
          ] do
        refuses_typed?(
          Compiler.compile_spec(p, %{"urn:step:a" => {NoopStep, bad_options}}),
          :invalid_handlers
        )
      end
    end

    test "refuses {module, improper_list} handlers typed instead of looping keyword?/1" do
      p = plan([step("urn:step:a")])

      refuses_typed?(
        Compiler.compile_spec(p, %{"urn:step:a" => {NoopStep, [:ok | :tail]}}),
        :invalid_handlers
      )
    end

    test "refuses handler tuples with a non-atom module typed" do
      p = plan([step("urn:step:a")])

      for bad <- [{"NoopStep", []}, {42, []}, {nil, []}, {{NoopStep}, []}] do
        refuses_typed?(Compiler.compile_spec(p, %{"urn:step:a" => bad}), :invalid_handlers)
      end
    end

    test "refuses handler shapes that are neither module nor {module, options} typed" do
      p = plan([step("urn:step:a")])

      for bad <- [nil, "NoopStep", {:mod, [], :args}, %{module: NoopStep}, [NoopStep]] do
        refuses_typed?(Compiler.compile_spec(p, %{"urn:step:a" => bad}), :invalid_handlers)
      end
    end

    test "refuses handlers for unloaded atoms typed" do
      p = plan([step("urn:step:a")])

      refuses_typed?(
        Compiler.compile_spec(p, %{"urn:step:a" => Definitely.Not.Loaded}),
        :invalid_handlers
      )
    end

    test "a {module, options} handler with a proper keyword list admits" do
      p = plan([step("urn:step:a")])
      compile_ok?(Compiler.compile_spec(p, %{"urn:step:a" => {NoopStep, [some_option: :value]}}))
    end

    test "a non-existent module in a plain-module handler refuses typed" do
      p = plan([step("urn:step:a")])

      refuses_typed?(
        Compiler.compile_spec(p, %{"urn:step:a" => This.Module.Does.Not.Exist}),
        :invalid_handlers
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Predecessor budget: exact documented boundary 16 vs 17
  # ---------------------------------------------------------------------------

  describe "predecessor budget boundary" do
    test "exactly 16 predecessors admits" do
      predecessors = Enum.map(1..16, &step("urn:step:p#{&1}"))
      p = plan(predecessors ++ [step("urn:step:b", Enum.map(predecessors, & &1.iri))])

      reactor = compile_ok?(Compiler.compile_spec(p, handlers(p)))
      assert Enum.any?(reactor.steps, &(&1.name == "urn:step:b"))
    end

    test "exactly 17 predecessors refuses typed with count and maximum" do
      predecessors = Enum.map(1..17, &step("urn:step:p#{&1}"))
      p = plan(predecessors ++ [step("urn:step:b", Enum.map(predecessors, & &1.iri))])

      assert {:error,
              %Error{
                reason: :too_many_predecessors,
                details: %{step: "urn:step:b", count: 17, maximum: 16}
              }} = Compiler.compile_spec(p, handlers(p))
    end

    test "the boundary applies to a single fan-in step, not the plan total" do
      # 40 plan steps total, no step exceeding 16 predecessors: admits.
      chain =
        Enum.map(
          1..40,
          &step("urn:step:s#{&1}", if(&1 == 1, do: [], else: ["urn:step:s#{&1 - 1}"]))
        )

      compile_ok?(
        Compiler.compile_spec(
          plan(chain, "urn:plan:long-chain"),
          handlers(plan(chain, "urn:plan:long-chain"))
        )
      )
    end

    test "duplicates deduplicate before the budget: 17 raw, 16 unique, admits" do
      unique = Enum.map(1..16, &"urn:step:p#{&1}")
      p = plan(Enum.map(unique, &step/1) ++ [step("urn:step:b", unique ++ [hd(unique)])])
      compile_ok?(Compiler.compile_spec(p, handlers(p)))
    end

    test "budget refusal fires even when the wide step comes first in the list" do
      wide = Enum.map(1..17, &"urn:step:p#{&1}")
      p = plan([step("urn:step:b", wide)] ++ Enum.map(wide, &step/1))

      assert {:error, %Error{reason: :too_many_predecessors}} =
               Compiler.compile_spec(p, handlers(p))
    end
  end

  # ---------------------------------------------------------------------------
  # Terminal budget and terminal combos
  # ---------------------------------------------------------------------------

  describe "terminal step combos" do
    test "a single-terminal plan returns that terminal directly" do
      p = plan([step("urn:step:a"), step("urn:step:b", ["urn:step:a"])])
      reactor = compile_ok?(Compiler.compile_spec(p, handlers(p)))

      # No return-collector step is minted for the single-terminal case.
      refute Enum.any?(reactor.steps, &(&1.name == {:ash_pplan, :return}))
    end

    test "exactly 16 terminals admits and mints the return collector" do
      terminals = Enum.map(1..16, &step("urn:step:t#{&1}"))
      p = plan(terminals, "urn:plan:16-terminals")

      reactor = compile_ok?(Compiler.compile_spec(p, handlers(p)))
      assert Enum.any?(reactor.steps, &(&1.name == {:ash_pplan, :return}))
    end

    test "exactly 17 terminals refuses typed with count and maximum" do
      terminals = Enum.map(1..17, &step("urn:step:t#{&1}"))
      p = plan(terminals, "urn:plan:17-terminals")

      assert {:error,
              %Error{
                reason: :too_many_terminal_steps,
                details: %{count: 17, maximum: 16}
              }} = Compiler.compile_spec(p, handlers(p))
    end

    test "0 terminals is unreachable for an acyclic plan — cyclic input refuses as cyclic_plan first" do
      # Every acyclic plan has >= 1 terminal; the only way to observe "no
      # terminal" is a fully-cyclic plan, which the topology walk refuses first.
      p = plan([step("urn:step:a", ["urn:step:b"]), step("urn:step:b", ["urn:step:a"])])

      assert {:error, %Error{reason: :cyclic_plan}} = Compiler.compile_spec(p, handlers(p))
    end

    test "an empty plan (0 steps, 0 terminals) refuses as empty_plan typed" do
      refuses_typed?(Compiler.compile_spec(plan([]), %{}), :empty_plan)
    end

    test "a diamond plan admits with exactly one terminal" do
      p =
        plan([
          step("urn:step:root"),
          step("urn:step:left", ["urn:step:root"]),
          step("urn:step:right", ["urn:step:root"]),
          step("urn:step:sink", ["urn:step:left", "urn:step:right"])
        ])

      reactor = compile_ok?(Compiler.compile_spec(p, handlers(p)))
      assert length(reactor.steps) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # IR the projection should survive: unicode and very-long IRIs
  # ---------------------------------------------------------------------------

  describe "unicode and very-long IRIs" do
    test "unicode plan and step IRIs admit and survive projection" do
      unicode_step = "urn:step:héllo→🌍-ünïcode"
      p = plan([step(unicode_step), step("urn:step:後続", [unicode_step])], "urn:plan:ユニコード🌍")

      reactor = compile_ok?(Compiler.compile_spec(p, handlers(p)))
      assert Enum.any?(reactor.steps, &(&1.name == unicode_step))
    end

    test "very-long step and plan IRIs admit" do
      long_step = "urn:step:" <> String.duplicate("s", 5_000)
      p = plan([step(long_step)], "urn:plan:" <> String.duplicate("p", 10_000))

      reactor = compile_ok?(Compiler.compile_spec(p, handlers(p)))
      assert Enum.any?(reactor.steps, &(&1.name == long_step))
    end

    test "unicode IRIs inside predecessor edges admit" do
      root = "urn:step:根–"
      p = plan([step(root), step("urn:step:子–", [root])], "urn:plan:unicode-edges")
      reactor = compile_ok?(Compiler.compile_spec(p, handlers(p)))
      assert length(reactor.steps) == 2
    end

    test "an IRI that is only whitespace is a non-empty binary, so it admits (documented shape)" do
      # The validity law is is_binary + byte_size > 0; whitespace IRIs are
      # admitted by that law — this pins the current documented behavior.
      p = plan([step("   ")], "urn:plan:whitespace-iri")
      compile_ok?(Compiler.compile_spec(p, handlers(p)))
    end
  end
end
