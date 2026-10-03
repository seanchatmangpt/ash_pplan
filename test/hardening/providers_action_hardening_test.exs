defmodule AshPPlan.Hardening.ProvidersActionHardeningTest do
  @moduledoc """
  HARDEN lane: typed-refusal law over `AshPPlan.Providers.Qualify`,
  `AshPPlan.Providers.Registry` and `AshPPlan.Action.Run`.

  Garbage in -> typed refusal out. No raise ever escapes a public seam.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Action.Run
  alias AshPPlan.Action.Run.Refusal
  alias AshPPlan.Providers.{Qualify, Registry}

  describe "Qualify.check/6 garbage inputs" do
    test "non-map requirement is a typed rejection" do
      assert {:error, :invalid_requirement} =
               Qualify.check(nil, %{}, ["File.Write"], [], [], [:construct])
    end

    test "non-map context is a typed rejection" do
      assert {:error, :invalid_requirement} =
               Qualify.check(%{capability: "File.Write"}, :garbage, ["File.Write"], [], [], [
                 :construct
               ])
    end

    test "non-list capability surface is a typed rejection" do
      assert {:error, :invalid_requirement} =
               Qualify.check(%{capability: "File.Write"}, %{}, :garbage, [], [], [:construct])
    end

    test "non-list required properties are wrapped, not a `--` crash" do
      assert {:error, {:missing_properties, [:fast]}} =
               Qualify.check(
                 %{capability: "File.Write", properties: :fast},
                 %{},
                 ["File.Write"],
                 [],
                 [],
                 [
                   :construct
                 ]
               )
    end

    test "non-list required evidence is wrapped, not a `--` crash" do
      assert {:error, {:missing_evidence, [:audit]}} =
               Qualify.check(
                 %{capability: "File.Write", evidence: :audit},
                 %{},
                 ["File.Write"],
                 [],
                 [],
                 [
                   :construct
                 ]
               )
    end

    test "an authority at :do is a typed ceiling rejection" do
      assert {:error, {:authority_exceeds_ceiling, :do}} =
               Qualify.check(
                 %{capability: "File.Write", authority: :do},
                 %{},
                 ["File.Write"],
                 [],
                 [],
                 [:construct]
               )
    end
  end

  describe "Qualify.realize/4 garbage inputs" do
    test "non-map table is a typed refusal" do
      assert {:error, {:invalid_binding_entry, _}} =
               Qualify.realize(%{capability: "File.Write"}, :p, :not_a_map, [])
    end

    test "malformed table entry is a typed refusal, not a MatchError" do
      assert {:error, {:invalid_binding_entry, _}} =
               Qualify.realize(%{capability: "File.Write"}, :p, %{"File.Write" => :junk}, [])
    end

    test "wrong-arity table entry is a typed refusal" do
      assert {:error, {:invalid_binding_entry, _}} =
               Qualify.realize(%{capability: "File.Write"}, :p, %{"File.Write" => {:a, :b}}, [])
    end

    test "non-keyword requirement options are a typed refusal" do
      assert {:error, {:invalid_options, [:not_kw]}} =
               Qualify.realize(
                 %{capability: "File.Write", options: [:not_kw]},
                 :p,
                 %{"File.Write" => {SomeAdapter, :file_write, []}},
                 []
               )
    end

    test "well-formed requirement still realizes" do
      assert {:ok, %AshPPlan.Realization{options: [timeout: 5]}} =
               Qualify.realize(
                 %{capability: "File.Write", options: [timeout: 5]},
                 :p,
                 %{"File.Write" => {SomeAdapter, :file_write, [timeout: 1]}},
                 []
               )
    end
  end

  describe "Qualify.adapter_available/1" do
    test "non-atom adapter is typed unavailable" do
      assert {:error, {:unsupported, :reactor_process_unavailable}} =
               Qualify.adapter_available("NotAModule")
    end

    test "an adapter raising in available?/0 is unavailable, not a crash" do
      assert {:error, {:unsupported, :reactor_process_unavailable}} =
               Qualify.adapter_available(AshPPlan.Hardening.RaisingAdapter)
    end

    test "a loaded adapter with available?/0 -> true is available" do
      assert :ok = Qualify.adapter_available(AshPPlan.Hardening.OkAdapter)
    end
  end

  describe "Registry.resolve/3 garbage inputs" do
    test "non-map requirement is a typed refusal" do
      assert {:error, %{detail: :invalid_requirement_or_context}} =
               Registry.resolve(Registry.new([String]), "not a requirement")
    end

    test "non-map ctx is a typed refusal" do
      assert {:error, %{detail: :invalid_requirement_or_context}} =
               Registry.resolve(Registry.new([String]), %{capability: "File.Write"}, :garbage)
    end

    test "nil requirement is a typed no-provider refusal" do
      assert {:error, %{reason: :no_qualified_provider}} = Registry.resolve(Registry.new([]), nil)
    end

    test "empty registry yields the typed no-provider refusal" do
      assert {:error, %{reason: :no_qualified_provider, rejected: []}} =
               Registry.resolve(Registry.new([]), %{capability: "File.Write"})
    end

    test "real generated providers resolve a real capability" do
      reg = Registry.default()

      assert {:ok, %{provider: provider}} = Registry.resolve(reg, %{capability: "File.Write"})

      assert provider in AshPPlan.Generated.ProviderIndex.modules()
    end
  end

  describe "Action.Run direct invocation seams" do
    @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"

    test "non-map action_input / non-list opts is a typed refusal" do
      assert {:error, %Refusal{reason: :invalid_action_invocation}} =
               Run.run(:not_a_map, [], %{})

      assert {:error, %Refusal{reason: :invalid_action_invocation}} =
               Run.run(%{arguments: %{}}, :not_a_list, %{})
    end

    test "invalid server opts are a typed refusal" do
      assert {:error, %Refusal{reason: :invalid_action_options, details: %{option: :handlers}}} =
               Run.run(%{arguments: %{}}, [handlers: 1], %{})
    end

    test "non-binary plan_iri is a typed refusal" do
      assert {:error,
              %Refusal{reason: :invalid_action_arguments, details: %{argument: :plan_iri}}} =
               Run.run(%{arguments: %{plan_iri: 123, input: nil}}, [], %{})
    end

    test "plan_iri outside the allowlist is plan_not_allowed" do
      assert {:error, %Refusal{reason: :plan_not_allowed}} =
               Run.run(%{arguments: %{plan_iri: "https://example.com#nope"}}, [plans: ["y"]], %{})
    end

    test "a caller-supplied handlers argument is refused when handlers are configured" do
      assert {:error, %Refusal{reason: :handlers_argument_refused}} =
               Run.run(
                 %{arguments: %{plan_iri: @plan, handlers: %{}}},
                 [handlers: %{}],
                 %{}
               )
    end

    test "missing input argument is a typed refusal" do
      assert {:error, %Refusal{reason: :missing_action_argument, details: %{argument: :input}}} =
               Run.run(
                 %{arguments: %{plan_iri: @plan}},
                 [handlers: %{@plan => AshPPlan.Test.Steps.Emit}],
                 %{}
               )
    end
  end

  describe "real generated provider qualification" do
    test "garbage requirement properties never crash real qualification" do
      provider = hd(AshPPlan.Generated.ProviderIndex.modules())

      assert {:error, _typed} =
               provider.qualify(%{capability: "File.Write", properties: :garbage}, %{})
    end
  end
end

defmodule AshPPlan.Hardening.RaisingAdapter do
  def available?, do: raise("boom")
end

defmodule AshPPlan.Hardening.OkAdapter do
  def available?, do: true
end
