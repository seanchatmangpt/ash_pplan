defmodule AshPPlan.Workflow.RegistryTest do
  @moduledoc """
  Court: provider resolution honors semantic compatibility, execution
  properties, evidence, authority ceiling, availability, and cost-then-id order.

  Anti-vacuity: each filter is broken by a requirement it must reject.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Providers.Registry

  defmodule Base do
    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour AshPPlan.Provider
        @o opts
        def id, do: @o[:id]
        def capabilities, do: Keyword.get(@o, :caps, ["File.Write"])
        def properties, do: Keyword.get(@o, :props, [])
        def evidence, do: Keyword.get(@o, :evidence, [])
        def cost, do: Keyword.get(@o, :cost, 1)
        def qualify(_r, _c), do: Keyword.get(@o, :qualify, :ok)

        def realize(_r, _c),
          do:
            Keyword.get(
              @o,
              :realize,
              {:ok,
               %AshPPlan.Realization{
                 capability: "File.Write",
                 provider: id(),
                 binding: %{adapter: :reactor_file, op: :file_write}
               }}
            )
      end
    end
  end

  defmodule Cheap, do: use(Base, id: :cheap, cost: 1, props: [:durable], evidence: [:hash])

  defmodule Dear,
    do: use(Base, id: :dear, cost: 5, props: [:durable, :resumable], evidence: [:hash, :log])

  defmodule TieA, do: use(Base, id: :a_tie, cost: 3)
  defmodule TieB, do: use(Base, id: :b_tie, cost: 3)
  defmodule Down, do: use(Base, id: :down, cost: 0, qualify: {:error, :offline})
  defmodule Other, do: use(Base, id: :other, cost: 0, caps: ["Network.Fetch"])
  defmodule BadRealize, do: use(Base, id: :bad, cost: 0, realize: {:error, :boom})

  defmodule Ghost,
    do:
      use(Base,
        id: :ghost,
        cost: 0,
        realize:
          {:ok,
           %AshPPlan.Realization{
             capability: "File.Write",
             provider: :ghost,
             binding: %{adapter: :reactor_process, op: :file_write}
           }}
      )

  defp req(extra \\ %{}), do: Map.merge(%{capability: "File.Write"}, extra)

  test "lowest cost wins among qualified" do
    reg = Registry.new([Dear, Cheap])
    assert {:ok, %{provider: Cheap, candidates: [Cheap, Dear]}} = Registry.resolve(reg, req())
  end

  test "equal cost ordered by id" do
    reg = Registry.new([TieB, TieA])
    assert {:ok, %{provider: TieA}} = Registry.resolve(reg, req())
  end

  test "property support filters; mutation: dropping requirement changes winner" do
    reg = Registry.new([Cheap, Dear])

    assert {:ok, %{provider: Dear, rejected: [{Cheap, {:missing_properties, [:resumable]}}]}} =
             Registry.resolve(reg, req(%{properties: [:resumable]}))

    assert {:ok, %{provider: Cheap}} = Registry.resolve(reg, req())
  end

  test "evidence support filters" do
    reg = Registry.new([Cheap, Dear])
    assert {:ok, %{provider: Dear}} = Registry.resolve(reg, req(%{evidence: [:log]}))
  end

  test "unavailable and semantically incompatible providers are rejected with reasons" do
    reg = Registry.new([Down, Other, Cheap])
    assert {:ok, %{provider: Cheap, rejected: rejected}} = Registry.resolve(reg, req())
    assert {Down, {:unavailable, :offline}} in rejected
    assert {Other, :capability_unsupported} in rejected
  end

  test "failed realize falls through to the next candidate" do
    reg = Registry.new([BadRealize, Cheap])

    assert {:ok, %{provider: Cheap, rejected: [{BadRealize, {:realize_failed, :boom}}]}} =
             Registry.resolve(reg, req())
  end

  test "authority: :do is refused and ceiling is enforced" do
    reg = Registry.new([Cheap])

    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(reg, req(%{authority: :do}))

    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(reg, req(), %{ceiling: :do})

    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(reg, req(%{authority: :construct}), %{ceiling: :observe})

    assert {:ok, _} = Registry.resolve(reg, req(%{authority: :observe}), %{ceiling: :observe})
  end

  test "invalid capability is a typed refusal" do
    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(Registry.new([Cheap]), %{capability: "Bogus"})
  end

  test "register and seal bump generation; default/0 is a registry" do
    reg = Registry.new([Cheap])
    reg2 = Registry.register(reg, Dear)
    assert reg2.generation == reg.generation + 1
    assert Registry.providers(reg2) == [Cheap, Dear]
    assert %Registry{} = Registry.default()
  end

  test "an :unsupported adapter makes the provider a typed rejected candidate and falls through" do
    reg = Registry.new([Ghost, Cheap])

    assert {:ok, %{provider: Cheap, adapter: :reactor_file, op: :file_write, rejected: rej}} =
             Registry.resolve(reg, req())

    assert [{Ghost, {:unsupported_adapter, %{reason: :unsupported}}}] = rej

    assert {:error, %{reason: :no_qualified_provider, rejected: [{Ghost, _}]}} =
             Registry.resolve(Registry.new([Ghost]), req())
  end
end

defmodule AshPPlan.Workflow.RegistryB10Test do
  @moduledoc """
  B10-D1 court: per-step annotation properties qualify when they are
  namespaced provenance (`powl:...` curies emitted by `AshPPlan.POWL.Project`),
  while execution properties keep strict intersection with the provider's
  static `properties/0`.

  The provider is declared exactly like a generated provider (static
  `properties/0 = [:compensable]` that can never contain the annotations).
  The end-to-end case runs a real in-process Reactor over a projected POWL
  model through the documented `:extra_adapters` seam (save/restore, async:
  false because the seam is a global Application env).
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Providers.Registry
  alias AshPPlan.Workflow.Runtime
  alias AshPPlan.POWL

  # Local in-process step for `workflow.execute`: emits observation telemetry
  # and succeeds. A real Reactor.Step, never a stub return.
  defmodule WfAdapter do
    @behaviour AshPPlan.Reactor.Adapter

    def id, do: :wf_local
    def available?, do: true
    def ops, do: [:workflow_execute]

    def step(:workflow_execute, options),
      do: {:ok, {AshPPlan.Reactor.Steps.Telemetry, Keyword.put(options || [], :name, :b10_executed)}}

    def step(op, _options), do: {:error, {:unknown_op, op}}
  end

  # Generated-provider-shaped surface: static properties/0 cannot contain the
  # per-step `powl:` annotations.
  defmodule WfExec do
    @behaviour AshPPlan.Provider

    def id, do: :wf_exec
    def capabilities, do: ["workflow.execute"]
    def properties, do: [:compensable]
    def evidence, do: []
    def cost, do: 1
    def qualify(_r, _c), do: :ok

    def realize(_r, _c),
      do: {
        :ok,
        %AshPPlan.Realization{
          capability: "workflow.execute",
          provider: :wf_exec,
          binding: %{adapter: :wf_local, op: :workflow_execute}
        }
      }
  end

  setup do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :wf_local, WfAdapter)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
    :ok
  end

  test "annotation properties qualify; execution properties keep strict intersection" do
    reg = Registry.new([WfExec])

    # genuine missing-property refusal is unchanged: an execution property
    # (`:resumable`) the provider does not declare still refuses with reasons
    assert {:error,
            %{reason: :no_qualified_provider, rejected: [{WfExec, {:missing_properties, [:resumable]}}]}} =
             Registry.resolve(reg, %{capability: "workflow.execute", properties: [:resumable]})

    # conflicting static set still refuses: :resumable not in [:compensable]
    assert {:error, %{reason: :no_qualified_provider}} =
             Registry.resolve(
               Registry.new([WfExec]),
               %{capability: "workflow.execute", properties: [:resumable, "powl:id=a"]}
             )

    # namespaced annotations (curie form) qualify without being declared
    assert {:ok, %{provider: WfExec, rejected: []}} =
             Registry.resolve(reg, %{
               capability: "workflow.execute",
               properties: ["powl:operator=activity", "powl:id=a"]
             })

    # mixed static + annotation requirement qualifies on the static side
    assert {:ok, %{provider: WfExec}} =
             Registry.resolve(reg, %{
               capability: "workflow.execute",
               properties: [:compensable, "powl:id=a"]
             })
  end

  test "a capability with an execution property no provider declares still refuses" do
    reg = Registry.new([WfExec])

    assert {:error, %{reason: :no_qualified_provider, rejected: rejected}} =
             Registry.resolve(
               reg,
               %{capability: "workflow.execute", properties: [:unheard_of]}
             )

    assert [{WfExec, {:missing_properties, [:unheard_of]}}] = rejected
  end

  test "end-to-end: projected POWL steps qualify and execute" do
    assert {:ok, %{steps: steps}} =
             POWL.sequence("s1", [
               POWL.activity("a"),
               POWL.choice("c1", [POWL.activity("b"), POWL.activity("d")])
             ])
             |> AshPPlan.POWL.Project.to_reactor_steps()

    model_src = [name: :wf_b10, tasks: steps]

    # every projected step carries the capability + powl: annotations
    assert Enum.all?(steps, &(&1[:capability] == "workflow.execute"))
    assert Enum.any?(steps, fn step ->
             Enum.any?(step[:properties], &(&1 =~ "powl:id="))
           end)

    # qualifies: resolution binds every step despite undeclared annotations
    assert {:ok, r} = Runtime.resolve(model_src, providers: [WfExec])

    assert Enum.all?(steps, fn t ->
             res = r.resolutions[t[:id]]
             res.provider == WfExec and res.rejected == []
           end)

    # executes: a real in-process Reactor run over the projected model
    assert {:ok, state} = Runtime.run(model_src, %{}, providers: [WfExec])
    assert %{observation: %{state: :succeeded}} = state
  end
end
