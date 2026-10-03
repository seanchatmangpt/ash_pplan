defmodule AshPPlan.Hardening.CapabilityPolicyTest do
  @moduledoc """
  HARDEN lane: nil/garbage capability ids, unknown providers, wrong-typed
  action options, closure over cyclic graphs. Typed-refusal law: every bad
  input returns a typed error, never raises.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Capability
  alias AshPPlan.CapabilityPack
  alias AshPPlan.PolicyClosure.AuthorityCeiling
  alias AshPPlan.Providers.{Registry, Resolver}
  alias AshPPlan.Workflow.{Model, Task}

  defp no_raise(fun) do
    fun.()
  rescue
    e -> flunk("raised instead of typed refusal: #{Exception.format(:error, e)}")
  end

  # ---- Capability.parse/1 -----------------------------------------------------------------

  describe "capability id parsing" do
    test "nil, integers, lists, maps, tuples refuse typed, never raise" do
      for bad <- [nil, 123, [], %{}, {:odd, :tuple}, 1.5] do
        assert {:error, %{reason: :invalid_capability}} =
                 no_raise(fn -> Capability.parse(bad) end)
      end
    end

    test "garbage strings and bare family are refused" do
      for bad <- [
            "",
            "nope",
            "File",
            "9File.Write",
            "File.",
            ".Write",
            "File..Write",
            "File.9Write"
          ] do
        refute Capability.valid?(bad), "expected refusal for #{inspect(bad)}"
      end
    end

    test "unknown family is refused with the id echoed back" do
      assert {:error, %{reason: :invalid_capability, capability: "Galaxy.Spin"}} =
               Capability.parse("Galaxy.Spin")
    end

    test "valid ids parse and normalize" do
      assert {:ok, %Capability{family: :file, name: "Write", id: "File.Write"}} =
               Capability.parse("File.Write")

      assert {:ok, "file.write"} = Capability.normalize("file.write")
      assert {:ok, "File.Write"} = Capability.normalize(:"File.Write")
      assert Capability.valid?(:"File.Write")
    end

    test "multi-segment names keep the remainder as name" do
      assert {:ok, %Capability{family: :file, name: "Write.Binary"}} =
               Capability.parse("File.Write.Binary")
    end

    test "normalize of garbage is a typed error" do
      assert {:error, %{reason: :invalid_capability}} = Capability.normalize(42)
      # a well-formed Capability struct round-trips through normalize
      assert {:ok, "x"} = Capability.normalize(%Capability{id: "x", family: :file, name: "x"})
    end
  end

  # ---- AuthorityCeiling ---------------------------------------------------------------------

  describe "authority ceiling" do
    test "allowed levels admit; everything else is a typed refusal, never a raise" do
      assert {:ok, :observe} = AuthorityCeiling.admit(:observe)
      assert {:ok, :select} = AuthorityCeiling.admit(:select)
      assert {:ok, :construct} = AuthorityCeiling.admit(:construct)

      for bad <- [:do, nil, "observe", 7, 1.5, %{}, []] do
        assert {:error, :authority_ceiling} = no_raise(fn -> AuthorityCeiling.admit(bad) end)
      end
    end
  end

  # ---- CapabilityPack.load/1 ----------------------------------------------------------------

  describe "capability pack loading" do
    test "garbage shapes refuse without raising" do
      for bad <- [nil, 123, "pack", :atom, [1, 2], {:a, :b}] do
        assert {:error, %{reason: :invalid_pack}} = no_raise(fn -> CapabilityPack.load(bad) end)
      end
    end

    test "missing id or capabilities refuses typed" do
      assert {:error, %{reason: :invalid_pack, detail: :missing_id_or_capabilities}} =
               CapabilityPack.load(%{capabilities: ["File.Read"]})

      assert {:error, %{reason: :invalid_pack, detail: :missing_id_or_capabilities}} =
               CapabilityPack.load(%{id: "p"})
    end

    test "mixed non-string/atom keys alongside string keys still load (typed success)" do
      assert {:ok, %CapabilityPack{}} =
               no_raise(fn ->
                 CapabilityPack.load(%{1 => :x, "id" => "p", "capabilities" => ["File.Read"]})
               end)
    end

    test "wrong-typed fields refuse typed (authority, capability members, empty list)" do
      assert {:error, %{reason: :authority_ceiling}} =
               CapabilityPack.load(%{id: "p", capabilities: ["File.Read"], authority: 123})

      assert {:error, %{reason: :invalid_capability}} =
               CapabilityPack.load(%{id: "p", capabilities: [123]})

      assert {:error, %{reason: :invalid_pack, detail: :no_capabilities}} =
               CapabilityPack.load(%{id: "p", capabilities: []})
    end

    test "duplicate capabilities refuse typed" do
      assert {:error, %{reason: :invalid_pack, detail: :duplicate_capabilities}} =
               CapabilityPack.load(%{id: "p", capabilities: ["File.Read", "File.Read"]})
    end

    test "string keys load equivalently to atom keys" do
      assert {:ok, %CapabilityPack{capabilities: ["File.Read"], id: "p"}} =
               CapabilityPack.load(%{"id" => "p", "capabilities" => ["File.Read"]})
    end

    test "a map with only non-string/atom keys refuses typed (no FunctionClauseError)" do
      assert {:error, %{reason: :invalid_pack, detail: :missing_id_or_capabilities}} =
               no_raise(fn -> CapabilityPack.load(%{1 => :x, 2.5 => :y}) end)
    end
  end

  # ---- Provider doubles (real modules, no mocks) ----------------------------------------------

  defmodule OkProvider do
    @behaviour AshPPlan.Provider

    def id, do: :ok_provider
    def capabilities, do: ["Observation.Telemetry"]
    def properties, do: [:durable]
    def evidence, do: [:receipt]
    def cost, do: 1.0
    def qualify(_req, _ctx), do: :ok

    def realize(_req, _ctx),
      do:
        AshPPlan.Realization.new(
          %{provider: __MODULE__, adapter: :local, op: :observation_telemetry},
          "Observation.Telemetry"
        )
  end

  defmodule RaisingProvider do
    @behaviour AshPPlan.Provider

    def id, do: :raising
    def capabilities, do: ["File.Read"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 0.1
    def qualify(_req, _ctx), do: :ok
    def realize(_req, _ctx), do: raise("boom")
  end

  defmodule GarbageProvider do
    @behaviour AshPPlan.Provider

    def id, do: :garbage
    def capabilities, do: ["File.Read"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 0.0
    def qualify(_req, _ctx), do: :ok
    def realize(_req, _ctx), do: {:ok, %{not: :a_realization}}
  end

  defmodule RaisingQualifyProvider do
    @behaviour AshPPlan.Provider

    def id, do: :raising_qualify
    def capabilities, do: ["File.Read"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 0.5
    def qualify(_req, _ctx), do: raise("qualify boom")
    def realize(_req, _ctx), do: {:ok, nil}
  end

  defmodule OtherCapabilityProvider do
    @behaviour AshPPlan.Provider

    def id, do: :other_capability
    def capabilities, do: ["Network.Call"]
    def properties, do: []
    def evidence, do: []
    def cost, do: 0.0
    def qualify(_req, _ctx), do: :ok

    def realize(_req, _ctx),
      do:
        AshPPlan.Realization.new(
          %{provider: __MODULE__, adapter: :anon, op: :net},
          "Network.Call"
        )
  end

  describe "resolver typed refusals" do
    test "requirement that is not a map refuses typed, never raises" do
      for bad <- [nil, :atom, ["capability"], "File.Read", 42] do
        assert {:error, %{reason: :no_qualified_provider}} =
                 no_raise(fn -> Resolver.resolve([OkProvider], bad) end)
      end
    end

    test "nil/garbage capability id refuses typed" do
      for bad <- [nil, "", "nope", "7File.Write", 123, :garbage] do
        assert {:error, %{reason: :no_qualified_provider}} =
                 Resolver.resolve([OkProvider], %{capability: bad})
      end
    end

    test "string-keyed requirement refuses typed" do
      assert {:error, %{reason: :no_qualified_provider}} =
               Resolver.resolve([OkProvider], %{"capability" => "File.Read"})
    end

    test "no provider supports the capability: typed refusal with empty rejection list" do
      assert {:error,
              %{
                reason: :no_qualified_provider,
                rejected: [{OtherCapabilityProvider, :capability_unsupported}]
              }} =
               Resolver.resolve([OtherCapabilityProvider], %{capability: "File.Read"})
    end

    test "provider whose qualify/2 raises is contained as a typed rejection" do
      assert {:error, %{reason: :no_qualified_provider, rejected: rejected}} =
               Resolver.resolve([RaisingQualifyProvider], %{capability: "File.Read"})

      assert [{RaisingQualifyProvider, {:qualify_raised, "qualify boom"}}] = rejected
    end

    test "provider whose realize/2 raises is contained as realize_failed" do
      assert {:error, %{reason: :no_qualified_provider, rejected: rejected}} =
               Resolver.resolve([RaisingProvider], %{capability: "File.Read"})

      assert [{RaisingProvider, {:realize_failed, {:raised, "boom"}}}] = rejected
    end

    test "realize returning a non-realization is typed-rejected" do
      assert {:error, %{reason: :no_qualified_provider, rejected: rejected}} =
               Resolver.resolve([GarbageProvider], %{capability: "File.Read"})

      assert [{GarbageProvider, {:realize_failed, {:not_a_realization, _}}}] = rejected
    end

    test "unknown/refused authority levels refuse typed" do
      assert {:error, %{reason: :no_qualified_provider, detail: {:unknown_authority, :warp}}} =
               Resolver.resolve([], %{capability: "File.Read", authority: :warp})

      assert {:error, %{reason: :no_qualified_provider, detail: {:authority_refused, :do}}} =
               Resolver.resolve([], %{capability: "File.Read", authority: :do})

      assert {:error,
              %{
                reason: :no_qualified_provider,
                detail: {:authority_exceeds_ceiling, :select, :observe}
              }} =
               Resolver.resolve([], %{capability: "File.Read", authority: :select}, %{
                 ceiling: :observe
               })
    end

    test "happy path selects the real provider and binds a step" do
      assert {:ok, %{provider: OkProvider, step: {step, _}}} =
               Resolver.resolve([OkProvider], %{capability: "Observation.Telemetry"})

      assert is_atom(step)
    end
  end

  describe "registry" do
    test "seal of an unknown provider is a no-op (no crash, same generation)" do
      reg = Registry.new([])
      assert Registry.seal(reg, DoesNotExist, :x) == reg
    end

    test "seal then resolve degrades to a typed refusal" do
      reg = Registry.new([OkProvider]) |> Registry.seal(OkProvider)

      assert {:error, %{reason: :no_qualified_provider}} =
               Registry.resolve(reg, %{capability: "File.Read"})
    end

    test "register dedups and bumps the generation" do
      reg = Registry.new([OkProvider]) |> Registry.register(OkProvider)
      assert Registry.providers(reg) == [OkProvider]
      assert reg.generation == 1
    end
  end

  # ---- Action.Run option validation -----------------------------------------------------------

  describe "action run option validation" do
    @resource AshPPlan.Test.PlanRunResource

    defp call(opts, arguments \\ %{plan_iri: "https://example.test/plan", input: %{}}) do
      AshPPlan.Action.Run.run(
        %{arguments: arguments, resource: @resource, action: %{touches_resources: []}},
        opts,
        %{}
      )
    end

    test "invalid option types refuse typed, never raise" do
      for opts <- [
            [handlers: :not_a_map],
            [plans: "not_a_list"],
            [plans: [1, 2]],
            [allow_halt?: "yes"],
            [reactor_options: :not_a_list],
            [reactor_options: [1, 2]]
          ] do
        assert {:error,
                %AshPPlan.Action.Run.Refusal{reason: :invalid_action_options, details: details}} =
                 no_raise(fn -> call(opts) end)

        assert is_map(details)
      end
    end

    test "missing arguments refuse typed" do
      assert {:error,
              %AshPPlan.Action.Run.Refusal{
                reason: :missing_action_argument,
                details: %{argument: :plan_iri}
              }} =
               call([], %{handlers: %{}, input: %{}})

      assert {:error,
              %AshPPlan.Action.Run.Refusal{
                reason: :missing_action_argument,
                details: %{argument: :input}
              }} =
               call([], %{plan_iri: "https://example.test/plan", handlers: %{}})
    end

    test "non-binary plan_iri refuses typed; plan outside allowlist refuses plan_not_allowed" do
      assert {:error, %AshPPlan.Action.Run.Refusal{reason: :invalid_action_arguments}} =
               call([], %{plan_iri: 42, input: %{}})

      assert {:error, %AshPPlan.Action.Run.Refusal{reason: :plan_not_allowed}} =
               call(plans: ["https://example.test/other"])
    end

    test "argument-supplied handlers when server-side handlers configured: refused" do
      assert {:error, %AshPPlan.Action.Run.Refusal{reason: :handlers_argument_refused}} =
               call([handlers: %{}], %{plan_iri: "p", input: %{}, handlers: %{}})
    end

    test "non-map handlers argument without server config refuses typed" do
      assert {:error, %AshPPlan.Action.Run.Refusal{reason: :invalid_action_arguments}} =
               call([], %{plan_iri: "e", input: %{}, handlers: :garbage})
    end
  end

  # ---- Cyclic dependency graphs ---------------------------------------------------------------

  describe "cyclic dependency graphs" do
    test "topological_order terminates on a 2-cycle and names the cyclic tasks" do
      tasks = [
        %Task{id: "a", depends_on: ["b"]},
        %Task{id: "b", depends_on: ["a"]}
      ]

      assert {:error, %{reason: :cyclic_dependencies, tasks: ["a", "b"]}} =
               Model.topological_order(tasks)
    end

    test "self-dependency is refused as cyclic, not an infinite loop" do
      assert {:error, %{reason: :cyclic_dependencies, tasks: ["a"]}} =
               Model.topological_order([%Task{id: "a", depends_on: ["a"]}])
    end

    test "large cyclic graph (1000-node ring) terminates" do
      ring = Enum.map(1..1000, &task("t#{&1}", ["t#{rem(&1, 1000) + 1}"]))

      {micros, result} = :timer.tc(fn -> Model.topological_order(ring) end)
      assert {:error, %{reason: :cyclic_dependencies}} = result
      assert micros < 2_000_000
    end

    test "validate/1 on a cyclic model refuses typed" do
      model = %Model{
        name: "cyc",
        tasks: [%Task{id: "a", depends_on: ["b"]}, %Task{id: "b", depends_on: ["a"]}]
      }

      assert {:error, %{reason: :cyclic_dependencies}} = Model.validate(model)
    end
  end

  defp task(id, deps), do: %Task{id: id, depends_on: deps}
end
