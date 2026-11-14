defmodule AshPPlan.ProviderQualificationPm4Test do
  @moduledoc """
  Process-conformance of real provider qualification traces.

  Every event is emitted from the observed outcome of a real call
  (`Capability.parse/1`, `Qualify.check/6`, `Qualify.realize/4`,
  `ProviderRegistry.select/2`); no event is fabricated.
  """
  use ExUnit.Case, async: true
  use Pm4ExUnit

  alias AshPPlan.{Capability, CapabilityPack}
  alias AshPPlan.FOND.ProviderRegistry
  alias AshPPlan.Providers.Qualify

  @moduletag :pm4exunit

  @table %{"file.Write" => {:file, :write, [mode: :append]}}

  @valid_paths [
    [:resolve, :qualify, :authority_check, :realize],
    [:resolve, :qualify]
  ]

  defp ev(session, activity, attrs \\ []) do
    emit_event(session, "e#{System.unique_integer([:positive, :monotonic])}", activity, attrs)
  end

  defp provider(overrides \\ %{}) do
    Map.merge(
      %{
        id: :fs_provider,
        capabilities: ["file.Write"],
        properties: [:durable, :resumable],
        evidence: [:receipt],
        authorities: Qualify.authorities(),
        cost: 1
      },
      overrides
    )
  end

  # Real pipeline: resolve -> qualify -> authority check -> realize (only if qualified).
  defp pipeline(session, requirement, prov) do
    case Capability.normalize(requirement.capability) do
      {:ok, canon} ->
        ev(session, :resolve)
        requirement = %{requirement | capability: canon}

        # Qualify.check/6 with the full authority list isolates the non-authority gates.
        case Qualify.check(requirement, %{}, prov.capabilities, prov.properties, prov.evidence) do
          :ok ->
            ev(session, :qualify)
            authority = Map.get(requirement, :authority)

            case Qualify.check(
                   requirement,
                   %{},
                   prov.capabilities,
                   prov.properties,
                   prov.evidence,
                   prov.authorities
                 ) do
              :ok ->
                ev(session, :authority_check)
                ev(session, :realize)

                {:ok, realization} = Qualify.realize(requirement, prov.id, @table, prov.properties)
                {:realized, realization}

              {:error, reason} ->
                _ = authority
                ev(session, :authority_check)
                {:rejected, reason}
            end

          {:error, reason} ->
            ev(session, :qualify)
            {:rejected, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  describe "capability parse and families" do
    test "every declared family is accepted", %{pm4_session: session} do
      for family <- Capability.families() do
        id = "#{Macro.camelize(Atom.to_string(family))}.Probe"
        assert {:ok, %Capability{family: ^family, name: "Probe"}} = Capability.parse(id)
        ev(session, :resolve)
      end

      assert_conformance(
        session,
        [List.duplicate(:resolve, length(Capability.families()))]
      )
    end

    test "invalid capability ids are refused with a typed reason" do
      for bad <- ["nodot", "Bogus.Thing", ".Write", "File.", "", 42, nil, %{}] do
        assert {:error, %{reason: :invalid_capability}} = Capability.parse(bad)
        refute Capability.valid?(bad)
      end
    end

    test "normalization is canonical across spellings" do
      assert {:ok, "file.Write"} = Capability.normalize("File.Write")
      assert {:ok, "file.Write"} = Capability.normalize("file.Write")
      assert {:ok, "file.Write"} = Capability.normalize(:"File.Write")
    end

    test "capability packs validate through the same parser" do
      assert {:ok, %CapabilityPack{authority: :construct}} =
               CapabilityPack.load(%{id: "p", capabilities: ["File.Write", "Network.Get"]})

      assert {:error, %{reason: :invalid_capability, capability: "Bogus.X"}} =
               CapabilityPack.load(%{id: "p", capabilities: ["File.Write", "Bogus.X"]})

      assert {:error, %{reason: :invalid_pack, detail: :no_capabilities}} =
               CapabilityPack.load(%{id: "p", capabilities: []})

      assert {:error, %{reason: :invalid_pack, detail: :duplicate_capabilities}} =
               CapabilityPack.load(%{id: "p", capabilities: ["File.Write", "File.Write"]})
    end
  end

  describe "qualification pipeline stages" do
    test "qualified provider traces resolve, qualify, authority_check, realize",
         %{pm4_session: session} do
      req = %{capability: "File.Write", properties: [:durable], evidence: [:receipt]}

      assert {:realized, realization} = pipeline(session, req, provider())
      assert realization.capability == "file.Write"
      assert realization.binding == %{adapter: :file, op: :write}

      assert_conformance(session, @valid_paths)
    end

    test "rejected provider stops after qualify", %{pm4_session: session} do
      req = %{capability: "File.Write", properties: [:atomic]}

      assert {:rejected, {:missing_properties, [:atomic]}} =
               pipeline(session, req, provider())

      assert_conformance(session, @valid_paths)
    end

    test "realizing a rejected provider violates the model", %{pm4_session: session} do
      req = %{capability: "file.Write", evidence: [:signature]}

      assert {:error, {:missing_evidence, [:signature]}} =
               Qualify.check(req, %{}, ["file.Write"], [], [:receipt])

      ev(session, :resolve)
      ev(session, :qualify)

      # A driver that realizes regardless of the qualification result.
      assert {:ok, _} = Qualify.realize(req, :fs_provider, @table)
      ev(session, :realize)

      refute_conformance(session, @valid_paths)
    end

    test "every capability in a batch follows resolve then qualify then optional realize",
         %{pm4_session: session} do
      reqs = [
        %{capability: "File.Write"},
        %{capability: "Network.Get"},
        %{capability: "File.Write", properties: [:atomic]}
      ]

      outcomes = Enum.map(reqs, &pipeline(session, &1, provider()))

      assert [{:realized, _}, {:rejected, {:unsupported_capability, "network.Get"}},
              {:rejected, {:missing_properties, [:atomic]}}] = outcomes

      per_capability_path = @valid_paths

      # resolve/qualify/(authority_check/realize) repeated per capability
      assert_conformance(
        session,
        [
          [:resolve, :qualify, :authority_check, :realize, :resolve, :qualify, :resolve, :qualify]
        ]
      )

      assert length(per_capability_path) == 2
    end
  end

  describe "typed refusal" do
    test "unsatisfiable properties" do
      assert {:error, {:missing_properties, [:atomic]}} =
               Qualify.check(
                 %{capability: "file.Write", properties: [:durable, :atomic]},
                 %{},
                 ["file.Write"],
                 [:durable],
                 []
               )
    end

    test "unsatisfiable evidence" do
      assert {:error, {:missing_evidence, [:signature]}} =
               Qualify.check(
                 %{capability: "file.Write", evidence: [:receipt, :signature]},
                 %{},
                 ["file.Write"],
                 [],
                 [:receipt]
               )
    end

    test "unsupported capability, compared in canonical form" do
      assert {:error, {:unsupported_capability, "network.Get"}} =
               Qualify.check(%{capability: "network.Get"}, %{}, ["file.Write"], [], [])

      assert :ok = Qualify.check(%{capability: "file.Write"}, %{}, ["File.Write"], [], [])

      # Only the family is case-folded; the capability name is case-sensitive.
      assert {:error, {:unsupported_capability, "file.write"}} =
               Qualify.check(%{capability: "file.write"}, %{}, ["File.Write"], [], [])
    end

    test "garbage requirement or surface is refused, never raised" do
      assert {:error, :invalid_requirement} = Qualify.check(:nope, %{}, [], [], [])
      assert {:error, :invalid_requirement} = Qualify.check(%{}, %{}, :nope, [], [])
      assert {:error, {:invalid_binding_entry, :not_a_map}} = Qualify.realize(%{}, :p, :nope)

      assert {:error, {:unsupported_capability, "file.read"}} =
               Qualify.realize(%{capability: "file.read"}, :p, @table)
    end
  end

  describe "authority ceilings" do
    test "ceiling list tops out at construct" do
      assert List.last(Qualify.authorities()) == :construct
      refute :do in Qualify.authorities()
    end

    test "requested authority above the ceiling is refused" do
      assert {:error, {:authority_exceeds_ceiling, :do}} =
               Qualify.check(
                 %{capability: "file.Write", authority: :do},
                 %{},
                 ["file.Write"],
                 [],
                 []
               )
    end

    test "authority may come from context and is checked against a lower provider ceiling" do
      assert {:error, {:authority_exceeds_ceiling, :construct}} =
               Qualify.check(
                 %{capability: "file.Write"},
                 %{authority: :construct},
                 ["file.Write"],
                 [],
                 [],
                 [:none, :observe]
               )

      assert :ok =
               Qualify.check(
                 %{capability: "file.Write", authority: :observe},
                 %{},
                 ["file.Write"],
                 [],
                 [],
                 [:none, :observe]
               )
    end

    test "authority-rejected provider stops before realize", %{pm4_session: session} do
      prov = provider(%{authorities: [:none, :observe]})
      req = %{capability: "File.Write", authority: :construct}

      assert {:rejected, {:authority_exceeds_ceiling, :construct}} =
               pipeline(session, req, prov)

      assert_conformance(session, [
        [:resolve, :qualify, :authority_check],
        [:resolve, :qualify, :authority_check, :realize]
      ])
    end

    test "packs cannot declare authority above construct" do
      assert {:error, %{reason: :authority_ceiling, max: :construct}} =
               CapabilityPack.load(%{id: "p", capabilities: ["File.Write"], authority: :do})
    end
  end

  describe "cost-ordered selection among qualified providers" do
    test "cheapest qualified provider is selected and realized", %{pm4_session: session} do
      candidates = [
        provider(%{id: :pricey, cost: 9}),
        provider(%{id: :cheap, cost: 1}),
        provider(%{id: :unqualified, cost: 0, properties: []}),
        provider(%{id: :mid, cost: 4})
      ]

      req = %{capability: "file.Write", properties: [:durable]}
      ev(session, :resolve)

      qualified =
        Enum.filter(candidates, fn prov ->
          result =
            Qualify.check(req, %{}, prov.capabilities, prov.properties, prov.evidence)

          ev(session, :qualify)
          result == :ok
        end)

      assert Enum.map(qualified, & &1.id) |> Enum.sort() == [:cheap, :mid, :pricey]

      registry =
        ProviderRegistry.new(
          Enum.map(qualified, &%{id: &1.id, capabilities: &1.capabilities, cost: &1.cost})
        )

      assert {:ok, %{id: :cheap}, _gen} = ProviderRegistry.select(registry, ["file.Write"])
      ev(session, :select)

      assert {:ok, _} = Qualify.realize(req, :cheap, @table, [:durable])
      ev(session, :realize)

      assert_conformance(session, [
        [:resolve, :qualify, :qualify, :qualify, :qualify, :select, :realize]
      ])
    end

    test "unhealthy cheapest provider is skipped; equal cost breaks ties deterministically" do
      registry =
        ProviderRegistry.new([
          %{id: :b, capabilities: ["file.Write"], cost: 2},
          %{id: :a, capabilities: ["file.Write"], cost: 2},
          %{id: :cheap, capabilities: ["file.Write"], cost: 1}
        ])

      {:ok, %{id: :cheap}, gen} = ProviderRegistry.select(registry, ["file.Write"])
      {:ok, down} = ProviderRegistry.observe_health(registry, gen, :cheap, false)

      assert {:ok, %{id: :a}, _} = ProviderRegistry.select(down, ["file.Write"])

      assert {:error, {:stale_generation, _, _}} =
               ProviderRegistry.observe_health(down, gen, :a, false)
    end

    test "no qualified provider yields a typed no_provider refusal" do
      registry = ProviderRegistry.new([%{id: :only, capabilities: ["network.Get"]}])

      assert {:error, {:no_provider, ["file.Write"]}} =
               ProviderRegistry.select(registry, ["file.Write"])
    end
  end
end
